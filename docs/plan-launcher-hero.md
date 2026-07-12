# Plan — the launcher hero, as a generic notification feed

> Status: approved by the user (2026-07-12), implementing.
> Goal: the hero carousel stops being "a NOSTR widget" and becomes **the
> launcher's notification surface** — any wapp can publish into it, it focuses on
> the people you follow, it caches and serves what they post, and it costs nothing
> when nobody is looking at it.

## 1. Context — what is wrong today

The hero carousel (`lib/launcher/novelties_carousel.dart`) is fed by
`lib/services/novelties_service.dart`, which opens its own NOSTR subscriptions and
ranks them with a crude integer `score` (`novelties_service.dart:56`). Nothing
else in the system can put anything on the hero. A blog wapp has no way in.

Four problems on top of that, each verified in the tree:

| Problem | Where |
|---|---|
| Refresh timer and carousel animation run while a wapp page is on top, and while the screen is off | `novelties_service.dart:387` (`Timer.periodic(1 minute)`), `novelties_carousel.dart:49` (6 s advance). `LauncherPage` stays mounted under pushed routes, and **nothing in the app observes routes or lifecycle** — no `RouteObserver`, no `navigatorObservers`. |
| We forget what the people we follow said, and serve it to nobody | The NOSTR hub isolate writes `nostr_feed.sqlite3` (`rns_service.dart:2081`). `RelayNode` — what answers other peers — serves `_relayStore` = `social.sqlite3` (`rns_service.dart:1989`). **The hub never writes into `_relayStore`.** Only locally-published notes (`:3703`) and events off the RNS relay protocol (`admitEvent`, `:2022`) land there. The comment at `:2061` claiming they merge into one store is wrong. |
| The storage quota is decorative | `hostQuota()` (`:4792`) reads `host.ceilingGb`, default **100 GB** (`preferences_service.dart:138`). `planEviction()` runs hourly (`:2195-2237`) and evicts nothing. And `BlossomServer` only ever starts lazily from inside `hal_media_infohash` (`wapp_engine.dart:1258`) — a device that merely *reads* the feed never starts it and serves no media at all. |
| Unreadable cards, blind dock | The scrim is a flat 0.10→0.78 black over the whole image (`novelties_carousel.dart:230-241`): it dims the photo and is still too light behind the summary. No timestamp. And the dock's 4 slots are ordered purely by pins/launch-count (`home_modules.dart:9-33`), so a wapp with 12 unread can sit off-dock, invisible — even though `WappUnreadService` already paints a badge on its tile. |

## 2. Decisions taken

- **Follows-only, strict.** Once you follow anyone, the hero shows *only* their
  posts. No global discovery mixed in. Quiet follows are backfilled from the local
  cache (their older posts), not from the network's popular posts.
- **NOSTR stays a host source, not a wapp source.** The social wapp is a pure UI
  driver with no storage; every piece of NOSTR state already lives host-side.
  Third-party wapps publish through a new host message; NOSTR does not.
- **Whole-app AMOLED black**, not launcher-only.
- **10 GB media quota by default**, with a Settings slider.
- The wapp-facing API is a **host message over the existing `hal_msg_send`**, not
  a new HAL import — because that channel already works from a headless background
  wapp, which is exactly what a blog wapp is.

## 3. The generic feed

New `lib/services/hero/`. `novelties_service.dart` is absorbed; its pure parsers
move over intact (they run off the UI isolate via `compute` — that must not
regress).

```dart
class HeroItem {
  final String id;          // "<sourceId>:<rawId>"
  final String sourceId;    // 'nostr' (built-in) or the publishing wappId
  final String? intent;     // routes the tap
  final String title, summary;
  final String? imageUrl;   // http(s)://… or file:<sha256>.<ext> (MediaArchive)
  final Uint8List? thumbnail;
  final DateTime createdAt; // drives "19 minutes ago"
  final DateTime? expiresAt;
  final String? authorPubkey, authorName, authorPic;
  final int likes, replies, priority;
  final String? deepLink;               // -> WappPage.initialView
  final Map<String, dynamic>? payload;  // -> WappPage.initialPost
}

abstract class HeroSource {
  String get id;
  Future<List<HeroItem>> candidates();  // unranked; the ranker decides
}
```

`HeroFeedService` merges the sources, ranks, and publishes a
`ValueNotifier<List<HeroItem>>`. Two sources ship: `NostrHeroSource` (today's
logic, now yielding candidates instead of deciding) and `WappHeroSource`, backed
by `HeroInbox`.

### The wapp → host message

```json
{"type":"hero.publish","replace":true,"items":[{
   "id":"post-42", "title":"…", "summary":"…",
   "image":"https://…",     // or "file:<sha256>.jpg"
   "thumb":"<base64url>",   // optional inline preview
   "created_at":1752300000, // epoch SECONDS
   "ttl":86400, "view":"post:42", "intent":"blog", "priority":1
}]}
{"type":"hero.remove","id":"post-42"}
{"type":"hero.clear"}
```

Handled in **both** dispatchers, beside the existing `unread` branch —
`lib/wapp/wapp_page.dart` (foreground) and
`lib/wapp/background_wapp_manager.dart` (headless).

`HeroInbox` is the host-side sink and it does not trust the publisher: `id` ≤64
chars, title→80, summary→160, thumb ≤64 KB, `priority` clamped 0..2, and
`created_at` clamped to `[now-30d, now+5m]` — otherwise a wapp pins itself at the
top of the hero forever by claiming to be from the future. Rate-limited to 1
publish/sec per wapp; capped at 20 items per wapp and 8 wapps; TTL defaults to 24
h, hard cap 7 days. Persisted to `hero_inbox.json` so a headless publish survives
a restart.

Tapping a card reuses what exists: `_wappForIntent(intent)` →
`WappPage(initialView: deepLink, initialPost: payload)`. NOSTR items keep today's
`post:<id>` deep link, so `wapps/social/main.c` is untouched.

## 4. Ranking

```
score = (1 + likes + 2*replies)          // a reply beats a drive-by like
      * pow(0.5, ageHours / halfLife)    // 6 h in follows mode, 24 h cold
      * (hasImage ? 1.35 : 1.0)          // the hero needs a backdrop
      * (1 + 0.25 * priority)
```

- **Follows set non-empty** → NOSTR candidates are *only* kind-1 from followed
  authors, drawn from the live subscription **and** the local mirror
  (`RelayEventStore.feedForFollows`), so quiet follows still fill the carousel.
- **Follows set empty** → the existing discovery rung (`nostrDiscovery()`, ≥3
  reactions, self-filtering against spam) with the 45 s-grace firehose fallback for
  mesh-only nodes.
- **Per-author cap of 2**, so one loud follow cannot own all ten slots.
- **Wapp items** get up to **4 of the 10 slots** (max 2 per wapp), interleaved —
  never buried, never flooding. They backfill the rest if NOSTR under-delivers.

## 5. Visibility-gated refresh

`LauncherVisibility.visible = routeOnTop && resumed`, from a `RouteObserver`
registered on `MaterialApp.navigatorObservers` (with `LauncherPage` as `RouteAware`)
plus a `WidgetsBindingObserver`. `rootNavigatorKey.canPop()` is **not** a
substitute: the all-apps sheet and the drawer don't push routes, and a dialog
would false-negative.

`HeroRefresher` refreshes **every 5 minutes while visible**, immediately on
becoming visible if the last refresh is older than 90 s, and **cancels its timer
entirely when hidden**. The carousel's 6 s auto-advance and the connection dot's
2 s poll get the same gate — `docs/performance.md` §6.3 lists exactly this as a
cheap win not yet taken.

## 6. Cache what you follow — and serve it

**The mirror.** One *owned* subscription `{kinds:[0,1,3], authors:<follows>}`,
drained every 2 minutes into the **served** store in a single batched transaction.
`RelayNode` already answers peers' `REQ` out of that store, so the "be a mini-relay
for the people you follow" requirement needs **no protocol work** — only the write.

Three constraints from `docs/performance.md`, each one a rule the project already
paid for:

- **No crypto on main.** `RelayEventStore.put()` verifies id + Schnorr, and that
  store is on the **main isolate**. Re-verifying every followed author's events
  there is the pattern that froze the app for hours (§3.1). The `nostr-engine`
  isolate **already verified** them, so the mirror uses a new
  `putAllVerified(batch, tier:)` that skips it. Verification stays **on by default**
  for everything off the wire — only the already-verified in-process path opts out.
- **No reactions.** Kinds 0/1/3 only. §3.2 records that persisting the kind-7
  firehose — an unbatched INSERT per inbound reaction, for rows nobody reads —
  was itself a regression that pegged a core. Likes/replies come from the engine's
  in-memory tallies, which already exist.
- **Own and close the subscription.** A leaked NOSTR sub re-queries the relays and
  pays a verify per event *forever* — that is the `discoF` leak (§3.5) and the
  `wapp_engine.dart` engine-dispose fix. The mirror's sub is torn down on every
  follow-set change and on shutdown.

A followed note now lives in both `nostr_feed.sqlite3` (the engine's scratch
firehose cache) and `social.sqlite3` (what we durably serve). That duplication is
deliberate. Writing `social.sqlite3` from inside the engine isolate is *not* the
alternative: two writers on one sqlite file is a lock-contention bug waiting to
happen.

**Media.** `FollowedMediaCache` pulls the images of followed authors' posts into
`MediaArchive.putHosted(tier: followed)` — content-addressed, so `BlossomServer`
serves them to peers for free at `GET /<sha256>`. The item's `imageUrl` is
rewritten to `file:<sha>.<ext>`, so the card then renders from local bytes:
instant, and it works offline. Budgeted, because this writes multi-MB blobs into a
sqlite store on the main isolate: ≤4 blobs per cycle, ≤5 MB each, 2 concurrent
fetches, only while the launcher is visible and the network unmetered. And it
**caches the miss** (§3.2) — on a public network a dead image URL is the common
case, and a hit-only cache re-fetches it forever.

`BlossomServer` is started from `rns_autostart.dart` rather than lazily from a
share code path, or we cache media and serve it to nobody.

**The quota.** `host.ceilingGb` 100 → **10**, `host.strangerSliceGb` 100 → **2**,
plus a Settings slider with a live "x.x GB used" readout. `planEviction()` needs no
change — it already never touches our own content, never deletes followed **text**,
and evicts strangers first, then followed **media largest-first**. Only the number
was wrong. Text is structurally safe: `planEviction` is fed `hostedInventory()`,
which is blobs only.

## 7. The card, and the dock

- **Fade to black**: the flat full-height scrim becomes a bottom-anchored 5-stop
  gradient (`transparent → black@0.10 → 0.45 → 0.82 → 0.96`). The photo keeps its
  top half; the text sits on near-black; the stops make it read as a smooth
  transition rather than a band. A light top scrim keeps the author/time chips
  legible on a white photo.
- **"19 minutes ago"**: there are already **six** ago-formatters in the tree. The
  best (`activityTimeLabel`, `activity_feed.dart:681`) is extracted into
  `lib/util/time_ago.dart` and reused — we don't add a seventh.
- **Deep black**: `scaffoldBackgroundColor: black` + `surface: #0C0C0F`, so cards
  and the all-apps sheet still read as lifted above the background.
- **The dock floats what has unread**: alerting wapps come first (already-docked
  ones keep their mutual order; off-dock alerters are pulled in), then the normal
  pinned/most-launched resolution. It is a pure function of `(preferred, unread)`,
  so it only moves when the unread set moves. The 3 module bars are left alone —
  they are the user's chosen shortcuts and must not jitter.

## 8. What the live run proved (Linux desktop, 2026-07-12)

All of it on the desktop build, driven through the debug API (`:3466` on this
box) and X11 window capture.

| Claim | Evidence |
|---|---|
| A wapp can put a card on the hero | `POST /api/hero/publish` (the same `HeroInbox` entry point `hal_msg_send` lands on) → the card renders with its source chip, title, summary and time pill. |
| Follows-only, strict | `hero: source=follows (4 buffered)`; the four cards are exactly the followed authors, **two each** — the per-author cap, visible on screen. |
| The 5-minute refresh is gated on being seen | Opening a wapp logs `hero: launcher hidden (route=false resumed=true)`; `lastRefresh` then did not move for **100 s** (the old code would have refreshed twice). Coming back logs `visible` and refreshes at once. |
| We cache what we follow | Seeded a signed post from a followed author into the hub's own store (`test/live/hero_mirror_seed_test.dart`) → the mirror copied it into `social.sqlite3` at the followed tier: `perf: hero mirror stored=1 dropped=0 ms=3`. |
| …and **serve** it | Connected to the node's own relay endpoint as an outside client and asked for that author's posts — it handed the note back (`test/live/hero_mirror_serve_test.dart`). That is the mini-relay, proven from outside the app. |
| Blossom actually runs | `curl http://127.0.0.1:3457/` → `{"app":"aurora-blossom","v":1}`. Before this change it never started on a device that had not shared something. |
| Unread floats to the dock | Chat went from dock slot 4 to slot 1, badge `12`, when it gained unread. |
| Deep black | The launcher's background samples `#000000`. |

Unit: 47 tests green (`hero_ranker`, `hero_inbox`, `time_ago`,
`host_retention_policy`), plus `relay_store_put_verified_test.dart` in
reticulum-dart, which locks the security property that the batch path skips
verification **and the default `put()` still rejects a forged signature**.

### An unrelated bug this surfaced

`nostr-engine seen=0 stored=0` on this desktop: the hub is **ingesting nothing
from its five public wss relays**, and has not been. It is not the network — a
direct Dart WebSocket client from the same machine pulls events from
`relay.damus.io` and `nos.lol` fine — and it is not the hero work, which touches
no relay code. The hero can therefore only show what the Reticulum mesh and the
local mirror already hold. Worth its own investigation; the hub connects its
clients eagerly (`nostr_relay_hub.dart:144`), so the failure is inside the
client or the isolate it runs in.

## 9. Verification

Unit: ranker (follows-strict yields zero global items; author cap; wapp slot
reservation; decay ordering), inbox (clamps, TTL, replace-by-id, caps), `timeAgo`,
`putAllVerified` (**and that the default `put()` still rejects a forged
signature** — only the in-process path may skip verification), and
`host_retention_policy` at the new 10 GB / 2 GB numbers.

Live: on the **Linux desktop build** (`./launch-linux.sh`, debug API on
`localhost:3456`). Follow an account, confirm its notes land in `social.sqlite3`
(`perf: hero mirror stored=…` in `/api/log`, and the relay event count in
`/api/status` rising), then fetch one of its images back out of our own Blossom
(`curl http://127.0.0.1:3457/<sha256>`) — that is the cache-and-serve requirement
proven from the outside. Screenshots (X11 window capture) confirm the black
background, the readable hero text over a photo, and the "N minutes ago" label.

CPU, on the desktop, following the measurement discipline in `docs/performance.md`
§4 (long windows — CPU here is bursty too): `pidstat`/`/proc/<pid>/stat` over a
≥5-minute window with the launcher visible vs. a wapp page on top. With a wapp page
covering the launcher the hero must contribute **zero** — no refresh lines in
`/api/log`, no carousel animation. Then confirm no documented pattern regressed:
`main isolate stalled` stays at zero (a stall would mean the mirror is doing crypto
or an unbatched write on main), `crypto-worker` shows no paired `x25519Gen`/`edGen`
climb, `nostr-engine profileLookups` does not climb.

The Android numbers in `docs/performance.md` §7 (8% of a core, screen-off) are the
battery baseline this design is written against, but they are not re-measured here
— the desktop has no doze, no metered network and no screen-off state, so a phone
run is the only thing that could confirm them. Left for a later device pass.
