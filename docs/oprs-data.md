# OPRS data formats

Specification of the OPRS wire format: framing, addressing, messages, receipts,
parcels, signing, privacy, and observations (position, movement, weather,
telemetry).

Companion document: [OPRS.md](OPRS.md), which describes what OPRS is and why it
exists. This specification is self-contained and depends on no other document.

Status: DRAFT 1. Section 12 records which parts have a working producer today.

---

## 1. Scope and design rules

APRS added data formats one at a time over three decades. The result is four
incompatible position encodings, weather carried as fixed-width fields inside a
position report, telemetry whose units are defined in separate messages that
must be received and cached beforehand, and a mix of feet, knots, miles per
hour, Fahrenheit, hundredths of an inch and tenths of a millibar. Each addition
was constrained by a packet that was already full.

OPRS starts with 250 bytes and no legacy. The rules below are fixed once, before
multiple implementations exist.

1. One frame type carries every kind of report. New data means a new key, never
   a new packet type.
2. Every field is self-describing. No definition is sent out of band, and no
   receiver needs prior state to read a frame.
3. All values are SI. Units are fixed by this document and never transmitted.
4. All fields are optional. A station sends what it has.
5. Field order carries no meaning.
6. An unknown token is skipped, not rejected. An implementation that discards a
   frame containing an unrecognised key is non-conforming.
7. Values are readable as text. Compression is not used.

---

## 2. Packet size

The maximum frame is 250 bytes on every transport.

| Transport | Limit | Source |
|---|---|---|
| LoRa (SX1262, SX1276) | 255 B per packet | `esp32/components/geogram_sx1262/sx1262.h:130`, length is a `uint8_t` documented "max 255" |
| Custody store (ESP32) | 252 B per parked frame | `BLEMESH_SCF_FRAME_MAX` |
| Mesh courier | 240 B aired | `MeshCourier.maxWire` |
| BLE5 extended advertising | 184 B to 296 B, controller dependent, measured | runtime `leMaximumAdvertisingDataLength` |

A frame within 250 bytes is carried by all of them. Content that does not fit is
split into parcels (section 5.8), not compressed.

---

## 3. Frame

```
FROM <US> TO <US> TEXT
```

`<US>` is the ASCII unit separator, `0x1F`, one byte. There are three fields,
two separators, no header and no escaping.

`FROM` is the sender callsign. `TO` selects the frame type:

| `TO` | Frame type |
|---|---|
| a callsign | direct message |
| `#GROUP` | group message |
| `!` | observation (section 7) |
| empty | area broadcast |
| `?NAME` | control frame |

The characters `#`, `!` and `?` are reserved as the first character of `TO`. A
callsign never begins with one, so frame type is determined by a single byte.

---

## 4. Token grammar

`TEXT` is a sequence of tokens separated by single spaces:

```
key:value key:value key:value
```

- Keys are 1 to 3 lowercase ASCII letters.
- Values contain no space, except a single trailing free-text field (section
  7.6), which is always last.
- Numbers are an optional leading `-`, digits, and an optional `.` followed by
  digits. No leading `+`, no exponent, no digit grouping, no unit suffix.
- Order is not significant.
- Unknown tokens are skipped.

The body of a plain message is human text, not a token list. A receiver
distinguishes the two by the frame type in `TO`.

---

## 5. Messages

### 5.1 Direct message

```
X1QZ3N <US> X1RD89 <US> meet at the bridge at six
```

39 bytes. Text that is not a control word is the message.

### 5.2 Group message

```
X1QZ3N <US> #LISBOA <US> net starts in ten minutes
```

40 bytes. A group name is 1 to 16 characters, uppercase letters and digits.

### 5.3 Area broadcast

An empty `TO` addresses any station in range:

```
X1QZ3N <US>  <US> anyone near the north gate?
```

35 bytes.

### 5.4 Message identifier

Every group message has an identifier: the first 4 hexadecimal characters of
`SHA-1(FROM + "|" + TEXT)`, lowercase.

```
FROM = X1QZ3N
TEXT = net starts in ten minutes
id   = first 4 hex characters of SHA-1("X1QZ3N|net starts in ten minutes")
```

The identifier is derived from the content, so every receiver computes the same
value without a registry, a counter, or a negotiation. A collision between two
different messages causes a misplaced reply, not a lost message.

Direct messages carry a receipt identifier instead (section 5.7).

### 5.5 Threads

A reply begins with `+`, the parent identifier, and a space:

```
X1RD89 <US> #LISBOA <US> +9c4e I'll be late, start without me
```

51 bytes. The marker is removed before display and retained for threading. The
reply's own identifier is computed over the complete text including the marker,
so replies are themselves replyable.

### 5.6 Reactions

The whole body is `<id>:like` or `<id>:unlike`:

```
X1RD89 <US> #LISBOA <US> 9c4e:like
```

24 bytes. A reaction is counted once per callsign and is idempotent. It is not
displayed as a message and raises no notification. A station without reaction
support displays the body as text, which remains legible.

### 5.7 Receipts

A sender requesting confirmation includes a receipt identifier: `am:` followed
by 6 hexadecimal characters, positioned first in `TEXT`.

```
X1QZ3N <US> X1RD89 <US> am:40c124 meet at the bridge at six
```

49 bytes.

The recipient replies with a control frame:

```
X1RD89 <US> ?ACK <US> 40c124 d
```

20 bytes. The state is `d` for delivered to the device or `r` for read by the
operator. The `r` state is optional.

Any station may act on a receipt it overhears. A station carrying that message
on behalf of another discards its copy when it hears the matching `?ACK`. This
is the mechanism by which carried copies are released.

`am:` is first in `TEXT` so that a carrying station reads it at a fixed offset
without parsing the remainder.

### 5.8 Parcels

Content exceeding 250 bytes is split into parcels. Each part carries:

```
p:<id>.<index>/<total>
```

`<id>` is 3 hexadecimal characters selected by the sender, sufficient to
distinguish concurrent parcels from the same station. `<index>` starts at 1.

```
X1QZ3N <US> #LISBOA <US> p:7a3.1/3 The repeater on the hill is down. We
X1QZ3N <US> #LISBOA <US> p:7a3.2/3  swapped the antenna feed this morning and
X1QZ3N <US> #LISBOA <US> p:7a3.3/3  it is back up, but only just.
```

Rules:

- The token is removed and the remainder of each part is concatenated in index
  order with no added separator. A sender that splits on a word boundary
  includes its own spacing.
- Reassembly is keyed on `(FROM, id)`.
- Incomplete parcels are held for 10 minutes and then discarded. A partial
  message is never displayed.
- Parts may arrive out of order. A repeated index is ignored.
- A signature (section 6.1) covers the reassembled text and is carried on the
  final part.
- A parcel set is limited to 16 parts. Larger content is transferred as a file.

### 5.9 Attachments

A message references content by hash rather than carrying it:

```
X1QZ3N <US> #LISBOA <US> antenna after the storm file:kZ9v7Qm.jpg
```

`file:` carries the content hash and extension. The optional `ih:` token carries
a torrent infohash for the same content. The transfer path is not specified
here.

---

## 6. Signing and privacy

### 6.1 Signatures

A signature is appended last, preceded by a space and `~`:

```
X1QZ3N <US> #LISBOA <US> net starts in ten minutes ~<60 characters>
```

The signature covers `FROM + "|" + <all text preceding the trailing " ~">`,
binding both author and content. The signature encoding excludes the space and
`~` characters, so the split point is the last occurrence of ` ~` in the frame.

A receiver reports one of four states:

| State | Condition |
|---|---|
| verified | signature present, valid, signer key known |
| forged | signature present and invalid |
| unverified | signature present, signer key unknown |
| unsigned | no signature |

Reactions and key announcements are not signed.

### 6.2 Encryption

A private message replaces the body with ciphertext:

```
X1QZ3N <US> X1RD89 <US> am:40c124 ENC1:pQ4m9xT ~<60 characters>
```

`ENC1:` is the entire body when present. The envelope fields `FROM` and `TO`
remain in cleartext so that an intermediate station can route the frame and
identify the recipient without being able to read the content.

### 6.3 Permitted use by band

| Spectrum | Signing | Encryption |
|---|---|---|
| Licence-free (Bluetooth and LoRa ISM, WiFi), and the internet | permitted | permitted, and is the default for direct messages |
| Amateur bands, under an amateur licence | permitted | not permitted |

Amateur regulations prohibit obscuring the meaning of a transmission. A licensed
operator using OPRS on amateur bands is bound by that rule as on any other mode,
and must not transmit `ENC1:` there.

A signature is not encryption. It leaves the text in cleartext and establishes
only authorship, so signing is permitted on amateur bands.

An implementation able to reach amateur infrastructure must refuse to transmit a
sealed body onto it.

---

## 7. Observations

Position, movement, weather and device telemetry share one frame and one
vocabulary, addressed to `!`:

```
FROM <US> ! <US> <tokens>
```

There is no separate weather frame and no separate telemetry frame. A weather
station is a station that reports temperature in addition to position.

### 7.1 Position

```
@<lat>,<lon>
```

Decimal degrees, WGS84. Negative values are south and west. No hemisphere
letters, no degrees-minutes-seconds, no compression.

```
@38.7223,-9.1393
```

16 bytes.

The number of decimal places states the precision claimed:

| Decimals | Resolution |
|---|---|
| 2 | 1.1 km |
| 3 | 110 m |
| 4 | 11 m |
| 5 | 1.1 m |
| 6 | 0.11 m |

A station sends only the digits its fix supports and reports measured
uncertainty separately in `e:`.

Absence of `@` means the position is unknown. It does not mean zero. `0,0` is a
valid coordinate in the Gulf of Guinea.

### 7.2 Movement

| Key | Meaning | Unit |
|---|---|---|
| `a` | altitude above mean sea level | metres |
| `e` | horizontal accuracy radius | metres |
| `s` | speed over ground | metres per second |
| `c` | course over ground | degrees true, 0 to 359 |
| `v` | vertical speed, signed | metres per second |

### 7.3 Weather

| Key | Meaning | Unit |
|---|---|---|
| `t` | air temperature | degrees Celsius |
| `h` | relative humidity | percent |
| `b` | barometric pressure, station level | hPa |
| `w` | wind speed, sustained | metres per second |
| `wd` | wind direction, the direction it blows from | degrees true |
| `wg` | wind gust, peak | metres per second |
| `r1` | rainfall, previous hour | mm |
| `r24` | rainfall, previous 24 hours | mm |
| `sr` | solar irradiance | watts per square metre |

Conversion to SI is performed by the sender. No unit is transmitted and no
receiver infers one.

### 7.4 Device telemetry

| Key | Meaning | Unit |
|---|---|---|
| `bt` | battery charge | percent |
| `vb` | supply voltage | volts |
| `rs` | received signal strength | dBm |
| `sn` | signal-to-noise ratio | dB |

`rs` and `sn` describe the link on which a frame arrived and are recorded by the
receiver. A station does not transmit its own received signal strength.

### 7.5 Time

An observation that may be carried by another station must include a time field.
Custody delivery holds a frame for up to 7 days, and an undated position is
plotted as current.

| Station capability | Key | Example | Meaning |
|---|---|---|---|
| keeps wall-clock time | `ts` | `ts:1780000000` | Unix seconds, UTC |
| no clock, no storage | `ag` | `ag:45` | seconds between observation and transmission |
| no clock, persistent storage | `ep` | `ep:7.4210` | boot epoch 7, 4210 seconds into that epoch |

The epoch form supports stations without a real-time clock. The station keeps a
counter in non-volatile storage, increments it once per boot, and reports it
with its seconds since boot:

```
X3WX01 <US> ! <US> @38.7223,-9.1393 t:14.2 ep:7.4210
```

Two properties follow.

Ordering without a clock: between two frames from the same station, the higher
epoch is later, and within one epoch the higher uptime is later.

Anchoring: a receiver holding a clock records the wall-clock time at which it
first heard a given epoch, and can then date every frame of that epoch,
including frames delivered days later by custody.

A station that subsequently obtains the time sends one frame carrying both
forms, which anchors that epoch for all receivers in range, and thereafter sends
`ts` only:

```
X3WX01 <US> ! <US> @38.7223,-9.1393 ep:7.9930 ts:1780005720
```

### 7.6 Station type and note

| Key | Meaning |
|---|---|
| `y` | station type: `node`, `wx`, `car`, `boat`, `foot`, `balloon`, `sos` |
| `n` | free text, always the last token, may contain spaces |

A receiver that does not recognise a `y` value displays a default marker and the
value as text.

### 7.7 Private extensions

Keys beginning with `x` are reserved for private and experimental use and are
never assigned by this document:

```
xco2:412 xpm25:8
```

Unknown tokens are skipped (section 4), so an extension imposes no cost on other
stations.

---

## 8. Frame examples

Byte counts are for the complete frame including both `0x1F` separators.

Position beacon, station with a fix and a clock:

```
X1QZ3N <US> ! <US> @38.7223,-9.1393 ts:1780000000
```

`6 + 1 + 1 + 1 + 30` = 39 bytes

Weather station, no clock, reporting all available sensors:

```
X3WX01 <US> ! <US> @38.7223,-9.1393 t:14.2 h:78 b:1013.2 w:3.4 wd:210 wg:7.1 r1:0.4 bt:96 y:wx ep:7.4210
```

`6 + 1 + 1 + 1 + 85` = 94 bytes

Vehicle in motion:

```
X1QZ3N <US> ! <US> @38.7231,-9.1402 a:87 s:13.4 c:212 e:8 y:car ts:1780000060 n:heading south on the N8
```

`6 + 1 + 1 + 1 + 84` = 93 bytes

Emergency:

```
X1QZ3N <US> ! <US> @38.7223,-9.1393 e:6 y:sos ts:1780000120 n:injured, need help
```

`6 + 1 + 1 + 1 + 61` = 70 bytes

Signed group message with receipt. The signature is a fixed 60 characters and
costs 62 bytes including the leading ` ~`:

```
X1QZ3N <US> #LISBOA <US> am:40c124 net starts in ten minutes ~<60 characters>
```

`6 + 1 + 7 + 1 + 97` = 112 bytes

Balloon ascent, altitude and vertical speed:

```
X3BAL1 <US> ! <US> @38.9012,-9.0021 a:11240 v:4.8 s:9.2 c:47 y:balloon ts:1780001800
```

`6 + 1 + 1 + 1 + 65` = 74 bytes

Minimum useful observation, coarse position only:

```
X1QZ3N <US> ! <US> @38.72,-9.14 ag:30
```

`6 + 1 + 1 + 1 + 18` = 27 bytes

All of the above fit one LoRa packet, one BLE5 advertisement, and the custody
store. The largest is under half the 250-byte limit.

---

## 9. Worked exchanges

Complete sequences, in transmission order. `<US>` is `0x1F`.

### 9.1 Group conversation with a reply and a reaction

```
1  X1QZ3N <US> #LISBOA <US> net starts in ten minutes
2  X1RD89 <US> #LISBOA <US> +9c4e I'll be late, start without me
3  X32DVA <US> #LISBOA <US> 9c4e:like
```

Frame 1 has identifier `9c4e`, computed by every receiver from
`SHA-1("X1QZ3N|net starts in ten minutes")`. Frame 2 references it and gains its
own identifier, so it can be replied to in turn. Frame 3 is a reaction to frame
1: it is tallied against `9c4e`, counted once for `X32DVA`, and is not displayed
as a message.

### 9.2 Direct message with delivery and read receipts

```
1  X1QZ3N <US> X1RD89 <US> am:40c124 meet at the bridge at six
2  X1RD89 <US> ?ACK <US> 40c124 d
3  X1RD89 <US> ?ACK <US> 40c124 r
```

Frame 2 is emitted when the message reaches the device, frame 3 when the
operator reads it. A station that does not track reading sends frame 2 only.

### 9.3 Private message on licence-free spectrum

```
X1QZ3N <US> X1RD89 <US> am:5b91e0 ENC1:pQ4m9xT ~<60 characters>
```

`FROM` and `TO` are readable, so intermediate stations can route and carry the
frame. Only the body is sealed. This frame must not be transmitted on amateur
bands (section 6.3).

### 9.4 Store and forward through a station that meets neither party

```
1  X1QZ3N <US> X1RD89 <US> am:40c124 meet at the bridge at six
   X1RD89 is out of range. X32DVA hears the frame and retains it.

2  X32DVA <US> X1RD89 <US> am:40c124 meet at the bridge at six
   Hours later, X32DVA encounters X1RD89 and retransmits.

3  X1RD89 <US> ?ACK <US> 40c124 d
   X32DVA hears the receipt and discards its copy.
```

The receipt identifier is unchanged throughout, so the delivered message is
recognised as the same message and duplicates are suppressed. Any other station
that retained frame 1 and hears frame 3 also discards its copy.

### 9.5 Parcelled announcement

```
1  X3RLY7 <US> #LISBOA <US> p:7a3.1/3 The repeater on the hill is down. We
2  X3RLY7 <US> #LISBOA <US> p:7a3.2/3  swapped the antenna feed this morning and
3  X3RLY7 <US> #LISBOA <US> p:7a3.3/3  it is back up, but only just.
```

Reassembly is keyed on `(X3RLY7, 7a3)`. Parts may arrive in any order. If part 2
never arrives, the set is discarded after 10 minutes and nothing is displayed.

### 9.6 Clockless weather station anchored by a neighbour

```
1  X3WX01 <US> ! <US> @38.7223,-9.1393 t:14.1 h:80 ep:7.3600
2  X3WX01 <US> ! <US> @38.7223,-9.1393 t:14.2 h:78 ep:7.4210
   A receiver holding a clock records: epoch 7 heard at 1780004800.

3  X3WX01 <US> ! <US> @38.7223,-9.1393 ep:7.9930 ts:1780005720
   The station has obtained the time and anchors epoch 7 for all receivers.

4  X3WX01 <US> ! <US> @38.7223,-9.1393 t:15.0 h:74 ts:1780009320
```

Frames 1 and 2 are orderable without any clock, since the higher uptime is
later. A receiver holding a clock dates them from its own observation of epoch
7. Frame 3 makes that anchor explicit and available to every station in range.
After it, the station reports wall-clock time.

### 9.7 Position, weather and telemetry in one frame

```
X3RLY7 <US> ! <US> @38.7810,-9.2043 a:210 t:11.8 h:88 b:1008.4 w:6.1 wd:295 bt:64 vb:12.9 y:node ts:1780003000
```

`6 + 1 + 1 + 1 + 91` = 100 bytes. A receiver interested only in position reads
`@` and skips the remaining tokens under the rule in section 4.

---

## 10. Migration from the current position frame

Existing stations transmit `lat,lon[,comment]` in the `!` frame. The two forms
are distinguished by the first character of `TEXT`:

> If `TEXT` begins with a digit, `-` or `.`, it is the legacy form. Otherwise it
> is a token list.

A token list begins with a key, and a key begins with a lowercase letter or `@`.
The legacy form begins with a number. No version field is required.

Receivers should accept both forms. Senders should emit the token form.

---

## 11. Reserved

Assigned tokens: `am:`, `sd:`, `np:`, `ENC1:`, `file:`, `ih:`, `p:`, `@`, `~`,
`+`, `<id>:like`, `<id>:unlike`, and the observation keys in section 7.

Reserved control addressees: `?ACK`, `?MAIL`, `?IGATE`, `?HELLO`, `?PING`,
`?PONG`, `?PRIV`, `?FOLLOW`, `?UNFOLLOW`, `?RLY`.

Reserved first characters of `TO`: `#`, `!`, `?`.

Reserved key prefix: `x` (section 7.7).

A new field takes an unused key and inherits the skip-unknown rule of section 4.
It does not introduce a packet type and does not redefine an existing key.

---

## 12. Implementation status

| Element | Producer today |
|---|---|
| `@` position | yes, from the platform location service |
| `ts` | yes on phones and desktops |
| `ag`, `ep` | no, requires an epoch counter in non-volatile storage |
| `a`, `e`, `s`, `c`, `v` | no. The platform supplies altitude, accuracy, speed and heading; the location service retains only latitude and longitude |
| `t`, `h` | one board carries a temperature and humidity sensor reaching a local display only. The sensor HAL reports not-available on every platform |
| `b`, `w`, `wd`, `wg`, `r1`, `r24`, `sr` | no source |
| `bt`, `vb` | no. Charging state is tracked, charge level is not |
| `rs`, `sn` | yes, available on the BLE and LoRa receive paths |
| messages, threads, reactions, receipts, parcels, signing, encryption | yes, in service |

Sections 5 and 6 describe behaviour that runs today. Section 7 is mostly a
format definition awaiting producers.
