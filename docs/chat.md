# Chat wapp

The **Chat** wapp is Aurora's governed group-chat client: a Discord-like surface
over NOSTR, federating to any standard relay and riding Aurora's transports
(Reticulum mesh first, Bluetooth for off-grid, APRS as legacy). A **main room**
everyone shares, **user-created sub-rooms** that a moderator must approve,
**npub-based admins/mods** with subtree-scoped authority, and a **global
reputation** derived from participation.

This is the top-level, living document for the wapp: what it is, what is built,
what is missing, and — importantly — **what has and has not been validated**. The
wire-level protocol (event kinds, tags, authority walk, reducers) lives in its own
reference, [`chat-rooms.md`](./chat-rooms.md); the NOSTR transport and sync
reliability rules live in [`NOSTR.md`](./NOSTR.md). Read those for depth; read this
for the whole picture and the state of play.

- **Source of truth for code:** `geograms/wapps` repo, folder `chat/` (`main.c`,
  `room.c`/`room.h`, `chat.c`, `ble.c`, `screens/home.ui.json`, `manifest.json`).
  Aurora only carries a bundled copy at `assets/wapps/chat.wapp`.
- **Current version:** `0.2.117`.

---

## 1. Architecture

Aurora is a generic Flutter **host** that runs WebAssembly **wapps**. The host
never contains app-specific logic; the Chat wapp is portable C compiled to
`wasm32-wasi`, driven entirely through the host's HAL message bus.

```
┌─────────────────────────────────────────────────────────┐
│ Aurora host (Flutter, generic)                          │
│  • GeoUI: $type widget dispatch (wapp_page.dart)        │
│  • rooms_field.dart  ← Discord layout (rail/chat/members)│
│  • ConversationStore + chat_view_field.dart (bubbles)   │
│  • PeopleViewField (member roster)                      │
│  • HALs: nostr, sqlite, crypto, identity, msg, time,    │
│          sensor/gps, http, ble                          │
└───────────────▲───────────────────────┬─────────────────┘
                │ ui.* messages          │ hal_* calls
                │ (host → wapp events)   │ (wapp → host)
┌───────────────┴───────────────────────▼─────────────────┐
│ chat.wapp (WASM/C)                                       │
│  main.c  — commands, screens, convo pipeline, BLE, APRS  │
│  room.c  — NIP-72 rooms, authority, moderation, rep      │
│  chat.c  — chat/geochat helpers                          │
│  ble.c   — BLE parcel transport                          │
└──────────────────────────────────────────────────────────┘
```

**Host↔wapp contract used by Chat:**

- Wapp → host (rendering): `ui.rooms.set` (the rail), `ui.convo.upsert/msg/react/
  status` (message surface), `ui.people.set` (member roster), `ui.prompt`
  (moderation / new-room / approval dialogs), `ui.screen.open` (Settings/Members).
- Host → wapp (input): commands `rooms_open`, `rooms_send`, `rooms_new`,
  `rooms_settings`, `room_members`, `room_members_tap`, `prompt` (dialog result),
  plus the Settings actions (`ble_apply`, `pubkey_apply`, …).
- HALs the wapp leans on: `hal_nostr_post(kind,content,tags)`,
  `hal_nostr_subscribe`/`_event_recv`/`_unsubscribe`, `hal_nostr_self`,
  `hal_sqlite_*`, `hal_crypto_*`, `hal_identity_sign`, `hal_msg_send`,
  `hal_time_epoch`.

**Keep-generic rule:** the `rooms` layout is a *generic* UI primitive
(`lib/wapp/geoui/widgets/rooms_field.dart`) — a rail + chat + member panel driven
by data. It knows nothing about NIP-72. All chat semantics live in the wapp.

---

## 2. Transports

Chat messages are NOSTR events; they travel by whatever Aurora has:

- **Reticulum (RNS) — primary everywhere.** Room defs, ops, proposals, approvals
  and messages federate as NOSTR events over the mesh (same path the Social wapp
  uses reliably). Works phone↔phone across networks, over hubs, and phone↔ESP32.
- **Bluetooth (BLE).** Off-grid parcel transport (`ble.c`): connectionless
  broadcast ≤300 B, GATT for larger. Toggle in Settings.
- **Internet relays.** Standard `wss://` NOSTR relays — a room is a NIP-72
  community, messages are ordinary kind-1 notes, so non-geogram clients interop.
- **APRS — legacy.** Retained but no longer surfaced in the UI.

Reliability rules inherited from `NOSTR.md` and already applied to rooms: **dedup
by event id** (never by content), **re-subscribe when the interest set changes**,
a **rate limiter never sits in front of the quality gate**, and use **generous
event buffers**. If a socket goes silent ~90 s it is treated as dead and the host
reconnects, replaying subscriptions.

---

## 3. The rooms model (summary; full spec in `chat-rooms.md`)

A single **room tree** rooted at the main room. Every node is a NIP-72 community
(kind `34550`); messages are kind `1` tagged `h`/`a` to the room.

**Event kinds**

| Purpose | Kind | Notes |
|---|---|---|
| Room definition | `34550` | `d`=roomId, `name`, `p`=moderator, `a`=parent link, `access` |
| Room message | `1` | `a`=`34550:<admin>:<roomId>`, `h`=roomId |
| Moderation op | `9078` (custom) | `h`=roomId (or `*` wapp-wide), `p`, `op`, `until`, `amount` |
| Sub-room proposal | `9079` (custom) | `h`=parent, `name` |
| Sub-room approval | `9080` (custom) | `e`=proposalId, `h`=parent |

**Authority — subtree-scoped.** The main-room author is the **global admin**; its
`p`-moderators are **global mods** (authority over everything). Each sub-room's
author is its **sub-admin**, with sub-mods; their authority covers that room and
its descendants only. `room_has_authority(pub, roomId)` walks `parentRoomId` to
the root, checking admin + `room_mods` at each level. An op / approval is honoured
**only** if its author has authority over the room it names — a forged op from a
non-authority is ignored by every client (client-side reducer, like the coin
authority-log and Circles).

**Moderation (soft-gated; relays still store everything):** `kick`, `suspend`
(until ts), `unsuspend`, `ban` (room), wapp-wide `ban` (`h=*`, global only),
`close` (drops a sub-room + descendants from the tree), `award`/`deduct` points,
`promote`/`demote`.

**Reputation — global, level 1..10.**
`score = REP_W_MSG(2) × messages-in-trailing-~6-months + net points`;
`level = 1 + (# of REP_THRESH crossed)`, cap 10.
`REP_THRESH = {5,15,40,90,180,350,650,1200,2500}`, `REP_WINDOW_SEC = ~182 days`.
Constants are one block in `room.c`.

**Sub-room approval flow (Phase 2):**

1. `room_propose(parent,name)` — an authority creates directly; anyone else
   publishes a **9079**.
2. A node holding parent authority ingests the 9079 → `room_ingest` returns **3**
   → wapp shows an approve/dismiss prompt.
3. `room_approve(id)` publishes a **9080** (parent-authority only).
4. The **proposer**, on ingesting the 9080, publishes the sub-room **34550** with
   **itself as admin** and the **approver as a moderator**, carrying an
   `["approved",<9080 id>]` proof.

**Validity gate:** a sub-room 34550 is *verified* only if its author already had
parent authority, or it carries an `approved` tag whose 9080 was signed by a
parent authority. Unverified rooms are stored `verified=0` and hidden. Because
events arrive in any order, the 9080 ingest **re-verifies**
(`UPDATE rooms SET verified=1 WHERE approvedBy=<9080 id>`) independent of whether
that node ever saw the 9079. Duplicate 9080s are idempotent (`pending→published`
status guard on the one-time publish).

`room_ingest` return codes: **0** not a room event · **1** consumed (op/proposal/
message-recorded) · **2** tree changed → refresh rail + re-subscribe · **3**
approvable proposal → prompt.

**Storage — device-local `rooms.sqlite3`:** `rooms(roomId, adminPub, name,
description, parentRoomId, access, approvedBy, closed, verified, createdTs)`,
`room_mods(roomId, pub)`, `ops(...)`, `msgs(id, roomId, author, ts)`,
`proposals(id, parentRoomId, proposerPub, name, description, ts, status)`,
`approvals(id, proposalId, approverPub, ts)`. All of it is a pure reduction of
public events — nothing secret.

---

## 4. Discord-like UI

Redesigned from the old flat topic list to a three-pane layout
(`lib/wapp/geoui/widgets/rooms_field.dart`, `$type:"rooms"`):

- **Left rail.** Collapsed ~64 px column of room icons; **drag left→right**
  expands it to ~248 px of room names + the **nested sub-room tree** (indented by
  depth), a **+ New room**, and a bottom **⚙ gear** → Settings. Fed by
  `ui.rooms.set {rooms:[{id,name,icon,parent,depth,unread,selected}]}`.
- **Center.** The open room's messages (`ChatViewField` over `ConversationStore`,
  keyed to the open room id) + composer. Send → `rooms_send`.
- **Right member panel.** Slides in on swipe-left or the members button; a
  `PeopleViewField` (`room_members`) showing each member's **reputation level +
  role**. Row tap → `room_members_tap` → moderation prompt for an authority.
- **Responsive:** wide (≥640) = side-by-side Row; narrow = Stack overlay with a
  scrim (fixes the phone "1-char-wide chat" squeeze).
- **Chrome takeover:** the rooms screen hides the wapp's TabBar and actions (same
  mechanism as the graph panel) so Chat owns the whole surface.

**Hidden (code kept, not shown):** Geochat, Follows, APRS, Beacon, Tools, Keys,
and the legacy `#DEV/#NEWS/…` topics. Settings is a hidden screen reached only via
the ⚙ (identity/position, Bluetooth, media auto-download, pubkey beacon).

---

## 5. File map

| Layer | File | Role |
|---|---|---|
| Wapp | `chat/main.c` | commands, screens, convo pipeline, rooms wiring, BLE, APRS, pubkey beacon |
| Wapp | `chat/room.c` / `room.h` | rooms tree, authority, moderation, reputation, proposal/approval, rail + member rendering |
| Wapp | `chat/chat.c` | chat/geochat helpers |
| Wapp | `chat/ble.c` | BLE parcel transport |
| Wapp | `chat/screens/home.ui.json` | one `rooms` screen + hidden Settings |
| Host | `lib/wapp/geoui/widgets/rooms_field.dart` | generic Discord layout |
| Host | `lib/wapp/wapp_page.dart` | `$type:"rooms"` detector, `_buildRoomsScreen`, `ui.rooms.set`, chrome-hide |
| Host | `chat_view_field.dart`, `conversation_store.dart`, `people_view_field.dart` | reused message + roster surfaces |
| Doc | `docs/chat-rooms.md` | wire protocol reference |
| Doc | `docs/NOSTR.md` | transport + sync reliability |

**Build:** `WASI_SDK_PATH=~/wasi-sdk make` in `wapps/chat` (`-Werror`), then
`wapps/build-archive.sh chat` to package `chat-<ver>.wapp`, then copy into
`aurora/assets/wapps/chat.wapp`. The APK build MUST use `~/bin/android-build-locked
flutter build apk` from the aurora root (its own step — never chained after a `cd`
into another dir) with a `--build-number` above the installed one (CI keeps bumping
TANK2's versionCode; a lower local build fails `INSTALL_FAILED_VERSION_DOWNGRADE`).

---

## 6. Status: built vs. missing

### Built and in the wapp
- [x] **Phase 1** — main room, subtree-scoped roles, moderation op-log (9078),
      reputation, open rooms.
- [x] **Discord UI redesign** — rail (drag-expand) + chat + member panel; legacy
      surfaces hidden.
- [x] **Phase 2** — user-created sub-rooms with the 9079/9080 approval flow;
      validity gate + order-independent re-verification; subscription covers
      `34550,9078,9079,9080`; rc-driven prompts; 8 KB drain buffer.

### Missing / next
- [ ] **Phase 3 — members-only rooms.** `access="members"` soft-gating: a room
      restricted to members; join-request → admit; kick/suspend scoped to the
      room timeline. Blueprint = Circles (members/roles/status/requests schema).
- [ ] **Multiple pending approvals.** Today only the newest actionable proposal is
      prompted (`room_newest_pending`); others wait for the next event to re-trigger.
      Add a proposals inbox / badge so an admin can see and act on all pending.
- [ ] **Reactions in reputation.** A reactions term is reserved in the score
      formula but not yet counted.
- [ ] **Real `ROOM_MAIN_ADMIN`.** Ship a designated project global-admin key and
      publish the main-room 34550 from it (see the blocker below).
- [ ] **Proposal/approval UX polish.** Dismiss currently just drops the prompt; no
      explicit "reject" event, no notification to the proposer on approve/reject.

---

## 7. Validation — status and plan

> **Discipline (per project memory):** never claim a step works without a
> screenshot that proves it. Validate on real devices on **different networks**
> (same-LAN is a false positive). Status cadence ~every 3 min for long ops.

### 7.1 Validation matrix

| Area | State | Evidence |
|---|---|---|
| Phase 1 moderation prompt (member tap → Award/Deduct/Suspend/…) | **Validated** | screenshot on TANK2; award moved reputation 1→2 |
| Self-echo dedup (own room post renders once) | **Validated** | screenshot; new msg rendered once |
| Discord UI (rail drag-expand, chat, members slide-in) | **Validated** | 7-item screenshot pass on TANK2 |
| Phase 2 code (9079/9080, validity gate, re-verify) | **Built, compiles, NOT live-validated** | `-Werror` clean build only |
| Phase 2 **approval handshake** across two identities | **BLOCKED — not validated** | see blockers |
| Phase 3 members-only | **Not built** | — |

### 7.2 The two blockers to live validation

1. **The approval flow is dormant under bring-up auto-admin.** `room_init` /
   `ensure_self` set `ROOM_MAIN_ADMIN = self` whenever it is empty, so **every
   device is its own global admin**. `room_has_authority(self,"main")` is always
   true → `room_propose` creates rooms directly and the 9079/9080 path never
   fires. To exercise proposer→approver, **one identity must have
   `ROOM_MAIN_ADMIN` pinned to the other's key** so the proposer is a genuine
   non-authority. This is also a product fact: the approval flow only becomes
   meaningful once a designated project admin key is configured.

2. **Device availability + the machine build lock.**
   - `adb devices` showed only **Hyper_8_Ultra** and **TANK2**; **C61 is offline**,
     so the requested c61+desktop pairing is unavailable right now.
   - The 16 GB machine hard-freezes on two concurrent heavy builds; a second
     Claude session was running `flutter run -d linux --release` + an Android/
     Gradle build. **Do not** start an APK/desktop build until that clears
     (`~/bin/android-build-locked`).

### 7.3 How to validate the approval flow (do this to close it out)

**Option A — desktop-only, two instances (no phone; honors "desktop linux").**
Two `$HOME`s give two identities and two storage roots (`homeDir()` reads `$HOME`;
storage = `$HOME/.local/share/aurora`).

1. When the build lock is free: build desktop once
   (`~/bin/android-build-locked ./launch-linux.sh --build`).
2. Run instance **A** with `HOME=/tmp/aurora-A`. Read A's NOSTR pubkey.
3. Pin `ROOM_MAIN_ADMIN = <A pubkey>` (test-only) in `room.c`, rebuild the wapp
   (`make` + `build-archive.sh chat`), re-copy into `assets/`. Remove A's installed
   chat wapp so it re-seeds the pinned build — **A keeps its identity** (identity
   lives in the profile, not the wapp), so A stays the global admin.
4. Run instance **B** with `HOME=/tmp/aurora-B` → fresh identity = non-admin.
5. Confirm A and B federate (local RNS interface should mesh them; both to hubs).
6. **Screenshot each step:** B → New room → "waiting for a moderator to approve";
   A gets the approval prompt → Approve; the sub-room appears **in both** rails,
   nested under the parent; B posts in it; A moderates a B message.
7. Restore `ROOM_MAIN_ADMIN` to its release value before committing.

**Option B — desktop (admin) + C61 (proposer), when C61 reconnects.** Same pin:
`ROOM_MAIN_ADMIN` = the desktop's key; C61 as the non-admin proposer. Devices on
**different networks** (cellular for C61), not the same WiFi.

### 7.4 Regression checks (single instance, quick)
Even without two identities: open Chat → Discord rail renders, no legacy topics,
no Geochat/Follows/APRS tabs; as auto-admin, **New room** creates a nested
sub-room directly; post a message → appears once; open Members → roster with
reputation levels; ⚙ → Settings (identity/position/bluetooth/media/pubkey only).

---

## 8. Known bugs fixed (do not regress)

- **Moderation prompt never opened** — a `ui.prompt` `id` with a long/`\t`-tab
  value silently failed. Use a **short fixed prompt id** (`rmod`, `rappr`,
  `newroom`) + a target stashed in a global (`g_mod_target`, `g_appr_target`,
  `g_new_parent`). Do not encode data into the prompt id.
- **Self-echo double render** — own posts federate back; `g_pubkey` (APRS) ≠ the
  NOSTR pubkey. Use `room_is_self` (compares `hal_nostr_self`) + dedup by event id.
- **Authority check flaky at startup** — `g_self` empty until the profile key
  lands. `ensure_self()` lazily refreshes it in every authority path.
- **Phone layout squeeze** — Row side-by-side crushed chat when members opened;
  narrow screens use a Stack overlay + scrim.
- **Left-edge rail drag = Android back gesture** — start the drag past ~x>100.
- **Phase 2 re-verify ordering** — re-verification must NOT depend on holding the
  9079; a node with only the room-def + 9080 must still un-hide the room (fixed).

## 9. Build / test gotchas

- Bundle the wapp **before** the APK; run the APK build as its own step from the
  aurora root (a chained `cd wapps && … && flutter build apk` builds in the wrong
  dir and installs a stale APK).
- Use `--build-number` above the installed versionCode; CI auto-updates TANK2.
- Never `adb reconnect`/`kill-server` on the test phones — forces a re-auth prompt.
- The shared `wapps` working tree is used by a concurrent Social session; when
  committing, **stage only the chat files** (`chat/main.c`, `chat/room.c`,
  `chat/room.h`, `chat/manifest.json`, `chat/app.wasm`, and the specific
  `binaries/chat/chat-0.2.117.wapp` / index entry) so unrelated Social changes are
  not folded in.

## Nearby devices (chat 0.4.8)

A mesh radio's first question is not "who exists" but **"who can I touch from
here, right now"**. Chat answers it in a full-size tab, `$type:"people"`, fed by
one presence table the wapp merges from three sources:

| Source | What it gives |
|---|---|
| `hal_people_directory` | Reticulum: geogram people + LXMF peers, with `via` (interface) and hop count |
| `hal_mesh_devices` | BLE street-mesh neighbours (direct radio reach) |
| `g_pk_call` / `g_pk_ts` | the pubkey beacons Chat already hears over BLE broadcast / APRS / RNS |

Merged **by identity, not by radio**: the same neighbour heard over BLE and LAN
is one row carrying two tags (LAN / BLE / Reticulum / LXMF / Radio), not two
rows. Peers more than one hop away are dropped — reachable *through* somebody is
a different promise from local reach.

Two sections, each sorted newest-first:

- **Within reach** — heard within `NEAR_ACTIVE_SEC` (10 minutes).
- **Seen before** — everyone else, rendered grey (`"dim": true`, honoured by
  `PeopleViewField`) with the age spelled out ("last seen 40m ago"). Nobody is
  deleted and the table is persisted in KV `nearby`: "who was here earlier" is
  the second question a presence list has to answer, and dropping the row
  answers it with a lie.

A stats strip carries the two counts. Section titles carry NO count — the host's
section tab already appends one (a "(0) (0)" bug caught in review). "direct" is
only claimed for active rows: it is a statement about now.

Tapping a row emits `ui.profile.open {callsign, npub}` — a generic host outbox
type — and the host opens its full profile screen, where **Chat** and **Mail**
sit side by side. Mail falls back to the callsign when the key is not known yet
(the Mail wapp resolves callsign → key through the relay directory), so someone
standing next to you is never unreachable just because their beacon has not
landed.

Refresh runs on a 5s cadence while a UI is attached, diffed via
`fnd_changed_send` — a quiet poll costs two HAL reads and no rebuild. The tab is
switched by the HOST, so there is no "screen opened" event to hang it on; that
mistake shipped a permanently empty list in 0.4.6.

### Validated (2026-08-02, desktop X16JK8 ⇄ phone X1RD89 on one LAN)

Both directions, screenshot-verified: each device listed the other under
**Within reach (1)** with tags `LAN` + `LXMF`, the age ticking ("seen 2s ago -
direct"), the desktop's 7 stale radio-beacon rows greyed under **Seen before**,
and phone-side row → profile → **Mail** opening the 1:1 composer for X16JK8.
