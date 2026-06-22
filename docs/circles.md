# Circles wapp — architecture & operational notes

Private, encrypted group chat over Reticulum. This documents how it actually
works (verified by reading the code in `../wapps/circles`), what is solid, and
the gaps found while building the short-id-join end-to-end test.

Source of truth: `geogram/wapps/circles/` (C → wasm). Host HAL: `lib/wapp/wapp_engine.dart`.

## 1. Where the code lives

| Part | File |
|------|------|
| Lifecycle + UI glue (commands in / prompts out, RNS drain) | `wapps/circles/main.c` |
| All circle logic: keys, epochs, crypto, sync, panels, folders | `wapps/circles/circle.c` (~2080 lines) |
| Thin sqlite wrappers + schema | `wapps/circles/db.c` / `db.h` |
| String/JSON/base64 helpers | `wapps/circles/util.c` |
| Native (non-wasm) integration test | `wapps/circles/tests/native/` (`sh tests/native/run.sh`) |
| Host HAL (sqlite/crypto/rns/msg) | `aurora/lib/wapp/wapp_engine.dart` |
| Headless background runner | `aurora/lib/wapp/background_wapp_manager.dart` |
| Shipped binary | `aurora/assets/wapps/circles.wapp` (a zip: app.wasm + manifest + ui) |

The wapp is **generic-host clean**: all circle-specific logic is in the wapp C;
the host only exposes generic `hal_sqlite_*`, `hal_crypto_*`, `hal_rns_*`,
`hal_msg_*`, `hal_identity_*`, `hal_contacts_*` primitives.

## 2. Host ↔ wapp event model

The host drives the wapp by queuing a flat JSON `{"command":"…", …fields}` via
`hal_msg` and calling the exported `module_handle_event` (`main.c`). The wapp
replies by `hal_msg_send`-ing UI messages the host renders:

- `{"type":"ui.prompt", …}` — a dialog (e.g. New circle name, Join code).
- `{"type":"notify","level":…,"title":"Circles","body":…}` — a toast / when
  running headless → an **Android system notification** (see §7).
- `ui.chat.*`, `screen_open`, `field_set` — GeoUI rendering.

Key commands (`module_handle_event` in `main.c`): `new_circle`, `join_circle`,
`apply_url` (deep link), `conversations_send` (post a message),
`conversations_open`, `manage_people`, `share_circle`, `req_approve`/`req_reject`,
`add_member`, role/folder commands, and `prompt` (answer to a `ui.prompt`).

Driving headlessly: send the flat command directly, e.g. create a circle with
`{"command":"prompt","prompt_id":"newcircle","prompt_input":"My Circle"}`
(bypasses needing the UI to open the prompt first — `on_prompt` runs regardless).

## 3. Data model (sqlite, NOT encrypted at rest)

Databases live under the wapp data dir, opened with plain `sqlite3.open` (WAL,
no SQLCipher). On Android: `…/app_flutter/<profile>/wapps-data/circles/`.

- **Index DB** `circles/index.sqlite3`: `circles(id, name, master_priv, created)`.
  `master_priv` is set **only for circles we own**.
- **Per-circle DB** `circles/<circleId>.sqlite3` (`db_init_circle`):
  - `meta(k,v)` — name, description, picture, epoch, default_role.
  - `members(pub, added_epoch, revoked_epoch, role, status)`.
  - `roles(name, description, created)`.
  - `epochs(epoch, key)` — **the AES keys, base64url, in cleartext**.
  - `events(id, epoch, author, ts, ct, sig, body)` — `ct` = ciphertext
    (base64url IV‖AES-256-CBC), `body` = **decrypted plaintext, cleartext,
    NULL until decryptable**. The render path reads `body` directly.
  - `folders`, `folder_keys`, `folder_events` — permissioned nestable spaces
    (same ct/body pattern per folder, per-folder epoch key).
  - `requests(pub, nick, ts)` — pending join applications (owner side).

### Encryption posture (verified)
- **In transit: content encrypted.** Message body → AES-256-CBC (random IV) under
  the epoch key → `ct`, carried in the datagram `"x"` field. The RNS wapp channel
  is an **announce** (broadcast) and is NOT additionally transport-encrypted;
  envelope metadata (circle tag, epoch, author pubkey, ts, signature) travels in
  cleartext. So content is protected; metadata (who/when/which circle) leaks.
- **At rest: NOT encrypted.** The DB stores `events.body` plaintext AND the AES
  keys (`epochs.key`) AND the owner's `master_priv` all in cleartext. Anyone with
  the `.sqlite3` file reads everything. Fixing this needs SQLCipher / keyed DB
  open in the host HAL (`sqlite3.open`) — see §8. Accepted as-is for now.

## 4. Identity & crypto primitives

- Device identity = a secp256k1 key; `g_self` = our x-only pubkey base64url
  (`hal_identity_pubkey`). Signatures via `hal_identity_sign` / `hal_verify`
  (schnorr over sha256, host side `NostrCrypto`).
- A **Circle** = a secp256k1 keypair. `circleId` = its x-only pubkey hex. The
  owner holds `master_priv` and signs the membership keyset.
- **Epoch keys**: a random AES-256 key per epoch (`hal_crypto_random`).
  Distributed by wrapping to each member's pubkey via `hal_encrypt` (ECDH+AES),
  sent as a `key` datagram. Rotated (epoch bump) whenever membership changes.
- `hal_crypto_aes_encrypt/decrypt` = AES-256-CBC, output `IV(16)‖ciphertext`.

## 5. RNS datagram protocol (the wapp channel)

Transport = `RnsService.wappBroadcast(tag, payload)`: wraps the payload in an
announce of the sender's `geogram/wapp` destination carrying
`{t:<wappId>, p:base64(payload)}`. Every peer running the same wapp id receives
it (`wappDrain`). One packet, a few hundred bytes; larger → chunk in the wapp.
**Content privacy is the wapp's job** (encrypt before broadcast).

Datagram kinds (`circle_on_datagram` dispatch, field `"k"`):

| k | meaning | direction |
|----|---------|-----------|
| `msg` | a chat message event (`x`=ct, `s`=sig, `a`=author, `e`=epoch, `t`=ts) | any member → all |
| `ks` | signed membership keyset (name, members, roles, folders) | owner → all |
| `key` | a wrapped epoch key (`to`=recipient, `b`=ECDH blob) | owner → member |
| `kr` | key request (I'm missing epoch keys) | member → owner |
| `rq` | history request (`since`=ts) → owner replays ≤50 events as `msg` | member → owner |
| `fm`/`fk`/`fkr` | folder message / folder key / folder key request | per-folder |
| `jr` | join request / application (`cid`,`frm`,`nm`,`s`) | applicant → owner |
| `cd`/`co` | **short-code discovery req / circle offer (added for short-id join)** | applicant ↔ owner |

## 6. Membership lifecycle (how a join actually completes)

1. **Create** (`circle_create`): generate master key, seed epoch 1, add self as
   first member (role `admin`), insert index + per-circle DB, show the row.
2. **Share** (`circle_open_share`): exposes three forms —
   - full key `circle:<64hex>` (authoritative),
   - deep link / QR `https://geogram.radio/circle/<64hex>`,
   - **short code** `circle/<first3>-<last3>` — only ~24 bits, **NOT a secret**,
     for quick human reference (`circle_short_code`).
3. **Apply** (`circle_apply_join`): resolve the ref to a full `circleId`, sign
   `cid|self`, broadcast a `jr` datagram to the owner.
4. **Owner receives** (`handle_jr`): verify the applicant's signature, insert a
   `requests` row, `notify("Someone applied to join your circle")`, refresh the
   People panel.
5. **Approve** (`circle_approve_request` → `add_member_pub`): bump epoch, add the
   member, wrap **every entitled epoch key** to them (`key` datagrams),
   re-sign + broadcast the keyset (`ks`), delete the request.
6. **New member provisioned** (`handle_keyset`): if the `ks` lists us and we
   don't have the circle yet, **auto-create** the local circle (no master key),
   replace members/roles/folders/meta, then `send_keyreq` (ask for epoch keys).
7. **Keys arrive** (`handle_key`): decrypt the wrapped key, `epoch_store`, then
   `decrypt_pending` decrypts any events we already hold for that epoch.
8. **History** (`rq` → `handle_req`): owner replays the last 50 events as `msg`
   datagrams; the new member stores + decrypts them.

## 7. Headless / background operation & notifications

`BackgroundWappManager` runs a wapp's wasm engine with no UI page: `init()` then
`tick()` on the manifest interval, draining the outbox in `_drain`:
- `notify` → `NotificationService.show(scope: both)` → **Android system
  notification** (the notification-bar entry the user can act on). This is the
  mechanism behind "the owner gets a notification when someone applies".
- `host.run_command`, `ui.chat.append` (archive), reactions — handled; other
  `ui.*` ignored (no UI in background).

On Android, always-on (screen off) additionally needs the native foreground
service (`AndroidForegroundService`), started whenever a background wapp is live.

## 8. Gaps found (and what was done about them)

While wiring the short-id-join test end-to-end, three real gaps surfaced:

1. **Background RNS was dead.** `BackgroundWappManager.start()` never called
   `engine.setAppId(name)` (only `WappPage` did), so `hal_rns_broadcast/available`
   had no tag → a background circles engine could not send or receive ANY
   Reticulum datagrams. → **Fix in host:** call `setAppId` when starting a
   background engine.
2. **No short-code network discovery.** `circle_resolve_short` only matches
   circles **already known locally**; the short code is a lossy hash so a new
   joiner holding only `abc-xyz` cannot derive the full id. → **Added** a
   discovery exchange: joiner broadcasts `cd{f,l}`, the owner answers `co{cid,n}`
   with the full id, joiner then auto-sends `jr`. The full id stays the only
   authoritative identifier (short code is just a lookup hint).
3. **New members never pulled history.** `circle_tick` only re-requests *keys*
   for events already in the local DB; a fresh member has zero events and so
   never fired an `rq`. → **Added** a history request on join + bounded retry.

Headless control: a generic `/api/wapp/*` set of endpoints was added to inject a
flat command into a running background engine and read its outbox — generic (any
wapp), so it keeps `lib/` app-agnostic.

### Transport-layer bugs found while testing two phones over the internet
These are in the RNS stack (host + `reticulum-dart`), not the circles wapp, but
they blocked circles datagrams from crossing device-to-device:

4. **Wapp announces were shed by the flood budget.** The transport caps
   verification of announces from *new* destinations to ~20/s so the public-hub
   flood can't peg the CPU, exempting a `priorityAnnounceNames` allowlist (chat,
   files, dht, relay, lxmf). The **`geogram/wapp`** aspect was missing from that
   list, so on a busy public hub a peer's wapp-datagram announce (a new
   destination) was dropped amid the flood and never delivered. → **Fixed:** add
   the wapp name-hash to `priorityAnnounceNames` (`rns_service.dart`).
5. **A phone tried to relay the whole public mesh → 100% CPU / ANR.** Every
   Aurora node ran as a TRANSPORT node (`transportId = own id`), rebroadcasting
   every inbound announce onto every other hub interface — thousands of sends/s
   on a phone connected to 5 hubs, which pegged a core (especially after a
   network change) and starved the UI + wapp ticks. → **Fixed:** added an
   automatic **passive (leaf) mode** to `RnsTransport`: when the inbound announce
   rate shows the device can't afford relaying, it stops rebroadcasting other
   nodes' announces + link/resource transit, while staying connected to all hubs
   and still announcing/receiving its OWN traffic (the hubs do the relaying, so
   meshing is unaffected). It auto-resumes when the flood subsides. Surfaced in
   `/api/rns/status` as `passive` + `annRate`. See §11.

Still open / not done: at-rest DB encryption (SQLCipher / keyed open) — see §3.

## 11. RNS passive (leaf) mode — staying meshed under CPU pressure

A constrained device (phone) connected to busy public hubs cannot relay the
whole network's announce flood without pegging its CPU. Rather than disconnect
(which would leave the mesh) or melt down, `RnsTransport` auto-degrades:

- **Trigger:** inbound announce rate sampled per second in `ingest()`. `>50/s`
  sustained for 3 s → passive ON; `<12/s` sustained for 10 s → passive OFF
  (hysteresis). Tunable via `_loadHighPerSec` / `_loadLowPerSec`.
- **Passive behaviour:** skips `_rebroadcast` (announce relay) and `_maybeForward`
  (link/resource transit). Still: keeps all hub uplinks, ingests announces (so it
  learns paths + receives its own datagrams), and `sendOnAll`s its own announces.
  So a leaf phone still reaches every peer **through the hubs** — discovery,
  circles datagrams, file fetch all keep working.
- **Manual override:** `transport.setPassive(bool)` pins the mode (sets
  `autoPassive=false`); `autoPassive=true` restores automatic control.
- **Observability:** `GET /api/rns/status` → `{"passive": bool, "annRate": n}`.

This is the real-world answer to "the CPU can't take it": shed relay duty, not
connectivity. Hubs/desktops with spare CPU stay full transport nodes (their rate
never crosses the threshold).

## 9. Build & deploy

- Wapp wasm: `cd wapps/circles && make` (uses `../sdk/Makefile.common`, clang
  wasm target). Repackage `circles.wapp` (zip of app.wasm + manifest + screens +
  media + lang) and ship into `aurora/assets/wapps/`.
- Native logic test (fast, no wasm): `sh wapps/circles/tests/native/run.sh`.
- Host (Dart) changes: rebuild the Flutter APK (`./launch-android.sh`) — the wapp
  HAL and background manager live in the host.
- On device the installed wapp lives under the app data dir; the app seeds /
  reinstalls wapps from assets on launch.

## 10. Live test workflow (two phones, different networks)

Both phones reach the same public RNS hub (default `rns.beleth.net:4242`) so they
mesh over the internet (NAT is not the blocker — see the RNS multi-hub memory).
Drive each phone via its remote API over adb:

```
adb -s <serial> forward tcp:<localport> tcp:3456    # reach the in-app API
curl localhost:<localport>/api/status               # node up? hub connected?
curl localhost:<localport>/api/log?n=200            # wapp + RNS logs
```

Read the sqlite DBs directly (verify ciphertext at rest, membership, requests):
`adb -s <serial> exec-out run-as com.geogram.aurora cat <path>/circles/<db>`.

## 12. Cooperative data exchange / gossip transport (validated 2026-06-22)

This is the big one — how circle data actually moves between members over
Reticulum, learned by getting two NAT'd phones on different networks to sync a
circle over the real public hubs (no dedicated hardware, no network change).

### 12.1 Three transport layers (the wapp uses all three)
A circle "datagram" is the inner JSON (`{"k":"msg"|"ks"|"key"|"kr"|"rq"|...}`).
It can travel three ways; circles now uses each where it fits:

1. **Broadcast announce** (`hal_rns_broadcast` → `RnsService.wappBroadcast`): the
   datagram rides the app_data of an RNS *announce* of the sender's `geogram/wapp`
   destination. One-to-many, no path needed. **BUT announces are unreliable
   device-to-device on busy public hubs** — they're rate-limited (announce_cap)
   and the community hubs don't reliably flood one leaf's announce to another.
   Kept only as a best-effort fast path / LAN path.
2. **Addressed delivery** (`hal_rns_send_to(destHex, payload)` →
   `RnsService.wappSendTo` → `sendLxmf` with LXMF field `0xB0 = [tag, payload]`):
   the datagram is wrapped in an LXMF message addressed to ONE peer's LXMF
   delivery dest, delivered over a Reticulum **Link** (small = single packet,
   large = a **Resource**, e.g. the ~1KB keyset). Reliable + encrypted +
   signature-verified. Routes through the hubs; needs a path (see 12.2).
3. **Store-and-forward pull** (cooperative mailbox): if addressed delivery fails
   (no path / unreachable peer), the sender HOLDS the message
   (`LxmfRouter._mailbox`, keyed by recipient delivery hash) and the recipient
   PULLS it later over a link IT initiates (`hal_rns_pull(propDest)` →
   `pullFrom` → peer's `lxmf/propagation` dest). The held batch travels as one
   Resource (`_packBatch`/`_unpackBatch`). This is what makes sync work despite
   asymmetric routing — the unreachable side reaches OUT.

Inbound for (2)/(3): the host's LXMF `onMessage` checks for field `0xB0` and
routes `[tag, payload]` into `_wappInbox[tag]` (same queue as broadcasts), so the
wapp's `drain_rns` receives them transparently via `hal_rns_recv`.

### 12.2 Path requests are the key primitive (NOT NAT/inbound)
A Reticulum leaf behind NAT does NOT need inbound reachability — it connects
OUTBOUND to a transport hub and the hub relays everything to it. So "broken
inbound" is a non-problem. The real issue was **paths**: addressed packets need a
path to the destination, and the destination's *announce* (which establishes the
path) often does not passively flood across busy public hubs. The fix is the
**pull** half of path-finding — `requestPath(destHash)` (RNS path request to the
PLAIN dest `rnstransport.path.request`); a hub the target is attached to answers
with the target's announce (context PATH_RESPONSE). With a path established,
addressed delivery + Resources work in both directions. `sendLxmf` and
`LxmfRouter` auto-request the path when missing (sender side, and receiver side
to resolve an unknown message SOURCE for signature verification). Inspect routing
with `GET /api/rns/route?dest=<hex>` (next hop, via interface, hops, age).

`rns.beleth.net` (the app's intended reliable relay) was DOWN during testing;
the community hubs still route addressed traffic fine via path requests.

### 12.3 The cooperative-hosting model (no central owner)
Circles are hosted by ALL members, not the admin. The owner is only needed to
SIGN membership changes (it holds the circle master private key). Data sync is
member-to-member gossip:
- `circle_send` / `broadcast_keyset` / `send_wrapped_key` / `send_keyreq` /
  `send_history_req` / `handle_req` (history replay) all now do
  `hal_rns_broadcast` (fast path) **+ `deliver_to_members(i, d)`** (reliable
  addressed to every member whose delivery dest we know, store-and-forward on
  failure).
- `circle_tick` runs `pull_from_members(i)` — pulls every member's mailbox, so
  events someone couldn't push to us are retrieved. Because every member both
  pushes addressed AND pulls peers, any online subset converges with no owner
  online. The owner being offline does not stop the circle.

### 12.4 Member address book (npub ↔ RNS dest)
Members are identified by their NOSTR npub (x-only pubkey, used for signing +
ECDH), which is a DIFFERENT key from their RNS identity/dest. To address a member
you need their RNS dests, so:
- `members` table gained `deliv` (LXMF delivery dest) + `prop` (propagation/
  mailbox dest) columns. `hal_rns_delivery_dest` / `hal_rns_prop_dest` expose a
  node's own dests; `whoami` reports `pub|deliv|prop`.
- The signed keyset carries each member's `dl`/`pp`, so everyone who has the
  keyset can address everyone else. The owner bootstraps this by including dests
  in the keyset and delivering it addressed at join.

### 12.5 The join → key → message flow that was validated
1. Owner adds the member with their dests → bumps epoch → wraps the new epoch key
   to the member (`send_wrapped_key`, addressed) → re-signs + delivers the keyset
   addressed (`broadcast_keyset` + `deliver_to_members`).
2. Joiner receives the keyset (Resource), VERIFIES the master signature, creates
   the local circle, and `send_keyreq` (addressed → stored). Note: the wrapped
   key may arrive BEFORE the circle exists (queued first) and get dropped — the
   addressed `send_keyreq` covers this: it is stored, the OWNER pulls it, and
   re-sends the key (addressed, owner→joiner works) → joiner gets the key.
3. Joiner can now post. Its message is delivered addressed to members; where
   direct fails it is stored and the owner PULLS it (validated: a 244-byte msg
   datagram arrived at the owner this way).

### 12.6 THE root-cause bug (host) — NUL termination
`_writeStr` / `_writeUtf8` in `wapp_engine.dart` did **not** NUL-terminate the
wasm output buffer. The wapp reads returned strings with strlen-based `s_len()`.
For a STACK buffer (`char sig[160]`) holding the 128-hex keyset signature, that
ran past the data into stack garbage (s_len measured 189 vs 128), corrupting the
sig in the datagram JSON → the receiver got a truncated sig → `KS:sig-fail` → the
keyset was rejected and joins silently failed. STATIC zero-init buffers happened
to work (hid it); the native test mocks crypto (never caught it). **Fix: NUL-
terminate in `_writeStr`/`_writeUtf8`.** General rule: any hal func returning a
C string must NUL-terminate, because wapps use strlen on the result.

### 12.7 Datagram sizes (observed)
keyset `ks` ≈ 1069 B (Resource), wrapped key ≈ 237 B (single packet), a short
chat message ≈ 244 B. LXMF single-packet max ≈ 360 B; above that → Resource.

### 12.8 Short-code discovery (rendezvous) — in progress
A joiner with only the lossy short code can't derive the owner's RNS dest, and
broadcast discovery (`cd`/`co`) is unreliable. The robust design (building):
a deterministic RNS identity is derived from the short code
(`RnsService._rvIdentity`: sha256-seeded `RnsIdentity.fromPrivateKey`); the owner
ANNOUNCES a `circles/rv` destination of it carrying `{fullCircleId, ownerDeliv}`;
the joiner derives the same identity, PATH-REQUESTS the rendezvous dest, reads the
appData → learns the owner's address → sends an ADDRESSED join request. Host:
`rvAnnounce` (fire-and-forget) + `rvResolve` (sync poll: kicks off the async
path-request, returns the appData once resolved). Open issue: if joiner→owner
direct push has a poor path, the join request may need a pull-based fallback
(the owner doesn't yet know the joiner to pull it).

### 12.9 Diagnostics added while debugging (REMOVE before shipping)
- wapp (`circle.c`): `RXDG:<k>` (every inbound datagram kind), `KS:*`
  (handle_keyset bail points), `KSTX/KSRX` (keyset+sig lengths) — all `notify()`.
- host: `RNS/wapp: rx datagram tag=… queued=…` in `_routeWappLxmf`; background
  `_drain` mirrors wapp `notify` bodies to `LogService` (so `/api/log` shows
  headless wapp diagnostics — NotificationService is in-memory only).
- These are temporary debugging aids; strip them for a clean build.

### 12.10 Test driving (headless, two phones)
`/api/wapp/start {wapp}` runs the wasm engine headless; `/api/wapp/cmd
{wapp,msg}` injects a flat `{"command":…}` and returns the outbox; `/api/wapp/tick
{wapp,n}` pumps N ticks (drains RNS/LXMF). `add_member_dests` (a test command)
adds a member with pasted dests to bootstrap the keyset addressed (the real
short-code flow replaces it). Both phones are driven via `adb forward` to the
in-app API; the C61 (budget phone) must run a RELEASE build (debug ANRs it).

## 13. Real short-code join + bidirectional sync (validated 2026-06-22, two NAT'd phones)

This session wired and validated the REAL short-code join end-to-end over the
public internet (TANK2 owner + C61 joiner on different networks, no LAN, no
hardware). The join works; bidirectional message sync exposed several real bugs,
fixed below. Five fixes shipped this session — each a genuine architectural
correction, not a workaround.

### 13.1 What the short-code join does, step by step (VALIDATED)
1. **C61 enters only the short code** (e.g. `5cc-d08`) in the add-circle screen ->
   `circle_apply_join`. It isn't a key, so C61 can't derive the circle id. It
   parses `first3-last3`, sets a pending search, and `discovery_tick` polls
   `hal_rns_rv_resolve`.
2. **Rendezvous resolve** (`RnsService.rvResolve`): C61 derives the SAME RNS
   identity the owner announces under (`_rvIdentity(seed)` = sha256-seeded
   `RnsIdentity.fromPrivateKey`, `seed = "<first3>-<last3>"`), PATH-REQUESTS the
   `circles/rv` dest of it, and reads its announce appData
   `"<fullCircleId>|<ownerDeliv>"`. Owner side: `rv_announce_owned()` runs every
   `circle_tick`. Validated: C61 logged "Found the circle" ~10 s after applying.
3. **Addressed join request**: `send_join_request_to(fullId, ownerDeliv)` sends a
   signed `jr` datagram (`hal_rns_send_to(ownerDeliv,...)`) carrying the joiner's
   own `dl`/`pp` dests so the owner can later deliver addressed.
4. **Owner receives it** -> `handle_jr` verifies the inline Schnorr sig, stores the
   request (with the joiner's `dl`/`pp` — new `deliv`/`prop` columns on `requests`)
   and notifies. Validated: TANK2 People panel History shows
   `applied: npub1rtp2xdhu3v5`. On Android this is the actionable notification.
5. **Owner approves** (`req_approve` -> `circle_approve_request`): reads stored
   `dl`/`pp`, calls `add_member_pub2` -> bumps epoch, wraps keys, re-signs and
   delivers the keyset ADDRESSED to the joiner. Validated: "Approved — they're in
   the circle"; C61 becomes an Active member; `KSTX kslen=378`.
6. **Joiner enters + posts**: C61 received the keyset, created the local circle,
   pulled its epoch key, and posted a message that decrypted+stored. Validated:
   C61 `ui.convo.msg` for its own posts.
7. **Owner auto-receives the joiner's live message**: Validated — TANK2 showed
   `in | C61 here after deliv fix` once the deliv bug (13.3) was fixed.

### 13.2 FIX (host, generic) — self-authenticating wapp datagrams bypass LXMF source-verify
The join request reached TANK2's HOST (`rx datagram tag=circles ... queued=true`)
but the LXMF router DROPPED it: `unknown source — requesting its path to verify`
-> `message from unknown source (no announce) — dropped`. On quiet/asymmetric
public hubs the sender's announce often never arrives, so the LXMF-layer signature
can't be checked. But wapp datagrams carry their OWN app-layer signature (the
`jr`'s inline Schnorr over the npub, verified in `handle_jr`), making LXMF-layer
source verification redundant. Fix: `LxmfRouter` gained an
`acceptUnverified(message)` predicate; when the source is unresolvable it delivers
anyway if the predicate returns true. `RnsService` sets it to
`(m) => m.fields.containsKey(_kWappLxmfField)`. Package stays generic (a
predicate); host expresses the policy. This made first-contact joins land.

### 13.3 FIX (wapp) — the keyset must carry the owner's LIVE delivery dest
Symptom: C61 had TANK2 as a member but `deliver_to_members` never sent to it, so
C61 couldn't reach TANK2 at all (history requests + posts went nowhere). Root
cause: TANK2's OWN member row had `deliv=(empty)` — its RNS dests weren't ready at
circle creation, and that empty deliv propagated to every member via the keyset.
Fix: `build_keyset_json` overrides the owner's own entry with the live
`g_deliv`/`g_prop` (after `ensure_dests()`). After a keyset rebroadcast C61's copy
of TANK2 went `dl=(empty)` -> `dl=a4437...` and Step 7 started working. Lesson:
never trust a stored dest written before the node had one; advertise live for self.

### 13.4 FIX (wapp) — new members get the FULL epoch-key history (read previous messages)
`handle_keyreq` served epoch keys only from the member's `added` epoch upward, so
a member added at the bumped epoch could never decrypt earlier messages -> stored
them `body IS NULL` and `circle_render` (body NOT NULL) showed nothing. Step 6
(a new member reads previous messages) requires the full key history. Fix:
`handle_keyreq` serves `for (e = 1; e <= top; e++)` (send_wrapped_key skips epochs
it lacks). `handle_key` already calls `decrypt_pending`, so stored-undecrypted
events get re-decrypted once old keys arrive. This is a deliberate policy choice:
new members read the whole back-catalogue (group-chat semantics), distinct from
the revocation model where a REMOVED member can't read FUTURE epochs.

### 13.5 FIX (wapp) — history pull not gated on "no events yet"
`circle_tick` only requested history when the events table was empty; once a
member posts its own message the table is non-empty, so it never pulls the OWNER's
earlier history, and the bounded retry could exhaust before the member could reach
the owner. Fixes: (a) `circle_tick` requests full history while `histtries < 8`
regardless of existing events (`handle_msg` dedups by id, so re-pulls are safe);
(b) `handle_keyset` resets `histtries=0` on any keyset for a non-owned circle;
(c) `circle_init` resets `histtries=0` on every launch.

### 13.6 FIX (host, generic) — dedup the store-and-forward mailbox
A sender that retries delivery (the owner replays history on every `rq`) piled
hundreds of IDENTICAL copies into `LxmfRouter._mailbox` (cap 256). The pull serves
the whole mailbox as ONE resource, so a bloated mailbox makes the resource huge
and the pull fails. Fix: `_storeForRelay` dedups by `m.hash` before adding.

### 13.7 Remaining issue — TANK2->C61 convergence is unreliable (Step 6 / reliable Step 7)
After 13.2–13.6, C61->TANK2 works (live posts arrive). TANK2->C61 does NOT reliably
converge: TANK2's direct push to C61 fails (C61's INBOUND is unreachable over its
current hubs — the documented asymmetry), so messages are stored for relay (now
deduped, ~19 held). C61 is supposed to PULL them (`pull_from_members` -> `pullFrom`
C61-initiated link to TANK2's PROPAGATION dest, which works regardless of inbound).
C61 *has* a path to TANK2's prop dest and the pull link sometimes establishes
(`propagation pull from bc84 (N held)` on TANK2), but the held-message RESOURCE
does not reliably transfer back to C61, so C61 ends up with its own posts only.
This is a TRANSPORT-RELIABILITY problem (resource transfer over a pull link when
the initiator's inbound is flaky), not a circles-logic bug. Likely next steps:
serve the mailbox as small per-message single-packet deliveries (or bounded
batches) instead of one big resource; add pull retry/ack; or validate the RNS
Resource responder->initiator path under asymmetric inbound. The architecture
(every member a propagation node; owner only needed to SIGN) is correct and both
*direct* legs are proven; the store-and-forward PULL leg needs hardening.

### 13.8 Debugging insight — native-heartbeat ticks hide wapp `notify`
A background wapp is ticked by BOTH the API (`/api/wapp/tick`, whose return value
is the outbox you see) AND the native foreground-service heartbeat (~1 Hz). A
datagram is drained by whichever ticks first — almost always the native heartbeat
— and its `notify`/diagnostic output is NOT returned to your API call and does NOT
reach `/api/log` (`hal_log` only fills the engine's in-memory `logs` list). So
`RXDG`-style `notify` diagnostics are invisible unless YOUR pump wins the drain
race. To observe headless flow reliably: (a) add a command that performs the
action SYNCHRONOUSLY and read its returned outbox (`force_histreq`, `dump_msgs`,
`members_dump`); (b) inspect the HOST log (`/api/log`) which DOES capture
`RnsService`/`LxmfRouter` lines (`rx datagram tag=... queued=...`, `stored message
for relay to ... (N held)`, `propagation pull from ... (N held)`,
`verified, delivering`).

### 13.9 Diagnostic commands added this session (TEMP — strip for a clean build)
`circles_list` (-> `CIRCLE <id>|<owner|member>|<short>|<name>`),
`members_dump` (-> `MEMBER <pub>|<status>|dl=...|pp=...`),
`dump_msgs` (re-emits a circle's decrypted messages as `ui.convo.msg`),
`force_histreq` (forces a full history request, bypassing `histtries`), plus
`DBG ...` notifies in `circle_on_datagram`/`handle_req`/`send_history_req` and
`KSTX/KSRX`. All marked TEMP; remove with the §12.9 set before shipping.

## 14. Closing Step 6 — pull hardening, decryption, render-on-open (validated 2026-06-22)

Step 6 (a member reads the owner's messages) was closed and VISUALLY VERIFIED:
C61 (joined by short code) shows "SYNCTEST 0.30 from TANK2" authored by TANK2's
npub, decrypted at rest; TANK2 shows "C61 here after deliv fix" from C61's npub.
Getting there took four more fixes + one key insight.

### 14.1 FIX (host, generic) — store-and-forward must serve SINGLE PACKETS, not one bulk resource
The pull served the WHOLE mailbox as one responder→initiator RNS Resource. That
direction is fragile when the puller's inbound is asymmetric (the keyset delivery
works because it's initiator→responder). Rewrote the propagation protocol: the
responder sends each held message as its OWN single link packet (`_ctxSyncMsg`),
ends with `_ctxSyncEnd`, and the initiator ACKs (`_ctxSyncAck`) so the responder
drops the mailbox; only batches containing an oversized message (e.g. a keyset)
fall back to the bulk Resource. Each small transfer is independent — a lost one is
just re-sent next pull, and the receiver dedups.

### 14.2 FIX (host, generic) — dedup the mailbox on CONTENT, not the LXMF hash
§13.6's dedup-by-`m.hash` was INEFFECTIVE: `LxmfMessage.create` folds the wall-clock
timestamp into the hash+signature, so the owner replaying the same circle message
every tick makes a NEW envelope each time → the mailbox refilled to its 256 cap
with near-identical copies → the pull batch was huge. Fix: `_contentKey(m)` =
sha256(dest+source+title+content+msgpack(fields)) — stable across re-sends — and
dedup the mailbox (`_mailboxKeys`) on that. Mailbox now holds one copy per
distinct logical message.

### 14.3 FIX (host, generic) — hold for relay IMMEDIATELY, not after a 30s push timeout
`send_` only stored a message for relay AFTER the direct push timed out (~30s), so
a recipient with a flaky inbound couldn't pull it for 30s. THIS was the actual
Step-6 blocker (short test windows always missed it). Fix: `_storeForRelay` UP
FRONT in `send_` (so the message is pullable immediately), attempt the direct push
in parallel, and `_removeFromRelay` (by content key) only on confirmed direct
delivery. With this, a fresh TANK2 message reached C61 and decrypted within one
sync cycle (events total 11→12, decrypted 6→7).

### 14.4 FIX (wapp) — render stored history when a circle is OPENED
Opening a circle showed "No messages yet" even with messages in the local db:
`conversations_open` set up the folder rail but never re-rendered the stored chat,
so history only appeared as messages arrived LIVE in that engine session. Fix:
`conversations_open` now calls `circle_render(id)` (re-emits `ui.convo.msg` for
every decrypted event) before opening the rail. This is also why the headless
`dump_msgs` diagnostic could "see" messages the UI couldn't.

### 14.5 KEY INSIGHT — distinguishing "didn't arrive" from "can't decrypt"
The decisive diagnostic was `events_stat` (total vs `body IS NOT NULL`, plus the
epochs of undecrypted events and a 4-byte fingerprint of each held epoch key). It
showed C61 had the owner's history events (they ARRIVED — transport was fine) but
`body NULL` at epoch 1, while holding an epoch-1 key. The undecryptable leftovers
are TEST CRUFT: ~10 redeploys with repeated epoch bumps churned the epoch keys, so
the ORIGINAL early ciphertext no longer matches any held key (all epochs even
collapsed to one fingerprint `fd318e98`). NEW messages encrypt+decrypt fine end to
end — proven by SYNCTEST. Lesson for diagnosis: always separate the transport
question (did the event row arrive?) from the crypto question (is `body` set?);
they have totally different fixes. Lesson for the product: heavy epoch churn can
strand old messages — a member must obtain an epoch key BEFORE that epoch's key is
superseded, or keep all historical epoch keys (which `handle_keyreq` now serves,
§13.4) AND the ciphertext must have been encrypted under the SAME key the owner
still holds.

### 14.6 Net state of the 7-step test
Steps 1–5 + 7: validated (real short-code join, owner approval, addressed keyset,
member posts, owner auto-receives). Step 6: the MECHANISM is validated — the owner's
message reaches the short-code-joined member, decrypts at rest, and renders
(screenshots). Remaining caveat: bidirectional convergence over the public hubs is
now reliable for messages sent after the fixes, but is still bounded by the
member's inbound reachability (the cooperative PULL is the workaround and now holds
messages immediately + serves them as robust single packets). The short-code
RENDEZVOUS discovery is validated but propagation-timing-dependent (resolved in
~10s for one circle, did not propagate in a multi-minute window for another) —
hardening the rv announce cadence/retention is a follow-up.

### 14.7 More diagnostic commands added (TEMP — strip for a clean build)
`events_stat` (total/decrypted counts + undecrypted epochs + per-epoch key
fingerprints). Plus the §13.9 set. The `circle_render`-on-open change in §14.4 is
NOT diagnostic — keep it.

## 15. Hardening the rendezvous announce (validated 2026-06-22)

§13.7/§14.6 flagged short-code discovery as propagation-timing-dependent (resolved
~10s for one circle, didn't propagate in minutes for a fresh one). Three host
changes fixed the ANNOUNCE side; the resolve became near-instant.

### 15.1 FIX — flood-exempt the `circles.rv` beacon
A joiner resolves the beacon by INGESTING the owner's `circles/rv` announce into
its path table (then `pathFor(rvDest)` returns the appData). On a busy public hub
the per-second announce-verify budget can DROP that announce. Fix: add
`RnsDestination.nameHash('circles', ['rv'])` to `priorityAnnounceNames` (the
name_hash is constant across all rv identities), so a joiner ALWAYS processes a
beacon even under flood. This is the single biggest win.

### 15.2 FIX — re-announce the beacon on a FAST host timer, decoupled from the wapp tick
The owner only re-asserted the beacon once per `circle_tick` (~15s), and a freshly
created circle's beacon isn't cached on any hub, so a joiner's path request often
found nothing. Fix: `rvAnnounce` records each beacon in `_rvActive` (seedHex →
appData+lastMs) and a host `Timer.periodic(8s)` re-announces all active beacons —
fast and independent of the slow wapp tick. Entries not re-asserted within 90s
(circle deleted / no longer owned) expire, so the set never grows unbounded.

### 15.3 FIX — keep the owner's DELIVERY/PROP dests fresh WHILE joinable
Resolving the beacon only gives the joiner the owner's address STRING; to push the
join request it must then PATH-REQUEST the owner's lxmf delivery dest, whose normal
service-announce cadence is 30s (charging+wifi) to 5 min (battery/cellular) — too
slow. Fix: the rv re-announce tick (which only runs while `_rvActive` is non-empty,
i.e. we own joinable circles) also calls `_announceLxmfDests()` so the delivery +
propagation dests are re-announced every 8s too. Validated: after this, the joiner
reliably had a path to the owner's delivery dest (`hasPath a4437` → true).

The resolver window was also extended 20s→40s to bridge re-announce cycles.

### 15.4 Result + remaining first-contact caveat
Validated live: a BRAND-NEW circle (`57c-fec`) that previously wouldn't resolve in
minutes now resolves in **0s** (the joiner had already ingested the flood-exempt
beacon by the time it applied), and the joiner reliably gets a path to the owner.
REMAINING: pushing the actual join request still depends on the OWNER'S INBOUND
accepting the joiner's direct link (a non-member applicant can't be PULLED — the
owner doesn't know it yet). When the owner's inbound link acceptance is flaky on
its current hubs (`connections: 0` while still receiving flooded announces), the jr
stalls even though discovery + the path to the owner both succeed. The robust fix
is to route the jr THROUGH the rendezvous: have the OWNER also run an inbound LXMF
responder on the rv identity's dest (which it already derives to announce) and the
joiner send the jr to the rv dest (which it has a path to) instead of the owner's
delivery dest — turning first-contact into a pull-like meeting point the owner
always serves. That is the recommended follow-up.

## 16. Join requests through the rendezvous (first-contact channel, built 2026-06-22)

Implemented the §15.4 follow-up so a join request no longer depends on the owner's
flaky delivery-dest inbound. The owner LISTENS on the same rendezvous identity it
already derives to announce, and the joiner sends the jr there as ONE encrypted
connectionless packet — no link handshake.

### 16.1 Mechanism
- **Owner**: when `rvAnnounce` emits a beacon it also registers the rv dest hash →
  rv identity in `_rvInboundDests`. `_onInbound` routes any DATA/SINGLE packet
  whose destHash is in that map to `_handleRvInbound`, which `rvIdentity.decrypt`s
  the payload and pushes it to `_wappInbox['circles']` (the same signed `jr`
  datagram `handle_jr` would get over LXMF, so it is verified the same way). The rv
  dest is re-announced every ~8s and flood-exempt (§15), so the hub keeps a FRESH
  route back to the owner — unlike the 30s–5min delivery-dest announce.
- **Joiner**: `send_join_request_to` derives the rv seed from the circle id and
  calls `hal_rns_rv_send(seed, jr)` → `RnsService.rvSend`, which derives the rv
  identity, `rvIdentity.encrypt`s the jr, and sends it via
  `RnsTransport.sendDataTo` (a new helper: HEADER_2 to the next-hop if we hold a
  path, else HEADER_1 broadcast for the hub to forward). One packet, no handshake.
- **Size**: the MTU is 500B. The jr's old `nm` field was the full bech32 npub
  (~63B) which pushed the encrypted packet over MTU, so `nm` was DROPPED (the owner
  shows the applicant's npub derived from `frm` anyway — the People panel already
  did). `rvSend` guards: if the encrypted packet would exceed MTU it logs and skips
  (the direct push + broadcast remain as fallbacks). The jr still rides all three
  channels (broadcast + addressed push + rv packet) for redundancy.

### 16.2 New surfaces
`RnsTransport.sendDataTo(destHash, data)`; `RnsService.rvSend` / `_handleRvInbound`
/ `_rvInboundDests`; `hal_rns_rv_send` (wapp_engine import + HAL header + native
mock); `send_join_request_to` drops `nm` and calls `hal_rns_rv_send`.

### 16.3 Validation status
Built, analyzes clean, native circles tests pass, deployed (0.31.0). The joiner's
code path is exercised live: `apply` → "Application sent", `rvSend` fires, and the
jr fits in one packet (no size-guard log). END-TO-END delivery was NOT confirmable
in this window: the test hit a degraded-propagation patch where the joiner (C61)
could no longer even RESOLVE the beacon (it resolved in 0s earlier the same
session) — and the rv packet, like the beacon, needs the rv-dest path to be present
at the joiner's hub, so when discovery is down the rv channel is down too. The
channel HELPS exactly the case it was built for — discovery succeeds (joiner has
the fresh rv-dest path) but the owner's delivery-dest inbound is stale — which
could not be reproduced while discovery itself was failing. Re-validate when hub
conditions recover: a join where the joiner resolves the beacon should land the jr
via `_handleRvInbound` ("RNS/rv: join request received on rendezvous dest …") even
with the owner's `connections: 0`.

### 16.4 `rvSend` self-heals its path
`rvSend` now PATH-REQUESTS the rv dest (12s wait) before sending if it holds no
path, so it works without a prior beacon resolution (the owner announces the rv
dest flood-exempt every ~8s, so the request is normally answered fast). Without a
path `sendDataTo` would only HEADER_1-broadcast, which a hub may not forward toward
a SINGLE dest.

### 16.5 IMPORTANT finding — addressed rv-routing can't beat a FULLY-DOWN owner inbound
Extended live testing (40 rounds, network recovered mid-test) showed the limit
precisely. The joiner RESOLVED the beacon every round (RV hardening solid) and sent
the jr via the rv channel, but the owner received NOTHING — it sat at
`connections: 0` while its `inbox` climbed past 1268, i.e. it reliably receives
FLOODED ANNOUNCES but cannot accept ANY addressed traffic (no inbound links, no
addressed single packets). The rv channel is still ADDRESSED delivery to the owner,
so it cannot overcome this: it helps the PATH-STALENESS variant of owner-inbound
(fresh rv announce → hub has a current route to the owner) but NOT the
INBOUND-FULLY-DOWN variant (hub can't deliver anything addressed to the owner at
all — likely the owner's hub is an announce/relay endpoint that doesn't route
inbound to that client, or a NAT/firewall that only sustains the outbound TCP the
flooded announces ride).

The ONLY channel that reaches such an owner is a FLOODED ANNOUNCE. The jr already
ALSO rides a wapp broadcast (`hal_rns_broadcast` → announce on the joiner's wapp
dest with the jr in app_data, which the owner ingests via the wapp-broadcast path
→ `_wappInbox['circles']`), and the wapp dest is flood-exempt on the owner.

### 16.6 FIX (host) — the jr broadcast now actually SENDS (raw app_data), and it CLOSES first-contact
Root cause the broadcast never landed: `wappBroadcast` JSON-wrapped a BASE64 copy of
the payload (`{t,p:base64(payload)}`), inflating it ~33%. A ~300B jr → ~400B base64
→ an announce of ~580B that EXCEEDS the 500B MTU, so `pkt.pack()` threw inside a
fire-and-forget async and the announce was never sent — silently, for every jr.
Fix: `wappBroadcast` now puts the payload in app_data as RAW bytes
(`[tagLen:1][tag][payload]`, parsed symmetrically on receive), removing the base64
inflation. A jr (~300B) now yields a ~472B announce that fits one MTU. `wappBroadcast`
also guards `pack()` in a try/catch and LOGS+skips anything still too big instead of
throwing into the void.

VALIDATED LIVE (2026-06-22): with TANK2's inbound FULLY DOWN the entire time
(`connections: 0`), C61 applied, the jr rode the flooded broadcast to TANK2 (~20s),
a candidate appeared, TANK2 approved, the keyset flowed back, and C61 JOINED RV Test
as a member — the complete first-contact join with NO working owner inbound. This is
the owner-inbound-independent path the addressed channels (push, rv-routing) could
not provide. (The rv-routing of §16.1–16.5 remains as a faster path when the owner's
inbound DOES work but its delivery-dest path is merely stale; the broadcast is the
floor that always works because flooded announces always reach the owner.)

Note: only the circles wapp uses `hal_rns_broadcast`, so the raw-format change is
self-contained. The wapp itself is unchanged by this fix (host-only).

## 17. Delete-circle feature + diagnostics cleanup (2026-06-22)

### 17.1 New feature — delete/leave a circle
There was no way to remove a circle. Added `circle_delete(circleId)` + a
`delete_circle` command + a "Delete circle" item (trash icon) in the circle's gear
menu (`screens/home.ui.json`, room slot). It drops the index row, the in-memory
cache entry (closing the per-circle db), and the host conversation row. It is
ROBUST to a stale list entry: it emits `ui.convo.remove` even when the circle is no
longer in the engine cache, so a lingering persisted conversation row (from a
circle removed in a prior session) can still be cleared.

Host fix it needed: `ConversationStore.remove` only removed a sender's messages
(`from`) or a single message (`id`+`key`) — there was no path to drop a whole
conversation ROW by id. Extended it so `ui.convo.remove {id}` (no `key`) removes
`items[id]` + its order entry. Validated live: deleting circles showed a "Circle
removed" toast and the rows vanished.

### 17.2 Stripped the temporary diagnostics
Removed everything marked TEMP across §12.9/§13.9/§14.7: the wapp commands
`circles_list`/`members_dump`/`dump_msgs`/`force_histreq`/`events_stat` (+ their
functions), the older `whoami`/`add_member_dests` test bootstrap (and
`circle_self_info`/`circle_add_member_dests`), the `dlog` helper and all `DBG …`
lines, `RXDG`, `KSTX`/`KSRX`, and the `KS:*` bail notifies (kept the early
returns). Host: removed the verbose `RNS/wapp: rx datagram tag=…` log in
`_routeWappLxmf` and the bg-manager `notify → LogService` mirror (+ its now-unused
import). KEPT the load-bearing non-diagnostic additions: `circle_render` on
`conversations_open` (§14.4), the `acceptUnverified` predicate, the rv channel, the
raw-broadcast format, and the rendezvous hardening. The wasm shrank ~26 KB.

### 17.3 FIX — list rows showed "No messages yet" for circles full of messages
The conversation-list row shows `subtitle` (or "No messages yet" if empty). But
`circle_init` re-emitted `convo_upsert(id, name, "", 0)` for every circle on every
launch, and the host's `upsert` does `if (d.containsKey('subtitle')) it.subtitle =
…` — so an EMPTY subtitle OVERWROTE the persisted last-message text with nothing.
`circle_save_edit` had the same wipe. Result: every circle read "No messages yet"
after any relaunch/edit, regardless of content. Fixes: (a) `convo_upsert` now omits
the `subtitle` field entirely when the preview is empty (never wipes); (b) new
`convo_refresh_last(i)` sets the row from the circle's LAST decrypted message —
`subtitle` = the message text, `badge` = its time (`fmt_time`) shown on the right —
used by `circle_init` and by `handle_msg`/`circle_send` on every live message (so
the badge stays current). A circle with no readable message yet keeps its existing
subtitle ("Invited"/"New circle" placeholder, or empty → "No messages yet").
Validated live (C61): Tank Squad → "SYNCTEST 0.30…" · 12:36:47, Gossip Test →
"MARKER-C61-XYZ789" · 09:41:40, RV Test → "No messages yet". NOTE: this is distinct
from the stale-deleted-row gap in §17.1; it's a separate subtitle-wipe bug.
