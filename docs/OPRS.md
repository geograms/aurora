# OPRS, Open Packet Reporting System

Protocol specification.

OPRS carries position, movement, weather, telemetry and messages between
stations over licence-free spectrum and the internet. It occupies the same role
as APRS and requires no amateur licence.

Status: DRAFT 1. Section 12 states which parts are implemented.

---

## 1. Purpose

APRS is a proven network, and an OPRS station meeting APRS infrastructure
operates under APRS rules (section 11). APRS has two prerequisites: amateur
spectrum, and a callsign issued by a radio authority. Both are correct for a
licensed service, and both exclude everyone without a licence.

OPRS applies the same design to Bluetooth and LoRa in the ISM bands, WiFi, and
the internet, with identity derived from a keypair generated on the device.

APRS accumulated its data formats one field at a time over three decades. The
result is four incompatible position encodings, weather carried as fixed-width
fields inside a position report, telemetry whose units are defined in separate
messages that must be received beforehand, and a mixture of feet, knots, miles
per hour, Fahrenheit, hundredths of an inch and tenths of a millibar. Each
addition was constrained by a packet that was already full.

OPRS defines all of it once, in this document.

---

## 2. Design rules

1. One frame type carries every kind of report. New data means a new key, never
   a new packet type.
2. Every field is self-describing. Nothing is defined out of band and no
   receiver requires prior state to read a frame.
3. All values are SI. Units are fixed here and never transmitted.
4. All fields are optional. A station sends what it has.
5. Field order carries no meaning.
6. An unknown token is skipped, not rejected. An implementation that discards a
   frame containing an unrecognised key is non-conforming.
7. Values are text. Compression is not used.

---

## 3. Callsigns

A callsign is `X1` or `X3` followed by four characters derived from the
station's public key:

```
X1 = person or operator
X3 = station, relay or unattended equipment
```

The four characters are taken from the bech32 encoding of the key, so the
letters `b`, `i` and `o` and the digit `1` never appear in them.

A callsign is a label, not an identity. Four characters is approximately one
million values, and collisions can be produced deliberately. A receiver that
needs to establish identity verifies a signature against the full public key
(section 6). No authority issues, revokes or vouches for a callsign.

---

## 4. Frame

```
FROM 0x1F TO 0x1F TEXT
```

`0x1F` is the ASCII unit separator, one byte. Three fields, two separators, no
header, no escaping.

The maximum frame is **250 bytes on every transport**. This fits one LoRa
packet, one BLE5 extended advertisement, and the store-and-forward buffer of the
smallest station. Content that does not fit is split into parcels (section 5.7),
never compressed.

`TO` selects the frame type:

| `TO` | Frame type |
|---|---|
| a callsign | direct message |
| `#GROUP` | group message |
| `!` | observation: position, movement, weather, telemetry |
| empty | area broadcast |
| `?NAME` | control frame |

The characters `#`, `!` and `?` are reserved as the first character of `TO`. A
callsign never begins with one, so the frame type is determined by a single
byte.

### Token grammar

Observation frames and control frames carry a list of tokens separated by single
spaces:

```
key:value key:value key:value
```

- Keys are 1 to 3 lowercase ASCII letters.
- Values contain no space, except a single trailing free-text field, which is
  always last.
- Numbers are an optional leading `-`, digits, and an optional `.` followed by
  digits. No leading `+`, no exponent, no digit grouping, no unit suffix.
- Order is not significant.
- Unknown tokens are skipped.

The body of a message frame is human text, not a token list.

---

## 5. Messages

### 5.1 Direct

```
X1QZ3N <US> X1RD89 <US> meet at the bridge at six
```

39 bytes.

### 5.2 Group

```
X1QZ3N <US> #LISBOA <US> net starts in ten minutes
```

40 bytes. A group name is 1 to 16 characters, uppercase letters and digits.

### 5.3 Area broadcast

An empty `TO` addresses any station in range.

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
value with no registry, counter or negotiation. A collision between two
different messages produces a misplaced reply, not a lost message.

### 5.5 Threads

A reply begins with `+`, the parent identifier, and a space.

```
X1RD89 <US> #LISBOA <US> +9c4e I'll be late, start without me
```

51 bytes. The marker is removed before display. The reply's own identifier is
computed over the complete text including the marker, so replies are themselves
replyable.

### 5.6 Reactions

The whole body is `<id>:like` or `<id>:unlike`.

```
X1RD89 <US> #LISBOA <US> 9c4e:like
```

24 bytes. Counted once per callsign, idempotent, not displayed as a message and
raising no notification. A station without reaction support displays the body as
text, which remains legible.

### 5.7 Receipts

A sender requesting confirmation includes a receipt identifier, `am:` followed
by 6 hexadecimal characters, first in `TEXT`.

```
X1QZ3N <US> X1RD89 <US> am:40c124 meet at the bridge at six
```

49 bytes. The recipient replies with a control frame:

```
X1RD89 <US> ?ACK <US> 40c124 d
```

20 bytes. The state is `d` for delivered to the device or `r` for read by the
operator. The `r` state is optional.

Any station may act on a receipt it overhears. A station holding that message
for later delivery discards its copy on hearing the matching `?ACK`.

`am:` is first so that a relaying station reads it at a fixed offset without
parsing the remainder.

### 5.8 Parcels

Content exceeding 250 bytes is split. Each part carries:

```
p:<id>.<index>/<total>
```

`<id>` is 3 hexadecimal characters chosen by the sender. `<index>` starts at 1.

```
X3RLY7 <US> #LISBOA <US> p:7a3.1/3 The repeater on the hill is down. We
X3RLY7 <US> #LISBOA <US> p:7a3.2/3  swapped the antenna feed this morning and
X3RLY7 <US> #LISBOA <US> p:7a3.3/3  it is back up, but only just.
```

- The token is removed and the remainder of each part is concatenated in index
  order with no added separator. A sender splitting on a word boundary includes
  its own spacing.
- Reassembly is keyed on `(FROM, id)`.
- Incomplete parcels are held for 10 minutes and then discarded. A partial
  message is never displayed.
- Parts may arrive out of order. A repeated index is ignored.
- A signature covers the reassembled text and is carried on the final part.
- A parcel set is limited to 16 parts. Larger content is transferred as a file.

### 5.9 Attachments

```
X1QZ3N <US> #LISBOA <US> antenna after the storm file:kZ9v7Qm.jpg
```

55 bytes. `file:` carries the content hash and extension. An optional `ih:`
token carries a torrent infohash for the same content. The transfer path is not
specified here.

---

## 6. Signing and privacy

### 6.1 Signatures

A signature is appended last, preceded by a space and `~`, and is 60 characters.

```
X1QZ3N <US> #LISBOA <US> am:40c124 net starts in ten minutes ~<60 characters>
```

112 bytes. The signature covers `FROM + "|" + <all text preceding the trailing
" ~">`, binding author and content. The encoding excludes the space and `~`
characters, so the split point is the last occurrence of ` ~` in the frame.

| State | Condition |
|---|---|
| verified | signature present, valid, signer key known |
| forged | signature present and invalid |
| unverified | signature present, signer key unknown |
| unsigned | no signature |

Reactions and key announcements are not signed.

### 6.2 Encryption

A private message replaces the body with ciphertext.

```
X1QZ3N <US> X1RD89 <US> am:5b91e0 ENC1:pQ4m9xT2vB8kR ~<60 characters>
```

104 bytes. `ENC1:` is the entire body when present. `FROM` and `TO` remain in
cleartext so that an intermediate station can route the frame and identify the
recipient without reading the content.

### 6.3 Permitted use by band

| Spectrum | Signing | Encryption |
|---|---|---|
| Licence-free (Bluetooth and LoRa ISM, WiFi), and the internet | permitted | permitted, and is the default for direct messages |
| Amateur bands, under an amateur licence | permitted | not permitted |

Amateur regulations prohibit obscuring the meaning of a transmission. A licensed
operator using OPRS on amateur bands is bound by that rule as on any other mode
and must not transmit `ENC1:` there.

A signature is not encryption. It leaves the text in cleartext and establishes
only authorship, so signing is permitted on amateur bands.

An implementation able to reach amateur infrastructure must refuse to transmit a
sealed body onto it.

---

## 7. Observations

Position, movement, weather and telemetry share one frame and one vocabulary,
addressed to `!`.

```
FROM <US> ! <US> <tokens>
```

There is no separate weather frame and no separate telemetry frame. A weather
station is a station that reports temperature in addition to position.

### 7.1 Coordinates

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

| Decimals | Resolution | Appropriate for |
|---|---|---|
| 2 | 1.1 km | a town |
| 3 | 110 m | a district |
| 4 | 11 m | a normal satellite fix |
| 5 | 1.1 m | a good fix or survey equipment |
| 6 | 0.11 m | rarely justified |

A station sends only the digits its fix supports, and reports measured
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
receiver infers one. A station holding Fahrenheit converts before transmitting.

### 7.4 Telemetry

| Key | Meaning | Unit |
|---|---|---|
| `bt` | battery charge | percent |
| `vb` | supply voltage | volts |
| `rs` | received signal strength | dBm |
| `sn` | signal-to-noise ratio | dB |

`rs` and `sn` describe the link on which a frame arrived and are recorded by the
receiver. A station does not transmit its own received signal strength.

### 7.5 Time

An observation that may be relayed or held for later delivery must include a
time field. A held frame can be delivered days later, and an undated position is
plotted as current.

| Station capability | Key | Example | Meaning |
|---|---|---|---|
| keeps wall-clock time | `ts` | `ts:1780000000` | Unix seconds, UTC |
| no clock, no storage | `ag` | `ag:45` | seconds between observation and transmission |
| no clock, persistent storage | `ep` | `ep:7.4210` | boot epoch 7, 4210 seconds into that epoch |

The epoch form supports stations with no real-time clock. The station keeps a
counter in non-volatile storage, increments it once per boot, and reports it
with its seconds since boot. Two properties follow.

Ordering without a clock: between two frames from the same station, the higher
epoch is later, and within one epoch the higher uptime is later.

Anchoring: a receiver holding a clock records the wall-clock time at which it
first heard a given epoch, and can then date every frame of that epoch,
including frames delivered days later.

A station that subsequently obtains the time sends one frame carrying both
forms, anchoring that epoch for all receivers in range, and thereafter sends
`ts` only.

### 7.6 Station type and note

| Key | Meaning |
|---|---|
| `y` | station type: `node`, `wx`, `car`, `boat`, `foot`, `balloon`, `sos` |
| `n` | free text, always the last token, may contain spaces |

A receiver that does not recognise a `y` value displays a default marker and the
value as text.

### 7.7 Private extensions

Keys beginning with `x` are reserved for private and experimental use and are
never assigned by this document.

```
xco2:412 xpm25:8
```

Unknown tokens are skipped, so an extension imposes no cost on other stations.

---

## 8. Examples

Byte counts are for the complete frame including both separators.

### 8.1 Position

Minimum useful observation, coarse position, station with no clock:

```
X1QZ3N <US> ! <US> @38.72,-9.14 ag:30
```

27 bytes.

Normal fix with a clock:

```
X1QZ3N <US> ! <US> @38.7223,-9.1393 ts:1780000000
```

39 bytes.

High-precision fix with stated uncertainty. Five decimals of arithmetic, eight
metres of measured accuracy:

```
X1QZ3N <US> ! <US> @38.72231,-9.13934 e:8 ts:1780000000
```

45 bytes.

### 8.2 Movement

Person on foot:

```
X1QZ3N <US> ! <US> @38.7223,-9.1393 a:87 y:foot s:1.4 c:212 ts:1780000000
```

63 bytes.

Vehicle, with a note:

```
X1CAR7 <US> ! <US> @38.7231,-9.1402 a:87 s:13.4 c:212 e:8 y:car ts:1780000060 n:heading south on the N8
```

93 bytes.

Balloon ascending at 4.8 m/s through 11240 m:

```
X3BAL1 <US> ! <US> @38.9012,-9.0021 a:11240 v:4.8 s:9.2 c:47 y:balloon ts:1780001800
```

74 bytes.

Vessel under way, no altitude:

```
X1BOA3 <US> ! <US> @38.6902,-9.4012 s:3.1 c:275 y:boat ts:1780002400
```

58 bytes.

### 8.3 Weather

Station with three sensors:

```
X3WX01 <US> ! <US> @38.7223,-9.1393 t:14.2 h:78 b:1013.2 y:wx ts:1780000000
```

65 bytes.

Full station reporting every defined weather field plus battery:

```
X3WX01 <US> ! <US> @38.7223,-9.1393 t:14.2 h:78 b:1013.2 w:3.4 wd:210 wg:7.1 r1:0.4 r24:12.6 sr:640 bt:96 y:wx ts:1780000000
```

114 bytes, under half the packet.

Indoor sensor with no position and no clock. Position is omitted rather than
sent as zero:

```
X3WX01 <US> ! <US> t:14.2 h:78 ag:60
```

26 bytes.

### 8.4 Telemetry

Unattended node reporting power state:

```
X3RLY7 <US> ! <US> @38.7810,-9.2043 a:210 bt:64 vb:12.9 y:node ts:1780003000
```

66 bytes.

### 8.5 Emergency

```
X1QZ3N <US> ! <US> @38.7223,-9.1393 e:6 y:sos ts:1780000120 n:injured, need help
```

70 bytes.

### 8.6 Position, weather and telemetry in one frame

```
X3RLY7 <US> ! <US> @38.7810,-9.2043 a:210 t:11.8 h:88 b:1008.4 w:6.1 wd:295 bt:64 vb:12.9 y:node ts:1780003000
```

100 bytes. A receiver interested only in position reads `@` and skips the
remaining tokens.

### 8.7 Decoding a frame

```
X3RLY7 <US> ! <US> @38.7810,-9.2043 a:210 t:11.8 h:88 b:1008.4 y:node ts:1780003000
```

| Field | Value | Reading |
|---|---|---|
| FROM | `X3RLY7` | unattended station |
| TO | `!` | observation |
| `@` | `38.7810,-9.2043` | 38.7810 N, 9.2043 W, four decimals, so about 11 m |
| `a` | `210` | 210 m above mean sea level |
| `t` | `11.8` | 11.8 degrees Celsius |
| `h` | `88` | 88 percent relative humidity |
| `b` | `1008.4` | 1008.4 hPa at station level |
| `y` | `node` | unattended node |
| `ts` | `1780003000` | Unix seconds, UTC |

---

## 9. Worked exchanges

Complete sequences in transmission order.

### 9.1 Group conversation with a reply and a reaction

```
1  X1QZ3N <US> #LISBOA <US> net starts in ten minutes
2  X1RD89 <US> #LISBOA <US> +9c4e I'll be late, start without me
3  X32DVA <US> #LISBOA <US> 9c4e:like
```

Frame 1 has identifier `9c4e`, computed by every receiver from
`SHA-1("X1QZ3N|net starts in ten minutes")`. Frame 2 references it and gains its
own identifier. Frame 3 is tallied against `9c4e`, counted once for `X32DVA`,
and is not displayed as a message.

### 9.2 Direct message with delivery and read receipts

```
1  X1QZ3N <US> X1RD89 <US> am:40c124 meet at the bridge at six
2  X1RD89 <US> ?ACK <US> 40c124 d
3  X1RD89 <US> ?ACK <US> 40c124 r
```

Frame 2 is sent when the message reaches the device, frame 3 when the operator
reads it. A station not tracking reading sends frame 2 only.

### 9.3 Private message on licence-free spectrum

```
X1QZ3N <US> X1RD89 <US> am:5b91e0 ENC1:pQ4m9xT2vB8kR ~<60 characters>
```

`FROM` and `TO` are readable, so intermediate stations can route and relay the
frame. Only the body is sealed. This frame must not be transmitted on amateur
bands (section 6.3).

### 9.4 Delivery through a station that meets neither party

```
1  X1QZ3N <US> X1RD89 <US> am:40c124 meet at the bridge at six
   X1RD89 is out of range. X32DVA receives the frame and retains it.

2  X32DVA <US> X1RD89 <US> am:40c124 meet at the bridge at six
   Hours later, X32DVA encounters X1RD89 and retransmits.

3  X1RD89 <US> ?ACK <US> 40c124 d
   X32DVA receives the receipt and discards its copy.
```

The receipt identifier is unchanged throughout, so the delivered message is
recognised as the same message and duplicates are suppressed. Any other station
that retained frame 1 and receives frame 3 also discards its copy.

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

Frames 1 and 2 (47 and 47 bytes) are orderable without any clock, since the
higher uptime is later. A receiver holding a clock dates them from its own
observation of epoch 7. Frame 3 is 49 bytes and makes that anchor explicit.

### 9.7 A hiker and a weather station over one hour

```
1  X3WX01 <US> ! <US> @38.7223,-9.1393 t:14.2 h:78 b:1013.2 y:wx ts:1780000000
2  X1QZ3N <US> ! <US> @38.7223,-9.1393 a:87 y:foot s:1.4 c:212 ts:1780000000
3  X1QZ3N <US>  <US> anyone near the north gate?
4  X3RLY7 <US> X1QZ3N <US> am:7c31a9 gate is closed, use the east path
5  X1QZ3N <US> ?ACK <US> 7c31a9 d
6  X1QZ3N <US> ! <US> @38.7301,-9.1355 a:142 y:foot s:1.2 c:41 ts:1780003600
```

Frame 3 reaches whoever is in range without addressing anyone. Frame 4 is a
direct reply carrying a receipt identifier, acknowledged in frame 5. Frames 2
and 6 show the hiker's movement over the hour, and frame 1 gives the conditions
at the same location.

---

## 10. Migration from the earlier position frame

Earlier stations transmit `lat,lon[,comment]` in the `!` frame. The two forms
are distinguished by the first character of `TEXT`:

> If `TEXT` begins with a digit, `-` or `.`, it is the earlier form. Otherwise
> it is a token list.

A token list begins with a key, and a key begins with a lowercase letter or `@`.
The earlier form begins with a number. No version field is required.

Receivers should accept both forms. Senders should emit the token form.

---

## 11. Operating alongside APRS

A licensed amateur may bridge OPRS and APRS under their own callsign and
responsibility, subject to section 6.3. An `X1` or `X3` callsign is generated by
the station itself and assigned by no authority, so traffic from such a callsign
must not be originated onto amateur infrastructure. Ciphertext must never be
placed on APRS, both because APRS is a 7-bit protocol that would corrupt it and
because obscured meaning is not permitted on amateur bands.

---

## 12. Reserved

Assigned tokens: `am:`, `sd:`, `np:`, `ENC1:`, `file:`, `ih:`, `p:`, `@`, `~`,
`+`, `<id>:like`, `<id>:unlike`, and the observation keys in section 7.

Reserved control addressees: `?ACK`, `?MAIL`, `?IGATE`, `?HELLO`, `?PING`,
`?PONG`, `?PRIV`, `?FOLLOW`, `?UNFOLLOW`, `?RLY`.

Reserved first characters of `TO`: `#`, `!`, `?`.

Reserved key prefix: `x`.

A new field takes an unused key and inherits the skip-unknown rule. It does not
introduce a packet type and does not redefine an existing key.

---

## 13. Implementation status

| Element | State |
|---|---|
| Callsigns, signatures, verification | implemented |
| Direct messages, groups, area broadcast | implemented |
| Message identifiers, threads, reactions | implemented |
| Receipts and relay release | implemented |
| Parcels | implemented |
| Encryption and the band rules | implemented |
| Attachments | implemented |
| `@` coordinates | implemented |
| `ts` time | implemented on phones and desktops |
| `ag` and `ep` time | not implemented; requires an epoch counter in non-volatile storage |
| `a`, `e`, `s`, `c`, `v` movement | not implemented; the platform supplies these values and the location layer currently retains only latitude and longitude |
| `t`, `h` weather | one hardware sensor exists and reaches a local display only |
| `b`, `w`, `wd`, `wg`, `r1`, `r24`, `sr` weather | no source |
| `bt`, `vb` telemetry | not implemented; charging state is tracked, charge level is not |
| `rs`, `sn` telemetry | implemented on the receive paths |

Sections 5 and 6 describe behaviour in service. Section 7 is largely a format
definition awaiting producers.
