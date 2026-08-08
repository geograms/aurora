# OPRS, Open Packet Reporting System

Protocol specification.

OPRS carries position, movement, weather, telemetry and messages between
stations over licence-free spectrum and the internet. It occupies the same role
as APRS and requires no amateur licence.

Status: DRAFT 2. Section 14 states which parts are implemented.

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

OPRS defines the framing so that adding a field is always possible and never
affects an existing one.

---

## 2. Design rules

1. Every packet declares its type in the first field, so a receiver can sort,
   filter or discard without parsing the remainder.
2. Every field after the header is a self-delimiting `key:value`. There are no
   positional fields, no prefix characters, and no field whose meaning depends
   on where it appears.
3. Every key has a declared value type (section 4.5). A parser knows what shape
   a value has before reading it, and a key's type never varies with the packet
   it appears in.
4. Any field may appear anywhere, and any field may contain spaces. Adding a
   field never changes how an existing field is read.
5. One packet type carries every kind of observation. New data means a new key,
   never a new packet type.
6. Nothing is defined out of band. No receiver requires prior state to read a
   packet.
7. All values are SI. Units are fixed here and never transmitted.
8. All fields are optional. A station sends what it has.
9. An unknown key is skipped and an unknown packet type is ignored, in both
   cases without error.
10. Values are text. Compression is not used.

Rules 2 to 4 are the ones that matter in ten years. A format whose last field is
"whatever remains" can never gain a field after it, and can carry only one value
containing a space. OPRS has neither restriction.

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
TYPE<US>FROM<US>TO<US>field<US>field<US>...
```

`<US>` is the ASCII unit separator, `0x1F`, a single byte. There are no spaces
around it. Every example in this document is written exactly as it is
transmitted.

Three positional header fields, then any number of `key:value` fields. Parsing
is one split on `0x1F`, then one split on the first `:` of each field after the
third. There is no escaping and no nesting.

The maximum packet is **250 bytes on every transport**. This fits one LoRa
packet, one BLE5 extended advertisement, and the store-and-forward buffer of the
smallest station. Content that does not fit is split into parts (section 5.7),
never compressed.

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

```
key:value
```

- A key is 1 to 6 characters, lowercase letters and digits, beginning with a
  letter.
- A field is terminated by `0x1F` or by the end of the packet. Nothing else
  terminates it.
- A value may contain any byte except `0x1F`, including spaces and colons. Only
  the first `:` separates key from value.
- Order is not significant, except that `sig:` is last (section 7.1).
- A key appears at most once per packet.
- An unknown key is skipped.

There is no other syntax. Every reference to another message, every part number,
every measurement, every line of human text and every signature has the same
shape and the same delimiter.

Two consequences are worth stating, because the earlier framing had neither. Any
number of fields may contain spaces, so a caption and a note can coexist in one
packet. And a value may contain a colon, so a URL inside a message needs no
escaping.

### 4.3 Message text

Human text is the `txt:` field. It is an ordinary field in an ordinary position
and carries no special parsing rule.

```
SMS<US>X1QZ3N<US>X1RD89<US>txt:meet at the bridge at six
```

47 bytes. `txt:` costs four bytes on a message packet. That is the price of
being able to place a field after the text, which a trailing free-text field can
never allow.

### 4.4 Extending the format

A new field takes an unused key, declares its type, and is placed anywhere.
Receivers that do not know the key skip it. No existing field moves, no packet
type is added, and no version is negotiated. Section 11 works an example.

Keys beginning with `x` are reserved for private and experimental use and are
never assigned by this document.

### 4.5 Value types

Every assigned key has one of these types. The type is fixed by this document
and is never transmitted.

| Type | Form | Example |
|---|---|---|
| `int` | digits, optional leading `-` | `210` |
| `dec` | digits, optional leading `-`, optional single `.` and fraction | `-9.1393` |
| `text` | any bytes except `0x1F` | `heading south on the N8` |
| `enum` | one value from a list given with the key | `foot` |
| `hex6` | exactly 6 lowercase hexadecimal characters | `9c4e21` |
| `time` | `int`, Unix seconds, UTC | `1780000000` |
| `coord` | two `dec` separated by a comma, latitude then longitude | `38.7223,-9.1393` |
| `ratio` | two `int` separated by `/`, position then total | `2/3` |
| `ref` | 64 lowercase hexadecimal characters, a dot, 1 to 8 lowercase alphanumerics | `9f2c...0e13.jpg` |
| `b64` | base64url, no padding | `pQ4m9xT2vB8kR` |
| `bech32` | a bech32 string | `npub1qz3n7...` |
| `sig` | 60 characters, base85 | |
| `epoch` | two `int` separated by a dot, boot counter then seconds | `7.4210` |

A value that does not match its declared type is treated as an unknown key and
skipped. A packet is never rejected as a whole because one field is malformed.

---

## 5. Messages

### 5.1 Direct

```
SMS<US>X1QZ3N<US>X1RD89<US>txt:meet at the bridge at six
```

47 bytes.

### 5.2 Group

```
GRP<US>X1QZ3N<US>LISBOA<US>id:9c4e21<US>txt:net starts in ten minutes
```

57 bytes.

### 5.3 Area broadcast

`ALL` addresses any station in range.

```
ALL<US>X1QZ3N<US><US>txt:anyone near the north gate?
```

43 bytes. `TO` is empty, so two separators are adjacent.

### 5.4 Message identifier

`id:` is `hex6`, chosen at random by the sender. It gives the message a name
that other packets can refer to.

One identifier serves every purpose. A reply refers to it, a reaction refers to
it, a receipt refers to it, and the parts of a long message share it. There is
no second identifier scheme and nothing is derived from the message content.

A sender includes `id:` on any message it expects to be answered, acknowledged,
reacted to, or split. A message with no identifier can still be read; it simply
cannot be referenced.

### 5.5 Replies

`re:` is `hex6` and names the message being replied to.

```
GRP<US>X1RD89<US>LISBOA<US>id:3f8a04<US>re:9c4e21<US>txt:I'll be late, start without me
```

72 bytes. The reply carries its own `id:`, so it can be replied to in turn. A
receiver that has not seen the parent still displays the reply, marked as
answering a message it does not hold.

### 5.6 Reactions

`like:` and `unlike:` are `hex6`.

```
GRP<US>X32DVA<US>LISBOA<US>like:9c4e21
GRP<US>X32DVA<US>LISBOA<US>unlike:9c4e21
```

29 and 31 bytes. A reaction packet carries no `txt:`. It is counted once per
callsign, is idempotent, is not displayed as a message and raises no
notification.

### 5.7 Long messages

A message longer than one packet is split into numbered parts. Every part
carries the same `id:` and its own `part:`, which is a `ratio`.

```
GRP<US>X3RLY7<US>LISBOA<US>id:7a3e51<US>part:1/3<US>txt:The repeater on the hill is down.
GRP<US>X3RLY7<US>LISBOA<US>id:7a3e51<US>part:2/3<US>txt:We swapped the antenna feed this morning
GRP<US>X3RLY7<US>LISBOA<US>id:7a3e51<US>part:3/3<US>txt:and it is back up, but only just.
```

74, 81 and 74 bytes. `part:2/3` is part 2 of 3, and `id:7a3e51` says which
message it belongs to.

- Only the `txt:` field is split. Every other field is carried whole on the part
  it belongs to.
- **A sender splits only at a space, and never inside a word.**
- **A receiver joins the `txt:` values in order with exactly one space between
  them.** No part begins or ends with a space, so there is never a doubled space
  and never a missing one.
- Reassembly is keyed on `(TYPE, FROM, id)`.
- Incomplete sets are held for 10 minutes and then discarded. A partial message
  is never displayed.
- Parts may arrive in any order. A repeated part number is ignored.
- A set is limited to 16 parts. Longer content is sent as a file (section 5.8).
- A signature covers the joined text and is carried on the last part.

### 5.8 File references

`file:` is a `ref`: the SHA-256 digest of the file contents as 64 lowercase
hexadecimal characters, a dot, and 1 to 8 lowercase alphanumeric characters
giving the file type. The field is 73 bytes.

```
GRP<US>X1QZ3N<US>LISBOA<US>file:9f2c4e1a7b3d5f8092a6c4e7b1d3f5a8c2e4906b8d1f3a5c7e9b2d4f6a8c0e13.jpg<US>txt:the antenna after the storm
```

123 bytes. The caption is an ordinary `txt:` field, so one packet may carry a
file reference, a caption and any other field, in any order.

The hash identifies the file exactly, so any station holding those bytes can
satisfy the reference and a receiver can verify what it obtained. The extension
is advisory: it indicates how to present the content and never affects
identification. A receiver that does not recognise an extension offers the file
as an opaque download.

How the bytes are transferred is outside this specification. A reference remains
valid whether the file arrives over the same radio, over the internet, or on
physical media.

### 5.9 Receipts

A sender that wants confirmation gives the message an `id:`.

```
SMS<US>X1QZ3N<US>X1RD89<US>id:40c124<US>txt:meet at the bridge at six
```

57 bytes. The recipient replies with an `ACK` packet naming the same identifier
and a state. `st:` is an `enum`.

```
ACK<US>X1RD89<US>X1QZ3N<US>id:40c124<US>st:d
```

32 bytes.

| `st:` | Meaning |
|---|---|
| `d` | delivered to the device |
| `r` | read by the operator |

The `r` state is optional; a station that does not track reading sends `d` only.

Any station may act on a receipt it overhears. A station holding that message
for later delivery discards its copy on hearing the matching `ACK`.

---

## 6. Message keys

| Key | Type | Meaning |
|---|---|---|
| `id` | `hex6` | identifier of this message |
| `re` | `hex6` | this message replies to that identifier |
| `like` | `hex6` | reaction to that identifier |
| `unlike` | `hex6` | withdrawal of a reaction |
| `part` | `ratio` | this packet is part i of n |
| `txt` | `text` | human-readable content |
| `file` | `ref` | content hash and type of a referenced file |
| `enc1` | `b64` | sealed body, cipher suite 1 |
| `st` | `enum`: `d`, `r` | receipt state |
| `sig` | `sig` | signature over the preceding fields |
| `key` | `bech32` | public key, in `ID` only |
| `ts` | `time` | time of the packet |

---

## 7. Signing and privacy

### 7.1 Signatures

`sig:` is the last field in the packet. It covers `FROM`, then `0x1F`, then
every field that precedes it exactly as transmitted, separators included. The
author, the content, and the order in which the sender wrote the fields are all
bound.

```
GRP<US>X1QZ3N<US>LISBOA<US>id:9c4e21<US>txt:net starts in ten minutes<US>sig:<60 characters>
```

122 bytes.

| State | Condition |
|---|---|
| verified | signature present, valid, signer key known |
| forged | signature present and invalid |
| unverified | signature present, signer key unknown |
| unsigned | no signature |

Reactions and identity announcements are not signed.

### 7.2 Encryption

`enc1:` carries the sealed body. When present it replaces `txt:`.

```
SMS<US>X1QZ3N<US>X1RD89<US>id:5b91e0<US>enc1:pQ4m9xT2vB8kR<US>sig:<60 characters>
```

111 bytes. The header and `id:` remain in cleartext, so an intermediate station
can route the packet, identify the recipient and release a carried copy on the
matching receipt, without reading the content.

The `1` names the cipher suite, so a later suite is a new key rather than a
change to this one.

### 7.3 Permitted use by band

| Spectrum | Signing | Encryption |
|---|---|---|
| Licence-free (Bluetooth and LoRa ISM, WiFi), and the internet | permitted | permitted, and is the default for direct messages |
| Amateur bands, under an amateur licence | permitted | not permitted |

Amateur regulations prohibit obscuring the meaning of a transmission. A licensed
operator using OPRS on amateur bands is bound by that rule as on any other mode
and must not transmit `enc1:` there.

A signature is not encryption. It leaves the text in cleartext and establishes
only authorship, so signing is permitted on amateur bands.

An implementation able to reach amateur infrastructure must refuse to transmit a
sealed body onto it.

---

## 8. Observations

Position, movement, weather and telemetry share one packet type and one
vocabulary.

```
OBS<US>FROM<US><US>field<US>field<US>...
```

There is no separate weather packet and no separate telemetry packet. A weather
station is a station that reports temperature in addition to position.

### 8.1 Position

`pos:` is a `coord`: decimal degrees, WGS84, latitude then longitude, negative
for south and west. No hemisphere letters, no degrees-minutes-seconds, no
compression.

```
pos:38.7223,-9.1393
```

19 bytes.

The number of decimal places states the precision claimed:

| Decimals | Resolution | Appropriate for |
|---|---|---|
| 2 | 1.1 km | a town |
| 3 | 110 m | a district |
| 4 | 11 m | a normal satellite fix |
| 5 | 1.1 m | a good fix or survey equipment |
| 6 | 0.11 m | rarely justified |

A station sends only the digits its fix supports, and reports measured
uncertainty separately in `acc:`.

Absence of `pos:` means the position is unknown. It does not mean zero. `0,0` is
a valid coordinate in the Gulf of Guinea.

### 8.2 Movement

| Key | Type | Meaning | Unit |
|---|---|---|---|
| `alt` | `dec` | altitude above mean sea level | metres |
| `acc` | `dec` | horizontal accuracy radius | metres |
| `spd` | `dec` | speed over ground | metres per second |
| `crs` | `int` | course over ground, 0 to 359 | degrees true |
| `vsp` | `dec` | vertical speed, signed | metres per second |

### 8.3 Weather

| Key | Type | Meaning | Unit |
|---|---|---|---|
| `tmp` | `dec` | air temperature | degrees Celsius |
| `hum` | `int` | relative humidity | percent |
| `bar` | `dec` | barometric pressure, station level | hPa |
| `wnd` | `dec` | wind speed, sustained | metres per second |
| `wdi` | `int` | wind direction, the direction it blows from | degrees true |
| `wgu` | `dec` | wind gust, peak | metres per second |
| `rn1` | `dec` | rainfall, previous hour | mm |
| `rn24` | `dec` | rainfall, previous 24 hours | mm |
| `sol` | `int` | solar irradiance | watts per square metre |

Conversion to SI is performed by the sender. No unit is transmitted and no
receiver infers one. A station holding Fahrenheit converts before transmitting.

### 8.4 Telemetry

| Key | Type | Meaning | Unit |
|---|---|---|---|
| `bat` | `int` | battery charge | percent |
| `vlt` | `dec` | supply voltage | volts |
| `rssi` | `int` | received signal strength | dBm |
| `snr` | `dec` | signal-to-noise ratio | dB |

`rssi` and `snr` describe the link on which a packet arrived and are recorded by
the receiver. A station does not transmit its own received signal strength.

### 8.5 Time

An observation that may be relayed or held for later delivery must include a
time field. A held packet can be delivered days later, and an undated position
is plotted as current.

| Station capability | Key | Type | Example | Meaning |
|---|---|---|---|---|
| keeps wall-clock time | `ts` | `time` | `ts:1780000000` | Unix seconds, UTC |
| no clock, no storage | `age` | `int` | `age:45` | seconds between observation and transmission |
| no clock, persistent storage | `ep` | `epoch` | `ep:7.4210` | boot epoch 7, 4210 seconds into that epoch |

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
`ts` only.

### 8.6 Station type and note

| Key | Type | Meaning |
|---|---|---|
| `sym` | `enum`: `node`, `wx`, `car`, `boat`, `foot`, `balloon`, `sos` | station type |
| `txt` | `text` | free note |

`txt:` is the same key as in a message, with the same type and the same rules. A
note on an observation and the content of a message are one field, not two.

A receiver that does not recognise a `sym` value displays a default marker and
the value as text.

---

## 9. Examples

Byte counts are for the complete packet including every separator.

### 9.1 Position

Minimum useful observation, coarse position, station with no clock:

```
OBS<US>X1QZ3N<US><US>pos:38.72,-9.14<US>age:30
```

34 bytes.

Normal fix with a clock:

```
OBS<US>X1QZ3N<US><US>pos:38.7223,-9.1393<US>ts:1780000000
```

45 bytes.

High-precision fix with stated uncertainty. Five decimals of arithmetic, eight
metres of measured accuracy:

```
OBS<US>X1QZ3N<US><US>pos:38.72231,-9.13934<US>acc:8<US>ts:1780000000
```

53 bytes.

### 9.2 Movement

Person on foot:

```
OBS<US>X1QZ3N<US><US>pos:38.7223,-9.1393<US>alt:87<US>sym:foot<US>spd:1.4<US>crs:212<US>ts:1780000000
```

77 bytes.

Vehicle, with a note:

```
OBS<US>X1CAR7<US><US>pos:38.7231,-9.1402<US>alt:87<US>spd:13.4<US>crs:212<US>acc:8<US>sym:car<US>ts:1780000060<US>txt:heading south on the N8
```

111 bytes.

Balloon ascending at 4.8 m/s through 11240 m:

```
OBS<US>X3BAL1<US><US>pos:38.9012,-9.0021<US>alt:11240<US>vsp:4.8<US>spd:9.2<US>crs:47<US>sym:balloon<US>ts:1780001800
```

90 bytes.

Vessel under way, no altitude:

```
OBS<US>X1BOA3<US><US>pos:38.6902,-9.4012<US>spd:3.1<US>crs:275<US>sym:boat<US>ts:1780002400
```

70 bytes.

### 9.3 Weather

Station with three sensors:

```
OBS<US>X3WX01<US><US>pos:38.7223,-9.1393<US>tmp:14.2<US>hum:78<US>bar:1013.2<US>sym:wx<US>ts:1780000000
```

79 bytes.

Full station reporting every defined weather field plus battery:

```
OBS<US>X3WX01<US><US>pos:38.7223,-9.1393<US>tmp:14.2<US>hum:78<US>bar:1013.2<US>wnd:3.4<US>wdi:210<US>wgu:7.1<US>rn1:0.4<US>rn24:12.6<US>sol:640<US>bat:96<US>sym:wx<US>ts:1780000000
```

136 bytes, leaving 114 for fields not yet defined.

Indoor sensor with no position and no clock. Position is omitted rather than
sent as zero:

```
OBS<US>X3WX01<US><US>tmp:14.2<US>hum:78<US>age:60
```

34 bytes.

### 9.4 Telemetry

Unattended node reporting power state:

```
OBS<US>X3RLY7<US><US>pos:38.7810,-9.2043<US>alt:210<US>bat:64<US>vlt:12.9<US>sym:node<US>ts:1780003000
```

78 bytes.

### 9.5 Emergency

```
OBS<US>X1QZ3N<US><US>pos:38.7223,-9.1393<US>acc:6<US>sym:sos<US>ts:1780000120<US>txt:injured, need help
```

82 bytes.

### 9.6 Position, weather and telemetry in one packet

```
OBS<US>X3RLY7<US><US>pos:38.7810,-9.2043<US>alt:210<US>tmp:11.8<US>hum:88<US>bar:1008.4<US>wnd:6.1<US>wdi:295<US>bat:64<US>vlt:12.9<US>sym:node<US>ts:1780003000
```

121 bytes. A receiver interested only in position reads `pos:` and skips the
remaining fields.

### 9.7 Identity announcement

`ID` binds a callsign to the public key that signatures are verified against.

```
ID<US>X1QZ3N<US><US>key:npub1qz3n7fu9j9uenmyva7ha6x9eqwymytv2847ccv4vxdmn45y50q7h7k5f<US>ts:1780000000
```

90 bytes. A receiver stores the binding and uses it to verify signed packets
from that callsign.

An `ID` packet is not signed, because a signature on it would have to be
verified with the key the packet is carrying. Trust in the binding comes from
repetition, from consistency with the callsign derivation in section 3, and from
the signed packets that follow it.

### 9.8 Decoding a packet

```
OBS<US>X3RLY7<US><US>pos:38.7810,-9.2043<US>alt:210<US>tmp:11.8<US>hum:88<US>bar:1008.4<US>sym:node<US>ts:1780003000
```

89 bytes.

| Field | Value | Type | Reading |
|---|---|---|---|
| TYPE | `OBS` | | observation; a station filtering for messages discards it here |
| FROM | `X3RLY7` | | unattended station |
| TO | empty | | not addressed to anyone in particular |
| `pos` | `38.7810,-9.2043` | `coord` | 38.7810 N, 9.2043 W, four decimals, so about 11 m |
| `alt` | `210` | `dec` | 210 m above mean sea level |
| `tmp` | `11.8` | `dec` | 11.8 degrees Celsius |
| `hum` | `88` | `int` | 88 percent relative humidity |
| `bar` | `1008.4` | `dec` | 1008.4 hPa at station level |
| `sym` | `node` | `enum` | unattended node |
| `ts` | `1780003000` | `time` | Unix seconds, UTC |

---

## 10. Worked exchanges

Complete sequences in transmission order.

### 10.1 Group conversation with a reply and a reaction

```
1  GRP<US>X1QZ3N<US>LISBOA<US>id:9c4e21<US>txt:net starts in ten minutes
2  GRP<US>X1RD89<US>LISBOA<US>id:3f8a04<US>re:9c4e21<US>txt:I'll be late, start without me
3  GRP<US>X32DVA<US>LISBOA<US>like:9c4e21
```

57, 72 and 29 bytes. Packet 1 names itself `9c4e21`. Packet 2 replies to that
identifier and names itself `3f8a04`, so it can be replied to in turn. Packet 3
is a reaction to packet 1, counted once for `X32DVA` and never displayed as a
message.

### 10.2 Direct message with delivery and read receipts

```
1  SMS<US>X1QZ3N<US>X1RD89<US>id:40c124<US>txt:meet at the bridge at six
2  ACK<US>X1RD89<US>X1QZ3N<US>id:40c124<US>st:d
3  ACK<US>X1RD89<US>X1QZ3N<US>id:40c124<US>st:r
```

57, 32 and 32 bytes. Packet 2 is sent when the message reaches the device,
packet 3 when the operator reads it. A station not tracking reading sends packet
2 only.

### 10.3 Private message on licence-free spectrum

```
SMS<US>X1QZ3N<US>X1RD89<US>id:5b91e0<US>enc1:pQ4m9xT2vB8kR<US>sig:<60 characters>
```

111 bytes. The header and `id:` are readable, so intermediate stations can route
the packet and release a carried copy when the receipt arrives. Only the body is
sealed. This packet must not be transmitted on amateur bands (section 7.3).

### 10.4 Delivery through a station that meets neither party

```
1  SMS<US>X1QZ3N<US>X1RD89<US>id:40c124<US>txt:meet at the bridge at six
   X1RD89 is out of range. X32DVA receives the packet and retains it.

2  SMS<US>X32DVA<US>X1RD89<US>id:40c124<US>txt:meet at the bridge at six
   Hours later, X32DVA encounters X1RD89 and retransmits.

3  ACK<US>X1RD89<US>X1QZ3N<US>id:40c124<US>st:d
   X32DVA receives the receipt and discards its copy.
```

57, 57 and 32 bytes. The identifier is unchanged throughout, so the delivered
message is recognised as the same message and duplicates are suppressed. Any
other station that retained packet 1 and receives packet 3 also discards its
copy.

### 10.5 A long group message

```
1  GRP<US>X3RLY7<US>LISBOA<US>id:7a3e51<US>part:1/3<US>txt:The repeater on the hill is down.
2  GRP<US>X3RLY7<US>LISBOA<US>id:7a3e51<US>part:2/3<US>txt:We swapped the antenna feed this morning
3  GRP<US>X3RLY7<US>LISBOA<US>id:7a3e51<US>part:3/3<US>txt:and it is back up, but only just.
```

74, 81 and 74 bytes. Reassembly is keyed on `(GRP, X3RLY7, 7a3e51)`. The three
`txt:` values joined with one space between them read:

```
The repeater on the hill is down. We swapped the antenna feed this morning and it is back up, but only just.
```

If part 2 never arrives, the set is discarded after 10 minutes and nothing is
displayed.

### 10.6 Clockless weather station anchored by a neighbour

```
1  OBS<US>X3WX01<US><US>pos:38.7223,-9.1393<US>tmp:14.1<US>hum:80<US>ep:7.3600
2  OBS<US>X3WX01<US><US>pos:38.7223,-9.1393<US>tmp:14.2<US>hum:78<US>ep:7.4210
   A receiver holding a clock records: epoch 7 heard at 1780004800.

3  OBS<US>X3WX01<US><US>pos:38.7223,-9.1393<US>ep:7.9930<US>ts:1780005720
   The station has obtained the time and anchors epoch 7 for all receivers.

4  OBS<US>X3WX01<US><US>pos:38.7223,-9.1393<US>tmp:15.0<US>hum:74<US>ts:1780009320
```

57, 57, 55 and 61 bytes. Packets 1 and 2 are orderable without any clock, since
the higher uptime is later. A receiver holding a clock dates them from its own
observation of epoch 7. Packet 3 makes that anchor explicit.

### 10.7 A hiker and a weather station over one hour

```
1  OBS<US>X3WX01<US><US>pos:38.7223,-9.1393<US>tmp:14.2<US>hum:78<US>bar:1013.2<US>sym:wx<US>ts:1780000000
2  OBS<US>X1QZ3N<US><US>pos:38.7223,-9.1393<US>alt:87<US>sym:foot<US>spd:1.4<US>crs:212<US>ts:1780000000
3  ALL<US>X1QZ3N<US><US>txt:anyone near the north gate?
4  SMS<US>X3RLY7<US>X1QZ3N<US>id:7c31a9<US>txt:gate is closed, use the east path
5  ACK<US>X1QZ3N<US>X3RLY7<US>id:7c31a9<US>st:d
6  OBS<US>X1QZ3N<US><US>pos:38.7301,-9.1355<US>alt:142<US>sym:foot<US>spd:1.2<US>crs:41<US>ts:1780003600
```

79, 77, 43, 65, 32 and 77 bytes. Packet 3 reaches whoever is in range without
addressing anyone. Packet 4 is a direct reply carrying an identifier,
acknowledged in packet 5. Packets 2 and 6 show the hiker's movement over the
hour, and packet 1 gives the conditions at the same location.

---

## 11. Adding a field, worked

A format is judged by what it costs to add something it did not foresee. Suppose
a station gains an air-quality sensor.

The implementer takes an unused key, gives it a type and a unit, and transmits
it:

```
OBS<US>X3WX01<US><US>pos:38.7223,-9.1393<US>tmp:14.2<US>xpm25:8<US>ts:1780000000
```

62 bytes. Every existing receiver skips the unknown key and reads the rest
normally. Nothing is versioned, nothing is negotiated, and no other field is
affected. The key is written `xpm25:` because unassigned keys belong in the `x`
space; if this document later assigns it, the entry `pm25` is added to the table
in section 8.3 with its type and unit.

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

Assigned keys: `id`, `re`, `like`, `unlike`, `part`, `txt`, `file`, `enc1`,
`st`, `sig`, `key`, `pos`, `alt`, `acc`, `spd`, `crs`, `vsp`, `tmp`, `hum`,
`bar`, `wnd`, `wdi`, `wgu`, `rn1`, `rn24`, `sol`, `bat`, `vlt`, `rssi`, `snr`,
`sym`, `ts`, `age`, `ep`.

Reserved key prefix: `x`.

A new field takes an unused key and inherits the skip-unknown rule. A new
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
| Uniform `0x1F`-separated typed fields | not implemented; the current wire has three fields and packs everything else into a space-separated trailing string |
| Explicit packet type as the first field | not implemented; the current wire infers the purpose from the destination field |
| Single `id:` for replies, reactions, receipts and parts | not implemented; the current wire derives one identifier from message content and carries a separate receipt identifier |
| `pos:` coordinates | implemented under a different key |
| `ts` time | implemented on phones and desktops |
| `age` and `ep` time | not implemented; requires an epoch counter in non-volatile storage |
| `alt`, `acc`, `spd`, `crs`, `vsp` movement | not implemented; the platform supplies these values and the location layer currently retains only latitude and longitude |
| `tmp`, `hum` weather | one hardware sensor exists and reaches a local display only |
| `bar`, `wnd`, `wdi`, `wgu`, `rn1`, `rn24`, `sol` weather | no source |
| `bat`, `vlt` telemetry | not implemented; charging state is tracked, charge level is not |
| `rssi`, `snr` telemetry | implemented on the receive paths |
