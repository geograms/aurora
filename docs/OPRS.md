# OPRS, Open Packet Reporting System

Protocol specification.

OPRS carries position, movement, weather, telemetry and messages between
stations over licence-free spectrum and the internet. It occupies the same role
as APRS and requires no amateur licence.

Status: DRAFT 5. Section 20 states which parts are implemented.

---

## 1. Purpose

APRS is a proven network, and an OPRS station meeting APRS infrastructure
operates under APRS rules (section 18). APRS has two prerequisites: amateur
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

1. Every packet is a list of `key:value` fields separated by one space. There
   are no positional fields, no binary framing and no escaping.
2. Every packet declares its type in the first field, so a station never has to
   guess what it is holding.
3. Every key has a declared value type (section 4.3). A reader knows the shape
   of a value before reading it, and a key's meaning never varies with the
   packet it appears in.
4. Any field may appear anywhere and any field may be absent. Adding a field
   never changes how an existing field is read.
5. One packet type carries every kind of observation. New data means a new key,
   never a new packet type.
6. Nothing is defined out of band. No receiver requires prior state to read a
   packet.
7. Every measurement carries its unit, so no value on the wire is ambiguous
   and no receiver has to assume one.
8. An unknown key is skipped and an unknown packet type is ignored, in both
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
key:value key:value key:value ...
```

- A key is 1 to 6 characters, lowercase letters and digits, beginning with a
  letter, followed by `:`.
- A value contains no space, and is never empty.
- Fields are separated by exactly one space.
- Order is free, except that `t:` is first and `m:`, when present, is last.
- An unknown key is skipped along with its value.

The maximum packet is **250 bytes on every transport**. This fits one LoRa
packet, one BLE5 extended advertisement, and the store-and-forward buffer of the
smallest station. Content that does not fit is split into parts (section 6.6),
never compressed.

`m:` is the one field whose value may contain spaces, which is why it is last:
everything after `m:` is the message. It needs no delimiter and no escaping, so
a message may contain spaces, colons, URLs and any punctuation.

### 4.1 Envelope keys

| Key | Type | Meaning |
|---|---|---|
| `t` | `enum` | packet type, always the first field |
| `f` | `call` | sending callsign |
| `d` | `dest` | destination: a callsign, a group name, or absent for a broadcast |
| `ts` | `time` | when the packet was composed, UTC |
| `tz` | `offset` | the sender's offset from UTC, for display |
| `q` | `words` | what the sender wants back (section 7) |
| `s` | `words` | what this packet answers or reports (section 7) |
| `r` | `hex6` | the identifier of another packet this one refers to |
| `n` | `ratio` | this packet is part i of n |
| `tag` | `labels` | topic labels chosen by the sender (section 4.5) |
| `add` | `enum` | something this packet adds (section 6.5) |
| `remove` | `enum` | something this packet withdraws (section 6.5) |
| `via` | `path` | callsigns that relayed this packet, oldest first (section 13) |
| `trk` | `label` | name of a track this packet belongs to (section 14) |
| `seq` | `int` | position of this point within that track |
| `kind` | `enum` | nature of an event, values per packet type (sections 15, 16) |
| `sev` | `enum` | severity of a warning (section 16) |
| `rad` | `qty` | radius of the area affected (section 16) |
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
| `trk` | a point in a named track (section 14) |
| `sos` | a call for help (section 15) |
| `warn` | a warning about a hazard (section 16) |
| `png` | a reachability test |
| `pnr` | a reply to `png` |

An unknown type is ignored. It is never an error and is never displayed as a
message. Types not listed here are reserved (section 19).

### 4.3 Value types

The type is fixed by this document and is never transmitted.

| Type | Form | Example |
|---|---|---|
| `int` | digits, optional leading `-` | `210` |
| `dec` | digits, optional leading `-`, optional single `.` and fraction | `-9.1393` |
| `enum` | one lowercase word from a list given with the key | `foot` |
| `words` | one or more lowercase words separated by commas | `ack,read` |
| `label` | lowercase letters, digits and `-`, at least one character | `field-day` |
| `labels` | one or more `label`, separated by commas | `field-day,photos` |
| `call` | uppercase letters, digits, `-` and `/` | `CT1ABC-9` |
| `dest` | a `call` or a group name | `LISBOA` |
| `path` | one or more `call`, separated by commas | `X32DVA,CT1ABC-9` |
| `hex6` | exactly 6 lowercase hexadecimal characters | `f6ff8d` |
| `time` | `YYYY-MM-DD_HH:MM:SS`, UTC | `2026-08-08_14:26:40` |
| `offset` | `+HH:MM` or `-HH:MM` | `+05:45` |
| `coord` | two `dec` separated by a comma, latitude then longitude | `38.7223,-9.1393` |
| `ratio` | two digits `1` to `9` separated by `/`, position then total | `2/3` |
| `epoch` | two `int` separated by a dot, boot counter then seconds | `7.4210` |
| `qty` | a number followed immediately by its unit (section 10.7) | `48km/h` |
| `ref` | 64 lowercase hexadecimal characters, a dot, 1 to 8 lowercase alphanumerics | `9f2c...0e13.jpg` |
| `b64` | base64url, no padding | `pQ4m9xT2vB8kR` |
| `bech32` | a bech32 string | `npub1qz3n7...` |
| `sig` | 60 characters, base85, no space | |
| `text` | any bytes, spaces included | `heading south on the N8` |

A value that does not match its declared type is skipped, as an unknown key is.
A packet is never rejected as a whole because one field is malformed.

### 4.4 Numbers

The decimal separator is a dot. A comma is never part of a number.

```
c:14.2        14.2 degrees
c:-3.5        3.5 below zero
a:11240       eleven thousand two hundred and forty metres
rh:0.4        four tenths of a millimetre
```

This is not a preference between conventions. A comma is already structural in
this format: it separates latitude from longitude in `pos:38.7223,-9.1393` and it
separates words in `q:ack,read`. A station writing `temp:14,2` for 14.2, or
`alt:11,240` for eleven thousand, produces a packet that reads as two values.

- The decimal separator is `.`, always, in every field and every locale.
- **There is no thousands separator.** `alt:11240`, never `alt:11,240`.
- A negative number carries a leading `-`. A positive number carries no sign.
- A number has at least one digit before the dot: `0.4`, never `.4`. It never
  ends in a dot.
- No exponent notation.
- **A measurement carries its unit** (section 10.6). The number rules above
  govern the digits; the unit follows them with no space: `alt:3048m`,
  `spd:48km/h`, `temp:-3.5C`.

Trailing zeros are significant, because the number of decimal places states the
precision claimed (section 10.1). `temp:14.0` says the reading was measured to a
tenth; `temp:14` says it was not.

Software that formats numbers according to the operator's locale must be
overridden before transmission. This is the most likely way for an
implementation to emit packets that every other station silently misreads,
since `14,2` is correct in most of Europe and is a different packet here.

### 4.5 Labels

`tag:` carries topic labels chosen by the sender. They let a receiver file,
filter or search a packet without reading it.

```
t:msg f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 tag:vacation m:back on Monday, radio off until then
```

98 bytes. Several labels are separated by commas:

```
t:msg f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 tag:vacation,photos m:the coast near Sagres
```

90 bytes. There is no limit on how many labels a packet carries beyond the
250-byte packet itself. It applies to any packet, not only messages:

```
t:obs f:X3WX01 pos:38.7223,-9.1393 temp:14.2C ts:2026-08-08_14:26:40 tag:field-day
```

82 bytes.

**A label contains no space.** No field value may contain a space, `m:` alone
excepted, and `tag:` is not that exception. A label is lowercase letters,
digits and `-`, at least one character, and words are joined with `-` rather
than spaces: `tag:field-day`, never `tag:field day`, which would end the field
at the space and leave `day` to be read as a malformed field and skipped.

Labels are lowercase so that a receiver matching them does not have to decide
whether `Vacation` and `vacation` are the same label. They are chosen freely
and this document assigns none: unlike `q:` and `s:`, whose words are a fixed
vocabulary because both ends must agree on what they mean, a label means
whatever the people using it agree it means.

A receiver that does not recognise a label keeps it and displays it. Labels are
never a routing decision: `d:` says where a packet goes, and a label never
changes that.

### 4.6 Time

`ts:` is written the way a person reads it, in UTC:

```
ts:2026-08-08_14:26:40
```

The `_` keeps it one field.

`ts:` is always UTC, so two packets from opposite sides of the world are ordered
by comparing them directly, with nothing to convert first.

`tz:` optionally carries the sender's offset from UTC, so a reader can show the
local time it was written at:

```
t:msg f:VK2XYZ d:X1QZ3N ts:2026-08-08_14:26:40 tz:+11:00 m:good morning from Sydney
```

83 bytes. The receiver reads 14:26 UTC, and knows it was 01:26 the next morning
where the sender was standing. Offsets of 30 and 45 minutes exist, so the
minutes are written out rather than assumed to be zero.

`tz:` is presentation only. It never changes `ts:`, never takes part in an
identifier, and a station that ignores it loses nothing but the courtesy.

A packet that may be relayed or carried **must** have a time field. A carried
packet can be delivered days later, and an undated position is plotted as
current. Two alternatives exist for stations without a clock (section 10.5).

### 4.7 Extending the format

A new field takes an unused key, declares its type, and is placed anywhere.
Receivers that do not know the key skip it and its value. No existing field
moves, no packet type is added, and no version is negotiated.

Keys beginning with `z` are reserved for private and experimental use and are
never assigned by this document.

```
t:obs f:X3WX01 pos:38.7223,-9.1393 temp:14.2C zpm:8 ts:2026-08-08_14:26:40
```

74 bytes. Every existing receiver reads `temp:14.2` and `ts:`, skips `zpm:8`, and
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
- **A set is limited to 9 parts**, so `n:` is always three characters and the
  last part is at most `n:9/9`. A message that does not fit in nine parts is
  sent as a file (section 6.7) rather than split further: at that size the
  content is a document, and a receiver that loses one of twenty parts has
  waited a long time to be told it has nothing.

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
t:obs f:X3RLY7 d:X1QZ3N pos:38.7810,-9.2043 batt:64% ts:2026-08-08_14:26:40 s:pos,bat
```

56 and 85 bytes. A station holding only part of what was asked says so, rather
than failing:

```
t:obs f:X3RLY7 d:X1QZ3N pos:38.7810,-9.2043 ts:2026-08-08_14:26:40 s:pos
```

72 bytes: position sent, battery not available, no error packet needed.

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
beginning with `z` is private, as a key beginning with `z` is.

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

A later cipher suite takes a new key rather than changing this one.

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

`pos:` is decimal degrees, WGS84, latitude then longitude, negative for south and
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
uncertainty separately in `acc:`.

Absence of `pos:` means the position is unknown. It does not mean zero. `0,0` is a
valid coordinate in the Gulf of Guinea.

### 10.2 Movement

| Key | Type | Meaning | Quantity |
|---|---|---|---|
| `pos` | `coord` | position | degrees |
| `alt` | `qty` | altitude above mean sea level | distance |
| `acc` | `qty` | horizontal accuracy radius | distance |
| `spd` | `qty` | speed over ground | speed |
| `dir` | `qty` | course over ground, the direction it is travelling | angle |
| `o` | `qty` | heading, the direction it is pointing | angle |
| `climb` | `qty` | vertical speed, signed | speed |

`dir:` and `o:` are different measurements and a station may report both. `dir:`
is where it is going, which is what a satellite fix gives. `o:` is where it is
pointing, which is what a compass gives. They agree on a road and disagree
wherever wind or current pushes a vehicle sideways:

```
t:obs f:X1BOA3 pos:38.6902,-9.4012 spd:6kt dir:275deg o:262degm type:boat ts:2026-08-08_14:26:40
```

96 bytes: making 6 knots over the ground towards 275 true, with the bow held
at 262 magnetic to hold that track against the current.

A station with only a satellite fix sends `dir:` alone, which is the common
case. A station that is stationary has no course and may still have a heading:

```
t:obs f:X1CAR7 pos:38.7231,-9.1402 o:212degm type:car ts:2026-08-08_14:26:40
```

76 bytes.

### 10.3 Weather

| Key | Type | Meaning | Quantity |
|---|---|---|---|
| `temp` | `qty` | air temperature | temperature |
| `hum` | `qty` | relative humidity | proportion |
| `press` | `qty` | barometric pressure, station level | pressure |
| `wind` | `qty` | wind speed, sustained | speed |
| `wdir` | `qty` | wind direction, the direction it blows from | angle |
| `gust` | `qty` | wind gust, peak | speed |
| `rain1` | `qty` | rainfall, previous hour | rainfall |
| `rain24` | `qty` | rainfall, previous 24 hours | rainfall |
| `solar` | `qty` | solar irradiance | irradiance |

Conversion to SI is performed by the sender. No unit is transmitted and no
receiver infers one. A station holding Fahrenheit converts before transmitting.

### 10.4 Telemetry and station type

| Key | Type | Meaning | Quantity |
|---|---|---|---|
| `batt` | `qty` | battery charge | proportion |
| `volt` | `qty` | supply voltage | voltage |
| `rssi` | `qty` | received signal strength | signal power |
| `snr` | `qty` | signal-to-noise ratio | signal ratio |
| `type` | `enum` | what the station is or is riding on, from the set in section 14.2 | |

`rs` and `sn` describe the link a packet arrived on and are reported by the
receiver, in a `pnr` reply. A station does not transmit its own received signal
strength.

An observation carries a note in `m:`, the same key a message uses.

### 10.5 Stations without a clock

| Station capability | Key | Example | Meaning |
|---|---|---|---|
| keeps wall-clock time | `ts` | `ts:2026-08-08_14:26:40` | UTC |
| no clock, no storage | `age` | `age:30` | seconds between observation and transmission |
| no clock, persistent storage | `epoch` | `epoch:7.4210` | boot epoch 7, 4210 seconds into that epoch |

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

### 10.6 Units of measure

**Every measurement carries its unit, immediately after the number and with no
space between them.**

```
alt:3048m    spd:48km/h    temp:14.2C    press:1013.2hPa    rain1:0.4mm
```

A person reads the value and the unit together, with no table to consult and
nothing to remember about which key means what.

The unit is **required**, not optional. A bare number is not a measurement, it
is a malformed value, and it is skipped like any other. This is the rule that
separates OPRS from APRS: APRS units are implicit and positional, so a receiver
that assumes the wrong one is never told it guessed. Here there is nothing to
guess.

A sender transmits in the unit it works in. A boat reports knots, an aircraft
reports feet and knots, a European car reports km/h, an American weather station
reports Fahrenheit and inches of mercury:

```
t:obs f:X1BOA3 pos:38.6902,-9.4012 spd:6kt dir:275deg type:boat ts:2026-08-08_14:26:40
t:trk f:CT1ABC-9 seq:3 pos:38.9012,-9.0021 alt:10000ft spd:250kt dir:47deg type:airplane ts:2026-08-08_14:26:40
t:obs f:X3WX01 pos:38.7223,-9.1393 temp:57.6F hum:78% press:29.92inHg wind:7.6mph type:wx ts:2026-08-08_14:26:40
```

86, 111 and 112 bytes.

### 10.7 The permitted units

| Quantity | Units | Canonical |
|---|---|---|
| distance, altitude | `m`, `km`, `ft`, `mi`, `nmi` | `m` |
| speed | `m/s`, `km/h`, `mph`, `kt` | `m/s` |
| angle | `deg`, `degm` | `deg` |
| temperature | `C`, `F` | `C` |
| pressure | `hPa`, `inHg` | `hPa` |
| rainfall | `mm`, `in` | `mm` |
| irradiance | `W/m2` | `W/m2` |
| voltage | `V` | `V` |
| proportion | `%` | `%` |
| signal power | `dBm` | `dBm` |
| signal ratio | `dB` | `dB` |

`deg` is degrees true and `degm` is degrees magnetic. The difference is not
cosmetic: magnetic declination exceeds 20 degrees in parts of the world and
changes with the year, so a bearing whose reference is assumed is a bearing that
is wrong by an amount nobody can recover. A station reports whichever its
instrument gives it and says which that was.

Each key accepts only the units of its own quantity. `temp:48km/h` is not a cold
day, it is a malformed value, and a receiver skips it rather than trying to make
sense of it.

**A receiver converts to the canonical unit before it compares, stores or plots
anything.** Two stations reporting `spd:6kt` and `spd:3.1m/s` are reporting the same
speed, and a receiver that sorts them by their digits has a bug. Conversion is
the receiver's job precisely because the sender should not have to do it: a
skipper who has to convert knots to metres per second before transmitting will
eventually get it wrong, and nobody will notice.

The unit set is closed. A sender may not invent one, because a unit no receiver
recognises makes the value unreadable rather than merely unfamiliar, and unlike
an unknown key it cannot simply be skipped without losing the reading.

Coordinates are the one exception: `pos:` carries no unit, because it is always
decimal degrees in WGS84 and no second option exists (section 10.1).

---

## 11. Examples

### 11.1 Position

Coarse position, station with no clock:

```
t:obs f:X1QZ3N pos:38.72,-9.14 age:30
```

37 bytes.

Normal fix with a clock:

```
t:obs f:X1QZ3N pos:38.7223,-9.1393 ts:2026-08-08_14:26:40
```

57 bytes.

Five decimals of arithmetic, eight metres of measured accuracy:

```
t:obs f:X1QZ3N pos:38.72231,-9.13934 acc:8m ts:2026-08-08_14:26:40
```

66 bytes.

### 11.2 Movement

Person on foot:

```
t:obs f:X1QZ3N pos:38.7223,-9.1393 alt:87m type:foot spd:1.4m/s dir:212deg ts:2026-08-08_14:26:40
```

97 bytes.

Vehicle, with a note:

```
t:obs f:X1CAR7 pos:38.7231,-9.1402 alt:87m spd:13.4m/s dir:212deg acc:8m type:car ts:2026-08-08_14:26:40 m:heading south on the N8
```

130 bytes.

Balloon ascending at 4.8 m/s through 11240 m:

```
t:obs f:X3BAL1 pos:38.9012,-9.0021 alt:11240m climb:4.8m/s spd:9.2m/s dir:47deg type:balloon ts:2026-08-08_14:26:40
```

115 bytes.

Vessel under way, no altitude:

```
t:obs f:X1BOA3 pos:38.6902,-9.4012 spd:3.1m/s dir:275deg type:boat ts:2026-08-08_14:26:40
```

89 bytes.

### 11.3 Weather

Station with three sensors:

```
t:obs f:X3WX01 pos:38.7223,-9.1393 temp:14.2C hum:78% press:1013.2hPa type:wx ts:2026-08-08_14:26:40
```

100 bytes.

Every defined weather field plus battery, fourteen fields:

```
t:obs f:X3WX01 pos:38.7223,-9.1393 temp:14.2C hum:78% press:1013.2hPa wind:3.4m/s wdir:210deg gust:7.1m/s rain1:0.4mm rain24:12.6mm solar:640W/m2 batt:96% type:wx ts:2026-08-08_14:26:40
```

185 bytes, leaving 65 for fields not yet defined. It is the longest packet in
this document.

Indoor sensor with no position and no clock. Position is omitted rather than
sent as zero:

```
t:obs f:X3WX01 temp:14.2C hum:78% age:60
```

40 bytes.

### 11.4 Telemetry

Unattended node reporting power state:

```
t:obs f:X3RLY7 pos:38.7810,-9.2043 alt:210m batt:64% volt:12.9V type:node ts:2026-08-08_14:26:40
```

96 bytes.

### 11.5 Emergency

A call for help is its own packet type, not an observation with a flag on it
(section 15):

```
t:sos f:X1QZ3N pos:38.7223,-9.1393 acc:6m kind:medical ts:2026-08-08_14:26:40 m:broken leg, cannot walk
```

103 bytes, identifier `2adab3`. Any station may answer:

```
t:ack f:X32DVA d:X1QZ3N r:2adab3 s:ack
```

38 bytes.

### 11.6 Reachability

```
t:png f:X1QZ3N d:X3RLY7 ts:2026-08-08_14:26:40
t:pnr f:X3RLY7 d:X1QZ3N ts:2026-08-08_14:26:40 rssi:-92dBm snr:7.5dB
```

46 and 68 bytes. The reply reports the signal the test arrived with, which is
the receiver's measurement, not the sender's.

### 11.7 Reading a packet

```
t:obs f:X3RLY7 pos:38.7810,-9.2043 alt:210m temp:11.8C hum:88% press:1008.4hPa type:node ts:2026-08-08_14:26:40
```

111 bytes.

| Field | Type | Reading |
|---|---|---|
| `t:obs` | `enum` | an observation; a station filtering for messages stops here |
| `f:X3RLY7` | `call` | unattended station |
| `pos:38.7810,-9.2043` | `coord` | 38.7810 N, 9.2043 W, four decimals, so about 11 m |
| `alt:210` | `dec` | 210 m above mean sea level |
| `temp:11.8` | `dec` | 11.8 degrees Celsius |
| `hum:88` | `int` | 88 percent relative humidity |
| `press:1008.4` | `dec` | 1008.4 hPa at station level |
| `type:node` | `enum` | unattended node |
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
2  t:obs f:X3RLY7 d:X1QZ3N pos:38.7810,-9.2043 ts:2026-08-08_14:26:40 s:pos
```

56 and 72 bytes. The station has no battery reading. It answers with what it
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
1  t:obs f:X3WX01 pos:38.7223,-9.1393 temp:14.1C hum:80% epoch:7.3600
2  t:obs f:X3WX01 pos:38.7223,-9.1393 temp:14.2C hum:78% epoch:7.4210
   A receiver holding a clock records: epoch 7 heard at 2026-08-08_14:26:40.

3  t:obs f:X3WX01 pos:38.7223,-9.1393 epoch:7.9930 ts:2026-08-08_14:26:40
   The station has obtained the time and anchors epoch 7 for all receivers.

4  t:obs f:X3WX01 pos:38.7223,-9.1393 temp:15.0C hum:74% ts:2026-08-08_14:36:00
```

54, 54, 65 and 67 bytes. Packets 1 and 2 are orderable without any clock, since
the higher uptime is later. Packet 3 makes the anchor explicit.

---

## 13. Relaying and carried messages

A packet may travel further than the radio that sent it. A message to a station
no path reaches is handed to a nearby station, which carries it and delivers it
on meeting the recipient; a digipeater repeats what it hears so that stations
beyond the sender's range receive it.

`via:` is the list of callsigns that relayed the packet, in order, oldest
first. **A relay never rewrites `f:`.** It appends itself to `via:` and leaves
the author alone.

```
t:msg f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 q:ack m:meet at the bridge at six
t:msg f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 via:X32DVA q:ack m:meet at the bridge at six
t:msg f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 via:X32DVA,CT1ABC-9 q:ack m:meet at the bridge at six
t:msg f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 via:X32DVA,CT1ABC-9,X3RLY7 q:ack m:meet at the bridge at six
```

80, 91, 100 and 107 bytes: as sent, then after each of three relays. The
recipient reads that the message came from `X1QZ3N` and travelled through
`X32DVA`, `CT1ABC-9` and `X3RLY7` in that order.

The hop count is not transmitted. It is the number of callsigns in `via:`, which
every station can count for itself, and a packet with no `via:` has taken no
hops.

The identifier is `101a23` in all four. `f:`, `ts:` and the payload never
change, so relaying alters neither the identifier nor a signature, and a station
that already holds the message recognises the repeat and does not display it
twice.

### 13.1 How far a packet travels

A relay forwards a packet only while `via:` holds fewer callsigns than the limit
for that packet type:

| Packet type | Relays |
|---|---|
| `sos`, `warn` | 9 |
| everything else | 3 |

The limit belongs to the type rather than to a field. A sender cannot ask the
network for more of its airtime than its traffic warrants, and an emergency does
not have to remember to ask: `sos` and `warn` travel nine relays because they
are the packets worth spending a shared channel on, and a chat message travels
three because it is not.

### 13.2 Loops

**A station that finds its own callsign in `via:` does not relay the packet**,
whatever the count says. The limit bounds how far a packet travels; the path
prevents it from travelling in a circle, and neither substitutes for the other.

A relay also drops a packet it has already relayed within the last few minutes,
identified by `f:`, `ts:` and the payload. Two digipeaters in range of each
other otherwise trade the same packet until the limit is reached, which is legal
under the rules above and still a waste of the channel.

### 13.3 Carried messages

A carrier holding a message for a station that is not currently reachable
follows the same rules: it appends itself to `via:` when it finally transmits.

The recipient's `s:ack` releases carriers still holding a copy. A station that
overhears a receipt for a message it is carrying discards its copy, which is why
a receipt is worth repeating even after the sender has seen it.

---

## 14. Tracks

A track is a named sequence of positions: a flight, a ride, a crossing. Any
station may record one and publish it as it goes, and a receiver assembles the
points into a line without having heard the beginning.

```
t:trk f:X3BAL1 trk:sagres-2026 seq:1 pos:38.9012,-9.0021 alt:11240m type:balloon ts:2026-08-08_14:26:40
t:trk f:X3BAL1 trk:sagres-2026 seq:2 pos:38.9104,-8.9772 alt:14980m climb:4.8m/s type:balloon ts:2026-08-08_14:36:00
```

103 and 116 bytes. `trk:` names the track and `seq:` places the point within it.

- **`trk:` is optional.** A track packet without one belongs to the station's
  current track, keyed on `f:` alone. A station that runs one track at a time
  never names it:

  ```
  t:trk f:X1QZ3N seq:7 pos:38.7301,-9.1355 spd:5.2m/s dir:41deg type:bike ts:2026-08-08_14:26:40
  ```

  Naming becomes worth its bytes when a station runs more than one track, or
  when a track is worth referring to after it ends.
- When present, `trk:` is a `label`: lowercase letters, digits and `-`, no
  spaces. It is chosen by the station and is unique only in combination with
  `f:`, so two stations may both run a track called `commute` without
  collision.
- `seq:` counts from 1 and increases by one per point. A receiver that sees
  `seq:1` then `seq:4` knows two points are missing and draws the gap rather
  than a straight line through it.
- A track point carries any observation field. Altitude, speed, course and
  vertical speed describe the movement; `ts:` dates it.
- A track is never complete. There is no final packet, because a station that
  stops transmitting is indistinguishable from one that is out of range.

```
t:trk f:X1QZ3N trk:commute seq:7 pos:38.7301,-9.1355 spd:5.2m/s dir:41deg type:bike ts:2026-08-08_14:26:40
```

106 bytes.

A track packet is an observation with a name attached. It is a separate type
because a receiver files it differently: an `obs` replaces what it knew about a
station's position, and a `trk` is appended to a line.

### 14.1 Updating a track

Later points are sent as further `trk` packets carrying the same `trk:` and a
higher `seq:`. A point sent again with a `seq:` already held replaces it, which
is how a station corrects a position it later computed more accurately.

### 14.2 What the station is riding on

`type:` names what is moving, from this set. It applies to `obs` and `trk` alike.

| Group | Values |
|---|---|
| On foot | `foot`, `run`, `ski`, `horse` |
| Cycles | `bike`, `ebike`, `motorcycle` |
| Road | `car`, `bus`, `truck`, `tractor`, `emergency` |
| Rail | `train`, `tram` |
| Water | `boat`, `sailboat`, `ship`, `kayak` |
| Air | `airplane`, `helicopter`, `glider`, `balloon`, `drone` |
| Fixed | `node`, `digi`, `wx`, `home`, `portable` |

The words are English and are not translated on the wire. A receiver displays
them in the operator's own language from this fixed set, which is the reason the
set is fixed: a value invented by one station cannot be translated by another.

A receiver that does not recognise a value displays a default marker and the
value as text.

---

## 15. Calls for help

`t:sos` is a call for help. It is a packet type rather than a flag on an
observation, so that a station can act on it after reading three bytes and
without understanding anything else in the packet.

```
t:sos f:X1QZ3N pos:38.7223,-9.1393 acc:6m kind:medical ts:2026-08-08_14:26:40 m:broken leg, cannot walk
```

103 bytes.

| Field | Required | Meaning |
|---|---|---|
| `pos:` | yes, if known | where the person is |
| `acc:` | no | how well that position is known, metres |
| `kind:` | no | what is wrong |
| `ts:` | yes | when the call was made |
| `m:` | no | anything a rescuer should know |

`kind:` takes one of `medical`, `trapped`, `lost`, `fire`, `water`, `cold`,
`assault`, `vehicle`, `other`.

Everything except `ts:` is optional, and a call with no position is still
transmitted. A person who cannot get a fix is exactly the person who needs
help, and a format that refuses to carry the call because a field is missing has
failed at the only moment that matters.

```
t:sos f:X1QZ3N pos:38.7223,-9.1393 kind:trapped ts:2026-08-08_14:26:40
```

70 bytes: no accuracy, no message, and still actionable.

An `sos` is relayed up to nine times (section 13.1). It is never encrypted:
a call for help that only one station can read is worth less than one anybody
can. Any station may answer with `s:ack`, and more than one should.

---

## 16. Warnings

`t:warn` reports a hazard: a thing happening in a place, rather than a thing
happening to the sender. A station transmits a warning about a fire it can see;
it transmits an `sos` about a fire it is caught in.

```
t:warn f:X3RLY7 pos:39.4012,-8.2043 rad:5000m kind:fire sev:danger ts:2026-08-08_14:26:40 m:fast moving, wind from the north
```

124 bytes.

| Field | Meaning |
|---|---|
| `pos:` | centre of the affected area |
| `rad:` | radius of the affected area, in metres |
| `kind:` | what the hazard is |
| `sev:` | how bad it is |
| `ts:` | when the warning was issued |
| `m:` | context a person needs and the fields cannot carry |

`kind:` takes one of `fire`, `flood`, `storm`, `wind`, `snow`, `ice`, `quake`,
`tsunami`, `landslide`, `chemical`, `radiation`, `outage`, `road`, `crowd`,
`animal`, `other`.

`sev:` takes one of:

| `sev:` | Meaning |
|---|---|
| `info` | happening, no action needed |
| `watch` | may affect you, be ready |
| `warning` | will affect you, act now |
| `danger` | life-threatening, leave |

`pos:` with `rad:` states an area rather than a point, which is what a hazard
occupies. A receiver knows whether it is inside the circle without asking
anyone.

```
t:warn f:X3RLY7 pos:38.6902,-9.4012 rad:1200m kind:flood sev:watch ts:2026-08-08_14:26:40
```

89 bytes: a flood watch 1200 m around a point, with no message, because
the fields already say it.

A warning is relayed up to nine times and is never encrypted, for the same
reason an `sos` is not. `ts:` matters more here than anywhere else in this
document: a fire warning that arrives by carrier three days later, and is
plotted as current, is worse than no warning.

---

## 17. Adding a field, worked

A format is judged by what it costs to add something it did not foresee. Suppose
a station gains an air-quality sensor.

The implementer takes an unused key, gives it a type and a unit, and transmits
it:

```
t:obs f:X3WX01 pos:38.7223,-9.1393 temp:14.2C zpm:8 ts:2026-08-08_14:26:40
```

74 bytes. The new field costs six bytes. Every existing receiver reads `zpm:8`,
does not recognise the key, skips it, and continues at `ts:`. Nothing is
versioned, nothing is negotiated, and no other field is affected.

The key begins with `z` because unassigned keys belong in the private space. If
this document later assigns it, the entry is added to the table in section 10.3
with its type and unit, and a shorter key may be chosen; nothing else changes.

The same holds for a new word in `q:` and `s:`. A station asking `q:pos,co2`
gets `s:pos` from every station built before CO2 existed, with no error and no
negotiation.

---

## 18. Operating alongside APRS

A licensed amateur may bridge OPRS and APRS under their own callsign and
responsibility, subject to section 9.4. An `X1` or `X3` callsign is generated by
the station itself and assigned by no authority, so traffic from such a callsign
must not be originated onto amateur infrastructure. Ciphertext must never be
placed on APRS, both because APRS is a 7-bit protocol that would corrupt it and
because obscured meaning is not permitted on amateur bands.

---

## 19. Reserved

Assigned packet types: `msg`, `obs`, `ack`, `rct`, `req`, `id`, `trk`, `sos`,
`warn`, `png`, `pnr`.
All other lowercase words are reserved.

Assigned keys: `t`, `f`, `d`, `ts`, `tz`, `q`, `s`, `r`, `n`, `via`, `trk`,
`seq`, `kind`, `sev`, `rad`, `tag`, `type`, `m`, `file`, `x`, `g`, `k`, `add`,
`remove`, `pos`, `alt`, `acc`, `spd`, `dir`, `o`, `climb`, `temp`, `hum`,
`press`, `wind`, `wdir`, `gust`, `rain1`, `rain24`, `solar`, `batt`, `volt`,
`rssi`, `snr`, `age`, `epoch`.

Assigned `q:` and `s:` words: section 8.

Reserved prefix: `z`, for both keys and words.

A new field takes an unused key and inherits the skip-unknown rule. A new
purpose takes an unused type. Neither redefines an existing assignment.

---

## 20. Implementation status

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
| `key:value` fields separated by spaces | not implemented; the current wire has three `0x1F`-separated fields and packs everything else into a trailing string |
| `t:` packet type as the first field | not implemented; the current wire infers the purpose from the destination field |
| Derived identifiers | not implemented; the current wire hashes message content without a timestamp, so every `OK` collides, and carries a separate receipt identifier |
| `ts:` on messages | not implemented; messages carry no time, although they are the packets most often carried for days |
| `q:` and `s:` | not implemented; receipts exist, requests do not |
| `via:` instead of rewriting `f:` | not implemented; a carrier currently retransmits under its own callsign, which breaks both authorship and the identifier |
| Relay limit by packet type | not implemented; custody re-airs a fixed three times with no path recorded |
| `t:trk` tracks | not implemented; no track is recorded or published |
| `t:sos` calls for help | not implemented; the current wire has an `sos` station symbol, which is a different thing and is not relayed further than any other packet |
| `t:warn` warnings | not implemented; no source |
| `type:` vehicle set | partly; the current wire carries a handful of symbols and none of the rail, air or cycle values |
| Variable-length and authority-issued callsigns | not implemented; the current wire assumes the six-character `X1`/`X3` form |
| `pos:` coordinates | implemented in a different encoding |
| `age:` and `epoch:` time | not implemented; requires an epoch counter in non-volatile storage |
| `a`, `e`, `v`, `u`, `vs` movement | not implemented; the platform supplies these values and the location layer currently retains only latitude and longitude |
| `c`, `h` weather | one hardware sensor exists and reaches a local display only |
| `b`, `w`, `wd`, `wg`, `rh`, `rd`, `sr` weather | no source |
| `bt`, `vl` telemetry | not implemented; charging state is tracked, charge level is not |
| `rs`, `sn` telemetry | implemented on the receive paths |
