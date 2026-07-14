# Plan — third-party NOSTR signers (Amber, bunker), and the APRX phase-out

> Status: approved (2026-07-13), implementing. The seam (`NostrSigner` +
> `LocalSigner`) has landed; nothing else is wired up yet.
> Goal: **let the key live somewhere else.** A user logs in with the account that
> already exists in their signer, and Aurora never possesses the private key.

## 1. Why

The only way into Aurora is to hand it your secret: `WelcomePage` offers "paste
your nsec1…" (`lib/profile/welcome_page.dart:306`), and the app then holds it
(encrypted at rest since the profile-storage work, but still *possessed*). Anyone
with a real NOSTR identity keeps it in Amber or a bunker for exactly the reason
that makes this a non-starter — applications are not supposed to see it.

## 2. What the APRS retirement changed

The first version of this plan needed a whole workaround, because four things
could not be delegated to any signer. Two of them existed **only because of
APRS**: compact, bespoke crypto was the price of fitting a signed message into an
APRS frame.

| Was | Why it existed | Now |
|---|---|---|
| `hal_identity_sign` — APRX **48-byte truncated Schnorr** over raw bytes (`aprx_sign.dart:76`). chat ×4, circles ×3 | An APRS frame had no room for a real signature | **Deleted.** Chat messages become signed NOSTR events (standard 64-byte Schnorr). |
| `hal_encrypt` / `hal_decrypt` — **custom ECDH + AES-256-CBC** (`aprx_sign.dart:216`). chat ×3, circles ×4 | Same: a bespoke envelope small enough for APRS | **Deleted.** Circles epoch envelopes and chat DMs become **NIP-44**; the legacy kind-4 inbox stays NIP-04. |

With APRS gone, the size argument goes with it — 64 bytes against 48, on a
transport (Reticulum) where that is nothing. Chat has been RNS-primary since
`chat v0.2.109`.

**Consequence: no device key, no cross-certification event, no new protocol, no
peer migration.** Aurora becomes an ordinary NOSTR client that happens to run over
Reticulum, and a signer can do everything an identity needs to do.

### The two things that still need a local secret

Neither is your identity, and neither needs anyone else to verify it:

- **The coin wallet** (`coin_host_bridge.dart:162` → `CoinService(myPriv:)`) needs
  raw scalar material. It gets its **own generated key**. A wallet is not an
  identity; nothing outside the coin system checks it against your npub.
- **The profile KEK.** Encrypted storage derives
  `KEK = HKDF-SHA256(KEK_pw ‖ nsecBytes, salt)` and keeps the nsec encrypted at
  rest (`profile_crypto.dart:7-21`) — deliberately, so *"a profile folder copied
  off the device cannot be opened without BOTH the password and the nsec"*. A
  signer account has no nsec, so it mixes a **locally-generated 32-byte profile
  secret** instead. The property is unchanged (something you know × something on
  the device); only the source of the second factor moves.

## 3. The seam (landed)

`lib/services/nostr/nostr_signer.dart`:

```dart
abstract class NostrSigner {
  Future<String> publicKey();
  Future<NostrEvent> signEvent(NostrEvent unsigned);
  Future<String> nip04Encrypt(String peerPubHex, String plaintext);
  Future<String> nip04Decrypt(String peerPubHex, String ciphertext);
  bool get isLocal;        // key is here: sync-capable, never fails
  bool get worksHeadless;  // bunker yes; Amber intent NO
}
```

Everything is async because a signer **is** async: an Amber signature is an intent
the user approves; a bunker signature is a websocket round trip to another machine.
Failures are typed (`refused` / `unavailable` / `malformed`) because the difference
between "the user said no" and "not reachable right now" decides whether an
operation is *shown as refused* or *queued*.

`LocalSigner` is today's behaviour behind the interface, with tests proving
existing accounts are unaffected: same event id, signatures verifying under the
same pubkey, NIP-04 round-tripping against the implementation every peer already
uses. (BIP-340 is randomised — signature *bytes* differ between two signings of the
same message; the id is the stable thing, and the test says so.)

**To add:** `nip44Encrypt` / `nip44Decrypt` — both Amber and NIP-46 expose them,
and the new chat/circles crypto is NIP-44.

It replaces three chokepoints: `RnsService._profilePrivHex()`
(`rns_service.dart:5477`, feeds ~12 sign sites), `WappEngine._profilePrivScalar()`
(`wapp_engine.dart:460`), and `FolderService.adminPrivHex` (already an injected
closure).

## 4. The signers

- **`Nip46Signer`** — a remote bunker. Reuses `NostrWsClient`
  (`reticulum-dart/.../nostr_ws_client.dart`: cross-platform, reconnecting, replays
  subscriptions) plus kind-24133 request/response. Works on Android, on Linux, and
  **headless** — no Activity. This is the only signer that can sign while the app
  is in the background, which makes it the one that matters most (§6).
- **`Nip55Signer`** — Amber, over a new `com.geogram.aurora/signer` method channel
  following the `WifiDirect(context, messenger)` shape (`NativeBridgeRegistry.kt`).
  Needs `startActivityForResult`, which **does not exist** in `MainActivity.kt`
  today (only `startActivity`) — that plumbing is new.

## 5. The HAL becomes request/poll/read

The engine already has this idiom (`hal_http_*` → poll → read; `hal_relay_dm_fetch`
→ `hal_relay_dm_recv`). Key operations join it:

```c
uint32_t hal_nostr_post_request(const char* json, uint32_t len);  /* -> reqId */
int32_t  hal_nostr_post_poll(uint32_t reqId);   /* 0 pending, 1 ready, <0 refused */
uint32_t hal_nostr_post_read(uint32_t reqId, char* out, uint32_t cap);
/* same triple for: dm_send, dm_decrypt, react, repost, reply */
```

A wasm call cannot await, and a signer cannot answer immediately. Pretending
otherwise builds a UI that lies about whether a post was published.

The synchronous imports keep working **for local-key accounts**, so wapps migrate
one at a time instead of in a flag day; on a signer account they return a
documented "use the async API" failure rather than a wrong answer.
`hal_identity_sign`, `hal_encrypt` and `hal_decrypt` are **removed**, not made
async — after §7 nothing uses them.

## 6. Headless, and the signing outbox

Most of the app's key use happens with nobody watching: autostart wapps tick at
boot under `BackgroundWappManager`, `social.note` is published from a **closed**
wapp page (`background_wapp_manager.dart:428` — *"which is most of them"*), Blossom
signs a kind-24242 per upload, and the launcher **auto-signs unsigned wapp packages
during its startup scan** (`launcher_page.dart:161`).

A bunker signs all of that. **Amber cannot** — an intent needs a foreground
Activity. So: a **signing outbox**. The host builds the unsigned event and computes
its id — *which needs no private key* — persists it, and returns immediately. The
outbox drains when the signer is reachable (bunker) or the app next comes to the
foreground (Amber). A refusal is surfaced; nothing is silently dropped.

## 7. Migration, wapp by wapp

Each ships independently, in this order:

1. **social** — `hal_nostr_post` / `react` / `reply` / `repost`. Plain events.
   Proves the async HAL and the outbox end to end.
2. **messages** — `hal_nostr_dm_send` / `dm_decrypt`, `hal_relay_dm_*`. NIP-04
   through the signer. Decrypt becomes poll+read **with a cache**: it runs per
   message across the whole inbox, so a round trip each is not viable.
3. **circles** — `hal_encrypt`/`hal_decrypt` → **NIP-44** on the epoch-key
   envelopes; drop `hal_identity_sign`. A wire-format change, but circles are
   private groups: the blast radius is only members, who all update together.
4. **chat** — drop the APRX `~sig` and the `ENC1:` envelope; messages become signed
   NOSTR events + NIP-44. **Last, and the one with real fallout:** other geogram
   devices already speak that wire format. Old builds will show the new messages as
   *unverified* (not forged), and old `ENC1:` history must still open — so
   `AprxSign.decryptFrom` stays on the **read** path for one release, and the UI
   says what is happening.

## 8. Onboarding

`WelcomePage` gains a third route beside "create new" and "restore backup":
**"Use my NOSTR signer"** → Amber if installed, else a bunker (`bunker://` paste or
a `nostrconnect://` QR). Then: fetch kind-0 for that pubkey to fill
nickname/avatar, derive the callsign from the npub exactly as now
(`profile_service.dart:142`), generate the coin key and the profile secret, and ask
the signer for one signature — which doubles as proof it really holds the key.

- `IwiProfile` gains `signerKind` (`local|nip55|nip46`) and `bunkerUri`; `nsec` is
  **empty** for signer accounts. **Every `nsec.isEmpty` check in the codebase
  currently means "broken profile"** and will start meaning "signer account" — that
  audit is the sharpest edge in this work.
- The **vanity callsign generator** (`vanity_callsign_page.dart`) is meaningless in
  signer mode — you cannot grind a key you do not hold — and is hidden, not left to
  fail.
- "Reveal secret key" (`profile_edit_page.dart:290`) and the nsec paste path stay
  for local accounts, hidden for signer ones.
- **Identity backup** (`identity_backup.dart`) has nothing to back up for a signer
  account. It must say so, not write an empty envelope.

## 9. Files

| File | Change |
|---|---|
| `lib/services/nostr/nostr_signer.dart` | landed; add NIP-44 |
| `lib/services/nostr/nip46_signer.dart`, `nip55_signer.dart`, `signing_outbox.dart` | **new** |
| `android/.../SignerBridge.kt`, `MainActivity.kt`, `NativeBridgeRegistry.kt` | Amber intents + `startActivityForResult` (new) |
| `lib/profile/iwi_profile.dart`, `profile_service.dart`, `welcome_page.dart`, `profile_edit_page.dart`, `vanity_callsign_page.dart`, `identity_backup.dart` | signer kind, empty nsec, the new login route |
| `lib/profile/profile_crypto.dart` | KEK mixes a **local profile secret** when there is no nsec |
| `lib/services/reticulum/rns_service.dart` | `_profilePrivHex` → signer; ~12 sign sites async |
| `lib/wapp/wapp_engine.dart` | HAL v2; **delete** `hal_identity_sign` / `hal_encrypt` / `hal_decrypt` |
| `lib/wapp/coin/*` | its own generated wallet key |
| `wapps/{social,messages,circles,chat}/main.c`, `wapps/hal/geogram_wasm_hal.h` | the four migrations |
| `reticulum-dart/.../aprx_sign.dart` | verify/decrypt only, then delete (its `nip04*` helpers stay — they are real NIP-04) |

## 10. Verification

**Unit:** a `FakeSigner` (async, refusable) drives every host sign site; the outbox
survives a restart and drains in order; a refusal surfaces rather than vanishing;
**local-key accounts stay byte-identical** — the regression that matters most,
because every existing user is one.

**Live** (C61 with Amber, desktop with a bunker):

1. Log in with Amber → `profiles.json` contains **no nsec**. One grep; it is the
   entire point of the feature.
2. Post from Social → Amber prompts → the post appears in another client (`nak`,
   damus) under the right npub.
3. DM round trip through the signer.
4. Kill the app; a background wapp publishes a `social.note` → it is **queued**, not
   lost, and lands on the next foreground. With a bunker, the same note is signed
   **headless**, no prompt.
5. Chat + Circles between two devices on the new NOSTR crypto; an **old** build
   shows those messages as unverified rather than forged, and old `ENC1:` history
   still decrypts.
6. A local-key account behaves exactly as before.
