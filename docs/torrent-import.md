# Importing an internet torrent into an ntorrent (plan)

> Status: **planned, not implemented.** Both halves it needs already exist
> host-side; this doc plans the glue. See `docs/torrents.md` for ntorrents
> themselves.

## The idea

Let a user paste a normal magnet link or open a `.torrent` file, have the app
**download it from the public BitTorrent swarm**, and then **re-share it as an
ntorrent over Reticulum** — a folder-torrent addressed by a key, browsable and
resilient (`torrents.md`). The internet torrent is the *source*; the ntorrent is
what we actually publish and seed.

**Scope, chosen deliberately: download only.** We leech from BitTorrent, verify,
disconnect, and re-share exclusively on Reticulum. **We do not re-seed to the
public BitTorrent swarm.** This is both a policy choice (we are a Reticulum app,
not a BitTorrent seedbox) and a practical one — see Mobile below.

## Both halves already exist

1. **Download — `TorrentService`** (`lib/services/torrent_service.dart`) already
   wraps the vendored `dtorrent_task_v2` (`third_party/dtorrent_task_v2`): magnet
   / infohash → `MetadataDownloader` (BEP-9) → `TorrentTask` → verify. It runs on
   the host isolate over `dart:io` sockets, so it works on desktop and Android.
   - **Gap to close:** today's `fetch()` is **single-file, content-addressed**
     (built for the media archive / Files wapp). A real torrent is **multi-file**.
     The plan adds a folder-aware `fetchToDir(magnetOrTorrentPath, destDir, {onProgress})`
     using `TorrentTask.newTask(model, savePath)` that writes the whole file tree
     under `destDir` and **stops on completion** (leech-only: download, verify,
     disconnect — never announce ourselves as a BT seeder).

2. **Convert — `RnsService.folderAddFromDisk(dir)`**
   (`rns_service.dart` → `disk_folder_manager.dart:139`) already turns a directory
   of files into a shared ntorrent: mints the folder key, hashes every file, emits
   the signed op-log, advertises providers, seeds over Reticulum. One call.

3. **Carry the name / artwork** — after `folderAddFromDisk`, call
   `RnsService.folderSetMeta(folderId, FolderMeta(title: torrentName))` (the
   torrent's display name, from `TorrentModel.name` or the magnet `dn=`), and
   optionally `folderSetMedia` for a cover. The file list is carried
   automatically — the add-from-disk scan hashes and publishes every file already
   on disk. Listing structure: `folder_meta.dart` / `torrents.md §12`.

## The flow

```
paste magnet / open .torrent
        │  TorrentService.fetchToDir(src, <downloadRoot>/<name>/)   ← host, BitTorrent
        ▼
files on disk (verified), BT connection dropped
        │  RnsService.folderAddFromDisk(dir)                        ← host, generic
        ▼
an ntorrent you own → folderSetMeta(title: name) → seeding on Reticulum
```

The download lands under the **download library root** (`torrents.md §13`), so the
result appears in the normal torrents list and can be organized like any other.

## Shape (the HAL-separation rule)

A WASM wapp **cannot open sockets or run a swarm**, so the BitTorrent engine must
be **host-side** — which it already is (`TorrentService`, behind a capability
seam). The importer is therefore a **thin wapp** driving generic host HALs:

- a new generic `torrent_import(magnetOrPath)` → starts `fetchToDir`, reports
  progress, and on completion calls `folderAddFromDisk` + `folderSetMeta`;
- reuse the existing `folder_add_disk`, `folder_download_root`, `folder_set_meta`.

No torrent-specific vocabulary enters the core; the wapp owns the UX (paste box,
progress, "now sharing on Reticulum").

## Mobile / networking

Because we **only download**, the usual mobile blocker disappears: pulling from a
BitTorrent swarm is **outbound** and works fine behind symmetric CGNAT (the case
that breaks *seeding*, `docs/performance.md`). A phone can import; it simply never
tries to be dialable by BT peers. Desktop-first for throughput, but Android is
viable for the download leg. The re-share leg is ordinary Reticulum seeding
(`torrents.md §5`).

## Privacy

The ntorrent we publish should not expose who imported it:

- **The author npub is off by default** in the shared link (already implemented —
  `RnsService.folderLink` omits it unless the user opts in via the torrents
  Settings toggle). So an imported-and-reshared torrent carries the folder key
  and nothing that names a person.
- Deeper anonymity (unlinkable seeding across folders) is a broader ntorrent
  design axis, not specific to import: the honest position is that Reticulum gives
  **no IPs + encryption + pseudonymous keys** (far better than clearnet
  BitTorrent), but the provider "who-has" map is still a correlation surface for a
  determined adversary. The first concrete step, when we choose to harden it,
  would be **ephemeral per-folder serving destinations**. Out of scope here; noted
  so import is not mistaken for anonymity.

## Safety

A dual-use download tool — strictly **user-initiated**, no auto-fetch, no
background crawling. The user pastes a specific link; the app downloads that and
nothing else.

## Not built

Everything above. The reusable calls (`TorrentService.fetch`,
`folderAddFromDisk`, `folderSetMeta`) exist; the new work is `fetchToDir`
(multi-file, leech-only), the `torrent_import` HAL, and the importer wapp UI.
