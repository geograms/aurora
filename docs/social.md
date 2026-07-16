# The Social wapp — what it does, and what will bite you

> Companion docs: [NOSTR.md](NOSTR.md) (the vision + full architecture),
> [nostr-client.md](nostr-client.md) (relays as transports), [nostr-fix.md](nostr-fix.md)
> (the original All-refresh fix plan), [performance.md](performance.md) (the isolate
> model), [validation.md](validation.md) (the acceptance bar).
>
> This file is the **practical guide for anyone changing the Social feed**. It is
> written after several days of the feed being broken in ways that were not obvious
> from the code. Read the "Lessons / things to watch" section before you touch it.

---

## 1. What it is

Social is a NOSTR client shipped as a wapp. Four tabs:

- **Internet** (enum `all`, string `'all'` — kept for pref compat) — a *curated*
  feed of interesting public posts from strangers over wss relays. NOT a raw
  firehose (see §4). This is the tab that caused all the pain.
- **Nomadnet** (enum/string `nomadnet`) — NOSTR publications fetched over
  **Reticulum** (indexers + callsign peers) + this device's own posts. NO
  curation, newest-first. See §11.
- **Following** — kind-1 notes from the accounts the user follows (their own
  archive, `social_following.sqlite3`).
- **Saved** — posts the user bookmarked.

Each of the three feeds has its OWN sqlite DB: `social_all.sqlite3` (Internet),
`social_following.sqlite3` (Following), `social_nomadnet.sqlite3` (Nomadnet).

The protocol is NOSTR (kinds 0/1/6/7, NIP-01 wire, NIP-19 mentions, Schnorr). The
wapp id/title are "social"; the protocol keeps the "nostr" name. A "publication" =
a kind-1 text note.

---

## 2. Where the code lives (and who owns what)

The Social feed is split across **four** layers. Knowing which layer owns a thing
is most of the battle.

| Concern | Layer | File |
|---|---|---|
| Wapp UI + Following/thread/search drains | wapp C → WASM | `geograms/wapps/social/main.c`, `screens/*.ui.json` |
| Feed rendering (cards, tabs, compose) | host GeoUI | `aurora/lib/wapp/geoui/widgets/activity_feed.dart` |
| Feed state, archive, ranking, likes, profiles | host page | `aurora/lib/wapp/wapp_page.dart` |
| **The All-feed data source** | host, main isolate | `aurora/lib/services/social/nostr_all_poller.dart` |
| Persisted posts + engagement | host | `aurora/lib/wapp/geoui/activity_archive.dart` (`social_all.sqlite3`, `social_following.sqlite3`) |
| Keys, relay list, signed reactions | host | `aurora/lib/services/reticulum/rns_service.dart` |
| NOSTR engine (relay hub, gate, curator) | **`nostr-engine` isolate** | `reticulum-dart/lib/src/services/social/nostr_relay_hub.dart`, `nostr_engine.dart`, `nostr_ws_client.dart` |
| Launcher hero (when user follows nobody) | host | `aurora/lib/services/hero/nostr_hero_source.dart` |

The **All feed is driven entirely from the main isolate by `NostrAllPoller`** and
writes into `_activityArchive`. The engine isolate still exists (Following mirror,
notifications, the launcher hero) but **is not trusted for the All feed** — see §3.

---

## 3. The single most important fact: the engine isolate cannot reopen a WebSocket

**On real hardware (validated on a budget Android phone, "C61"), the `nostr-engine`
isolate freezes solid whenever it tries to (re)open a WebSocket.** The synchronous
portion of `WebSocketChannel.connect` blocks the whole isolate — even when fired
`unawaited`. The device log fingerprint was an edition logging `step=connect` and
never reaching the next line; every timer and message on that isolate stalled behind
it, and the feed died.

Consequences you must respect:

- **The main isolate opens WebSockets fine. The engine isolate does not.** Any
  feature that needs to fetch or publish over wss must run on the **main isolate**
  (that is why `NostrAllPoller` and `buildSignedReaction`-then-`publishEvent` live
  there).
- Sockets opened at engine *startup* happen to work and keep delivering — it is
  *reopening* after a relay cuts them that wedges the isolate. Do not build anything
  that relies on the engine reconnecting relay sockets.
- Public relays **cut idle clients constantly**. So the model is not "hold a socket
  open"; it is **poll-and-close**: open briefly, take what you need, disconnect.
  Never assume permanent internet or a lingering socket. This is off-grid software.

If you ever need genuine long-lived socket work, it must be on the main isolate or a
purpose-spawned isolate proven to open sockets on the target device — not the engine.

---

## 4. How the All feed is curated (`NostrAllPoller`)

A freshest-first firehose is useless: seconds-old posts have **no likes**, so the
feed looks dead and the user (rightly) complains it isn't real curation. So the
poller finds what is actually *popular* by sampling reactions.

Every ~10 minutes while Social is open (plus on open and pull-to-refresh), on one
set of short-lived main-isolate sockets:

1. **Phase 1** — REQ recent reactions/reposts (`kinds 6,7`, last ~2h) + a little
   fresh content (`kind 1`, last ~20m). Reactions point at whatever posts people
   are engaging with, of any age.
2. **Tally** likers per post id → the genuinely popular ids.
3. **Phase 2** — fetch those popular posts by id + their replies.
4. **Phase 3** — fetch `kind-0` **profiles** for the authors (so names/avatars show,
   not hex keys — §6).
5. **Disconnect all sockets.**
6. Off-thread in a `compute` isolate: verify Schnorr, spam-gate (`contentVerdict`),
   drop machine-junk payloads, and **score by real engagement**
   (`likes×3 + replies×4 + reposts×2`, freshness only a nudge). Keep the top **~22**.
7. Persist the curated posts with their real like counts (`setReaction` per liker)
   and their replies; hand the profiles to the host cache.

`compute` is safe here because it does **pure Dart** (no sockets) — none of the
engine-isolate freeze applies. Reaction *counting* is not verified (not worth
~100ms/signature for a like badge on a stranger's post); only the **posts shown**
are signature-verified.

The **display ranking** (`wapp_page._socialActivityPosts`) sorts the accumulated set
by `engagement × age-decay` and caps to ~60, so the most-liked/active surface and
yesterday's popular post fades below today's.

---

## 5. Likes / reactions — one implementation, main-isolate publish

**`wapp_page._likePost(mid, like)` is the ONE place a like is handled.** The feed,
thread and profile cards all call it. Do not add another. It:

1. Records the like locally: `_activityArchive.setReaction(mid, self, like, mine:true)`
   → the heart fills and the count updates instantly (the curated feed reads the
   archive, so this is what makes it visible).
2. Publishes the signed `kind-7` through `NostrAllPoller.publishEvent` — a
   short-lived main-isolate socket, the only path that reaches relays.

The old path routed the like through the wapp → the engine's `hub.publish`, whose
sockets are frozen, so **it silently never published**. If likes stop working, check
that `_likePost` is still wired and still uses the poller, not the engine.

`RnsService.buildSignedReaction(eventId, authorHex)` builds+signs the kind-7 on the
main isolate (it has the key via `_profilePrivHex`). Signing is fine on any isolate;
only the socket send must be on main.

---

## 6. Profiles — names, not hex keys

The feed resolves an author's display name via `_feedProfileFor(short12)`, which
looks in **`_wappProfiles`** (a host-side `Map<short12, {name, pic}>`) **before**
falling back to the engine's profile store. The engine's store is stale (frozen
sockets), so the main-side cache is what makes names appear.

`NostrAllPoller` fetches `kind-0` for the curated authors and feeds them to
`_wappProfiles` via the `onProfiles` callback (keyed by the **12-char prefix** — that
is the key the card resolves by). If you see raw hex keys instead of names, the
profile fetch or the cache write is the thing to check, not the card.

---

## 7. The "(updated)" label

The All feed is engagement-ranked, so an old post can sit at the **top** because it
just gathered a like/reply — which reads as a stale "most recent". To explain that,
`NostrAllPoller` reports each curated post's **newest engagement time**
(`onActivity`), stored in `_postActivityMs`. `_socialActivityPosts` sets
`post['updated'] = true` when the latest like/reply landed well after the post was
created, and the card renders `<name> 1h (updated)`. It is a *why-is-this-here*
signal, not a claim of freshness.

---

## 8. The archive (`ActivityArchive`)

- `social_all.sqlite3` (All) and `social_following.sqlite3` (Following). SQLCipher —
  keyed by the profile key; a **locked profile** means writes/reads fail (watch for
  `ProfileLockedException` at cold start).
- `recent(limit)` returns rows **ORDER BY t DESC then reversed** → oldest→newest.
  The feed shows newest at top; `_socialActivityPosts` re-orders by curation score.
- Dedup is by **event id (`mid`)** — re-fetching the same post is a no-op. This is
  what lets multiple writers coexist without doubles.
- `replyCount(mid)` = rows with `parent = mid`. Replies are stored (parent set) so
  the count is real, but the **All list shows roots only** (`parent` empty) — a reply
  to some off-screen post has no context there.
- Likes live in `activity_likes` (`setReaction`/`likeInfo`), deduped by
  `(mid, liker)`.

---

## 9. Lessons / things to watch — READ THIS BEFORE CHANGING THE FEED

1. **One implementation of "show publications."** The user explicitly does not want
   duplicated feed logic. The All feed = `NostrAllPoller` → `_activityArchive` →
   `_socialActivityPosts` → `ActivityFeed`. Likes = `_likePost`. Do not add a second
   drain, a second publish path, or a second ranking. If you find yourself adding a
   parallel writer, stop.

2. **Never route feed fetches or reaction publishes through the engine isolate.** It
   freezes on socket reopen (§3). Main isolate, poll-and-close, always.

3. **A fresh firehose can never show likes.** Seconds-old posts have none. If you are
   asked to "show more likes", the answer is *better curation* (sample more
   reactions, widen the window, add relays), not fetching fresher posts.

4. **Engagement is low on the public relays.** The default relays yield single-digit
   to a few-dozen likes on popular posts, not thousands. That is real, not a bug.
   Higher numbers need more/bigger relays in the user's relay list.

5. **Validate on the device, with screenshots.** Per [validation.md](validation.md):
   the feed has failed in ways invisible to unit tests and analyzers (frozen isolate,
   stale cache, wrong render order, likes that sign but never publish). Nothing is
   done until a finger-tap on C61 and a screenshot prove it. The on-device log helps:
   `adb forward tcp:PORT tcp:3456` → `curl /api/log?n=5000`, filter the RNS
   `path request` spam with `grep -ivE "path request"`. Poller lines are `all-poll:`.

6. **The build/versionCode race.** A second Claude/agent session often shares this
   working tree and the phone. Symptoms: your installed versionCode is overwritten
   within seconds; the build fails on symbols you never wrote (their mid-save).
   Because the tree is shared, committing your fix means every build (theirs or
   yours) carries it — so *commit* rather than fight the race, and if the build fails
   on a foreign symbol, wait for the other session to finish rather than editing
   their code.

7. **Prefer the wapp layer, but the All-feed engine had to be host code.** Per
   [reusable.md](reusable.md) new work belongs in the wapp. The All feed is the
   exception: it needs main-isolate sockets and the profile/like/ranking plumbing,
   which cannot live in WASM. Everything the wapp C *can* still own (Following,
   thread, search, compose) stays in `main.c`.

8. **Poll-and-close means brief sockets.** Do not extend socket lifetime to "make it
   more reliable" — that reintroduces the exact long-lived-client behaviour the
   relays punish. Open, take what is needed, disconnect.

9. **Timestamps and ordering are subtle.** `t` is stored in **ms**; NOSTR
   `created_at` is **seconds** (multiply). `recent()` is oldest→newest and the feed
   card reverses for display; the curation re-sort must respect "best last → top".

10. **Memory and the main thread will OOM/ANR a budget phone if you are careless.**
    Three traps, all hit and fixed:
    - **Never decode avatars/banners at source resolution.** A profile picture is
      often 1000px+; 100+ cached profiles + a full-res profile banner blew GPU
      texture memory to ~94MB and OOM'd. Use `avatar_image.dart`
      (`avatarImage`/`bannerImage`, `ResizeImage`); post images use `cacheHeight`.
      The global `imageCache` is capped in `main.dart`.
    - **Batch archive writes.** The archive is SQLCipher (encrypted) — hundreds of
      individual `add`/`setReaction` INSERTs blocked the UI thread for seconds
      (ANR). The poller wraps its whole persist in `ActivityArchive.transact()`.
    - **Do not do sqlite in `build()`.** `_socialActivityPosts` reads like/reply
      counts to rank; unmemoised it ran ~800 queries per build (every scroll frame).
      It is memoised on the archive revision. And remember the **poll decodes every
      collected event's JSON on the main isolate** (sockets can't be on the engine)
      — keep the reaction/fresh sample sizes modest or it janks the UI.
    - **Poll-and-close has a socket-leak trap.** The poll fires `connect()`
      unawaited then `close()`s a few seconds later. If a slow relay's handshake
      completes AFTER close(), `connect()` will resurrect the socket (stream
      listener + idle timer) on a "closed" client — leaked once per slow relay per
      poll, native heap climbs to OOM. `NostrWsClient.connect()` guards this with a
      `_closed`/status check right after `await ch.ready`. Any new poll-and-close
      code must do the same.

---

## 11. Nomadnet — NOSTR over Reticulum

The Nomadnet tab is a feed of NOSTR publications carried over the **Reticulum
mesh**, not the internet. Unlike Internet (wss, frozen engine → main-isolate
poller), Reticulum NOSTR is already isolate-safe and lives on the MAIN isolate.

- **Transport**: `RnsService._relay` (`RelayNode.query` over an RNS Link),
  `RnsService._relayDir` (reachable relays/indexers via announces), and
  `RnsService._relayStore` (the local NOSTR relay store). `nomadnetFetch` uses the
  shared `_fanOutQuery` (also used by `fetchFeedBackfill`): local store + best
  indexer + all reachable relays + callsign peers, parallel, deduped.
- **Poller**: `nomadnet_poller.dart` (`NomadnetPoller`) — main isolate, NO
  sockets. Verifies signatures in a `compute` isolate, writes newest-first into
  `social_nomadnet.sqlite3`, fetches kind-0 profiles. Starts/stops ONLY while the
  Nomadnet tab is viewed (`onFilterChanged`), with a `_disposed` guard so an
  in-flight poll can't write after teardown. The archive is **cleared on open**
  so it is always a live view of what the mesh currently holds.
- **Publishing**: `nostrPost` now also `relayPublish()`es our note (local store
  self-tier + replicate to indexers), done FIRST and independent of the engine
  publish — else the post lives only in the internet store, invisible to the mesh.
- **No internet contamination**: the local `_relayStore` ALSO holds internet
  posts. So Nomadnet scopes the **local** query to OUR authored posts only
  (`localAuthors: [self]`); remote peers are already self-scoped by the relay
  responder (`relay_node.dart` leaf branch — a leaf answers only its own posts).
  Net: Nomadnet shows only reticulum-native posts (self + peers' own).

**Validation is CROSS-DEVICE, over Reticulum only.** In this initial
implementation only the phones publish NOSTR over Reticulum, so the ONLY valid
proof is: publish a unique status on device A's Social, and it appears on device
B's Nomadnet — with the two devices on **different internet networks**, fetched
purely over Reticulum (the marker exists on no public relay). RNS link queries
between NAT'd phones are slow to warm up (~one poll cycle; a link that times out
on the first poll answers on the next), so allow a cycle or use pull-to-refresh.

## 10. History

This design replaced an engine-isolate firehose that froze after ~1–2 hours every
time the relay sockets were cut. The full forensic story (three compounding root
causes, the on-device debug workflow, the final main-isolate poll-and-close design,
and the curation/likes/profiles work) is in the project memory
`nostr-engine-isolate-socket-freeze` and across commits `d70c7e4`, `c184d2b`,
`45d0c91`, `d53708d`, `419dc34`, `b04c8de`.
