# Torrents over Reticulum

A torrent client where **the unit of sharing is a folder, not a file**, the
tracker is the **Indexer mesh** ([NOSTR.md](NOSTR.md)), the swarm is
**Reticulum**, and the "info hash" is a **public key** instead of a digest of the
contents.

Nothing here is a new network. The pieces already exist: mutable folders
(`lib/services/folders/`, [folders.md](folders.md)), the content-addressed file
layer and DHT (`lib/services/files/`), the Indexer role and provider records
(NOSTR.md). The **Torrents wapp** (`wapps/torrents`) is the torrent-client
face on top of them, plus one genuinely new storage backend: a **per-folder
SQLite database** so a shared folder need not exist as files on disk.

---

## 1. The one difference from BitTorrent

| BitTorrent | Aurora torrents |
|---|---|
| Info hash = SHA-1 of the metadata | **Folder id = an npub** (secp256k1 public key) |
| Changing a file changes the info hash → a new torrent | The npub **never changes**; the contents change under it |
| `.torrent` file / magnet link, distributed out of band | The **signed op-log** is fetched from the swarm itself |
| Tracker / DHT keyed by content | **Indexers** keyed by the folder npub *and* by each file's sha256 |
| Anyone with the info hash can seed; nobody can update | Anyone with the npub can **read and seed**; only the **nsec holder** (and admins they signed in) can **publish an update** |

**The folder hash is not a hash of the folder.** It is the folder's public key.
The author holds the nsec; the npub is the address other people use to find the
folder *from that publisher*. That is what makes a torrent **updatable**: the
publisher adds a file, signs one more op, republishes — and every seeder and
downloader converges on the new state under the same address. No new magnet
link, no re-sharing, no dead torrent.

The **files** inside are still content-addressed exactly like BitTorrent: sha256
per file, verified on arrival, fetchable from anyone. Mutability lives in the
directory; immutability lives in the bytes. That split is the whole design.

```
   npub1folder…        ← the "info hash"; stable forever, key-derived
        │
        │  signed op-log (kind 1064 ops + kind 30564 keyset)
        ▼
   name → sha256 + size + metadata          ← the "torrent file", rebuildable
        │
        ├── file a → sha256 aaaa…  ← immutable, content-addressed
        ├── file b → sha256 bbbb…
        └── file c → sha256 cccc…
```

---

## 2. Where the bytes live: disk-backed vs database-backed

Two backends for the same folder abstraction. A torrent is one or the other, set
at creation time, and both look identical on the wire.

### Disk-backed — "share this directory"

The user picks a directory. The wapp scans it, hashes each file, and builds the
op-log from what it finds. The bytes stay where they are; the wapp owns no copy.
A rescan diffs the directory against the reduced state and emits add/rm ops for
what moved. This is `disk_folder.dart` / `disk_folder_manager.dart` today.

Right for: a media library, a photo directory, anything the user already
organises with a file manager and wants to keep organising that way.

### Database-backed — one SQLite per shared folder

The folder has no directory. Its contents live in a SQLite database owned by the
Torrents wapp, **one database per shared folder**:

```
<profile>/torrents/<folderId>.sqlite3
```

One file per folder is a deliberate performance decision, not tidiness. A single
shared database would put every torrent's blobs, every op, and every piece
bitmap in one write path, one page cache, one `VACUUM`, and one lock — and a
100 k-file archive would tax a 12-file folder. Separating them means: a torrent
is one file you can move, back up, delete or hand to another device wholesale;
a corrupt torrent cannot take the others with it; the page cache of the folder
you are actively downloading is not evicted by the one that is merely seeding;
and unpinning is `rm one.sqlite3`, not a delete sweep.

Schema (per folder DB):

| Table | Holds |
|---|---|
| `meta` | folderId, share type, name, description, our role (owner / pinned / partial), created, last verified |
| `events` | the signed op-log: kind 1064 ops + kind 30564 keysets, raw, verifiable |
| `entries` | reduced state: `name → (sha256, size, ext, mtime, metadata)` — a materialised view of `events`, rebuildable at any time |
| `blobs` | `sha256 → bytes` (or `sha256 → external path`, for a disk-backed folder that pins only some files) |
| `pieces` | per-file piece bitmap: which 64 KiB chunks of a partially-downloaded file we hold, so a resume costs nothing |
| `peers` | providers last seen for this folder, with their node profile — a warm start that skips the first DHT resolve |

Right for: content that has no natural place in the filesystem (a feed of small
files, a message archive, a set of thousands of blobs), an Android device where
the SAF makes real directories painful, and any folder the user *pinned* rather
than authored.

**Blobs are shared where possible.** A file the device already holds in the
media archive (`media.sqlite3`) or another folder is referenced by sha256 rather
than copied — a torrent DB stores the bytes only when it is the only holder on
this device.

---

## 3. Creating a torrent

1. **Generate the key.** `create` mints a secp256k1 keypair. The npub is the
   folder id and the shareable address; the nsec goes into the keystore
   (`folder_keystore.dart`) and **never leaves the device** — never into the DB
   that gets shared, never into a backup someone else can host. Copying the key
   file to another machine is handing over write authority, not "seeding".
2. **Choose the backend** — a directory on disk, or a new per-folder SQLite.
3. **Hash the contents.** sha256 per file, on a background isolate. Big files are
   hashed in 64 KiB pieces and the piece hashes are kept, so a later
   partial/parallel download can verify a chunk without holding the whole file.
4. **Sign the op-log.** One `addFile` op per entry — `{name, x: sha256, ext,
   size}` — signed with the folder nsec, appended to `events`.
5. **Announce.** Publish a provider record under the **folder npub** *and* one
   under **each file sha256**, to the DHT and to the Indexers we know
   (`publishKey`). Those two keys are what the tracker answers on: *who has this
   folder* and *who has this file*.
6. **Share the `nfolder1…`.** Chat message, QR, copy button. It is the magnet
   link: the folder key plus a few swarm hints and the author, bech32-encoded
   under its own `nfolder` prefix so any parser — the chat wapp, the OS, another
   client — knows on sight that this is a torrent folder and not a person. See
   §11. A bare `npub1…` is still accepted, it is just slower to cold-start.

**Updating** is step 4 and 5 again: add an op, republish. Every seeder that has
`autosync` on pulls the new op, fetches the new bytes, and starts seeding them.
The torrent never dies and never forks.

---

## 4. Downloading a torrent

The client is the ordinary torrent loop, with Reticulum in place of TCP and
Indexers in place of a tracker.

1. **Resolve the folder.** Ask the **best Indexer** (`bestIndexer()`, scored by
   interest match, capacity, hops, freshness) for the folder npub. It answers
   with a **list of holders**, and per holder — this is the part a bare peer list
   would be useless without — the node profile from NOSTR.md §"What an Indexer
   actually answers": last-heard and its provenance (heard directly vs learned
   from another Indexer), power source and uplink, capacity class, radios and
   listening schedule, coverage region.
2. **Pull the op-log**, reduce it, and show the user the file list *before*
   downloading a byte. This is the `.torrent` — except it was fetched from the
   swarm and it is signed, so a hostile holder cannot alter the listing.
3. **Rank the swarm.** The rule is the one from NOSTR.md and the user would call
   it fair: **an awake machine on mains and WiFi first; a battery phone on
   cellular last, and only if nothing else has it.** An Archiver that volunteered
   is *supposed* to be the one that gets called — that is the reward for
   volunteering.
4. **Fetch in parallel, from many peers at once.** Per file: resolve the sha256
   (a separate DHT key, so a file present in several folders is served by all of
   their seeders), then split it into 64 KiB pieces and **request different
   pieces from different providers concurrently**, over independent RNS links —
   rarest-first across the swarm, with the per-peer request window sized by that
   peer's capacity class and measured throughput, not a fixed constant. A slow
   LoRa holder is given the tail; a fibre Archiver is given the bulk. Pieces are
   verified against the piece hash on arrival and written into `pieces` +
   `blobs`, so a peer that stalls or lies is dropped and its outstanding pieces
   re-issued elsewhere. A dead provider is demoted in the DHT (`demoteProvider`)
   so the next caller does not repeat our mistake.
5. **Verify and complete.** Whole-file sha256 must match the op-log entry, or the
   file is discarded and refetched.
6. **Seed.** A completed download is republished as a provider record — for the
   folder and for each file we now hold. Downloading *is* joining the swarm; the
   default is on, and a device that only leeches is a setting the user had to
   change on purpose.

`partial_store.dart` already carries the resume machinery; the piece bitmap in
the per-folder DB is where it lands.

---

## 5. Pinning

**Pinning is the Archiver decision, made per folder, by a user who saw a torrent
they care about.**

Pin a folder and the device: downloads everything under it, keeps it against
eviction (retention tier 0 — a pinned folder is never evicted for a stranger's
junk), follows the op-log so an update is fetched automatically, and — the
point — **reports itself to the Indexers as a holder**, for the folder key and
for every file sha256 in it, republished every 30 min against the 45-min record
TTL.

That report is what makes pinning worth anything to anyone but the pinner: a
folder with five pins has five entries in every Indexer's who-has map, and the
publisher's phone stops being the single point of failure it was the day the
folder was created. **A pin is a vote that the thing should survive.**

Pinning obeys the quotas that already exist:

- **Storage** — `HostQuota` / the Archiver's disk ceiling. A pin that would blow
  the ceiling is refused loudly, not silently trimmed.
- **Bandwidth** — `ServeQuota`, identity-aware. My devices and people I follow
  are unmetered; strangers share a daily byte budget; a phone on cellular serves
  strangers **nothing** by default. Over budget, a node does not go dark: it
  answers *"not me, try one of these"* and hands back the other providers.
  Seeding is generosity, not a tax.

Unpin = drop the provider records, delete `<folderId>.sqlite3` (or forget the
disk path). One file, one delete.

---

## 6. What the Indexers answer

Two questions, two keys, one mechanism — the existing DHT + provider-record
layer, which stores **pointers only, never content**.

| Question | Key | Answer |
|---|---|---|
| *Who has this folder?* | the folder **npub** (32 bytes) | signed provider records + node profiles |
| *Who has this file?* | the file **sha256** (first 16 bytes) | the same, across every folder containing it |

A `ProviderRecord` is ~176 B, Ed25519-signed by the provider, TTL 45 min,
republished at 30 — so a seeder that goes away leaves the tracker by itself, with
nobody to garbage-collect it and nobody to bribe to stay in. Indexers sync their
maps with each other (fast, wired, spares the phones), and they anchor the DHT.
An Indexer that dies costs the swarm a directory, not an archive.

**An Indexer never sends file bytes.** It says *these N devices have it*, and it
says enough about each of them that the client can choose well.

---

## 7. The wapp

`wapps/torrents`, id `tools.geogram.torrents`. Like every wapp, the code lives in
the `geograms/wapps` repo; aurora is the engine (see the HAL rule: no
torrent-specific logic in `lib/` — it belongs in the wapp's C + GeoUI, on top of
generic host HALs).

| Screen | Shows |
|---|---|
| **Torrents** | one row per folder: name, size, files, ▲ seeders / ▼ leechers from the Indexer, our state (owner · pinned · downloading 43% · seeding), the transport that is serving us |
| **Detail** | file list from the reduced op-log, per-file progress, the swarm — each holder with its profile (mains/battery, WiFi/cellular/LoRa, last heard and *how* we know), and which peers our pieces are coming from right now |
| **Create** | pick a disk directory *or* a new database folder, name it, mint the key, hash, publish. Copy/QR the npub |
| **Open by id** | paste an npub → resolve → listing → download |
| **Settings** | pin list, disk ceiling, stranger bandwidth budget, serve-on-cellular, piece size, max parallel peers per file |

HAL: the folder HALs already exist (`hal.folder_create/list/edit/browse/stats/
remove/opendir/add_disk/rescan/download/autosync/owned/subs`) plus the generic
`hal_sqlite`. What is missing is generic and belongs in the host: a **piece-level
parallel fetch** (`folder/download` today pulls a file from one provider), a
**swarm/peer-status** read so the wapp can render who is serving us, and a
**database-backed folder source** alongside the disk one.

---

## 8. Build order

1. **Database-backed folder source** — the per-folder SQLite, `FolderSource`
   interface with disk and DB implementations behind it. Everything else already
   works against the folder abstraction.
2. **The piece engine** — the actual torrent, and the only genuinely new
   networking. Four parts, and the first three are what separate a swarm from a
   download queue:
   - **Signed piece hashes.** The `addFile` op carries a merkle root (or the
     piece-hash list) over the file's 64 KiB pieces, signed by the folder key.
     Without it a piece from a stranger is only verifiable *after* the whole file
     lands — one hostile holder wastes the entire transfer. With it, every piece
     is verifiable in isolation, which is what makes fetching from strangers in
     parallel safe at all.
   - **Partial holders seed.** The provider record advertises a **piece bitfield**
     ("folder npub, file sha, pieces 0–412 of 900"), not just whole files. A
     leecher uploads what it already has, exactly like BitTorrent. Without this a
     50-peer swarm has one uploader — the publisher — and the design's whole
     redundancy claim is false while the download is in flight, which is the only
     time it matters.
   - **Endgame mode.** For the last few outstanding pieces, request each from
     *every* peer that has it and cancel on first arrival. Otherwise a download
     sits at 98 % behind one slow LoRa holder.
   - Then the ordinary loop: multi-provider concurrent requests, rarest-first,
     per-peer window sized by capacity + measured throughput, verify per piece,
     drop and re-issue from a liar, `demoteProvider` a dead one.
3. **Swarm view** — expose the resolved holders + their profiles to the wapp; the
   Indexer already returns them, nothing renders them.
4. **Pin as a first-class state** — the report loop, the quota checks, the
   retention pin.
5. **The wapp UI** — the five screens above.
6. **Live validation on different networks.** Same-LAN is a false positive: the
   RNS "via lan" shortcut is not the path a real swarm takes. Phone on cellular,
   desktop on wired, ≥3 seeders, one of them killed mid-download to prove the
   client re-issues its pieces elsewhere.

## 9. Honest state of the ground it stands on

- **The wapp itself** (`wapps/torrents`, id `tools.geogram.torrents`): **built**.
  The five screens, the disk-backed create path, open-by-link, download, pin, and
  the swarm view. It autostarts in the background (aurora's
  `_defaultAutostartWappIds`), because a seeder that only serves while its page is
  open is not a seeder. Live-checked on Linux: the wapp installs, starts, ticks,
  and a directory turned into a torrent produced a signed op-log with per-file
  sha256s.
- **`nfolder1…`** (§11): **built and unit-tested** (`lib/services/folders/nfolder.dart`,
  `test/nfolder_test.dart`) — round-trip, hints, author, a bare npub still
  opening a folder, and a mangled link failing closed rather than resolving
  somewhere else.
- **The three new host HALs** — `folder_link`, `folder_swarm`, `folder_pin`:
  **built**. `folderSwarm` answers from a cached snapshot and refreshes the DHT
  resolve in the background (60s TTL, misses cached), ranked by the NOSTR.md
  rule: mains + a fat uplink first, a battery phone on cellular last.
- **The database-backed folder source (§2) is NOT built.** Today a torrent is
  disk-backed; the per-folder SQLite is item 1 of the build order.
- Mutable folders, the op-log, the reducer, the capability boundaries: **built and
  tested**.
- The DHT, provider records, Indexer selection, node profiles, quotas: **built**,
  and the DHT is live-validated across networks.
- File transfer over RNS: **at parity with reference RNS** for a single-provider
  fetch (45 MB sha-exact, both directions). **Multi-provider parallel fetch does
  not exist yet** — that is item 2, and it is the heart of this wapp.
- The known device-to-device folder-byte gap in [folders.md](folders.md) §6 is on
  the same path this wapp depends on. It must be closed, or a torrent between two
  phones will list and never transfer.

---

## 10. Parity with a normal client

Everything above describes a swarm. A *client* is what a user compares against
qBittorrent, and the difference is mostly this list. Items marked **engine** are
in §8 step 2 and are not optional — without them the swarm is a download queue
with extra steps.

### Swarm behaviour

| Item | Why it matters here |
|---|---|
| **Signed piece hashes** (engine) | verify a piece from a stranger without the whole file |
| **Partial holders seed** (engine) | a leecher uploads what it has; otherwise the publisher is the only source for the entire life of the download |
| **Endgame mode** (engine) | duplicate-request the last pieces, cancel on first arrival |
| **Choking / fairness** | the quotas answer *how much* we give strangers, never *which* stranger. A swarm of pure leechers is currently stable and useless. Rank requesters by what they served **us**, keep one **optimistic-unchoke** slot so a newcomer with nothing can still bootstrap. This is tit-for-tat, and it is the only thing that makes seeding rational rather than charitable |
| **Availability** | the minimum number of copies of the rarest piece across the swarm. Shown per torrent, because `0.7` means *this folder is dying and nobody has told you* |
| **PEX** | peers gossip their peer lists, so a swarm survives every Indexer being unreachable |
| **LSD** | LAN broadcast peer discovery — the LAN bus already exists; a co-located peer should never need the mesh |
| **Web seed (BEP-19)** | **Blossom is already this.** A content-addressed HTTPS blob is a web seed; use it as the fallback tier when the swarm is cold, subject to the Reticulum-first rule (mesh first, internet only on timeout, switchable off) |
| **Private swarm** | a flag that suppresses PEX/DHT gossip: the folder is discoverable only through the Indexers the owner named. Pairs with `private` share type |
| **Ban list** | drop a peer that serves bad pieces, persistently, per torrent |

### Client behaviour

| Item | Notes |
|---|---|
| **Pause / resume / stop / recheck** | force-recheck rehashes local data against the signed hashes and refetches what is wrong — bit-rot, a killed write, a half-flushed DB |
| **Queue** | max N active torrents, max N downloading, start order; the rest queued, not all thrashing one radio |
| **Selective download + priorities** | deselect a file, high/normal/low, and **sequential mode** so mp4player can play while the tail is still arriving |
| **Speed limits** | global and per-torrent, up and down, plus **alternative limits on a schedule**. Half of this exists in `ServeQuota` (daily byte budget, zero-on-cellular); it needs rate limits, not just totals |
| **Seed goals** | stop at ratio X, or after N days; otherwise seed forever. A pin overrides — a pinned folder seeds regardless of ratio, because the pin *is* the goal |
| **Stats** | up/down rate, ETA, ratio, total up/down, and a peer count that distinguishes **complete holders from partial** (a "seeder" that has 3 % is not a seeder) |
| **Storage** | incomplete-dir vs completed-dir, move storage, "delete torrent" vs "delete torrent **and** data", and a real disk-full path that pauses rather than corrupts |
| **Watch folder / auto-add** | drop an npub in a list (or a file in a directory) and it downloads |
| **Labels** | categories, filters, sort. Free, and the difference between 6 torrents and 600 |
| **Deep links** | `geogram://folder/<npub>` (and a bare `npub1…`) handled as a magnet link from chat, QR, or the OS |
| **Creation params** | piece size, exclude patterns, follow-symlinks, file ordering |

### Deliberately absent

- **Port forwarding / NAT traversal / UPnP** — Reticulum's problem, already solved.
- **Protocol encryption / obfuscation** — every RNS link is encrypted; there is no
  plaintext mode to hide.
- **IP blocklists** — there are no IPs. A ban is by pubkey.
- **Trackers as infrastructure** — no announce URLs, nothing to seize, nothing to
  pay for. Indexers self-nominate and expire on their own.

---

## 11. The link: `nfolder1…`

The magnet link. A NIP-19-style TLV bech32 string with its own human-readable
prefix, so a link parser knows what it is holding **before** it knows anything
about the network.

```
nfolder1qqsrq…               ← paste anywhere: chat, QR, a note, the clipboard
geogram://folder/nfolder1qqsrq…   ← the OS deep link
```

### Why not just the npub

A bare public key is 32 bytes and nothing else, and that costs three things:

- **No swarm hints.** A cold receiver would have to walk the DHT to find *anyone*
  holding the folder. The sharer already knows several holders — the link is the
  free place to say so. Every other NOSTR pointer solved exactly this:
  `nprofile` = npub + relay hints, `nevent` = id + hints, `naddr` = kind:pubkey:d
  + hints. Same problem, same shape.
- **Ambiguity.** `npub1…` means *a person* everywhere else in this app. Reusing it
  for a folder forces the chat wapp, the profile panel and the deep-link handler
  to guess what a key is for. A distinct prefix resolves that in the parser, not
  in the semantics.
- **No author.** The folder key is minted per folder — it is *not* the publisher's
  identity key. Without the author npub in the link, "published by X" cannot be
  shown, and X's kind-0 cannot be fetched, until after a full resolve.

### Encoding

HRP `nfolder`, bech32, NIP-19 TLV body:

| T | V | |
|---|---|---|
| `0` special | 32-byte **folder pubkey** | required, exactly one |
| `1` hint | 16-byte **RNS destination hash** of a known provider or Indexer | repeatable, 0..n |
| `2` author | 32-byte **npub of the publisher** | optional |
| `3` kind | uint32 | optional; reserved, so a later pointer variant needs no new HRP |

A cold client tries the `1` hints **before** the DHT walk, and falls back to the
walk when they are stale — which they will be, because a hint is a snapshot and
the swarm moves.

### What the link can and cannot do to you

Hints and the author are **unsigned**. That is fine, and it is the same trust
model as an `nprofile` relay hint: a hostile sharer can make you dial a peer that
turns out not to have the folder — costing one failed link — but they **cannot**
alter the listing, because the op-log is signed by the folder key, and the folder
key is TLV `0` of the very link they handed you. The worst case is a wasted
round-trip.

**The folder name is deliberately not in the link.** An unsigned name in a
shareable string is a phishing surface ("Ubuntu ISOs"), and the real, signed name
arrives with the op-log a second later. Until it does, the UI shows the truncated
key — never a name it cannot prove.

### Parsing rules

- `nfolder1…` → folder pointer. Hints and author used as given.
- `npub1…` → still accepted as a folder pointer with **zero hints and no author**.
  It works; it is just the slow cold start. This keeps every link ever shared
  before this section valid.
- `geogram://folder/<nfolder|npub>` → the same, from the OS.
- An `nfolder` with an unknown TLV type is **not** an error: unknown types are
  skipped, so the encoding can grow without breaking old clients.
