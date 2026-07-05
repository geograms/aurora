# APRX — APRS eXtended messaging protocol

> Part of the Geogram protocol docs — see [README](README.md) for the full set
> ([Reticulum](reticulum.md), [DHT](dht.md), [APRS transport](aprs.md),
> [BLE transport](ble.md), [file sharing](file-sharing.md)).

APRX is a thin set of **conventions layered on top of standard APRS**. Every
APRX frame is a 100% valid APRS frame: a vanilla APRS client shows it as
ordinary text and ignores the parts it doesn't understand. APRX adds, purely
through how the text/addressee fields are filled in:

- multi‑line (long) messages,
- group messages (bulletins) with **local vs global** scope,
- message **threads** (replies),
- **reactions** ("likes"),
- **public‑key announcements** (callsign → key, for later encrypted DMs),
- **geo‑chat** (area broadcast text).

There is **no new packet type, no binary framing, no handshake**. If you can
send and receive APRS messages/bulletins/position reports, you can speak APRX.

This document is the wire contract so other apps can interoperate. It describes
two transports — APRS‑IS (TNC2) and APRS‑over‑BLE — but the *semantics* are the
same on both.

---

## 1. Design principles

1. **Backward compatible.** An APRX frame is a legal APRS frame. Non‑APRX
   clients still display the body; they just see markers like `+b9fb ` or
   `b9fb:like` as plain text.
2. **Stateless & derivable.** A message's identity is *computed from its own
   content* (§3), so any receiver derives the same id without a registry,
   sequence negotiation, or extra fields. Threads/likes reference that id.
3. **Transport‑agnostic.** The same conventions ride APRS‑IS and BLE. The only
   difference is framing/size limits.
4. **Scope is a receiver concept.** "Local" vs "global" is decided by *how you
   filter*, not by anything on the wire (§7). The transmitted bytes are
   identical.

### Limits

| | APRS‑IS (TNC2) | BLE compact advert |
|---|---|---|
| Message body | **67** chars (`APRS_MAX_MSG_LEN`) | keep whole frame ≤ ~27 bytes |
| Bulletin body | 67 chars/line, up to **10 lines** (BLN0–BLN9) | as above |
| Position comment | 107 chars | as above |

Anything longer is split (§5) on APRS‑IS, or sent over the chunked/GATT BLE
parcel transport on capable hardware (see `BLE_PROTOCOL.md`).

---

## 2. Transports

### 2.1 APRS‑IS / TNC2

Standard APRS over an APRS‑IS connection. Frames are normal TNC2 lines. Login
uses a computed passcode; the server‑side filter is `r/<lat>/<lon>/<km>`
optionally extended with `g/...` terms (§7).

- **Direct message:** `FROM>APRS,TCPIP*::ADDRESSEE :text{seq`
  - `ADDRESSEE` is the callsign, **uppercased and space‑padded to 9 chars**.
  - `{seq` is an incrementing message number (used for ack + multi‑line merge).
- **Bulletin (group):** `FROM>APRS,TCPIP*::BLN<id><GROUP>:text`
  - addressee = `BLN` + one line‑id char + group name, **padded to 9 chars**.
  - bulletins carry **no `{seq`** and are never acked.
- **Position:** `FROM>APRS,<path>:!<DDMM.mmN><symtable><DDDMM.mmW><symcode><comment>`

### 2.2 APRS‑over‑BLE (compact)

Connectionless broadcast in manufacturer data (company id `0xFFFF`). Fields are
separated by the unit‑separator byte `0x1F`:

```
<from> 0x1F <to> 0x1F <text>
```

- `to` routing target:
  - a callsign → 1:1 message
  - `#GRP` → group/bulletin message (group name only, **no scope marker**)
  - `!` → position; `text` = `lat,lon[,comment]` (decimal degrees)
  - empty → area / geo‑chat broadcast text (may begin `>>`)

The **payload semantics below (threads, likes, pubkey, geo‑chat) apply
identically to the BLE `text` field.** See `BLE_PROTOCOL.md` for the byte‑level
advert format, dedup, and BLE↔APRS‑IS relaying.

---

## 3. Message id (the foundation)

Every group message has a short **message id (`mid`)**: the **first 4 lowercase
hex characters** (= first 2 bytes) of the SHA‑1 of the string

```
<from> "|" <text>
```

where:
- `<from>` is the sender callsign exactly as it appears in the frame,
- `<text>` is the **exact transmitted body** — *including* any leading thread
  marker (§6). The id is computed over the raw wire text, even though the marker
  is stripped before display.

```
mid = lowerhex( SHA1( from + "|" + wire_text ) )[0:4]
```

**Worked example** (byte‑identical to standard SHA‑1):

```
from = "X1TX"
text = "GROUPTEST12175 hi"
SHA1("X1TX|GROUPTEST12175 hi") = b9fb...   →  mid = "b9fb"
```

This id is stable, content‑derived, and identical for every receiver, so it can
be referenced by threads and likes without any coordination. Ids are only
defined for **group** traffic (§5/§6); 1:1 messages don't use them.

> Collision note: 16 bits (65 536 values) is enough for a human‑scale group
> conversation. A receiver scopes ids per group + recent window; implementers
> may widen to 6–8 hex if they need more, but **must** keep the
> `first‑N‑hex‑of‑sha1(from|text)` rule so ids agree across apps.

---

## 4. Direct (1:1) messages

Plain APRS messages addressed to a callsign. No APRX additions beyond §5
(multi‑line). Threads/likes/scope do **not** apply to 1:1.

```
X10EGL>APRS,TCPIP*::CT1ABC   :see you at the repeater{12
```

---

## 5. Multi‑line (long) messages

A body longer than the limit is split into multiple frames; the receiver
concatenates them back.

**Splitting rule** (APRSdroid‑compatible): break at the **last space at or
before `max_len`**; only hard‑break a single word that itself exceeds `max_len`.
Trailing spaces of a chunk and the gap before the next chunk are trimmed; parts
are rejoined with a single space.

- **Direct messages:** each chunk is a normal message with its **own
  incrementing `{seq`**. The receiver merges consecutive parts from the same
  sender. (`aprs_send_message_multi`.)
- **Bulletins:** each chunk is line **`0,1,2,…`** of the same group, encoded in
  the bulletin **line id** (`BLN0GRP`, `BLN1GRP`, …). Capped at **10 lines**
  (`BLN0`–`BLN9`). Receiver orders by line id. (`aprs_send_bulletin_multi`.)

```
X10EGL>APRS,TCPIP*::BLN0NET  :Weekly net tonight 2000Z on the
X10EGL>APRS,TCPIP*::BLN1NET  :club repeater — all welcome, bring
X10EGL>APRS,TCPIP*::BLN2NET  :a friend.
```

---

## 6. Group messages (bulletins)

A group message is an APRS **bulletin** whose addressee is `BLN<id><GROUP>`:

- `<id>` — line id (`0`–`9`), used to order multi‑line bulletins (§5).
- `<GROUP>` — group name: **1–5 chars, uppercased, alphanumeric**, the rest of
  the 9‑char addressee field space‑padded.

```
addressee = "BLN" + line_id + GROUP, padded to 9
e.g.  BLN0NEWS , BLN0WX   , BLN0NOSTR
```

The frame's **`from` field is the author's callsign**. Bulletins are broadcast:
anyone whose filter selects them receives them.

```
X10EGL>APRS,TCPIP*::BLN0NEWS :repeater PI3UTR back on air
```

Over BLE the same message is `from 0x1F #NEWS 0x1F repeater PI3UTR back on air`.

### Reserved group names

| Group | Meaning |
|---|---|
| `NOSTR` | Public‑key announcements (§9). Receivers should treat these as identity records, not chat. |

---

## 7. Local vs global scope

**Scope is not on the wire.** The transmitted bulletin for `NEWS` is the same
whether the sender thinks of it as local or global. Scope is how the *receiver*
chooses to pull the group:

- **Local** — rely on the standard area filter `r/<lat>/<lon>/<km>`. You see a
  group's bulletins only from senders inside your radius. (APRS‑IS positions the
  sender; BLE is inherently in‑range.)
- **Global** — additionally ask APRS‑IS for the group worldwide with a bulletin
  filter term. Geogram adds a single catch‑all **`g/BLN*`** when any global group
  is subscribed, then files only the groups the user actually joined.

> **APRS‑IS `g/` gotcha (verified live against aprsc):** `g/` has **no
> mid‑string wildcard**. `g/BLN?NEWS` and `g/BLN*NEWS` both **miss**. Only an
> exact addressee (`g/BLN0NEWS`) or a **trailing** wildcard (`g/BLN*`) match.
> Because worldwide bulletin volume is tiny, the `g/BLN*` catch‑all + local
> filtering is the practical approach.

A client may represent the two views as two subscriptions (e.g. `#NEWS` local,
`#NEWS*` global). That `*` is a **local UI marker only** — it is stripped before
transmitting; the wire group is always the bare name.

---

## 8. Threads (replies)

A reply is an ordinary group message whose **body begins with a thread marker**:

```
+<pmid><SP><reply text>
```

- `+` literal,
- `<pmid>` — the 4‑hex `mid` (§3) of the message being replied to,
- one space, then the reply text.

```
X1BOB>APRS,TCPIP*::BLN0TEST :+b9fb agreed, see you there
```

Receiver behaviour:
- Detect the marker (`+`, 4 hex, space). Record `parent = b9fb`.
- **Strip the marker for display**; show the remainder as the message text.
- This reply's **own `mid` is computed over the FULL body including the marker**
  (`SHA1("X1BOB|+b9fb agreed, see you there")[0:4]`), so replies can be
  replied to in turn.

Non‑APRX clients simply show `+b9fb agreed, see you there` verbatim — still
readable. Threads are **group‑only**.

---

## 9. Reactions ("likes")

A like is an ordinary group message whose **entire body** is:

```
<mid>:like
<mid>:unlike      (retracts)
```

- `<mid>` — the 4‑hex id (§3) of the target message,
- the verb is exactly `like` or `unlike`.

```
X1ZED>APRS,TCPIP*::BLN0TEST :b9fb:like
```

Receiver behaviour:
- Recognise the form `^[0-9a-f]{4}:(like|unlike)$` and treat it as a **vote, not
  a chat message** (don't render it as a bubble, don't notify).
- Tally by **liker callsign** (the frame `from`): each callsign counts **once**;
  a repeat `:like` is idempotent; `:unlike` removes that callsign's vote.
- The deliberately human‑readable form (no special byte) lets **any** APRS
  client like a message by sending e.g. `b9fb:like` to the group.

Likes are group‑only and ride the same transports (APRS‑IS bulletin / BLE
`#GRP`).

---

## 10. Public‑key announcement

Every node **periodically announces its Nostr public key on APRS‑IS** — this is
**on by default**. A station advertises its public key so peers can build a
**callsign → public‑key** map and later send it **encrypted** messages (and verify
its **signed** ones, §14). It is the public‑key *beacon*; in the wapp it is
`pkbeacon_send` (`wapps/aprs/main.c`), gated by the `g_pubkey_beacon` flag
(default on, persisted in KV `pkbeacon`, toggled by "Broadcast my public key" in
Settings).

- Transport: a **bulletin to the reserved group `NOSTR`** (§6) on **APRS‑IS**,
  and the same over BLE (`#NOSTR`) — whichever transports are up. It fires only
  once a profile key exists.
- **Body = the 32‑byte public key, base64url‑encoded, no padding = 43 chars.**
  (The key is a Nostr/`secp256k1` x‑only public key — the 32 bytes an `npub`
  bech32 string encodes. base64url is used instead of the 63‑char `npub` so the
  record fits one 67‑char APRS message and a small BLE advert.)

```
X10EGL>APRS,TCPIP*::BLN0NOSTR:flH3-_InWKh9SjUYCetLr5rBgozalyqyTiJA1fH4kHI
```

Mapping for a receiver:
- `callsign` = frame `from` (here `X10EGL`),
- `pubkey`  = `base64url_decode(body)` → 32 raw bytes (use directly for NIP‑04 /
  NIP‑44 encryption, or re‑encode to `npub` for display).

Recommended cadence: low (the key rarely changes) — Geogram sends one **every
hour**, on whichever transports are up (APRS‑IS and/or BLE). A receiver should
treat repeats as refreshes of the same record. Geogram only **persists** the keys
of callsigns it actually interacts with (chats with or follows): a NOSTR beacon
from a stranger is parked in memory and promoted to the stored map the moment you
interact with that callsign. These beacons are intercepted before the chat layer,
so they never appear as messages.

> The base64url alphabet is `A–Z a–z 0–9 - _`. Encode the raw 32 bytes and strip
> any `=` padding. Decoding is the inverse.

---

## 11. Geo‑chat (area broadcast text)

Free‑text "anyone around?" chatter tied to a location, carried as the **comment
of a position report**, prefixed with `>>`:

```
X10EGL>APRS,TCPIP*:!3843.34N/00908.36W>>>net starting now
```

(`>` is the symbol code; `>>` then begins the comment.) Long geo‑chat is sent as
several position reports, each comment chunk prefixed `>>`. Over BLE it's the
empty‑`to` form: `from 0x1F  0x1F >>net starting now`.

Receivers show these on a location‑scoped "live" view rather than as a
1:1/group conversation.

---

## 12. Worked end‑to‑end example

A small `TEST` group thread with a like and the author's key, as seen on
APRS‑IS:

```
# 1. original post  (mid = sha1("X1TX|hi there")[0:4] = … )
X1TX>APRS,TCPIP*::BLN0TEST :hi there

# 2. a reply to it  (parent = <mid of #1>; this reply has its own mid)
X1BOB>APRS,TCPIP*::BLN0TEST :+<mid1> agreed

# 3. someone likes the original (counts once per callsign)
X1ZED>APRS,TCPIP*::BLN0TEST :<mid1>:like

# 4. X1TX advertises its public key for encrypted replies
X1TX>APRS,TCPIP*::BLN0NOSTR:flH3-_InWKh9SjUYCetLr5rBgozalyqyTiJA1fH4kHI
```

A plain APRS client renders #1–#3 as readable bulletin text and #4 as a 43‑char
string; an APRX client renders a threaded, likeable conversation and learns
`X1TX`'s key.

---

## 13. Implementation checklist (for other apps)

To receive APRX:
1. Parse APRS messages, bulletins, and position reports as usual.
2. For each **bulletin**: extract `GROUP` (chars after `BLN<id>`, trim padding)
   and `line_id`; merge multi‑line by line id.
3. If `body` ends with ` ~<base85-run>` → split off the **signature** first
   (§14); verify it and keep the rest as `body`. Strip it before the next steps.
4. Compute `mid = sha1(from + "|" + body)[0:4]` (lowercase hex).
5. If `body` matches `^\+[0-9a-f]{4} ` → it's a **reply**: record parent, strip
   marker before display.
6. If `body` matches `^[0-9a-f]{4}:(like|unlike)$` → it's a **reaction**: update
   the per‑callsign tally; do not display.
7. If `GROUP == NOSTR` → it's a **key record**: store `from → base64url_decode(body)`.
8. Otherwise it's a normal group message.
9. Position comments beginning `>>` → geo‑chat.
10. Any word matching `file:[A-Za-z0-9_-]{43}\.[a-z0-9]{1,18}` → an **embedded
    media reference** (§16): classify it by its extension and look the hash up
    in the local media archive.

To send APRX: emit the same forms. Keep each frame within the limits in §1;
split long bodies per §5.

---

## 14. Signed messages — verifiable authorship

Status: **implemented** (APRS wapp ≥ 0.2.18). Opt‑in per user setting. When on,
an outgoing message carries a compact signature so any peer can verify it came
from the sender's callsign key. Verifying needs the sender's public key, learned
from the §10 `NOSTR` beacon. Everything is on‑air — no relays, no lookup.

### 14.1 Signature scheme — short‑Schnorr `(e, s)`, 48 bytes

Signatures use the **same secp256k1 key behind the npub/callsign**, but in the
classic Schnorr `(e, s)` form rather than BIP‑340's `(R, s)`:

- `e` = challenge, truncated to **16 bytes** (128‑bit security),
- `s` = full **32‑byte** scalar (can't shrink — fixed by the curve order),
- **total = 48 bytes** = the smallest a secp256k1 signature can be.

`m = sha256("<FROM>|<core>")` is the signed digest. Sign: nonce `k` from a tagged
hash, `R = kG`, `e = first16( taggedHash("APRX/challenge", R.x ‖ P.x ‖ m) )`,
`s = (k + e·d') mod n` (with `d'` the even‑y key, BIP‑340 convention). Verify:
`R' = sG − eP`, check `first16(taggedHash("APRX/challenge", R'.x ‖ P.x ‖ m)) == e`.

This is an **APRX‑specific** scheme (NOT interoperable with BIP‑340/Nostr
verifiers); only APRX clients verify it. It reuses the existing key, so the §10
beacon and callsign binding are unchanged.

### 14.2 Encoding — APRS‑safe base85

48 bytes encode to **60 chars** (vs 64 for base64, 86 for a 64‑byte sig) using a
Z85‑style codec (4 bytes → 5 chars) over an **85‑char alphabet that excludes the
APRS‑reserved `{ | ~` and space**:

```
0-9 a-z A-Z .-+=^!/*?&<>()[]%$#@,;_
```

60 chars fits a single 67‑char APRS message.

### 14.3 What is signed

`core` = the message body **including** any thread marker `+<pmid> ` (§8) and
**excluding** the signature segment. `FROM` = the sender's callsign (the frame
source). Binding `FROM` + `core` proves *who authored this exact text*. Scope
(group/DM) is not bound — a genuine signed message could in principle be replayed
into another room, but it remains genuinely the author's words; `mid` dedup (§3)
limits repeats.

### 14.4 On‑air format

Append to the body: a space, a tilde, then the 60‑char base85 signature.

```
<core> ~<60-char base85 signature>
```

The base85 alphabet contains neither space nor `~`, so the split is unambiguous:
the signature is the trailing run of base85 chars and the `~` just before it;
everything earlier is `core`.

**Retro‑compatible multi‑line.** The signed body `<core> ~<sig>` is word‑split
into normal ≤67‑char APRS lines (§5). Because the 60‑char signature has no spaces
and is preceded by a space, the splitter always puts it on **its own final
line** — so a signed message is the body line(s) followed by a last line that is
just `~<sig>`:

```
X10EGL>APRS,TCPIP*::BLN0TEST :hi there            (body, line 0)
X10EGL>APRS,TCPIP*::BLN1TEST :~<60-char signature> (signature, last line)
```

For a direct message the parts are separate messages with consecutive `{seq`,
the last part being the `~<sig>` line. The receiver reassembles the lines (join
with single spaces), then strips the trailing ` ~<sig>` (§14.6). Each line stays
within the 67‑char APRS convention, so stock clients show normal text lines.
(BLE carries the whole body in one parcel — no split there.)

### 14.5 Setting

A per‑station **"Sign my messages"** toggle (default **off** — a signature adds a
line). Persisted in KV. Off → messages are sent plain (§4/§6). Likes (§9) and
key beacons (§10) are never signed.

### 14.6 Verification (receiver)

```
1. Reassemble multi-line parts (bulletins by line id; DMs by consecutive seq up
   to and including the final " ~<sig>" line), joined with single spaces.
2. If the body ends with " ~<base85-run>", split it: sig = decode(run); core = head.
   else → "unsigned".
3. Strip the signature BEFORE computing mid (§3) and thread/like parsing — so
   signing never changes ids; unsigned traffic is unaffected.
4. pubkey = lookup(FROM) from the §10 NOSTR map; none yet → "unverified".
5. m = sha256(FROM "|" core); ok = shortSchnorrVerify(sig, m, pubkey).
```

UI verdict: **verified** (green), **forged** (red, signature present but fails),
**unverified** (signed but sender's key not learned yet), or **unsigned** (no
badge).

### 14.7 Where the crypto runs

Signing and verifying happen **host‑side** (the private key never reaches the
wapp). The wapp builds the canonical bytes, asks the host to sign (returns the
base85 string), and appends it; on receive it hands the host `(pubkey, bytes,
sig)` to verify. A client SHOULD also check the callsign matches the key
(`npub(pubkey)[5:9].upper() == callsign[2:6]`).

### 14.8 Security notes

- **128‑bit** security; the unforgeable scalar is sent in full (no truncation).
- The `X1+4` callsign is a 20‑bit handle — always verify against the full key.
- Replay: dedup by `mid`; scope is not bound (see §14.3).
- The 16‑byte challenge gives 128‑bit existential‑forgery resistance; widen `e`
  to 24–32 bytes if a higher margin is ever wanted (at +5–10 chars).

---

## 15. Encrypted 1:1 messages

Status: **implemented** (APRS wapp ≥ 0.2.28). A direct message to a callsign
whose public key is in the keys database (§10) is end‑to‑end encrypted so only
that station can read it. Group messages are never encrypted.

> **⚠ Legal restriction — no encryption over licensed RF.** Amateur‑radio
> regulations (ITU Radio Regulation 25.2A and national rules such as FCC
> Part 97.113(a)(4)) forbid transmissions that obscure their meaning on
> licensed amateur frequencies. An `ENC1:` message must therefore **never be
> transmitted — or be forwardable — over licensed RF**: it may travel only on
> transports where encryption is lawful (e.g. Bluetooth LE,
> Reticulum). Any path that could put the frame on the air — an RF TNC, a
> digipeater, or an iGate gating traffic IS→RF — is off‑limits for encrypted
> bodies on frequencies requiring a license; implementations must suppress
> encryption (or refuse to send) when such a path cannot be ruled out, and
> gateways must drop `ENC1:` frames rather than forward them onto RF.
> Operators remain responsible for compliance with the regulations of their
> own jurisdiction.

### 15.1 Scheme

ECDH over secp256k1 + AES‑256‑CBC (NIP‑04‑style), using the same key pair behind
the npub/callsign:

```
shared = X coordinate of (my_private_scalar × lift_x(their_pubkey))   // 32 bytes
iv     = 16 random bytes
ct     = AES-256-CBC(key = shared, iv, PKCS7(plaintext))
blob   = iv ‖ ct
```

The X coordinate is parity‑independent, so `ecdh(a, B) == ecdh(b, A)` — sender
and recipient derive the same key, and the sender can also decrypt its own copy
(for the local echo). Confidentiality only; **the ciphertext is always signed
(§14)** so authenticity + integrity (and AES‑CBC malleability) are covered by the
signature, not by the cipher.

### 15.2 On‑air format

```
ENC1:<base64url(iv ‖ ct)>  ~<base85 signature>
```

`ENC1:` marks an encrypted body; the rest is the base64url blob; the message is
then signed (§14) and word‑split into multi‑line APRS (§5). Because the base64url
body has no spaces, multi‑line reassembly inserts artifact spaces into it — the
receiver **strips all spaces after `ENC1:`** before verifying the signature and
decrypting (the signature is computed over the space‑free `ENC1:<base64>`).

### 15.3 Send / receive

- **Send** (1:1 only): if the recipient's pubkey is known → encrypt to it,
  prefix `ENC1:`, sign, transmit. Otherwise send plaintext (e.g. to non‑APRX
  stations). Encryption is automatic when a key is on file.
- **Receive**: detect `ENC1:`, canonicalise (strip reassembly spaces), verify the
  signature with the sender's key, then decrypt with the **peer's** key (the
  sender for incoming; the recipient for our own echo) + our private key. Show
  the plaintext with a lock badge; if the peer's key is unknown or decryption
  fails, show `[encrypted - no key]` / `[encrypted - cannot decrypt]`.

### 15.4 Notes

- The private key never leaves the host (HAL `hal_encrypt` / `hal_decrypt`).
- Local message history is stored decrypted (the device owner reads their own
  chats); only the wire is encrypted.
- A station learns peers' keys passively from their §10 `NOSTR` beacons, so
  encryption “just works” once two APRX stations have heard each other's key.
- Encryption is a **transport‑gated** feature: it applies only on encryption‑
  legal transports (APRS‑IS, BLE, Reticulum). See the legal restriction at the
  top of this section — `ENC1:` bodies must never reach licensed RF.

---

## 16. Embedded media references

Status: **specified** (token grammar + local archive implemented host‑side;
sending/rendering in the wapp is future work).

An APRS text message cannot carry a picture — but it can carry a **name for
one**. APRX references a file by its content: the SHA‑256 of the bytes plus
the original file extension, embedded as a single word anywhere in a normal
message body:

```
file:<sha256-base64url>.<ext>
```

- `<sha256-base64url>` — the **unpadded base64url** encoding of the file's
  32‑byte SHA‑256: exactly **43 characters** of `A‑Z a‑z 0‑9 - _` (the same
  encoding as the §10 key beacons; base64url was chosen over hex for length —
  43 chars instead of 64 — and over base85 because `-`/`_` survive every APRS
  path untouched).
- `.` — a literal dot. The dot is not in the base64url alphabet, so the hash /
  extension boundary is unambiguous.
- `<ext>` — the original file extension, **lowercase**, 1–18 of `a‑z 0‑9`,
  no dot inside. Senders normalise to lowercase; receivers compare lowercase.

The extension is what lets a receiver decide **how the reference could be
shown before it has any bytes**: as an inline image, a playable video, audio,
or a generic file attachment.

Example (token embedded mid‑sentence, then as the entire body):

```
X1ABCD>APRS,TCPIP*::BLN0FEED :sunset from the hill file:qL0gJ9smPmKBcGGNUx0a2RkYJyhYzv2ZUKKcUemZ3-A.jpg
X1ABCD>APRS,TCPIP*::X1WXYZ   :file:qL0gJ9smPmKBcGGNUx0a2RkYJyhYzv2ZUKKcUemZ3-A.pdf{42
```

### 16.1 Grammar

```
token   = "file:" hash "." ext
hash    = 43 * b64url-char          ; unpadded base64url of SHA-256(bytes)
ext     = 1*18 ( %x61-7A / DIGIT )  ; lowercase letters / digits
b64url-char = ALPHA / DIGIT / "-" / "_"
```

Receiver extraction regex: `file:[A-Za-z0-9_-]{43}\.[a-z0-9]{1,18}`

- A token contains no spaces and no punctuation characters, so it is always a
  single word: adjacent sentence punctuation (`file:….png.` at the end of a
  sentence) falls naturally outside the match.
- A message may contain **multiple tokens**, separated by ordinary text.
- Tokens compose with everything else in this spec: they are plain body text,
  so threading (§8), signing (§14) and encryption (§15) apply unchanged.

### 16.2 Length invariant

`5 ("file:") + 43 (hash) + 1 (".") + 18 (max ext) = 67` — exactly the APRS
message‑text limit (§1). A token therefore always fits on one line: the §5
word‑splitter never breaks words, so even a worst‑case token travels intact
(real extensions are 2–4 chars, ≈ 52 chars total).

### 16.3 Display classification

| Kind    | Extensions                                                          |
|---------|---------------------------------------------------------------------|
| `image` | `png` `jpg` `jpeg` `webp` `bmp` `svg` `avif` `heic` `tif` `tiff` `ico` |
| `video` | `gif` `webm` `mpeg` `mpg` `mp4` `mov` `avi` `mkv` `ogv`              |
| `audio` | `mp3` `ogg` `aac` `flac` `wav` `opus`                                |
| `file`  | anything else (attachment; offer to save / open externally)          |

`gif` is classified as video — it is presented as a looping clip. Unknown
extensions degrade gracefully to a generic file attachment.

### 16.4 Local media archive

Each station keeps a **content‑addressed local archive** mapping
`sha256 → bytes`: when a token arrives and the hash is in the archive, the
media renders immediately; identical content is stored once no matter how
many messages, senders or apps reference it. Per entry the archive keeps:

| Field         | Meaning                                                       |
|---------------|---------------------------------------------------------------|
| `sha256`      | primary key — unpadded base64url, 43 chars (the token hash)   |
| `sha1`        | secondary hash of the same bytes (base64url, 27 chars)        |
| `tlsh`        | TLSH fuzzy hash — *reserved*, null until an implementation exists |
| `name`        | original file name, when available                            |
| `ext`         | lowercase extension (as in the token)                         |
| `description` | free‑text description                                         |
| `tags`        | user/app tags (JSON array)                                    |
| `first_seen`  | when the entry was first stored (epoch ms)                    |
| `last_seen`   | when it was last accessed (epoch ms)                          |
| `size`        | byte length of the data                                       |
| `screenshot`  | a reusable preview image (thumbnail/poster), shown before/instead of the full media |
| `data`        | the file bytes themselves                                     |

The reference implementation is a single SQLite database (`media.sqlite3`,
WAL‑journalled) shared by all wapps on the device.

### 16.5 Out of scope (for now)

**How the bytes travel is deliberately not specified here.** A token only
*identifies* media; fetching the content for an unknown hash (peer query,
BLE parcel transfer, internet gateway, …) is a separate, future layer. A
station that cannot resolve a hash simply shows the token as text — which is
also exactly what a non‑APRX client sees: retro‑compatible by construction.

---

*This spec documents the Geogram APRS wapp implementation (`wapps/aprs`). The
APRS-IS framing helpers live in `aprs.c`/`aprs.h`; the BLE compact form in
`BLE_PROTOCOL.md`; the host-side crypto in `geogram/lib/util/aprx_sign.dart`
(exposed via `hal_identity_sign`/`hal_verify`/`hal_encrypt`/`hal_decrypt`);
the media token parser in `geogram/lib/util/media_ref.dart` and the media
archive in `geogram/lib/util/media_archive.dart`. Signed messages (§14) ship
in wapp 0.2.18; encrypted 1:1 (§15) in 0.2.28; media references (§16) are
specified as of 0.2.35.*
