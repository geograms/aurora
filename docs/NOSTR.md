# NOSTR: every user a relay

> Companion docs: [nostr-client.md](nostr-client.md) (the client, the relay hub
> and the transports as they exist today), [dht.md in reticulum-dart](../../reticulum-dart/doc/dht.md)
> (the who-has layer), [folders.md](folders.md), [mesh.md](mesh.md).
> This file is the **vision and the architecture**; it marks clearly what is
> built, what is half-built, and what is not built at all.

## Why

NOSTR today is a handful of big relays that everybody connects to. They give no
guarantee your notes will still be there in ten years, and where a relay *does*
promise longevity it is usually because somebody with an agenda is paying for
the disk. A protocol designed to be censorship-resistant ends up with a dozen
load-bearing servers.

The next step is the obvious one: **each user is a relay.** Each participant
hosts what it publishes, plus whatever it decided is worth keeping from other
people. If you care about an author, you keep their notes and their media on
your own devices — that is what keeps them alive. Nobody else is obliged to,
and nobody else can be leaned on to stop.

That is not a slogan, it is a storage model with consequences:

- **Your data survives because *you* carry it.** The copy in your pocket is the
  authoritative one, readable offline, on the bus, in a blackout.
- **An author survives because their readers carry them.** Popularity becomes
  literal replication. An author nobody keeps, fades — as it should.
- **No relay is load-bearing.** Any of them can be taken offline, seized, or
  quietly co-opted, and nothing is lost, because none of them was the only copy.

Aurora runs NOSTR over two networks at once: the plain internet (`wss://`
relays, Blossom servers) **and** Reticulum (the mesh: LAN, BLE, LoRa, RNS hubs,
public TCP hubs). Same account, same events, same signatures. You keep
interacting with the internet NOSTR world you already use, and the same posts
land on Reticulum relays — including your own device. When the major relays of
today are gone, nothing about your account or your archive changes.

## The scaling problem, and the answer

If a thousand users each host their own relay, the naive design is a thousand
devices asking a thousand devices "anything new?". Phones would cook their
batteries doing nothing but answering. Fan-out is what killed every previous
attempt at this.

The answer is **self-nominated indexers**.

An indexer is an ordinary device that has volunteered: plugged into power, on a
home WiFi with a real uplink. An old Android phone in a drawer is perfectly
good hardware for it. Its job is to answer one question:

> "Where can I find notes from `npub…`?"

It receives, from many users, statements of *what they are willing to share*,
and it answers *which devices have what you are asking for*. It is a phone book,
not a library.

**An indexer is not a disk drive.** It gives out locations, not content. Users
remain responsible for keeping their own data alive; an indexer that vanishes
costs the network a directory, not an archive. That is what stops the whole
thing sliding back into "a few big servers with everything on them", which is
exactly the world we are trying to leave.

Indexers **self-nominate** — anybody can volunteer their hardware — and they
**sync with each other**, because indexer-to-indexer traffic is fast and spares
the small battery-powered devices. When an indexer goes offline you pick another
one that is still alive with good uptime and ask there. There is no election, no
registry, and nothing to seize.

Indexers also carry **retention rules** (what is worth keeping a pointer to,
what is spam) — the anti-abuse half of the design, sketched at the end of this
doc.

## What is actually built today

Verified against the code, July 2026. Paths are `reticulum-dart/lib/src/…`
unless stated.

### Roles and the directory — BUILT

`services/social/relay_role.dart`:

- `enum RelayRole { leaf, indexer }`.
- `RelayCap` bit-flags: `search`, `firehose`, `storeForward`, `archive`, `probe`.
- **Role is derived from hardware, not from a setting**:
  `RelayAnnouncement.forCapacity()` — a device that is not `unlimited`
  (charger + WiFi/Ethernet) is a **leaf** and advertises only `probe`. A device
  that is unlimited becomes an **indexer** (`search | firehose | storeForward |
  probe`), and one on the top capacity tier (pinned archive / home fibre) also
  goes `wide` + `archive`. That *is* self-nomination: plug the old phone in, it
  volunteers; unplug it, it stops. `CapacityGovernor` re-derives it live.
- `InterestSet` — the topics and author pubkeys a node aggregates. The network
  shards **by interest**, not by hash range. `wide` = holds everything it sees.
- `RelayAnnouncement` is the advert itself: `{role, capacity, caps, wide,
  topics[], authorPrefixes[], pubkey, uptimeSeconds}`, msgpack, carried in the
  **app_data of the `geogram/relay` RNS announce** (≤ ~350 B, so it fits one
  announce). Authors are advertised as **4-byte prefixes** — enough to shard,
  not enough to be a mailing list.
- `RelayDirectory` — every relay announce heard is observed with its hop count
  (TTL 1 h). `indexers()`, `identityForPubkey(npub) → RnsIdentity`, and
  **`bestIndexer({topic, author})`**, scored: explicit interest match +1000,
  wide/archive +400, capacity `(9-cap)*20`, `−hops*10`, freshness as tiebreak.

So "find another indexer with good uptime and ask there" already works: uptime
is announced, the directory is live, and selection is one call.

### Asking a peer without waking it — BUILT

`RelayNode.answerProbe` (`services/social/relay_node.dart`) is a
**connectionless NOSTR probe**: a query rides a datagram, and a peer that holds
nothing **answers with silence** — no link, no Curve25519 handshake, no radio
burn. If the answer fits a datagram it comes back inline; if not, the peer says
`HAVE n` and the querier opens a link. This is the mechanism that makes "a
thousand relays" survivable for phones; it is advertised as `RelayCap.probe` so
old nodes keep getting links exactly as before.

### The who-has layer — BUILT (for files and folders)

`services/files/dht/` — a Kademlia DHT over RNS links. The important property,
and the one that makes it the right substrate for indexers:

> **Holders store pointers only.** The only value in the DHT is a signed
> `ProviderRecord` = *"pubkey X provides sha256 Y, capacity class C, expires
> in 45 min"* (~176 B, Ed25519-signed by the provider, so a relaying node
> cannot forge one). No content, ever.

- Key = first 16 bytes of the sha256 (`dhtFileKey`), or an arbitrary 32-byte key
  — **folders publish under their NOSTR public key** (`FileTransferNode.publishKey`
  / `resolveProviders`). Publishing under an *author's npub* is therefore already
  possible with the code as it stands.
- `DhtNode`: `k`, `alpha`, iterative FIND_NODE/FIND_VALUE, `store` with
  anti-abuse caps (`maxStoredKeys`, `maxRecordsPerKey`, `storesRejected`), dead
  holder pruning (`demoteProvider` after a failed fetch), lazy TTL expiry,
  liveness eviction after 5 failed RPCs.
- **Persistence anchors**: `DhtNode(anchors:)` is a set of always-on nodes that
  every STORE also goes to and every resolve asks *first*, regardless of XOR
  distance. Aurora feeds it **the relay indexers**
  (`rns_service.dart` `stableAnchors:` = `_relayDir.indexers()` filtered to the
  good capacity classes, capped to 6). That join — *indexers are the DHT's
  anchors* — is the load-bearing piece of the whole design, and it is live.
- Records are republished every 30 min against a 45-min TTL, so a provider that
  goes away disappears from the directory by itself.

### Store-and-forward — BUILT

`services/social/store_forward.dart`: a message for an offline recipient is
deposited at an indexer advertising `RelayCap.storeForward` (found via the
directory), and flushed to the recipient when their LXMF destination announces.
30-day TTL. This is the indexer earning its keep for messaging, not just feeds.

### The device as a relay — BUILT

- **Over Reticulum**: `RelayNode` answers `REQ` / `COUNT` / `EVENT` /
  `DEPOSIT` / `DROP` over RNS links (`relay_protocol.dart`), backed by
  `RelayEventStore` (SQLite + FTS5, NIP-50 search). A **leaf still answers
  queries about its own posts** — "ask the author directly" is a real path.
- **Over the LAN**: `NostrWsServer` — any stock NOSTR client on the LAN can use
  this device as a `wss://` relay, NIP-11 and all.
- **Media**: `blossom_server.dart` serves content-addressed blobs over HTTP, and
  the same blobs are fetchable over Reticulum by sha256 through
  `FileTransferNode` + `MediaFileSource`, with a Blossom-style **deposit**
  opcode (`file_transfer.dart`, BIP-340-authorised) for asking a host to keep a
  blob. Blossom-over-Reticulum as an HTTP-compatible service does **not** exist;
  the RNS path is the files layer.

### Retention: what a node keeps — BUILT

`retention_tier.dart` + `host_retention_policy.dart`: every event is tiered
**self (0) / followed (1) / stranger (2)**. Strangers get a byte slice, a
notes-per-month cap and a retention window; eviction only ever deletes tier 2,
never kinds 0/3. Anything that is *about you* — a reply, a repost, a reaction
carrying your `p` tag — is stored at tier 0 the moment it arrives, which is why
your notifications and the notes they point at are readable with the radio off.

**This is the "you keep what matters to you" model, implemented.** Following an
author is already a storage decision, not just a display decision.

### Two networks, one store — BUILT

The client (`nostr_relay_hub.dart`) is transport-abstract: a relay is a URI.
`wss://` → the internet, `local` → this device's own store, `rns://<idhash>` →
a relay on the mesh. Every event from every transport is signature-verified and
merged into **one** store, so the feed is a single unified cache and a post you
make goes out over both. The user-facing panel is **NOSTR on Internet** (relays
+ Blossom servers, add / remove / enable-disable).

## What is NOT built (do not assume it)

Honest list, because a doc that overstates is worse than no doc:

1. **Indexers do not yet answer "where", they answer "what".** Today an indexer
   *is* a relay host: it stores stranger events in its own `RelayEventStore`
   (under quota) and serves them back. The pointer-only model — an indexer that
   holds a `who-has` map and no content — is the target, and the DHT already
   implements exactly that primitive; the two layers are joined only as
   *anchors* so far, not as *the* answer to "where can I find `npub…`".
2. **No author→provider records.** Nothing publishes *"I hold notes from
   npub XYZ"* into the DHT. The mechanism exists (`publishKey(key32)` takes an
   arbitrary 32-byte key, and an npub is exactly 32 bytes); it is not called for
   authors.
3. **Indexers do not sync with each other.** Each one observes announces and
   serves what it happens to hold. There is no indexer↔indexer replication
   channel.
4. **`rns://` relay URIs are inert in the shipped app.** The relay hub runs on a
   background isolate that is constructed with `rnsClientFactory: null`
   (`nostr_engine.dart`), so an `rns://…` entry in the relay list resolves to a
   null client. All real Reticulum relay traffic goes through `RelayNode` on the
   main isolate instead. The `NostrRnsClient` class is complete and unused.
5. **No long-lived subscriptions over RNS.** A `REQ` returns one `RESULT` and
   ends; mesh "subscriptions" poll. (Correct for a mesh — just don't expect
   push.)
6. **No spam cost on DHT stores.** Only count caps. `coin/postage_gate.dart`
   exists and is not wired in.
7. **No Blossom over Reticulum** (HTTP only), and BUD-02 upload auth is not
   verified — uploads are gated by a toggle.

## The road

In dependency order. Each step is small and independently useful.

1. **Publish author-provider records.** When a device decides to keep an author
   (follow ⇒ tier 1 ⇒ it already stores their notes), publish a `ProviderRecord`
   under `key = the author's 32-byte pubkey`, exactly as folders already do. Now
   "who has notes from `npub…`" is a DHT resolve, and the answer is a list of
   devices — not a server.
2. **Resolve-then-ask in the client.** A feed fetch for an author it cannot see
   goes: local store → DHT resolve (anchored at indexers) → probe the returned
   providers connectionlessly → link only to one that says `HAVE`. Silence costs
   nothing; this is what keeps a thousand-relay network from melting phones.
3. **Make the indexer pointer-only.** An indexer answers `where`, and stores the
   provider map, not the notes. It may keep a small hot cache of recent events
   for its advertised interests (that is what `RelayCap.firehose` means), but its
   promise to the network is the directory, not the archive. Users are told this
   plainly: *an indexer is not your backup.*
4. **Indexer↔indexer sync.** Anchored gossip of provider records between nodes
   advertising `RelayCap.search`, so asking any live indexer gives the same
   answer, and a dead one costs nothing. Uptime is already announced; prefer the
   long-lived ones.
5. **Retention rules on the indexer.** What is worth a pointer: a record signed
   by a provider that is actually reachable, an author somebody follows, a topic
   in the interest set. What is not: unsolicited floods (the store caps), records
   whose provider never answers a fetch (`demoteProvider` already prunes those),
   and eventually a postage/PoW cost per store for the abusive tail.
6. **Media follows the same rule.** Following an author keeps their blobs too —
   Blossom is part of the package. Your phone carries the photos and the videos
   of the people you care about, fetchable over the internet by sha256 *or* over
   Reticulum from another device that also kept them.
7. **Merge the two worlds properly.** Wire `rnsClientFactory` so `rns://` relays
   are first-class in the same relay list as `wss://` ones (item 4 above), and a
   single post fans out to internet relays, mesh indexers, and the copy on your
   own disk, in one operation, with one signature. That is the end state: you use
   NOSTR exactly as you do today, and it keeps working after the relays you use
   today are gone.

## The one-sentence version

Users keep what they value, indexers remember where it is, and the two networks
— internet and Reticulum — carry the same signed events, so no relay is ever
load-bearing again.
