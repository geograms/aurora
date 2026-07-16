# Chat rooms: NIP-72 communities with moderation and reputation

The Chat wapp models rooms as **NIP-72 moderated communities** plus a custom,
npub-signed **moderation op-log**, all reduced client-side. Rooms federate to any
standard NOSTR relay: a room is a plain kind-34550 community, room messages are
ordinary kind-1 notes tagged to it, and a non-geogram client simply ignores our
custom op kind. All of this lives in the wapp (`wapps/chat/room.c` + `room.h`);
the host stays generic (only its existing `hal_nostr_*`, `hal_sqlite_*`,
`hal_crypto_*` HALs are used).

Status: **Phase 1 shipped** (main room, roles, moderation, reputation, open
rooms). Phase 2 (user-created sub-rooms with approval) and Phase 3 (members-only
rooms) are planned.

## Events

| Purpose | Kind | Key tags |
|---|---|---|
| Room definition | **34550** (NIP-72) | `d`=roomId, `name`, `description`, `p`=moderator (`["p",pub,"","moderator"]`), `a`=parent (`34550:<parentAdmin>:<parentId>`) for a sub-room, `access`=`open`\|`members` |
| Room message | **1** | `a`=`34550:<admin>:<roomId>`, `h`=roomId |
| Moderation op | **9078** (custom) | `h`=roomId (or `*` for a wapp-wide ban), `p`=target, `op`, `until`, `amount`, `client`=`geogram-chat` |

`op` is one of `kick`, `suspend`, `unsuspend`, `ban`, `close`, `award`, `deduct`,
`promote`, `demote`. Content of a 9078 is the optional reason. 9078 is a regular
event (relays keep it, unknown clients ignore it); it sits above NIP-29's
9000-9022 admin range to avoid colliding with relay-enforced groups.

The **main room** is the tree root; its `d`=`main` and its author is the
**global admin**. That 34550 is published by whoever runs the project (its key is
`ROOM_MAIN_ADMIN` in `room.h`). During bring-up, with no project key configured,
the running device becomes the global admin so moderation is testable — replace
`ROOM_MAIN_ADMIN` before release.

## Authority (subtree-scoped)

Rooms form a tree by their `a`/parent link. Authority over room R is held by:

- the **global admin** (main-room author) and **global mods** (main-room `p`
  moderators) — authority over everything; and
- the **admin or a mod of R or of any ancestor of R** — a sub-admin (a room's
  author) and its sub-mods run that room and its descendants only.

`room_has_authority(pub, roomId)` walks `parentRoomId` from the room up to the
root and checks each level. The moderation reducer (`reduce`/`member_status`)
honours a 9078 op **only if its author has authority over the room the op names**,
so a forged op from a non-authority is ignored by every client.

Moderation effects (client-enforced soft gating; relays still store everything):
suspend-until hides the member's compose until the timestamp; a room `ban` hides
their posts and blocks compose in that room; a wapp-wide `ban` (`h=*`, global
authority only) hides them everywhere; `close` (global/ancestor authority) drops
the sub-room and its descendants from the tree.

## Reputation (global, level 1-10)

Computed client-side, deterministically, so anyone replaying the same public
events gets the same number — no authority, relay-agnostic. Per pubkey:

```
score = REP_W_MSG * (their room messages in the trailing ~6 months)
        + net points (awards − deducts from honoured ops)
level = 1 + (number of REP_THRESH crossed), capped at 10
```

Weights (`REP_W_MSG`), the 6-month window (`REP_WINDOW_SEC`) and the level curve
(`REP_THRESH`) are one constants block in `room.c`; adjust there. (A reactions
term is reserved for a later phase.)

## Storage (device-local, `rooms.sqlite3`)

`rooms(roomId, adminPub, name, description, parentRoomId, access, approvedBy,
closed, createdTs)` (a tree), `room_mods(roomId, pub)`, `ops(id, roomId,
authorPub, targetPub, op, amount, until, reason, ts)` (dedup by event id),
`msgs(id, roomId, author, ts)` (for the reputation window). Kept on the device;
nothing about moderation state or reputation is a private secret — it is all a
pure reduction of public events.

## Wapp integration

`main.c` subscribes to `{kinds:[34550,9078]}` plus `{kinds:[1],#h:[rooms]}`, feeds
each event to `room_ingest` (defs/ops) or renders it as a room message; a
conversation whose id is a known room posts through `room_post` (kind-1 with the
`a`/`h` tags) instead of the APRS/BLE path. The room list is the conversations
widget (sub-rooms indented); the **Members** screen is a `people` list showing
each member's status and reputation level, and an authority tapping a member gets
a moderation prompt (award/deduct/suspend/kick/ban).

## UI (Discord-like)

The Chat wapp renders through a generic host widget `$type:"rooms"`
(`lib/wapp/geoui/widgets/rooms_field.dart`, wired by `_buildRoomsScreen` in
`wapp_page.dart`): a thin left icon rail of rooms that expands on a left→right
drag into room names + the nested sub-room tree (with a `+` to create a room and
a bottom gear to Settings), the chat pane in the center, and a member list that
slides in from the right showing each member's reputation level (tap a member as
an authority for the moderation actions). On a phone the rail and member panel
overlay the chat with a tap-to-close scrim; on wide screens all three panes sit
side by side. The widget is app-agnostic — the wapp drives it with `ui.rooms.set`
(the rail), the usual `ui.convo.*` (chat), and `ui.people.set` (members), and
handles `rooms_open` / `rooms_send` / `rooms_new` / `rooms_settings` /
`room_members_tap`.
