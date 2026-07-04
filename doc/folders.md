# Shared folders over Reticulum

Aurora shares directories of files between devices as **mutable folders**: an
IPNS-like, key-addressed directory whose contents are a signed, append-only log
of NOSTR events pointing at immutable, content-addressed (SHA-256) files. Any
number of devices can re-host and seed a folder torrent-style. This doc is the
aurora-side operational guide; the cryptographic spec lives in
[`reticulum-dart/doc/mutable-folders.md`](../../reticulum-dart/doc/mutable-folders.md)
and the file layer in [`file-sharing.md`](../../reticulum-dart/doc/file-sharing.md).

Code: `lib/services/folders/` (`folder_event.dart`, `folder_state.dart`,
`folder_service.dart`, `folder_relay.dart`, `disk_folder_manager.dart`,
`folder_keystore.dart`, `folder_subscriptions.dart`). Facade:
`RnsService` (`lib/services/reticulum/rns_service.dart`, `folder*` methods).
UI: the **Files** wapp (`wapps/files`).

## 1. Identity and capabilities

A folder is a secp256k1 keypair.

- **`folderId`** = the master public key (x-only, 64 hex). Its `npub1…` is the
  permanent, shareable address. Sharing it lets others **read and host**; it does
  NOT let them change the folder.
- The master **private** key is the folder's write root, held only by the owner.

| Capability            | Requires                                          |
|-----------------------|---------------------------------------------------|
| Read / list the files | the public `folderId` (npub) — no permission step |
| Host / seed the bytes | the public `folderId` + the content (no key)      |
| Edit (add/remove file)| be the master, or an admin in the master keyset   |
| Add/remove admins     | the master private key (owner only)               |

Two event kinds: `KEYSET` (kind 30564, the master-signed admin list) and `OP`
(kind 1064, one edit each: addFile / rmFile / setMeta / link / unlink).
`reduceFolder` (`folder_state.dart`) applies an op only if it carries the
folder's `d` tag, its signature verifies, and its author was authorized **at the
op's timestamp** — the master, or an admin whose keyset entry covers that time.

## 2. Reading is open; writing is granted

**Reading/joining needs no key and no permission.** A peer with only the
`folderId` resolves providers (via the DHT, keyed by the folder's public key),
pulls the signed keyset + op events, reduces them to the current
`name → (sha256, metadata)` map, then fetches each file by its SHA over
Reticulum and verifies it against the hash. It can then re-serve those bytes and
relay those signed events — a host proves nothing (integrity comes from the SHA
and the event signatures).

**Writing is granted out-of-band.** The owner adds a member's npub to the
master-signed keyset (`grantAdmin`); that member thereafter signs ops with their
own profile key, which the reducer now authorizes. Revocation is forward-only —
a removed admin's earlier, legitimately-signed edits remain valid.

## 3. Sharing flow (device A owns → device B joins)

1. **A creates + shares.** `POST /api/rns/folder/create {name,desc}` → `folderId`
   (or `folder/adddisk {path}` to share an on-disk directory as-is). A adds files
   with `folder/edit {folderId, op:{op:"addFile", x:<sha256hex>, name, ext, size}}`.
   Creating/editing publishes a DHT provider record for the folder key.
2. **A hands B the `folderId`/npub** (chat, copy button, QR — any channel).
3. **B joins by ID** — `folder/browse {folderId}` (or the Files-wapp
   "Open by id"). B's browse resolves A as a provider, pulls the op-log, reduces,
   and lists the files. *No permission prompt for reading.*
4. **B downloads** — `folder/download {folderId, sha, name}` for one file, or
   `{folderId, all:true}` for the whole folder. Each fetch verifies the SHA,
   archives the bytes, and re-seeds so B becomes an additional provider.
5. **(Write access, optional)** B sends its npub to A; A runs
   `folder/edit {folderId, op:{op:"grant", p:<B npub>, role:"contributor"}}`.
   B can now add/remove files, signing with B's own key.

HTTP API (`/api/rns/folder/*`): `create`, `edit`, `browse`, `list`, `adddisk`,
`rescan`, `download`, `autosync {folderId,on}`, `subscriptions`, `owned`. WASM
HAL (Files wapp): `hal.folder_create/list/edit/browse/stats/remove/opendir/
add_disk/rescan/download/autosync/owned/subs`.

## 4. Multi-hosting and auto-sync

Many devices host the same `folderId`, each an interchangeable provider of
identical bytes. A device becomes a provider by subscribing (`autosync on`),
downloading, pinning, and auto-seeding — **no key involved**. This is the
correct way to keep a folder durable across devices.

**Never copy the hidden key file (`.folder.json`) to host** — it holds the
master private key and would silently grant that device full write authority.
Moving write control to a new device is a deliberate, owner-only export of the
master private key, distinct from hosting.

## 5. Folder-share types

Selectable when creating a folder (metadata `shareType`):

| Type          | Who can add files                     | Membership              |
|---------------|---------------------------------------|-------------------------|
| `private`     | owner only (default)                  | owner grants each admin |
| `readonly`    | owner only; shared for reading        | anyone with the id reads|
| `collab`      | **every member** (shared write)       | members co-write        |

`collab` (the **synced folder**) is the multi-writer type used to keep the same
set of files in sync across many people — including the same account on the
owner's other devices. It builds directly on the op-log reducer, which already
merges ops from any authorized author (ordered by `created_at`, ties by event
id) into a convergent state. See [sync.md](sync.md) for how membership is
bootstrapped and how a personal folder syncs across one account's devices.

## 6. Live validation status

The folder model + op-log + reducer are unit-tested and the read/host/write
capability boundaries are enforced in `reduceFolder`. Device-to-device transfer
between two co-located phones rides the RNS link + resource layer; on the same
LAN, path selection now prefers the LAN medium (see the LAN interface and
`speedRank`), so a folder's files transfer directly at LAN speed rather than via
an internet hub. Cross-network (two phones on different carriers behind
symmetric CGNAT) direct P2P remains hard; the file layer falls back to the
public content tier there.
