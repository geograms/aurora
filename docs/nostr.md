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

## HAL surface (`hal.nostr`)

`hal_nostr_relays` / `relay_add` / `relay_remove` (manage the list, see status),
`hal_nostr_subscribe(filter)→subId` / `event_recv(subId)` / `unsubscribe`
(inbox-pop streaming, like `hal_relay_*`), `hal_nostr_post(kind,content,tags)`
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
