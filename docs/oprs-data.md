# OPRS data formats — the wire, defined once

> How an OPRS station says where it is, how fast it is going, what the weather
> is doing, and what it wants to tell you. Plus messages, receipts, parcels,
> signing and privacy.
>
> Companion: [OPRS.md](OPRS.md) — what OPRS is and why it exists.
>
> This document is self-contained. Everything needed to write an interoperable
> implementation is here.

---

## 1. Why this document exists at all

APRS's data formats grew one field at a time for thirty years, and it shows. A
position can arrive in four incompatible encodings — uncompressed, Base91
compressed, Mic-E (hidden *inside* the AX.25 destination field), and a `!DAO!`
extension bolted on later to recover the precision the first encoding threw
away. Weather takes over the position report as a fixed-width run of
letter-suffixed fields. Telemetry is worse: numbered packets whose *meaning*
lives in separate definition messages you must have received earlier and cached
— lose those and the numbers are unreadable forever. Units are whatever was
convenient that year: feet, knots, miles per hour, Fahrenheit, hundredths of an
inch, tenths of a millibar.

None of that was a mistake at the time. It is what happens when every new idea
has to fit in the gaps left by the last one, in a packet that was already full.

We do not have that problem. We have **250 bytes and a blank page**. So the
rules are decided once, here, before there are a hundred implementations to keep
compatible.

**The two goals, in tension, resolved:** short enough for the smallest radio we
will ever use, and readable by a person looking at a log. Where they conflict,
readability wins, because we can afford it — see §2.

---

## 2. The packet: 250 bytes, everywhere

One number for every transport. It is not a compromise; it is roughly what every
path independently landed on:

| Path | Limit | Where |
|---|---|---|
| LoRa (SX1262 / SX1276) | **255 B** in one packet | `esp32/components/geogram_sx1262/sx1262.h:130` — `len` is a `uint8_t`, documented "max 255" |
| ESP32 custody store | 252 B per parked frame | `BLEMESH_SCF_FRAME_MAX` |
| Mesh courier | 240 B aired | `MeshCourier.maxWire` |
| BLE5 extended advert | 184–296 B (controller-dependent, measured) | runtime `leMaximumAdvertisingDataLength` |

**So: a frame that fits 250 bytes goes anywhere.** Longer content is not
squeezed — it is split into parcels (§5.8).

That budget is generous enough that this format never needs to be cryptic.
A full weather report with position and a timestamp is 94 bytes (§8).

---

## 3. The frame

```
FROM <US> TO <US> TEXT
```

`<US>` is the ASCII unit separator, `0x1F` (1 byte). Three fields, two
separators, no headers, no escaping. Everything else in this document describes
what goes in `TEXT`.

`FROM` is the sender's callsign. `TO` decides what the frame *is*:

| `TO` | Meaning |
|---|---|
| a callsign | direct message to that station |
| `#GROUP` | group message (bulletin) |
| `!` | an observation — position, weather, telemetry (§7) |
| *(empty)* | area broadcast: text for whoever is nearby |
| `?…` | control frame (`?ACK`, `?PING`, …) |

**Reserved first characters: `#`, `!`, `?`.** A callsign never starts with one,
so the dispatch is a single-byte test.

---

## 4. Grammar

`TEXT` is a list of **tokens** separated by single spaces:

```
key:value key:value key:value
```

- **Keys** are 1–3 lowercase ASCII letters.
- **Values** contain no space. The one exception is a trailing free-text field,
  which must come last (§7.6).
- **Order is free.** No field position carries meaning — that is the mistake we
  are explicitly not repeating.
- **Numbers**: optional leading `-`, digits, optional `.` and more digits. No
  `+`, no exponent, no thousands separator, **and never a unit suffix**. Units
  are fixed by this document and never appear on the wire.
- **An unknown token is skipped, never an error.** This single rule is what lets
  fields be added for the next thirty years without a second format. An
  implementation that rejects a frame it does not fully understand is
  non-conforming.

A message body that is plain human text is not a token list — see §5.

---

## 5. Messages

### 5.1 Direct

```
X1QZ3N <US> X1RD89 <US> meet at the bridge at six
```
**39 bytes.** No ceremony: if the text is not a control word, it is the message.

### 5.2 Group

```
X1QZ3N <US> #LISBOA <US> net starts in ten minutes
```
**40 bytes.** Group names are 1–16 characters, uppercase letters and digits.

### 5.3 Area broadcast

An empty `TO` means "anyone in range", tied to wherever the sender is:

```
X1QZ3N <US>  <US> anyone near the north gate?
```
**35 bytes.**

### 5.4 Message id — derived, never assigned

Every group message has an **id**: the first 4 hex characters of
`SHA-1(FROM + "|" + TEXT)`, lowercase.

```
X1QZ3N | net starts in ten minutes   →  SHA-1 → 9c4e…  →  id = 9c4e
```

Nothing is negotiated, nothing is registered, no counter is kept, and every
receiver independently computes the same id from the bytes it already has. Two
different messages colliding costs a mis-threaded reply, not a lost message.

Direct messages do not need ids — they have a receipt id instead (§5.7).

### 5.5 Threads

A reply begins with `+<id>` and a space:

```
X1RD89 <US> #LISBOA <US> +9c4e I'll be late, start without me
```
**51 bytes.** Strip `+9c4e ` before display; keep it for the tree. The reply's
own id is computed over the *whole* text including the marker, so a reply is
itself replyable.

### 5.6 Reactions

The entire body is `<id>:like` or `<id>:unlike`:

```
X1RD89 <US> #LISBOA <US> 9c4e:like
```
**24 bytes.** Counted once per callsign, idempotent, never shown as a message
and never notified. Deliberately readable so that a station with no reaction
support still shows something a human can interpret.

### 5.7 Receipts (ACK)

A sender that wants confirmation puts a **receipt id** on the message —
`am:` followed by 6 hex characters, **first in the text**:

```
X1QZ3N <US> X1RD89 <US> am:40c124 meet at the bridge at six
```
**49 bytes.**

The recipient answers with a control frame:

```
X1RD89 <US> ?ACK <US> 40c124 d
```
**20 bytes.** The state is `d` (delivered to the device) or `r` (read by the
person). `r` is optional; a station that does not track reading never sends it.

**Any station may act on an overheard receipt.** A node carrying that message
for someone else (see [OPRS.md](OPRS.md) §7) drops its copy the moment it hears
the `?ACK`. This is how the mesh cleans up after itself without anybody
coordinating it.

`am:` must be first because carriers read it at a fixed offset without parsing
the rest.

### 5.8 Parcels — content larger than one packet

A message too long for 250 bytes is split into numbered **parcels**:

```
p:<id>.<index>/<total>
```

`<id>` is 3 hex characters chosen by the sender (enough to keep two concurrent
parcels from the same station apart), `<index>` counts from 1.

```
X1QZ3N <US> #LISBOA <US> p:7a3.1/3 The repeater on the hill is down. We
X1QZ3N <US> #LISBOA <US> p:7a3.2/3  swapped the antenna feed this morning and
X1QZ3N <US> #LISBOA <US> p:7a3.3/3  it is back up, but only just.
```

Rules:
- The token is stripped; the remainder of each part is concatenated **in index
  order, with no separator added**. A sender that splits on a word boundary
  keeps its own spaces.
- Reassembly is keyed on `(FROM, id)`.
- A receiver holds incomplete parcels for **10 minutes**, then discards them. A
  partial message is never displayed — half a sentence is worse than silence.
- Parts may arrive out of order and may be duplicated; a repeated index is
  ignored.
- Signatures (§6.1) cover the **reassembled** text and travel on the last part.
- A parcel set is bounded to 16 parts. Anything larger belongs in a file
  transfer, not a message.

### 5.9 Attachments

A message can point at content instead of carrying it:

```
X1QZ3N <US> #LISBOA <US> antenna after the storm file:kZ9v…7Qm.jpg
```

`file:` carries the content hash and extension; the bytes are fetched by
whatever path is available. An optional `ih:` token carries a torrent infohash
for the same content.

---

## 6. Signing and privacy

### 6.1 Signatures — authorship you can check

A callsign in a frame is a claim. A signature makes it checkable. The signature
is appended last, after a space and a `~`:

```
X1QZ3N <US> #LISBOA <US> net starts in ten minutes ~Kf3p…Qz1
```

It covers `FROM + "|" + <everything before the trailing " ~">`, so both the
author and the text are bound. The encoding deliberately excludes the space and
`~` characters, which makes the split unambiguous: the signature is whatever
follows the **last** ` ~` in the frame.

A receiver reports one of four verdicts, and they are not the same thing:
**verified** (signature present and valid for a known key), **forged**
(signature present and invalid — show this loudly), **unverified** (signed, but
the sender's key is unknown), **unsigned**.

Reactions and key announcements are never signed — they are too small to be
worth it and carry nothing worth forging.

### 6.2 Encryption

A private message replaces the body with sealed ciphertext:

```
X1QZ3N <US> X1RD89 <US> am:40c124 ENC1:pQ4m…9xT ~Kf3p…Qz1
```

**The envelope stays readable on purpose.** `FROM` and `TO` are in the clear so
that a station carrying the message for a peer it may never meet can still route
it and know whom to hand it to. Only the body is sealed. That is the whole
design: public routing, private content.

`ENC1:` must be the entire body when present.

### 6.3 Where each is allowed — the rule that matters

OPRS runs on licence-free spectrum, and the point of the project is that anyone
may use it. But some operators will want to run OPRS on amateur bands, and there
the rules are different — not worse, different, and they are not ours to bend.

| Where | Signing | Encryption |
|---|---|---|
| Licence-free spectrum (Bluetooth / LoRa ISM, WiFi), and the internet | yes | **yes — and it is the default for direct messages** |
| Amateur bands, under an amateur licence | yes | **no — never transmit `ENC1:` there** |

Amateur regulations in essentially every country forbid obscuring the meaning of
a transmission. That rule exists so the bands stay self-policing, and a licensed
operator using OPRS is bound by it exactly as they are on any other mode.

**A signature is not encryption.** It obscures nothing — the text stays in the
clear and anyone can read it. It only proves who wrote it. Signing is therefore
entirely legal on amateur bands, and it is precisely what an operator there
should use: authorship without obscurity.

An implementation that can reach amateur infrastructure **must refuse to
transmit a sealed body onto it**, rather than leaving that to the operator to
remember. Ours already does.

---

## 7. Observations

Position, movement, weather and device telemetry are **one frame with one
vocabulary**, addressed to `!`:

```
FROM <US> ! <US> <tokens>
```

There is no separate weather packet and no separate telemetry packet. A weather
station is not a different kind of station — it is a station that happens to
report temperature alongside where it is. **This is the single biggest departure
from APRS**, and it is what stops the format fragmenting later: a new
measurement is a new key, never a new packet type.

### 7.1 Position

```
@<lat>,<lon>
```

Decimal degrees, WGS84. Negative is south and west. One token, one comma, no
hemisphere letters, no degrees-minutes-seconds, no compression:

```
@38.7223,-9.1393
```
**16 bytes**, and you can paste it into any map on earth.

**Precision is a claim about accuracy.** Send only the digits your fix
justifies:

| Decimals | Resolution | Honest for |
|---|---|---|
| 2 | ~1.1 km | a town |
| 3 | ~110 m | a neighbourhood |
| 4 | ~11 m | a normal GPS fix |
| 5 | ~1.1 m | a good fix, survey gear |
| 6 | ~0.11 m | rarely justified |

Put the actual uncertainty in `e:` when you know it. A station reporting
`@38.72231,-9.13934 e:8` is saying "five decimals of arithmetic, eight metres of
truth", and both halves are useful.

**Absence of `@` means the position is unknown.** It does not mean zero. This
matters: `0,0` is a real place in the Gulf of Guinea, and treating it as a
sentinel is why so many maps have a mystery cluster there.

### 7.2 Motion

| Key | Meaning | Unit |
|---|---|---|
| `a` | altitude above mean sea level | metres |
| `e` | horizontal accuracy radius | metres |
| `s` | speed over ground | metres/second |
| `c` | course over ground | degrees true, 0–359 |
| `v` | vertical speed, signed | metres/second |

### 7.3 Weather

| Key | Meaning | Unit |
|---|---|---|
| `t` | air temperature | °C |
| `h` | relative humidity | % |
| `b` | barometric pressure, station level | hPa |
| `w` | wind speed, sustained | metres/second |
| `wd` | wind direction it blows **from** | degrees true |
| `wg` | wind gust, peak | metres/second |
| `r1` | rainfall, last hour | mm |
| `r24` | rainfall, last 24 hours | mm |
| `sr` | solar irradiance | W/m² |

Every value is SI. No station ever transmits a unit, and no receiver ever
guesses one. If you have Fahrenheit, convert before transmitting — that
conversion is your problem, once, instead of everyone's problem, forever.

### 7.4 Device telemetry

| Key | Meaning | Unit |
|---|---|---|
| `bt` | battery charge | % |
| `vb` | supply voltage | volts |
| `rs` | received signal strength | dBm |
| `sn` | signal-to-noise ratio | dB |

`rs` and `sn` describe the link a frame *arrived on*, so they are added by the
receiver for its own records — a station does not transmit its own RSSI.

### 7.5 Time — three forms, one per capability

**A time field is required on any observation that may be carried.** Our custody
lane holds a frame for up to seven days before delivering it; an undated
position plotted as "here, now" is not merely stale, it is wrong. This is not
optional politeness — it is what makes carried positions safe to use at all.

| The device can… | Field | Example | Meaning |
|---|---|---|---|
| keep wall-clock time | `ts` | `ts:1780000000` | unix seconds, UTC — **preferred** |
| neither keep time nor store anything | `ag` | `ag:45` | seconds between the observation and this transmission |
| not keep time, but **has persistent memory** | `ep` | `ep:7.4210` | boot epoch 7, 4210 seconds into it |

**The epoch form solves a real problem.** A small node with no real-time clock —
most microcontrollers, once the battery has been out — cannot say when anything
happened. But it can keep a counter in flash. It increments that counter once
per boot and reports it with its seconds-since-boot:

```
X3WX01 <US> ! <US> @38.7223,-9.1393 t:14.2 ep:7.4210
```

Two consequences fall out for free:

- **Ordering with no clock anywhere.** Between two frames from the same station,
  the one with the higher epoch is later; within an epoch, the higher uptime is
  later. A receiver can sort a station's history correctly having never known
  the time.
- **Anchoring.** Any receiver that *does* have a clock notes the wall time at
  which it first heard epoch 7 and can then date every frame of that epoch —
  including ones that reach it days later by custody. One node with a clock
  dates the whole neighbourhood.

When a clockless device eventually learns the time (from a peer, a GPS fix, the
internet), it should send **one** frame carrying both forms:

```
X3WX01 <US> ! <US> @38.7223,-9.1393 ep:7.9930 ts:1780005720
```

That single frame anchors epoch 7 for every station in earshot at once. After
it, the device uses `ts:` and stops sending `ep:`.

### 7.6 Symbol and note

| Key | Meaning |
|---|---|
| `y` | what this station *is* — `y:node` `y:wx` `y:car` `y:boat` `y:foot` `y:balloon` `y:sos` |
| `n` | free text, **must be the last token** (it may contain spaces) |

`y` replaces APRS's two-character symbol-table codes with something a person can
read. A receiver that does not know a symbol name shows a default marker and the
name as text — it never fails.

### 7.7 Extension

Keys beginning `x` are reserved for private and experimental use and will never
be assigned by this document:

```
xco2:412 xpm25:8
```

Because unknown tokens are skipped (§4), an experiment costs other stations
nothing.

---

## 8. Worked examples

Byte counts are the whole frame, both `0x1F` separators included.

**Minimal beacon** — a phone with a fix and a clock:
```
X1QZ3N <US> ! <US> @38.7223,-9.1393 ts:1780000000
```
`6 + 1 + 1 + 1 + 30` = **39 bytes**

**Weather station** — clockless, solar, reporting everything it has:
```
X3WX01 <US> ! <US> @38.7223,-9.1393 t:14.2 h:78 b:1013.2 w:3.4 wd:210 wg:7.1 r1:0.4 bt:96 y:wx ep:7.4210
```
`6 + 1 + 1 + 1 + 85` = **94 bytes** — well under half the packet.

**Moving vehicle** — position, motion and a note:
```
X1QZ3N <US> ! <US> @38.7231,-9.1402 a:87 s:13.4 c:212 e:8 y:car ts:1780000060 n:heading south on the N8
```
`6 + 1 + 1 + 1 + 84` = **93 bytes**

**Emergency** — everything that matters, nothing that does not:
```
X1QZ3N <US> ! <US> @38.7223,-9.1393 e:6 y:sos ts:1780000120 n:injured, need help
```
`6 + 1 + 1 + 1 + 61` = **70 bytes**

**Signed group message with a receipt** — the signature is a fixed 60
characters, so it costs 62 bytes with its leading ` ~`:
```
X1QZ3N <US> #LISBOA <US> am:40c124 net starts in ten minutes ~Kf3pQz1mR8vT2wX5nB7cY4dL9gH6jS3kA0eU1iO8pZ2fN5rV7bM4tC6yW9xQ
```
`6 + 1 + 7 + 1 + 97` = **112 bytes**

Every one of these fits a single LoRa packet, a single BLE5 advert and the
custody store, with room to spare. The largest is under half the budget — which
is the margin that lets a field be added later without a redesign.

---

## 9. Migration from the current position frame

Stations today send `lat,lon[,comment]` in the `!` frame. Both forms are
readable with a one-character test:

> **If the text begins with a digit, `-` or `.`, it is the legacy form.
> Otherwise it is tokens.**

A token list always begins with a key, and a key always begins with a lowercase
letter or `@`. Legacy always begins with a number. There is no ambiguity, and no
version field is needed.

Receivers should accept both indefinitely. Senders should move to tokens.

---

## 10. Reserved — do not reuse

Assigned tokens: `am:` `sd:` `np:` `ENC1:` `file:` `ih:` `p:` `@` `~` `+`
`<id>:like` `<id>:unlike`, and the observation keys in §7.

Reserved addressees: `?ACK` `?MAIL` `?IGATE` `?HELLO` `?PING` `?PONG` `?PRIV`
`?FOLLOW` `?UNFOLLOW` `?RLY`.

Reserved first characters for `TO`: `#` `!` `?`.

Reserved prefix: `x` (private/experimental, §7.7).

A new field takes an unused key and inherits the skip-unknown rule. It never
takes a new packet type, and it never redefines an existing key.

---

## 11. What exists today

Honest status, so nobody plans against something that is not there.

| Field | Producer today |
|---|---|
| `@` position | **yes** — GPS via the location service |
| `ts` | yes on phones and desktops |
| `ag`, `ep` | **no** — a clockless node needs an epoch counter kept in flash |
| `a` `e` `s` `c` `v` | **no** — the platform hands the app a full fix including altitude, accuracy, speed and heading, and the location service currently keeps only latitude and longitude, discarding the rest |
| `t` `h` | one dormant source — a temperature/humidity sensor exists on a single ESP32 board and reaches only its local screen; the sensor HAL returns "not available" on every platform |
| `b` `w` `wd` `wg` `r1` `r24` `sr` | **no source anywhere** — pure format definition |
| `bt` `vb` | **no** — charging state is tracked, charge level is not |
| `rs` `sn` | yes — RSSI is available on both BLE and LoRa receive paths |
| messages, threads, reactions, receipts, parcels, signing, encryption | **yes** — all in service today |

So the message half of this document describes what runs; the observation half
mostly describes what to build. That is the point of writing it down first.

**One related bug worth recording while we are here:** enabling *Coverage* in
the hardware settings stores the literal string `u0` as the node's coverage
region regardless of where the device actually is
(`lib/launcher/hardware_page.dart:169`), so a node in Portugal advertises a
region in the Baltic. That field is separate from everything above — it is a
coarse region in the node announce, not an observation — but it is the same
class of error this document exists to prevent.
