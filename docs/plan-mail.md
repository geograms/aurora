# Plan — the unified `Mail` wapp

> Status: approved by the user (2026-07-11), implementing.
> Goal: **one inbox**. Merge the messaging that today exists twice — in the
> **Chat** wapp (`tools.geogram.chat`) and the **Social** wapp
> (`tools.geogram.social`) — into a single wapp, `Mail`, that speaks
> **NOSTR** to send message notes between people.

## 1. Why this is a merge and not a rewrite

Both wapps already ship a *Messages* screen, and both render it with the **same
host widget**:

| | Chat (`chat/screens/home.ui.json:22`) | Social (`social/screens/home.ui.json:16`) |
|---|---|---|
| Screen | `Messages` (icon `mail`) | `Messages` (icon `mail`) |
| Widget | `group $type: "conversations"` | `group $type: "conversations"` |
| Conversation key | **callsign** (`N0CALL`, `#GROUP`) | **npub / hex pubkey** |
| Wire format | `am:<id> ENC1:<b64> ~<sig>` (custom) | **NOSTR kind-4** (NIP-04) |
| Encryption | `hal_encrypt` (ECDH + AES-256-CBC) | NIP-04, host-side |
| Transports | Reticulum direct + BLE + APRS-IS + NOSTR-relay backup | NOSTR relays |
| Code | `chat/main.c` — 5171 lines | `social/main.c` — 743 lines |

The duplication is literal, and the two disagree on the one thing that matters:
**what a conversation is keyed by.**

The decisive fact for the merge: `hal_nostr_dm_send` and `hal_relay_dm_send` both
publish **the same object** — *"a kind-4 NIP-04 DM, signed by the profile key"*
(`functionality_registry.dart:279`, `:384`). They differ only in **which relay
network carries it**: internet NOSTR relays vs Reticulum relay nodes. So a single
NOSTR event can be fanned across both, and both wapps' inboxes collapse into one.

## 2. The design in one paragraph

A message is a **NOSTR kind-4 event**. A conversation is keyed by the peer's
**pubkey** (npub) — never by callsign. The wapp publishes each message to *both*
relay networks (internet + Reticulum) and, when the peer is only reachable
off-grid, over the local transports too; every copy carries the same event id, so
the receiver de-duplicates and the user sees **one** message. A callsign becomes
what it should always have been: a human-readable **alias** that resolves to a
pubkey, not an address.

### Why npub is the key (and callsign is not)

- It is the only identifier NOSTR can actually address, sign for, and encrypt to.
- It is globally unique. A callsign is not: `X1`/`X3` auto-generated callsigns
  are non-unique by construction, and the Chat wapp already refuses to let them
  onto APRS-IS for exactly that reason.
- Chat already resolves callsign→npub before it can encrypt anything
  (`hal_relay_resolve`, three separate resolution paths). Keying by callsign means
  the *identity* is downstream of a lookup that can fail. Keying by npub inverts
  that: identity first, display name second.

Callsigns keep working as an input — you can still type `N0CALL` to start a
conversation. It just resolves to a pubkey first, and the conversation is filed
under the pubkey.

## 3. Transports — one event, several roads

Send fan-out for a message to peer `P` (all carry the **same kind-4 event id**):

1. **`hal_nostr_dm_send(P.hex, text)`** — internet NOSTR relays. Primary when online.
2. **`hal_relay_dm_send(P.npub, text, relays, mid)`** — Reticulum relay nodes
   (store-and-forward; survives NAT and reaches nodes with no internet).
   Relay set = the peer's *rendezvous* set (`hal_relay_for`) so sender and
   receiver independently derive the same relays.
3. **`hal_rns_send_to(dest, frame)`** — direct Reticulum to the peer's device
   dest(s), when known. Lowest latency; no relay involved.
4. **`hal_ble_advertise(frame)`** — BLE broadcast, when the peer is a local
   station. This is what keeps messaging working with **no internet at all**, and
   is the one capability Social never had. Off-grid is not a nice-to-have here.

Receive: `hal_nostr_event_recv` (kind 4), `hal_relay_dm_recv`, `hal_rns_recv`,
`hal_ble_scan_read` — all funnel into **one** `deliver()` that decrypts,
verifies, de-duplicates by event id, and emits `ui.convo.msg`.

**De-duplication is load-bearing.** The same message legitimately arrives 2–4
times (that is the point of the fan-out). The receiver keys on the NOSTR **event
id** — which is a hash of the event's own content and therefore identical across
every transport — and keeps a persistent seen-ring so a relay copy arriving after
a restart does not re-notify. Chat already learned this lesson the hard way and
carries a persistent `midseen` ring for it; we inherit the idea, keyed properly.

**APRS-IS is NOT a transport for this wapp.** Encrypted bodies cannot survive it
(7-bit mangling breaks base64 — Chat explicitly refuses, `chat/main.c:2728`), and
APRS-IS access is licence-gated. It stays in the Chat wapp where it belongs.

## 4. What the wapp does NOT do

The host already owns all of this — duplicating it would be the actual mistake:

- **Message history / persistence** — the host `ConversationStore`
  (`lib/wapp/geoui/conversation_store.dart`) persists conversations, unread state,
  mute, pin, close. The Chat wapp stores **no** message history at all; it emits
  `ui.convo.msg` and the host keeps it. We do the same.
- **NIP-04 crypto and BIP-340 signing** — host-side; the profile private key
  never enters wasm.
- **Rendering** — the `conversations` GeoUI widget draws the list and the room.

So the wapp is: transports in, decrypt/dedup, `ui.convo.*` out. It should be
*small* — closer to Social's 743 lines than Chat's 5171.

## 5. Host integration (already waiting for us)

The launcher header resolves its Mail icon **by intent** —
`_wappForIntent('mail')` (`launcher_page.dart:395`) — and no wapp currently
declares it, so the icon is dark. The manifest therefore declares:

```json
"provides": { "intents": ["mail"] }
```

Unread badge: the wapp emits `{"type":"unread","count":N,"intent":"mail"}`
(`background_wapp_manager.dart:430`), which lights the header icon and the app
tile. Running in the background, `{"type":"notify",...}` raises a native
notification for a new message.

## 6. Scope

**In:**
- New wapp `wapps/mail` — id `tools.geogram.mail`, title `Mail`,
  icon mail, `intents: ["mail"]`, autostart/background (messages must arrive
  when the app is closed).
- Conversations keyed by pubkey; display name + avatar from `hal_nostr_profile`;
  callsign shown as an alias when known.
- Send fan-out + unified receive + event-id dedup (§3).
- Start-a-conversation by npub, by callsign (resolved), or by picking a known
  contact (`hal_contacts_query`).
- Unread counts + notifications.
- Wapp unit tests (`tests/test_*.c` → `tests.wasm`, per SDK §20).

**Out (deliberately, for now):**
- Groups. Chat's groups are an APRS bulletin construct (`#GROUP`, `g/` filters).
  A NOSTR-native group is a different protocol question (NIP-28/29 or the Circles
  wapp's epoch-keyed model) and does not belong in the first cut.
- APRS-IS (§3).
- Deleting the Messages screens from Chat and Social. They keep working until
  this wapp is proven on-device; removing them is a follow-up commit, not a
  prerequisite. **Nothing is deleted until the replacement is validated.**

## 7. Outcome (2026-07-11) — built and validated

Shipped as `wapps/messages` v0.1.2 (`geograms/wapps` `989ae1a`). Validated on C61
and TANK2 on **different networks** (home Wi-Fi `192.168.178.x` vs phone hotspot
`172.20.10.x`, mutually unreachable at IP level, so every copy crossed a public
hub), on release-grade AOT builds:

- **Delivered both ways.** C61 → TANK2 and the reply back; messages decrypt and
  render `verified` (BIP-340), keyed by pubkey with the callsign shown as the
  alias (`X1A67X`).
- **The fan-out folds.** One message, both lanes, one bubble:
  ```
  [messages] recv key=47360655 (envelope)   <- first lane to land, shown
  [messages] fold key=47360655 (envelope)   <- the other lane's copy, folded
  ```
- **The launcher icon lights.** `provides.intents:["mail"]` resolves, and the
  header Mail badge shows the unread count.
- **Background delivery works** — the wapp autostarts, so messages arrive with
  the page closed.
- 20 wapp unit tests, run natively against the same source.

### The two bugs the device found (both silent)

Neither would have been caught by reading the code, and neither crashed anything:

1. **Lane 1 was dead.** The NOSTR subscription was made once in `module_init` —
   which, for a *background* wapp, runs before the relay hub exists. It returned
   0, and a subscription id that is never retried means no inbound DMs from
   internet relays for the life of the process (not even the echo of our own
   sent messages). Now established lazily and retried every tick. **Lesson: a
   background wapp must treat every host subsystem as "not up yet".**
2. **One message showed up as four.** The relay lane hands the message back as
   *host-encoded JSON*, so the dedup envelope's control bytes arrived as the
   literal characters `` — and `json_raw` returns raw values, escapes and
   all. The envelope went unrecognised, nothing folded, and the escape junk was
   visible in the message text. Fixed with `json_unescape`. **Lesson: anything
   crossing the HAL as JSON is escaped; decode before parsing it.**

### Known residue

- Conversations that received messages from the *pre-fix* builds still show the
  old `…` prefix in those historical bubbles — they are persisted in
  the host `ConversationStore` as they were delivered. New messages are clean.
- The `notify` reaches the in-app notification store but did not raise a **system
  tray** notification while the app was foregrounded; worth a follow-up.
- BLE / direct-RNS as message transports are **not** wired (see §3): the wapp
  cannot serialise a signed kind-4 itself, so an off-grid, no-relay hop would
  need a host HAL to publish a pre-signed event. Chat keeps its BLE lane in the
  meantime. **Nothing has been deleted from Chat or Social.**

## 8. Validation (as planned)

1. `make tests` in the wapp → `tests.wasm` (codec, dedup, key handling) run by
   the host tester.
2. Build + install on **C61 and TANK2**, which are on **different networks**
   (per `docs/performance.md` §4 and the "test on different networks" rule — a
   same-LAN test takes the RNS `via lan` shortcut and is a false positive).
3. Send C61 → TANK2 and back. Assert: message arrives, decrypts, shows **once**
   (dedup across the fan-out), unread badge lights the launcher header icon.
4. Kill the app on the receiver, send, reopen → the message is there (background
   delivery + store-and-forward).
5. Confirm the same message is not double-notified when the relay copy lands
   after the direct copy.

## 8. Renamed to `Mail` (2026-08-02)

The wapp shipped as `Messages` and was renamed to **`Mail`** — folder
`wapps/messages` → `wapps/mail`, id `tools.geogram.messages` →
`tools.geogram.mail`, title/screen `Messages` → `Mail`, icon
`media/icons/mail.svg`, first release `0.2.0`.

The launcher **intent** moved with it: `messages` → `mail`. Both sides changed
together (`manifest.provides.intents`, the wapp's `unread`/`notify` payloads,
`_wappForIntent('mail')` and `_HomeHeader`'s badge). A device still running the
pre-rename wapp therefore stops lighting the header badge until the bundled
0.2.0 lands — which it does on the next launch via `upgradeBundledWapps`.

Two compatibility surfaces are kept deliberately:

- Host accepts **both** `mail.open` and the legacy `messages.open` outbox type
  (`wapp_page.dart`), so a not-yet-upgraded Chat build still routes NOSTR people
  into the inbox.
- `migrateMessagesToMail` (`launcher/seeding.dart`, registered as a boot task
  before seeding) moves the installed program dir, the **data dir** (conversation
  history, dedup ring, peers), the autostart preference and the offered-set
  entries. Without the data-dir move the rename would read as history loss.

## 9. Blocking (0.2.1)

An inbox anyone can write to needs a way to say **no**: a spammer knows your
key, so the only defence is dropping what arrives from theirs.

**Keyed on the pubkey, never the name.** A display name is a kind-0 nickname —
or, for a stranger, the 12-char truncation of their key (`fa31ff61cfa7`) — and
both are things the spammer chooses. The block list holds 64-char hex keys,
persisted in the wapp's KV under `blocked` (";"-joined), so it survives a
restart. Nothing is transmitted: the sender is never told, and there is no list
to leak.

Entry points:

| Where | What happens |
|---|---|
| **☰ menu** (top-right) with a conversation open → *Block <name>* | host confirms, then sends `conversations_block` with `conversations_convo` (the peer's key) + `conversations_blockcall` (display name). The same menu carries *Mute notifications* and *Close conversation* |
| Long-press a message → **Block** | same command, no confirmation (the sheet is already an explicit choice) |
| **Blocked** screen → *Block a key* | `ui.prompt` for an npub / hex key |
| **Blocked** screen → *Unblock* | `ui.prompt` with the blocked keys as one-tap chips |

`block_convo()` adds the key, then emits `ui.convo.remove` for that thread —
blocking a spammer has to remove the spam already on screen, not just the next
message. `ingest()` drops a blocked sender **before** the dedup ring, the
conversation store and the notification, so nothing lights up.

Two host changes came with it, both generic:

- `ConversationsField.onBlock` now yields `(id, from)` instead of `from` alone,
  and `wapp_page` puts the id in `<field>_convo`. A pubkey-keyed wapp cannot
  block on a display name; a callsign-keyed one (Chat) still reads `blockcall`.
- The ☰ options menu grows Mute / Close / Block entries **as text** whenever a
  conversation is open, in every layout (the old thread-chrome path only
  existed below 640px). A long-press is invisible: someone being spammed looks
  for a menu, so the menu has to carry it. Block asks for confirmation there,
  since it takes the thread off the screen.
- Icon vocabulary gained `block`.

Also fixed while in here: the New-message prompt sent a `fields:[…]` array,
which `ui.prompt` ignores — the box had chips and no way to type a key — and
its result was read from `to`/`value` instead of `prompt_value` /
`prompt_input`. Prompt results now dispatch on `prompt_id`
(`newmsg` / `blockkey` / `unblock`).

### 9.1 Where Block lives in the UI (verified on Linux desktop, 2026-08-02)

Three entry points, all reaching the same `conversations_block` command, all
screenshot-verified against a live spammer (`fa31ff61cfa7…310e988`):

1. **Conversation row ⋮** — Mute / Close / *Block <name>*.
2. **Message bubble ⋮ (or long-press)** — Info / Copy / Forward / Hide this
   message / *Block <name>*.
3. **☰ app-bar menu** — *Mute notifications* / *Close conversation* /
   *Block <name>*, shown ONLY while a conversation is open; with nothing
   selected the menu holds just the panel screens (Blocked, Status) and Edit
   wapp. The gate is `convActionsId`, not the narrow-layout `thread` variable —
   the wide side-by-side layout has an open conversation too.

All three confirm first (`_confirmBlockConversation`), because blocking removes
the thread and its messages from the screen.

Blocked senders are logged (`[mail] blocked drop from <key>`) — a message that
vanishes with no trace is indistinguishable from a delivery bug. Note the host
log ring is small and NOSTR-chatty; read it from `/api/log` and grep.
