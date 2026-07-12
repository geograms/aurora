# NOSTR client — transport-abstract relays

Aurora ships a normal NOSTR client (the **NOSTR** wapp) that reads kind-1 notes
from the accounts you follow and posts your own. What makes it different from a
stock client: a **relay is not tied to the internet**. Each relay's URI scheme
picks the transport, and the wapp never knows which one a relay uses.

| URI scheme            | transport                              | implementation |
|-----------------------|----------------------------------------|----------------|
| `wss://` / `ws://`    | public internet WebSocket              | `NostrWsClient` (`web_socket_channel`, native + web) |
| `rns://<idhash>`      | a relay on the Reticulum mesh          | `NostrRnsClient` → the existing `RelayNode` over an RNS link |
| `local`               | **this device**                        | `NostrLocalClient` → the local `RelayEventStore` |

All of these are just NIP-01 (`REQ`/`EVENT`/`EOSE`/`OK`) — the packets are
identical standard NOSTR; only the pipe differs. Every inbound event from every
transport is verified and merged into the ONE local event store, so the feed
reads a single unified cache. Adding a transport later = one new client class,
zero changes to the wapp or the store.

Code: `reticulum-dart/lib/src/services/social/nostr_*.dart`
(`nostr_wire.dart` codec, `nostr_relay_client.dart` interface,
`nostr_ws_client.dart`, `nostr_rns_client.dart`, `nostr_local_client.dart`,
`nostr_relay_hub.dart`, `nostr_ws_server.dart`). Reuses the pre-existing
`NostrEvent`/`NostrCrypto` (BIP-340), `NostrFilter`, `RelayEventStore`,
`FollowSet`, and `RelayNode`. Host wiring + HAL in
`aurora/lib/services/reticulum/rns_service.dart` (`nostr*` facade) and
`aurora/lib/wapp/{functionality_registry,wapp_engine}.dart` (`hal.nostr`).

## The device is itself a relay + Blossom server

- **Reticulum relay**: `RelayNode` already answers NOSTR queries over RNS links,
  so other Aurora devices reach this device as an `rns://<idhash>` relay.
- **wss:// relay**: `NostrWsServer` (an `HttpServer` that upgrades WebSockets,
  serving/ingesting the local store, + a NIP-11 document) lets ANY stock NOSTR
  app on the LAN use this device as a `wss://` relay. Events arriving over the
  mesh or internet are live-pushed to its subscribers.
- **Blossom**: `blossom_server.dart` hosts content-addressed blobs for media
  referenced by notes.

So `local` in the relay list is not a toy — it is a real, servable relay.

## The wapp

`wapps/nostr/` — a thin C module over `hal.nostr`:
- **Feed** tab (`$type:"chat"`): subscribes to `{kinds:[1], authors:<follows>}`,
  drains events (`hal_nostr_event_recv`) into the feed, composes posts
  (`hal_nostr_post(1, …)` — the host signs with the profile key; the nsec never
  enters the wasm sandbox).
- **NOSTR servers** menu panel (`$type:"people"`): relay list with per-relay
  status (reachable / connecting / error), an input + **Add relay** button, and
  tap-a-row-to-remove. Pre-populated with common public relays + `local`.

## Three feeds, and why they are different

The distinction matters, because conflating two of them is what made the "All"
tab show hour-old posts:

| Feed | What it is | Freshness |
|---|---|---|
| **Firehose** (`hal_nostr_firehose`) | A live `{kinds:[0,1]}` subscription. The relays PUSH; the host's quality gate filters. **This is the All tab** — the feed of strangers, for finding people to follow. | Sub-second |
| **Popular** (`hal_nostr_discovery`) | Watches the kind-7 REACTION firehose, tallies distinct likers, and fetches a post by id once it crosses the threshold. | **Always behind** — a post cannot appear until it has *collected* likes |
| **Follows** (`hal_nostr_subscribe` + WoT) | `{kinds:[1], authors:<follows>}`. Everything the people you follow do. | Sub-second |

"Popular" is a ranking signal (the launcher hero's cold start uses it). It can
never be a live feed, by construction. It used to be the All tab.

## The quality gate (`feed_quality.dart`)

A firehose of strangers is only usable if the obvious junk never reaches the
screen — but the bias is deliberate: **a false positive is worse than a miss.**
Hiding a real person's post is invisible to the user and unfixable by them;
letting one advert through costs a moment's annoyance.

Dropped: empty posts, hashtag walls, link-only adverts, emoji/symbol soup, the
same text from a *different* author within 10 minutes (copy-paste rings), authors
posting more than 4×/minute, muted authors, and — in strict mode — authors with
no kind-0 profile at all. Kept: short replies, non-Latin scripts, emoji, ALL
CAPS, and links that come with a sentence. **Your own posts and everyone you
follow bypass the gate entirely.**

A post whose author has no profile *yet* is **held**, not dropped (3-minute TTL,
bounded buffer), and released the moment their kind-0 lands. Two traps here, both
of which we fell into and fixed:

- The profile has to be **asked for**. A live `{kinds:[0,1]}` subscription brings
  whichever kind-0s happen to be published right now — almost never the authors
  currently posting. Held authors are batched into one small `{kinds:[0]}` REQ on
  a 10-second timer.
- That batch must be **slow and bounded**. `trackProfile` re-issues a 500-author
  REQ on every call; driven by a firehose (a new stranger every second) it became
  a REQ storm, the relays dropped our subscriptions — *including the firehose* —
  and the feed strangled itself while waiting for profiles nobody had asked for.

Every drop is counted by reason: `perf: nostr firehose seen=… kept=… pending=…
expired=… flooding=… linkOnly=…`. A filter nobody can see is a filter nobody can
trust; "the feed looks empty" must be answerable from `/api/log`.

There is also a **watchdog**: relays cap how many subscriptions one connection
may hold and silently drop the excess (we hold many — profiles, stats, reactions,
WoT, search). Sixty seconds of silence on the firehose re-opens its REQ. There is
no error to catch; silence is the only signal.

## HAL surface (`hal.nostr`)

`hal_nostr_relays` / `relay_add` / `relay_remove` (manage the list, see status),
`hal_nostr_subscribe(filter)→subId` / `event_recv(subId)` / `unsubscribe`
(inbox-pop streaming, like `hal_relay_*`), `hal_nostr_firehose` (live, gated),
`hal_nostr_discovery` (popular), `hal_nostr_post(kind,content,tags)`
(sign-as-profile + publish), `hal_nostr_follows` / `follow` / `unfollow`.

## Compatibility

Fully NIP-01/09/11/50 compatible — a post made here is fetched by any NOSTR
client via a shared relay, and vice-versa. The relay list add/remove, the wire
codec, and the hub routing/merge are unit-tested
(`reticulum-dart/test/nostr_wire_test.dart`, `nostr_relay_hub_test.dart`).

## Verify

- Unit: `flutter test test/nostr_wire_test.dart test/nostr_relay_hub_test.dart`
  in reticulum-dart (11 tests).
- Live: open the NOSTR wapp → top-right menu → **NOSTR servers** → rows show the
  default relays turning "connected"; follow a known npub → its notes appear in
  the Feed; post a note → it shows in the feed and is fetchable from
  relay.damus.io by a stock client. Point a relay at another Aurora device's
  `rns://<idhash>` (or `wss://<lan-ip>:4848`) to exercise the mesh / local-server
  transports.
