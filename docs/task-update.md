# RESOLVED 2026-07-15 15:05 — see the bottom section

The task described below was completed. The All feed's ten-minute curated
editions now fire indefinitely, device-validated (build 38400, PID 13500,
screenshots): editions at 14:53:58 (newest post 20s old) and 15:03:38 (newest
12s old), same untouched process. Two root causes, both fixed and pushed:

1. **The Android heartbeat listener removed itself after its first tick**
   (aurora `rns_service._nostrBackgroundTick`), so the wall clock reached the
   edition coordinator exactly once per process. It now lives until `stop()`.
   (Fix rode into aurora commit `1df4743` via a whole-file sweep.)
2. **The engine isolate was a pegged core doing pure-Dart BigInt Schnorr
   verification inline for every delivered event** (CPU profiler: 75% of
   samples in `_BigIntImpl.*`). Everything sharing that isolate starved —
   timers, port messages, websocket handshakes — which was the true cause of
   every "socket connected but silent" mystery. Verification now happens at
   KEEP-time in the hub, once per event id, after dedup and after the content
   gate (reticulum-dart `792e4e4`); forged events still die at the verify
   (test pinned). Editions also survive teardown/re-subscribe (the deadline
   belongs to the wall clock, not the subscriber lifecycle).

Forensics that found it (reusable): profile build (`--profile
--build-number=NNNNN`, release-signed, updates in place) → `/api/log` prints
the VM service URI → `setFlag profiler true` → `getCpuSamples` per isolate.
Tools live in the session scratchpad (`vmsamples.dart`, `vmflag.dart`).

---

# Handoff: the Social "All" feed — 5-minute curated poll

State of an unfinished task, written for whoever picks it up. The user's spec is
settled; the code for it is written and unit-tested; **it is uncommitted and its
on-device validation was not completed**. Read the whole file before touching
anything — most of the time already burned on this task was burned re-discovering
the traps listed at the bottom.

## The spec (user's words, do not re-litigate)

1. **The firehose runs ONLY when someone is looking at it**: Social's All tab is
   open, or the launcher Hero panel needs content because the user follows nobody
   yet. Never in the background — with the screen off, only Following, replies,
   mentions, DMs and notifications matter.
2. **The firehose is curated**: rank what arrives and show the most attractive
   posts — engagement (likes/replies), carries an image, author has a real
   profile, freshness. Followed authors bypass curation entirely.
3. **Update the All feed every 5 minutes with a new batch of posts. Polling, not
   streaming.** Evidence across the whole session: a fresh REQ reliably returns
   the newest ~200 events (`new=200` on every re-open), while waiting for live
   push after EOSE delivers nothing dependable on this phone. Stop depending on
   push.
4. **Pull-to-refresh = give me ~100 more curated notes, immediately.**
5. Validation is ONLY by screenshots taken on C61, clicking through the actual
   UI. No log-line is accepted as proof that the user can see something.

## Where the code stands (all of it analyze-clean, 23 nostr tests + full suites green)

### Already COMMITTED and pushed (earlier today)

- `reticulum-dart d89c080` — ingest fixes: event-id dedup at the firehose
  (`_fireSeenIds`), `since` watermark on re-open, flood rule counts distinct
  event ids not deliveries, kind-0 handled ahead of the rate cap
  (`_releaseProfile`), pending posts delivered-not-destroyed via `sweepExpired`,
  profile fetch retries (`_profileAsked`), teardown keeps caches.
- `reticulum-dart 1685dd5` — **FirehoseCurator**
  (`lib/src/services/social/firehose_curator.dart`): bounded candidate buffer
  (300), scoring (likes ×2, replies ×3, media +4, profile +3, familiar author,
  freshness, length floor), `take()` + `takeBurst(n)`, drops the WORST when full.
  Wired in the hub: gate-kept stranger posts → `_curator.offer(...)`; trusted
  authors bypass; delivered posts are `trackStats`-ed so like/reply counts show.
- `reticulum-dart 97f272f` — NIP-19 decode not capped at 90 chars.
- `aurora dddf890` — host refuses firehose/discovery to a **headless** engine
  (`wapp_engine.dart`, `if (headless) return 0;`) — this is what enforces spec
  §1; plus the 64 KB wapp event buffer note (the 8 KB one silently dropped most
  posts).
- `wapps d4fc3d7` — social wapp 0.2.33: asks for firehose only when
  `hal_ui_attached()`.
- `aurora 60cba93` — Following = mirrored kind-3 ∪ followed-here − unfollowed-here
  (see "Following" below), host-side follow/unfollow by full key, firehose stats
  accumulate correctly on main (they were a 400 ms snapshot read once a minute —
  that lie caused a day of false diagnosis).

### UNCOMMITTED (working trees, this is the actual task)

`reticulum-dart` (7 files + tests):

- `nostr_relay_hub.dart` — **the 5-minute poll cycle** replacing the 10 s
  trickle: while `_fireSubscribers` is non-empty, every 5 min:
  `_closeFirehoseReq(); _openFirehoseReq()` (cheap — `since` watermark), then a
  20 s timer → `_curator.takeBurst(100)` → `_deliverFirehose` each. Plus an
  opening batch 12 s after subscribe. Plus `resumeNetwork()` (reconnect zombie
  sockets + one since-bounded re-ask; called from pull-to-refresh and feed-open,
  throttled 20 s host-side) and `refreshBurst({n})`. Plus `relayHealth()`
  (status + frames per relay) and `debugCurateNow()` for tests.
- `nostr_ws_client.dart` — keepalive `pingInterval: 20 s` +
  `connectTimeout: 12 s` (IOWebSocketChannel), idle watchdog 45 s, `resume()`
  (reconnect now, skip backoff), frame counter `drainFrames()`.
- `nostr_engine.dart` — `refreshBurst`/`resume` commands; heavy sqlite throttled
  out of the 400 ms tick (`myNotifications` every 25th tick, `relaysJson` every
  5th) — it ran EVERY tick before; periodic `relays:` health log line.
- `nostr_relay_client.dart` + local/rns clients + test fakes — `drainFrames()` /
  `resume()` members.
- `firehose_curator.dart` — `takeBurst(n)` added.

`aurora` (3 files + bundled wapp):

- `rns_service.dart` — `nostrRefreshBurst`, `nostrResume` (20 s throttle),
  `followsDebug()` + `follows:` log line.
- `wapp_page.dart` — pull-to-refresh calls `nostrResume()` +
  `nostrRefreshBurst(n:100)` then the wapp command; opening the activity screen
  calls `nostrResume()`.
- `geoui/widgets/activity_feed.dart` — after refresh, `_pullNew(scroll:false)`
  adopts the fresh posts instead of parking them behind the "N new posts" pill.
- `assets/wapps/social.wapp` = 0.2.34.

`wapps` (social 0.2.34, uncommitted): `main.c` — pull-to-refresh no longer
unsubscribes/re-subscribes the feed subs (churn = relays quietly drop you); the
64 KB `g_evt` buffer; drain loop 300/tick at 700 ms.

**Diagnostic probes were removed** from all three layers (engine-isolate raw
probe, main-isolate twin, `frame#` logging). Health lines kept: `relays: …`,
`curator: …`, `perf: nostr firehose …`, `follows: …`.

## The unresolved question the next session MUST answer first

The isolate probe result is still unexplained and could invalidate the polling
assumption partially: an in-app raw `WebSocket.connect('wss://nos.lol')` **from
the NostrEngine isolate** timed out (12.000 s exactly — event loop responsive),
while the **same code on the main isolate** streamed instantly
(`probe MAIN nos.lol: frames=12`). Yet the hub's own clients in that same engine
isolate DO connect and DO pull backlogs (`new=200` on every re-open). So
"connect from the engine isolate" is flaky/slow, not impossible. The 5-minute
poll works with that (each poll re-uses the already-open sockets — it re-issues
REQs, it does not reconnect), but if polls come back empty on-device, suspect
the isolate's sockets again, and the fallback design is known: move the ws
clients to the main isolate behind the existing `NostrRelayClient` interface and
pipe frames to the engine (verify/store stay off the UI thread).

## What remains (in order)

1. **Validate on C61 by screenshots** — this was in progress when the task was
   handed off. Build `31910` (versionCode 33910) IS installed and contains
   everything above. Protocol:
   - `adb shell svc power stayon true` (removes the screen-off/Doze variable);
   - kill properly: `adb shell am force-stop com.geogram.aurora`, **verify**
     `adb shell pidof com.geogram.aurora` is empty;
   - launch, open Social → screenshot: posts present, top post minutes old, like
     counts non-zero on curated posts;
   - stay ≥6 min (one full poll cycle; watch `curator: 5-min cycle handed over N`
     in the log) → screenshot: **top post changed**;
   - pull-to-refresh (`input swipe 360 400 360 1200 300`) → screenshot: a batch
     of new curated notes appears immediately (log: `curator: refresh handed
     over N`);
   - the last T0 screenshot taken (00:07) showed top posts **1 h old** — the
     opening batch either hadn't landed yet or delivered old-but-top-ranked
     items. If reproduced: check `curator: opening batch N` fired, and whether
     the archive's newest row actually advanced (the feed renders the archive).
2. **If a poll returns nothing** (`new=0` on the cycle): the relays answer a
   *fresh REQ on a fresh socket* reliably; make the 5-min cycle call
   `resumeNetwork()` first (one-line change in the poll timer) so each poll
   rides a verified-live socket.
3. **Run both suites** (`flutter test` in both repos; aurora has one
   pre-existing failure `test/live/hero_mirror_serve_test.dart` and skips —
   unrelated; reticulum-dart 325 pass, one 107 MB transfer test is flaky-slow).
4. **Commit + push all three repos** (aurora, reticulum-dart, wapps; commit to
   main, no feature branches, no Claude co-author lines).
5. `svc power stayon false` when done.

## Traps that burned hours — do not rediscover them

- **A second Claude session shares these repos and the phone.** It bumps
  versionCode (31xxx → 33xxx ranges collide); `adb install -r` of an older
  versionCode **prints nothing useful and keeps the old app** — ALWAYS verify
  with `dumpsys package com.geogram.aurora | grep versionCode` after install,
  and rebuild with a higher `--build-number` when beaten. It also edits
  `reticulum-dart/lib/src/services/files/*` and `aurora/lib/wapp/wapp_engine.dart`
  mid-save: Gradle failures naming `FolderMeta` / `_onPiecePacket` are THEIR
  in-flight edits — wait ~60 s and rebuild; do not "fix" their files.
- **Shell cwd resets between commands, and `cd` into reticulum-dart leaks**: a
  build started after such a leak fails with `Target file "lib/main.dart" not
  found` — and a subsequent `adb install` then silently installs the PREVIOUS
  apk. Two separate "validated" runs were actually running stale builds because
  of this. Always build with an explicit cwd of `~/code/geogram/aurora`.
- **Wrap every flutter/gradle build in `~/bin/android-build-locked`** (16 GB
  machine, two concurrent builds freeze it).
- **Wapps bundle by version**: rebuilding `social.wapp` with the same manifest
  version means the host silently keeps the old copy. Bump `manifest.json`
  version every time; copy from `wapps/binaries/social/social-X.Y.Z.wapp` (build
  with `WASI_SDK_PATH=/home/brito/wasi-sdk make` then `./build-archive.sh social`).
- **The log API** (`adb forward tcp:3456 tcp:3456`, `curl /api/log?n=4000`)
  freezes when the app is backgrounded — a silent log means backgrounded app,
  not a hung app. Many `.dart` files trip grep's binary detection: use
  `grep -a`.
- **The stats lied once already**: any counter drained by one reader and logged
  by another reports garbage. `drainFirehoseStats` counters now accumulate on
  main and reset on log; keep it that way.

## Context that explains "why is Following empty"

The user's persisted follow set was destroyed by an earlier bug in this session
(a kind-3 mirror ran against a not-yet-fetched contact list and treated it as
empty). The account has **no kind-3 on the relays** and no tier-1 rows to
recover from, so the follows are gone for real; the user must re-follow. The
mirror is now guarded (`_mergeMyFollows` in `rns_service.dart`: an absent
contact list can never drive removals; explicit unfollows always honoured;
6 tests in `aurora/test/follow_mirror_test.dart`). Follow/unfollow now resolve
the full pubkey host-side (`_applyNostrFollow` in `wapp_page.dart`) — the old
path handed the wapp a 12-char prefix it usually could not resolve, making
unfollow a silent no-op. The "stupid error when following" (a warning toast on
every follow) was removed.

## Key files, one line each

- `reticulum-dart/lib/src/services/social/nostr_relay_hub.dart` — hub: gate →
  curator → subscribers; poll cycle; resume; health.
- `reticulum-dart/lib/src/services/social/firehose_curator.dart` — ranking +
  batching. Knobs: `maxCandidates 300`, `firstBurst 30`, `takeBurst(100)`.
- `reticulum-dart/lib/src/services/social/feed_quality.dart` — spam gate
  (unchanged rules; flood-by-id; `sweepExpired` delivers).
- `reticulum-dart/lib/src/services/social/nostr_ws_client.dart` — sockets:
  keepalive, idle watchdog, resume, frame counter.
- `reticulum-dart/lib/src/services/social/nostr_engine.dart` — the isolate:
  commands, tick (throttled sqlite), snapshots to main.
- `aurora/lib/wapp/wapp_engine.dart` — HAL; headless firehose refusal (~:2909);
  event_recv with the too-big log.
- `aurora/lib/wapp/wapp_page.dart` — feed wiring: onRefresh, mute, follow,
  mentions.
- `wapps/social/main.c` — subscriptions (UI-gated), drain, refresh handler.
- Tests to keep green: `reticulum-dart/test/{firehose_curator,firehose_starvation,
  nostr_relay_hub,nostr_relay_defaults,feed_quality}_test.dart`,
  `aurora/test/{follow_mirror,note_mentions,notification_dedup}_test.dart`.
