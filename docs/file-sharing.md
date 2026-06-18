# File sharing — hosting, finding by hash, finding by text

Aurora shares files **by content, not by location**. A file is named by the
SHA‑256 of its bytes; that hash is what travels in a chat message, what the DHT
indexes, and what the receiver verifies on arrival. No IP address, no URL, and no
central host is ever required.

This document covers:

- how a file is referenced in a chat message,
- the decentralized **resolution tiers** a receiver tries,
- **find‑by‑hash** (DHT) vs **find‑by‑text** (relay full‑text search),
- and the two properties the design depends on, **verified against the code**:
  *decentralized discovery* and *every downloader becomes a seeder*.

Key code: [`shared_media_fetch.dart`](../lib/wapp/shared_media_fetch.dart),
[`file_node.dart`](../lib/services/files/file_node.dart),
[`media_file_source.dart`](../lib/services/files/media_file_source.dart),
[`composite_file_source.dart`](../lib/services/files/composite_file_source.dart),
[`media_archive.dart`](../lib/util/media_archive.dart),
[`rns_service.dart`](../lib/services/reticulum/rns_service.dart).

---

## 1. How a file is referenced in chat (APRX §16)

When you attach a file, Aurora hashes the bytes, stores them in a
content‑addressed archive, and puts only **short, location‑independent tokens**
into the message text:

```
file:<sha256-b64url-43>.<ext>     what the file is (hash) + how to render it
sz:<bytes>                        size hint (for the size badge / auto‑download)
ih:<40hex>                        optional BitTorrent infohash (which swarm)
```

The hash is both the **identity** and the **integrity check** — a receiver only
accepts bytes whose SHA‑256 matches. See [aprx.md](aprx.md) §16 for the exact
token grammar.

## 2. The content‑addressed archive (`media_archive.dart`)

`MediaArchive` is a local SQLite store keyed by `sha256`. `putBytes(data, ext)`
writes the file and returns its `file:` token; `has(sha)` / `getBytes(sha)` read
it back. This archive is the single source of truth for "what this device can
serve", and it is wrapped as a Reticulum **file source**:

- `MediaFileSource(archive)` exposes `read(hash) → bytes` from the archive.
- `CompositeFileSource([MediaFileSource(archive), diskFolderRegistry])` lets a
  device *also* serve files straight from on‑disk shared folders without copying
  them into SQLite.

`RnsService` registers this as `fileServeSource`, so anything in the archive (or
a shared disk folder) is automatically reachable over Reticulum by its hash.

## 3. Serving — the responder side (`file_node.dart`)

`FileTransferNode` answers two kinds of incoming Reticulum link:

- on `geogram/dht` → DHT RPCs (see [dht.md](dht.md)),
- on `geogram/files` → file requests: it reads the bytes from the
  `CompositeFileSource`, ships them as a Reticulum **Resource**, and fires
  `onServed(hash)` (which bumps a download counter and serve stats).

Serving is gated by `ServeQuota` (`serve_quota.dart`) — a default **1 GB/day**
budget plus an off switch — so a phone can't be drained. A node that's over
budget simply stops advertising and resolvers route around it.

## 4. Resolution tiers — the receiver side (`shared_media_fetch.dart`)

When a chat message references a file the device doesn't already hold,
`maybeFetchSharedMedia` runs `_resolve`, trying **decentralized paths first**:

| Tier | Path | Central server? |
|------|------|-----------------|
| 1 | **Local cache** — `archive.has()` | n/a (already have it) |
| **R1** | **Reticulum, direct from the sender** by callsign | No — sender is a holder; its route was learned from its chat announce |
| **R2** | **Reticulum DHT** — `dhtResolveFetch(sha)` resolves providers, multi‑source fetch | No — peer‑to‑peer DHT, no index |
| 2 | **LAN Blossom** — known local servers (no per‑message scan) | Local‑only |
| 2.5 | **I2P** — fetch from the sharer, else content‑route to any provider | No |
| 4 | **BitTorrent** — join the swarm via `ih:` | No (DHT + trackers) |

> **There is deliberately no public‑Blossom tier.** Aurora never depends on a
> third‑party central content host. (An earlier build had a public‑Blossom
> fallback; it was removed.) Cross‑NAT reachability comes from the Reticulum
> **hub**, which *relays transport packets* — it never sees or indexes content.

### Why R1 before R2

On a big *foreign* public Reticulum network the XOR‑closest DHT nodes to a file
key are reference nodes that ignore Aurora's overlay, so DHT resolution can come
up empty there. The **sender is, by definition, a holder** of the file it just
referenced, and you already learned its route from its announce — so a direct
fetch from the sender is the most reliable cross‑network path. R2 (the DHT) is
what lets you fetch from *other* holders once the overlay exists.

---

## 5. Verified property #1 — every downloader becomes a seeder

After `_resolve` succeeds (by *any* tier), the bytes are in the archive, and the
fetch path calls `_reseed`:

```dart
// shared_media_fetch.dart
void _reseed(MediaRef ref, MediaArchive archive) {
  final shaBytes = _sha256Bytes(ref.sha256);
  if (shaBytes == null) return;
  if (!RnsService.instance.isUp) return;
  if (!archive.has(ref.sha256Hex)) return;   // only advertise what we can serve
  unawaited(RnsService.instance.dhtPublish(shaBytes));
}
```

`dhtPublish` → `FileTransferNode.publishProvider` signs a provider record and
STOREs it at the k DHT nodes closest to the file's key, **and registers it for
the 30‑minute republish loop**. From that moment the downloader:

1. is discoverable as a provider of that hash (DHT `resolve` returns it), and
2. actually serves the bytes from its archive over `geogram/files` (§3).

So a file shared into a group gains a new holder with **every** download, and the
swarm of holders grows without any central coordinator. The original **sender**
also auto‑seeds (it publishes on attach), and **shared disk folders** auto‑seed
every file on each sync — but the key fix is that *plain downloaders* now seed
too, which they previously did not.

> Re‑seeding is gated the same way serving is: it only publishes when the node is
> on the network *and* the bytes are actually in the archive, so a device never
> advertises something it can't deliver. The daily serve quota still bounds how
> much it ultimately uploads.

## 6. Verified property #2 — decentralized discovery (find‑by‑hash + find‑by‑text)

### Find‑by‑hash (DHT)

You already know the hash (it's in the message, a folder entry, or a search
result). `dhtResolveFetch(sha)` walks the Kademlia DHT to the providers of that
hash and fetches in parallel — no central index. Full detail in [dht.md](dht.md).

### Find‑by‑text (social relay, `lib/services/social/`)

To discover a file you *don't* have the hash for, Aurora runs a NOSTR‑style relay
with a **SQLite FTS5** full‑text index (`relay_event_store.dart`):

- A file is published as a **kind‑1063 metadata event**: tags
  `['x', <sha256>]`, `['name', …]`, `['m', <mime>]`, `['t', <topic>]`, with a
  free‑text description as the content.
- The relay indexes the content **and** the tag values (file name, topic, mime…)
  into an `events_fts` virtual table (`tokenize = 'unicode61'`).
- `relaySearch(text)` runs `events_fts MATCH …` ranked by `bm25()` (best match
  first, ties broken by recency) and returns the matching events.
- A node queries the **best peer indexer over a Reticulum link**
  (`RelayNode.query`, NIP‑01 filter + NIP‑50 `search`), falling back to its local
  store — again, no central index.

### How they complement each other

```
  find‑by‑text                         find‑by‑hash
  ────────────                         ────────────
  relaySearch("…")  ──→  kind‑1063 event  ──→  sha256  ──→  dhtResolveFetch(sha)  ──→  bytes
  (FTS over the relay)   (metadata + hash)      (id)        (DHT providers, multi‑source)
```

**Discovery** (which file?) is decoupled from **delivery** (who has the bytes?):
text search on relay indexers finds the hash; the DHT finds the holders. Neither
step needs a central server.

## 7. Mutable folders — a directory layer on top

Files are immutable (a hash is forever a single set of bytes). To publish a
*changing* collection, Aurora has **mutable folders** (`lib/services/folders/`):

- A folder is identified by a **secp256k1 public key** (`folderId`).
- Its contents are a **signed op‑log** of NOSTR events
  (`addFile`/`rmFile`/`setMeta`/`link`), reduced to a current `name → (sha256,
  metadata)` map. The master key delegates write access to **admins**; revoking
  an admin stops only their *future* edits.
- The folder is discovered **by key** over Reticulum (IPNS‑like): a holder
  publishes a DHT provider record for the folderId; a browser resolves providers
  and queries them for the signed events. No central index.
- **Disk folders** let an owner serve a real on‑disk directory by sha256 without
  copying into SQLite; consumers subscribe and optionally auto‑sync newer
  versions of files they've already downloaded.

So a folder is a **mutable directory pointing at immutable, content‑addressed
files** — the mutable part is signed and key‑addressed, the file bytes are the
same hash‑addressed, re‑seedable objects described above.

---

## 8. Summary of guarantees

- **No central content index.** Holders are found by walking a DHT toward the
  file's hash (find‑by‑hash) or by querying peer relay indexers (find‑by‑text).
  The only shared infrastructure is a Reticulum hub that *relays bytes*.
- **No third‑party content host.** The public‑Blossom tier was removed; content
  travels over Reticulum / LAN / I2P / BitTorrent.
- **Integrity by construction.** Every fetched file is verified against its
  SHA‑256 before use, so a malicious provider can at worst waste a round trip.
- **The swarm grows with use.** Sender, disk‑folder owner, *and every
  downloader* publish provider records and serve the bytes — bounded only by the
  per‑node daily serve quota.
