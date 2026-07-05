# Synced folders (multi-writer) and cross-device sync

A **collab** folder (`FolderShareType.collab`) is a shared folder that *every
member can write to*, not just the owner. It is the mechanism Aurora uses to
keep the same set of files in sync across many people — and across the several
devices of a single account.

It is built entirely on the existing mutable-folder machinery
([folders.md](folders.md)); nothing about the op-log, the signatures, or the
transport changes. What makes it "synced" is two small additions:

1. **The membership is seeded so writes converge**, and
2. **members auto-subscribe**, so each device downloads and re-seeds the others'
   additions and the file sets converge.

## Why the op-log is already a sync engine

A folder's contents are a signed, append-only log of ops reduced by
`reduceFolder` (`folder_state.dart`). The reducer already:

- accepts an op from **any** author the master keyset authorized at the op's
  timestamp (the master, or any admin), and
- orders all ops by `created_at` (ties by event id) into one **convergent**
  state — files keyed by name (addFile upserts, rmFile deletes), metadata
  last-writer-wins.

So multiple writers already merge deterministically: give two devices the same
event set and they reduce to identical contents. The only thing missing for
"everyone can write" was authorizing everyone in the keyset.

## Two flavours of sync

### a) Cross-device sync for ONE account

The same account on two phones signs edits with the **same profile key** (the
identity is restored from backup on each device — see the identity backup/restore
flow). So a collab folder created by that account authorizes the account's own
public key in its initial keyset:

```
publishInitial(folderId, shareType: 'collab')
  → keyset = [ AdminEntry(<ownAccountPubHex>, contributor, now) ]  (master-signed)
  → setMeta { shareType: 'collab', owner: <ownNpub> }
```

Now **every device signed into that account can add/remove files** (they all sign
as that admin key), and every device auto-subscribes, so a file added on phone A
appears on phone B once B pulls the op + fetches the bytes. This is the
"same files on all my devices" case.

Note this needs **no master-private-key export**: the devices write as an
*admin* (the account key), while the folder's master key stays only on the
creating device. Losing the creating device loses only the ability to change
*membership* (grant/revoke), never the ability to keep writing files.

### b) Shared sync among DIFFERENT users

The owner grants each member's npub into the keyset
(`folder/edit {op:"grant", p:<member npub>}`). Each member then writes with their
own key and auto-subscribes. All members' additions converge. Revocation is
forward-only: a removed member's past, legitimately-signed files remain, but they
can add no more.

Membership is still **owner-authoritative** (only the master key can grant/revoke)
— this is deliberate: it keeps a single, auditable, master-signed source of truth
for who may write, and prevents an open write-membership spam surface. A future
extension could let moderators co-sign a delegated keyset; today, ask the owner
to grant.

## Creating one

- API: `POST /api/rns/folder/create {"name":"Team files","type":"collab"}`.
- Facade: `RnsService.folderCreate(name, shareType: FolderShareType.collab)` —
  publishes the seeded keyset + `setMeta{shareType:collab}` and turns on
  auto-sync for the folder.
- Members join exactly like any folder: they open it by `folderId`, and (for the
  different-users case) the owner grants their npub so they can write.

## Convergence and conflicts

- **Add/add** of different names → both files kept.
- **Add/add** of the same name → last `created_at` wins (deterministic; ties by
  event id), older entry replaced.
- **Add then remove** the same name → the later op wins by timestamp.
- **Clock skew**: ordering is by each op's own `created_at`; badly-skewed clocks
  can reorder near-simultaneous edits, but every device still reduces the same
  event set to the *same* result — it is convergent, not real-time.

## Status

The model + multi-writer merge + share-type stamping are unit-tested
(`test/folder_collab_test.dart`): owner + member co-writes converge, pre-grant
and stranger ops are rejected, and `shareType` round-trips through the reducer.
Live cross-device convergence rides the same file-transfer layer as any folder;
on a shared LAN it uses the direct LAN path (see [folders.md](folders.md) §6).
