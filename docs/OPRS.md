# OPRS, Open Packet Reporting System

Protocol specification.

OPRS carries position, movement, weather, telemetry and messages between
stations over licence-free spectrum and the internet. It occupies the same role
as APRS and requires no amateur licence.

Status: DRAFT 3. Section 14 states which parts are implemented.

---

## 1. Purpose

APRS is a proven network, and an OPRS station meeting APRS infrastructure
operates under APRS rules (section 12). APRS has two prerequisites: amateur
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

OPRS names its fields so that a new one can always be added, and spends as few
bytes as possible doing it.

---

## 2. Design rules

1. Every packet declares its type in the first field, so a receiver can sort,
   filter or discard without parsing the remainder.
2. A tag opens a field. The field runs until the next tag. Nothing separates
   them, because nothing needs to: the tag alphabet and the value alphabet are
   disjoint (section 4.2).
3. Every tag has a declared value type (section 4.5). A parser knows the shape
   of a value before reading it, and a tag's type never varies with the packet
   it appears in.
4. Any field may appear anywhere. Adding a field never changes how an existing
   field is read.
5. One packet type carries every kind of observation. New data means a new tag,
   never a new packet type.
6. Nothing is defined out of band. No receiver requires prior state to read a
   packet.
7. All values are SI. Units are fixed here and never transmitted.
8. All fields are optional. A station sends what it has.
9. An unknown tag is skipped and an unknown packet type is ignored, in both
   cases without error.
10. Values are text. Compression is not used.

Rule 2 is what keeps the format from turning into XML. A self-describing format
usually pays twice per field, once to name it and once to delimit it, and that
overhead is charged on every packet forever. OPRS pays once. Every assigned tag
is one or two characters and its value ends where the next tag begins, so a
temperature costs
`T14.2`, five bytes, of which four are the reading.

Rules 3 and 4 are what keep it from turning into APRS. Fields are named, not
positional, so a station sends what it has and a field added in ten years costs
nothing to the receivers that do not know it.

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
(section 7). No authority issues, revokes or vouches for a callsign.

---

## 4. Packet

```
TYPE<US>FROM<US>TO<US>fields
```

`<US>` is the ASCII unit separator, `0x1F`, a single byte. There are no spaces
around it. Every example in this document is written exactly as it is
transmitted.

Three positional header fields, then a run of tagged fields. The maximum packet
is **250 bytes on every transport**. This fits one LoRa packet, one BLE5
extended advertisement, and the store-and-forward buffer of the smallest
station. Content that does not fit is split into parts (section 5.7), never
compressed.

### 4.1 Header

The three header fields are positional because they are present in every packet,
their meaning never varies, and a station filters on them. `TYPE` at offset 0
lets a low-power relay discard an observation after three bytes. `TO` at a fixed
field index lets it answer "is this mine" without reading the payload.

`TYPE` is 1 to 3 uppercase ASCII letters and is always present.

| Type | Purpose | `TO` |
|---|---|---|
| `SMS` | direct message to one station | recipient callsign |
| `GRP` | group message | group name |
| `ALL` | area broadcast, addressed to whoever is in range | empty |
| `OBS` | observation: position, movement, weather, telemetry | empty |
| `ID` | identity announcement, binding callsign to public key | empty |
| `ACK` | receipt | station being acknowledged |
| `REQ` | request for data held by another station | recipient callsign |
| `PNG` | reachability test | empty or a callsign |
| `PNR` | reply to `PNG` | callsign of the originator |

An unknown type is ignored. It is never an error and is never displayed as a
message. Types not listed here are reserved (section 13).

`FROM` is the sending callsign. `TO` is a plain callsign or group name with no
prefix character; the type already states whether the destination is a station,
a group, or nobody in particular. `TO` is empty for `ALL`, `OBS` and `ID`, and
its separator is still present, so the header is always exactly three fields.

Group names are 1 to 16 characters, uppercase letters and digits.

### 4.2 Fields

A field is a tag immediately followed by its value. There is no separator
between them and no separator after them.

- **A tag is 1 to 3 uppercase ASCII letters.** At a tag position the longest
  assigned tag matches.
- **A value never contains an uppercase ASCII letter.** Values are digits,
  lowercase letters, and `. - , /`.
- **A compact field ends at the next uppercase letter, or at `0x1F`, or at the
  end of the packet.** That is the whole rule.
- **A value is never empty.** Two adjacent tags would be read as one longer tag.
- An unknown tag is skipped: the reader consumes it and the value that follows,
  and continues at the next tag.

```
T14.2H78B1013.2
```

Fifteen bytes carrying three readings. `T` opens a field, `14.2` runs until `H`,
which opens the next. Naming costs one byte per field and delimiting costs
nothing, because the tag that ends a field is the same byte that begins the next
one.

Five value types are mixed-case and cannot end at an uppercase letter: human
text, file references, ciphertext, public keys and signatures. Their tags are
**delimited**: the value runs to the next `0x1F` or to the end of the packet.
Which tags these are is fixed by section 4.5, so a reader always knows before it
reads the value.

```
SMS<US>X1QZ3N<US>X1RD89<US>ID40c124<US>Mmeet at the bridge at six
```

53 bytes. `ID40c124` is compact. `M` is delimited, so the text runs to the end
and may contain anything except `0x1F`, including uppercase, spaces and colons.

### 4.3 Message text

Human text is the `M` field. It is an ordinary field with an ordinary tag, and
its only distinction is that it is delimited rather than compact.

```
SMS<US>X1QZ3N<US>X1RD89<US>Mmeet at the bridge at six
```

44 bytes, of which 25 are the message and one is the tag.

### 4.4 Extending the format

A new field takes an unused tag, declares its type, and is placed anywhere.
Receivers that do not know the tag skip it and the value that follows. No
existing field moves, no packet type is added, and no version is negotiated.
Section 11 works an example.

Tags beginning with `X` are reserved for private and experimental use and are
never assigned by this document.

### 4.5 Tags

Compact tags. The value ends at the next uppercase letter.

| Tag | Type | Meaning | Unit |
|---|---|---|---|
| `ID` | `hex6` | identifier of this message | |
| `RE` | `hex6` | this message replies to that identifier | |
| `LK` | `hex6` | reaction to that identifier | |
| `UL` | `hex6` | withdrawal of a reaction | |
| `PT` | `ratio` | this packet is part i of n | |
| `ST` | `enum`: `d`, `r` | receipt state | |
| `P` | `coord` | position | degrees |
| `A` | `dec` | altitude above mean sea level | metres |
| `E` | `dec` | horizontal accuracy radius | metres |
| `S` | `dec` | speed over ground | metres per second |
| `C` | `int` | course over ground, 0 to 359 | degrees true |
| `VS` | `dec` | vertical speed, signed | metres per second |
| `T` | `dec` | air temperature | degrees Celsius |
| `H` | `int` | relative humidity | percent |
| `B` | `dec` | barometric pressure, station level | hPa |
| `W` | `dec` | wind speed, sustained | metres per second |
| `WD` | `int` | wind direction, the direction it blows from | degrees true |
| `WG` | `dec` | wind gust, peak | metres per second |
| `RH` | `dec` | rainfall, previous hour | mm |
| `RD` | `dec` | rainfall, previous 24 hours | mm |
| `SR` | `int` | solar irradiance | watts per square metre |
| `BT` | `int` | battery charge | percent |
| `VL` | `dec` | supply voltage | volts |
| `RS` | `int` | received signal strength | dBm |
| `SN` | `dec` | signal-to-noise ratio | dB |
| `Y` | `enum` | station type | |
| `TS` | `time` | Unix seconds, UTC | seconds |
| `AG` | `int` | seconds between observation and transmission | seconds |
| `EP` | `epoch` | boot counter and seconds into it | |

Delimited tags. The value runs to the next `0x1F` or the end of the packet.

| Tag | Type | Meaning |
|---|---|---|
| `M` | `text` | human-readable content |
| `F` | `ref` | content hash and type of a referenced file |
| `X` | `b64` | sealed body, cipher suite 1 |
| `K` | `bech32` | public key, in `ID` only |
| `G` | `sig` | signature over the preceding fields |

Value types. The type is fixed by this document and is never transmitted.

| Type | Form | Example |
|---|---|---|
| `int` | digits, optional leading `-` | `210` |
| `dec` | digits, optional leading `-`, optional single `.` and fraction | `-9.1393` |
| `enum` | one lowercase value from a list given with the tag | `foot` |
| `hex6` | exactly 6 lowercase hexadecimal characters | `9c4e21` |
| `time` | `int`, Unix seconds, UTC | `1780000000` |
| `coord` | two `dec` separated by a comma, latitude then longitude | `38.7223,-9.1393` |
| `ratio` | two `int` separated by `/`, position then total | `2/3` |
| `epoch` | two `int` separated by a dot, boot counter then seconds | `7.4210` |
| `text` | any bytes except `0x1F` | `heading south on the N8` |
| `ref` | 64 lowercase hexadecimal characters, a dot, 1 to 8 lowercase alphanumerics | `9f2c...0e13.jpg` |
| `b64` | base64url, no padding | `pQ4m9xT2vB8kR` |
| `bech32` | a bech32 string | `npub1qz3n7...` |
| `sig` | 60 characters, base85 | |

A value that does not match its declared type is skipped, as an unknown tag is.
A packet is never rejected as a whole because one field is malformed.

---

## 5. Messages

### 5.1 Direct

```
SMS<US>X1QZ3N<US>X1RD89<US>Mmeet at the bridge at six
```

44 bytes.

### 5.2 Group

```
GRP<US>X1QZ3N<US>LISBOA<US>ID9c4e21<US>Mnet starts in ten minutes
```

53 bytes.

### 5.3 Area broadcast

`ALL` addresses any station in range.

```
ALL<US>X1QZ3N<US><US>Manyone near the north gate?
```

40 bytes. `TO` is empty, so two separators are adjacent.

### 5.4 Message identifier

`ID` is `hex6`, chosen at random by the sender. It gives the message a name that
other packets can refer to.

One identifier serves every purpose. A reply refers to it, a reaction refers to
it, a receipt refers to it, and the parts of a long message share it. There is
no second identifier scheme and nothing is derived from the message content.

A sender includes `ID` on any message it expects to be answered, acknowledged,
reacted to, or split. A message with no identifier can still be read; it simply
cannot be referenced.

### 5.5 Replies

`RE` is `hex6` and names the message being replied to.

```
GRP<US>X1RD89<US>LISBOA<US>ID3f8a04RE9c4e21<US>MI'll be late, start without me
```

66 bytes. `ID3f8a04RE9c4e21` is two fields and sixteen bytes. The reply carries
its own `ID`, so it can be replied to in turn. A receiver that has not seen the
parent still displays the reply, marked as answering a message it does not hold.

### 5.6 Reactions

`LK` and `UL` are `hex6`.

```
GRP<US>X32DVA<US>LISBOA<US>LK9c4e21
GRP<US>X32DVA<US>LISBOA<US>UL9c4e21
```

26 bytes each. A reaction packet carries no `M`. It is counted once per
callsign, is idempotent, is not displayed as a message and raises no
notification.

### 5.7 Long messages

A message longer than one packet is split into numbered parts. Every part
carries the same `ID` and its own `PT`, which is a `ratio`.

```
GRP<US>X3RLY7<US>LISBOA<US>ID7a3e51PT1/3<US>MThe repeater on the hill is down.
GRP<US>X3RLY7<US>LISBOA<US>ID7a3e51PT2/3<US>MWe swapped the antenna feed this morning
GRP<US>X3RLY7<US>LISBOA<US>ID7a3e51PT3/3<US>Mand it is back up, but only just.
```

66, 73 and 66 bytes. `PT2/3` is part 2 of 3, and `ID7a3e51` says which message
it belongs to.

- Only the `M` field is split. Every other field is carried whole on the part it
  belongs to.
- **A sender splits only at a space, and never inside a word.**
- **A receiver joins the `M` values in order with exactly one space between
  them.** No part begins or ends with a space, so there is never a doubled space
  and never a missing one.
- Reassembly is keyed on `(TYPE, FROM, ID)`.
- Incomplete sets are held for 10 minutes and then discarded. A partial message
  is never displayed.
- Parts may arrive in any order. A repeated part number is ignored.
- A set is limited to 16 parts. Longer content is sent as a file (section 5.8).
- A signature covers the joined text and is carried on the last part.

### 5.8 File references

`F` is a `ref`: the SHA-256 digest of the file contents as 64 lowercase
hexadecimal characters, a dot, and 1 to 8 lowercase alphanumeric characters
giving the file type. The field is 69 bytes including its tag.

```
GRP<US>X1QZ3N<US>LISBOA<US>F9f2c4e1a7b3d5f8092a6c4e7b1d3f5a8c2e4906b8d1f3a5c7e9b2d4f6a8c0e13.jpg<US>Mthe antenna after the storm
```

116 bytes. The caption is an ordinary `M` field, so one packet may carry a file
reference, a caption and any other field, in any order.

The hash identifies the file exactly, so any station holding those bytes can
satisfy the reference and a receiver can verify what it obtained. The extension
is advisory: it indicates how to present the content and never affects
identification. A receiver that does not recognise an extension offers the file
as an opaque download.

How the bytes are transferred is outside this specification. A reference remains
valid whether the file arrives over the same radio, over the internet, or on
physical media.

### 5.9 Receipts

A sender that wants confirmation gives the message an `ID`.

```
SMS<US>X1QZ3N<US>X1RD89<US>ID40c124<US>Mmeet at the bridge at six
```

53 bytes. The recipient replies with an `ACK` packet naming the same identifier
and a state. `ST` is an `enum`.

```
ACK<US>X1RD89<US>X1QZ3N<US>ID40c124STd
```

29 bytes: a complete receipt in a packet smaller than this sentence.

| `ST` | Meaning |
|---|---|
| `d` | delivered to the device |
| `r` | read by the operator |

The `r` state is optional; a station that does not track reading sends `d` only.

Any station may act on a receipt it overhears. A station holding that message
for later delivery discards its copy on hearing the matching `ACK`.

---

## 6. Reading a compact run

```
ID40c124STd
```

| At | Longest assigned tag | Value ends at | Field |
|---|---|---|---|
| `ID40c124STd` | `ID` | `S` of `ST` | identifier `40c124` |
| `STd` | `ST`, not `S` | end of packet | receipt state `d` |

`S` is speed and `ST` is receipt state. The longest assigned tag matches, so
`STd` is never read as speed `td`. This is why a value may not be empty: `S`
followed immediately by `T` would be indistinguishable from the tag `ST`.

---

## 7. Signing and privacy

### 7.1 Signatures

`G` is the last field in the packet. It covers `FROM`, then `0x1F`, then every
field that precedes it exactly as transmitted, separators included. The author,
the content, and the order in which the sender wrote the fields are all bound.

```
GRP<US>X1QZ3N<US>LISBOA<US>ID9c4e21<US>Mnet starts in ten minutes<US>G<60 characters>
```

115 bytes.

| State | Condition |
|---|---|
| verified | signature present, valid, signer key known |
| forged | signature present and invalid |
| unverified | signature present, signer key unknown |
| unsigned | no signature |

Reactions and identity announcements are not signed.

### 7.2 Encryption

`X` carries the sealed body. When present it replaces `M`.

```
SMS<US>X1QZ3N<US>X1RD89<US>ID5b91e0<US>XpQ4m9xT2vB8kR<US>G<60 characters>
```

103 bytes. The header and `ID` remain in cleartext, so an intermediate station
can route the packet, identify the recipient and release a carried copy on the
matching receipt, without reading the content.

A later cipher suite takes a new tag rather than changing this one.

### 7.3 Permitted use by band

| Spectrum | Signing | Encryption |
|---|---|---|
| Licence-free (Bluetooth and LoRa ISM, WiFi), and the internet | permitted | permitted, and is the default for direct messages |
| Amateur bands, under an amateur licence | permitted | not permitted |

Amateur regulations prohibit obscuring the meaning of a transmission. A licensed
operator using OPRS on amateur bands is bound by that rule as on any other mode
and must not transmit `X` there.

A signature is not encryption. It leaves the text in cleartext and establishes
only authorship, so signing is permitted on amateur bands.

An implementation able to reach amateur infrastructure must refuse to transmit a
sealed body onto it.

---

## 8. Observations

Position, movement, weather and telemetry share one packet type and one
vocabulary. There is no separate weather packet and no separate telemetry
packet. A weather station is a station that reports temperature in addition to
position.

### 8.1 Position

`P` is a `coord`: decimal degrees, WGS84, latitude then longitude, negative for
south and west. No hemisphere letters, no degrees-minutes-seconds, no
compression.

```
P38.7223,-9.1393
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
uncertainty separately in `E`.

Absence of `P` means the position is unknown. It does not mean zero. `0,0` is a
valid coordinate in the Gulf of Guinea.

### 8.2 Units

Every unit is given in the tag table in section 4.5 and none is transmitted.
Conversion to SI is performed by the sender: a station holding Fahrenheit
converts before transmitting, and no receiver infers a unit from anything.

`RS` and `SN` describe the link on which a packet arrived and are recorded by
the receiver. A station does not transmit its own received signal strength.

### 8.3 Station type

`Y` is an `enum`: `node`, `wx`, `car`, `boat`, `foot`, `balloon`, `sos`. A
receiver that does not recognise a value displays a default marker and the value
as text.

`Y` values are lowercase because a compact value may not contain an uppercase
letter. This is the constraint the encoding imposes, and it is the only one.

### 8.4 A note on an observation

An observation carries a note in `M`, the same tag a message uses. A note on an
observation and the content of a message are one field, not two.

### 8.5 Time

An observation that may be relayed or held for later delivery must include a
time field. A held packet can be delivered days later, and an undated position
is plotted as current.

| Station capability | Tag | Example | Meaning |
|---|---|---|---|
| keeps wall-clock time | `TS` | `TS1780000000` | Unix seconds, UTC |
| no clock, no storage | `AG` | `AG45` | seconds between observation and transmission |
| no clock, persistent storage | `EP` | `EP7.4210` | boot epoch 7, 4210 seconds into that epoch |

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
`TS` only.

---

## 9. Examples

Byte counts are for the complete packet including every separator.

### 9.1 Position

Minimum useful observation, coarse position, station with no clock:

```
OBS<US>X1QZ3N<US><US>P38.72,-9.14AG30
```

28 bytes.

Normal fix with a clock:

```
OBS<US>X1QZ3N<US><US>P38.7223,-9.1393TS1780000000
```

40 bytes.

High-precision fix with stated uncertainty. Five decimals of arithmetic, eight
metres of measured accuracy:

```
OBS<US>X1QZ3N<US><US>P38.72231,-9.13934E8TS1780000000
```

44 bytes.

### 9.2 Movement

Person on foot:

```
OBS<US>X1QZ3N<US><US>P38.7223,-9.1393A87YfootS1.4C212TS1780000000
```

56 bytes.

Vehicle, with a note:

```
OBS<US>X1CAR7<US><US>P38.7231,-9.1402A87S13.4C212E8YcarTS1780000060<US>Mheading south on the N8
```

83 bytes. The note contains an uppercase `N`, which is why `M` is delimited.

Balloon ascending at 4.8 m/s through 11240 m:

```
OBS<US>X3BAL1<US><US>P38.9012,-9.0021A11240VS4.8S9.2C47YballoonTS1780001800
```

66 bytes.

Vessel under way, no altitude:

```
OBS<US>X1BOA3<US><US>P38.6902,-9.4012S3.1C275YboatTS1780002400
```

53 bytes.

### 9.3 Weather

Station with three sensors:

```
OBS<US>X3WX01<US><US>P38.7223,-9.1393T14.2H78B1013.2YwxTS1780000000
```

58 bytes.

Full station reporting every defined weather field plus battery. Thirteen
fields:

```
OBS<US>X3WX01<US><US>P38.7223,-9.1393T14.2H78B1013.2W3.4WD210WG7.1RH0.4RD12.6SR640BT96YwxTS1780000000
```

92 bytes, leaving 158 for fields not yet defined. Of the 92, 20 are the tags.

Indoor sensor with no position and no clock. Position is omitted rather than
sent as zero:

```
OBS<US>X3WX01<US><US>T14.2H78AG60
```

24 bytes.

### 9.4 Telemetry

Unattended node reporting power state:

```
OBS<US>X3RLY7<US><US>P38.7810,-9.2043A210BT64VL12.9YnodeTS1780003000
```

59 bytes.

### 9.5 Emergency

```
OBS<US>X1QZ3N<US><US>P38.7223,-9.1393E6YsosTS1780000120<US>Minjured, need help
```

66 bytes.

### 9.6 Position, weather and telemetry in one packet

```
OBS<US>X3RLY7<US><US>P38.7810,-9.2043A210T11.8H88B1008.4W6.1WD295BT64VL12.9YnodeTS1780003000
```

83 bytes. A receiver interested only in position reads `P` and skips the rest.

### 9.7 Identity announcement

`ID` binds a callsign to the public key that signatures are verified against.

```
ID<US>X1QZ3N<US><US>Knpub1qz3n7fu9j9uenmyva7ha6x9eqwymytv2847ccv4vxdmn45y50q7h7k5f<US>TS1780000000
```

86 bytes. A receiver stores the binding and uses it to verify signed packets
from that callsign. `K` is delimited because a bech32 string is not restricted
to lowercase.

An `ID` packet is not signed, because a signature on it would have to be
verified with the key the packet is carrying. Trust in the binding comes from
repetition, from consistency with the callsign derivation in section 3, and from
the signed packets that follow it.

### 9.8 Decoding a packet

```
OBS<US>X3RLY7<US><US>P38.7810,-9.2043A210T11.8H88B1008.4YnodeTS1780003000
```

64 bytes.

| Field | Tag | Value | Reading |
|---|---|---|---|
| TYPE | | `OBS` | observation; a station filtering for messages discards it here |
| FROM | | `X3RLY7` | unattended station |
| TO | | empty | not addressed to anyone in particular |
| position | `P` | `38.7810,-9.2043` | 38.7810 N, 9.2043 W, four decimals, so about 11 m |
| altitude | `A` | `210` | 210 m above mean sea level |
| temperature | `T` | `11.8` | 11.8 degrees Celsius |
| humidity | `H` | `88` | 88 percent relative humidity |
| pressure | `B` | `1008.4` | 1008.4 hPa at station level |
| station type | `Y` | `node` | unattended node |
| time | `TS` | `1780003000` | Unix seconds, UTC |

Each value ends where the next uppercase letter begins. `A210T11.8` is altitude
210 and temperature 11.8: nine bytes for two readings and their names.

---

## 10. Worked exchanges

Complete sequences in transmission order.

### 10.1 Group conversation with a reply and a reaction

```
1  GRP<US>X1QZ3N<US>LISBOA<US>ID9c4e21<US>Mnet starts in ten minutes
2  GRP<US>X1RD89<US>LISBOA<US>ID3f8a04RE9c4e21<US>MI'll be late, start without me
3  GRP<US>X32DVA<US>LISBOA<US>LK9c4e21
```

53, 66 and 26 bytes. Packet 1 names itself `9c4e21`. Packet 2 replies to that
identifier and names itself `3f8a04`, so it can be replied to in turn. Packet 3
is a reaction to packet 1, counted once for `X32DVA` and never displayed as a
message.

### 10.2 Direct message with delivery and read receipts

```
1  SMS<US>X1QZ3N<US>X1RD89<US>ID40c124<US>Mmeet at the bridge at six
2  ACK<US>X1RD89<US>X1QZ3N<US>ID40c124STd
3  ACK<US>X1RD89<US>X1QZ3N<US>ID40c124STr
```

53, 29 and 29 bytes. Packet 2 is sent when the message reaches the device,
packet 3 when the operator reads it. A station not tracking reading sends packet
2 only.

### 10.3 Private message on licence-free spectrum

```
SMS<US>X1QZ3N<US>X1RD89<US>ID5b91e0<US>XpQ4m9xT2vB8kR<US>G<60 characters>
```

103 bytes. The header and `ID` are readable, so intermediate stations can route
the packet and release a carried copy when the receipt arrives. Only the body is
sealed. This packet must not be transmitted on amateur bands (section 7.3).

### 10.4 Delivery through a station that meets neither party

```
1  SMS<US>X1QZ3N<US>X1RD89<US>ID40c124<US>Mmeet at the bridge at six
   X1RD89 is out of range. X32DVA receives the packet and retains it.

2  SMS<US>X32DVA<US>X1RD89<US>ID40c124<US>Mmeet at the bridge at six
   Hours later, X32DVA encounters X1RD89 and retransmits.

3  ACK<US>X1RD89<US>X1QZ3N<US>ID40c124STd
   X32DVA receives the receipt and discards its copy.
```

53, 53 and 29 bytes. The identifier is unchanged throughout, so the delivered
message is recognised as the same message and duplicates are suppressed. Any
other station that retained packet 1 and receives packet 3 also discards its
copy.

### 10.5 A long group message

```
1  GRP<US>X3RLY7<US>LISBOA<US>ID7a3e51PT1/3<US>MThe repeater on the hill is down.
2  GRP<US>X3RLY7<US>LISBOA<US>ID7a3e51PT2/3<US>MWe swapped the antenna feed this morning
3  GRP<US>X3RLY7<US>LISBOA<US>ID7a3e51PT3/3<US>Mand it is back up, but only just.
```

66, 73 and 66 bytes. Reassembly is keyed on `(GRP, X3RLY7, 7a3e51)`. The three
`M` values joined with one space between them read:

```
The repeater on the hill is down. We swapped the antenna feed this morning and it is back up, but only just.
```

If part 2 never arrives, the set is discarded after 10 minutes and nothing is
displayed.

### 10.6 Clockless weather station anchored by a neighbour

```
1  OBS<US>X3WX01<US><US>P38.7223,-9.1393T14.1H80EP7.3600
2  OBS<US>X3WX01<US><US>P38.7223,-9.1393T14.2H78EP7.4210
   A receiver holding a clock records: epoch 7 heard at 1780004800.

3  OBS<US>X3WX01<US><US>P38.7223,-9.1393EP7.9930TS1780005720
   The station has obtained the time and anchors epoch 7 for all receivers.

4  OBS<US>X3WX01<US><US>P38.7223,-9.1393T15.0H74TS1780009320
```

44, 44, 48 and 48 bytes. Packets 1 and 2 are orderable without any clock, since
the higher uptime is later. A receiver holding a clock dates them from its own
observation of epoch 7. Packet 3 makes that anchor explicit.

### 10.7 A hiker and a weather station over one hour

```
1  OBS<US>X3WX01<US><US>P38.7223,-9.1393T14.2H78B1013.2YwxTS1780000000
2  OBS<US>X1QZ3N<US><US>P38.7223,-9.1393A87YfootS1.4C212TS1780000000
3  ALL<US>X1QZ3N<US><US>Manyone near the north gate?
4  SMS<US>X3RLY7<US>X1QZ3N<US>ID7c31a9<US>Mgate is closed, use the east path
5  ACK<US>X1QZ3N<US>X3RLY7<US>ID7c31a9STd
6  OBS<US>X1QZ3N<US><US>P38.7301,-9.1355A142YfootS1.2C41TS1780003600
```

58, 56, 40, 61, 29 and 56 bytes. The whole exchange is 300 bytes. Packet 3
reaches whoever is in range without addressing anyone. Packet 4 is a direct
reply carrying an identifier, acknowledged in packet 5. Packets 2 and 6 show the
hiker's movement over the hour, and packet 1 gives the conditions at the same
location.

---

## 11. Adding a field, worked

A format is judged by what it costs to add something it did not foresee. Suppose
a station gains an air-quality sensor.

The implementer takes an unused tag, gives it a type and a unit, and transmits
it:

```
OBS<US>X3WX01<US><US>P38.7223,-9.1393T14.2XPM8TS1780000000
```

49 bytes. The new field costs four bytes, three of them the tag. Every existing
receiver reads `XPM`, does not recognise it, consumes the value that follows,
and continues at `TS`. Nothing is versioned, nothing is negotiated, and no other
field is affected.

The tag begins with `X` because unassigned tags belong in the private space. If
this document later assigns it, the entry is added to the table in section 4.5
with its type and unit, and a shorter tag may be chosen; nothing else on the
wire changes.

The same holds for a second free-text field, a second identifier, or a field
placed after the message text. None of them is a special case, because the
message text is not a special case.

---

## 12. Operating alongside APRS

A licensed amateur may bridge OPRS and APRS under their own callsign and
responsibility, subject to section 7.3. An `X1` or `X3` callsign is generated by
the station itself and assigned by no authority, so traffic from such a callsign
must not be originated onto amateur infrastructure. Ciphertext must never be
placed on APRS, both because APRS is a 7-bit protocol that would corrupt it and
because obscured meaning is not permitted on amateur bands.

---

## 13. Reserved

Assigned packet types: `SMS`, `GRP`, `ALL`, `OBS`, `ID`, `ACK`, `REQ`, `PNG`,
`PNR`. All other 1 to 3 letter uppercase combinations are reserved.

Assigned compact tags: `ID`, `RE`, `LK`, `UL`, `PT`, `ST`, `P`, `A`, `E`, `S`,
`C`, `VS`, `T`, `H`, `B`, `W`, `WD`, `WG`, `RH`, `RD`, `SR`, `BT`, `VL`, `RS`,
`SN`, `Y`, `TS`, `AG`, `EP`.

Assigned delimited tags: `M`, `F`, `X`, `K`, `G`.

Reserved tag prefix: `X`. Note that `X` alone is the ciphertext tag, so a
private tag is at least two characters.

A new field takes an unused tag and inherits the skip-unknown rule. A new
purpose takes an unused type. Neither redefines an existing assignment.

---

## 14. Implementation status

| Element | State |
|---|---|
| Callsigns, signatures, verification | implemented |
| Direct, group and area messages | implemented |
| Replies and reactions | implemented |
| Receipts and relay release | implemented |
| Long messages in parts | implemented |
| Encryption and the band rules | implemented |
| File references by content hash | implemented |
| Identity announcement | implemented |
| Tagged fields, compact and delimited | not implemented; the current wire has three fields and packs everything else into a space-separated trailing string |
| Explicit packet type as the first field | not implemented; the current wire infers the purpose from the destination field |
| Single `ID` for replies, reactions, receipts and parts | not implemented; the current wire derives one identifier from message content and carries a separate receipt identifier |
| `P` coordinates | implemented in a different encoding |
| `TS` time | implemented on phones and desktops |
| `AG` and `EP` time | not implemented; requires an epoch counter in non-volatile storage |
| `A`, `E`, `S`, `C`, `VS` movement | not implemented; the platform supplies these values and the location layer currently retains only latitude and longitude |
| `T`, `H` weather | one hardware sensor exists and reaches a local display only |
| `B`, `W`, `WD`, `WG`, `RH`, `RD`, `SR` weather | no source |
| `BT`, `VL` telemetry | not implemented; charging state is tracked, charge level is not |
| `RS`, `SN` telemetry | implemented on the receive paths |
