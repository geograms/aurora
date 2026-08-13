# Indexers

An indexer answers the question a station cannot answer for itself: **what
happened while I was not listening, and who has the thing I want?**

Radio is the present tense. A packet exists for as long as it is in the air and
then it is gone, and a station that was asleep, out of range or not yet built
missed it entirely. A file is worse: it exists somewhere, on somebody's disk,
and nothing about hearing its name tells you where. An indexer is the station
that kept a note.

It is deliberately not a server. APRS-IS is one place everyone connects to, and
everything anyone sends becomes everyone's; a NOSTR relay is one place the
clients agree to meet. Both work and both have a centre. An indexer here is
chosen by each side independently — the publisher picks the ones it pushes to,
the reader picks the ones it asks, and the two need not overlap for the network
to function.

## The three properties

**1. Chosen, never imposed.** No station is obliged to use one, and zero
indexers is a working configuration: such a station keeps its own publications
and serves them to whoever asks over the radio. It is not findable by somebody
who was not listening at the time, which is a fair trade and sometimes the point
— a station that talks only to the people in range of it is not degraded, it is
private.

**2. It holds signed things it cannot forge.** Everything an indexer stores was
signed by whoever made it, and a reader verifies against that author's key, not
against the indexer that handed it over. An indexer can refuse, lose, or decline
to serve; it cannot alter, retarget or resurrect. This is the property that
makes the whole role safe, and it is what lets indexers gossip with each other
(below) instead of each having to see everything first-hand.

**3. It answers by reading what it was given.** No summary records, no
derived schema, no transformation step on ingest. The query surface is the
fields the thing already carries, so there is no second format to keep in step
with the first and get subtly wrong.

## What gets indexed: the thing, or a pointer to it?

Both patterns exist here, and the choice is arithmetic, not principle:

| | Unit stored | Size | Why |
|---|---|---|---|
| **Files** (Reticulum) | a signed pointer — "this key has that file" | ~176 B for a file of any size | content is megabytes; storing it in the index would make every indexer a mirror |
| **XPRS** | the packet itself, verbatim | ≤ 250 B | pointer and content are the same order of size, so a pointer *plus* a fetch costs more than the thing |

The rule is **send whichever is smaller**. Applying the file layer's answer to
XPRS would mean paying twice for a 150-byte warning.

---

# Files over Reticulum

Implemented in the `reticulum-dart` sibling package under
`lib/src/services/files/`. `docs/folders.md` covers the folder layer on top;
this is the index underneath it.

## The map: sha256 → who has it

A Kademlia-style DHT over Reticulum (`dht/dht_core.dart`):

- keyspace is Reticulum's native **128 bits**; a node's id is its DHT
  destination hash (`RnsDestination.hash(identity, 'geogram', ['dht'])`), and a
  file's routing key is the first 128 bits of its sha256
- distance is XOR, and the *k* nodes closest to a file's key hold its records
- replies are capped so one fits a single link-encrypted packet — 5 contacts or
  2 records (a contact public key is 64 B, a record ~176 B)

The value stored is a **`ProviderRecord`** (`dht/provider_record.dart`): the
file's sha256, the provider's public key, a capacity class, an optional manifest
hash, a timestamp, a TTL and a 64-byte signature.

- the **public key** is both how you verify the record and how you reach the
  provider's files destination — one field, two jobs
- the **capacity class** ranks providers by what they can actually give:
  archive (pinned, always-on) → home fibre → home wifi → transient wifi →
  cellular → BLE. A phone on a train is a valid provider and a poor first choice.
- **TTL with republish** is how abrupt departures self-heal: a provider that
  vanishes stops republishing and its records age out on their own. Nothing has
  to notice it left.

A lying record is not a security problem, only a wasted round trip: the
downloader hashes what arrives and content addressing does the rest.

## Indexers talking to each other

The load belongs on the well-connected nodes, not on the phones. So:

**Leaves announce once. Indexers spread it among themselves.** A
battery-powered node is never a sync partner — it announces, it is indexed, and
it is left alone. That asymmetry is the entire reason the role exists.

The mechanism is a **pointer log** (`dht/pointer_log.dart`) and a sync protocol
over it (`dht/pointer_sync.dart`):

- the log is **append-only and carries removals as well as insertions**,
  because "this address is dead" has to travel as surely as "this address is
  new" — otherwise every indexer's map only grows, slowly filling with pointers
  to things that are not there
- a peer resumes at **a position, not a time**: `SyncCursor(epoch, seq)`, eight
  bytes and a name. A position cannot skew, and a device with no clock can still
  persist one across a reboot. The `epoch` changes when a log is rebuilt, which
  is how a peer is told to start over rather than silently resume against a log
  that no longer means what it did.
- a server that cannot honour a cursor answers **RESET** rather than handing
  back a partial answer that looks complete
- a merging indexer **verifies every record against the provider that signed
  it** before applying it, and applies idempotently

A fresh indexer therefore fills its map from a peer in one exchange, instead of
waiting for a thousand phones to re-announce.

---

# XPRS

`docs/XPRS.md` §36 is normative; this is the shape of it.

## Publication or mail — the `d:` field decides

| | What it is | What the indexer does |
|---|---|---|
| **Publication** — no `d:` | offered to whoever is interested | answers queries about it, to anybody |
| **Mail** — carries `d:` | addressed to one station | holds it, tells that station it is there, **never serves it to a third party** |
| `ping` / `pong` | is this path alive *now* | neither stored nor served |

Addressing decides, not the type. A rule that named types would need
re-litigating every time a type gains a `d:`, and the packet already says who it
is for.

## The packet is sent as it was composed

No envelope, no summary, no transformation. An indexer receives the exact bytes
the author signed, and everything a query needs is already in them: `t:` type,
`f:` author, `ts:` when, `pos:` where, `dest:`/`near:` the region, `until:` when
it stops mattering, `scope:` how far it may travel.

Because the author's signature travels with the packet, an indexer passing on a
third party's publication is exactly as trustworthy as the author — which is to
say the indexer's honesty never enters into it.

## Choosing indexers

- the list is **configuration**: defaults, editable, and changing it is an
  ordinary act rather than a reinstall
- **per station, not per operator** — a phone may push to two while the node in
  the shed pushes to none
- an indexer **may decline** what it is offered: its disk, its bandwidth, its
  decision
- the station remembers **what each indexer has already had**, as a position in
  its own log; a reconnect resumes rather than re-sends
- **push when the link is cheap** — internet or wire. A blog post that reaches
  the index four hours late has lost nothing, and a station that spends its LoRa
  duty cycle pushing publications has spent it on the wrong thing.

## An indexer is also a mailbox

The sender is usually gone — the phone is in a pocket and the screen is off. An
indexer is the best carrier on the network for store-and-forward: always on,
addressable, and chosen deliberately. So mail is handed to one too, and it tells
the recipient there is something waiting.

- **it is a hold, not an archive**: `until:` bounds it, and the copy is released
  the moment a receipt is heard whose signature verifies — unsigned would let a
  stranger delete other people's undelivered mail from every indexer holding it
- **sealing the body with `x:` is the content's protection**, and it is real:
  the indexer stores something it cannot read. But `t:`, `f:`, `d:` and `ts:`
  stay in cleartext, because a station that cannot see who a packet is for
  cannot deliver it. The indexer learns that X1QZ3N wrote to X1RD89 at that
  minute, and how often. Encryption protects contents; **choosing your indexer
  is what protects the pattern.**

## Asking the author instead

An indexer is a convenience, not a dependency. A station that heard something
and wants the rest asks the author directly with `cmd:history` — already
metered, already refusable with `code:429`, and already the answer to "I was not
here, what did I miss".

---

# The Flutter implementation (Aurora)

## `XprsArchive` — `lib/services/xprs/xprs_archive.dart`

The spool of what this station has heard. On by default: a spool nobody keeps is
a network nobody can catch up on.

- **SQLite**, WAL, `synchronous = NORMAL`. Two tables: `packets` (the §5
  identifier as primary key, plus `ts`/`pts`, type, `fromc`, `toc`, bearer,
  rssi, signature state, via-count, heard-count and the wire) and
  `mailbox_decl` (the `t:mailbox` declarations of §13.12).
- indexes on `pts`, `(fromc, pts)` and `(toc, pts)` — the three shapes a query
  actually takes.
- **duplicates collapse on the derived identifier**, so hearing the same packet
  from three digipeaters costs one row. A copy with **fewer `via:` hops replaces
  one with more**: the zero-hop copy is the closest thing to what the author
  transmitted.
- **the hot path writes nothing.** `admit()` appends to RAM and returns; a 20 s
  timer flushes in one transaction, verifies signatures off the hot path and
  prunes in bounded batches. Nothing blocks the UI isolate for longer than one
  small indexed transaction — `docs/architecture.md`'s standing rule.
- retention is **500 MB / 365 days**, pruned by age first and then by size.
- never spooled: `ping`, `pong`, `receipt`, `result`. `command` **is** kept —
  a command to a sleeping station is mail.

## `XprsHistoryServer` — `xprs_history_server.dart`

The answering half of `cmd:history`: `code:202`, then the **original packets
re-aired unchanged, newest first**, then `code:200` — or `code:206` when that
was one page and more exists, and the requester continues by moving `until:` to
the oldest `ts:` it received. `code:404` for a window not held, `code:429` over
budget.

Airtime is the scarce thing: one replay in flight ever, **12 packets a page, one
every 1.5 s** on a short-TTL advert slot so a replay never camps on the presence
beacons, and token buckets per requester — a station that declared us gets more
than a stranger, and another device of ours is unmetered.

The replayed bytes are **byte-identical** to what was stored: no added `via:`,
no re-signing. An indexer passes on the author's packet.

## Around them

- `XprsIngest` — the single admission point; the `t:mailbox` declarations decide
  which Reticulum-borne traffic may enter at all.
- `XprsPublisher` — publishing across every bearer this device has, with the
  scope rules applied once rather than per bearer.
- the **file** side is not here: it lives in `reticulum-dart`
  (`lib/src/services/files/`), because a DHT is core transport, not app code.

# The ESP32 implementation (T-Dongle)

`esp32/components/geogram_xprsindex/`. Same role, no SQLite, and the reasons are
measured rather than aesthetic — see `docs/esp32.md`.

- the app is ~1.86 MB in a 1,966,080 B partition and the board has **no PSRAM**,
  so a page cache would come out of the SRAM already shared with BLE, WiFi and
  the display. SQLite does not fit, and repartitioning would break OTA for
  deployed dongles.

**The store:** 320-byte records holding the packet verbatim, in `seg_*.bin`
segments of 4096, with a monotonic index and an epoch letter so a client detects
a wiped card and re-syncs.

**Two derived indexes, for the two questions that are actually asked:**

| Question | Structure | Cost |
|---|---|---|
| "the most recent 20 warnings" | `t/<code>.idx` — 4-byte record numbers per type, newest last | a seek, an 80-byte read, 20 record reads. Never grows with the store. |
| "what was sent last year" | `zone.idx` — 16 B per segment: `{first_index, min_ts, max_ts, type_mask}` | binary-search by seeking, then open only the overlapping segments |

Both are **derived**: if either is missing or was truncated by a power cut it is
rebuilt by walking the segments. The segments are the source of truth and the
store is readable without either index.

Measured on the device: 20 recent warnings in **28 ms**, 50 records from a
year-long range in **123 ms**, a record written in **4.7 ms**.

**§36 is enforced in the store, not in the callers.** `xprsindex_query` takes an
`asker`, and a record carrying `d:` is emitted only when it matches. The caller
is a radio protocol; forgetting the rule there would publish other people's
mail. On the GATT path the asker is **self-declared** — there is no
authenticated identity on a write — so it stops a station handing a stranger's
mail to a passer-by, and is not proof of who is asking.

**Serving:** `GET /api/xprs?type=&recent=&since=&until=&from=&asker=&limit=`
over HTTP, and an `xprs_query` command over GATT that pages into one ATT
notification.

**The hardware rules this store had to learn** (all in `docs/esp32.md`, all paid
for in device time):

- decide on the caller's thread — parse, identify, deduplicate — and hand the
  finished record to a queue drained by a task **pinned to core 1**. The BLE
  controller, NimBLE, WiFi and `app_main` are all on core 0; writing from a
  receive path took the radio's processor and the WiFi station could not
  transmit at all.
- drain **in bursts**, not as a trickle, or every other reader of the card
  queues behind the writer.
- take a **mutex**: FatFs is not thread-safe and two tasks write while two
  servers read.
- read the **active** segment through the handle that is writing it, and
  `fsync` it — a file's size lives in a directory entry FatFs only writes on
  sync or close.

---

# Being an indexer

- **It is a decision, not a duty.** Disk, bandwidth and who to carry for are the
  operator's, and refusing is always allowed — including refusing mail while
  still serving publications.
- **You will learn things about people who trusted you with metadata.** Sealed
  contents stay sealed; who talks to whom, and how often, does not. Say so
  plainly to anyone choosing you.
- **Being one is cheap at the edges.** A dongle on a shelf with a microSD is a
  perfectly good indexer for a village; the DHT and pointer-sync roles above are
  for nodes with a real link and a real disk.

## See also

- `docs/XPRS.md` §36 — publishing and indexers, normative
- `docs/XPRS.md` §13.12, §25.2 — `hold:` lists and `cmd:history`
- `docs/store-and-forward.md` — delivery to absent peers
- `docs/folders.md`, `docs/NOSTR.md` — the file and relay layers that use the
  pointer-based index
- `docs/esp32.md` — the constraints behind the dongle's implementation
