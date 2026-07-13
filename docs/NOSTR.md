# NOSTR on geogram: every user a relay

> Companion docs: [nostr-client.md](nostr-client.md) (the client, the relay hub
> and the transports as they exist today), [dht.md in reticulum-dart](../../reticulum-dart/doc/dht.md)
> (the who-has layer), [folders.md](folders.md), [mesh.md](mesh.md).
> This file is the **vision and the architecture**; it marks clearly what is
> built, what is half-built, and what is not built at all.
>
> *geogram* is the platform. "Aurora" is only the codename of one edition of it;
> where code paths below say `aurora/`, read "the app repo".

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

geogram runs NOSTR over two networks at once: the plain internet (`wss://`
relays, Blossom servers) **and** Reticulum (the mesh: LAN, BLE, LoRa, RNS hubs,
public TCP hubs). Same account, same events, same signatures. You keep
interacting with the internet NOSTR world you already use, and the same posts
land on Reticulum relays — including your own device. When the major relays of
today are gone, nothing about your account or your archive changes.

## The ecosystem: three roles

Everything below hangs off one separation, and it is the whole design:

> **Finding data, hosting data, and owning data are three different jobs, done
> by three different kinds of device, and no device is forced into more than
> the one it volunteered for.**

| Role | Answers | Stores | Typical hardware | Volunteered via |
|---|---|---|---|---|
| **Publisher** (leaf) | "here are *my* notes" | its own posts + the authors it follows (notes **and** media) | phone, laptop — anything | nothing to volunteer; this is every user |
| **Indexer** | "*where* can I find notes from `npub…`" | **pointers only** — a who-has map. Never other people's content | old Android on a charger, home WiFi | the **Indexer wapp** |
| **Archiver** | "I *hold* a copy of that" | other people's content, up to a quota the owner sets | NAS, home server, a phone with a big card, a LoRa/BLE gateway box | the **Archiver wapp** |

A single device can be all three. Most are only a Publisher, and that is fine —
a network of pure Publishers already works, it just gets slow to search and
loses anything nobody happened to follow.

### Publisher — the floor

Every geogram device is a relay for itself. It answers queries about its own
posts, it keeps the authors it follows (that is what *follow* means here: a
storage decision, not a display filter), and it carries their media. It is
battery-powered and mostly asleep, so the network must never make it the first
thing anyone asks.

### Indexer — the phone book

If a thousand users each host their own relay, the naive design is a thousand
devices asking a thousand devices "anything new?". Phones would cook their
batteries doing nothing but answering. Fan-out is what killed every previous
attempt at this.

An **Indexer** is an ordinary device that volunteered: plugged into power, on a
home WiFi with a real uplink. An old Android in a drawer is perfectly good
hardware. It receives, from many users, statements of *what they are willing to
share*, and it answers one question:

> "Where can I find notes from `npub…`?"

**An Indexer is not a disk drive.** It gives out locations, not content. An
Indexer that vanishes costs the network a directory, not an archive — which is
exactly what stops the whole thing sliding back into "a few big servers that
have everything", the world we are leaving.

Indexers **self-nominate**, and they **sync with each other**, because
indexer-to-indexer traffic is fast and spares the small battery-powered devices.
When one goes offline you pick another that is still alive with good uptime and
ask there. No election, no registry, nothing to seize.

### Archiver — the redundancy

Pointers are worthless if every copy they point at is asleep or gone. Somebody
has to be willing to hold **other people's** bytes. That is a separate,
explicit, quota-bound offer — never an accident of having volunteered to index.

An **Archiver**:

- **Takes a quota from its owner** ("30 GB, no more") and never exceeds it.
- **Chooses what it takes**: authors it follows, topics it cares about, or
  *whatever comes over a direct link* (see below). Eviction is oldest-and-least-
  wanted first, and never touches the owner's own data.
- **Pulls from small devices.** A phone that holds the only copy of a
  neighbourhood's photos is one drop away from losing them. An Archiver mirrors
  what those devices offer to share, then **publishes itself as a provider** —
  so the DHT starts pointing at the Archiver instead of waking the phone. The
  phone's battery, and the data, both survive.
- **Store-and-forwards on direct connections.** LAN, Bluetooth and LoRa peers
  come and go and have no route to anywhere. An Archiver on those links accepts
  what they hand it, holds it, and passes it on when the other side appears — the
  bridge between an off-grid pocket of the mesh and the rest of the world. The
  machinery for this exists (`RelayCap.storeForward`, `store_forward.dart`,
  30-day TTL); the Archiver is what makes it a *role a user chooses* instead of
  a side effect of being plugged in.

An Archiver is not a backup service and makes no promise to any individual. It
is redundancy: with a handful of them around an author, that author survives the
loss of any one machine, including their own.

### How the three fit together

```
   Publisher (phone)                      Publisher (laptop)
     keeps: own posts                       keeps: own posts
            + followed authors                     + followed authors
        │  publishes ProviderRecord              │
        │  "I hold npub X"                       │
        ▼                                        ▼
   ┌──────────────────── DHT (pointer-only) ────────────────────┐
   │  key = author npub / file sha256 → [signed provider recs]  │
   └────────▲───────────────────────────────────────▲───────────┘
            │ anchored at                           │
      ┌─────┴──────┐                          ┌─────┴──────┐
      │  INDEXER   │◄──── sync ──────────────►│  INDEXER   │
      │ who-has map│  (fast, wired, spares    │ who-has map│
      │ no content │   the phones)            │ no content │
      └─────┬──────┘                          └────────────┘
            │ "npub X lives on: phone, laptop, archiver-7"
            ▼
      ┌────────────┐   mirrors small devices, publishes itself as a
      │  ARCHIVER  │   provider, so the DHT points HERE not at a phone
      │  quota-set │   ─ and store-and-forwards for LAN/BLE/LoRa peers
      └────────────┘
```

A read goes: **local store → DHT resolve (asking an Indexer first) →
connectionless probe of the returned providers → link only to one that answers
`HAVE`.** Silence costs nothing, so a sleeping phone is never charged for a query
it cannot answer. Archivers, being awake and fat, get picked over phones for the
same content — that is the point of publishing a capacity class in the record.

## What is actually built today

Verified against the code, July 2026. Paths are `reticulum-dart/lib/src/…`
unless stated.

### Roles and the directory — BUILT (Indexer only)

`services/social/relay_role.dart`:

- `enum RelayRole { leaf, indexer }` — **there is no Archiver role yet**; see the
  road below.
- `RelayCap` bit-flags: `search`, `firehose`, `storeForward`, `archive`, `probe`.
- **Role is derived from hardware, not from a setting**:
  `RelayAnnouncement.forCapacity()` — a device that is not `unlimited`
  (charger + WiFi/Ethernet) is a **leaf** advertising only `probe`. An unlimited
  device becomes an **indexer** (`search | firehose | storeForward | probe`), and
  one on the top capacity tier (pinned archive / home fibre) also goes `wide` +
  `archive`. `CapacityGovernor` re-derives it live.
- `InterestSet` — the topics and author pubkeys a node aggregates. The network
  shards **by interest**, not by hash range. `wide` = holds everything it sees.
- `RelayAnnouncement` is the advert itself: `{role, capacity, caps, wide,
  topics[], authorPrefixes[], pubkey, uptimeSeconds}`, msgpack, carried in the
  **app_data of the `geogram/relay` RNS announce** (≤ ~350 B, one announce).
  Authors are advertised as **4-byte prefixes** — enough to shard, not enough to
  be a mailing list.
- `RelayDirectory` — every relay announce heard is observed with its hop count
  (TTL 1 h). `indexers()`, `identityForPubkey(npub) → RnsIdentity`, and
  **`bestIndexer({topic, author})`**, scored: explicit interest match +1000,
  wide/archive +400, capacity `(9-cap)*20`, `−hops*10`, freshness as tiebreak.

So "find another indexer with good uptime and ask there" already works: uptime
is announced, the directory is live, selection is one call.

### Asking a peer without waking it — BUILT

`RelayNode.answerProbe` (`services/social/relay_node.dart`) is a
**connectionless NOSTR probe**: the query rides a datagram, and a peer holding
nothing **answers with silence** — no link, no Curve25519 handshake, no radio
burn. If the answer fits a datagram it comes back inline; if not the peer says
`HAVE n` and the querier opens a link. Advertised as `RelayCap.probe`, so older
nodes keep getting links exactly as before.

### The who-has layer — BUILT (for files and folders)

`services/files/dht/` — Kademlia over RNS links. The property that makes it the
right substrate for Indexers:

> **Holders store pointers only.** The only value in the DHT is a signed
> `ProviderRecord` = *"pubkey X provides sha256 Y, capacity class C, expires in
> 45 min"* (~176 B, Ed25519-signed by the provider, so a relaying node cannot
> forge one). No content, ever.

- Key = first 16 bytes of a sha256 (`dhtFileKey`), or an arbitrary 32-byte key —
  **folders already publish under their NOSTR public key**
  (`FileTransferNode.publishKey` / `resolveProviders`). Publishing under an
  *author's* npub is therefore possible with the code as it stands.
- `DhtNode`: `k`, `alpha`, iterative FIND_NODE/FIND_VALUE, STORE with anti-abuse
  caps (`maxStoredKeys`, `maxRecordsPerKey`, `storesRejected`), dead-holder
  pruning (`demoteProvider` after a failed fetch), lazy TTL expiry, liveness
  eviction after 5 failed RPCs.
- **Persistence anchors**: `DhtNode(anchors:)` is a set of always-on nodes that
  every STORE also goes to and every resolve asks *first*, regardless of XOR
  distance. The app feeds it **the relay indexers** (`rns_service.dart`
  `stableAnchors:` = `_relayDir.indexers()` filtered to the good capacity
  classes, capped to 6). That join — *Indexers are the DHT's anchors* — is the
  load-bearing piece of the whole design, and it is live.
- Records republish every 30 min against a 45-min TTL, so a provider that goes
  away leaves the directory by itself.

### Store-and-forward — BUILT (as a side effect, not as a role)

`services/social/store_forward.dart`: a message for an offline recipient is
deposited at a node advertising `RelayCap.storeForward` (found via the
directory) and flushed when the recipient's LXMF destination announces. 30-day
TTL. This is the Archiver's job, already implemented — it just has no owner-facing
role, no quota UI, and no direct-link (LAN/BLE/LoRa) policy yet.

### The device as a relay — BUILT

- **Over Reticulum**: `RelayNode` answers `REQ` / `COUNT` / `EVENT` / `DEPOSIT`
  / `DROP` over RNS links (`relay_protocol.dart`), backed by `RelayEventStore`
  (SQLite + FTS5, NIP-50 search). A **leaf still answers queries about its own
  posts** — "ask the author directly" is a real path.
- **Over the LAN**: `NostrWsServer` — any stock NOSTR client on the LAN can use
  this device as a `wss://` relay, NIP-11 and all.
- **Media**: `blossom_server.dart` serves content-addressed blobs over HTTP, and
  the same blobs are fetchable over Reticulum by sha256 through
  `FileTransferNode` + `MediaFileSource`, with a Blossom-style **deposit** opcode
  (`file_transfer.dart`, BIP-340-authorised) for asking a host to keep a blob —
  the primitive an Archiver accepts on. Blossom-over-Reticulum as an
  HTTP-compatible service does **not** exist; the RNS path is the files layer.

### Retention: what a node keeps — BUILT

`retention_tier.dart` + `host_retention_policy.dart`: every event is tiered
**self (0) / followed (1) / stranger (2)**. Strangers get a byte slice, a
notes-per-month cap and a retention window; eviction only ever deletes tier 2,
never kinds 0/3. Anything *about you* — a reply, a repost, a reaction carrying
your `p` tag — is stored at tier 0 the moment it arrives, which is why your
notifications and the notes they point at are readable with the radio off.

**This is "you keep what matters to you", implemented.** It is also the skeleton
of the Archiver quota: `HostQuota{ceilingBytes, strangerSliceBytes,
strangerNotesPerMonth, strangerRetentionMs}` already exists and is enforced.

### Two networks, one store — BUILT

The client (`nostr_relay_hub.dart`) is transport-abstract: a relay is a URI.
`wss://` → the internet, `local` → this device's own store, `rns://<idhash>` → a
relay on the mesh. Every event from every transport is signature-verified and
merged into **one** store, so the feed is a single unified cache and a post goes
out over both. The user-facing panel is **NOSTR on Internet** (relays + Blossom
servers: add / remove / enable-disable).

## What is NOT built (do not assume it)

1. **Indexers answer *what*, not *where*.** Today an Indexer *is* a relay host:
   it stores stranger events in its own `RelayEventStore` (under quota) and
   serves them back. The pointer-only model is the target; the DHT already
   implements exactly that primitive, but the two layers are joined only as
   *anchors* so far — not as *the* answer to "where can I find `npub…`".
2. **No author→provider records.** Nothing publishes *"I hold notes from npub
   XYZ"* into the DHT. The mechanism exists (`publishKey(key32)` takes an
   arbitrary 32-byte key, and an npub is exactly 32 bytes); it is not called for
   authors.
3. **Indexers do not sync with each other.**
4. **There is no Archiver role.** No `RelayRole.archiver`, no quota UI, no
   direct-link store-and-forward policy, no "mirror the small devices around me".
   The parts (deposit opcode, `HostQuota`, `StoreForward`, provider publishing,
   `_autoSyncTick` mirroring folders on an indexer host) exist and are unjoined.
5. **`rns://` relay URIs are inert in the shipped app.** The relay hub runs on a
   background isolate constructed with `rnsClientFactory: null`
   (`nostr_engine.dart`), so an `rns://…` entry resolves to a null client. All
   real Reticulum relay traffic goes through `RelayNode` on the main isolate.
   `NostrRnsClient` is complete and unused.
6. **No long-lived subscriptions over RNS.** A `REQ` returns one `RESULT` and
   ends; mesh "subscriptions" poll. Correct for a mesh — just don't expect push.
7. **No spam cost on DHT stores.** Only count caps. `coin/postage_gate.dart`
   exists and is not wired in.
8. **No Blossom over Reticulum** (HTTP only), and BUD-02 upload auth is not
   verified — uploads are gated by a toggle.

## Planned: the physical profile — what a node is made of

Every role above is a promise about *software*. Whether a node can keep that
promise on the worst day of the year is a question about **hardware, power and
antennas**, and today the code asks only two-thirds of one of those questions
(`CapacityProfile`: is it charging, and what kind of network — that's it).

That is not enough. **A solar-powered Indexer on Starlink is worth more than a
hundred fibre boxes when the grid goes down**, and the network has to be able to
know that *before* it needs it. So every node — Publisher, Indexer, Archiver —
carries a physical profile, and every node that has to choose a peer can read it.

### What is announced

Added to `RelayAnnouncement` (the `geogram/relay` announce app_data, msgpack,
short keys, ~20–30 B on top of the existing ~350 B budget — it must never cost a
second announce packet):

| Field | Key | Values |
|---|---|---|
| **Power source** | `ps` | `grid` · `grid+ups` · `solar` · `solar+battery` · `wind/hydro` · `vehicle` · `battery-only` |
| **Powered fraction** | `pw` | 0–100: **percent of the last 7 days this node actually had power**. Measured by the governor, not typed by the user |
| **Uplink kind** | `up` | `fibre/wired` · `wifi` · `cellular` · `satellite` (Starlink et al.) · `none` — *offgrid*, mesh-only |
| **Uplink speed** | `bw` | measured bytes/sec, log-bucketed (one byte: 2^n) — an *observed* number, not a sales figure |
| **Other links** | `lk` | bitmask: `LoRa` · `Bluetooth` · `WiFi-Direct` · `packet radio / AX.25` · `serial` · `RNS TCP hub` |
| **Autonomy** | `au` | hours this node expects to keep running with no grid and no sun (battery bank ÷ draw). 0 = unknown |
| **Coverage** | `gh` + `rx[]` | a **coarse** geohash of the region this node serves, plus **one entry per radio**: its range, its band, and the frequency it is listening on (see below). Absent = says nothing about where it is |

Two rules keep this honest:

1. **Announce facts, score locally.** A node never announces "I am precious".
   It announces what it *is*; every asker computes its own score from that. There
   is nothing to inflate that would be believed, because…
2. **Claims are corroborated by observation.** A node claiming `pw: 100` that we
   have heard from twice in a week is scored on the two times we heard it. The
   `RelayDirectory` already tracks observed uptime, freshness and hop count, and
   `bw` is checked against what the transfer actually did. **Observed beats
   claimed, always.** Self-reported physical facts are a *hint that saves a
   measurement*, never a credential.

`pw`, `bw` and `au` are measured by the existing `CapacityGovernor` (extended: it
already samples charging state and network kind on a timer — it starts keeping a
7-day powered-fraction ring and a throughput estimate). `ps`, `up` and `lk` are
the parts a human must state — nothing on Android can tell you the roof has a
solar panel on it, and no API reports a LoRa antenna.

### Coverage: where a node is useful, and how far it reaches

A radio has a footprint, and that footprint is the whole point of it. "There is a
LoRa gateway with a 12 km range on the hill above the valley" is *actionable* —
it tells a phone in that valley who to shout at, and it tells the network which
nodes still connect two towns when everything between them is down. A LoRa node
that never says where it is is a radio nobody can find.

So the profile can carry:

- **`gh`** — a **geohash of the region the node serves**. Deliberately coarse.
- **`rx[]`** — **one entry per radio this node listens on**, because one number
  cannot describe a machine with two antennas.

#### One range per link, because the antennas are not the same

A node may have Bluetooth (tens of metres), a LoRa gateway (a few km), and an HF
or VHF station that reaches 80 km. Collapsing that into a single "range" is a
lie in both directions: it makes the Bluetooth look magical and the radio look
useless. Each radio therefore gets its own entry:

| Sub-field | Meaning |
|---|---|
| `l` | which link — LoRa · packet radio / AX.25 · Bluetooth · WiFi-Direct · other |
| `r` | **range in km** for *this* link, as the person who raised the antenna estimates it |
| `f` | **the frequency it is listening on**, in kHz (868 200, 433 775, 144 800, 14 105 …). 0 = not applicable (Bluetooth) |
| `m` | modulation / mode, short string: `LoRa-SF7BW125`, `FSK`, `AX.25-1200`, `JS8`, … — free-form, because the radio world will always invent another one |
| `d` | **when it is listening** — a schedule string (next section). Default `always` |

**The frequency is the point.** A range says a station *could* hear you; a
frequency says *where to call*. Without it, discovering "there is an 80 km packet
station over that ridge" is a fact you cannot act on — you would have to guess
the band, and guessing is exactly what a mesh is supposed to spare you. With it,
a phone with a LoRa dongle, or an operator with an HF rig, knows precisely what
to tune to and in which mode.

Wire cost: 4–5 chars of geohash, plus ~8–14 bytes per radio entry. Two radios is
about 30 bytes — inside the announce budget, and if a node really has five, the
list is capped and the longest-range ones win, because those are the ones nobody
else can substitute.

#### The listening schedule (`d`)

Solar and battery stations do not hear 24/7 — they wake, listen and sleep. **A
node that is only reachable in a window is not broken, it is thrifty**, and a
caller who gives up after one unanswered call has thrown away a perfectly good
station. So the schedule is part of the advert, and it is **one string that a
person can read and a machine can parse** — no separate "display" and "wire"
forms to drift apart, and nothing a user has to translate into cron.

**Grammar** (case-insensitive, canonical form is lower-case):

```
schedule   := "always" | term ("," term)*        ; commas = union ("or")
term       := duty | window
duty       := "every" span "for" span            ; clock-free — a repeating cycle
window     := range [ days ]                     ; needs a clock
range      := point "-" point
point      := HH:MM | "dawn" | "dusk" [ offset ]
offset     := ("+"|"-") span
days       := "mon".."sun" ( "," day | "-" day )* | "weekdays" | "weekends" | "daily"
span       := INT ("m"|"h")                      ; minutes or hours
```

Times are **UTC** unless suffixed `local` — a mesh spans time zones, and a
station that says `06:00-18:00` and means "my local morning" is a station nobody
can call. `dawn`/`dusk` resolve against the node's own announced coverage region
(that is the second thing the geohash is for): a solar node's real schedule *is*
the sun, and writing it as `dawn-dusk` stays correct in December.

**Examples — this is the whole feature:**

| String | Reads as | Who says it |
|---|---|---|
| `always` | listening 24/7 | mains-powered gateway |
| `every 30m for 3m` | wakes for 3 minutes, every 30 | battery LoRa node |
| `every 10m for 1m` | 1 minute in every 10 | ESP32 with no clock |
| `06:00-18:00` | daylight hours, UTC, every day | solar node, fixed window |
| `06:00-18:00 local` | the same, in its own time zone | a person's home station |
| `dawn-dusk` | as long as the sun is up, wherever it is | solar node, done right |
| `dawn+30m-dusk-30m` | sun up, with a margin to charge | cautious solar node |
| `08:00-20:00 weekdays, 10:00-14:00 sat` | an office box and its Saturday | a club station |
| `every 15m for 2m, 18:00-22:00` | thrifty all day, wide open in the evening | the common real case |

**Clockless is not a degraded mode, it is a first mode.** `every N for M` needs
no calendar, no NTP, no RTC — it is a duty cycle, and an ESP32 that just rebooted
can honour it from `millis()` alone. Anything the node cannot resolve, it must
not claim: **a node with no clock advertises only `duty` terms.** Advertising
`06:00-18:00` when you cannot tell the time is a lie that costs a caller a wasted
transmission on a battery, which is exactly the resource this whole design exists
to protect.

**What the caller does with it.** Parse → *is it listening now?* → if yes, call.
If no, `nextWindow()` gives the instant it wakes, and the call is queued for then
rather than burned now. With a duty cycle and no shared clock, phase is unknown —
so the caller **retries across one full period** (`every 30m for 3m` ⇒ keep trying
for 30 minutes, and you are guaranteed to land inside a listening window) instead
of concluding the station is dead after one try. A schedule that turns out to be
wrong is corrected by observation, like every other claim: the directory already
records when a peer actually answered.

**On the wire** the string is short enough (`every 30m for 3m` is 17 bytes) that
it can simply be sent as text, and the announce budget can take it for one or two
radios. A node that is tight for space may send the **canonical packed form**
instead — one byte of kind, then the parameters (`duty`: two varints; `window`:
two 11-bit minute-of-day values, a day bitmask, and a flag for UTC/local/solar) —
typically 3–5 bytes. **The text is normative and the packed form is an
optimisation**: they must round-trip, and a receiver that does not understand a
term ignores that term rather than the whole schedule (so a future `dawn` term
never breaks an old node — it just makes it call at a time the station is asleep,
which is the failure it already knows how to survive).

The parser, the packer and `isListeningNow()` / `nextWindow()` are one small
pure-Dart file with a table-driven test, testable with no radio in the room.

Rules, and they are firm because this is the one field that can hurt somebody:

- **It is a region, never a position.** The user does not report GPS — they
  **pick a place on the map** (reuse the existing `maps` wapp / the host's map
  picker) and choose how coarse to be. The stored value is a truncated geohash;
  the precision *is* the privacy control, and it is shown as what it means:
  *5 characters ≈ a town (±2.4 km)*, *4 ≈ a district (±20 km)*, *3 ≈ a region
  (±78 km)*. Default for a phone: **nothing at all**.
- **Opt-in, per device, and it defaults to off.** A phone in someone's pocket has
  no business advertising where it sleeps. This field exists for **infrastructure
  that wants to be found**: the gateway on the hill, the solar box on the roof of
  the community centre, the Archiver in the village hall. Those nodes gain
  everything by being locatable and risk nothing — they are already a physical
  antenna in a public place.
- **Coarse by construction.** A truncated geohash cannot be sharpened, and each
  range is one number in km. There is nothing here to triangulate with. If a user
  picks town-level precision, town-level is all that exists on the wire — the
  fine bits are never stored, so they cannot leak later. (A licensed station is a
  separate case: its callsign and its location are already public by law, and its
  operator may well *want* the precise entry. That is their choice to make, not
  our default.)
- **It is a claim like any other.** A node saying "80 km on 144.800" is telling
  you what to *try*, not what is true. Whether it answers is the only real
  evidence, and the directory already keeps that.

What it buys, all of it at the moment the internet is not there:

- **"Who can reach me right now, and on what?"** — a phone with no signal filters
  the directory to nodes whose region is adjacent to its own and whose radios
  plausibly cover the gap, then calls them **on the link and the frequency they
  said they were listening on** — instead of spraying the whole mesh. A node with
  a LoRa dongle only cares about the LoRa entries; an operator with a VHF rig only
  cares about the packet ones. Same announce, different reader.
- **A map of the mesh that a human can read.** The Reticulum wapp already draws a
  graph; with coverage it can draw it *on the map*: who covers this valley, where
  the hole is, which single node is bridging two towns (and therefore which one
  to add redundancy next to). That is a picture a community can act on.
- **Disaster routing.** When the score enters degraded mode (below), coverage is
  how a node decides *which* solar-and-LoRa neighbour is worth waking: the one
  whose footprint actually overlaps the people who need it.

### The score, and why it changes with the weather

Every asker computes a **resilience score** locally, from the announced facts and
its own observations. Two profiles, and the node switches between them by itself:

**Normal times** — the internet is up, and what matters is speed and closeness:
uplink speed, low hop count, high uptime. A fibre box wins. This is roughly what
`bestIndexer()` scores today (interest match, capacity class, hops, freshness).

**Degraded mode** — entered when the internet path is *gone*: no `wss://` relay
reachable, no RNS TCP hub answering, for long enough that it is not a blip. Now
the weights invert, and the scoring becomes a survivability question:

| Signal | Why it is worth points when things are broken |
|---|---|
| **Grid-independent power** (`solar+battery`, `wind/hydro`, high `au`) | It is still running. Nothing else matters if it is dark. |
| **Grid-independent uplink** (`satellite`) | Starlink survives the local ISP, the local exchange and the local flood. It is a path *out* that does not depend on any infrastructure between here and the horizon. |
| **Off-grid links** (`LoRa`, `packet radio`, `Bluetooth`) | It can be *reached* without any internet at all — from a phone with no signal, over kilometres, on a battery. |
| **Coverage that overlaps mine, on a radio I actually have** (`gh` + `rx[]`) | A solar LoRa gateway 200 km away cannot help me. The one on the hill above this valley can — and if all I own is LoRa, its 80 km HF entry is worth nothing to me while its 6 km LoRa entry is worth everything. Score per link, not per node. |
| **High powered-fraction, observed** | It was there yesterday, and the day before. |
| Uplink speed | Still counts, but far below all of the above. A slow node that exists beats a fast node that is a brick. |

So **solar + Starlink + LoRa** is the top of the table in a disaster and
unremarkable on a Tuesday — which is exactly right, and exactly what a fixed
score cannot express. A node with that profile should also be *told* it is
precious, and asked (in the wapp) to keep itself that way: pinned interests, a
bigger quota, sync partners chosen for reach rather than speed.

Nothing here is a new transport or a new protocol — it is six fields in an
announce, a governor that already runs, and a scoring function that reads the
room. That is deliberate: **the disaster case must not depend on code that only
runs during a disaster.** The same announce, the same directory, the same probe;
only the weights move.

### Where it shows up

- **`bestIndexer()` / provider selection** — the score replaces the current
  capacity-class-only ordering, and the DHT's `ProviderRecord` capacity class
  gains the same treatment (prefer an Archiver that is still powered over one
  that is not).
- **DHT anchors** — the persistence anchors an Indexer publishes to should skew
  toward grid-independent nodes, because an anchor set that all shares one grid
  is not an anchor set.
- **Sync partners** — an Indexer in degraded mode syncs with whoever is *still
  there*, not with whoever is fastest.
- **Settings → Hardware** (below) — stated once, for the device, and read by
  every role.

### Stated once: Settings → Hardware

The physical profile describes **the device**, not a role. A user who volunteers
the same box as an Indexer *and* an Archiver must not be asked twice what it is
plugged into, and two answers that can disagree is a bug waiting to be filed.

So it lives in **Settings, as its own full-size panel** — not a section squeezed
into a list, because the point is to make the *combinations* easy to state:
power source × uplink kind × which radios are actually attached. A full panel can
lay those out as pickers and toggles that read like a description of the machine
in front of you; a settings row cannot.

The panel holds:

- **What only a human knows** — power source (grid / grid+UPS / solar /
  solar+battery / wind / vehicle / battery-only), uplink kind (wired / WiFi /
  cellular / satellite / none), autonomy in hours without grid or sun, and which
  extra links are physically attached (LoRa, Bluetooth, WiFi-Direct, packet
  radio, serial). Sensible defaults, so a normal phone user never touches it.
- **Coverage** (off by default) — *"pick the area this device serves"* opens the
  **map**; the user drops a pin and chooses the precision with a slider labelled
  in plain words (town / district / region). The panel draws the resulting circle:
  **this is what the network will be told, and nothing finer.** A phone leaves it
  off; the gateway on the hill turns it on, because being found is the entire
  reason it is up there.
- **Radios** — a row per antenna, added by the user, because a machine with a
  LoRa hat *and* a VHF rig has two very different footprints and one number would
  lie about both. Each row: the link, the **range in km**, the **frequency it
  listens on**, the mode, and **when it is listening**. Each row draws its own
  circle on the same map, in its own colour, so the user *sees* the difference
  between 6 km of LoRa and 80 km of packet — and so does the network.
- **The schedule editor** is a picker, not a text box, but it *writes the string*
  and shows it: pick `always`, or `every [30m] for [3m]`, or `[06:00]–[18:00]` on
  chosen days, or `dawn–dusk`, and the panel prints back the canonical line
  (`every 30m for 3m, 18:00-22:00`) plus a plain-language sentence and a 24-hour
  strip showing the awake bands. Typing the string by hand is allowed and parses
  to the same thing — the string is the format, the picker is a convenience.
  A device with no clock is offered **only** the `every N for M` form, because it
  cannot honestly promise a time of day.
- **What the device measured for them** — powered fraction over the last 7 days,
  real observed throughput. Read-only, and shown next to the claims so the two
  can be compared honestly.
- **What it means** — the resilience score in **both** modes, in plain words:
  *"On a normal day this device is an ordinary node. If the grid goes down it
  becomes one of the most valuable ones your network has."* People who own such
  hardware should be told, because they are the ones who decide whether to keep
  it running.

Roles **read** this profile; they never restate it. The Indexer and Archiver
wapps each show a one-line summary of it with a link straight into the panel
(*"Solar · Starlink · LoRa · 96% powered — change in Settings"*), and everything
else — the announce, the score, anchor choice, sync-partner choice — is derived
from the single stored profile. One source of truth, one place to edit it.

## Planned: Indexer↔Indexer sync — "what changed?"

Indexers exchange **addresses, never content**: the unit of sync is the signed
`ProviderRecord` (*"pubkey X provides key K, capacity C, expires at T"*, ~176 B),
which is exactly what the DHT already stores. Because every record is signed by
the provider itself, an Indexer can pass on a record it received from a third
party and the receiver still verifies it end-to-end — a relaying Indexer cannot
forge, retarget or resurrect a pointer. That is what makes gossip between them
safe, and what lets a fresh Indexer fill its map from a peer instead of by
waiting for a thousand phones to re-announce.

Indexer-to-indexer traffic is fast and wired, so this is where the load should
sit: the phones announce once, the Indexers spread it among themselves.

### The pointer log

Each Indexer keeps its pointer map as an **append-only log**, and every entry
gets, at the moment it is accepted:

- **`seq`** — a strictly increasing 64-bit counter, local to this Indexer, that
  never repeats and never goes backwards. It is a *position in my log*, not a
  measure of anything.
- **`ts`** — the local wall-clock time, **when the node has a clock**. Optional.
- **`epoch`** — a random 8-byte id for the *current* log. Regenerated whenever
  the log is truncated, rebuilt, wiped, or restored from a snapshot.

The log holds insertions *and* removals (a provider that was demoted, a record
that expired), because "this address is dead" is as important to propagate as
"this address is new" — otherwise every Indexer's map only ever grows.

### Two cursors, because not every node has a clock

A peer asks **"what changed since …"** and may express *since* in either of two
ways. Both are answered; a node offers whichever it can honour.

| Cursor | Asked by | Meaning |
|---|---|---|
| **`since_seq` + `epoch`** | anything, and the **only** option for a clockless node | "resume my read of *your* log at position `seq`" |
| **`since_ts`** | a node with a working clock | "everything you accepted after this instant" |

The sequence cursor is the primitive and the time cursor is the convenience.
**An ESP32 that reboots has no idea what day it is** — it has no RTC, no NTP, and
possibly no route to anything that does. It cannot say "since Tuesday". But it
*can* persist eight bytes: the last `(epoch, seq)` it read from each peer it
syncs with. That is a durable, restart-proof, clock-free cursor, and it is why
`seq` — not time — is the normative one. A time cursor is also inherently
untrustworthy across a fleet: two Indexers with skewed clocks will silently drop
or duplicate records at the boundary. `seq` cannot skew, because it is not a
measurement — it is a position in one node's log, interpreted only by that node.

**`epoch` is what makes `seq` safe.** A cursor is only meaningful against the log
it came from. If the peer's `epoch` no longer matches the one the cursor carries,
the peer's log was rebuilt underneath us and the position is meaningless — the
peer says so, and the asker restarts from zero (or from a snapshot, below)
instead of silently missing everything that happened in between. This is the
failure mode that quietly corrupts every naive "sync since N" design, and the
epoch closes it for the price of eight bytes.

### The exchange

Three new opcodes on the existing relay protocol (msgpack over an RNS link,
alongside `EVENT`/`REQ`/`COUNT`/`DEPOSIT`/`DROP` — see `relay_protocol.dart`):

| op | payload | meaning |
|---|---|---|
| `SYNC_REQ` | `[op, epoch?, since_seq?, since_ts?, filter?, max]` | "what changed since…" — `filter` narrows to an interest set (topics / author prefixes), so a small Indexer syncs only its own shard |
| `SYNC_RES` | `[op, epoch, records[], removals[], next_seq, more]` | a bounded batch, plus the cursor to resume from and whether there is more waiting |
| `SYNC_RESET` | `[op, epoch, oldest_seq]` | "your cursor is not from this log (or is older than what I still hold) — start over" |

Rules that make it survive real networks:

- **Bounded batches, resumable.** `max` caps the batch to what fits a link; the
  asker loops on `next_seq` while `more` is set. A LoRa-attached Indexer takes
  the same log in tiny bites over hours; the cursor makes that free.
- **Idempotent merge.** A record is keyed by `(key, providerPub)` and the newest
  `timestampMs` wins. Replaying an overlapping range is harmless, so a cursor
  that is *too old* costs bandwidth, never correctness. Nodes should always
  re-ask from slightly before their cursor rather than risk a gap.
- **Verify on arrival, always.** Every record's signature is checked against
  `providerPub` before it enters the map; unsigned or expired records are
  dropped, not relayed. An Indexer never has to trust the Indexer it is talking
  to.
- **Removals are TTL-bounded too.** A removal (`demoteProvider`, expiry) is kept
  in the log long enough to propagate, then compacted away — otherwise the log is
  immortal. Compaction bumps `oldest_seq`, and any peer whose cursor predates
  that gets a `SYNC_RESET`.
- **Snapshot for the cold or the reset.** A node with no cursor (or a rejected
  one) asks for a filtered snapshot of the *live* map — expired records already
  gone — and receives it as a normal batched stream ending at the peer's current
  `next_seq`. A fresh Indexer is useful within one exchange instead of after a
  full announce cycle.
- **Anti-abuse is the same as everywhere else.** The store caps
  (`maxStoredKeys`, `maxRecordsPerKey`) apply to synced records exactly as to
  direct STOREs, so a hostile peer cannot inflate a neighbour's map, and a
  provider that never answers a fetch is pruned locally (`demoteProvider`)
  regardless of who vouched for it.

### Who syncs with whom

From the `RelayDirectory`: peers advertising `RelayCap.search`, preferring high
uptime and low hop count (both already announced), a handful at a time, at an
interval scaled to capacity — a home-fibre Indexer every few minutes, a LoRa one
when the link is idle. **Battery-powered leaves are never sync partners**: they
announce, they are indexed, they are left alone. That asymmetry is the whole
reason the role exists.

## Planned: the Indexer wapp

**Purpose: let a person volunteer a device, see what it is doing for the network,
and take the offer back.** Today the role is inferred from the charger and the
WiFi, which is right as a *default* but wrong as the *only* way — a user with an
old phone in a drawer has no way to say "yes, use this", and a user on a metered
home line has no way to say "no, don't".

Screens:

- **Volunteer** — one switch: *Serve as an Indexer*. States: `off` /
  `on when plugged in` (the current behaviour) / `always on`. Shows plainly what
  it costs (uplink, no meaningful disk) and what it does **not** do: *an Indexer
  stores no one else's posts. It remembers where they are. It is not a backup.*
- **What I answer** — the interest set (`InterestSet`): topics and authors this
  node indexes, or **wide** (index everything it hears). Prefilled from what the
  owner already follows.
- **Live** — the numbers, because a role nobody can inspect is a role nobody
  trusts: queries answered/hour, pointers held, distinct authors covered,
  providers demoted (dead pointers pruned), uptime as announced, peers who chose
  us as their anchor.
- **The network** — the `RelayDirectory` as a list: the other Indexers this
  device knows, their capacity, uptime and hop distance, which one is currently
  `bestIndexer` for a given author.
- **Sync** — one row per peer we sync pointers with: its `epoch`, our cursor
  (`seq`, and the time if it has a clock), how far behind we are, records pulled
  and pushed, and when a `SYNC_RESET` last forced a restart. A stuck cursor is
  the first thing to look at when an Indexer starts giving stale answers, so it
  has to be visible.

Host work behind it: expose the role manager (`RelayRoleManager.applyCapacity` +
an explicit override), the `InterestSet`, and the `DhtNode` counters
(`storedKeys`, `replicasStored`, `providersDemoted`, `storesRejected`) through
the HAL. Wire the road items 1–4 below so the numbers are about *pointers*, not
about stored notes.

## Planned: the Archiver wapp

**Purpose: let a person donate storage on purpose, with a number they choose,
and know exactly what is on their disk and why.**

Screens:

- **Quota** — a slider and a number: *hold up to N GB for other people*. This is
  the whole contract. Current use, free space, what gets evicted next
  (oldest-and-least-wanted; the owner's own data is never touched). Backed by
  `HostQuota`, which already enforces a ceiling, a stranger slice, a monthly
  note cap and a retention window.
- **What I host** — checkboxes, and they are the interesting part:
  - *Authors I follow* — the default; redundancy for the people this user
    already cares about.
  - *Topics* — the interest set again.
  - *Whatever arrives over a direct link* — **LAN, Bluetooth, LoRa**. A peer
    with no route to anywhere hands its data to this device, which holds it and
    passes it on when the far side appears. This is store-and-forward as an
    explicit, quota-bound *offer* rather than a side effect of being plugged in.
    Per-transport switches, because a LoRa gateway wants a very different policy
    (tiny, precious, slow) from a LAN box.
  - *Mirror the small devices near me* — pull what battery-powered peers are
    willing to share, then publish ourselves as a provider so the DHT stops
    waking them.
- **What's on my disk** — a real list: author, size, how many other providers
  hold this (redundancy count, from the DHT), last time somebody actually fetched
  it. With **Drop** on every row. A user who cannot see and delete what strangers
  put on their machine has not consented to anything.
- **Deposits** — inbound "please keep this blob" requests (the BIP-340-authorised
  deposit opcode already exists): accept / reject policy, and a log.
The physical profile is **not** repeated here — it is the device's, stated once in
Settings → Hardware. The wapp shows the one-line summary and links into it. It
matters more to an Archiver than to anyone, though: an Archiver that dies with the
grid is holding the only copy of somebody's photos on a disk that just went dark,
and a solar Archiver with a LoRa antenna is where a neighbourhood's data should
live — so the summary line is what the quota screen should be read against.

Host work behind it: a `RelayRole.archiver` (or a capability flag on the
announce, which is cheaper on the wire — `RelayCap.archive` already exists and
is currently derived, not chosen), the quota + policy plumbed to `HostQuota` and
the deposit verdict hook, per-transport admission (the interface a peer arrived
on is already known), and the mirror loop generalised from the existing
indexer-host folder mirroring (`_autoSyncTick`).

## The road

Dependency order. Each step is small and independently useful.

1. **Publish author-provider records.** When a device keeps an author (follow ⇒
   tier 1 ⇒ it already stores their notes), publish a `ProviderRecord` under
   `key = the author's 32-byte pubkey`, exactly as folders already do. "Who has
   notes from `npub…`" becomes a DHT resolve, and the answer is a list of
   devices — not a server.
2. **Resolve-then-probe-then-ask in the client.** Local store → DHT resolve
   (anchored at Indexers) → connectionless probe of the providers → link only to
   one that says `HAVE`. Silence costs nothing; this is what keeps a
   thousand-relay network from melting phones.
3. **Make the Indexer pointer-only.** It answers *where* and stores the provider
   map, not the notes. It may keep a small hot cache of recent events for its
   advertised interests (that is what `RelayCap.firehose` means), but its promise
   to the network is the directory. Told to the user in those words: *an Indexer
   is not your backup.*
4. **Indexer↔Indexer sync** (designed above). An append-only pointer log with a
   `(epoch, seq)` cursor and an optional time cursor, `SYNC_REQ` / `SYNC_RES` /
   `SYNC_RESET` over the existing relay link. Any live Indexer then gives the
   same answer and a dead one costs nothing. A clockless node (ESP32 after a
   reboot) resumes on `seq` alone.
5. **The physical profile** (above): power, uplink and autonomy on the announce,
   plus an opt-in coverage region (coarse, picked on the map) with **one entry per
   radio** — its range, its listening frequency, its mode and its duty. The
   governor extended to measure powered-fraction and throughput. **One full-size
   Hardware panel in Settings**, where the device is described once and each radio
   draws its own circle on the map. And a resilience score that re-weights itself
   when the internet path disappears, scoring **per link** — a neighbour's 80 km
   HF entry is worthless to a caller who only owns LoRa. Do this *before* the
   wapps, so both read a profile that already exists instead of each growing its
   own copy of it.
6. **The Indexer wapp** (above) — the role becomes something a person grants,
   inspects and revokes.
7. **The Archiver role**, then the **Archiver wapp** (above): quota, policy,
   direct-link store-and-forward, mirror-the-small-devices, and a visible,
   deletable list of what is being held for others.
8. **Retention rules on both.** What is worth a pointer: a record signed by a
   provider that actually answers, an author somebody follows, a topic in the
   interest set. What is not: unsolicited floods (the store caps), records whose
   provider never answers a fetch (`demoteProvider` already prunes those), and
   eventually a postage/PoW cost per store for the abusive tail.
9. **Media follows the author.** Following keeps their blobs too — Blossom is
   part of the package. Your phone carries the photos and videos of the people
   you care about, fetchable over the internet by sha256 *or* over Reticulum from
   another device that also kept them. Archivers hold the redundant copies.
10. **Merge the two worlds properly.** Wire `rnsClientFactory` so `rns://` relays
   are first-class in the same relay list as `wss://` ones, and a single post
   fans out to internet relays, mesh Indexers, Archivers and the copy on your own
   disk, in one operation, with one signature. That is the end state: NOSTR works
   exactly as it does today, and it keeps working after the relays we use today
   are gone.

## The one-sentence version

Users keep what they value, Archivers hold the redundant copies, Indexers
remember where everything is, and the two networks — internet and Reticulum —
carry the same signed events, so no relay is ever load-bearing again.
