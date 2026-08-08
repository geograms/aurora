# OPRS, Open Packet Reporting System

Protocol specification.

OPRS carries position, movement, weather, telemetry and messages between
stations over licence-free spectrum and the internet. It occupies the same role
as APRS and requires no amateur licence.

Status: DRAFT 4. Section 17 states which parts are implemented.

---

## 1. Purpose

APRS is a proven network, and an OPRS station meeting APRS infrastructure
operates under APRS rules (section 15). APRS has two prerequisites: amateur
spectrum, and a callsign issued by a radio authority. Both are correct for a
licensed service, and both exclude everyone without a licence.

OPRS applies the same design to Bluetooth and LoRa in the ISM bands, WiFi, and
the internet, with identity derived from a keypair generated on the device.

APRS accumulated its data formats one field at a time over three decades. The
result is four incompatible position encodings, weather carried as fixed-width
fields inside a position report, telemetry whose units are defined in separate
messages that must be received beforehand, and a mixture of feet, knots, miles
per hour, Fahrenheit, hundredths of an inch and tenths of a millibar. Each
addition was constrained by a packet that was already full and by a format with
nowhere left to put a new field.

OPRS is one syntax, readable on sight, with room to grow.

---

## 2. Design rules

1. Every packet is a list of `tag:value` fields separated by one space. There
   are no positional fields, no binary framing and no escaping.
2. Every packet declares its type in the first field, so a station never has to
   guess what it is holding.
3. Every tag has a declared value type (section 4.3). A reader knows the shape
   of a value before reading it, and a tag's meaning never varies with the
   packet it appears in.
4. Any field may appear anywhere and any field may be absent. Adding a field
   never changes how an existing field is read.
5. One packet type carries every kind of observation. New data means a new tag,
   never a new packet type.
6. Nothing is defined out of band. No receiver requires prior state to read a
   packet.
7. All values are SI. Units are fixed here and never transmitted.
8. An unknown tag is skipped and an unknown packet type is ignored, in both
   cases without error.
9. A station asks for what it wants in `q:` and answers with the same words in
   `s:`. There is one vocabulary, not one per direction.
10. Values are text. Compression is not used.

A packet is readable without a decoder:

```
t:msg f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 m:net starts in ten minutes
```

74 bytes. A person reads it, and so does a five-line parser.

---

## 3. Callsigns

An OPRS callsign is `X1` or `X3` followed by four characters derived from the
station's public key:

```
X1 = person or operator
X3 = station, relay or unattended equipment
```

The four characters are taken from the bech32 encoding of the key, so the
letters `b`, `i` and `o` and the digit `1` never appear in them.

Callsigns are **always uppercase** and are **not a fixed length**. A callsign
issued by a radio authority is equally valid on the wire, including a suffix:

```
t:msg f:CT1ABC-9 d:G0XYZ/P ts:2026-08-08_14:26:40 m:gate is closed, use the east path
```

85 bytes. Nothing in this format assumes a callsign length.

An OPRS callsign is a label, not an identity. Four characters is approximately
one million values, and collisions can be produced deliberately. A receiver that
needs to establish identity verifies a signature against the full public key
(section 9). No authority issues, revokes or vouches for an `X1` or `X3`
callsign.

---

## 4. Packet

```
tag:value tag:value tag:value ...
```

- A tag is 1 to 6 lowercase ASCII letters, followed by `:`.
- A value contains no space, and is never empty.
- Fields are separated by exactly one space.
- Order is free, except that `t:` is first and `m:`, when present, is last.
- An unknown tag is skipped along with its value.

The maximum packet is **250 bytes on every transport**. This fits one LoRa
packet, one BLE5 extended advertisement, and the store-and-forward buffer of the
smallest station. Content that does not fit is split into parts (section 6.6),
never compressed.

`m:` is the one field whose value may contain spaces, which is why it is last:
everything after `m:` is the message. It needs no delimiter and no escaping, so
a message may contain spaces, colons, URLs and any punctuation.

### 4.1 Envelope tags

| Tag | Type | Meaning |
|---|---|---|
| `t` | `enum` | packet type, always the first field |
| `f` | `call` | sending callsign |
| `d` | `dest` | destination: a callsign, a group name, or absent for a broadcast |
| `ts` | `time` | when the packet was composed |
| `q` | `words` | what the sender wants back (section 7) |
| `s` | `words` | what this packet answers or reports (section 7) |
| `r` | `hex6` | the identifier of another packet this one refers to |
| `n` | `ratio` | this packet is part i of n |
| `add` | `enum` | something this packet adds (section 6.5) |
| `remove` | `enum` | something this packet withdraws (section 6.5) |
| `vi` | `call` | station that relayed this packet (section 13) |
| `m` | `text` | human-readable content, always last |
| `file` | `ref` | content hash and type of a referenced file |
| `x` | `b64` | sealed body |
| `g` | `sig` | signature |
| `k` | `bech32` | public key, in `t:id` only |

### 4.2 Packet types

| `t:` | Purpose |
|---|---|
| `msg` | a message, to a station, a group, or anyone in range |
| `obs` | an observation: position, movement, weather, telemetry |
| `ack` | a receipt or an answer to a request |
| `rct` | a reaction to another message |
| `req` | a request for data another station holds |
| `id` | an identity announcement, binding callsign to public key |
| `png` | a reachability test |
| `pnr` | a reply to `png` |

An unknown type is ignored. It is never an error and is never displayed as a
message. Types not listed here are reserved (section 16).

### 4.3 Value types

The type is fixed by this document and is never transmitted.

| Type | Form | Example |
|---|---|---|
| `int` | digits, optional leading `-` | `210` |
| `dec` | digits, optional leading `-`, optional single `.` and fraction | `-9.1393` |
| `enum` | one lowercase word from a list given with the tag | `foot` |
| `words` | one or more lowercase words separated by commas | `ack,read` |
| `call` | uppercase letters, digits, `-` and `/` | `CT1ABC-9` |
| `dest` | a `call` or a group name | `LISBOA` |
| `hex6` | exactly 6 lowercase hexadecimal characters | `f6ff8d` |
| `time` | `YYYY-MM-DD_HH:MM:SS`, UTC | `2026-08-08_14:26:40` |
| `coord` | two `dec` separated by a comma, latitude then longitude | `38.7223,-9.1393` |
| `ratio` | two `int` separated by `/`, position then total | `2/3` |
| `epoch` | two `int` separated by a dot, boot counter then seconds | `7.4210` |
| `ref` | 64 lowercase hexadecimal characters, a dot, 1 to 8 lowercase alphanumerics | `9f2c...0e13.jpg` |
| `b64` | base64url, no padding | `pQ4m9xT2vB8kR` |
| `bech32` | a bech32 string | `npub1qz3n7...` |
| `sig` | 60 characters, base85, no space | |
| `text` | any bytes, spaces included | `heading south on the N8` |

A value that does not match its declared type is skipped, as an unknown tag is.
A packet is never rejected as a whole because one field is malformed.

### 4.4 Time

`ts:` is written the way a person reads it, in UTC:

```
ts:2026-08-08_14:26:40
```

The `_` keeps it one field. No offset is transmitted, because there is no local
time on the wire.

A packet that may be relayed or carried **must** have a time field. A carried
packet can be delivered days later, and an undated position is plotted as
current. Two alternatives exist for stations without a clock (section 10.5).

### 4.5 Extending the format

A new field takes an unused tag, declares its type, and is placed anywhere.
Receivers that do not know the tag skip it and its value. No existing field
moves, no packet type is added, and no version is negotiated.

Tags beginning with `z` are reserved for private and experimental use and are
never assigned by this document.

```
t:obs f:X3WX01 p:38.7223,-9.1393 c:14.2 zpm:8 ts:2026-08-08_14:26:40
```

68 bytes. Every existing receiver reads `c:14.2` and `ts:`, skips `zpm:8`, and
is otherwise unaffected.

---

## 5. Message identifiers

A packet carrying a payload has an identifier that **is not transmitted**. Both
ends compute it:

```
id = first 6 hex characters of sha256("<f>|<ts>|<payload>")
```

where `<payload>` is the value of `m:`, or of `x:` if there is no `m:`, or of
`file:` if there is neither.

Nothing announces its own identifier. A packet already carries who sent it and
when, so the identifier is free.

The timestamp is what makes this work. Hashing content alone would give every
`OK` ever sent the same identifier, and `OK` is the most common message on any
network:

```
X1QZ3N  2026-08-08_14:26:40  OK   ->  4ec9ed
X1QZ3N  2026-08-08_14:27:22  OK   ->  2ff664
X1RD89  2026-08-08_14:26:40  OK   ->  db8cdf
```

Sender, second and text together are unique in practice.

`r:` carries an identifier only when a packet refers to a message **it did not
send**: a reply, a reaction, or a receipt. Adding, removing or checking a
signature does not change an identifier, and neither does relaying (section 13),
because none of them changes `f:`, `ts:` or the payload.

---

## 6. Messages

### 6.1 Broadcast

No `d:`. The packet is addressed to whoever is in range.

```
t:msg f:X1QZ3N ts:2026-08-08_14:26:40 m:anyone near the north gate?
```

67 bytes.

### 6.2 Direct

```
t:msg f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 m:meet at the bridge at six
```

74 bytes, identifier `101a23`.

### 6.3 Group

`d:` holds a group name. Group names are uppercase, 1 to 16 characters. A
station tells a group from a callsign by the `X1`/`X3` prefix and the four
characters that follow, so a group may not be named like an OPRS callsign.

```
t:msg f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 m:net starts in ten minutes
```

74 bytes, identifier `f6ff8d`.

### 6.4 Replies

`r:` names the message being replied to.

```
t:msg f:X1RD89 d:LISBOA ts:2026-08-08_14:36:00 r:f6ff8d m:I'll be late, start without me
```

88 bytes. The reply has its own identifier, computed the same way, so it can be
replied to in turn. A receiver that has not seen the parent still displays the
reply, marked as answering a message it does not hold.

### 6.5 Reactions

```
t:rct f:X32DVA d:LISBOA r:f6ff8d add:like
t:rct f:X32DVA d:LISBOA r:f6ff8d remove:like
```

41 and 44 bytes. `add:` states what is being added and `remove:` withdraws that
same thing, so neither has to be read as the negation of the other. A reaction
carries no `m:`. It is counted once per callsign, is
idempotent, is not displayed as a message and raises no notification.

### 6.6 Long messages

A message longer than one packet is split into numbered parts. Every part
carries the same `ts:` and its own `n:`.

```
t:msg f:X3RLY7 d:LISBOA ts:2026-08-08_14:26:40 n:1/3 m:The repeater on the hill is down.
t:msg f:X3RLY7 d:LISBOA ts:2026-08-08_14:26:40 n:2/3 m:We swapped the antenna feed this morning
t:msg f:X3RLY7 d:LISBOA ts:2026-08-08_14:26:40 n:3/3 m:and it is back up, but only just.
```

88, 95 and 88 bytes.

- Reassembly is keyed on `(f, ts)`. The parts of one message share a timestamp,
  so no identifier has to be transmitted to bind them.
- Only `m:` is split. Every other field is carried whole on the part it belongs
  to.
- **A sender splits only at a space, and never inside a word.**
- **A receiver joins the `m:` values in order with exactly one space between
  them.** No part begins or ends with a space, so there is never a doubled space
  and never a missing one.
- The identifier of the whole message is computed from the joined text.
- Incomplete sets are held for 10 minutes and then discarded. A partial message
  is never displayed.
- Parts may arrive in any order. A repeated part number is ignored.
- A set is limited to 16 parts. Longer content is sent as a file.

### 6.7 Files

`file:` is the SHA-256 digest of the file contents as 64 lowercase hexadecimal
characters, a dot, and 1 to 8 lowercase alphanumeric characters giving the type.

```
t:msg f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 file:9f2c4e1a7b3d5f8092a6c4e7b1d3f5a8c2e4906b8d1f3a5c7e9b2d4f6a8c0e13.jpg m:the antenna after the storm
```

150 bytes. The caption is an ordinary `m:` field.

The hash identifies the file exactly, so any station holding those bytes can
satisfy the reference and a receiver can verify what it obtained. The extension
is advisory: it indicates how to present the content and never affects
identification. A receiver that does not recognise an extension offers the file
as an opaque download.

How the bytes are transferred is outside this specification. A reference remains
valid whether the file arrives over the same radio, over the internet, or on
physical media.

---

## 7. Asking and answering

`q:` says what the sender wants back. `s:` answers using the same words.

```
q:ack        confirm this reached the device
q:read       confirm the operator read it
q:pos        send your position
q:bat        send your battery level
q:id         send your public key
q:pnr        reply to this reachability test
```

Several are separated by commas. An unknown word is ignored, so `q:pos,bat,co2`
still returns position and battery from a station that has never heard of CO2.

Absence of `q:` means nothing is expected back, so silence is never ambiguous.

```
t:msg f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 q:ack,read m:did you get the keys?
```

81 bytes, identifier `8ab15f`.

The answers, naming that identifier in `r:`:

```
t:ack f:X1RD89 d:X1QZ3N r:8ab15f s:ack
t:ack f:X1RD89 d:X1QZ3N r:8ab15f s:read
```

38 and 39 bytes. `s:ack` is sent when the message reaches the device, `s:read`
when the operator reads it. A station that does not track reading sends `s:ack`
only, and the sender sees exactly which of the two requests was satisfied.

A request for data is the same exchange without a message:

```
t:req f:X1QZ3N d:X3RLY7 ts:2026-08-08_14:26:40 q:pos,bat
t:obs f:X3RLY7 d:X1QZ3N p:38.7810,-9.2043 bt:64 ts:2026-08-08_14:26:40 s:pos,bat
```

56 and 80 bytes. A station holding only part of what was asked says so, rather
than failing:

```
t:obs f:X3RLY7 d:X1QZ3N p:38.7810,-9.2043 ts:2026-08-08_14:26:40 s:pos
```

70 bytes: position sent, battery not available, no error packet needed.

`s:no` is the one word not in `q:`, for a request a station will not or cannot
serve at all:

```
t:ack f:X3RLY7 d:X1QZ3N ts:2026-08-08_14:26:40 s:no
```

51 bytes.

Any station may act on a receipt it overhears. A station holding a message for
later delivery discards its copy on hearing the matching `s:ack`.

---

## 8. Reserved words

`q:` and `s:` words assigned by this document: `ack`, `read`, `pos`, `bat`,
`id`, `pnr`, `no`. Reactions assigned for `add:` and `remove:`: `like`. All
other words are reserved. A word
beginning with `z` is private, as a tag beginning with `z` is.

---

## 9. Signing and privacy

### 9.1 Signatures

`g:` covers the whole packet with the `g:` field and its separating space
removed. Position in the packet is therefore not significant, and a verifier
reconstructs the signed text by deletion.

```
t:msg f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 g:<60 characters> m:net starts in ten minutes
```

137 bytes. The identifier is `f6ff8d`, the same as the unsigned packet in
section 6.3, because signing changes neither `f:`, `ts:` nor the payload.

| State | Condition |
|---|---|
| verified | signature present, valid, signer key known |
| forged | signature present and invalid |
| unverified | signature present, signer key unknown |
| unsigned | no signature |

Reactions and identity announcements are not signed.

### 9.2 Encryption

`x:` carries the sealed body and replaces `m:`.

```
t:msg f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 x:pQ4m9xT2vB8kR g:<60 characters>
```

125 bytes. `t:`, `f:`, `d:` and `ts:` stay in cleartext, so an intermediate
station can route the packet, identify the recipient and release a carried copy
on the matching receipt, without reading the content.

A later cipher suite takes a new tag rather than changing this one.

### 9.3 Identity

```
t:id f:X1QZ3N ts:2026-08-08_14:26:40 k:npub1qz3n7fu9j9uenmyva7ha6x9eqwymytv2847ccv4vxdmn45y50q7h7k5f
```

100 bytes. A receiver stores the binding and uses it to verify signed packets
from that callsign. Answers `q:id`.

An identity announcement is not signed, because the signature would have to be
verified with the key the packet is carrying. Trust comes from repetition, from
consistency with the callsign derivation in section 3, and from the signed
packets that follow.

### 9.4 Permitted use by band

| Spectrum | Signing | Encryption |
|---|---|---|
| Licence-free (Bluetooth and LoRa ISM, WiFi), and the internet | permitted | permitted, and is the default for direct messages |
| Amateur bands, under an amateur licence | permitted | not permitted |

Amateur regulations prohibit obscuring the meaning of a transmission. A licensed
operator using OPRS on amateur bands is bound by that rule as on any other mode
and must not transmit `x:` there.

A signature is not encryption. It leaves the text in cleartext and establishes
only authorship, so signing is permitted on amateur bands.

An implementation able to reach amateur infrastructure must refuse to transmit a
sealed body onto it.

---

## 10. Observations

Position, movement, weather and telemetry share one packet type and one
vocabulary. There is no separate weather packet and no separate telemetry
packet. A weather station is a station that reports temperature in addition to
position.

### 10.1 Position

`p:` is decimal degrees, WGS84, latitude then longitude, negative for south and
west. No hemisphere letters, no degrees-minutes-seconds, no compression.

```
p:38.7223,-9.1393
```

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

Absence of `p:` means the position is unknown. It does not mean zero. `0,0` is a
valid coordinate in the Gulf of Guinea.

### 10.2 Movement

| Tag | Type | Meaning | Unit |
|---|---|---|---|
| `p` | `coord` | position | degrees |
| `a` | `dec` | altitude above mean sea level | metres |
| `e` | `dec` | horizontal accuracy radius | metres |
| `v` | `dec` | speed over ground | metres per second |
| `u` | `int` | course over ground, 0 to 359 | degrees true |
| `vs` | `dec` | vertical speed, signed | metres per second |

### 10.3 Weather

| Tag | Type | Meaning | Unit |
|---|---|---|---|
| `c` | `dec` | air temperature | degrees Celsius |
| `h` | `int` | relative humidity | percent |
| `b` | `dec` | barometric pressure, station level | hPa |
| `w` | `dec` | wind speed, sustained | metres per second |
| `wd` | `int` | wind direction, the direction it blows from | degrees true |
| `wg` | `dec` | wind gust, peak | metres per second |
| `rh` | `dec` | rainfall, previous hour | mm |
| `rd` | `dec` | rainfall, previous 24 hours | mm |
| `sr` | `int` | solar irradiance | watts per square metre |

Conversion to SI is performed by the sender. No unit is transmitted and no
receiver infers one. A station holding Fahrenheit converts before transmitting.

### 10.4 Telemetry and station type

| Tag | Type | Meaning | Unit |
|---|---|---|---|
| `bt` | `int` | battery charge | percent |
| `vl` | `dec` | supply voltage | volts |
| `rs` | `int` | received signal strength | dBm |
| `sn` | `dec` | signal-to-noise ratio | dB |
| `y` | `enum` | `node`, `wx`, `car`, `boat`, `foot`, `balloon`, `sos` | |

`rs` and `sn` describe the link a packet arrived on and are reported by the
receiver, in a `pnr` reply. A station does not transmit its own received signal
strength.

An observation carries a note in `m:`, the same tag a message uses.

### 10.5 Stations without a clock

| Station capability | Tag | Example | Meaning |
|---|---|---|---|
| keeps wall-clock time | `ts` | `ts:2026-08-08_14:26:40` | UTC |
| no clock, no storage | `ag` | `ag:30` | seconds between observation and transmission |
| no clock, persistent storage | `ep` | `ep:7.4210` | boot epoch 7, 4210 seconds into that epoch |

The epoch form supports stations with no real-time clock. The station keeps a
counter in non-volatile storage, increments it once per boot, and reports it
with its seconds since boot. Two properties follow.

Ordering without a clock: between two packets from the same station, the higher
epoch is later, and within one epoch the higher uptime is later.

Anchoring: a receiver holding a clock records the wall-clock time at which it
first heard a given epoch, and can then date every packet of that epoch,
including packets delivered days later.

A station that subsequently obtains the time sends one packet carrying both
forms, anchoring that epoch for all receivers in range, and thereafter sends
`ts:` only.

---

## 11. Examples

### 11.1 Position

Coarse position, station with no clock:

```
t:obs f:X1QZ3N p:38.72,-9.14 ag:30
```

34 bytes.

Normal fix with a clock:

```
t:obs f:X1QZ3N p:38.7223,-9.1393 ts:2026-08-08_14:26:40
```

55 bytes.

Five decimals of arithmetic, eight metres of measured accuracy:

```
t:obs f:X1QZ3N p:38.72231,-9.13934 e:8 ts:2026-08-08_14:26:40
```

61 bytes.

### 11.2 Movement

Person on foot:

```
t:obs f:X1QZ3N p:38.7223,-9.1393 a:87 y:foot v:1.4 u:212 ts:2026-08-08_14:26:40
```

79 bytes.

Vehicle, with a note:

```
t:obs f:X1CAR7 p:38.7231,-9.1402 a:87 v:13.4 u:212 e:8 y:car ts:2026-08-08_14:26:40 m:heading south on the N8
```

109 bytes.

Balloon ascending at 4.8 m/s through 11240 m:

```
t:obs f:X3BAL1 p:38.9012,-9.0021 a:11240 vs:4.8 v:9.2 u:47 y:balloon ts:2026-08-08_14:26:40
```

91 bytes.

Vessel under way, no altitude:

```
t:obs f:X1BOA3 p:38.6902,-9.4012 v:3.1 u:275 y:boat ts:2026-08-08_14:26:40
```

74 bytes.

### 11.3 Weather

Station with three sensors:

```
t:obs f:X3WX01 p:38.7223,-9.1393 c:14.2 h:78 b:1013.2 y:wx ts:2026-08-08_14:26:40
```

81 bytes.

Every defined weather field plus battery, fourteen fields:

```
t:obs f:X3WX01 p:38.7223,-9.1393 c:14.2 h:78 b:1013.2 w:3.4 wd:210 wg:7.1 rh:0.4 rd:12.6 sr:640 bt:96 y:wx ts:2026-08-08_14:26:40
```

129 bytes, leaving 121 for fields not yet defined.

Indoor sensor with no position and no clock. Position is omitted rather than
sent as zero:

```
t:obs f:X3WX01 c:14.2 h:78 ag:60
```

32 bytes.

### 11.4 Telemetry

Unattended node reporting power state:

```
t:obs f:X3RLY7 p:38.7810,-9.2043 a:210 bt:64 vl:12.9 y:node ts:2026-08-08_14:26:40
```

82 bytes.

### 11.5 Emergency

```
t:obs f:X1QZ3N p:38.7223,-9.1393 e:6 y:sos ts:2026-08-08_14:26:40 q:ack m:injured, need help
```

92 bytes, identifier `4db89b`. `q:ack` asks any station that hears it to
confirm, and any station may answer:

```
t:ack f:X32DVA d:X1QZ3N r:4db89b s:ack
```

38 bytes.

### 11.6 Reachability

```
t:png f:X1QZ3N d:X3RLY7 ts:2026-08-08_14:26:40
t:pnr f:X3RLY7 d:X1QZ3N ts:2026-08-08_14:26:40 rs:-92 sn:7.5
```

46 and 60 bytes. The reply reports the signal the test arrived with, which is
the receiver's measurement, not the sender's.

### 11.7 Reading a packet

```
t:obs f:X3RLY7 p:38.7810,-9.2043 a:210 c:11.8 h:88 b:1008.4 y:node ts:2026-08-08_14:26:40
```

89 bytes.

| Field | Type | Reading |
|---|---|---|
| `t:obs` | `enum` | an observation; a station filtering for messages stops here |
| `f:X3RLY7` | `call` | unattended station |
| `p:38.7810,-9.2043` | `coord` | 38.7810 N, 9.2043 W, four decimals, so about 11 m |
| `a:210` | `dec` | 210 m above mean sea level |
| `c:11.8` | `dec` | 11.8 degrees Celsius |
| `h:88` | `int` | 88 percent relative humidity |
| `b:1008.4` | `dec` | 1008.4 hPa at station level |
| `y:node` | `enum` | unattended node |
| `ts:2026-08-08_14:26:40` | `time` | UTC |

There is no `d:`, so it is addressed to no one in particular. There is no `q:`,
so nothing is expected back.

---

## 12. Worked exchanges

### 12.1 Group conversation with a reply and a reaction

```
1  t:msg f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 m:net starts in ten minutes
2  t:msg f:X1RD89 d:LISBOA ts:2026-08-08_14:36:00 r:f6ff8d m:I'll be late, start without me
3  t:rct f:X32DVA d:LISBOA r:f6ff8d add:like
```

74, 88 and 41 bytes. Packet 1 transmits no identifier; every receiver computes
`f6ff8d` from its sender, time and text. Packets 2 and 3 name that value.
Packet 2 has its own computed identifier and can be replied to in turn.

### 12.2 Direct message with both receipts

```
1  t:msg f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 q:ack,read m:did you get the keys?
2  t:ack f:X1RD89 d:X1QZ3N r:8ab15f s:ack
3  t:ack f:X1RD89 d:X1QZ3N r:8ab15f s:read
```

81, 38 and 39 bytes. Packet 1 asks for two things by name and packets 2 and 3
answer with the same names.

### 12.3 Request and partial answer

```
1  t:req f:X1QZ3N d:X3RLY7 ts:2026-08-08_14:26:40 q:pos,bat
2  t:obs f:X3RLY7 d:X1QZ3N p:38.7810,-9.2043 ts:2026-08-08_14:26:40 s:pos
```

56 and 70 bytes. The station has no battery reading. It answers with what it
has and says which request that satisfied, so the asker is not left waiting.

### 12.4 A long group message

```
1  t:msg f:X3RLY7 d:LISBOA ts:2026-08-08_14:26:40 n:1/3 m:The repeater on the hill is down.
2  t:msg f:X3RLY7 d:LISBOA ts:2026-08-08_14:26:40 n:2/3 m:We swapped the antenna feed this morning
3  t:msg f:X3RLY7 d:LISBOA ts:2026-08-08_14:26:40 n:3/3 m:and it is back up, but only just.
```

88, 95 and 88 bytes. Reassembly is keyed on `(X3RLY7, 2026-08-08_14:26:40)`.
Joined with one space between parts:

```
The repeater on the hill is down. We swapped the antenna feed this morning and it is back up, but only just.
```

If part 2 never arrives, the set is discarded after 10 minutes and nothing is
displayed.

### 12.5 Clockless weather station anchored by a neighbour

```
1  t:obs f:X3WX01 p:38.7223,-9.1393 c:14.1 h:80 ep:7.3600
2  t:obs f:X3WX01 p:38.7223,-9.1393 c:14.2 h:78 ep:7.4210
   A receiver holding a clock records: epoch 7 heard at 2026-08-08_14:26:40.

3  t:obs f:X3WX01 p:38.7223,-9.1393 ep:7.9930 ts:2026-08-08_14:26:40
   The station has obtained the time and anchors epoch 7 for all receivers.

4  t:obs f:X3WX01 p:38.7223,-9.1393 c:15.0 h:74 ts:2026-08-08_14:36:00
```

54, 54, 65 and 67 bytes. Packets 1 and 2 are orderable without any clock, since
the higher uptime is later. Packet 3 makes the anchor explicit.

---

## 13. Relaying and carried messages

A message to a station that no path reaches is handed to a nearby station, which
carries it and delivers it on meeting the recipient.

**A carrier never rewrites `f:`.** It retransmits the packet as received and
adds `vi:` naming itself:

```
t:msg f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 vi:X32DVA q:ack m:meet at the bridge at six
```

90 bytes. `f:` still names the author, so the identifier is still `101a23`, any
signature still verifies, and the recipient sees the original time rather than
the time it was finally handed over.

`vi:` records who carried it. Where more than one station relays a packet, each
appends its callsign to the existing `vi:` value with a comma.

The recipient's `s:ack` releases carriers still holding a copy: a station that
overhears a receipt for a message it is carrying discards its copy.

---

## 14. Adding a field, worked

A format is judged by what it costs to add something it did not foresee. Suppose
a station gains an air-quality sensor.

The implementer takes an unused tag, gives it a type and a unit, and transmits
it:

```
t:obs f:X3WX01 p:38.7223,-9.1393 c:14.2 zpm:8 ts:2026-08-08_14:26:40
```

68 bytes. The new field costs six bytes. Every existing receiver reads `zpm:8`,
does not recognise the tag, skips it, and continues at `ts:`. Nothing is
versioned, nothing is negotiated, and no other field is affected.

The tag begins with `z` because unassigned tags belong in the private space. If
this document later assigns it, the entry is added to the table in section 10.3
with its type and unit, and a shorter tag may be chosen; nothing else changes.

The same holds for a new word in `q:` and `s:`. A station asking `q:pos,co2`
gets `s:pos` from every station built before CO2 existed, with no error and no
negotiation.

---

## 15. Operating alongside APRS

A licensed amateur may bridge OPRS and APRS under their own callsign and
responsibility, subject to section 9.4. An `X1` or `X3` callsign is generated by
the station itself and assigned by no authority, so traffic from such a callsign
must not be originated onto amateur infrastructure. Ciphertext must never be
placed on APRS, both because APRS is a 7-bit protocol that would corrupt it and
because obscured meaning is not permitted on amateur bands.

---

## 16. Reserved

Assigned packet types: `msg`, `obs`, `ack`, `rct`, `req`, `id`, `png`, `pnr`.
All other lowercase words are reserved.

Assigned tags: `t`, `f`, `d`, `ts`, `q`, `s`, `r`, `n`, `vi`, `m`, `file`, `x`,
`g`, `k`, `add`, `remove`, `p`, `a`, `e`, `v`, `u`, `vs`, `c`, `h`, `b`, `w`,
`wd`, `wg`, `rh`, `rd`, `sr`, `bt`, `vl`, `rs`, `sn`, `y`, `ag`, `ep`.

Assigned `q:` and `s:` words: section 8.

Reserved prefix: `z`, for both tags and words.

A new field takes an unused tag and inherits the skip-unknown rule. A new
purpose takes an unused type. Neither redefines an existing assignment.

---

## 17. Implementation status

| Element | State |
|---|---|
| Callsigns, signatures, verification | implemented |
| Direct, group and broadcast messages | implemented |
| Replies and reactions | implemented |
| Receipts and carrier release | implemented |
| Long messages in parts | implemented |
| Encryption and the band rules | implemented |
| File references by content hash | implemented |
| Identity announcement | implemented |
| `tag:value` fields separated by spaces | not implemented; the current wire has three `0x1F`-separated fields and packs everything else into a trailing string |
| `t:` packet type as the first field | not implemented; the current wire infers the purpose from the destination field |
| Derived identifiers | not implemented; the current wire hashes message content without a timestamp, so every `OK` collides, and carries a separate receipt identifier |
| `ts:` on messages | not implemented; messages carry no time, although they are the packets most often carried for days |
| `q:` and `s:` | not implemented; receipts exist, requests do not |
| `vi:` instead of rewriting `f:` | not implemented; a carrier currently retransmits under its own callsign, which breaks both authorship and the identifier |
| Variable-length and authority-issued callsigns | not implemented; the current wire assumes the six-character `X1`/`X3` form |
| `p:` coordinates | implemented in a different encoding |
| `ag:` and `ep:` time | not implemented; requires an epoch counter in non-volatile storage |
| `a`, `e`, `v`, `u`, `vs` movement | not implemented; the platform supplies these values and the location layer currently retains only latitude and longitude |
| `c`, `h` weather | one hardware sensor exists and reaches a local display only |
| `b`, `w`, `wd`, `wg`, `rh`, `rd`, `sr` weather | no source |
| `bt`, `vl` telemetry | not implemented; charging state is tracked, charge level is not |
| `rs`, `sn` telemetry | implemented on the receive paths |
