# XPRS, eXtended Packet Radio System

Protocol specification.

XPRS carries position, movement, weather, telemetry and messages between
stations over licence-free spectrum and the internet. It occupies the same role
as APRS and requires no amateur licence.

Status: DRAFT 10. Section 36 states which parts are implemented.

---

## 1. Purpose

APRS is a proven network, and an XPRS station meeting APRS infrastructure
operates under APRS rules (section 20). APRS has two prerequisites: amateur
spectrum, and a callsign issued by a radio authority. Both are correct for a
licensed service, and both exclude everyone without a licence.

XPRS applies the same design to Bluetooth and LoRa in the ISM bands, WiFi, and
the internet, with identity derived from a keypair generated on the device.

APRS accumulated its data formats one field at a time over three decades. The
result is four incompatible position encodings, weather carried as fixed-width
fields inside a position report, telemetry whose units are defined in separate
messages that must be received beforehand, and a mixture of feet, knots, miles
per hour, Fahrenheit, hundredths of an inch and tenths of a millibar. Each
addition was constrained by a packet that was already full and by a format with
nowhere left to put a new field.

XPRS is one syntax, readable on sight, with room to grow.

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
t:message f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 m:net starts in ten minutes
```

78 bytes. A person reads it, and so does a five-line parser.

---

## 3. Callsigns

An XPRS callsign is `X1`, `X3` or `X5` followed by four characters derived from
the holder's public key:

```
X1 = person or operator
X3 = station, relay or unattended equipment
X5 = group (section 26)
```

A group holds a keypair like anything else, so it gets a callsign like anything
else. What differs is only who holds the private half: a person for `X1`, a
machine for `X3`, and whoever administers the group for `X5`.

The four characters are taken from the bech32 encoding of the key, so the
letters `b`, `i` and `o` and the digit `1` never appear in them.

Callsigns are **always uppercase** and are **not a fixed length**. A callsign
issued by a radio authority is equally valid on the wire, including a suffix:

```
t:message f:CT1ABC-9 d:G0XYZ/P ts:2026-08-08_14:26:40 m:gate is closed, use the east path
```

89 bytes. Nothing in this format assumes a callsign length.

An XPRS callsign is a label, not an identity. Four characters is approximately
one million values, and collisions can be produced deliberately. A receiver that
needs to establish identity verifies a signature against the full public key
(section 9). No authority issues, revokes or vouches for an `X1`, `X3` or `X5`
callsign.

That last sentence has a consequence on the air: **a self-generated callsign may
never be transmitted on licensed spectrum**, where identifying the station is a
condition of the licence. Section 9.4.1 states the rule and section 9.4.2 shows
how an operator ties a callsign that *was* issued to them to the key they sign
with.

### 3.1 One person, several devices

The same person runs a phone, a tablet, and a node in the shed. All three hold
the same key, so all three derive the same four characters -- and on the air they
are one callsign saying three different things.

APRS answered this with an SSID: `CT1ABC-9`. XPRS keeps that notation, because
it is the one every operator already reads, and changes what sits underneath it.

**The bare callsign is the person. A suffix is one of their devices.**

```
X1A67X      the person, on whatever device is in reach
X1A67X-1    one of their devices
X1A67X-2    another
```

Numbers run `-1` to `-99`. `-0` is never written: the bare form already means
the person. The suffix costs two or three bytes on `f:` and on `d:`, and nothing
anywhere else.

#### 3.1.1 Choosing a number, without anyone to ask

A device starts bare and stays bare while it is alone -- most stations never
number themselves at all.

It learns it is not alone the moment it hears a beacon (section 10.6) carrying
**its own callsign and a different key**. Two devices of one person share the
person's key; they do not share the key their own destination is derived from,
and on a beacon that difference is visible as `lx:`:

```
t:observation f:X1A67X-1 link:ble peers:2 lx:5463d9bc93aebda57d1f704a3cfbee80
t:observation f:X1A67X-2 link:ble peers:2 lx:23698e7593f05e2053f5183580e2cf98
```

77 bytes each. Each device then takes **the lowest number it has not heard in
use**, and when two would take the same one, the device whose own key sorts
lower keeps it and the other picks again. Both sides compute that from what they
have already heard, so there is no negotiation, no registry, no coordinator, and
no state that can be lost -- only a rule that two devices apply to the same facts
and reach the same answer.

A number, once adopted, is kept across restarts. A device that has been alone
for a long time may drop back to bare, and nothing breaks if it does not.

#### 3.1.2 What the numbers mean

APRS gave its SSIDs conventional meanings, and a generation of operators reads
them fluently: `-9` is the car, `-7` is the handheld, `-13` is a weather
station. XPRS keeps those meanings for `-1` to `-15`, unchanged, so an operator
who has been reading them for twenty years reads ours correctly and a gateway
maps both ways without a table of its own.

| Suffix | APRS convention | XPRS `type:` it usually goes with |
|---|---|---|
| *(bare)* | primary / home station | -- the person |
| `-1` to `-4` | generic, digipeater | `digi`, `node` |
| `-5` | other networks, smartphone | `portable` |
| `-6` | special activity, satellite, camping | `portable` |
| `-7` | handheld | `portable` |
| `-8` | boats, RV, second mobile | `boat`, `sailboat` |
| `-9` | primary mobile | `car` |
| `-10` | internet gateway | `node` |
| `-11` | balloon, aircraft, spacecraft | `balloon`, `airplane`, `glider`, `drone` |
| `-12` | trackers, DTMF, RFID devices | `drone`, `node` |
| `-13` | weather station | `wx` |
| `-14` | trucker, full-time driver | `truck` |
| `-15` | generic, digipeater | `digi` |

**`-16` to `-99` mean nothing at all, and that is the extension.** APRS stopped
at 15 because four bits was what it had. We have room, so the numbers above 15
are plain serials for a person with more devices than the conventions have names
-- a fourth tablet is not a *kind* of thing, it is the fourth one.

**Where the two disagree, `type:` wins.** A suffix is a hint for people and for
gateways; `type:` (section 35) is the machine-readable answer, and APRS never
had one:

```
t:observation f:X1A67X-9 type:car link:ble peers:2 lx:5463d9bc93aebda57d1f704a3cfbee80
```

86 bytes. **A receiver never infers what a station is from its suffix when
`type:` is present**, and never rejects a station for wearing a number that
disagrees with it. The conventions are there to be helpful, not to be enforced.

This also improves the numbering above: a device that knows its own `type:`
**prefers the conventional number for it** when that number is free. A phone in
a car self-numbers to `-9` without anyone typing anything, and an operator who
has never read this document still guesses right.

#### 3.1.3 What is addressed to whom

| `d:` | Reaches | Use it for |
|---|---|---|
| `X1A67X` | the person, on whatever device is reachable | everything ordinary |
| `X1A67X-2` | that one device | what only that machine can answer |

Ordinary traffic names the person, because a person is not their tablet:

```
t:message f:X1RD89 d:X1A67X ts:2026-08-12_17:28:52 m:on my way
```

62 bytes. Every device of that person shows it, and the sender does not have to
know or care which screen its reader is in front of.

A suffix is for when the machine is the point -- the photos are on the tablet,
the sensor is wired to the shed:

```
t:message f:X1RD89 d:X1A67X-2 ts:2026-08-12_17:28:52 m:the tablet has the photos
```

80 bytes.

**Commands are the other way round.** `cmd:door-open` addressed to a person is
meaningless -- a person is not a door -- so a command (section 25) names a
device:

```
t:command f:X1A67X-1 d:X1A67X-2 ts:2026-08-12_17:28:52 cmd:status
```

65 bytes. A station receiving a command addressed to the bare callsign may
refuse it, and should, unless it is the only device wearing that callsign.

**A station accepts a packet addressed to its own suffixed name or to the bare
callsign, and no other.** Everything a receiver keys on a *person* -- a thread, a
reputation, a block, a follow -- keys on the bare callsign, so numbering a device
never splits a conversation in two.

#### 3.1.4 Two devices, one recipient

Both will answer, and that is correct rather than a fault to suppress. A receipt
(section 13.7.1) names the device that sent it:

```
t:receipt f:X1A67X-1 d:X1RD89 r:40f357 s:ack sig:<60 characters>
t:receipt f:X1A67X-2 d:X1RD89 r:40f357 s:ack sig:<60 characters>
```

109 bytes each, both naming the one message in `r:`. The sender collapses them
on that identifier: one message, delivered -- and, if it cares to look, delivered
to two of the three devices that person carries.

Mail held for a bare callsign (section 13.3) is discharged by handing it to
**any** device wearing it. The person has their message; the carrier's job is
finished. Getting that message onto their *other* devices is not the mesh's
business -- it is the same key on all of them, and their own software can settle
it between themselves.

#### 3.1.5 What a suffix is not

It is not authentication, and nothing should be built as though it were. Every
device of one person holds the same private key, so any of them can sign as that
person and any of them can claim any number. A suffix distinguishes devices that
are cooperating, never devices that are competing.

The device's real name on the wire is `lx:` -- a destination derived from a key
that device alone holds. When it genuinely matters which machine is being
addressed, that is what proves it; the digits after the hyphen are a convenience
for people.

Which is the difference from APRS worth stating plainly. There the SSID was
typed by the operator and meant something by convention. Here the **person is
proven by the key**, the **device is proven by `lx:`**, and the suffix exists so
a human can say which one they mean.

---

## 4. Packet

```
key:value key:value key:value ...
```

- A key is 1 to 8 characters, lowercase letters and digits, beginning with a
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
| `d` | `addr` | recipient: a callsign, a group name, or absent for a broadcast |
| `ts` | `time` | when the packet was composed, UTC |
| `tz` | `offset` | the sender's offset from UTC, for display |
| `q` | `words` | what the sender wants back (section 7) |
| `s` | `words` | what this packet answers or reports (section 7) |
| `r` | `hex6` | the identifier of another packet this one refers to |
| `n` | `ratio` | this packet is part i of n |
| `tag` | `labels` | topic labels chosen by the sender (section 4.5) |
| `cw` | `words` | what the packet contains, warned before rendering (section 4.6) |
| `urg` | `enum` | how much this is worth carrying (section 13.5) |
| `scope` | `scope` | how far this may be relayed, default global (section 13.11) |
| `lang` | `lang` | language of `m:`, default English (section 4.7) |
| `hold` | `path` | preferred mailboxes, in order (section 13.12) |
| `serve` | `words` | what a station does for others (section 24) |
| `cmd` | `label` | the action a command asks for (section 25) |
| `arg` | `words` | its arguments |
| `code` | `int` | what happened, on a `result` |
| `near` | `qty` | how close to `dest` counts as arrived (section 13.4) |
| `route` | `path` | the route a receipt is acknowledging (section 13.10) |
| `add` | `enum` | something this packet adds (section 6.5) |
| `remove` | `enum` | something this packet withdraws (section 6.5) |
| `grant` | `path` | callsigns admitted to a group (section 26) |
| `revoke` | `path` | callsigns removed or suspended (section 26) |
| `role` | `enum` | what a grant confers: `mod`, `sub`, or absent for a member |
| `hide` | `enum` | what a moderator withdraws from view: `message` |
| `mood` | `enum` | how the sender feels (section 27.1) |
| `only` | `addr` | narrows a replay to one callsign or group (section 25.2) |
| `opt` | `labels` | the choices in a poll, two to six (section 28) |
| `root` | `hex6` | the packet a thread hangs from (section 6.4) |
| `size` | `qty` | how large a file is (section 6.7.1) |
| `vote` | `label` | the option chosen in a poll (section 28.3) |
| `via` | `path` | callsigns that relayed this packet, oldest first (section 13) |
| `track` | `label` | name of a track this packet belongs to (section 14) |
| `title` | `label` | name of a post or event, stable across revisions |
| `dest` | `coord` | where a passage is bound (section 20) |
| `onboard` | `int` | how many people are aboard |
| `price` | `money` | what is being asked or offered (section 22.1) |
| `freq` | `qty` | a frequency (section 23) |
| `bw` | `qty` | bandwidth |
| `shift` | `qty` | repeater input, as an offset from `freq` |
| `input` | `qty` | repeater input frequency, stated outright |
| `tone` | `qty` | access tone |
| `power` | `qty` | transmit power |
| `mode` | `enum` | how a channel is modulated |
| `ch` | `label` | channel number in a band plan |
| `range` | `qty` | expected usable range, an estimate |
| `site` | `enum` | whether the station stays where it is |
| `supply` | `enum` | what powers the station |
| `every` | `qty` | how long between recurring windows |
| `for` | `qty` | how long each window lasts |
| `at` | `clock` | time of day a cycle is anchored to, UTC |
| `seq` | `int` | position of this point within that track |
| `kind` | `enum` | nature of an event, values per packet type (sections 15, 16) |
| `sev` | `enum` | severity of a warning (section 16) |
| `rad` | `qty` | radius of the area affected or asked about (sections 16, 17, 28) |
| `since` | `time` | when the condition started, or will start |
| `until` | `time` | when the sender expects the condition to end |
| `m` | `text` | human-readable content, always last |
| `file` | `ref` | content hash and type of a referenced file |
| `name` | `label` | filename, when the extension is not enough (section 6.7.1) |
| `ph` | `ref` | content hash of a file's piece list (section 6.7.2) |
| `count` | `int` | how many files a folder listing holds (section 6.7.3) |
| `b` | `b64` | a small file's bytes, inline (section 6.7.4) |
| `ih` | `label` | BitTorrent infohash, 40 hexadecimal characters (section 6.7.5) |
| `have` | `label` | what a station holds of a file: `full`, a bitfield, or a fraction (section 7.1) |
| `off` | `qty` | byte offset a `cmd:file` transfer resumes from (section 25.2) |
| `x` | `b64` | sealed body |
| `sig` | `base85` | signature |
| `k` | `bech32` | public key, in `t:identity` and `t:challenge` |

### 4.2 Packet types

| `t:` | Purpose |
|---|---|
| `message` | a message, to a station, a group, or anyone in range |
| `observation` | an observation: position, movement, weather, telemetry |
| `receipt` | a receipt or an answer to a request |
| `reaction` | a reaction to another message |
| `request` | a request for data another station holds |
| `identity` | an identity announcement, binding callsign to public key |
| `track` | a point in a named track (section 14) |
| `sos` | a call for help (section 15) |
| `info` | a notice about conditions (section 17) |
| `blog` | a published post (section 19) |
| `poll` | a question put to everybody, with the choices (section 28) |
| `file` | what a file is, so it can be wanted (section 6.7.1) |
| `report` | a claim that a packet is spam or abuse (section 29) |
| `place` | somewhere useful that is not the sender (section 30) |
| `status` | a short post about the sender, now (section 27) |
| `passage` | where a vessel is going (section 20) |
| `event` | something happening at a time and place (section 21) |
| `offer` | what a station has (section 22) |
| `need` | what a station wants (section 22) |
| `channel` | a frequency a station uses (section 23) |
| `mailbox` | stations that hold mail for the sender (section 13.12) |
| `service` | what a station does for others (section 24) |
| `command` | asks a station to do something (section 25) |
| `result` | what happened to a command |
| `moderate` | an act of authority in a group (section 26) |
| `challenge` | a challenge to prove a callsign (section 18) |
| `response` | the answer to a challenge |
| `warning` | a warning about a hazard (section 16) |
| `ping` | a reachability test |
| `pong` | a reply to `ping` |

An unknown type is ignored. It is never an error and is never displayed as a
message. Types not listed here are reserved (section 21).

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
| `addr` | a `call` or a group name | `LISBOA` |
| `path` | one or more `call`, separated by commas | `X32DVA,CT1ABC-9` |
| `hex6` | exactly 6 lowercase hexadecimal characters | `399227` |
| `time` | `YYYY-MM-DD_HH:MM:SS`, UTC | `2026-08-08_14:26:40` |
| `offset` | `+HH:MM` or `-HH:MM` | `+05:45` |
| `coord` | two `dec` separated by a comma, latitude then longitude | `38.7223,-9.1393` |
| `ratio` | two digits `1` to `9` separated by `/`, position then total | `2/3` |
| `epoch` | two `int` separated by a dot, boot counter then seconds | `7.4210` |
| `scope` | `local`, `global`, or ISO 3166-1 alpha-2 codes separated by commas | `PT,ES` |
| `lang` | an ISO 639-1 code, optionally `/` and a region | `PT/BR` |
| `nick` | 1 to 16 ASCII letters, digits, `-` and `_` | `joao-brito` |
| `clock` | `HH:MM:SS`, a time of day in UTC | `20:00:00` |
| `money` | an amount with an ISO 4217 code, optional leading `~` and `/` period, or one of `offers`, `swap`, `free` (section 22.2) | `~25EUR/day` |
| `qty` | a number followed immediately by its unit (section 10.9) | `48km/h` |
| `ref` | 43 base64url characters (a SHA-256, no padding), a dot, 1 to 8 lowercase alphanumerics | `nyxKz...L4Q.jpg` |
| `b64` | base64url, no padding | `pQ4m9xT2vB8kR` |
| `bech32` | a bech32 string | `npub1qz3n7...` |
| `base85` | 60 characters, base85, no space | |
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
- **A measurement carries its unit** (section 10.8). The number rules above
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
t:message f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 tag:vacation m:back on Monday, radio off until then
```

102 bytes. Several labels are separated by commas:

```
t:message f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 tag:vacation,photos m:the coast near Sagres
```

94 bytes. There is no limit on how many labels a packet carries beyond the
250-byte packet itself. It applies to any packet, not only messages:

```
t:observation f:X3WX01 pos:38.7223,-9.1393 temp:14.2C ts:2026-08-08_14:26:40 tag:field-day
```

90 bytes.

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

### 4.6 Content warnings

`cw:` warns a receiver what a packet contains before it renders it.

```
t:blog f:X1QZ3N ts:2026-08-08_14:26:40 title:haulout cw:injury m:the hand is fine now, photos below
```

99 bytes. `cw:` costs nine bytes and takes one or more words, separated by
commas:

| Word | Contents |
|---|---|
| `adult` | sexual content |
| `nudity` | nudity that is not sexual |
| `violence` | violence |
| `injury` | graphic injury, blood, surgery |
| `death` | death, human or animal |
| `drugs` | drug or alcohol use |
| `language` | profanity |
| `spoiler` | spoils something the reader may not have seen |
| `flashing` | rapid flashing or strobing |
| `other` | something else the sender thinks needs a warning |

`flashing` is not a matter of taste. Rapid flashing triggers seizures in
photosensitive epilepsy, and a receiver that autoplays is the case the warning
exists for:

```
t:info f:X3RLY7 pos:38.7223,-9.1393 kind:event cw:flashing ts:2026-08-08_14:26:40 m:fireworks over the harbour at ten
```

117 bytes.

It is a closed vocabulary rather than a `tag:`. A label means whatever the people
using it agree it means (section 4.5), which is fine for a topic and useless for
a filter: a receiver cannot hide adult content reliably if the word for it is
whatever each sender chose, in whatever language. These ten words a receiver can
act on, and translate.

It is several words rather than one rating, because a single scale cannot say
why. Somebody avoiding graphic injury is not the same person as somebody
avoiding sexual content, and neither is the reader who needs `flashing`.

Four rules, each covering a way this otherwise fails without anyone noticing.

**It covers the whole packet, including any `file:`.** The attachment is usually
the thing that needed warning about:

```
t:message f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 cw:adult,nudity file:nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w.jpg m:not for the group chat
```

144 bytes.

**It is repeated on every part** of a split message, not only the first. Parts
arrive in any order (section 6.6), so a warning carried once is a warning the
receiver may read after it has already displayed part two.

**It stays in cleartext when the body is sealed.** `cw:` is an envelope field
and is never moved inside `x:`, because a receiver has to decide whether to
render before it decrypts:

```
t:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 cw:adult x:<64 characters> sig:<60 characters>
```

191 bytes. What the packet contains is disclosed; the content itself is not.

**A relay never strips it**, and **its absence is not a guarantee**. An unmarked
packet is unmarked, not safe. A receiver that treats a missing `cw:` as a
promise has built a filter on the honesty of strangers.

`cw:` marks content. It does not regulate it: what is lawful to send or offer
differs by country, and that is the operator's business and not the format's.

```
t:offer f:X1QZ3N pos:38.6902,-9.4012 kind:other cw:adult price:~40EUR/h ts:2026-08-08_14:26:40 m:massage, by appointment
```

120 bytes.

### 4.7 Language

`lang:` says what language the text is in. It is optional and **the default is
English**, so a packet without it is read as English.

```
t:message f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 lang:PT m:a rede comeca daqui a dez minutos
```

94 bytes, nine of them the field. An ISO 639-1 code in uppercase.

A regional variant is added after a slash, which is worth the three bytes where
it changes the words rather than the accent:

```
t:message f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 lang:PT/BR m:a rede comeca daqui a dez minutos
```

97 bytes. `PT/BR` and `PT` are the same language and not the same
vocabulary, and `EN/US` and `EN/GB` disagree about enough words to matter in a
warning.

Uppercase and the slash both follow conventions already in the format: values
are uppercase where they are codes rather than words, and `/` already separates
in `n:2/3` and in a callsign like `G0XYZ/P`.

`lang:` describes `m:` and nothing else. A packet with no text does not need it,
and the keys, the packet types and every enum value in this document are English
regardless -- they are identifiers rather than prose, and translating them would
break every receiver.

A receiver that cannot read the language still relays it. Translation is a
presentation matter, and a station that dropped what it could not read would
make the network useless to anybody in a minority language.

### 4.8 Time

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
t:message f:VK2XYZ d:X1QZ3N ts:2026-08-08_14:26:40 tz:+11:00 m:good morning from Sydney
```

87 bytes. The receiver reads 14:26 UTC, and knows it was 01:26 the next morning
where the sender was standing. Offsets of 30 and 45 minutes exist, so the
minutes are written out rather than assumed to be zero.

`tz:` is presentation only. It never changes `ts:`, never takes part in an
identifier, and a station that ignores it loses nothing but the courtesy.

A packet that may be relayed or carried **must** have a time field. A carried
packet can be delivered days later, and an undated position is plotted as
current. Two alternatives exist for stations without a clock (section 10.7).

### 4.9 Extending the format

A new field takes an unused key, declares its type, and is placed anywhere.
Receivers that do not know the key skip it and its value. No existing field
moves, no packet type is added, and no version is negotiated.

Keys beginning with `z` are reserved for private and experimental use and are
never assigned by this document.

```
t:observation f:X3WX01 pos:38.7223,-9.1393 temp:14.2C zpm:8 ts:2026-08-08_14:26:40
```

82 bytes. Every existing receiver reads `temp:14.2` and `ts:`, skips `zpm:8`, and
is otherwise unaffected.

---

## 5. Message identifiers

**Every packet has an identifier, and it is never transmitted.** Both ends
compute it from the packet itself:

```
id = first 6 hex characters of sha256(the packet, with sig: and via: removed)
```

Nothing announces its own identifier. A packet already carries who sent it and
when, so the identifier is free.

The timestamp is what makes this work. Hashing content alone would give every
`OK` ever sent the same identifier, and `OK` is the most common message on any
network:

```
X1QZ3N  2026-08-08_14:26:40  OK   ->  06900a
X1QZ3N  2026-08-08_14:27:22  OK   ->  2c6755
X1RD89  2026-08-08_14:26:40  OK   ->  03d7dc
```

Sender, second and text together are unique in practice.

Two fields are excluded and both for the same reason: they change while a
packet is in flight. Signing must not alter the identifier of what was signed,
and a carrier appending itself to `via:` must not turn one message into a
different one. Everything else is included, which is what makes the identifier
exact.

`f:` and `ts:` alone would not be enough. A station beaconing position and
weather in the same second would give both packets one identifier, and a reply
naming it would be ambiguous. Hashing the whole packet costs nothing, because
none of it goes on the wire.

`r:` carries an identifier when a packet refers to another: a reply, a reaction,
a receipt, or a withdrawal of the sender's own earlier packet (section 17.2).

---

## 6. Messages

### 6.1 Broadcast

No `d:`. The packet is addressed to whoever is in range.

```
t:message f:X1QZ3N ts:2026-08-08_14:26:40 m:anyone near the north gate?
```

71 bytes.

### 6.2 Direct

```
t:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 m:meet at the bridge at six
```

78 bytes, identifier `de9780`.

### 6.3 Group

`d:` holds a group name. Group names are uppercase, 1 to 16 characters. A
station tells an open group from a person or a machine by the `X1`/`X3` prefix
and the four characters that follow, so an open group may not be named like one
of those.

```
t:message f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 m:net starts in ten minutes
```

78 bytes, identifier `399227`. Anyone may post to `LISBOA` and nobody may be
removed from it, which is the whole of what an open group is.

A group that needs a member list holds a keypair and is addressed by the `X5`
callsign derived from it (section 26). Everything in this section applies to it
unchanged:

```
t:message f:X1RD89 d:X5A3F2 ts:2026-08-08_14:26:40 m:net starts in ten minutes
```

78 bytes, identifier `89a9c8`. The same size as the line above it, because a
closed group costs an ordinary packet nothing.

### 6.4 Replies

`r:` names the packet being replied to, which may be any packet carrying
content (section 6.5).

```
t:message f:X1RD89 d:LISBOA ts:2026-08-08_14:36:00 r:399227 m:I'll be late, start without me
```

92 bytes. The reply has its own identifier, computed the same way, so it can be
replied to in turn. A receiver that has not seen the parent still displays the
reply, marked as answering a message it does not hold.

**Below the first level a reply also names the thread it belongs to**, with
`root:`:

```
t:message f:X32DVA d:LISBOA ts:2026-08-08_14:40:00 root:399227 r:8536fb m:no rush, we start at nine
```

99 bytes. `r:` keeps exactly the meaning it had -- the packet being replied to --
and `root:` names the packet the whole conversation hangs from.

A first-level reply carries `r:` alone, because its parent *is* the root. Only
deeper replies carry both, so the eleven bytes are spent only where they buy
something.

What they buy is the ordinary case on this network rather than an unusual one.
**A lost middle packet orphans everything beneath it**: with `r:` alone, a
receiver holding a reply whose parent it never heard cannot tell which
conversation the reply belongs to, and a thread arriving out of order over three
bearers reassembles into fragments. `root:` makes that reply filable anyway --
shown under the right conversation, in the right place, with a gap where the
missing packet was.

### 6.5 Reactions

```
t:reaction f:X32DVA d:LISBOA r:399227 add:like
t:reaction f:X32DVA d:LISBOA r:399227 remove:like
```

46 and 49 bytes. `add:` states what is being added and `remove:` withdraws that
same thing, so neither has to be read as the negation of the other. A reaction
carries no `m:`. It is counted once per callsign, is idempotent, is not
displayed as a message and raises no notification.

### 6.5.1 Replying, quoting and passing on

Three things a social network needs, and the format already had two of them.

**A reply is `r:`** (section 6.4), and it works on any packet carrying content.

**A quote is a reply that says something.** There is no separate mechanism and
there does not need to be: `r:` names what is being quoted and `m:` is the
comment on it.

```
t:status f:X32DVA ts:2026-08-08_14:40:00 r:399227 m:worth reading, he is right about the feed point
```

99 bytes. A client renders the parent above the comment; a client that never
heard the parent shows the comment and says so, which section 6.4 already
requires of every reply.

**Passing something on unchanged is `add:repost`.**

```
t:reaction f:X32DVA d:LISBOA r:399227 add:repost
t:reaction f:X32DVA d:LISBOA r:399227 remove:repost
```

48 and 51 bytes. It is a reaction because it has a reaction's shape exactly: one
per callsign, idempotent, withdrawable, and no text of its own.

**What travels is the original packet, not a copy of it.** A repost says "this
belongs in front of the people who follow me", and the thing itself is re-aired
with `f:`, `ts:` and `sig:` untouched -- the same act as a history replay
(section 25.2.1), and safe for the same reason: duplicates collapse on the
derived identifier, so a post reposted by nine stations is still one post.

That is the difference from a quote worth understanding. **A repost adds nothing
and changes nothing**, so it cannot misrepresent what it carries; the signature
still proves who wrote it and the reposter's callsign appears only on the
reaction. A quote is the sender's own packet with their own words, and they
answer for those.

**A reply and a reaction are different acts, and not every packet takes both.**

Every packet has an identifier (section 5), so `r:` can name any of them. What
differs is whether naming it means anything:

| Packet type | Reply | React |
|---|---|---|
| `message`, `status`, `blog`, `observation`, `track`, `passage`, `event`, `offer`, `need`, `channel`, `service`, `place`, `poll`, `file`, `warning`, `info` | yes | yes |
| `sos` | yes | **no** |
| `reaction`, `receipt`, `request`, `challenge`, `response`, `identity`, `mailbox`, `command`, `result`, `moderate`, `report`, `ping`, `pong` | no | no |

A weather observation, a warning, a blog post, an offer and a channel
announcement can all be replied to and reacted to. That is the point of deriving
an identifier for every packet rather than only for those carrying a message.

**A call for help takes replies and never reactions.** Answering an `sos` is
`t:receipt` with `s:ack` (section 11.5), which says a station heard it and is a
different thing from approving of it. A reaction adds nothing that mechanism
does not already carry, spends airtime on a channel that must stay clear, and a
counter of likes under somebody's call for help is grotesque. A receiver
discards one.

The bottom row is protocol machinery rather than content, and a receiver
**ignores** a reply or reaction naming any of it.

A reaction is excluded because a reaction to a reaction is not a thing anyone
means, and a reply to one is a reply to the wrong packet: the reaction already
names what it was about, and that is what should be answered.

A **track point** is replied to and reacted to like anything else, but people
mean the track rather than the point. A receiver attributes both to the track,
which `f:` and `track:` identify (section 14), and shows them once against the
line instead of against `seq:7`.

A **challenge and its response** are excluded for a stronger reason. They are a
two-party authentication exchange, valid for sixty seconds, and the only thing
that should ever name a challenge is its own response. Anything else pointing at
one is noise at best, and at worst an invitation to treat a security exchange as
a conversation.

### 6.5.2 Mentioning somebody

A mention is `@` followed by a callsign, written in the text where a person would
write it:

```
t:status f:X1QZ3N ts:2026-08-08_14:26:40 m:thanks @X1RD89 and @X32DVA for the relay last night
t:message f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 m:@CT1ABC-9 is the one to ask about the repeater
```

94 and 99 bytes. **There is no key for this**, and there should not be: a field
would carry the same information twice, once for the parser and once for the
reader, and cost bytes to do it. A receiver that has never heard of mentions
still shows `@X1RD89` and a person still understands it, which is the property
design rule 2 exists to protect. Other formats need a tag because their content
is opaque to the protocol; `m:` is not opaque to anybody.

**The parse rule is one line.** `@` followed by one or more `call` characters --
uppercase letters, digits, `-` and `/` -- ending at the first character that is
not one of those. A trailing `-` or `/` is punctuation and not part of the
callsign.

**Uppercase is what makes it safe.** Callsigns are always uppercase (section 3),
so `write to me@example.com` contains no mention, and the rule needs no escape
character, no delimiter and no exception.

**There is no limit on how many.** The packet limit is already the limit, and it
is a better one than any number this document could pick: mentions compete with
the message for the same 250 bytes, so a station that tags thirty people has no
room left to say anything to them.

Two things follow. A station that finds its own callsign after an `@` **raises a
notification**, which is the entire point of the convention. And **anyone may
mention anyone**: there is no consent, no blocking and no way to prevent it, so a
client must let its operator mute a callsign whose mentions it does not want.

A mention is also the strongest signal a station has for deciding what to keep
(section 31.3). Being named is what makes a packet worth more than the traffic
around it, and until now nothing in this format said so.

### 6.6 Long messages

A message longer than one packet is split into numbered parts. Every part
carries the same `ts:` and its own `n:`.

```
t:message f:X3RLY7 d:LISBOA ts:2026-08-08_14:26:40 n:1/3 m:The repeater on the hill is down.
t:message f:X3RLY7 d:LISBOA ts:2026-08-08_14:26:40 n:2/3 m:We swapped the antenna feed this morning
t:message f:X3RLY7 d:LISBOA ts:2026-08-08_14:26:40 n:3/3 m:and it is back up, but only just.
```

92, 99 and 92 bytes.

- Reassembly is keyed on `(f, ts)`. The parts of one message share a timestamp,
  so no identifier has to be transmitted to bind them.
- Only `m:` is split — with one exception: a packet carrying inline file bytes
  splits `b:` instead (section 6.7.4), and those parts are joined with nothing
  rather than a space, because base64url has no spaces to split at.
- Every field except `m:` and `n:` is repeated on each part, so a receiver can
  read the envelope of any one of them.
- **A sender splits only at a space, and never inside a word.**
- **A receiver joins the `m:` values in order with exactly one space between
  them.** No part begins or ends with a space, so there is never a doubled space
  and never a missing one.
- **The identifier is that of the packet the parts reassemble into**: every
  field from the first part, `m:` replaced by the joined text, and `n:` removed,
  hashed as section 5 says. A reply names that, never an individual part. Each
  part has its own identifier and none of them is the message's.
- Incomplete sets are held for 10 minutes and then discarded. A partial message
  is never displayed.
- Parts may arrive in any order. A repeated part number is ignored.
- **A set is limited to 9 parts**, so `n:` is always three characters and the
  last part is at most `n:9/9`. A message that does not fit in nine parts is
  sent as a file (section 6.7) rather than split further: at that size the
  content is a document, and a receiver that loses one of twenty parts has
  waited a long time to be told it has nothing.

### 6.7 Files

`file:` is the SHA-256 digest of the file contents as 43 base64url characters
(no padding), a dot, and 1 to 8 lowercase alphanumeric characters giving the
type.

```
t:message f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 file:nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w.jpg m:the antenna after the storm
```

133 bytes. The caption is an ordinary `m:` field.

base64url because the digest is the single most repeated expensive value in the
format and 43 characters against 64 for hex is 21 bytes returned to every
packet that carries one. A receiver also accepts the digest as 64 lowercase
hexadecimal characters — the earlier form of this field — and treats the two as
the same reference; a sender emits base64url.

The hash identifies the file exactly, so any station holding those bytes can
satisfy the reference and a receiver can verify what it obtained. The extension
is advisory: it indicates how to present the content and never affects
identification. A receiver that does not recognise an extension offers the file
as an opaque download.

How the bytes are transferred is outside this specification. A reference remains
valid whether the file arrives over the same radio, over the internet, or on
physical media. What THIS document defines is everything around the bytes: how
a file is described (6.7.1), how a large one is verified in pieces and a folder
of them is listed (6.7.2), how a whole folder is synchronised (6.7.3), how a
small one rides the packets themselves (6.7.4), how anyone asks who holds one
(section 7, `q:have`), and how one is fetched or deposited (section 25.2,
`cmd:file` and `cmd:put`).

### 6.7.1 Saying what a file is

A hash identifies a file perfectly and describes it not at all. `t:file` is the
packet that says what the bytes are, so somebody who does not already know can
decide whether to want them:

```
t:file f:X1QZ3N ts:2026-08-08_14:26:40 file:nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w.jpg size:240kB tag:radio m:the finished dipole, feed point centred
```

154 bytes. `m:` describes it, `tag:` files it under topics, and `size:` is a
quantity with its unit like every other measurement in this format.

**`size:` is the field that earns its bytes.** `cmd:file` (section 25.2) asks a
station to send the content, and on a bearer that owes seconds of silence per
packet the difference between a 240 kB photograph and a 40 MB video is the
difference between a fetch and a mistake. Knowing the size first is how a station
declines politely instead of starting something it cannot finish.

Two optional fields complete the description:

- `ph:` — a `ref`: the content hash of the file's **piece list** (6.7.2), which
  is itself an ordinary content-addressed file. Its presence says this file can
  be verified piece by piece, which is what lets several stations serve parts
  of it at once and a station holding half of it serve that half.
- `name:` — the filename, 1 to 64 characters with no space (the value rule of
  section 4). Optional because the extension already advises presentation and a
  name costs bytes the packet may not have.

```
t:file f:X1QZ3N ts:2026-08-08_14:26:40 file:nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w.jpg size:240kB ph:qA7dTf2mWx9bK4pZcV0yLuJ3gRhN8sE5iDoQ6vXaB1M.xfl tag:radio sig:<60 characters> m:the finished dipole
```

250 bytes — a fully described, signed, piece-verifiable file sits exactly at
the packet limit. Adding `name:` pushes it over, and that is fine: a `t:file`
splits like any packet (section 6.6), and a description is not beacon traffic.

A description packet is also the only thing that makes a file findable by
**words**. `file:` alone can be looked up by somebody who already has the hash and
by nobody else; a `t:file` gives a station something to index, so "that photo of
the dipole" is a question with an answer.

`t:file` describes and never delivers. The bytes travel however they travel
(above), and a description whose content nobody holds is a description of
something lost -- worth keeping anyway, because it says what was lost.

### 6.7.2 Listings: a folder's files, and a file's pieces

One text format serves two needs, because a folder of files and a file's pieces
are the same shape: a list of hashes with sizes. A **listing** is a UTF-8 text
file of LF-terminated lines:

```
XFL1
Uc3nRw8kFa5xPd1qGz7mYb0tJe6vHs2iLoA9XfCqK4E.gpx 18kB ridge track.gpx
nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w.jpg 240kB dipole finished.jpg
```

The first line is the magic. Every other line reuses the grammar the packets
already have: a reference (or a bare 43-character hash), a `qty` size, and —
because names contain spaces — the name last, running to the end of the line,
exactly the rule that puts `m:` last in a packet.

- **A folder listing**: `ref size name` per line, lines sorted bytewise by
  name. Sorting makes the listing deterministic: the same folder content always
  produces the same listing bytes, therefore the same hash, therefore one
  listing however many people publish it.
- **A piece list**: `hash size` per line, no name, no extension on the hash, in
  piece order — here the order IS the content. Every piece is `size:` long
  except the last. Recommended piece sizes: 64 kB, 256 kB for files of 4 MB
  and up, 1 MB for files of 64 MB and up. A 240 kB photograph's piece list is
  four lines and about 200 bytes; a 4 GB video's is 4096 lines and about
  200 kB — either way a small fraction of the file it verifies.

A listing is itself an ordinary content-addressed file: described by a
`t:file`, fetched with `cmd:file`, asked after with `q:have`, deposited with
`cmd:put`, and verified against the reference that named it. Nothing new
travels.

**A station that verified pieces 0 to 411 of 900 holds pieces 0 to 411, may
say so (section 7), and may serve them.** That is the rule that turns a crowd
of partial downloads into a working swarm: nobody has to finish before being
useful, and the most-copied pieces of a popular file are available from many
stations at once.

### 6.7.3 Syncing a folder

A folder is published by describing its listing — the existing `t:file` with
the reused `kind:` field, and nothing new:

```
t:file f:X1QZ3N ts:2026-08-08_14:26:40 file:qA7dTf2mWx9bK4pZcV0yLuJ3gRhN8sE5iDoQ6vXaB1M.xfl kind:folder count:34 size:210MB sig:<60 characters> m:Trip photos 2026
```

207 bytes. `count:` says how many files, and `size:` is the folder's TOTAL
payload — so a station knows what "everything" costs before fetching anything.

The whole flow is vocabulary this document already has. Fetch the listing
(`cmd:file` on the `.xfl` reference), read the names, sizes and hashes, then
fetch any or all members (`cmd:file` per reference, `q:have` to find nearer
holders first). Every member is verified against its own hash on arrival, so a
folder assembled from six different stations is exactly the folder that was
published.

**Sync is snapshots.** A changed folder is a new listing with a new hash,
announced with a new `t:file`. Files that did not change keep their hashes, so
a receiver holding the previous snapshot diffs two listings line by line and
fetches only what is new — incremental synchronisation with no mutation
protocol, no version numbers and nothing to negotiate. The old listing remains
a valid description of the old folder, which is what an archive wants anyway.

### 6.7.4 A small file inline

Below a certain size, describing a file costs more than sending it — the rule
of section 36.2, "send whichever is smaller", applied to content. `b:` carries
the file's bytes as base64url in the `t:file` that describes it:

```
t:file f:X1QZ3N ts:2026-08-08_14:26:40 file:Uc3nRw8kFa5xPd1qGz7mYb0tJe6vHs2iLoA9XfCqK4E.png size:240B b:iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8z9AAAAAdklEQVQ4y2P8z8BQ
```

A larger inline file splits per section 6.6 with one added rule: **`b:` splits
like `m:`, but the parts are joined with nothing** — base64url contains no
spaces, and a space would corrupt it. A 240-byte icon, signed, in three parts:

```
t:file f:X1QZ3N ts:2026-08-17_10:00:00 n:1/3 file:Uc3nRw8kFa5xPd1qGz7mYb0tJe6vHs2iLoA9XfCqK4E.png size:240B b:PtYgjmUhBel31iEl2hpChYgCfrL1spNxnyVmihA_2O76UMFxFkM_R5Kjp1vRt-1fjORS_6ilI8ihN5KXSc7Tvo_hBKqFYY_kv5ZJr3J1TWDtkwtDDb-xHKas1VOqg6YYZYn9ZhyiA4uo
t:file f:X1QZ3N ts:2026-08-17_10:00:00 n:2/3 file:Uc3nRw8kFa5xPd1qGz7mYb0tJe6vHs2iLoA9XfCqK4E.png size:240B b:RgnatmUdjAWtGSU8po-799NksnRH9ucAUsdMlHUvTCQCyEZDz_TddJ8HyS5SUkCnD8zRA9a9SkpXz9w3QlY7Zkuvqdt7s8Stqcbnr3yBdGBLEPH1qhT61qtc4xatws8phP9nhFyJfm5d
t:file f:X1QZ3N ts:2026-08-17_10:00:00 n:3/3 file:Uc3nRw8kFa5xPd1qGz7mYb0tJe6vHs2iLoA9XfCqK4E.png size:240B sig:<60 characters> b:i4PzJ59FHz5r1pY4OjE2jBMptUsGr7CmY-uCu3ZR
```

250, 250 and 215 bytes. Every field except `b:` and `n:` repeats on every
part, so any single part says whose file, which file and how big. Reassembly
is the section 6.6 procedure with the empty join: concatenate the `b:` values
in `n:` order, decode, hash, compare against `file:`. There is no offset and
no per-part checksum, because `n:` is the index and the whole-file hash is the
only integrity that matters at this size.

With these fields a part carries 140 characters of `b:` and the signed last
part 75, so nine parts carry 1195 characters: **an inline file tops out at
896 bytes.** Thumbnails, avatars, QR payloads, keys and configuration fit;
anything larger travels as section 6.7 says. The two never mix — a file is
inline or it is fetched, and a receiver that decodes `b:` checks it against
`file:` and, on a match, holds the file like any other holder.

The reason this lane exists is the bearer that has no other: on a LoRa-only
network there is no bulk connection to move bytes over, and a packet is the
only vehicle there is. 896 bytes is a real photograph thumbnail or a real
public key, and either arriving over 40 km of nothing is worth nine packets.

### 6.7.5 The BitTorrent bridge

A file can additionally be offered to stock BitTorrent clients, and the trick
is that nothing extra needs to be transmitted to arrange it. The torrent for a
file is built **deterministically**: single file, named `<digest-hex>.<ext>`,
piece length the power of two nearest `size/1024` clamped between 16 kB and
4 MB, no private flag and no source field. Two stations that hold the same
bytes therefore derive the same torrent and the same infohash independently —
the swarm address is a pure function of the content.

`ih:` (40 hexadecimal characters) carries that infohash when talking to
something that cannot derive it — a link handed to somebody's ordinary
torrent client. Between XPRS stations it is dead weight and is not sent.

The SHA-256 remains the identity throughout. The infohash addresses a swarm;
whatever the swarm delivers is verified against `file:` like bytes from any
other source, and fails like them if it lies.

---

## 7. Asking and answering

`q:` says what the sender wants back. `s:` answers using the same words.

```
q:ack        confirm this reached the device
q:read       confirm the operator read it
q:pos        send your position
q:batt       send your battery level
q:identity   send your public key
q:sign       sign a receipt confirming you read this
q:pong       reply to this reachability test
q:have       say whether you hold the file named by file:
```

Several are separated by commas. An unknown word is ignored, so `q:pos,bat,co2`
still returns position and battery from a station that has never heard of CO2.

Absence of `q:` means nothing is expected back, so silence is never ambiguous —
with one exception, and it is the common case: a direct message between two
stations that have exchanged one before is acknowledged without being asked
(section 13.7.1). Everything else still answers only what `q:` requested.

```
t:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 q:ack,read m:did you get the keys?
```

85 bytes, identifier `9821a4`.

The answers, naming that identifier in `r:`:

```
t:receipt f:X1RD89 d:X1QZ3N r:9821a4 s:ack
t:receipt f:X1RD89 d:X1QZ3N r:9821a4 s:read
```

42 and 43 bytes. `s:ack` is sent when the message reaches the device, `s:read`
when the operator reads it. A station that does not track reading sends `s:ack`
only, and the sender sees exactly which of the two requests was satisfied.

A request for data is the same exchange without a message:

```
t:request f:X1QZ3N d:X3RLY7 ts:2026-08-08_14:26:40 q:pos,batt
t:observation f:X3RLY7 d:X1QZ3N pos:38.7810,-9.2043 batt:64% ts:2026-08-08_14:26:40 s:pos,batt
```

61 and 94 bytes. A station holding only part of what was asked says so, rather
than failing:

```
t:observation f:X3RLY7 d:X1QZ3N pos:38.7810,-9.2043 ts:2026-08-08_14:26:40 s:pos
```

80 bytes: position sent, battery not available, no error packet needed.

`s:no` is the one word not in `q:`, for a request a station will not or cannot
serve at all:

```
t:receipt f:X3RLY7 d:X1QZ3N ts:2026-08-08_14:26:40 s:no
```

### 7.1 Who holds a file

`q:have` with a `file:` reference asks who holds those bytes. Broadcast, it is
the question a station asks the street before spending a fetch on somebody far
away; directed, it checks one station before asking it to serve.

```
t:request f:X1QZ3N ts:2026-08-08_14:26:40 q:have file:nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w.jpg
```

101 bytes, identifier `17d873`. A holder answers, directed, with `have:` in one
of three forms:

```
t:result f:X3RLY7 d:X1QZ3N ts:2026-08-08_14:26:41 r:17d873 s:have have:full size:240kB
t:result f:X3RLY7 d:X1QZ3N ts:2026-08-08_14:26:41 r:17d873 s:have have:412/900 size:58MB
```

86 and 88 bytes. `have:full` is the whole file. A partial holder answers the
piece bitfield as base64url, least significant bit first, **when it fits the
packet** — up to roughly 1200 pieces — and the fraction `have:412/900` when it
does not; the exact map travels with the transfer itself once one starts. A
station that holds nothing stays silent: on a broadcast ask, a hundred "no"s
would cost more than the answer is worth, and silence already says it
(section 7).

This is the radio's version of the claim a provider record makes on an
internet overlay: the same "I hold it", scoped to whoever can actually hear
the speaker — which for a fetch over the street is exactly the right scope.

55 bytes.

Any station may act on a receipt it overhears. A station holding a message for
later delivery discards its copy on hearing the matching `s:ack` **whose
signature it has verified** -- and on no other. An acknowledgement releases mail
across the whole network, so an unsigned one is a way to delete a message the
attacker never held (section 13.7.1).

---

## 8. Reserved words

`q:` and `s:` words assigned by this document: `ack`, `read`, `sign`, `pos`,
`batt`, `identity`, `pong`, `have`, `no`. Command words assigned: `history`,
`file`, `put`. Reactions assigned for `add:` and `remove:`:
`like`, `repost`. All other words are reserved. A word beginning with `z` is private, as a
key beginning with `z` is.

---

## 9. Signing and privacy

### 9.1 Signatures

`sig:` covers the whole packet with the `sig:` and `via:` fields and their
separating spaces removed. Position in the packet is therefore not significant,
and a verifier reconstructs the signed text by deletion.

**Both fields come out, and the reason for `via:` is not economy.** A relay
appends itself to `via:` (section 13), so a signature covering it would break at
the first hop and every relayed packet would read as forged -- on a network whose
whole point is relaying, and where signing is the default. The signed text is
therefore exactly the text the identifier is derived from (section 5), which
leaves one canonical form to implement rather than two.

```
t:message f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 sig:<60 characters> m:net starts in ten minutes
```

143 bytes. The identifier is `399227`, the same as the unsigned packet in
section 6.3, because signing changes neither `f:`, `ts:` nor the payload.

| State | Condition |
|---|---|
| verified | signature present, valid, signer key known |
| forged | signature present and invalid |
| unverified | signature present, signer key unknown |
| unsigned | no signature |

**`sig:` may appear on any packet, and a station signs by default.**

A callsign is a label that anyone can write (section 3). Nothing else in this
format stops a station putting `f:X1QZ3N` on a packet it did not send, and for
most traffic a signature is the only thing that does. It is 65 bytes and it
should be spent unless there is a reason not to.

Default means default and not mandatory. A sender may omit it, and a receiver
must accept an unsigned packet rather than discarding it, because the network
carries traffic from sensors with no key, from stations too small to sign, and
from software written before this section. What a receiver must not do is
present an unsigned packet as though its `f:` were established.

One exception remains, and it is not economy.

A **challenge and its response** carry their own proof: the response is signed,
and the exchange is the authentication rather than something needing it
(section 18).

Everything else is signed by default, including the smallest packets:

```
t:reaction f:X32DVA d:LISBOA r:399227 add:like sig:<60 characters>
```

111 bytes for a signed reaction, against 46 unsigned. A forged reaction
attributed to you is still an impersonation, and the extra bytes buy the same
thing they buy anywhere else.

### 9.1.1 When the signature does not fit

A signature is 65 bytes and the packet limit is 250, so a full observation can
run out of room. The weather station in section 11.3 is 193 bytes and would be
258 signed.

**Drop optional fields, never the signature.**

```
t:observation f:X3WX01 pos:38.7223,-9.1393 temp:14.2C hum:78% press:1013.2hPa wind:3.4m/s wdir:210deg type:wx ts:2026-08-08_14:26:40 sig:<60 characters>
```

197 bytes: the same station with two readings fewer, signed. A receiver
learns less and can trust what it learns, which is the better trade for a
station whose whole value is being believed.

Where the payload cannot be trimmed, split it (section 6.6) and sign the last
part, which is what a long message already does. Where neither is possible --
a single measurement that fills the packet by itself -- the sender may go
unsigned, and that is the case the "unsigned" state above exists to describe.

### 9.2 Encryption

`x:` carries the sealed body and replaces `m:`.

```
t:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 x:pQ4m9xT2vB8kR sig:<60 characters>
```

131 bytes. `t:`, `f:`, `d:` and `ts:` stay in cleartext, so an intermediate
station can route the packet, identify the recipient and release a carried copy
on the matching receipt, without reading the content.

A later cipher suite takes a new key rather than changing this one.

### 9.3 Identity

```
t:identity f:X1QZ3N ts:2026-08-08_14:26:40 k:npub1qz3n7fu9j9uenmyva7ha6x9eqwymytv2847ccv4vxdmn45y50q7h7k5f sig:<60 characters>
```

171 bytes. A receiver stores the binding and uses it to verify signed packets
from that callsign. Answers `q:identity`.

**An identity announcement is signed like everything else.** An earlier draft of
this document said it was not, on the grounds that the signature would have to be
verified with the key the packet carries and was therefore circular. That
reasoning was wrong, and the nickname below is what exposes it.

A self-signature proves the sender **holds the private key**, which is not
circular and is not nothing. Without one, anybody can rebroadcast
`t:identity f:X1QZ3N k:<the real key of X1QZ3N>` with whatever else they like
attached: the callsign still derives correctly from the key (section 3), every
check passes, and the extra fields are the attacker's. With one, they cannot,
because they do not have the private half.

What the signature does not establish is entitlement to the callsign. For an
`X1` or `X3` callsign the derivation in section 3 does that. For a callsign
issued by an authority nothing in this format does: section 18 proves that the
key holder is present, and section 9.4.2 says where entitlement is checked
instead, which is the authority's own register and not any packet.

### 9.3.1 Nicknames

`nick:` gives a callsign a human-readable name.

```
t:identity f:X1QZ3N ts:2026-08-08_14:26:40 k:npub1qz3n7fu9j9uenmyva7ha6x9eqwymytv2847ccv4vxdmn45y50q7h7k5f nick:joao sig:<60 characters>
```

181 bytes. One to sixteen characters: ASCII letters, digits, `-` and `_`. No
spaces, because no value except `m:` may contain one, and no accents, because the
whole format is ASCII. A name that needs more than that belongs in a profile
somewhere else, and this field is a label rather than a biography.

Three rules, and the third is the one that matters.

**It only counts when the signature verifies.** A receiver that cannot check the
signature shows the callsign and not the nickname. An unsigned or unverifiable
nickname is a claim by nobody.

**The newest verifiable announcement wins**, decided by `ts:`. A station changes
its nickname by announcing again.

**A nickname is never an address.** `d:` takes a callsign and only a callsign.
Nicknames are not unique, cannot be made unique without a registry this format
deliberately does not have, and two stations calling themselves `joao` is
expected rather than exceptional. A receiver that let a user address a nickname
would have built the spoofing surface that signing the rest of this section was
meant to close.

Show it as decoration next to the callsign, never instead of it.

### 9.3.2 A face and a line about yourself

A townhall of callsigns is a spreadsheet. `file:` gives an identity a picture and
`m:` a line of description, both optional and both signed with the rest:

```
t:identity f:X1QZ3N ts:2026-08-08_14:26:40 nick:joao file:nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w.jpg sig:<60 characters> m:sailing the Algarve coast
```

198 bytes. The picture is a **reference and not bytes** -- a content hash like
any other file in this format (section 6.7), fetched with `cmd:file` (section
25.2) if the receiver wants it and ignored entirely if it does not. A station
that never fetches an avatar has lost nothing but a picture.

**An identity announcement carries any subset of these fields, and a receiver
keeps, for each field, the value from the newest verifiable announcement that
carried it.** That rule is forced by arithmetic rather than chosen: the key
binding and the decoration together come to 262 bytes, which does not fit.

```
181  t:identity f:X1QZ3N ts:2026-08-08_14:26:40 k:npub1qz3n7fu9j9uenmyva7ha6x9eqwymytv2847ccv4vxdmn45y50q7h7k5f nick:joao sig:<60 characters>
198  t:identity f:X1QZ3N ts:2026-08-08_14:26:40 nick:joao file:nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w.jpg sig:<60 characters> m:sailing the Algarve coast
```

The split turns out to be the right shape anyway. The key binding is small and
must be repeated often, because a receiver that has never heard it can verify
nothing (section 18.1). The decoration is larger and changes once a year, so it
goes out rarely -- which is section 31 applied to this format's own traffic.

A packet without `k:` still verifies, against the key the receiver already holds
for that callsign. One from a station whose key is unknown is ignored, exactly as
the nickname rule above requires.

### 9.4 Permitted use by band

| Spectrum | Callsign in `f:` | Signing | Encryption |
|---|---|---|---|
| Licence-free (Bluetooth and LoRa ISM, WiFi), and the internet | any, including a self-generated `X1` or `X3` | permitted | permitted, and is the default for direct messages |
| Licensed spectrum, including the amateur bands | **only one issued by a competent authority to the operator transmitting** | permitted | not permitted on amateur bands |

Amateur regulations prohibit obscuring the meaning of a transmission. A licensed
operator using XPRS on amateur bands is bound by that rule as on any other mode
and must not transmit `x:` there.

A signature is not encryption. It leaves the text in cleartext and establishes
only authorship, so signing is permitted on amateur bands.

An implementation able to reach amateur infrastructure must refuse to transmit a
sealed body onto it.

### 9.4.1 Only an issued callsign may transmit on licensed spectrum

**Transmitting XPRS on a licensed frequency requires a callsign issued to the
operator by a competent authority, and nothing else will do.** This is the one
rule in this document that is not ours to relax: it comes from national
regulation, it applies to the person keying the transmitter, and no property of
the format changes it.

An `X1`, `X3` or `X5` callsign is derived by its holder from its own key
(section 3). No authority issued it, no register lists it, and it can be
generated by anyone in a moment. That is exactly right on licence-free spectrum, where a callsign is
a label. On licensed spectrum it identifies nobody, which is the thing an
identification requirement exists to prevent, so a packet whose `f:` is `X1`,
`X3` or `X5` **must never be originated onto a licensed frequency**. A licensed operator
transmits under the callsign on their licence, which the format already accepts
at any length and with a suffix.

This binds gateways harder than it binds people, because a gateway does it
automatically and at volume. **A station bridging licence-free traffic onto
licensed spectrum must drop packets from self-generated callsigns rather than
relay them.** Relaying one puts an unidentified transmission on the air under
the gateway operator's licence, and the operator, not the sender, answers for it.

### 9.4.2 Associating an issued callsign with a key

An operator who wants their traffic to be verifiable under their real callsign
announces the binding themselves, with the identity packet of section 9.3 and
their own callsign in `f:`:

```
t:identity f:CT1ABC ts:2026-08-08_14:26:40 k:npub1qz3n7fu9j9uenmyva7ha6x9eqwymytv2847ccv4vxdmn45y50q7h7k5f sig:<60 characters>
```

171 bytes. From then on their packets can carry `sig:` and a receiver can check
that the operator who announced that key wrote them.

**Be exact about what this proves**, because the temptation to read more into it
is strong. The self-signature proves the sender holds the private key for the
announced `npub`. It proves nothing whatever about entitlement to `CT1ABC`: an
`X1` callsign is checked against its key by arithmetic, an issued callsign has no
arithmetic relationship to any key, and this format has no registry and issues no
credentials. A second station can announce the same callsign with a different
key, and both announcements will verify.

| Question | Answered by |
|---|---|
| does the holder of this key write these packets | the signature, section 9.1 |
| is that key holder present right now | a challenge, section 18, on licence-free spectrum only |
| was this callsign issued to this person | **nothing in XPRS**; the authority's public register, out of band |

The last row is the honest one. Most administrations publish a searchable
licence register, and checking a name and locality against it is a human act
performed once, not a protocol exchange. What XPRS contributes is the part that
register cannot give you: that this packet, now, came from the same key as the
one you checked.

A receiver that has verified a binding out of band may mark it as such in its
own records. **It must never transmit that verdict as though it were a fact
about the callsign**, because a claim that a callsign is licensed carries far
more weight than the sender's opinion deserves.

### 9.4.3 What signing costs on the amateur bands

Amateur regulations prohibit obscuring the meaning of a transmission, and a
signature does not obscure it. `sig:` is detached: the message stays in clear in
`m:`, legible to any receiver, and the signature sits beside it as evidence about
authorship. Anyone monitoring reads the traffic exactly as they would unsigned.

```
t:message f:CT1ABC d:G0XYZ ts:2026-08-08_14:26:40 sig:<60 characters> m:net starts at eight on the repeater
```

152 bytes, lawful on an amateur band, and verifiable.

Three consequences follow, and they are the price of operating there:

- **`x:` is never transmitted on amateur spectrum.** Sealing a body obscures
  meaning, which is the prohibited act.
- **A challenge cannot be put on amateur spectrum**, because the exchange in
  section 18 works by sealing a nonce. Prove a callsign on licence-free spectrum
  or over the internet, then carry the result to the band.
- **Signing is authorship, not confidentiality.** On an amateur band XPRS can
  tell a receiver who wrote a packet and can never keep a third party from
  reading it. An operator wanting privacy uses licence-free spectrum, where
  section 9.2 applies in full.

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
t:observation f:X1BOA3 pos:38.6902,-9.4012 spd:6kt dir:275deg o:262degm type:boat ts:2026-08-08_14:26:40
```

104 bytes: making 6 knots over the ground towards 275 true, with the bow held
at 262 magnetic to hold that track against the current.

A station with only a satellite fix sends `dir:` alone, which is the common
case. A station that is stationary has no course and may still have a heading:

```
t:observation f:X1CAR7 pos:38.7231,-9.1402 o:212degm type:car ts:2026-08-08_14:26:40
```

84 bytes.

### 10.3 Weather

| Key | Type | Meaning | Quantity |
|---|---|---|---|
| `temp` | `qty` | air temperature, outdoors | temperature |
| `hum` | `qty` | relative humidity, outdoors | proportion |
| `intemp` | `qty` | air temperature, indoors | temperature |
| `inhum` | `qty` | relative humidity, indoors | proportion |
| `press` | `qty` | barometric pressure, station level | pressure |
| `wind` | `qty` | wind speed, sustained | speed |
| `wdir` | `qty` | wind direction, the direction it blows from | angle |
| `gust` | `qty` | wind gust, peak | speed |
| `rain1` | `qty` | rainfall, previous hour | rainfall |
| `rain24` | `qty` | rainfall, previous 24 hours | rainfall |
| `solar` | `qty` | solar irradiance | irradiance |

A station reports in the unit it works in and says which it is (section 10.8).
A station holding Fahrenheit sends `temp:57.6F`; it does not convert, and the
receiver does.

**`temp:` and `hum:` are outdoors. `intemp:` and `inhum:` are indoors.** A key
beginning with `in` is the indoor counterpart of the key that follows it.

They are separate keys rather than one key with a flag saying where the sensor
sat, because a station commonly has both and would otherwise need two packets to
report what it measured at one moment:

```
t:observation f:X3WX01 pos:38.7223,-9.1393 temp:14.2C hum:78% intemp:21.5C inhum:54% press:1013.2hPa type:wx ts:2026-08-08_14:26:40
```

131 bytes: 14.2 outside, 21.5 in the room, one timestamp, one transmission.

A station with only an indoor sensor sends only the indoor keys, and the reading
is no longer mistaken for outside air:

```
t:observation f:X3WX01 intemp:21.5C inhum:54% age:60
```

52 bytes.

A station with one sensor that does not know where it sits sends `temp:`.
Outdoors is the default because it is the reading another station can use: an
outdoor temperature describes the air a neighbour is standing in, an indoor one
describes a room only its owner cares about.

Pressure has no indoor form. The difference across a wall is smaller than the
instrument's error, and `press:` is already defined at station level.

### 10.4 At sea

| Key | Type | Meaning | Quantity |
|---|---|---|---|
| `wave` | `qty` | significant wave height | distance |
| `swell` | `qty` | swell period | duration |
| `seatemp` | `qty` | sea surface temperature | temperature |
| `vis` | `qty` | horizontal visibility | distance |

```
t:observation f:X1BOA3 pos:38.6902,-9.4012 wave:1.8m swell:9s seatemp:18.4C vis:2km wind:11m/s type:sailboat ts:2026-08-08_14:26:40
```

131 bytes.

These decide whether a passage happens, and nothing else in the format carries
them. Wind and pressure describe the air; a two-metre swell at nine seconds is a
different sea from a two-metre swell at four, and the number that tells them
apart is the period.

`vis:` is a distance rather than a category, so `vis:200m` in fog and `vis:20km`
on a clear day are the same measurement rather than two vocabularies.

A vessel sends what its instruments give it and omits the rest:

```
t:observation f:X1BOA3 pos:38.6902,-9.4012 wave:1.8m seatemp:18.4C type:boat ts:2026-08-08_14:26:40
```

99 bytes.

### 10.5 Telemetry and station type

| Key | Type | Meaning | Quantity |
|---|---|---|---|
| `batt` | `qty` | battery charge | proportion |
| `volt` | `qty` | supply voltage | voltage |
| `link` | `enum` | which bearer a reading is about (section 10.6) | |
| `busy` | `qty` | proportion of the last hour that bearer was occupied (section 10.6) | proportion |
| `txtime` | `qty` | proportion of the last hour this station transmitted | proportion |
| `hears` | `path` | callsigns heard directly, most relevant first (section 10.6.3) | |
| `peers` | `int` | how many stations are reachable in total (section 10.6.4) | |
| `mail` | `int` | messages held for other stations (section 10.6.5) | |
| `rssi` | `qty` | received signal strength | signal power |
| `snr` | `qty` | signal-to-noise ratio | signal ratio |
| `uptime` | `qty` | how long the station has run without interruption | duration |
| `lifetime` | `qty` | how long the station has run in total, across every restart | duration |
| `odometer` | `qty` | distance travelled over the station's service life | distance |
| `type` | `enum` | what the station is or is riding on, from the set in section 14.2 | |

Radiation readings — ionizing and electromagnetic — are their own family,
section 10.5.1.

`rssi` and `snr` describe the radio path a packet arrived on and are reported by the
receiver, in a `pong` reply. A station does not transmit its own received signal
strength.

`uptime` and `lifetime` are the station's account of its own stability, for
whoever is deciding whether to route through it or nominate it a mailbox.

```
t:observation f:X3RLY7 link:ble peers:4 mail:3 uptime:26h lifetime:38day
```

72 bytes. `uptime` resets to zero at every restart, which is the point: a
station that reboots hourly cannot claim otherwise for long. `lifetime` is
**accumulated service time** — the sum of every period the station has been
running since it first kept records — so it survives restarts and needs no
wall clock, which a station reporting `epoch:` (section 10.7) does not have.
It is not the calendar age of the hardware: a dongle powered one hour a day
for a year reports `lifetime:15day`, and that is the honest figure for a
station whose value is being on the air.

Both are claims, not measurements a receiver can check. Like `serve:`
(section 24.3), they say what the sender believes about itself; a receiver
weighs them against what it has observed. Coarse figures are the expected
form — `uptime:26h` rather than `uptime:94340s` — because the reading changes
by the second while its meaning changes by the hour, and the bytes are better
spent elsewhere.

`odometer:` is the moving station's counterpart to `lifetime:`: how far it has
travelled over its service life, in any distance unit (section 10.9). The word
is the instrument's own, so a reader needs no glossary, and the key fits the
eight characters a key is allowed exactly.

```
t:observation f:X1SHIP pos:38.7012,-9.1523 spd:12kt odometer:15420nmi lifetime:210day ts:2026-08-13_10:00:00
```

108 bytes: a ship with 15,420 nautical miles behind it across a 210-day
service record. A car reports `odometer:48213km`. Like `lifetime:` it is the
station's own account — a receiver weighs it, not verifies it.

An observation carries a note in `m:`, the same key a message uses.

### 10.5.1 Radiation

Radiation a station can measure and a person would want to know about:
ionizing radiation from nuclear sources, and the electromagnetic fields of
transmitters and power systems. One family, one discipline, built to grow.

| Key | Type | Meaning | Quantity |
|---|---|---|---|
| `dose` | `qty` | ambient ionizing dose rate — what a Geiger counter shows | dose rate |
| `lifedose` | `qty` | ionizing dose accumulated since the station's records began | dose |
| `radon` | `qty` | radon activity concentration in the air | activity concentration |
| `rf` | `qty` | radio-frequency power density | power density |
| `efield` | `qty` | electric field strength | electric field |
| `mfield` | `qty` | magnetic flux density | magnetic flux density |

```
t:observation f:X3WX01 pos:38.7223,-9.1393 dose:0.14uSv/h ts:2026-08-13_10:00:00
t:observation f:X3WX01 dose:0.14uSv/h lifedose:1.2mSv lifetime:38day ts:2026-08-13_10:00:00
t:observation f:X3WX01 rf:120uW/m2 efield:1.8V/m mfield:0.3uT ts:2026-08-13_10:00:00
t:observation f:X3LAB1 radon:120Bq/m3 ts:2026-08-13_10:00:00
```

80, 91, 84 and 60 bytes. Normal background dose rate is roughly `0.1uSv/h` to
`0.3uSv/h`, so `dose:2.5uSv/h` reads as anomalous on sight — which is the
point of putting the unit on the value rather than in a manual.

**These are instrument readings, never health claims.** A receiver may plot
them, compare them against its own idea of background, and decide what it
thinks; the sender asserts only what its instrument showed. And an absent key
means *not measured*, never *safe* — the same rule `cw:` states in section
4.6, for the same reason.

`lifedose` pairs with `lifetime:` exactly as it reads: everything the station
absorbed over the service record it is already reporting. `dose` is the now,
`lifedose` is the history.

A telemetry stream is not an alarm. A station watching a **sustained**
anomaly raises `t:warning kind:radiation` (section 16), which carries the
nine-relay budget an emergency deserves; the observation stream keeps its
ordinary three and its ordinary cadence (section 31.1).

**Counts per minute are refused.** A CPM figure is a property of the tube
that produced it and means nothing without out-of-band calibration, which
design rule 6 forbids. A station converts to dose rate before transmitting,
using its own tube's factor — the one party that reliably knows it.

**Growing the family** costs what section 4.9 says and nothing more: a new
reading takes a new key in this table and its unit family in section 10.9
with a canonical unit — no new packet type, no version, no negotiation. A
reading not yet adopted here travels under a `z`-key until it is. Candidates
already visible from here: an ultraviolet index, and separated beta and
neutron dose for stations with instruments that discriminate.

### 10.6 The radio itself

A station can measure the air, its battery and where it is. It can also measure
**the channel it is sitting on and the stations it can hear**, and those two
readings are what the rest of this format quietly assumes somebody has.

```
t:observation f:X3RLY7 ts:2026-08-08_14:26:40 link:lora busy:41% txtime:6%
t:observation f:X3RLY7 ts:2026-08-08_14:26:40 link:lora hears:X1QZ3N,X32DVA,CT1ABC-9
t:observation f:X3RLY7 ts:2026-08-08_14:26:40 link:ble hears:X1PZ4Q,X32DVA
```

74, 84 and 74 bytes. No new packet type, because design rule 5 settles it: one
type carries every kind of observation, and how busy a bearer is is an
observation about a radio exactly as temperature is one about the air.

| Key | Reading |
|---|---|
| `link` | which bearer every reading in this packet is about |
| `busy` | proportion of the last hour that bearer was occupied by anybody |
| `txtime` | proportion of the last hour **this station** was transmitting |
| `hears` | callsigns heard directly on that bearer, most relevant first |
| `peers` | how many are reachable in total, so a truncated `hears:` is honest |
| `mail` | messages held for others; omitted when none. A neighbour that can reach a recipient opens a session rather than everyone airing every message |

**The window is one hour and is not stated on the wire**, because two stations
reporting `busy:41%` have to mean the same thing for the number to be worth
transmitting. A station that has been listening for less than an hour reports
what it has and does not scale it up.

### 10.6.1 A reading without a bearer is not a reading

**`link:` is required whenever `busy:`, `txtime:` or `hears:` appears**, and a
packet carrying any of them without it is discarded rather than guessed at.

This is not pedantry. A station in this format is not one radio on one channel:
the same phone may be on LoRa, Bluetooth, WiFi Direct, a LAN and the internet at
once, and those bearers have nothing in common. On LoRa occupancy is a legal duty
cycle measured in seconds of owed silence; on a LAN it is close to meaningless; on
Bluetooth what binds is scan windows rather than airtime. A single number
averaged across them is not a quantity at all, and `busy:41%` from a gateway
would be a statement no receiver could act on and every receiver would graph.

`hears:` has the same defect for a better reason. Hearing `X1PZ4Q` over
Bluetooth means it is in the room; hearing it over LoRa means it is somewhere in
ten kilometres of countryside. Recorded identically, those two facts are worse
than either alone.

So a station reports **once per bearer** and says nothing it cannot mean:

| `link:` | The bearer |
|---|---|
| `lora` | LoRa on an ISM band |
| `ble` | Bluetooth Low Energy |
| `wifi` | 2.4 or 5 GHz WiFi, including WiFi Direct and WiFi Aware |
| `halow` | 802.11ah, sub-GHz WiFi |
| `lan` | a wired or local network the station is attached to |
| `internet` | reached through a gateway, wherever that gateway is |
| `vhf` | VHF packet |
| `uhf` | UHF packet |
| `hf` | HF |
| `cb` | Citizens' Band |
| `pmr` | PMR446 and its regional equivalents |
| `satellite` | any satellite path |
| `other` | something not in this list, named in `m:` |

The list is the one section 31.1 and `spectrum.md` already work through; this key
only gives it a name on the wire.

**Section 31.1 becomes computable because of this.** It already says a station is
bound by the strictest bearer it transmits on, and with one undifferentiated
number nothing could tell which bearer that was. Per-bearer readings can. A phone
bridging LoRa and the internet publishes `link:lora busy:41%` and, if it cares,
`link:internet busy:2%` -- two true statements where a single average would have
been one false one.

### 10.6.2 Why `busy:` matters more than it looks

Section 31 asks every station to be disciplined about airtime and gives it
nothing to measure. `busy:` is that measurement, and it changes politeness from a
rule of thumb into a decision.

A duty cycle is a legal limit on **one** transmitter. It says nothing about
whether forty other stations are already using the channel, and a station obeying
its own 1 percent perfectly can still be the packet that collides with a call for
help. A shared channel is a shared resource and the only station that can see the
whole of it is the one listening to it.

So a station that hears `busy:` climbing should slow down what is discretionary
-- beacons, status posts, history replays -- before the channel stops working for
what is not. **`urg:` (section 13.5) decides what survives that decision**, and
this is the reading that tells a station when to start making it.

`txtime:` is the honest half of the same measurement. A station reporting
`busy:60%` while contributing `txtime:45%` of it has identified the problem, and
it is itself.

### 10.6.3 `hears:` is what makes a mesh diagnosable

`hears:` is one station's answer to "who can you actually reach right now",
directly, without a relay.

It is worth its bytes three times over. It says **why a mesh is broken** -- a
station nobody lists is a station nobody hears, which is a different fault from
one that is heard but never answers. It says **who to route through**, since a
carrier that lists the recipient is one hop from delivering. And it is the best
evidence there is for choosing `hold:` in a `t:mailbox` declaration (section
13.12): the right mailbox is a station that other people list as heard.

Three limits, stated because a topology map invites over-reading:

- **Directly heard only.** A callsign reached through a relay does not belong in
  `hears:`, or the list stops meaning anything.
- **Most relevant first**, so a truncated list still carries the useful half.
  What counts as relevant is the sender's judgement -- signal now, uptime,
  whether the station is powered and stationary -- because a passing phone that
  happens to be loud is not more useful than the solar relay on the hill, and no
  single criterion suits every station. Signal per callsign is deliberately not
  carried: it would need a compound value this format does not have.
- **It is a claim like any other.** A station may list callsigns it cannot hear,
  and nothing here detects that. What it buys an attacker is being chosen as a
  carrier, which is why `hears:` informs a choice and never compels one.

The truncation of section 10.6.4 is **per bearer**, not a property of the
list. The advert channel cuts `hears:` to what fits one advert; the same
observation pushed to an indexer (section 36) carries the full list, over
section 6.6 parts when a busy gateway hears more than one packet holds —
about twenty-five callsigns fit a packet, two hundred fit nine. `peers:`
stays the true total either way, so a cut list is always visibly cut.

### 10.6.4 `peers:` says how many were left out

```
t:observation f:X1A67X link:ble peers:12 hears:X1RD89,X32DVA,CT1ABC-9
```

69 bytes. `peers:` is how many stations the sender can reach directly; `hears:`
is the ones that fitted. **A busy street will not fit** -- about 29 six-character
callsigns reach the 250-byte limit, and a shared bearer will offer less than
that.

Without the count, a truncated list is a lie by omission: a reader cannot tell
"these three are all there is" from "these three of forty". With it, a station
that is one of thirty knows to ask rather than assume, and a client can say
"3 of 12 shown" instead of drawing a map that is quietly wrong.

`peers:` counts what `hears:` would have listed in full, so the two always agree
when nothing was dropped, and `peers:` is never smaller than the list.

### 10.6.5 `mail:` says there is something to collect

```
t:observation f:X1A67X link:ble peers:12 mail:3 hears:X1RD89,X32DVA,CT1ABC-9
```

76 bytes. `mail:` is how many messages this station is holding **for other
people** (section 13.4) and would hand over if asked. It is omitted when there
is nothing, because a field that is almost always `0` is a field not worth
transmitting.

**This is what makes carrying mail cheap.** The alternative is what it replaces:
airing every carried message as its own repeating broadcast, so that a passer-by
might catch one. That spends the channel on messages most listeners have no use
for, and spends it again every time the copy is refreshed. A beacon is on the
air anyway. Saying "I have three" in six bytes lets a station that can actually
reach one of the recipients ask for them directly, and lets everybody else
ignore it.

So the sequence is: a station beacons `mail:3`; a neighbour that recognises a
recipient -- because it is one, or because its own `hears:` covers one -- opens a
session and takes custody; everybody else spends nothing. The count is a hint
for deciding whether a session is worth the battery, not a promise about what
the session will contain.

Hearing is also often **asymmetric** -- a handheld hears a hilltop repeater that
cannot hear it back. Two stations listing each other can reach each other; one
listing the other cannot, and a client drawing a map should show the difference.

### 10.7 Stations without a clock

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

### 10.8 Units of measure

**Every measurement carries its unit, immediately after the number and with no
space between them.**

```
alt:3048m    spd:48km/h    temp:14.2C    press:1013.2hPa    rain1:0.4mm
```

A person reads the value and the unit together, with no table to consult and
nothing to remember about which key means what.

The unit is **required**, not optional. A bare number is not a measurement, it
is a malformed value, and it is skipped like any other. This is the rule that
separates XPRS from APRS: APRS units are implicit and positional, so a receiver
that assumes the wrong one is never told it guessed. Here there is nothing to
guess.

A sender transmits in the unit it works in. A boat reports knots, an aircraft
reports feet and knots, a European car reports km/h, an American weather station
reports Fahrenheit and inches of mercury:

```
t:observation f:X1BOA3 pos:38.6902,-9.4012 spd:6kt dir:275deg type:boat ts:2026-08-08_14:26:40
t:track f:CT1ABC-9 seq:3 pos:38.9012,-9.0021 alt:10000ft spd:250kt dir:47deg type:airplane ts:2026-08-08_14:26:40
t:observation f:X3WX01 pos:38.7223,-9.1393 temp:57.6F hum:78% press:29.92inHg wind:7.6mph type:wx ts:2026-08-08_14:26:40
```

94, 113 and 120 bytes.

### 10.9 The permitted units

| Quantity | Units | Canonical |
|---|---|---|
| distance, altitude | `m`, `km`, `ft`, `mi`, `nmi` | `m` |
| speed | `m/s`, `km/h`, `mph`, `kt` | `m/s` |
| angle | `deg`, `degm` | `deg` |
| temperature | `C`, `F` | `C` |
| pressure | `hPa`, `inHg` | `hPa` |
| rainfall | `mm`, `in` | `mm` |
| duration | `s`, `min`, `h`, `day`, `week` | `s` |
| frequency | `Hz`, `kHz`, `MHz`, `GHz` | `Hz` |
| transmit power | `W`, `mW`, `kW`, `dBm` | `W` |
| irradiance | `W/m2` | `W/m2` |
| voltage | `V` | `V` |
| proportion | `%` | `%` |
| signal power | `dBm` | `dBm` |
| signal ratio | `dB` | `dB` |
| dose rate | `nSv/h`, `uSv/h`, `mSv/h` | `uSv/h` |
| dose | `uSv`, `mSv`, `Sv` | `uSv` |
| activity concentration | `Bq/m3`, `pCi/L` | `Bq/m3` |
| power density | `uW/m2`, `mW/m2`, `W/m2` | `W/m2` |
| electric field | `V/m`, `kV/m` | `V/m` |
| magnetic flux density | `nT`, `uT`, `mT`, `mG` | `uT` |

`deg` is degrees true and `degm` is degrees magnetic. The difference is not
cosmetic: magnetic declination exceeds 20 degrees in parts of the world and
changes with the year, so a bearing whose reference is assumed is a bearing that
is wrong by an amount nobody can recover. A station reports whichever its
instrument gives it and says which that was.

`mG` and `pCi/L` are in the radiation families for the same reason: cheap EMF
meters read milligauss and radon reports in some countries come in picocuries
per litre, and the station's job is to report what its instrument showed, not
to convert it. Conversion is the receiver's (1 mG = 0.1 uT; 1 pCi/L = 37
Bq/m3).

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
t:observation f:X1QZ3N pos:38.72,-9.14 age:30
```

45 bytes.

Normal fix with a clock:

```
t:observation f:X1QZ3N pos:38.7223,-9.1393 ts:2026-08-08_14:26:40
```

65 bytes.

Five decimals of arithmetic, eight metres of measured accuracy:

```
t:observation f:X1QZ3N pos:38.72231,-9.13934 acc:8m ts:2026-08-08_14:26:40
```

74 bytes.

### 11.2 Movement

Person on foot:

```
t:observation f:X1QZ3N pos:38.7223,-9.1393 alt:87m type:foot spd:1.4m/s dir:212deg ts:2026-08-08_14:26:40
```

105 bytes.

Vehicle, with a note:

```
t:observation f:X1CAR7 pos:38.7231,-9.1402 alt:87m spd:13.4m/s dir:212deg acc:8m type:car ts:2026-08-08_14:26:40 m:heading south on the N8
```

138 bytes.

Balloon ascending at 4.8 m/s through 11240 m:

```
t:observation f:X3BAL1 pos:38.9012,-9.0021 alt:11240m climb:4.8m/s spd:9.2m/s dir:47deg type:balloon ts:2026-08-08_14:26:40
```

123 bytes.

Vessel under way, no altitude:

```
t:observation f:X1BOA3 pos:38.6902,-9.4012 spd:3.1m/s dir:275deg type:boat ts:2026-08-08_14:26:40
```

97 bytes.

### 11.3 Weather

Station with three sensors:

```
t:observation f:X3WX01 pos:38.7223,-9.1393 temp:14.2C hum:78% press:1013.2hPa type:wx ts:2026-08-08_14:26:40
```

108 bytes.

Every defined weather field plus battery, fourteen fields:

```
t:observation f:X3WX01 pos:38.7223,-9.1393 temp:14.2C hum:78% press:1013.2hPa wind:3.4m/s wdir:210deg gust:7.1m/s rain1:0.4mm rain24:12.6mm solar:640W/m2 batt:96% type:wx ts:2026-08-08_14:26:40
```

193 bytes, leaving 65 for fields not yet defined. It is the longest packet in
this document.

Indoor sensor with no position and no clock, using the indoor keys so the
reading is not taken for outside air. Position is omitted rather than sent as
zero:

```
t:observation f:X3WX01 intemp:21.5C inhum:54% age:60
```

52 bytes.

### 11.4 Telemetry

Unattended node reporting power state:

```
t:observation f:X3RLY7 pos:38.7810,-9.2043 alt:210m batt:64% volt:12.9V type:node ts:2026-08-08_14:26:40
```

104 bytes.

### 11.5 Emergency

A call for help is its own packet type, not an observation with a flag on it
(section 15):

```
t:sos f:X1QZ3N pos:38.7223,-9.1393 acc:6m kind:medical ts:2026-08-08_14:26:40 m:broken leg, cannot walk
```

103 bytes, identifier `bfa3f1`. Any station may answer:

```
t:receipt f:X32DVA d:X1QZ3N r:bfa3f1 s:ack
```

42 bytes.

### 11.6 Reachability

```
t:ping f:X1QZ3N d:X3RLY7 ts:2026-08-08_14:26:40
t:pong f:X3RLY7 d:X1QZ3N ts:2026-08-08_14:26:40 rssi:-92dBm snr:7.5dB
```

47 and 69 bytes. The reply reports the signal the test arrived with, which is
the receiver's measurement, not the sender's.

### 11.7 Reading a packet

```
t:observation f:X3RLY7 pos:38.7810,-9.2043 alt:210m temp:11.8C hum:88% press:1008.4hPa type:node ts:2026-08-08_14:26:40
```

119 bytes.

| Field | Type | Reading |
|---|---|---|
| `t:observation` | `enum` | an observation; a station filtering for messages stops here |
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
1  t:message f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 m:net starts in ten minutes
2  t:message f:X1RD89 d:LISBOA ts:2026-08-08_14:36:00 r:399227 m:I'll be late, start without me
3  t:reaction f:X32DVA d:LISBOA r:399227 add:like
```

78, 92 and 46 bytes. Packet 1 transmits no identifier; every receiver computes
`399227` from its sender, time and text. Packets 2 and 3 name that value.
Packet 2 has its own computed identifier and can be replied to in turn.

### 12.2 Direct message with both receipts

```
1  t:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 q:ack,read m:did you get the keys?
2  t:receipt f:X1RD89 d:X1QZ3N r:9821a4 s:ack
3  t:receipt f:X1RD89 d:X1QZ3N r:9821a4 s:read
```

85, 42 and 43 bytes. Packet 1 asks for two things by name and packets 2 and 3
answer with the same names.

### 12.3 Request and partial answer

```
1  t:request f:X1QZ3N d:X3RLY7 ts:2026-08-08_14:26:40 q:pos,batt
2  t:observation f:X3RLY7 d:X1QZ3N pos:38.7810,-9.2043 ts:2026-08-08_14:26:40 s:pos
```

61 and 80 bytes. The station has no battery reading. It answers with what it
has and says which request that satisfied, so the asker is not left waiting.

### 12.4 A long group message

```
1  t:message f:X3RLY7 d:LISBOA ts:2026-08-08_14:26:40 n:1/3 m:The repeater on the hill is down.
2  t:message f:X3RLY7 d:LISBOA ts:2026-08-08_14:26:40 n:2/3 m:We swapped the antenna feed this morning
3  t:message f:X3RLY7 d:LISBOA ts:2026-08-08_14:26:40 n:3/3 m:and it is back up, but only just.
```

92, 99 and 92 bytes. Reassembly is keyed on `(X3RLY7, 2026-08-08_14:26:40)`.
Joined with one space between parts:

```
The repeater on the hill is down. We swapped the antenna feed this morning and it is back up, but only just.
```

If part 2 never arrives, the set is discarded after 10 minutes and nothing is
displayed.

### 12.5 Clockless weather station anchored by a neighbour

```
1  t:observation f:X3WX01 pos:38.7223,-9.1393 temp:14.1C hum:80% epoch:7.3600
2  t:observation f:X3WX01 pos:38.7223,-9.1393 temp:14.2C hum:78% epoch:7.4210
   A receiver holding a clock records: epoch 7 heard at 2026-08-08_14:26:40.

3  t:observation f:X3WX01 pos:38.7223,-9.1393 epoch:7.9930 ts:2026-08-08_14:26:40
   The station has obtained the time and anchors epoch 7 for all receivers.

4  t:observation f:X3WX01 pos:38.7223,-9.1393 temp:15.0C hum:74% ts:2026-08-08_14:36:00
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
t:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 q:ack m:meet at the bridge at six
t:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 via:X32DVA q:ack m:meet at the bridge at six
t:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 via:X32DVA,CT1ABC-9 q:ack m:meet at the bridge at six
t:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 via:X32DVA,CT1ABC-9,X3RLY7 q:ack m:meet at the bridge at six
```

84, 95, 104 and 111 bytes: as sent, then after each of three relays. The
recipient reads that the message came from `X1QZ3N` and travelled through
`X32DVA`, `CT1ABC-9` and `X3RLY7` in that order.

The hop count is not transmitted. It is the number of callsigns in `via:`, which
every station can count for itself, and a packet with no `via:` has taken no
hops.

The identifier is `de9780` in all four. Both the identifier and the signature are
computed with `via:` removed (sections 5 and 9.1), so relaying alters neither,
and a station that already holds the message recognises the repeat and does not
display it twice.

### 13.1 How far a packet travels

A relay forwards a packet only while `via:` holds fewer callsigns than the limit
for that packet type:

| Packet type | Relays |
|---|---|
| `sos`, `warning` | 9 |
| everything else | 3 |

The limit belongs to the type rather than to a field. A sender cannot ask the
network for more of its airtime than its traffic warrants, and an emergency does
not have to remember to ask: `sos` and `warning` travel nine relays because
they are the packets worth spending a shared channel on, and a chat message travels
three because it is not.

### 13.2 Loops

**A station that finds its own callsign in `via:` does not relay the packet**,
whatever the count says. The limit bounds how far a packet travels; the path
prevents it from travelling in a circle, and neither substitutes for the other.

A relay also drops a packet it has already relayed within the last few minutes,
identified by the identifier of section 5. Two digipeaters in range of each
other otherwise trade the same packet until the limit is reached, which is legal
under the rules above and still a waste of the channel.

### 13.2.1 When to re-air

The rules above say whether a packet may be relayed. They do not say **when**,
and on a shared bearer that is the difference between one transmission and five.

Every station in range hears the same packet at the same moment, and every one
of them that is willing to relay it is ready to transmit in the same instant.
On a LAN they collide as duplicates; on a radio they collide as radio.

So a station **waits a short random moment before re-airing**, and **drops its
copy if it hears the packet again during that wait**. Somebody else was closer
to the front of the queue; the packet is already travelling and a second copy
adds nothing but noise.

The wait is a fraction of a second on a fast bearer and longer on a slow one --
what matters is that it is random, so that two stations do not choose the same
instant, and that hearing the packet cancels it.

This works without a new field because a section 5 identifier is computed with
`sig:` and `via:` removed: the same packet relayed by a different station has
the same identifier. "Somebody already said this" is decidable from what is on
the air.

### 13.3 Carried messages

A carrier holding a message for a station that is not currently reachable
follows the same rules: it appends itself to `via:` when it finally transmits.

The recipient's `s:ack` releases carriers still holding a copy. A station that
overhears a receipt for a message it is carrying discards its copy, which is why
a receipt is worth repeating even after the sender has seen it.

---

### 13.4 Carrying toward a place

A message addressed to someone no path reaches, and whom no carrier knows, can
still arrive if it says where it is going.

```
t:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 dest:37.98,23.73 near:50km until:2026-09-08_00:00:00 q:sign m:are you still in Athens in September?
```

150 bytes: Lisbon to Athens, 2852 km, with nothing in between.

| Key | Meaning here |
|---|---|
| `dest:` | where the packet is bound |
| `near:` | how close counts as arrived |
| `until:` | when it stops being worth carrying |
| `urg:` | how much it is worth carrying |
| `via:` | who has carried it, as everywhere else |

`near:` is a separate key from `rad:` and not a second meaning for it. `rad:`
always describes the area a subject occupies -- a fire, a flood, how far a
station will travel to deliver. `near:` always describes how close to `dest:` is
close enough. A warning about a fire being carried to a town needs both at once
and they are different numbers (section 13.8).

**A carrier accepts a copy only if it expects to reduce the distance to
`dest:`.** That is the whole routing rule. A station driving to Madrid is 483 km
closer to Athens and takes it; one sailing to the Azores is not and does not. A
carrier already in `via:` does not take it again, and a carrier inside `near:`
stops carrying and starts airing it normally, because it has arrived.

A packet with `dest:` is **not** bound by the three-relay limit of section 13.1.
Three relays do not cross a continent. It is bound by `until:` instead, which is
why `until:` is required here and optional everywhere else: a carried packet with
no expiry is litter that outlives the reason it was sent.

**`until:` is never more than one year after `ts:`.** A packet still being
carried a year later is not in transit, it is lost, and a network that cannot
say so accumulates the difference for ever.

There is no copy limit in the format. Each carrier decides what to hold, and
`store-and-forward.md` already bounds that with a per-device quota and eviction
by priority, so a limit here would duplicate one the carrier already enforces and
cannot be trusted to obey anyway.

### 13.5 Urgency

`urg:` takes one of `low`, `normal`, `high`, `urgent`. It is what a carrier
sorts by when its store is full and something has to be dropped.

It is a request, not an instruction. A carrier is free to ignore it, to carry
only `low` traffic for its own reasons, or to distrust a station that marks
everything `urgent` -- and stations will. `urg:` earns its byte because the
alternative is a carrier choosing by arrival order, which is worse for everyone.

An `sos` is not marked `urgent`; it is an `sos`, and section 13.1 already gives
it nine relays. `urg:` is for ordinary traffic that happens to matter.

### 13.6 What a carrier can read

A carried packet passes through strangers. The envelope is what they need and
the body is not:

```
t:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 dest:38,24 near:200km urg:high until:2026-09-08_00:00:00 x:<64 characters> sig:<60 characters>
```

239 bytes. `dest:`, `near:`, `urg:` and `until:` stay in cleartext because a
carrier cannot route without them. `m:` is replaced by `x:`, sealed to the
recipient's key, so every carrier can decide whether to carry it and none can
read it. This is the same rule as section 9.2 and needs no new mechanism.

A sealed body is longer than the text it replaces, so a long carried message is
split into parts (section 6.6). Every part repeats the routing keys, since a
carrier may hold one part and not another.

**`dest:` tells every carrier roughly where your correspondent is**, and `d:`
already told them who. Coarsen it deliberately: `dest:38,24 near:200km` says
"somewhere around Athens" and is 2 decimal places short of a street. Section 10.1
ties decimal places to precision, and here that is a privacy control rather than
an accuracy claim.

### 13.7 Signed receipts

`q:sign` asks the recipient to sign an acknowledgement. It is a person agreeing
that they read something, not a device reporting that bytes arrived:

```
t:receipt f:X1RD89 d:X1QZ3N ts:2026-08-20_09:12:00 r:766d3e s:sign dest:38.72,-9.14 near:50km until:2026-10-01_00:00:00 sig:<60 characters>
```

184 bytes. `r:` names the original message -- `766d3e`, computed from its sender,
timestamp and text -- and `sig:` signs the receipt, which covers `f:` and `r:`
together (section 9.1). The result is evidence that the holder of `X1RD89`'s key
acknowledged that exact message, and it is checkable by anyone holding the
public key, not only by the sender.

The receipt carries its own `dest:` and `until:`, because it has to hitchhike
home the same way the message came.

| `s:` | Means | Signed |
|---|---|---|
| `ack` | it reached a device | **by default** (section 13.7.1) |
| `read` | it was opened | **by default** (section 13.7.1) |
| `sign` | a person acknowledged it | **required** |

**An `s:sign` receipt without a valid `sig:` is not a signed receipt.** A receiver
discards it rather than showing it as one, because the whole point of the state
is the signature, and a state that can be claimed without proof is worth less
than no state at all.

A signed receipt can be replayed by anyone who heard it, and that is harmless: it
names one message and says one thing, so a second copy asserts exactly what the
first did.

### 13.7.1 Receipts without asking

A direct message between two stations that have exchanged one before is
acknowledged automatically. Neither operator turns anything on, and the sender
does not have to remember `q:ack`:

```
t:message f:X1RD89 d:X1A67X ts:2026-08-12_17:28:52 m:on my way
t:receipt f:X1A67X d:X1RD89 r:40f357 s:ack
```

62 and 42 bytes. `r:40f357` is the message's identifier (section 5), so the
receipt costs two thirds of what it confirms and names it exactly.

This exists because the alternative is a message that fails in silence. A
station that hands a packet to a radio and hears nothing back cannot tell
delivery from loss, so it cannot retry, and a lost message is simply gone while
both operators believe it arrived. Measured between two phones with no internet:
a reply left as a single unacknowledged transmission was recorded as delivered
and retried **zero** times.

**When it applies.** One condition: a direct message has already passed between
the two callsigns, in **either** direction. From then on each acknowledges the
other's direct messages. A relayed message is acknowledged the same way — the
receipt travels home as section 13.7 describes, and a carried message is
precisely the case where the sender has least other evidence.

**When it does not.** Each of these would put an acknowledgement on a shared
channel for every station that hears it, so none of them is automatic:

| Not acknowledged | Why |
|---|---|
| a broadcast (no `d:`) | one packet, every hearer answering |
| a regional message (`dest:`, no `d:`) | same, bounded only by the region |
| a group message | every member answering every message |
| a receipt | an acknowledgement of an acknowledgement never terminates |
| a station never exchanged with | see below |

`q:ack` still works, and still asks a station outside these rules for a receipt.

**Why a known station rather than everybody.** An acknowledgement is airtime
paid on a channel everyone shares, and answering a stranger also confirms to
anyone listening that this callsign is here and awake. Two stations that have
already exchanged a direct message have both of those costs priced in; a
stranger has not agreed to either.

An automatic receipt carries no `q:` — it is a device reporting bytes, not a
person agreeing to anything, and that remains `s:sign` (section 13.7), which is
still asked for explicitly. But it **is signed**, and this is the one place
where that is not a preference:

```
t:receipt f:X1A67X d:X1RD89 r:40f357 s:ack sig:<60 characters>
```

107 bytes, against 44 unsigned. The reason is what an unsigned one is worth to
an attacker. `s:ack` is not merely a note to the sender: section 7 has every
carrier holding that message **discard its copy** when it hears the matching
acknowledgement. So a forged receipt is not a lie about delivery — it is a way
to delete a message from the whole mesh, cheaply, without holding anyone's key,
for any callsign the attacker cares to name. The victim is told their message
arrived, the carriers drop it, and nobody ever finds out.

**A receipt whose signature does not verify changes nothing.** It does not mark
a message delivered, it does not release a held copy, and it does not stop a
retry. A station that has never heard the signer's key cannot verify one, and
must treat it the same way: unverifiable is not "probably fine". Section 13.7
already says this of `s:sign` — *a state that can be claimed without proof is
worth less than no state at all* — and the same sentence was always true of
`s:ack`; it simply had not been written down.

On a rated bearer 107 bytes is two and a half times the airtime of 44. The
answer is to send **fewer** receipts — section 13.7.2 already spends them only
against evidence the peer is there — and never to send unsigned ones. An
acknowledgement nobody can check is airtime spent on nothing.

### 13.7.2 When to stop trying

A receipt that never comes is an instruction to stop, not to try harder.

The failure this guards against is the expensive one. A station holding an
unacknowledged message for a peer that walked out of range will re-air it on
whatever schedule it was given, and every one of those transmissions is spent on
a peer that is not there. On a duty-cycled band that is not merely wasteful:
section 31.1 counts a retry against the same budget as saying it the first time,
so a handful of stations each nursing a few undelivered messages can hold a
frequency down between them while delivering nothing.

**A retry is spent only against evidence that the peer can be reached.** Two
kinds count, and either will do:

| Evidence | Where it comes from |
|---|---|
| the peer's beacon, heard recently | section 10.6 — it already names the station and where to write to it |
| a live route to it | the bearer, on the paths that have one |

With neither, a station **parks** the message. Parking is not failure and not
delivery: nothing is transmitted, the copy stays held, and the attempt is not
counted. The station keeps listening, and when the peer's beacon returns the
ladder resumes where it left off rather than having been spent into an empty
room. A peer that comes back in an hour is then still owed its message, which is
what store-and-forward was for (section 13.3).

This costs nothing to implement, because the evidence is already arriving: a
station hears its neighbours' beacons whether or not it has anything to send.

**Three more rules keep the acknowledgement itself cheap.**

- **A receipt rides with traffic when it can.** A station that owes an
  acknowledgement and is about to send that peer something anyway names the
  message in `r:` on the packet it was already sending, rather than paying for a
  transmission of its own.
- **One cycle per peer, not one per message.** Several messages waiting for the
  same station are retried together.
- **The bearer sets the cadence, and the strictest one binds** (section 31.1).
  The fast first attempts that make a conversation in one room feel immediate
  belong to Bluetooth; on LoRa the same ladder is fewer rungs, further apart.

### 13.8 Delivering to a region

A message with `dest:` and **no `d:`** is addressed to whoever is in that region
rather than to a person. Carriers take it there and stations already there air
it locally.

```
t:message f:X3RLY7 ts:2026-08-08_14:26:40 dest:38.72,-9.14 near:30km urg:high until:2026-08-15_00:00:00 m:water is off in the old town until Friday
```

147 bytes: get this to within 30 km of Lisbon, and it stops mattering on Friday.

Nothing new is needed for this. `d:` absent already meant "anyone in range"
(section 6.1); adding `dest:` and `near:` moves which range. The same rules
apply: a carrier takes it only if it gets closer, `until:` is required and is
never more than a year out, and `urg:` decides what survives a full store.

There is no recipient, so nothing is acknowledged. `q:sign` on a regional message
is meaningless and ignored.

Any packet type can be delivered this way, and for a warning the two circles are
genuinely different things:

```
t:warning f:X3RLY7 pos:39.40,-8.20 rad:5km dest:38.72,-9.14 near:40km urg:urgent kind:fire sev:danger until:2026-08-10_00:00:00 ts:2026-08-08_14:26:40
```

150 bytes: a fire five kilometres across at `pos:`, to be delivered within 40 km
of a town 80 km away. `pos:` and `rad:` describe the fire; `dest:` and `near:`
describe where people need to hear about it. Collapsing those into one key would
have made this packet unsayable.

### 13.9 The same message by two routes

Two copies that travelled differently are still one message:

```
t:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 dest:37.98,23.73 near:50km until:2026-09-08_00:00:00 q:sign via:X32DVA,CT1ABC-9,SV1XYZ m:are you still in Athens in September?
t:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 dest:37.98,23.73 near:50km until:2026-09-08_00:00:00 q:sign via:X3RLY7,IT9ABC,SV2QRP m:are you still in Athens in September?
```

177 and 175 bytes. Both are identifier `766d3e`, because an identifier is computed
with `via:` removed (section 5) and that is the only field the two copies differ
in.

So the recipient recognises the second copy as one it already holds and shows it
once. This is not a rule that had to be added: it falls out of deriving
identifiers from the message rather than the journey.

It does **answer** each copy, with the same receipt. The two cases are
indistinguishable on the air — a resend after a lost acknowledgement carries the
same identifier as the original, because the identifier describes the message
and not the attempt — so a recipient that answered only the first copy would
leave a sender whose receipt was lost retrying against a silence it can never
break. A receipt is idempotent (section 13.7): re-airing it asserts exactly what
the first one did. Bound it at one receipt per message per sender per 20
seconds, so a burst of copies is answered once rather than once each.

The difference between the copies is worth keeping rather than discarding. Each
`via:` is a route that actually worked, which is knowledge no single copy
carries: the recipient learns that both `SV1XYZ` and `SV2QRP` can reach it, and a
reply can be sent back along the one that arrived first.

### 13.10 Recording the route in the receipt

`via:` on a carried packet is appended to by each carrier, so on arrival it names
everyone who moved it. A signed receipt copies that list into `route:` and signs
it:

```
t:receipt f:X1RD89 d:X1QZ3N ts:2026-08-20_09:12:00 r:766d3e s:sign route:X32DVA,CT1ABC-9,SV1XYZ dest:38.72,-9.14 near:50km until:2026-10-01_00:00:00 sig:<60 characters>
```

213 bytes. `via:` on this packet is the receipt's own journey home, which is a
different list and is still being written. `route:` is the journey the message
made, fixed at the moment it arrived.

Because `sig:` covers everything except itself (section 9.1), the signature binds
the signer, the message identifier and the route together. The sender gets back
a statement that this person read this message and that it came by these hands,
which nobody along the way can alter without breaking the signature.

A carrier that finds itself in a signed `route:` has evidence it delivered
something, which is the only durable record any of this produces.

---

### 13.11 How far a packet may go

`scope:` limits where a packet may be transmitted and repeated. It is optional
and **the default is global**: a packet without it may go anywhere, which is what
every packet in this document does.

| `scope:` | Meaning |
|---|---|
| absent, or `global` | anywhere, on any bearer |
| `local` | short-range bearers only: Bluetooth LE, WiFi Direct, WiFi Aware, and a local network |
| an ISO 3166-1 alpha-2 code, uppercase | not relayed out of that country |

Lowercase words and uppercase codes cannot be confused, which is the same
convention callsigns and enums already follow everywhere else.

### 13.11.1 local

```
t:message f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 scope:local m:anyone got a 10 mm spanner?
```

92 bytes, twelve of them the field.

**`local` names bearers, not a distance.** A station must not put the packet on
LoRa, on any radio band, on a satellite, or onto the internet. It may put it on
Bluetooth, WiFi Direct, WiFi Aware or the network it is attached to.

That is the difference between "the people in this building" and "everyone who
can hear a 500 mW transmitter", and it is a privacy control as much as a noise
one: a question asked in a marina should not arrive in the next county, and it
certainly should not reach a relay that gates to the internet.

**A `local` packet is not carried.** Section 13.4 exists to deliver somewhere
else later, and somewhere else later is what `local` excludes. A carrier holding
one drops it rather than taking it to another town.

### 13.11.2 A country

```
t:warning f:X3RLY7 pos:39.4012,-8.2043 rad:5km kind:fire sev:danger scope:PT ts:2026-08-08_14:26:40
```

99 bytes. A station **does not relay it out of the named country**, which it
decides from its own position -- the same position that already chose its
frequency (section 1 of [spectrum.md](spectrum.md)).

More than one country is a comma-separated list, which a border region needs:

```
t:warning f:X3RLY7 pos:41.8012,-6.7543 rad:9km kind:fire sev:danger scope:PT,ES ts:2026-08-08_14:26:40
```

102 bytes: a fire nine kilometres across on the Portuguese side of a border, to
be relayed in both countries because the smoke does not stop either.

**Radio does not respect borders, and `scope:` cannot pretend otherwise.** A
transmission near a frontier is heard across it whatever this field says. What
`scope:` governs is what a station chooses to *relay*, to carry, and to gate onto
another network. Reception is not restricted and cannot be: a station that hears
an out-of-scope packet may read it, and simply does not pass it on.

A receiver that does not know where it is treats a country scope as global for
reading and refuses to relay, which is the safe direction: it sees the packet
and does not spread it.

### 13.11.3 Gateways

A gateway republishes a packet onto something that is not XPRS: an internet
relay, a NOSTR relay, APRS-IS, a web page, a chat room. That is not relaying,
the rules in section 13.1 do not reach it, and this is exactly why it has to be
said separately.

**A gateway treats `scope:` as binding.** It never publishes a `local` packet at
all, and never publishes a country-scoped packet outside that country. A
gateway that cannot determine where it is does not publish country-scoped
traffic.

This is the leak that matters, because a gateway is the one station whose whole
purpose is to move traffic somewhere the sender cannot see.

Three things follow that a community should know before relying on any of it.

**The default publishes.** No `scope:` means global, and global includes the
internet. A group that does not want its traffic leaving must say so on every
packet; silence is not a restriction.

**A group is an address, not a boundary.** `d:LISBOA` says where a packet is
going, not who may read it. Anyone in range hears it, any station may relay it,
and a gateway may publish it. Group membership is not enforced anywhere in this
format and cannot be, because a broadcast medium has no door.

That holds for a closed group too (section 26). A member list decides what a
client **shows**, never what may be transmitted or received, so `d:X5A3F2` is as
public as `d:LISBOA` -- and publishes the roster on top.

**Only encryption keeps content private.** `scope:` asks well-behaved stations
not to spread a packet. It is a request that a hostile or careless station
ignores, and it leaves the text in clear for everyone in radio range regardless.
A packet that must not be read by strangers uses `x:` (section 9.2), and one
that must not travel uses both.

### 13.11.4 Against the other limits

`scope:` is an additional constraint and replaces nothing. A packet still stops
at the relay limit of section 13.1, still expires at `until:`, and still gets
carried only toward `dest:`. Whichever binds first, binds.

Where `scope:` and `dest:` disagree -- a country scope with a destination outside
it -- **`scope:` wins and the packet is not carried.** A sender that meant it to
travel should not have restricted it.

---

### 13.12 Where to leave mail for me

`t:mailbox` names the stations a sender should hand mail to when the recipient
cannot be reached directly.

```
t:mailbox f:X1QZ3N ts:2026-08-08_14:26:40 hold:X3RLY7,X32DVA sig:<60 characters>
```

125 bytes. `hold:` lists callsigns **in order of preference**, and a station
that cannot reach `X1QZ3N` tries `X3RLY7` first.

This is the missing half of section 13.4. Carrying toward a place works when the
sender knows where the recipient is; a mailbox works when the sender knows who
tends to see them. A boat that checks in at the same marina, a person whose
neighbour runs a solar node, a group whose members all pass one repeater: those
relationships exist and nothing in the format could infer them.

`until:` bounds the declaration, which matters because the arrangement changes:

```
t:mailbox f:X1QZ3N ts:2026-08-08_14:26:40 hold:X3RLY7,X32DVA,CT1ABC-9 until:2026-09-08_00:00:00 sig:<60 characters>
```

160 bytes. A mailbox list with no expiry outlives the friendship, and a sender
handing mail to a station that stopped carrying it a year ago gets silence.

**A mailbox declaration must be signed, and a receiver that cannot verify one
must not act on it.**

This is the one packet in the format where forgery pays directly. Anyone who can
publish `t:mailbox f:X1QZ3N hold:<attacker>` collects that station's incoming
mail from every polite sender, and the sender believes it delivered. Signing is
the default everywhere (section 9.1) and here it is the whole point: an unsigned
mailbox declaration is a request to misroute somebody's mail, and it should be
ignored rather than displayed.

### 13.12.1 Several at once, each for a period

**A station publishes as many mailboxes as it has, and they coexist.** An earlier
draft said the newest declaration replaced the previous one, which made it
impossible to say the true thing: that where you are found depends on when.

`since:` and `until:` bound each one. A boat that knows its season says so months
ahead:

```
t:mailbox f:X1BOA3 ts:2026-08-08_14:26:40 hold:X3RLY7,X32DVA sig:<60 characters>
t:mailbox f:X1BOA3 ts:2026-08-08_14:26:40 hold:CT1MAR since:2026-09-01_00:00:00 until:2026-09-30_23:59:59 sig:<60 characters>
t:mailbox f:X1BOA3 ts:2026-08-08_14:26:40 hold:EA7CAN,EA7GIB since:2026-11-01_00:00:00 until:2027-03-31_23:59:59 sig:<60 characters>
```

125, 170 and 177 bytes. Home stations all year, a marina through September,
the Canaries from November to March. All three are true and none contradicts
another.

A declaration with no `since:` or `until:` is open-ended and always applies. One
with a window applies only inside it.

**Where windows overlap, the narrowest one that contains the moment wins.** In
September a sender uses `CT1MAR` rather than the open-ended pair, because a
declaration made about September is better information than one made about every
month. Within a single declaration, `hold:` stays in order of preference.

Outside every window a sender falls back to the open-ended declaration, and
failing that to any station advertising `serve:mailbox` (section 24.2).

### 13.12.2 Cancelling one

Plans change earlier than they were meant to. A declaration is withdrawn by
naming it, exactly as a warning is (section 17.2):

```
t:mailbox f:X1BOA3 ts:2026-08-20_09:00:00 r:46b4ba remove:mailbox sig:<60 characters>
```

130 bytes. `r:46b4ba` is the identifier of the marina declaration and
`remove:mailbox` says what is being withdrawn. The other two are untouched, which
is the point of cancelling one rather than replacing all of them.

A cancellation must be signed like the declaration it cancels. An unsigned one is
a request to stop delivering somebody's mail, which is an attack rather than an
administrative act.

Re-publishing a declaration after cancelling it is allowed and produces a new
identifier, because `ts:` differs. There is no way to un-cancel, and none is
needed.

Listing a station is not asking its permission. `hold:` records where the sender
believes their mail will be seen, and a station named in one is free to carry
nothing: it is under exactly the quota and priority rules of
[store-and-forward.md](store-and-forward.md) as for any other traffic.

---

## 14. Tracks

A track is a named sequence of positions: a flight, a ride, a crossing. Any
station may record one and publish it as it goes, and a receiver assembles the
points into a line without having heard the beginning.

```
t:track f:X3BAL1 track:sagres-2026 seq:1 pos:38.9012,-9.0021 alt:11240m type:balloon ts:2026-08-08_14:26:40
t:track f:X3BAL1 track:sagres-2026 seq:2 pos:38.9104,-8.9772 alt:14980m climb:4.8m/s type:balloon ts:2026-08-08_14:36:00
```

107 and 120 bytes. `track:` names the track and `seq:` places the point within it.

- **`track:` is optional.** A track packet without one belongs to the station's
  current track, keyed on `f:` alone. A station that runs one track at a time
  never names it:

  ```
  t:track f:X1QZ3N seq:7 pos:38.7301,-9.1355 spd:5.2m/s dir:41deg type:bike ts:2026-08-08_14:26:40
  ```

  Naming becomes worth its bytes when a station runs more than one track, or
  when a track is worth referring to after it ends.
- When present, `track:` is a `label`: lowercase letters, digits and `-`, no
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
t:track f:X1QZ3N track:commute seq:7 pos:38.7301,-9.1355 spd:5.2m/s dir:41deg type:bike ts:2026-08-08_14:26:40
```

110 bytes.

A track packet is an observation with a name attached. It is a separate type
because a receiver files it differently: an `observation` replaces what it knew
station's position, and a `track` is appended to a line.

### 14.1 Updating a track

Later points are sent as further `track` packets carrying the same `track:` and a
higher `seq:`. A point sent again with a `seq:` already held replaces it, which
is how a station corrects a position it later computed more accurately.

### 14.2 What the station is riding on

`type:` names what is moving, from this set. It applies to `observation` and
`track` alike.

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
| `since:` | no | when the situation began |
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

`t:warning` reports a hazard: a thing happening in a place, rather than a thing
happening to the sender. A station transmits a warning about a fire it can see;
it transmits an `sos` about a fire it is caught in.

```
t:warning f:X3RLY7 pos:39.4012,-8.2043 rad:5000m kind:fire sev:danger ts:2026-08-08_14:26:40 m:fast moving, wind from the north
```

127 bytes.

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

`sev:` takes one of the three below. A condition not serious enough for
`watch` is a notice rather than a warning (section 17).

| `sev:` | Meaning |
|---|---|
| `watch` | may affect you, be ready |
| `warning` | will affect you, act now |
| `danger` | life-threatening, leave |

`pos:` with `rad:` states an area rather than a point, which is what a hazard
occupies. A receiver knows whether it is inside the circle without asking
anyone.

```
t:warning f:X3RLY7 pos:38.6902,-9.4012 rad:1200m kind:flood sev:watch ts:2026-08-08_14:26:40
```

92 bytes: a flood watch 1200 m around a point, with no message, because
the fields already say it.

A warning is relayed up to nine times and is never encrypted, for the same
reason an `sos` is not. `ts:` matters more here than anywhere else in this
document: a fire warning that arrives by carrier three days later, and is
plotted as current, is worse than no warning.

---

## 17. Notices

`t:info` reports something worth knowing that is not yet a hazard: a queue, a
stopped vehicle, standing water, fog on a bend. It is the same shape as a
warning and carries the same fields, and it is a separate type for two reasons.

A station filters on it after five bytes, without parsing a severity out of the
middle of the packet. A subscriber who wants hazards and not road conditions
gets that by type rather than by reading every packet and deciding.

And it does not inherit the relay budget of an emergency. `sos` and `warning`
travel nine relays because they are worth spending a shared channel on. A
traffic queue travels three, like ordinary traffic, because it is not.

```
t:info f:X1CAR7 pos:38.7231,-9.1402 rad:800m kind:traffic ts:2026-08-08_14:26:40 until:2026-08-08_15:30:00
```

106 bytes: a queue 800 m around a point, expected to clear by half past.

| Field | Meaning |
|---|---|
| `pos:` | where it is |
| `rad:` | how far it extends, optional |
| `kind:` | what it is |
| `ts:` | when it was reported |
| `since:` | when it started, or will start, optional |
| `until:` | when it is expected to end, optional |
| `m:` | context the fields cannot carry |

`kind:` takes one of `traffic`, `stopped`, `slow`, `works`, `closure`, `rain`,
`snow`, `ice`, `fog`, `wind`, `debris`, `animal`, `crowd`, `event`, `other`.

There is no `sev:`. The type is the severity: an `info` is by definition not
urgent, and a `warning` grades itself from `watch` to `danger`. A notice that
turns out to matter is re-sent as a `warning`, which is a different packet
the same one edited.

```
t:info f:X1CAR7 pos:38.7231,-9.1402 kind:stopped ts:2026-08-08_14:26:40 m:car on the hard shoulder, hazards on
t:info f:X3WX01 pos:38.7223,-9.1393 rad:5km kind:rain ts:2026-08-08_14:26:40 m:standing water in the underpass
```

110 and 110 bytes. `rad:` is optional: a stopped car is at a point, and
standing water covers a stretch of road.

```
t:info f:X1QZ3N pos:38.7301,-9.1355 kind:fog ts:2026-08-08_14:26:40
```

67 bytes, which is the whole of it: fog, here, now.

### 17.1 When the condition starts and ends

Three times may appear on one packet and they answer three different questions.

| Key | Question |
|---|---|
| `ts:` | when was this packet written |
| `since:` | when did the condition start, or when will it start |
| `until:` | when is it expected to end |

`ts:` is a property of the packet. `since:` and `until:` are properties of the
thing the packet describes, and both are optional `time` values.

A condition rarely begins when someone gets around to reporting it. A fire has
been burning for hours before the first warning goes out, and reporting it at
`ts:` alone makes every receiver believe it started at that moment:

```
t:warning f:X3RLY7 pos:39.4012,-8.2043 rad:5km kind:fire sev:danger ts:2026-08-08_14:26:40 since:2026-08-07_23:10:00
```

116 bytes: reported at 14:26, burning since 23:10 the previous night.

`since:` in the future describes something that has not happened yet, which is
how planned work is announced:

```
t:info f:X3RLY7 pos:38.7231,-9.1402 rad:2km kind:works ts:2026-08-08_14:26:40 since:2026-08-15_07:00:00 until:2026-08-22_18:00:00
```

129 bytes: roadworks, announced on the 8th, starting on the 15th and
expected to finish on the 22nd. **A receiver does not show a condition as
current before its `since:`.** It is a plan until then, and a station that plots
it as a live hazard a week early is worse than one that never received it.

`since:` applies to any packet describing something with a duration, including a
call for help:

```
t:sos f:X1QZ3N pos:38.7223,-9.1393 kind:trapped ts:2026-08-08_14:26:40 since:2026-08-08_11:40:00
```

96 bytes: trapped since 11:40, reported at 14:26. The difference between
those two is the first thing a rescuer wants to know.

A transient condition with no end is worse than no condition at all. A queue
reported at eight and still on the map at midnight teaches everyone to ignore
the map, and by then the packet has usually outlived the person who could
withdraw it. When `until:` is absent a receiver applies its own expiry, and this
document does not fix that interval: a fog bank and a road closure do not expire
on the same clock.

### 17.2 Withdrawing a notice or a warning

A condition that ends before its `until:` is withdrawn by naming the packet that
reported it:

```
t:warning f:X3RLY7 pos:39.4012,-8.2043 rad:5km kind:fire sev:danger ts:2026-08-08_02:10:00
t:warning f:X3RLY7 pos:39.5511,-8.1002 rad:2km kind:fire sev:watch ts:2026-08-08_09:40:00
t:warning f:X3RLY7 ts:2026-08-08_14:26:40 r:9fd8ea remove:warning
```

90, 89 and 65 bytes. Two fires from one station, then the first one out.

`r:` carries the identifier of the packet being withdrawn and `remove:` says
what is being withdrawn. The identifier is computed, not transmitted
(section 5), so both ends already have it: the first fire is `9fd8ea` and the
second `aad744`, from the sender and the second they were reported.

This is why neither a warning nor a notice needs a name of its own. Naming the
kind would not do: a station that has reported two fires and withdraws `fire`
has said nothing a receiver can act on. Naming the packet is exact, and the
mechanism is the one replies, reactions and receipts already use.

`remove:` takes the type being withdrawn: `warning`, `info`, `event`, `offer`,
`need`, `channel`, `passage`, `blog`, `mailbox`, `service`, `place`, `vote`,
`like` or `repost` for a reaction. It is stated
even though `t:` repeats it, so that a receiver can filter withdrawals of any
type on one key, and so that a later revision can withdraw part of a packet
rather than all of it.

A withdrawal carries no `pos:`, no `kind:` and no `m:`. It says one thing.

---

## 18. Proving a callsign

Anyone can write `f:CT1ABC-9` on a packet. Three things already limit what that
buys an impostor, and each stops short of the same place.

A signature (section 9.1) proves the packet was written by the holder of a key.
It is optional, most traffic will not carry one, and a signed packet can be
replayed later by anyone who heard it.

An `X1` or `X3` callsign is derived from its own public key (section 3), so a
station cannot announce one it does not hold: the four characters would not
match. **This does not extend to a callsign issued by a radio authority.**
`CT1ABC-9` has no arithmetic relationship to any key, so nothing in the format
prevents a second station from claiming it.

None of them proves the holder is present now. `t:challenge` does.

### 18.1 Publishing a key

A station transmits `t:identity` (section 9.3) periodically, not only once, because a
receiver that has never heard the announcement cannot check a signature or issue
a challenge. Every 30 minutes is a reasonable interval on a quiet channel; a
station that changes its key announces immediately and does not wait.

`q:identity` (section 7) asks for one directly rather than waiting for the next
period.

### 18.2 The exchange

The challenger generates a nonce of at least 16 random bytes, seals it to the
public key the claimed callsign has announced, and sends it:

```
t:challenge f:X32DVA d:CT1ABC-9 ts:2026-08-08_14:26:40 k:npub1x32dva7fu9j9uenmyva7ha6x9eqwymytv2847ccv4vxdmn45y50q7hq2mv x:<64 characters>
```

187 bytes. `k:` carries the challenger's own key so the answer can be sealed back
to it without a prior exchange. Where the responder already holds that key, it
is omitted:

```
t:challenge f:X32DVA d:CT1ABC-9 ts:2026-08-08_14:26:40 x:<64 characters>
```

121 bytes.

Only the holder of the private key can recover the nonce. The answer is sealed
to the challenger's key and names the challenge in `r:`:

```
t:response f:CT1ABC-9 d:X32DVA ts:2026-08-08_14:26:40 r:35a544 x:<64 characters>
```

129 bytes. A challenger that gets back the value it expects has learned that
the station it is talking to holds the private key for that callsign, right now.

**The whole exchange fits in single packets**, with room to spare on each. That
is worth stating because it is the property the design has to have: a challenge
that had to be split across parts could not be answered by a station that heard
only some of them, and the stations most worth challenging are the ones at the
edge of range.

The sizes above are not estimates. Sealing uses AES-256-CBC under a shared
secret from static-static ECDH, which is what makes `k:` sufficient and an
ephemeral key unnecessary:

| | Bytes |
|---|---|
| challenge plaintext, `xprs-chal ` and a 16-byte nonce | 26 |
| padded to the block size | 32 |
| with the initialisation vector | 48 |
| base64url, no padding | 64 characters |

The answer seals 16 bytes and lands on the same 64 characters, the padding
absorbing the difference. A public key is 63 characters. Every figure above
follows from those three.

### 18.3 What the answer contains

**The answer is never the decrypted nonce.** It is

```
sha256(nonce | challenger callsign | responder callsign | challenge identifier)
```

truncated to 16 bytes and sealed to the challenger.

This matters more than it looks. A station that decrypts whatever arrives and
returns the plaintext is a decryption oracle: an attacker who has intercepted a
private message can submit that ciphertext as a challenge and have the victim
decrypt it. Returning a hash instead means an attacker learns nothing it could
not have computed by already knowing the answer.

For the same reason a station **only answers a challenge whose recovered
plaintext begins with `xprs-chal`**. Ciphertext that does not decrypt to that
marker is not a challenge, whatever packet it arrived in, and is discarded
without a reply.

Binding the callsigns and the challenge identifier into the hash stops an answer
being relayed as the answer to a different challenge, or to the same challenge
put by somebody else.

### 18.4 Rules

- A challenge and its answer are **never relayed**. Both are direct, and a
  station that receives one addressed elsewhere ignores it. Liveness proved
  through a relay is not liveness.
- An answer arriving more than 60 seconds after the challenge is refused. The
  point of the exchange is freshness.
- A station answers a limited number of challenges per period and ignores the
  rest. A challenge costs the responder a decryption, and an unlimited right to
  demand one from a battery-powered station is a way to flatten it.
- A challenge is never sent on amateur bands, since it cannot work without
  encryption (section 9.4).

### 18.5 What a failed challenge means

**No answer is not proof of forgery.** A station may be out of range, asleep,
rate-limiting, running on a radio that cannot encrypt, or simply not
implementing this section. Treating silence as guilt would make the network
hostile to exactly the small stations it exists for.

A wrong answer is different, and is the one case that carries weight: something
claiming that callsign does not hold its key.

| Outcome | What it establishes |
|---|---|
| correct answer | the station holds the key, and held it a moment ago |
| wrong answer | it does not hold the key |
| no answer | nothing |

A receiver may show that a callsign has been proved recently. It should not show
that one has failed, unless it failed by answering wrongly.

---

## 19. Blog posts

`t:blog` publishes a piece of writing rather than sending a message. The
difference is not the length. A message is addressed to someone and expects to
be read once; a post is published, kept, listed and read later by people who
were not listening when it went out.

```
t:blog f:X1QZ3N ts:2026-08-08_14:26:40 title:antenna-notes tag:radio m:The wire ends are the whole job. Everything else is decoration.
```

134 bytes. `d:` is absent, so it is published to anyone in range; a post to a
group carries `d:` like any other packet.

### 19.1 Title

`title:` is a `label`: lowercase letters, digits and `-`, no spaces. It names
the post so that it can be listed, filtered and revised, and it is unique only
in combination with `f:`, so two stations may both publish `antenna-notes`.

A later post from the same station with the same `title:` and a newer `ts:`
**replaces** the earlier one. That is how a post is corrected. A message cannot
be edited and a post can, which is the second real difference between them.

`title:` is a slug rather than a sentence because no value except `m:` may
contain a space. The human title is the first line of the text, where a reader
expects it.

### 19.2 How long a post can be

A post is split across up to 9 parts like any other text (section 6.6), so its
length follows from the packet limit and what the envelope costs:

| Post | Bytes per part | Whole post |
|---|---|---|
| untitled, broadcast | 203 | **1827 characters** |
| titled | 183 | **1647 characters** |
| titled, one tag | 173 | 1557 characters |
| titled, signed | 183, less 63 on the last part | 1584 characters |

**About 1650 characters for a normal titled post**, which is three or four
paragraphs. That is a short essay, not an article.

```
t:blog f:X1QZ3N ts:2026-08-08_14:26:40 title:antenna-notes n:1/3 m:I rebuilt the dipole this weekend and measured it properly for once.
t:blog f:X1QZ3N ts:2026-08-08_14:26:40 title:antenna-notes n:2/3 m:The feed point was three centimetres off centre, which cost about a decibel.
```

135 and 143 bytes, parts 1 and 2 of 3.

### 19.3 Files and images

`file:` attaches one file to a post, content-addressed like any other
(section 6.7):

```
t:blog f:X1QZ3N ts:2026-08-08_14:26:40 title:antenna-notes file:nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w.jpg m:The finished dipole, feed point centred at last.
```

162 bytes, of which 52 are the file reference and 43 of those the digest itself. The post reads on its own and the image
is fetched by whoever wants it and can.

About 1500 characters is a generous budget once a title, a few tags and an image
reference are paid for, and it is the same 9 parts every other kind of text
gets. The limit is not raised for posts. A post split across forty packets would
be unreadable until every one of them arrived, and on a channel where a single
advertisement is already a lottery that is a poor way to publish. A post that
genuinely needs more room is a document, and a document is a file.

### 19.4 Signing

A post should be signed. A message is usually one of many between two stations
that know each other, but a post is read later, by strangers, after being
relayed by stations the author never met, and authorship is the only thing a
reader has to go on. A signature costs 65 bytes on the last part.

---

## 20. Passages

`t:passage` says where a vessel is going and when it expects to arrive. It is a
float plan: filed before leaving so that somebody knows when to start worrying.

```
t:passage f:X1BOA3 pos:38.6902,-9.4012 dest:38.5241,-8.8931 since:2026-08-09_06:00:00 until:2026-08-09_18:00:00 onboard:3 type:sailboat ts:2026-08-08_14:26:40
```

158 bytes.

| Field | Meaning |
|---|---|
| `pos:` | where it is departing from |
| `dest:` | where it is bound |
| `since:` | when it leaves, or left |
| `until:` | when it expects to arrive |
| `onboard:` | how many people are aboard |
| `type:` | what kind of vessel |
| `m:` | anything else worth knowing |

`since:` and `until:` are the ordinary keys (section 17.1) and are not renamed
for this packet: a passage is a thing with a start and an end like any other.
`until:` is the estimated arrival, and being an estimate is what makes it
useful. A vessel that has not arrived and has not cancelled by then is a vessel
worth asking about.

```
t:passage f:X1BOA3 dest:38.5241,-8.8931 until:2026-08-09_18:00:00 onboard:3 ts:2026-08-08_14:26:40
```

98 bytes: bound there, back by six, three aboard. That is the whole of a float
plan, and it fits in a third of a packet.

A passage is closed by sending another with the same `dest:` and a `since:` in
the past, or is superseded by any later passage from the same station. Arriving
and saying nothing is the case the format cannot fix, and no format can.

`onboard:` is a count and carries no unit, like `seq:` and `n:`. It is the
number a rescue coordinator asks for first.

---

## 21. Events

`t:event` announces something happening at a time and a place: a net, a market,
a meeting, a working party.

```
t:event f:X3RLY7 pos:38.7223,-9.1393 title:tuesday-net kind:net since:2026-08-11_20:00:00 until:2026-08-11_21:00:00 ts:2026-08-08_14:26:40 m:weekly net, all welcome
```

164 bytes.

`title:` names it, as it names a post, so an event can be revised: a later
`event` from the same station with the same `title:` replaces the earlier one,
which is how a time changes or a meeting is cancelled.

`kind:` takes one of `net`, `meeting`, `market`, `class`, `work`, `social`,
`race`, `service`, `other`.

`since:` and `until:` are when it starts and ends. `pos:` is where, and `rad:`
may give the area it covers when a point would mislead.

An event is a separate type from a notice because a receiver files it
differently. A notice is a condition that is true now and expires; an event is
an appointment, and belongs in a calendar rather than on a map.

---

## 22. Offers and needs

`t:offer` says what a station has. `t:need` says what it wants. They carry the
same fields and differ only in direction.

```
t:need f:X1BOA3 pos:38.6902,-9.4012 kind:crew rad:50km ts:2026-08-08_14:26:40 m:two for a delivery to Madeira, leaving Friday
t:offer f:X1QZ3N pos:38.6902,-9.4012 kind:crew until:2026-08-20_12:00:00 ts:2026-08-08_14:26:40 m:deckhand, some night watch experience
```

125 and 135 bytes.

`kind:` takes one of `crew`, `transport`, `water`, `food`, `fuel`, `power`,
`shelter`, `berth`, `mooring`, `gear`, `room`, `tools`, `repair`, `medical`,
`childcare`, `internet`, `storage`, `labour`, `other`.

`crew` is in that list because it is the most common thing asked for and offered
where boats gather, in both directions: `t:need kind:crew` is a skipper short of
hands for a passage, and `t:offer kind:crew` is somebody willing to sail. The
same pair of types covers a village after a storm and a marina in October
without needing separate vocabularies.

| Field | Meaning |
|---|---|
| `kind:` | what is offered or wanted |
| `pos:` | where |
| `rad:` | how far the sender can travel or deliver |
| `since:` | when it becomes available or needed |
| `until:` | when the offer or need lapses |
| `price:` | what is asked or offered, if any (section 22.1) |
| `m:` | the detail no vocabulary can carry |

```
t:need f:X1QZ3N pos:38.7223,-9.1393 kind:water rad:2km ts:2026-08-08_14:26:40
```

77 bytes, which is all a request for water needs to be.

`until:` matters here as much as on a notice. An offer of a spare battery that
was taken three weeks ago and never withdrawn is worse than no offer, because
somebody will travel for it. A station that cannot say when its offer lapses
should re-send it rather than let a receiver guess.

Neither type is relayed further than ordinary traffic (section 13.1). A need is
not an emergency; a need that is an emergency is an `sos`.

---

### 22.1 Price

`price:` states what is being asked. It is optional: an offer without one has
simply not named a price.

```
price:120EUR          once, for the thing itself
price:25EUR/day       per day
price:150EUR/week     per week
price:12.50EUR/h      per hour
price:free            nothing
```

An amount, a currency, and optionally `/` and a period. No period means a single
price for the whole thing; a period means it repeats, which is the difference
between selling and renting.

Periods: `h`, `day`, `week`, `month`, `year`.

### 22.2 Currencies

The currency is an **ISO 4217 code**: three uppercase letters, from the official
list and never invented.

```
EUR  USD  GBP  CHF  JPY  CAD  AUD  NZD  SEK  NOK  DKK  PLN  CZK
BRL  MXN  ARS  ZAR  INR  CNY  IDR  PHP  THB  TRY  MAD  XOF  XPF
```

Those are examples, not the list. Any code in ISO 4217 is valid, and nothing
outside it is: a receiver that meets `price:120XYZ` skips the field rather than
displaying a number in a currency it cannot name.

No symbols. `EUR` and not the euro sign, because the format is ASCII, and `USD`
rather than a dollar sign, because a dollar sign is the currency of about twenty
different countries and says which one only by context a packet does not carry.

The amount follows the ordinary number rules (section 4.4): a decimal point and
never a comma, so `price:12.50EUR`, and no thousands separator, so
`price:12000EUR`.

### 22.3 When the price is not fixed

Not every price is a figure, and a seller who has not decided is common enough
to deserve saying rather than leaving the field out.

| `price:` | Meaning |
|---|---|
| `120EUR` | firm, this is the price |
| `~120EUR` | negotiable, about that |
| `~25EUR/day` | negotiable, and per day |
| `offers` | no figure, make one |
| `swap` | wants a trade, not money |
| `free` | nothing |

A leading `~` means the figure is a starting point rather than a demand:

```
t:offer f:X1QZ3N pos:38.6902,-9.4012 kind:gear price:~120EUR ts:2026-08-08_14:26:40 m:Aries windvane, needs a new bearing
```

121 bytes, one more than the firm version. It reads as "about 120 euros" to a
person and parses as an amount with a negotiable flag to everything else, which
is what a sorted list of prices needs.

`offers` says the seller wants to hear a number first:

```
t:offer f:X1QZ3N pos:38.6902,-9.4012 kind:gear price:offers until:2026-08-20_12:00:00 ts:2026-08-08_14:26:40 m:folding bike, working order
```

138 bytes. There is nothing to sort by, and a receiver showing it in a price
column shows the word rather than inventing a zero.

`swap` says money is not what is wanted:

```
t:offer f:X1BOA3 pos:38.6902,-9.4012 kind:gear price:swap ts:2026-08-08_14:26:40 m:spare anchor for a good dinghy pump
```

118 bytes.

Leaving `price:` out entirely still means what it always meant: the sender has
not said. That is different from `offers`, which is an invitation, and from
`free`, which is a price.

`price:` works on a `need` as well, where it is what the sender will pay:

```
t:need f:X1BOA3 pos:38.6902,-9.4012 kind:berth price:30EUR/day since:2026-08-15_00:00:00 until:2026-08-22_00:00:00 ts:2026-08-08_14:26:40
```

137 bytes: wanted, a berth for a week in the middle of the month, at up to 30
a day.

```
t:offer f:X1QZ3N pos:38.7223,-9.1393 kind:crew price:free ts:2026-08-08_14:26:40
```

80 bytes. `price:free` says so explicitly, which is worth doing when the
alternative is a receiver wondering whether the price was left out by accident.

### 22.4 The format carries no money

`price:` says what something costs and that is the end of this format's
involvement. **There are no payment packets, no balances, no receipts for money
and no tipping**, and the omission is deliberate rather than pending.

A packet saying a payment happened is worth exactly what the recipient's
willingness to believe it is worth, and it is the highest-value forgery in any
format that has one. Settlement needs a ledger somebody agrees on, and a lossy
broadcast medium where every station hears a different subset of the traffic is
close to the worst place to keep one.

Where value does move in this project it moves in the coin layer, which is a
different system with different guarantees. A `t:offer` says the berth costs
twenty-five euros a day; how the twenty-five euros travel is not a radio
question.

---

## 23. Channels

`t:channel` announces a frequency a station uses: what it is, how it is
modulated, whether the station transmits there, and when it is listening.

```
t:channel f:X1QZ3N freq:145.500MHz mode:fm kind:listen since:2026-08-08_18:00:00 until:2026-08-08_22:00:00 ts:2026-08-08_14:26:40
```

129 bytes: monitoring two metres this evening, receive only.

| Key | Meaning |
|---|---|
| `freq:` | the frequency to tune to hear this station |
| `ch:` | its number in a band plan, where it has one |
| `mode:` | how it is modulated |
| `bw:` | bandwidth, where the mode does not imply it |
| `shift:` | repeater input, as an offset from `freq:` |
| `input:` | repeater input, stated outright (section 23.4) |
| `tone:` | access tone |
| `power:` | transmit power |
| `range:` | how far the operator expects it to reach |
| `kind:` | what the channel is for |
| `pos:` | where the station or repeater is |
| `site:` | whether it stays there |
| `supply:` | what powers it |
| `every:`, `for:`, `at:` | a recurring listening window (section 23.2) |
| `since:`, `until:` | when the whole schedule starts and stops |
| `m:` | anything else |

`kind:` takes one of `listen`, `simplex`, `repeater`, `beacon`, `net`,
`gateway`, `emergency`, `other`.

`mode:` takes one of `fm`, `am`, `usb`, `lsb`, `cw`, `ssb`, `packet`, `aprs`,
`lora`, `ft8`, `psk31`, `rtty`, `dmr`, `dstar`, `c4fm`, `m17`, `dv`, `other`.

### 23.1 Listening, or transmitting

**`power:` present means the station transmits on that channel. Absent means it
only listens.** There is no separate flag, because a transmit power is the thing
a listener would have had to state anyway, and a station that will not say its
power has not told you it transmits.

```
t:channel f:X1QZ3N freq:145.500MHz mode:fm power:25W kind:simplex ts:2026-08-08_14:26:40
```

88 bytes.

`since:` and `until:` are the listening window, and mean what they mean
everywhere else (section 17.1). Their absence says the station listens whenever
it is on, not that it never listens.

A recurring schedule is not expressed here. A weekly net is a `t:event`
(section 21) that names the frequency, and this packet describes the channel
itself rather than the calendar around it.

### 23.2 Recurring windows

Three keys describe a schedule that repeats.

| Key | Meaning |
|---|---|
| `every:` | how long between windows |
| `for:` | how long each window lasts |
| `at:` | the time of day the cycle is anchored to, UTC |

The 3-3-3 plan is channel 3, for 3 minutes, every 3 hours:

```
t:channel f:X1QZ3N freq:446.03125MHz ch:3 mode:fm every:3h for:3min kind:listen ts:2026-08-08_14:26:40
```

102 bytes.

`at:` defaults to `00:00:00`, so `every:3h` alone means 00:00, 03:00, 06:00 and
so on in UTC, which is what makes the plan work: every station calculates the
same windows without anyone coordinating. A schedule anchored to local time
would put two neighbours an hour apart on different minutes.

Give `at:` when the cycle is not anchored to midnight:

```
t:channel f:CT1ABC freq:14.300MHz mode:usb every:1day at:20:00:00 for:1h power:100W kind:net ts:2026-08-08_14:26:40
```

115 bytes: every day at eight in the evening, for an hour.

`since:` and `until:` bound the schedule itself, and are a different thing from
the windows inside it: `since:` says when the arrangement begins, `until:` when
it lapses. A net that runs weekly through the summer has both.

Absent `every:`, there is no schedule. `since:` and `until:` alone are a single
window, and neither means the station is deaf the rest of the time.

### 23.3 Where the station is, and whether it stays

```
t:channel f:X3RLY7 pos:38.7810,-9.2043 freq:145.600MHz mode:fm shift:-600kHz tone:123.0Hz power:50W range:40km site:fixed supply:solar kind:repeater ts:2026-08-08_14:26:40
```

171 bytes: a solar repeater on a hill, reaching about 40 km.

`site:` takes one of `fixed`, `mobile`, `portable`, `temporary`. It answers a
question `type:` does not: whether the channel will still be there tomorrow.
A repeater is `fixed`, a handheld carried up a hill is `portable`, a vessel is
`mobile`, and a set installed for a weekend is `temporary`.

`supply:` takes one of `grid`, `solar`, `wind`, `hydro`, `battery`, `generator`,
`fuel`, `mixed`. It is what tells a reader whether a station survives a power
cut, which is the moment its frequency matters most. A `solar` repeater is
reachable after the grid drops and a `grid` one is not.

`range:` is the operator's own estimate of usable range, as a radius from
`pos:`.

**It is an estimate and the document says so.** Terrain, weather and the other
station's antenna decide what actually happens, and a hill between two stations
30 km apart beats a `range:40km` every time. It is published because the person
who installed the antenna knows better than anyone else what it usually does,
and a reader 200 km away can rule the channel out without trying.

```
t:channel f:X1BOA3 pos:38.6902,-9.4012 freq:156.800MHz ch:16 mode:fm power:25W range:15km site:mobile supply:battery kind:emergency ts:2026-08-08_14:26:40
```

154 bytes: a vessel on channel 16, battery powered, about 15 km on a good day.

### 23.4 Repeaters that listen elsewhere

`freq:` is **the frequency to tune to hear this station**. On a simplex or
listen-only channel that is the whole story. A repeater has a second frequency:
the one it listens on, which is the one a user transmits on.

`shift:` gives it as an offset, which is how repeaters are conventionally
listed and is shorter:

```
shift:-600kHz     the input is 600 kHz below the output
```

`input:` gives it outright, for when it is not a simple offset:

```
t:channel f:X3RLY7 pos:38.7810,-9.2043 freq:145.750MHz input:433.000MHz mode:fm tone:123.0Hz power:25W range:30km kind:repeater ts:2026-08-08_14:26:40
```

150 bytes: listens on 70 centimetres, transmits on 2 metres. No offset can
express that, because the two frequencies are not in the same band and the
number would be larger than either.

The two forms describe the same thing and a packet carries one, not both:

```
t:channel f:X3RLY7 freq:145.600MHz input:145.000MHz mode:fm kind:repeater ts:2026-08-08_14:26:40
```

96 bytes, which is `shift:-600kHz` written out. Where a station sends both
anyway, `input:` is authoritative, being the measurement rather than the
arithmetic.

If the input differs by more than its frequency -- a different mode, a different
bandwidth, a gateway that hears DMR and speaks FM -- it is not one channel with
two frequencies. Send two `t:channel` packets with `kind:gateway`, one for each
side, and let each carry its own `mode:` and `bw:`. Cramming a second mode into
this packet would mean a second `mode:` key, and a key appears once.

### 23.5 One channel per packet

A station that uses several frequencies sends several packets, one each.

This is not a limitation worked around. A key appears at most once in a packet,
so two frequencies would need either `freq1:` and `freq2:`, or one value packing
frequency, mode and power together in a fixed order. The second is how APRS
encodes almost everything and the reason a receiver there cannot skip a field it
does not understand.

One packet each also means a station adding a band re-sends one packet rather
than all of them, a receiver can filter on `mode:lora` without parsing the
others, and a repeater's entry stays correct when the operator's handheld
changes.

```
t:channel f:X3RLY7 pos:38.7810,-9.2043 freq:145.600MHz mode:fm shift:-600kHz tone:123.0Hz power:50W kind:repeater ts:2026-08-08_14:26:40
t:channel f:X3RLY7 freq:433.775MHz mode:lora bw:125kHz power:22dBm kind:gateway ts:2026-08-08_14:26:40
```

136 and 102 bytes: a two-metre repeater with its offset and access tone, and a
LoRa gateway whose power is quoted in dBm because that is how the module is
specified.

```
t:channel f:CT1ABC freq:14.300MHz mode:usb power:100W kind:net since:2026-08-11_20:00:00 until:2026-08-11_21:00:00 ts:2026-08-08_14:26:40 m:maritime mobile net
t:channel f:X3RLY7 freq:156.800MHz mode:fm kind:emergency ts:2026-08-08_14:26:40 m:channel 16, monitored continuously
```

159 and 117 bytes.

### 23.6 Transmitting is regulated

A `t:channel` packet says what a station does; it does not make it lawful. A
frequency, a power and a mode together describe a transmission that in most of
the world requires a licence, an allocation, or both, and neither this document
nor a receiver can tell whether the sender holds one. Announcing a channel is
not a claim of authority to use it, and section 9.4 continues to govern what may
be transmitted where.

---

## 24. Services

`t:service` says what a station does for other stations.

```
t:service f:X3RLY7 pos:38.7810,-9.2043 serve:relay,mailbox ts:2026-08-08_14:26:40 sig:<60 characters>
```

146 bytes: a node that repeats packets and carries mail.

`serve:` is a comma-separated list from a fixed set:

| Word | The station |
|---|---|
| `relay` | repeats packets it hears |
| `mailbox` | carries mail for stations it cannot reach |
| `internet` | gateways to the internet |
| `aprs` | gateways to APRS-IS |
| `nostr` | runs a NOSTR relay |
| `files` | hosts content-addressed files: answers `q:have` (section 7.1) and `cmd:file`, and accepts `cmd:put` deposits within its budgets (section 25.2) |
| `history` | keeps a spool of what it has heard, and re-airs it on `cmd:history` |
| `time` | has a clock worth trusting, usually from GNSS |
| `weather` | publishes observations |
| `wifi` | offers network access to people nearby |
| `other` | something not in this list, described in `m:` |

A station with a position and a power source says so, because both decide
whether it is worth routing through:

```
t:service f:X3RLY7 pos:38.7810,-9.2043 serve:relay,mailbox,internet,aprs supply:solar ts:2026-08-08_14:26:40 sig:<60 characters>
```

173 bytes. `supply:solar` from section 23.3 means it survives a power cut,
which is when a gateway matters most.

### 24.1 What this is not

**Physical goods and help are `t:offer`, not this.** Water, fuel, shelter, a
lift, a spare battery and a berth are already in section 22 with a price and an
expiry, and they belong to a person rather than a station. `t:service` is what a
radio does on the network, and the division is worth keeping: a station offering
`internet` is advertising a route for packets, and one offering `wifi` is
advertising a socket for humans.

### 24.2 The other half of a mailbox

`serve:mailbox` is a station volunteering. `t:mailbox` (section 13.12) is a
recipient nominating. They are opposite directions of the same arrangement and
neither implies the other.

A sender with mail for an unreachable station looks for a `t:mailbox` from that
station first, because the recipient knows best who sees them. Failing that, any
station advertising `serve:mailbox` is a reasonable guess. **Neither is a
promise.** A carrier is under the quota and eviction rules of
[store-and-forward.md](store-and-forward.md) whatever it advertised, and a
station that stops carrying does not owe anybody a withdrawal.

### 24.3 Trust

**Sign it.** Signing is the default (section 9.1) and an unsigned service
advertisement is worth nothing: `serve:internet` is an invitation to route
traffic through a station, and forging one is the cheapest way to collect other
people's packets.

Even signed, an advertisement is a **claim about capability, not a promise of
behaviour, and never evidence of good faith**. A station that truthfully gateways
to the internet may also log everything that passes. Encrypt what should not be
read (section 9.2) and set `scope:` on what should not travel (section 13.11);
neither depends on trusting the station that carries it.

### 24.4 One port on an IP network

**A station reachable over TCP listens on port 4242, and that one port speaks
both Reticulum and XPRS.** 4242 is already the port Reticulum hubs answer on,
so an operator opening a firewall for one has opened it for both, and a client
guessing the port guesses right.

The two are told apart by the first byte of the connection, and nothing else:

- A Reticulum stream is HDLC-framed, and every frame begins with the flag
  byte `0x7E`.
- An XPRS connection is printable text, and a packet begins with `t:`
  (section 4) — the first byte is `0x74`.

A listener reads one byte and knows which protocol it has. A stock Reticulum
client connecting to the port works untouched; an XPRS client sends packets as
lines of text, one packet per line, and receives the same. Everything on such
a connection is an ordinary packet — a `t:ping` is answered with a `t:pong`, a
`cmd:history` with the replay of section 25.2 — so the socket adds no new
vocabulary, only a wire.

Two rules keep the demultiplexing honest, and they are load-bearing:

- **XPRS on this port stays plain text, one packet per line.** No binary
  framing, no envelope. The packet already has a size limit (250 bytes) and a
  grammar (section 4); a line needs nothing more.
- **Nothing that is not HDLC may ever begin with `0x7E`** on this port. A
  future binary variant that starts with the flag byte breaks the one-byte
  decision, so there will not be one.

The bearer is decided by where the peer actually is, because a TCP socket does
not say. A connection from a private or link-local address is the LAN it looks
like: recorded under `lan`, visible on the air view, archived like any local
bearer. A connection from a public address travelled the internet whatever
port it used, and it is treated exactly like the Reticulum lane: never shown
as an air sighting, and archived only under the mailbox-declaration rule of
section 36.3.

`until:` bounds the claim, and it should be short. A service list is a statement
about equipment that is switched on, and equipment gets switched off.

---

## 25. Commands

`t:command` asks another station to *do* something. `t:result` says what
happened.

```
t:command f:X1QZ3N d:X3RLY7 ts:2026-08-08_14:26:40 cmd:door-open arg:north sig:<60 characters>
```

139 bytes. `cmd:` is a `label` naming the action and `arg:` carries its
arguments, comma-separated. What the words mean is agreed between the two
stations and is not this document's business.

This is not `t:request`. That asks for state from a closed vocabulary -- send me
your position, send me your battery -- and reports. A command acts, its
vocabulary is whatever the operator defines, and reporting a battery level is not
the same act as unlocking a door.

### 25.1 The reply, immediately and again later

**A station answers a command at once, even when it cannot finish it.**

```
t:result f:X3RLY7 d:X1QZ3N ts:2026-08-08_14:26:40 r:747ae8 code:202 sig:<60 characters>
t:result f:X3RLY7 d:X1QZ3N ts:2026-08-08_14:29:12 r:747ae8 code:200 sig:<60 characters>
```

132 bytes each: accepted at 14:26:40, done at 14:29:12. `code:202` says the
command arrived and is being worked on; `code:200` says it finished. A sender
that hears nothing knows the command did not arrive, which is the whole point of
answering before the work is done.

**Any number of results may name one command**, and a late one needs no new
mechanism: `r:747ae8` is the command's derived identifier (section 5), and it is
the same however many minutes pass.

| `code:` | Meaning |
|---|---|
| `200` | done |
| `202` | accepted, working on it |
| `206` | part of the answer, more on request (section 25.2.1) |
| `400` | understood, arguments wrong |
| `403` | refused, not permitted |
| `404` | unknown command, or nothing held to answer it |
| `408` | too old, outside its freshness window |
| `429` | over budget, ask later or ask elsewhere (section 31) |
| `500` | tried and failed |

```
t:result f:X3RLY7 d:X1QZ3N ts:2026-08-08_14:26:40 r:747ae8 code:403 sig:<60 characters> m:not on the allow list
```

156 bytes. `m:` is detail for a person reading a log.

Numbers sit oddly beside `sev:danger` and `kind:fire`, and are still right here.
The outcome space is open-ended in a way a word list is not, and these particular
numbers are understood by everyone who has ever written a web client.

### 25.2 The commands this document defines

What a command word means is agreed between two stations and is mostly not this
document's business. Two are the exception, because they cannot work between
strangers if every station names them differently.

**`cmd:history` asks a station to re-air what it kept.** It is how somebody back
from four days at sea catches up on a townhall that was aired once while they
were away.

```
153  t:command f:X1BOA3 d:X3RLY7 ts:2026-08-08_14:26:40 cmd:history since:2026-08-04_00:00:00 sig:<60 characters>
165  t:command f:X1BOA3 d:X3RLY7 ts:2026-08-08_14:26:40 cmd:history since:2026-08-04_00:00:00 only:X5A3F2 sig:<60 characters>
```

`since:` and `until:` bound the window and already mean exactly this everywhere
else. `only:` narrows the replay to one callsign or one group, which on a slow
bearer is the difference between a useful answer and an unusable one.

**A standard command carries its parameters in the keys the format already
has**, not in `arg:`. `arg:` is positional, and design rule 1 says there are no
positional fields; it stays for operator commands, where this document has no
key to offer.

**`cmd:file` asks for the bytes behind a `file:` reference.**

```
177  t:command f:X1QZ3N d:X3RLY7 ts:2026-08-08_14:26:40 cmd:file file:nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w.jpg sig:<60 characters>
186  t:command f:X1QZ3N d:X3RLY7 ts:2026-08-08_14:26:40 cmd:file file:nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w.jpg off:64kB sig:<60 characters>
```

Until now a `file:` reference could be shown and not resolved, which made every
photograph in the format decoration. The command says **what** is wanted and
never how it should travel; a station advertising `serve:files` (section 24)
answers, and which bearer carries the bytes is the transport's business and not
this document's.

`off:` resumes: send from that byte offset, because the first attempt died at
64 kB and the 64 kB that arrived are verified against the piece list (6.7.2)
or simply kept. A station that cannot resume ignores `off:` and sends from
zero — the requester merely receives some bytes twice, and the file still
verifies or still fails as a whole.

The reply flow gives `cmd:file`'s codes their concrete meaning. `202` — I hold
it and it fits my budget; the bytes then move on whatever bulk lane the pair's
bearers offer (a GATT session beside the advert channel, a Reticulum resource,
a fetch across the LAN — examples, not requirements), and `200` follows only
after the REQUESTER's own hash check passed, making the final receipt a
statement about content rather than about transmission. `500` — the transfer
started and died. `404` — not held. `403` — refused, and a file too large for
the station's budget is refused here with `m:` saying so, which is what
`size:` on the description exists to prevent. `429` — over budget this hour,
with alternates in `m:` when the station knows any (section 31.2).

**`cmd:put` is the same exchange in reverse: I hold these bytes, take them.**

```
211  t:command f:X1QZ3N d:X3RLY7 ts:2026-08-08_14:26:40 cmd:put file:nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w.jpg size:2MB until:2026-09-08_00:00:00 sig:<60 characters>
132  t:result f:X3RLY7 d:X1QZ3N ts:2026-08-08_14:29:02 r:3148dd code:200 sig:<60 characters>
```

The ask names the file and its cost up front — `size:` is mandatory here,
because accepting bytes unseen is how a small station is filled by a stranger
— and `until:` bounds the stay, the discipline of section 36.7: a deposit is a
hold, not an archive. `202` means bring it, and the bytes travel exactly as a
`cmd:file` answer does, in the other direction. The receiver verifies what
arrived against `file:` and answers the signed `200` above: **a custody
receipt for bytes**, section 13.7's receipt discipline applied to a file. A
station already holding the file answers `200` immediately — the bytes exist,
custody is real, and nothing needs to travel; a sender must treat that as
success, not as an error. `403` and `429` refuse as they always do.

Why deposit at all: the recipient is away, and the file's author will be too.
A photograph left with the mailbox station a `t:mailbox` (section 13.12)
names, or with any station advertising `serve:files`, is a file that arrives
next week without either party being awake at the same time — store and
forward for content, under the same quota rules as everything else a station
carries.

### 25.2.1 What comes back

The answer is the ordinary sequence of section 25.1 -- accepted, then done:

```
132  t:result f:X3RLY7 d:X1BOA3 ts:2026-08-08_14:26:41 r:747ae8 code:202 sig:<60 characters>
132  t:result f:X3RLY7 d:X1BOA3 ts:2026-08-08_14:31:02 r:747ae8 code:200 sig:<60 characters>
```

Between them the station re-airs the packets themselves. `code:404` says nothing
was held for that window, `code:403` that the station will not serve this
requester, and `code:429` that it is over budget -- with, by section 31, the
names of stations that might serve instead.

**The replay is the original packets, unchanged.** `f:`, `ts:` and `sig:` are
exactly as first transmitted, so authorship survives having been held for days by
a station nobody trusts. It cannot alter what it replays without breaking a
signature, and it cannot invent traffic that was never sent.

**A station answers with as much as it can afford, and says there is more.**
A week of a busy group will not fit in one exchange on a bearer that owes several
seconds of silence per packet, and a station must not have to choose between
sending everything and sending nothing.

```
132  t:result f:X3RLY7 d:X1BOA3 ts:2026-08-08_14:31:02 r:747ae8 code:206 sig:<60 characters>
```

`code:206` closes a page rather than the request: what came before it is a
complete, verifiable part of the answer, and more exists. `code:200` in the same
place means that was all of it.

**A page is continued by asking again for a narrower window**, not by a cursor:

```
179  t:command f:X1BOA3 d:X3RLY7 ts:2026-08-08_14:33:10 cmd:history since:2026-08-04_00:00:00 until:2026-08-06_11:02:44 sig:<60 characters>
```

**A replay runs newest first**, so the requester always knows where the page
stopped: it moves `until:` to the `ts:` of the oldest packet it received and asks
again. Newest first is also the right order for a person -- somebody back from
four days at sea wants last night before last Tuesday, and a page that never
arrives costs them the least.

Nothing here is stateful. The station keeps no cursor, remembers no session and
owes the requester nothing between exchanges, so a request that is never
continued costs it nothing, and a station that reboots mid-backfill has broken
no promise. Repeating a boundary packet is free for the same reason everything
else here is: duplicates collapse on their identifiers.

**Derived identifiers make backfill safe by construction**, and this is the part
worth understanding before implementing any of it. A replayed packet has the same
identifier it always had (section 5), so a client that already holds it
recognises the duplicate and keeps one copy. That single property removes the
machinery every comparable protocol needs: no cursors to persist, no sequence
numbers to allocate, no agreement about where one station's history ends and
another's begins, and no bug at the boundary between two windows. Asking two
stations for overlapping windows costs airtime and nothing else.

A station that keeps a spool says so with `serve:history` (section 24). What it
keeps, for how long and for whom is its own to decide and to change: section 31.3
says why this document sets no retention period, and section 31.2 what a station
owes a stranger regardless.

### 25.2.2 A file transfer, on the wire

Illustrative, not normative: the packets below are this document's, the binary
frames between them belong to the bearer (here BLE's session protocol,
`docs/mesh.md`) and are shown ONCE so the division of labour is visible —
XPRS asks and receipts, the bulk lane moves bytes, and neither does the
other's job. X1QZ3N deposits a 240 kB photograph with X1RD89:

```
── advert channel (XPRS) ───────────────────────────────────────────────
X1QZ3N→ t:command f:X1QZ3N d:X1RD89 ts:2026-08-17_12:00:00 cmd:put file:nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w.jpg size:240kB sig:<60 characters>
X1RD89→ t:result f:X1RD89 d:X1QZ3N ts:2026-08-17_12:00:03 r:a91f04 code:202 sig:<60 characters>

── bulk lane (binary, one ATT write per frame; 4D 01 = the session magic) ──
X1QZ3N→ 4D 01 20  FILE_OFFER   xfer=7, sha256 (32 bytes), size=240640,
                               ttl, origin "X1QZ3N", target "X1RD89",
                               ext "jpg", name "photo.jpg"
X1RD89→ 4D 01 21  FILE_ACCEPT  xfer=7, offset=0, window=16
X1QZ3N→ 4D 01 23  CHUNK        xfer=7, offset=0,   498 raw file bytes
X1QZ3N→ 4D 01 23  CHUNK        xfer=7, offset=498, 498 raw file bytes
        …16 chunks per credit window…
X1RD89→ 4D 01 24  WIN_ACK      xfer=7, next=7968, window=16
        …until offset reaches 240640…
X1QZ3N→ 4D 01 25  FILE_DONE
X1RD89→ 4D 01 26  FILE_OK      (receiver's own sha256 matched file:)

── advert channel again ────────────────────────────────────────────────
X1RD89→ t:result f:X1RD89 d:X1QZ3N ts:2026-08-17_12:02:31 r:a91f04 code:200 sig:<60 characters>
```

The portion of the file on the air is the CHUNK frame: a 3-byte envelope, the
transfer id, the byte offset, then **raw file bytes, unencoded** — the packet
grammar never touches them. A lost chunk costs one window, because the
receiver's WIN_ACK names the next contiguous offset it wants and the sender
rewinds to it. The final signed `code:200` is the only durable record: a
custody receipt naming the command, issued only after the receiver hashed
what it holds. `accept` at `offset == size` is how "I already have it" is
said without moving a byte.

The same two XPRS packets bracket the transfer whatever the bearer — a
Reticulum resource, a LAN fetch, a swarm — with only the middle block
changing, which is the point of keeping it out of this document.

### 25.3 Keeping it out of the conversation

Four rules, each closing a specific confusion.

`t:command` and `t:result` are **distinct packet types**, so a station filters
them on the first field without parsing anything else.

**Neither is ever rendered as a message.** A command is not chat, and it must not
appear in a conversation view even when it carries `m:`.

**Neither is replied to or reacted to** (section 6.5). They are protocol
machinery like a receipt or a challenge.

**`m:` is detail, never the command.** A bot reads `cmd:` and `arg:`; the free
text is for the operator afterwards. A station that parsed instructions out of
`m:` would have built a natural-language interface to its front door.

### 25.4 Security

A packet that opens a door is the highest-value forgery in this format, and the
rules here are stricter than elsewhere because of it.

**A command must be signed, and one that cannot be verified is discarded.**
Signing is the default everywhere (section 9.1); here it is a requirement, and
"unsigned" is not a state a command may be acted on in.

**A command expires.** Without that, one signed packet opens a door for ever to
anyone who recorded it. The default window is **300 seconds** from `ts:`, and
`until:` extends it deliberately. Outside the window the answer is `code:408`.

Five minutes rather than the sixty seconds section 18.4 gives a challenge,
because a challenge is a direct exchange between two stations and a command
crosses real bearers: LoRa at SF9 owes 5.5 seconds of silence for every packet
under a 10 percent duty cycle, and a relay hop or two on top can honestly take
longer than a minute. Five minutes is still far too short for a recording to be
useful hours later.

**Commands are never carried.** Section 13.4 exists to deliver somewhere else
later, and later is precisely what a command must not be. A carrier drops one
rather than parking it.

**Repeating a command does not repeat the action.** The derived identifier of a
retransmitted command is unchanged, so a station that has acted on
`747ae8` recognises the second copy and answers again without opening the
door twice. Idempotency falls out of section 5 rather than needing a rule.

**Authentication is not authorisation, and this format only provides the first.**
A signature proves which callsign sent a command. Whether that callsign may open
that door is an allow-list held by the station acting on it, and nothing in XPRS
expresses, distributes or checks one. A bot that acts on any correctly signed
command has an open door with extra steps.

Where bystanders should not learn what is being operated, seal it:

```
t:command f:X1QZ3N d:X3RLY7 ts:2026-08-08_14:26:40 x:<64 characters> sig:<60 characters>
```

182 bytes, sealed and signed. `t:`, `f:`, `d:` and `ts:` stay in clear so the
packet can be routed and its freshness checked without reading it.

### 25.5 Commands too long for one packet

A command splits across parts exactly as a message does (section 6.6), which
matters for the case that motivates it: a spoken instruction, transcribed, and
handed to a station that interprets it.

`cmd:interpret` says the text in `m:` is the instruction and is to be read rather
than matched:

```
t:command f:X1QZ3N d:X3RLY7 ts:2026-08-08_14:26:40 cmd:interpret n:1/3 m:open the north door for thirty seconds then switch the yard light on
t:command f:X1QZ3N d:X3RLY7 ts:2026-08-08_14:26:40 cmd:interpret n:2/3 m:and leave it until sunrise, and if the water tank is below a quarter
t:command f:X1QZ3N d:X3RLY7 ts:2026-08-08_14:26:40 cmd:interpret n:3/3 sig:<60 characters> m:start the pump for ten minutes and tell me what the level was
```

141, 141 and 199 bytes. Reassembled it is 266 bytes, which is why it split.

This is the one command whose payload is `m:`, and it is an **explicit opt-in**
rather than a hole in section 25.3. Everywhere else a bot reads `cmd:` and
`arg:` and never takes instructions from free text. A station that does not
interpret natural language answers `404`, and one that does has said so by
accepting this command word.

The reply names the **whole** command:

```
t:result f:X3RLY7 d:X1QZ3N ts:2026-08-08_14:26:40 r:863d7f code:202 sig:<60 characters>
```

132 bytes. `r:863d7f` is the identifier of the reassembled packet, not of any
part. Each part has an identifier of its own and none of them is the command's.

Three rules on top of section 6.6, all of them about not acting too early.

**A station acts only on a complete, verified set.** The signature is on the last
part and covers the reassembled packet, so a partial set proves nothing about who
sent it. Half a command is not a smaller command.

**Parts are held for the command's freshness window, not the ten minutes a
message gets.** A set still incomplete at 300 seconds is discarded, because a
command that has expired is not worth assembling.

**The window runs from `ts:`, which every part shares.** A three-part command is
one command that took a few seconds to arrive, not three events.

### 25.6 Interpretation is not authorisation either

`cmd:interpret` puts attacker-influenced text in front of a language model, and
that is worth stating plainly rather than discovering later.

A signature proves which callsign sent the text. It says nothing about whether
the text is a good idea, and a model asked to interpret "open the north door"
will do exactly as well with a sentence designed to talk it into something else.
The allow-list of section 25.4 matters more here than anywhere in this document,
because it is the only thing standing between a stranger and the interpreter.

**A model's output should not be the last check before a physical action.** Map
what it produces onto the same fixed set of commands a `cmd:` would have named,
and apply the same permission test. An interpreter that can emit any action at
all has made the allow-list decorative.

---

## 26. Closed groups

An open group (section 6.3) has no door. Anyone may post to `LISBOA`, nobody may
be removed from it, and a single determined spammer or a persistently abusive
participant cannot be dealt with at all. That is fine for a calling channel and
useless for a community.

A **closed group** has a member list, one admin, and moderators. It changes
nothing about how packets travel and adds no enforcement anywhere: it lets a
group say who belongs, so a client can choose to show only those people.

### 26.1 A group is a station

A closed group holds a keypair, so it gets a callsign like anything else
(section 3):

```
X5A3F2
```

The admin is whoever holds the matching private key. **That key belongs to the
group, not to the person**, which is the property everything else in this
section rests on: an admin hands the group on by handing over the group's key,
and never has to share the private key of their own callsign to do it.

A group announces itself with the packet that already exists for announcing a
callsign and a key (section 9.3):

```
t:identity f:X5A3F2 ts:2026-08-08_14:26:40 k:npub1qz3n7fu9j9uenmyva7ha6x9eqwymytv2847ccv4vxdmn45y50q7h7k5f nick:lisboa-net sig:<60 characters>
```

187 bytes. It is self-signed, which proves possession of the group's private key
(section 9.3), and `nick:` gives the group a readable name that is shown only
when the signature verifies (section 9.3.1). A group needs no announcement
packet of its own, no registry and no creation ceremony. It exists once somebody
generates a key and says so.

**An `X5` callsign is a label, exactly as every other callsign is.** Four
characters is about a million values, and an attacker who wants a callsign that
looks like `X5A3F2` can grind keys until one produces those four characters.
Section 3 already says this and the answer is the same here: the group is its
**full public key**, and a receiver that has not verified a signature against
that key has identified nothing. Two groups with the same four characters are
two groups, and a client that holds the key of one is not fooled by the other.

### 26.2 Subgroups

A large group wants smaller rooms inside it: a club with a VHF section and a
contest section, a marina with one channel per pontoon. **A subgroup is not a
new kind of thing.** It is an ordinary closed group, with its own keypair, its
own `X5` callsign, its own admin and its own roster, that some other group has
listed as part of itself.

Listing one is a grant like any other, and `role:sub` is what it grants:

```
138  t:moderate f:X5A3F2 d:X5A3F2 ts:2026-08-08_14:26:40 grant:X5K2M9 role:sub sig:<60 characters>
145  t:moderate f:X5A3F2 d:X5A3F2 ts:2026-08-08_14:26:40 grant:X5K2M9,X5T4WD role:sub sig:<60 characters>
130  t:moderate f:X5A3F2 d:X5A3F2 ts:2026-08-08_14:26:40 revoke:X5K2M9 sig:<60 characters>
```

Delisting is `revoke:`, the same packet that removes a person. A client that
follows `X5A3F2` reads its listings and shows the tree; each subgroup announces
its own name with its own `t:identity`, exactly as its parent does.

**Listing confers no authority.** This is the rule that keeps subgroups simple,
and it follows from the group being its key: `X5A3F2` saying that `X5K2M9` is
part of it does not let `X5A3F2` grant, revoke or hide anything inside
`X5K2M9`, because those acts are signed by `X5K2M9`'s key and nothing else will
verify. Nor does membership travel down: belonging to a parent is not belonging
to a subgroup, and each roster is read on its own.

That is a deliberate difference from moderation systems that walk a tree to
decide who may act, and it costs the parent admin nothing in practice: an admin
who wants authority over a subgroup creates it and keeps its key, which is the
ordinary case. Handing that key to somebody else is how a section gets its own
administration, and section 26.6 already describes what handing a group key over
means.

**Five levels, counting the root.** A client ignores a listing that would place
a group deeper than that, so a root has at most four generations beneath it. It
also ignores a listing that names a group already in its own ancestry, because a
cycle is not a tree and two groups listing each other must not become an
infinite one.

A listing is a claim by the parent and nothing more. Any group may list any `X5`
callsign, whether or not that group agreed, and there is no packet to prevent
it -- the same limit section 3 states about callsigns, for the same reason. What
bounds the damage is the rule above: a false listing borrows a name into a menu
and confers nothing, and it is visible only to clients already following the
group that made the claim.

### 26.3 Membership

One packet type carries every act of authority. The admin signs as the group:

```
136  t:moderate f:X5A3F2 d:X5A3F2 ts:2026-08-08_14:26:40 grant:X1RD89,X32DVA sig:<60 characters>
164  t:moderate f:X5A3F2 d:X5A3F2 ts:2026-08-08_14:26:40 grant:X32DVA role:mod until:2027-02-08_00:00:00 sig:<60 characters>
130  t:moderate f:X5A3F2 d:X5A3F2 ts:2026-08-08_14:26:40 revoke:X1PZ4Q sig:<60 characters>
```

`grant:` and `revoke:` take one or more callsigns, so admitting a dozen people
is one packet rather than a dozen. `role:mod` makes a moderator; without it the
grant makes an ordinary member. `f:` is always the signer and `d:` is always the
group the act concerns, so a moderator's act looks the same but is signed by
them:

```
156  t:moderate f:X32DVA d:X5A3F2 ts:2026-08-08_14:26:40 revoke:X1PZ4Q until:2026-08-15_00:00:00 sig:<60 characters>
138  t:moderate f:X32DVA d:X5A3F2 ts:2026-08-08_14:26:40 r:89a9c8 hide:message sig:<60 characters>
```

**A suspension is a revocation with an end.** `revoke:` alone removes somebody;
`revoke:` with `until:` removes them until that moment and no longer. `until:`
keeps the meaning it has everywhere else in this document -- when the sender
expects the condition to end -- and `revoke:` keeps the meaning it has with or
without it.

**A moderator may revoke and hide. Only the admin may appoint.** Two tiers is
the whole hierarchy. `hide:message` asks clients not to display the packet named
in `r:`; it cannot unsend anything, because nothing on a radio can.

There is no application packet. **Asking to join is an ordinary message to the
group**, which needs no new type and leaves no permanent signed record that a
person asked and was refused.

### 26.4 Reading the log

Every act is signed and they accumulate; a client replays what it has heard.
Three rules decide what the result is, and they exist so that two implementations
reach the same answer from the same packets.

**Authority is judged at the moment of the act.** A moderator's `revoke:` counts
if that callsign held `role:mod` at the act's `ts:`, whatever their status now.
Otherwise removing a moderator would either silently undo a year of legitimate
moderation, or leave an abusive one's suspensions standing for ever.

**Newest wins, per signer.** Where one signer contradicts themselves, the later
`ts:` stands; where two acts share a `ts:`, the smaller identifier (section 5)
stands, so a tie is broken the same way everywhere. A `ts:` more than a few
minutes in the future is discarded, or a rogue moderator would win every
disagreement for ever by dating a packet to 2030. An `until:` more than a year
past its own `ts:` is discarded for the same reason.

**The admin can void a moderator's record.** `revoke:` with `since:` withdraws
the moderator and everything they did from that moment:

```
156  t:moderate f:X5A3F2 d:X5A3F2 ts:2026-08-08_14:26:40 revoke:X32DVA since:2026-08-01_00:00:00 sig:<60 characters>
```

Without it, a compromised moderator key that suspends fifty people costs fifty
packets to undo, each one a packet that is unsafe to lose.

Note what is **not** inherited from section 13.12.1: a mailbox declaration is
chosen by the narrowest window containing the moment, and membership is not.
Narrowest-window-wins would demote a moderator the instant any narrower grant
existed.

### 26.5 Expiry, and what a quiet group does

`until:` on a grant is optional, exactly as it is on a mailbox declaration
(section 13.12.1): a grant without one is open-ended and stays in force. A
revocation is kept indefinitely, because a client that forgets one and then
hears a replay of the grant it cancelled would readmit somebody who was removed.

The asymmetry is deliberate and worth stating the other way round: **losing a
grant is safe and losing a revocation is not**, so the format keeps revocations
and lets grants stand.

`until:` on a moderator's grant is the closest thing to cleanup this section
offers, and it is enough. A moderator who stops operating falls off when their
grant expires, with no vote, no timer and no act by anybody.

### 26.6 When the admin is gone

**Succession is handing over the key.** The outgoing admin gives the group's
private key to whoever takes it on; the callsign, the roster and every past
grant stay valid, because the root of trust has not moved. There is no heir
packet and no inactivity rule.

**There is deliberately no mechanism that infers an absent admin from silence.**
A healthy group with no membership churn emits no admin packets at all, so any
such timer fires on an admin who is present and simply had nothing to sign.
Section 18.5 already refuses this inference for challenges -- "treating silence
as guilt would make the network hostile to exactly the small stations it exists
for" -- and it is worse here, because clients that heard different packets would
promote different successors and split the group permanently, with no way for
either side to notice.

Three costs come with key handover, and none of them has a protocol answer:

- **It cannot be undone.** The previous holder keeps a copy.
- **A leaked key is permanent.** Anyone with it is indistinguishable from the
  admin.
- **The key cannot be rotated**, because the callsign derives from it. A new key
  is a new group.

The remedy in every one of those cases is the same, and it is social rather than
technical: found a new group and move to it. That is what a community does
anyway when its administration fails, it needs no packet, and unlike an
automatic succession it cannot silently fork a group in two.

### 26.7 What a client shows

Membership decides display and nothing else. A closed group is not a private
one, and three rules keep the difference honest.

**Safety traffic is never filtered.** `t:sos`, `t:warning`, `t:info` and direct
replies to them are shown whatever the roster says. A member whose grant a
receiver never heard must not have their call for help hidden by their own
group; section 15 makes the same argument about encryption, and it applies here
with more force, because a missing grant is an accident rather than a choice.

**A client that cannot verify fails open, and says so.** Without the group's key,
or knowing its own grant set is incomplete, it shows everything and marks the
group unverified. A closed group whose announcements have not arrived must look
broken rather than empty, since the alternative is a silent, invisible failure
that looks exactly like nobody talking.

**The roster is public, permanent and non-repudiable.** Grants have to reach
strangers for anyone to bootstrap, so they cannot be sealed with `x:` or held
back with `scope:local`. What a closed group publishes is a signed list of
everyone who belongs -- including members who never speak -- and a complete
history of who suspended whom and when, gatewayed to the internet like anything
else. That is **more** exposure than an open group, where only the people who
talk are visible. A group that needs its membership kept secret cannot have it
this way. `x:` conceals what is said and nothing conceals who belongs, because
the roster is what a stranger must read in order to honour it at all.

None of this contradicts section 13.11.3. A group is still an address and not a
boundary: anyone can still transmit to `X5A3F2` and everyone in range still
hears it. Design rule 6 also stands -- every packet remains fully readable with
no prior state, and the roster changes only what a client chooses to **show**.

### 26.8 Bootstrap, and not becoming a weapon

Any member may rebroadcast the grants it holds. They are signed by the group, so
a newcomer verifies them against the group's key and needs to trust the
rebroadcaster not at all.

Two limits keep that from being an amplifier, both following section 18.4:

- A station answers a bounded number of roster requests per period and ignores
  the rest.
- It answers the station that asked, never a broadcast.

A rebroadcast is a relay and not a new origination, so it stays under the limit
of section 13.1 and does not earn a fresh three hops by being re-signed.

---

## 27. Status

`t:status` is a short post about the sender, now. It is the packet a townhall is
made of: everybody publishes, everybody sees, and a client renders them in a
timeline newest first.

```
t:status f:X1QZ3N ts:2026-08-08_14:26:40 m:tied up in Sagres, the wind finally dropped
```

86 bytes. `d:` is absent, so it is published to anyone in range. A status
carrying `d:` goes to that group's timeline instead of the global one, whether
the group is an open name or a closed `X5` (section 26).

**Neither existing type would do.** A `t:blog` post is a document: it has a
`title:`, and a later post with the same title replaces it (section 19.1). Two
statuses an hour apart are two moments and not a correction of each other, so a
status has no title and never replaces anything. A broadcast `t:message` is
conversational and spoken to whoever is listening now; a status is published,
kept, and read later by people who were not, which is the distinction section 19
already draws between a message and a post.

Everything else a status needs already exists. `pos:` says where it was written,
`file:` attaches a photograph, `tag:` files it, `lang:` names its language, `cw:`
warns what it contains, `scope:` keeps it off the internet, `n:` splits a long
one across up to nine parts (section 6.6), and `sig:` signs it. A status takes
replies and reactions, which is most of the point of publishing one.

### 27.1 Mood

`mood:` says how the sender feels, so that a client can dress itself to match --
a colour, a background, an icon beside the post.

```
t:status f:X1QZ3N ts:2026-08-08_14:26:40 mood:becalmed m:no wind since dawn, going nowhere
```

90 bytes. It is optional, and the four bytes it costs beyond the word itself buy
a client everything it needs to theme a screen without parsing the text.

The value is one word from the list below and nothing else. A receiver that does
not recognise a value skips it (section 4.3) and shows the post plainly, which
is the correct outcome: the post is the content and the mood is decoration.

| Family | Word | What it says |
|---|---|---|
| general | `blessed` | fortunate, and aware of it |
| general | `grateful` | thankful to somebody in particular |
| general | `happy` | plainly glad |
| general | `sad` | plainly not |
| general | `tired` | worn down rather than sleepy |
| general | `lonely` | alone and minding it |
| general | `proud` | pleased with something done |
| general | `worried` | expecting trouble |
| general | `calm` | settled, nothing pressing |
| general | `determined` | set on finishing something |
| sea | `becalmed` | no wind, going nowhere |
| sea | `adrift` | unmoored, in the head or the hull |
| sea | `anchored` | held somewhere safe |
| sea | `seasick` | exactly that |
| sea | `salty` | weathered and cheerful about it |
| sea | `stormbound` | kept in shelter by weather |
| sea | `landsick` | ashore and missing the sea |
| sea | `soaked` | wet through |
| sea | `homebound` | on the way back |
| sea | `windblown` | battered by a long day on deck |
| mountain | `summited` | on top, and it was worth it |
| mountain | `breathless` | thin air, not fear |
| mountain | `snowbound` | cannot move for snow |
| mountain | `frostbitten` | cold has done damage |
| mountain | `footsore` | too many miles today |
| mountain | `exposed` | on a face, nothing between you and the weather |
| mountain | `sheltered` | out of it at last |
| mountain | `benighted` | caught out by darkness |
| mountain | `acclimatised` | the altitude has stopped mattering |
| mountain | `whiteout` | cannot see, cannot navigate |

Thirty words in three families. The families are there so a client can theme by
family and refine later, rather than needing thirty palettes on the first day.

```
t:status f:X1QZ3N ts:2026-08-08_14:26:40 mood:summited pos:42.6390,0.6560 m:top of Aneto, clear all the way to France
t:status f:X1QZ3N d:X5A3F2 ts:2026-08-08_14:26:40 mood:stormbound sig:<60 characters> m:staying put another day
```

117 and 156 bytes.

**A closed list is not a cage.** Section 4.9 reserves every key beginning with
`z` for private use, so a community that wants a mood this document does not
have writes `zmood:stoked` beside the standard one, and every other receiver
skips it without error.

`mood:` is defined here and, like any key, may appear on any packet the sender
chooses -- on a `t:blog` post it reads perfectly well. What it must never do is
change how a packet is treated. A mood is not a priority, does not earn a relay,
and does not raise a notification; `urg:` (section 13.5) is the field that speaks
to the network, and `sev:` (section 16) is the one that speaks to danger.

### 27.2 What a status is not

**Not carried.** Store-and-forward (section 13.4) delivers to a recipient, and a
broadcast status has none. A status that missed its audience is simply a post
nobody read, which is an ordinary thing for a post.

**Not privileged.** Three relays, the default of section 13.1. A townhall post
is not an emergency and must not compete with one.

**No follow packet.** A client keeps its own list of the callsigns whose
statuses it shows, and that list stays on the device. Publishing it would put a
permanent public record of who reads whom on the air -- the same leak section
26.7 describes for rosters -- and buys nothing that a local list does not already
give.

---

## 28. Polls

`t:poll` asks everybody the same question and counts the answers.

```
t:poll f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 opt:sagres,lagos,portimao until:2026-08-10_18:00:00 m:where shall we meet for the net?
```

134 bytes, identifier `7a9b50`. `opt:` carries the choices as comma-separated
labels and `m:` asks the question. A poll to a group carries `d:` like anything
else; without it, it is put to whoever is in range.

`opt:` takes **two to six** options, each a `label` (lowercase letters, digits
and `-`). Two because a poll with one option is not a question, and six because
a person choosing on a phone in a cockpit is not reading a menu -- and because
the options, the question and the envelope share 250 bytes.

### 28.1 `until:` is required

**A poll states when voting closes, always.** `until:` is the one field a poll
may not omit, and a poll without it is incomplete: a counter does not count votes
for it, and a client shows it as a question rather than a ballot.

This is the only field in the format that is required by its type rather than by
its packet, and the reason is that the alternative is worse. A poll with no
closing time never resolves. It sits in every spool that keeps it, collects votes
from stations coming back into range for as long as anybody replays it, and has a
different answer every time it is counted -- for ever, with no moment at which
anyone may say what the answer was. Section 31.3 makes that concrete: a station
may keep a followed callsign's traffic indefinitely, so "eventually it ages out"
is not true here.

Nothing about the requirement changes how a receiver **parses** a poll. Design
rule 4 stands: an unknown or absent field is skipped and the packet still reads.
What a missing `until:` costs is the count, not the parse.

The same key already carries this weight elsewhere: a carried packet must state
`until:` (section 13.4), for the same reason -- work with no deadline is work
nobody can ever stop doing.

### 28.2 Bounding who is being asked

A poll may narrow its audience with fields the format already has, and needs no
new ones:

```
133  t:poll f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 opt:yes,no scope:local until:2026-08-09_20:00:00 m:should we move the net to Sundays?
137  t:poll f:X3RLY7 ts:2026-08-08_14:26:40 opt:yes,no pos:37.0194,-7.9304 rad:20km until:2026-08-09_20:00:00 m:is anyone still without power?
131  t:poll f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 opt:sagres,lagos,portimao until:2026-08-10_18:00:00 lang:PT m:onde nos encontramos?
```

| Field | Narrows the poll to |
|---|---|
| `d:` | one group, open or closed (section 26) |
| `scope:` | `local` for the bearers in range now, or ISO country codes (section 13.11) |
| `pos:` with `rad:` | people within that radius of that point |
| `lang:` | people who read that language (section 4.7) |
| `cw:` | nobody -- it warns what the question contains before it renders |

**These say who is being asked. They do not say who may answer**, and the
difference is the same one section 26.7 draws about rosters. Anybody in range
hears the poll, anybody may transmit a vote, and no field prevents it. What the
fields do is tell a counter which votes belong in the answer and tell a client
whether to put the question in front of its operator at all.

A counter should therefore be honest about what it can actually check. `d:` and
`lang:` it can read off the packets. `scope:` it can apply to its own bearers.
**`rad:` it usually cannot check at all**, because a vote carries no position
unless the voter chose to include one, and requiring a position to vote asks
somebody to disclose where they are in order to answer a question. A poll bounded
by radius is a poll asked politely of a region, not a constituency with a roll.

### 28.3 Voting is a reaction

A vote needs no packet type of its own, because the format already has one that
behaves exactly like a ballot:

```
t:reaction f:X32DVA d:LISBOA r:7a9b50 vote:sagres
t:reaction f:X32DVA d:LISBOA r:7a9b50 remove:vote
```

49 bytes each. Section 6.5 already says a reaction is **counted once per callsign,
is idempotent, is not displayed as a message and raises no notification**, which
is the whole specification of a vote. `vote:` names the chosen option and `r:`
names the poll.

**Changing your mind is voting again.** The newest verifiable vote from a
callsign stands, decided by `ts:`, exactly as a nickname is replaced (section
9.3.1). `remove:vote` withdraws a vote without replacing it.

A vote for an option the poll does not offer is discarded rather than counted as
something else, and a vote arriving after `until:` is counted only if the
counter chooses to -- both stations may reasonably disagree about when the
deadline passed, and see below.

### 28.4 The count is local, and provisional

**There is no authoritative result and this format will not pretend otherwise.**
Every station counts the votes it has actually heard, and no two stations on a
radio network have heard the same set. A poll that closed an hour ago is still
gaining votes on the far side of a relay that has just come back up.

That is not a defect to be engineered away; it is what counting on a lossy
broadcast medium means. What follows from it:

- **Show the count as what it is** -- votes heard, not votes cast. A client that
  displays "7 for sagres" where it means "7 that reached me" has lied by
  rounding.
- **The author's tally is not special.** The station that asked has no more
  authority over the result than anyone else; it simply usually hears more. If a
  final figure matters, the author publishes one as an ordinary `t:status` or a
  reply, signed, and it is a claim like any other claim.
- **`cmd:history` improves a count** (section 25.2) and never completes it.

### 28.5 A poll is not a secret ballot

Every vote is a signed packet naming a callsign and a choice, transmitted in
clear to anybody in range and relayed onward. **Who voted for what is public,
permanently, to everyone.**

This cannot be fixed within the format. Sealing a vote with `x:` hides it from
bystanders and not from the counter, and a vote nobody can read is a vote nobody
can count. Anonymity on a broadcast medium needs cryptography this document does
not have and a trusted counter this network does not want.

So: use `t:poll` for what time the net should start and where to meet. Do not use
it to elect anybody, and do not use it for a question whose answer could cost
somebody something.

---

## 29. Reporting

`t:report` says that a packet is spam, abuse, or something worse. It is the one
thing a station can do about bad traffic that is not inside a closed group,
where section 26 gives a moderator `hide:` and everywhere else gives nobody
anything.

```
133  t:report f:X32DVA d:X5A3F2 ts:2026-08-08_14:26:40 r:399227 kind:spam sig:<60 characters>
164  t:report f:X32DVA ts:2026-08-08_14:26:40 r:399227 kind:abuse sig:<60 characters> m:same text to every group all morning
```

`r:` names the packet being reported and `kind:` says why. `d:` aims the report
at a group, whose admin and moderators are the people most able to act; without
it the report is made to whoever is listening.

| `kind:` | The packet is |
|---|---|
| `spam` | repetitive, automated, or sent to be seen rather than read |
| `abuse` | directed at somebody, and meant to harm them |
| `illegal` | unlawful where the reporter is |
| `false` | a claim the reporter believes is untrue and dangerous |
| `other` | something else, described in `m:` |

`kind:` needs no new key. It already means "what kind of thing this is" for a
warning, a channel and a place, and this is the fourth vocabulary it carries.

### 29.1 A report is a claim, never a verdict

**Nothing happens automatically because a report exists.** A report is not
moderation: `hide:` (section 26.3) is the only packet in this format that hides
anything, it works only inside one closed group, and only a moderator of that
group may send it. A report is one station's opinion, offered to whoever finds it
useful.

**A report must be signed.** An anonymous accusation is worth nothing to a
receiver and costs the accused something, which is the worst possible ratio. An
unsigned or unverifiable report is discarded.

**Reports are themselves an attack.** Mass false reporting is the obvious one:
twenty signed reports naming an innocent station cost an attacker nothing but
airtime, and a client that counts reports without weighing who sent them has
built a way to silence anybody. **A report counts for as much as its signer's
standing with the receiver and no more** -- which is a local judgement, like
every other judgement in this format, and cannot be delegated to the network.

**Reporting is not blocking.** A station that wants to stop seeing somebody mutes
them locally and needs no packet and nobody's permission. A report is for telling
other people, and the two should not be confused in a user interface: one is a
private decision, the other is a public statement about somebody else.

---

## 30. Places

Every packet so far reports the sender: where I am, what I see, how I feel. A
place reports **something that is not me and does not move** -- a tap on a
harbour wall, a mooring buoy, a bothy, the one gap in a wall of gorse. APRS has
had this for thirty years as Objects and Items, and a format aimed at people at
sea and in mountains cannot do without it.

```
t:place f:X1BOA3 ts:2026-08-08_14:26:40 kind:anchorage pos:37.0194,-7.9304 title:baleeira m:good holding in sand, exposed to south
```

130 bytes. `kind:` says what it is, `pos:` where it is, and `title:` names it.

`kind:` needs no new key: it already means "what kind of thing this is" for a
warning and for a channel, and this is the third vocabulary it carries.

| Word | The place |
|---|---|
| `anchorage` | somewhere to lie at anchor |
| `mooring` | a buoy or pile to make fast to |
| `ramp` | a slipway |
| `jetty` | a pontoon or quay to come alongside |
| `beach` | somewhere to land a small boat |
| `fuel` | diesel, petrol or gas |
| `water` | drinking water |
| `repair` | a yard, a chandlery, somebody who mends things |
| `shelter` | out of the weather, unstaffed |
| `hut` | a refuge or bothy, walls and a roof |
| `camp` | somewhere a tent goes |
| `spring` | water out of the ground |
| `ford` | a crossing |
| `pass` | a way through a ridge |
| `summit` | a top |
| `trailhead` | where a path starts |
| `other` | something not in this list, described in `m:` |

### 30.1 Naming, revising and withdrawing

`title:` is a `label` and works exactly as it does on a post (section 19.1): a
later place from the same station with the same title **replaces** the earlier
one. That is how a place is corrected when the tap is moved or the buoy is
lifted, and it is why a place needs no separate revision mechanism.

`until:` makes a place temporary -- a water point that runs dry in August, a
winter-only shelter. `file:` attaches a photograph, which for a landing beach
is worth more than any description. `remove:place` withdraws one:

```
t:place f:X1BOA3 ts:2026-08-08_14:26:40 kind:water pos:37.0194,-7.9304 title:sagres-tap sig:<60 characters> m:tap by the harbour office, potable
t:place f:X1BOA3 ts:2026-09-01_09:00:00 r:9f52f6 remove:place sig:<60 characters>
```

189 and 126 bytes.

### 30.2 A place is a claim

Nothing here is a survey and no station is an authority. Two people may publish
different places with the same title, or the same place in different positions,
and both are true statements about what somebody believed.

The rules are the ones this format uses everywhere else. **Newest wins per
signer**, so a station corrects itself and never anybody else. **A client shows
who said it**, because on a coast where a mistake grounds a boat, the callsign
that reported the anchorage is part of the information. **An unsigned place is a
claim by nobody**, and a client is right to rank it below one it can verify.

A place that matters for safety is not a place. A hazard is `t:warning` and a
call for help is `t:sos`; both carry a relay budget this type does not, and both
are the right packet when somebody could be hurt.

---

## 31. Airtime

Every other section says what a station **may** transmit. This one says how
often, and what it owes the strangers who ask it for things. Sections 25.2 and
13.12 make that urgent: `cmd:history` and `cmd:file` let one station ask another
to spend real airtime on demand, and a format that hands out that power without
a budget has designed a way to flatten a solar node from across a bay.

### 31.1 Cadence belongs to the bearer

There is no single right interval, because the constraint is not the same on
each bearer:

| Bearer | What binds |
|---|---|
| LoRa on ISM | a legal duty cycle, often 1 percent -- at SF9 a single packet owes several seconds of silence |
| VHF and UHF packet | a shared channel and whoever else is on it |
| Bluetooth and WiFi Direct | range, so traffic is naturally local and cheap |
| the internet | nothing, which is the trap |

**A station transmits unsolicited traffic no more often than the strictest
bearer it is transmitting on allows.** A phone that gateways to both LoRa and the
internet is bound by LoRa, not by the internet, for anything it sends to both.

Two consequences worth stating, because both have been got wrong in practice:
**a beacon is not free**, so position, identity and service announcements go out
on a period measured in tens of minutes rather than seconds; and **a retry is
not a new packet**, so re-airing something that went unanswered counts against
the same budget as saying it the first time.

Section 13.7.2 says when to stop re-airing altogether: a retry is spent only
against evidence that the peer can still be reached, because a station that
cannot hear its peer learns nothing by transmitting at it again — and a few
stations each nursing undelivered messages for peers that left can hold a
frequency down between them while delivering nothing at all.

### 31.2 What a station owes a stranger

`cmd:history` and `cmd:file` are requests to spend somebody else's battery. The
answer is not that they must be refused, and not that they must be honoured.

- **Serving yourself is unmetered; serving a stranger is optional and metered.**
  A station decides what it gives away, and a station that gives away nothing is
  still a good citizen of this network.
- **A bounded number of answers per period.** Section 18.4 already sets this
  precedent for challenges, and the reasoning transfers unchanged: an unlimited
  right to demand work from a battery-powered station is a way to flatten it.
- **Refuse out loud.** Over budget, a station answers `code:429` rather than
  going quiet, and names in `m:` any station it knows that serves the same thing:

```
t:result f:X3RLY7 d:X1BOA3 ts:2026-08-08_14:26:40 r:747ae8 code:429 sig:<60 characters> m:try X32DVA or CT1ABC-9
```

157 bytes. Silence and refusal look identical to the asker and mean opposite
things, so a refusal that says nothing wastes the very airtime it was trying to
save: the asker retries, reasonably, believing the packet was lost.

### 31.3 Retention belongs to the station

**This document states no retention period, and will not.** There is no minimum
depth, no maximum, no required eviction order, and no obligation to keep
anything at all. A hosting station and the software it runs decide what to keep,
for how long, and for whom -- and change that decision whenever storage,
battery, bandwidth or interest changes.

That is not an omission. The stations on this network are a dongle with a
microSD card, a phone that is someone's only computer, and a home server with a
spare terabyte. Any number this document picked would be an overstatement for
the first and an insult to the third, and it would be wrong again the day
somebody adds a disk.

**A spool is not a time window, and this is why no station can usefully publish
one number for it.** Keeping is a judgement about worth, not about age. A station
holds the notes of the people its operator follows and never drops them; it keeps
whatever recorded something that mattered -- a rescue, a storm, a passage that
went wrong -- long after everything around it is gone; and it discards a
stranger's chatter within hours of hearing it. Ask such a station "how far back
do you go" and there is no honest answer: it goes back a year for one callsign
and an afternoon for the next.

So a station advertises `serve:history` and nothing more. **The claim is "ask
me", never "I hold everything since a date"**, and a station that keeps four
hours of strangers should not dress that up as four months.

What it owes beyond that is plainness in the answer: **`code:404` for a window
it does not hold**, without apology or explanation. Nothing was promised, so
nothing has failed.

The consequence for the asking side is the one that matters. **A client must
never assume any depth exists.** It asks, takes what arrives, and asks somebody
else for the rest. Because a replay is the original packets and duplicates
collapse on their identifiers (section 25.2.1), asking three stations with
overlapping spools is not waste -- it is how a network with no guaranteed
retention still reassembles a week nobody was awake for.

Durability here is social rather than technical: several stations keeping
overlapping spools by their own choice, not one station promising to remember.

### 31.4 Who this protects

The stations worth protecting are the ones that cannot argue back: a solar relay
on a headland, a dongle in a hut, a phone at four percent in a tent. They are
also the stations that make the network reach anywhere interesting.

A budget is therefore not a limitation on generosity but the thing that makes
generosity survivable. A relay that serves until its battery dies has served
nobody by morning.

---

## 32. Adding a field, worked

A format is judged by what it costs to add something it did not foresee. Suppose
a station gains an air-quality sensor.

The implementer takes an unused key, gives it a type and a unit, and transmits
it:

```
t:observation f:X3WX01 pos:38.7223,-9.1393 temp:14.2C zpm:8 ts:2026-08-08_14:26:40
```

82 bytes. The new field costs six bytes. Every existing receiver reads `zpm:8`,
does not recognise the key, skips it, and continues at `ts:`. Nothing is
versioned, nothing is negotiated, and no other field is affected.

The key begins with `z` because unassigned keys belong in the private space. If
this document later assigns it, the entry is added to the table in section 10.3
with its type and unit, and a shorter key may be chosen; nothing else changes.

The same holds for a new word in `q:` and `s:`. A station asking `q:pos,co2`
gets `s:pos` from every station built before CO2 existed, with no error and no
negotiation.

---

## 33. Operating alongside APRS

A licensed amateur may bridge XPRS and APRS under their own callsign and
responsibility, subject to section 9.4. An `X1` or `X3` callsign is generated by
the station itself and assigned by no authority, so traffic from such a callsign
must not be originated onto amateur infrastructure. Ciphertext must never be
placed on APRS, both because APRS is a 7-bit protocol that would corrupt it and
because obscured meaning is not permitted on amateur bands.

---

## 34. Reserved

Assigned packet types: `message`, `observation`, `receipt`, `reaction`,
`request`, `identity`, `track`, `sos`, `warning`, `info`, `challenge`,
`response`, `blog`, `passage`, `event`, `offer`, `need`, `channel`, `mailbox`,
`service`, `command`, `result`, `moderate`, `status`, `place`, `poll`, `file`,
`report`, `ping`, `pong`.
All other lowercase words are reserved.

Assigned keys: `t`, `f`, `d`, `ts`, `tz`, `q`, `s`, `r`, `n`, `via`, `track`,
`seq`, `title`, `dest`, `onboard`, `price`, `cw`, `freq`, `bw`, `shift`,
`urg`, `scope`, `lang`, `nick`, `hold`, `serve`, `cmd`, `arg`, `code`, `near`, `route`, `tone`, `input`, `power`, `mode`, `ch`, `range`, `site`, `supply`, `every`, `for`, `at`, `kind`, `sev`, `rad`, `tag`, `type`, `m`, `file`, `x`, `sig`, `k`, `add`,
`remove`, `grant`, `revoke`, `role`, `hide`, `mood`, `only`, `opt`, `vote`, `root`, `size`, `since`, `until`, `pos`, `alt`, `acc`, `spd`, `dir`, `o`, `climb`,
`temp`, `hum`,
`intemp`, `inhum`, `wave`, `swell`, `seatemp`, `vis`, `press`, `wind`, `wdir`, `gust`, `rain1`, `rain24`, `solar`, `batt`, `volt`,
`rssi`, `snr`, `link`, `busy`, `txtime`, `hears`, `peers`, `mail`, `age`, `epoch`.

Assigned `q:` and `s:` words: section 8.

Reserved prefix: `z`, for both keys and words.

A new field takes an unused key and inherits the skip-unknown rule. A new
purpose takes an unused type. Neither redefines an existing assignment.

---

## 35. Cheat sheet

Everything the format defines, on one page. Each entry is stated in full in the
section it belongs to; nothing here is new.

```
key:value key:value key:value ...
```

Fields separated by one space. `t:` first, `m:` last, and only `m:` may contain
spaces. Keys are 1 to 6 characters, lowercase letters and digits, beginning with
a letter. An unknown key or an unknown type is skipped, never an error. Maximum
packet **250 bytes**, on every transport.

### Packet types

| `t:` | Purpose |
|---|---|
| `message` | a message, to a station, a group, or anyone in range |
| `observation` | an observation: position, movement, weather, telemetry |
| `receipt` | a receipt or an answer to a request |
| `reaction` | a reaction to another message |
| `request` | a request for data another station holds |
| `identity` | an identity announcement, binding callsign to public key |
| `track` | a point in a named track (section 14) |
| `sos` | a call for help (section 15) |
| `info` | a notice about conditions (section 17) |
| `blog` | a published post (section 19) |
| `poll` | a question put to everybody, with the choices (section 28) |
| `file` | what a file is, so it can be wanted (section 6.7.1) |
| `report` | a claim that a packet is spam or abuse (section 29) |
| `place` | somewhere useful that is not the sender (section 30) |
| `status` | a short post about the sender, now (section 27) |
| `passage` | where a vessel is going (section 20) |
| `event` | something happening at a time and place (section 21) |
| `offer` | what a station has (section 22) |
| `need` | what a station wants (section 22) |
| `channel` | a frequency a station uses (section 23) |
| `mailbox` | stations that hold mail for the sender (section 13.12) |
| `service` | what a station does for others (section 24) |
| `command` | asks a station to do something (section 25) |
| `result` | what happened to a command |
| `moderate` | an act of authority in a group (section 26) |
| `challenge` | a challenge to prove a callsign (section 18) |
| `response` | the answer to a challenge |
| `warning` | a warning about a hazard (section 16) |
| `ping` | a reachability test |
| `pong` | a reply to `ping` |

### Envelope keys

| Key | Type | Meaning |
|---|---|---|
| `t` | `enum` | packet type, always the first field |
| `f` | `call` | sending callsign |
| `d` | `addr` | recipient: a callsign, a group name, or absent for a broadcast |
| `ts` | `time` | when the packet was composed, UTC |
| `tz` | `offset` | the sender's offset from UTC, for display |
| `q` | `words` | what the sender wants back (section 7) |
| `s` | `words` | what this packet answers or reports (section 7) |
| `r` | `hex6` | the identifier of another packet this one refers to |
| `n` | `ratio` | this packet is part i of n |
| `tag` | `labels` | topic labels chosen by the sender (section 4.5) |
| `cw` | `words` | what the packet contains, warned before rendering (section 4.6) |
| `urg` | `enum` | how much this is worth carrying (section 13.5) |
| `scope` | `scope` | how far this may be relayed, default global (section 13.11) |
| `lang` | `lang` | language of `m:`, default English (section 4.7) |
| `hold` | `path` | preferred mailboxes, in order (section 13.12) |
| `serve` | `words` | what a station does for others (section 24) |
| `cmd` | `label` | the action a command asks for (section 25) |
| `arg` | `words` | its arguments |
| `code` | `int` | what happened, on a `result` |
| `near` | `qty` | how close to `dest` counts as arrived (section 13.4) |
| `route` | `path` | the route a receipt is acknowledging (section 13.10) |
| `add` | `enum` | something this packet adds (section 6.5) |
| `remove` | `enum` | something this packet withdraws (section 6.5) |
| `grant` | `path` | callsigns admitted to a group (section 26) |
| `revoke` | `path` | callsigns removed or suspended (section 26) |
| `role` | `enum` | what a grant confers: `mod`, `sub`, or absent for a member |
| `hide` | `enum` | what a moderator withdraws from view: `message` |
| `mood` | `enum` | how the sender feels (section 27.1) |
| `only` | `addr` | narrows a replay to one callsign or group (section 25.2) |
| `opt` | `labels` | the choices in a poll, two to six (section 28) |
| `root` | `hex6` | the packet a thread hangs from (section 6.4) |
| `size` | `qty` | how large a file is (section 6.7.1) |
| `vote` | `label` | the option chosen in a poll (section 28.3) |
| `via` | `path` | callsigns that relayed this packet, oldest first (section 13) |
| `track` | `label` | name of a track this packet belongs to (section 14) |
| `title` | `label` | name of a post or event, stable across revisions |
| `dest` | `coord` | where a passage is bound (section 20) |
| `onboard` | `int` | how many people are aboard |
| `price` | `money` | what is being asked or offered (section 22.1) |
| `freq` | `qty` | a frequency (section 23) |
| `bw` | `qty` | bandwidth |
| `shift` | `qty` | repeater input, as an offset from `freq` |
| `input` | `qty` | repeater input frequency, stated outright |
| `tone` | `qty` | access tone |
| `power` | `qty` | transmit power |
| `mode` | `enum` | how a channel is modulated |
| `ch` | `label` | channel number in a band plan |
| `range` | `qty` | expected usable range, an estimate |
| `site` | `enum` | whether the station stays where it is |
| `supply` | `enum` | what powers the station |
| `every` | `qty` | how long between recurring windows |
| `for` | `qty` | how long each window lasts |
| `at` | `clock` | time of day a cycle is anchored to, UTC |
| `seq` | `int` | position of this point within that track |
| `kind` | `enum` | nature of an event, values per packet type (sections 15, 16) |
| `sev` | `enum` | severity of a warning (section 16) |
| `rad` | `qty` | radius of the area affected or asked about (sections 16, 17, 28) |
| `since` | `time` | when the condition started, or will start |
| `until` | `time` | when the sender expects the condition to end |
| `m` | `text` | human-readable content, always last |
| `file` | `ref` | content hash and type of a referenced file |
| `name` | `label` | filename, when the extension is not enough (section 6.7.1) |
| `ph` | `ref` | content hash of a file's piece list (section 6.7.2) |
| `count` | `int` | how many files a folder listing holds (section 6.7.3) |
| `b` | `b64` | a small file's bytes, inline (section 6.7.4) |
| `ih` | `label` | BitTorrent infohash, 40 hexadecimal characters (section 6.7.5) |
| `have` | `label` | what a station holds of a file: `full`, a bitfield, or a fraction (section 7.1) |
| `off` | `qty` | byte offset a `cmd:file` transfer resumes from (section 25.2) |
| `x` | `b64` | sealed body |
| `sig` | `base85` | signature |
| `k` | `bech32` | public key, in `t:identity` and `t:challenge` |

### Position and movement

| Key | Type | Meaning | Quantity |
|---|---|---|---|
| `pos` | `coord` | position | degrees |
| `alt` | `qty` | altitude above mean sea level | distance |
| `acc` | `qty` | horizontal accuracy radius | distance |
| `spd` | `qty` | speed over ground | speed |
| `dir` | `qty` | course over ground, the direction it is travelling | angle |
| `o` | `qty` | heading, the direction it is pointing | angle |
| `climb` | `qty` | vertical speed, signed | speed |

### Weather

| Key | Type | Meaning | Quantity |
|---|---|---|---|
| `temp` | `qty` | air temperature, outdoors | temperature |
| `hum` | `qty` | relative humidity, outdoors | proportion |
| `intemp` | `qty` | air temperature, indoors | temperature |
| `inhum` | `qty` | relative humidity, indoors | proportion |
| `press` | `qty` | barometric pressure, station level | pressure |
| `wind` | `qty` | wind speed, sustained | speed |
| `wdir` | `qty` | wind direction, the direction it blows from | angle |
| `gust` | `qty` | wind gust, peak | speed |
| `rain1` | `qty` | rainfall, previous hour | rainfall |
| `rain24` | `qty` | rainfall, previous 24 hours | rainfall |
| `solar` | `qty` | solar irradiance | irradiance |

### At sea

| Key | Type | Meaning | Quantity |
|---|---|---|---|
| `wave` | `qty` | significant wave height | distance |
| `swell` | `qty` | swell period | duration |
| `seatemp` | `qty` | sea surface temperature | temperature |
| `vis` | `qty` | horizontal visibility | distance |

### Telemetry and station type

| Key | Type | Meaning | Quantity |
|---|---|---|---|
| `batt` | `qty` | battery charge | proportion |
| `volt` | `qty` | supply voltage | voltage |
| `link` | `enum` | which bearer a reading is about (section 10.6) | |
| `busy` | `qty` | proportion of the last hour that bearer was occupied (section 10.6) | proportion |
| `txtime` | `qty` | proportion of the last hour this station transmitted | proportion |
| `hears` | `path` | callsigns heard directly, most relevant first (section 10.6.3) | |
| `peers` | `int` | how many stations are reachable in total (section 10.6.4) | |
| `mail` | `int` | messages held for other stations (section 10.6.5) | |
| `rssi` | `qty` | received signal strength | signal power |
| `snr` | `qty` | signal-to-noise ratio | signal ratio |
| `uptime` | `qty` | how long the station has run without interruption | duration |
| `lifetime` | `qty` | how long the station has run in total, across every restart | duration |
| `odometer` | `qty` | distance travelled over the station's service life | distance |
| `type` | `enum` | what the station is or is riding on, from the set in section 14.2 | |

### Radiation (section 10.5.1)

| Key | Type | Meaning | Quantity |
|---|---|---|---|
| `dose` | `qty` | ambient ionizing dose rate | dose rate |
| `lifedose` | `qty` | ionizing dose accumulated since records began | dose |
| `radon` | `qty` | radon activity concentration in the air | activity concentration |
| `rf` | `qty` | radio-frequency power density | power density |
| `efield` | `qty` | electric field strength | electric field |
| `mfield` | `qty` | magnetic flux density | magnetic flux density |

### Time

| Station capability | Key | Example | Meaning |
|---|---|---|---|
| keeps wall-clock time | `ts` | `ts:2026-08-08_14:26:40` | UTC |
| no clock, no storage | `age` | `age:30` | seconds between observation and transmission |
| no clock, persistent storage | `epoch` | `epoch:7.4210` | boot epoch 7, 4210 seconds into that epoch |

`ts:` is when the packet was written; `since:` and `until:` are when the thing
it describes begins and ends. All are `YYYY-MM-DD_HH:MM:SS` in UTC. `tz:`
carries the sender's offset, for display only.

### Units

Every measurement carries its unit, immediately after the number, with no space.

| Quantity | Units | Canonical |
|---|---|---|
| distance, altitude | `m`, `km`, `ft`, `mi`, `nmi` | `m` |
| speed | `m/s`, `km/h`, `mph`, `kt` | `m/s` |
| angle | `deg`, `degm` | `deg` |
| temperature | `C`, `F` | `C` |
| pressure | `hPa`, `inHg` | `hPa` |
| rainfall | `mm`, `in` | `mm` |
| duration | `s`, `min`, `h`, `day`, `week` | `s` |
| frequency | `Hz`, `kHz`, `MHz`, `GHz` | `Hz` |
| transmit power | `W`, `mW`, `kW`, `dBm` | `W` |
| irradiance | `W/m2` | `W/m2` |
| voltage | `V` | `V` |
| proportion | `%` | `%` |
| signal power | `dBm` | `dBm` |
| signal ratio | `dB` | `dB` |
| dose rate | `nSv/h`, `uSv/h`, `mSv/h` | `uSv/h` |
| dose | `uSv`, `mSv`, `Sv` | `uSv` |
| activity concentration | `Bq/m3`, `pCi/L` | `Bq/m3` |
| power density | `uW/m2`, `mW/m2`, `W/m2` | `W/m2` |
| electric field | `V/m`, `kV/m` | `V/m` |
| magnetic flux density | `nT`, `uT`, `mT`, `mG` | `uT` |

`deg` is true and `degm` is magnetic. A receiver converts to the canonical unit
before comparing, storing or plotting. `pos:` is the one measurement with no
unit: always decimal degrees, WGS84.

### Numbers

The decimal separator is `.`, never `,`, because a comma already separates
latitude from longitude and words in a list. No thousands separator:
`alt:11240m`. Leading `-` for negative, no `+`, no exponent. A digit before the
dot, never a trailing dot. Trailing zeros are significant.

### Asking and answering

`q:` asks and `s:` answers with the same words, several separated by commas.

Assigned: `ack`, `read`, `sign`, `pos`, `batt`, `identity`, `pong`, `no`.

`s:no` means the request will not be served at all. A partial answer names only
what it satisfied.

A direct message between two stations that have exchanged one before is answered
with `t:receipt … s:ack` **without** `q:ack` (section 13.7.1). Broadcasts, group
and regional messages, receipts, and strangers are never answered automatically.

### What a station is, or is riding on

`type:`

| Group | Values |
|---|---|
| On foot | `foot`, `run`, `ski`, `horse` |
| Cycles | `bike`, `ebike`, `motorcycle` |
| Road | `car`, `bus`, `truck`, `tractor`, `emergency` |
| Rail | `train`, `tram` |
| Water | `boat`, `sailboat`, `ship`, `kayak` |
| Air | `airplane`, `helicopter`, `glider`, `balloon`, `drone` |
| Fixed | `node`, `digi`, `wx`, `home`, `portable` |

### What an event is

`kind:`, scoped to the packet type it appears in.

| Packet | Values |
|---|---|
| `sos` | `medical`, `trapped`, `lost`, `fire`, `water`, `cold`, `assault`, `vehicle`, `other` |
| `warning` | `fire`, `flood`, `storm`, `wind`, `snow`, `ice`, `quake`, `tsunami`, `landslide`, `chemical`, `radiation`, `outage`, `road`, `crowd`, `animal`, `other` |
| `info` | `traffic`, `stopped`, `slow`, `works`, `closure`, `rain`, `snow`, `ice`, `fog`, `wind`, `debris`, `animal`, `crowd`, `event`, `other` |

`sev:`, on a `warning` only:

| `sev:` | Meaning |
|---|---|
| `watch` | may affect you, be ready |
| `warning` | will affect you, act now |
| `danger` | life-threatening, leave |

### Content warnings

`cw:`, one or more words separated by commas.

| Word | Contents |
|---|---|
| `adult` | sexual content |
| `nudity` | nudity that is not sexual |
| `violence` | violence |
| `injury` | graphic injury, blood, surgery |
| `death` | death, human or animal |
| `drugs` | drug or alcohol use |
| `language` | profanity |
| `spoiler` | spoils something the reader may not have seen |
| `flashing` | rapid flashing or strobing |
| `other` | something else the sender thinks needs a warning |

Repeated on every part, covers any `file:`, stays in cleartext when the body is
sealed, never stripped by a relay. Absence is not a guarantee.

### Prices

```
120EUR        firm          ~120EUR       negotiable
25EUR/day     per day       ~25EUR/day    negotiable, per day
offers        make one      swap          wants a trade
free          nothing       (absent)      not stated
```

Currency is an ISO 4217 code, three uppercase letters, never a symbol. Periods:
`h`, `day`, `week`, `month`, `year`.

### Channels

`t:channel`, one packet per frequency. `power:` present means the station
transmits there; absent means it only listens.

```
kind:    listen simplex repeater beacon net gateway emergency other
mode:    fm am usb lsb cw ssb packet aprs lora ft8 psk31 rtty dmr dstar c4fm m17 dv other
site:    fixed mobile portable temporary
supply:  grid solar wind hydro battery generator fuel mixed
```

Recurring windows: `every:` between them, `for:` how long each lasts, `at:` the
UTC time of day the cycle is anchored to, default `00:00:00`. The 3-3-3 plan is
`ch:3 every:3h for:3min`. `since:` and `until:` bound the schedule itself.

`freq:` is what you tune to hear the station. A repeater's input is `shift:` as
an offset or `input:` outright, the latter for cross-band.

`range:` is the operator's estimate, not a guarantee.

### Carrying toward a place

`dest:` where it is bound, `near:` how close counts as arrived, `until:` when to
stop (required, never more than a year out), `urg:` `low` `normal` `high`
`urgent`. A carrier takes a copy only if it expects to get closer. Not bound by
the three-relay limit.

`lang:` names the language of `m:`, default English: `PT`, or `PT/BR` for a
regional variant.

`nick:` is a signed, human-readable name on `t:identity`. Shown only when the
signature verifies, newest `ts:` wins, and never usable as an address.

### Commands

`t:command` with `cmd:` and `arg:`; `t:result` with `code:` naming it in `r:`.

```
200 done   202 accepted   400 bad args   403 refused
404 unknown   408 too old   500 failed
```

Answer at once with 202 even when the work takes minutes; any number of results
may name one command. Splits across parts like a message; `cmd:interpret` puts a
natural-language instruction in `m:` for a station that reads it, and a reply
names the reassembled packet rather than any part. Must be signed, expires after 300 s unless `until:` says
otherwise, never carried, never shown as a message. Authentication is not
authorisation -- the allow-list is the bot's.

`t:service` advertises what a station does: `relay` `mailbox` `internet` `aprs`
`nostr` `files` `time` `weather` `wifi` `other`. Physical goods are `t:offer`,
not this. A claim about capability, never evidence of good faith.

`t:mailbox` names the stations that hold mail for the sender, `hold:` in order
of preference. Several coexist, each optionally bounded by `since:` and `until:`;
the narrowest window containing the moment wins. Cancel one with `r:` and
`remove:mailbox`. All of it must be signed, and an unverifiable one ignored.

`scope:` limits where a packet goes: absent or `global` anywhere, `local` only
on BLE, WiFi Direct, WiFi Aware and a LAN, or ISO country codes. Not carried
when `local`, and binding on gateways. Reception is never restricted, only
relaying. A group is an address, not a boundary -- only `x:` keeps content
private.

### Catching up, and fetching

```
t:command f:X1BOA3 d:X3RLY7 ts:... cmd:history since:... sig:...
t:command f:X1BOA3 d:X3RLY7 ts:... cmd:history since:... until:... only:X5A3F2 sig:...
t:command f:X1QZ3N d:X3RLY7 ts:... cmd:file file:nYxKz...M1w.jpg [off:64kB] sig:...
t:command f:X1QZ3N d:X3RLY7 ts:... cmd:put file:nYxKz...M1w.jpg size:2MB [until:...] sig:...
```

Standard commands carry parameters in named keys, never `arg:`. The station
answers `code:202`, re-airs the **original packets unchanged**, then `code:200`.
`206` instead means that was one page and more exists: the replay runs **newest
first**, so continue by moving `until:` to the oldest `ts:` you received and
asking again. No cursor, no session. `404` nothing held, `403` refused, `429`
over budget with alternatives in `m:`.
Derived identifiers make the replay safe: a duplicate collapses on the identifier
it already had, so there are no cursors and overlapping windows cost only
airtime. Advertise a spool with `serve:history`, files with `serve:files`.

### Mentions, threads and files

A mention is `@CALLSIGN` **inside `m:`** -- no key. `@` then uppercase letters,
digits, `-` and `/`, ending at the first character that is not one; uppercase is
why `me@example.com` is not a mention. No limit but the packet limit. Being named
raises a notification and is the strongest signal for what to keep. Anyone may
mention anyone, so a client must offer to mute.

`root:` names the packet a thread hangs from. A first-level reply carries `r:`
alone; deeper replies carry both, so a lost middle packet no longer orphans
everything beneath it.

`t:file` says what a file is: `file:` the hash (43 base64url characters, a
dot, the type), `size:` with its unit, `tag:` topics, `m:` the description,
optionally `name:` the filename and `ph:` the piece list's own hash. `size:`
is what lets a station decline before starting a fetch it cannot finish, and
the description is the only thing that makes a file findable by words rather
than by hash.

Files, the whole flow (section 6.7): a listing file (`XFL1`, one `ref size
name` line per file, sorted by name) is a folder; announce it with `t:file
kind:folder count: size:`; fetch anything with `cmd:file` (resume with
`off:`), find holders with `q:have` (`have:full`, a bitfield, or `412/900`),
deposit with `cmd:put file: size: [until:]` and the signed `code:200` is the
custody receipt. A file up to 896 bytes rides inline in `b:` over section 6.6
parts, joined with nothing. Piece lists (`sha size` per line, piece order)
let partial holders serve what they verified. The BitTorrent infohash is
derived deterministically and never needs transmitting between stations.

### The radio itself

```
t:observation f:X3RLY7 ts:... link:lora busy:41% txtime:6% hears:X1QZ3N,X32DVA
```

**`link:` names the bearer and is required** -- `lora` `ble` `wifi` `halow` `lan`
`internet` `vhf` `uhf` `hf` `cb` `pmr` `satellite` `other` -- because a station
here is not one radio on one channel, and a figure averaged across LoRa and a LAN
is not a quantity. A reading without it is discarded; report once per bearer.

`busy:` how much of the last hour that bearer was occupied by anybody, `txtime:`
how much of it was **this** station, `hears:` callsigns heard **directly** on it,
most relevant first (the sender decides what relevant means), `peers:` how many
are reachable in total so a truncated list is honest. Window is one hour and is never on the wire, so numbers compare.
Keys on `t:observation`, never a new type -- design rule 5.

`busy:` is what section 31 was missing: a duty cycle limits one transmitter and
says nothing about the forty others already on that bearer. Rising `busy:` means
slow down what is discretionary -- beacons, statuses, history replays -- and let
`urg:` decide what survives. A station reporting `busy:60%` with
`txtime:45%` has found the problem and it is itself.

`hears:` says why a mesh is broken, who to route through, and who is worth naming
in `hold:`. Hearing is often asymmetric -- two stations listing each other can
reach each other; one listing the other cannot.

### Reporting

```
t:report f:X32DVA d:X5A3F2 ts:... r:399227 kind:spam sig:...
```

`kind:` is `spam` `abuse` `illegal` `false` `other`. Must be signed. A report is
a **claim, never a verdict** -- nothing acts on it automatically, and `hide:`
(section 26.3) remains the only packet that hides anything. Mass false reporting
is the obvious attack, so a report is worth its signer's standing and no more.
Reporting is not blocking: muting is local, needs no packet and tells nobody.

### Polls, and passing things on

```
t:poll f:X1QZ3N d:LISBOA ts:... opt:sagres,lagos,portimao until:... m:where shall we meet?
t:reaction f:X32DVA d:LISBOA r:7a9b50 vote:sagres
t:reaction f:X32DVA d:LISBOA r:7a9b50 remove:vote
```

`opt:` is two to six labels. **`until:` is required** -- a poll without it is not
counted, because a poll that never closes has a different answer every time
anybody replays it. Narrow the audience with `d:` (a group), `scope:` (`local` or
country codes), `pos:` with `rad:`, or `lang:`; those say who is being **asked**,
never who may answer, and a counter usually cannot check `rad:` at all because a
vote carries no position.

A vote is a reaction, so it is one per callsign,
idempotent and withdrawable; voting again replaces the earlier vote. The count is
**local and provisional** -- every station counts what it heard, the author's
tally is not authoritative, and a client that shows "7 votes" where it means "7
that reached me" has lied by rounding. **Not a secret ballot**: who voted for
what is public and permanent.

Reply is `r:`. A **quote** is a reply that carries `m:` -- no separate mechanism.
A **repost** is `add:repost` / `remove:repost` on a reaction, and what travels is
the original packet with `f:`, `ts:` and `sig:` untouched, so duplicates collapse
on the identifier and a post reposted by nine stations is still one post. A
repost adds nothing and so cannot misrepresent; a quote is your own packet with
your own words.

### Places

`t:place` reports something that is not you and does not move. `kind:` from:

```
anchorage mooring ramp jetty beach fuel water repair
shelter hut camp spring ford pass summit trailhead other
```

`pos:` where, `title:` names it and a later place with the same title from the
same station replaces it, `until:` for temporary, `file:` for a photograph,
`remove:place` to withdraw. Newest wins per signer; a client shows who said it.
A hazard is `t:warning` and a call for help is `t:sos` -- both carry a relay
budget a place does not.

### Airtime

Unsolicited traffic is bound by the **strictest bearer** a station transmits on,
not the loosest. A beacon is not free; a retry is not a new packet. Serving
yourself is unmetered, serving a stranger is optional, metered and bounded per
period (section 18.4's precedent). Refuse out loud with `code:429` and name
somebody else -- silence and refusal look identical to the asker and mean
opposite things.

**Retention is the station's own** -- this format sets no period, no minimum and
no eviction order. A spool is not a time window: a station may keep a followed
callsign for a year and a stranger for an afternoon, so it advertises
`serve:history` and never a depth. Answer `code:404` for a window you no longer
hold. A client assumes no depth: ask, take what arrives, ask somebody else for
the rest.

### Status

`t:status` is a short post about the sender, now -- the townhall packet. No
`title:` and it never replaces an earlier one, which is what separates it from
`t:blog`. `d:` absent publishes to anyone in range; `d:` on a group makes it that
group's timeline. Three relays, never carried, replies and reactions both.
Following is a list on the client and never a packet.

`mood:` is optional and one word from this list, for theming only:

```
general   blessed grateful happy sad tired lonely proud worried calm determined
sea       becalmed adrift anchored seasick salty stormbound landsick soaked
          homebound windblown
mountain  summited breathless snowbound frostbitten footsore exposed sheltered
          benighted acclimatised whiteout
```

An unrecognised mood is skipped and the post shown plainly. A mood never earns a
relay, a priority or a notification -- `urg:` speaks to the network and `sev:` to
danger. For a mood this list does not have, `zmood:` is private by section 4.9.

### Closed groups

A group holds a keypair and is addressed by the `X5` callsign derived from it.
The admin holds that key; handing it over is the whole of succession. The group
announces itself with `t:identity` and names itself with `nick:`.

```
t:moderate f:X5A3F2 d:X5A3F2 ts:... grant:X1RD89,X32DVA sig:...
t:moderate f:X5A3F2 d:X5A3F2 ts:... grant:X32DVA role:mod until:... sig:...
t:moderate f:X32DVA d:X5A3F2 ts:... revoke:X1PZ4Q until:... sig:...
t:moderate f:X32DVA d:X5A3F2 ts:... r:89a9c8 hide:message sig:...
t:moderate f:X5A3F2 d:X5A3F2 ts:... revoke:X32DVA since:... sig:...
```

A subgroup is an ordinary closed group with its own key, listed by another with
`grant:<X5> role:sub` and delisted with `revoke:`. Listing confers no authority
inside it and membership does not travel down. Five levels counting the root; a
listing that makes a cycle is ignored.

`f:` signs, `d:` names the group. `revoke:` with `until:` is a suspension;
`revoke:` with `since:` voids that moderator's acts from then. Only the admin
appoints; a moderator may revoke and hide. Authority is judged at the act's
`ts:`; newest per signer wins, identifier breaks a tie, a future `ts:` is
discarded. `until:` on a grant is optional, revocations are kept. Asking to join
is an ordinary message -- there is no join packet.

**Never filter `sos`, `warning`, `info` or replies to them.** A client that
cannot verify shows everything and marks the group unverified. Closed is not
private: the roster and the whole moderation history are public, permanent and
gatewayed, which is more exposure than an open group, not less.

### Licensed spectrum

| | Licence-free and internet | Licensed spectrum |
|---|---|---|
| `f:` | any, `X1` and `X3` included | only a callsign issued to that operator |
| `sig:` | permitted | permitted |
| `x:` | permitted, default on direct messages | never on amateur bands |
| `t:challenge` | works | cannot: it seals a nonce |

**A self-generated callsign never goes on a licensed frequency**, and a gateway
must drop such packets rather than relay them under its operator's licence.
Announce an issued callsign with `t:identity` under that callsign to bind it to
a key; the signature proves key possession, and entitlement is checked against
the authority's register, never in a packet. Signing is lawful on amateur bands
because a detached signature leaves `m:` in clear; sealing is not.

`near:` is not `rad:`. `rad:` is the area a subject occupies; `near:` is how
close to `dest:` is close enough. A warning carried to a town uses both.

`dest:` with no `d:` delivers to a region rather than a person; nothing is
acknowledged.

Two copies by different routes share one identifier, so the recipient sees the
message once and keeps both `via:` lists as routes that work.

Seal the body with `x:` and leave the routing keys in cleartext. Coarsen
`dest:` -- it geolocates your correspondent.

`q:sign` asks for a signed receipt; it copies the arrival `via:` into `route:`
and signs it. `s:sign` without a valid `sig:` is discarded.

`sig:` goes on every packet by default, 65 bytes. Drop optional fields before
dropping the signature. Not signed: `challenge`, `response`.

### Identifiers

Never transmitted. Both ends compute
`sha256(the packet, with sig: and via: removed)` and take the first 6
hexadecimal characters. `r:` carries an identifier
when referring to another packet, including the sender's own when withdrawing it.
Signing and relaying do not change it, which is exactly why those two fields come
out before hashing.

### Limits

| Thing | Limit |
|---|---|
| packet, every transport | 250 bytes |
| parts in one message or post | 9, `n:1/9` to `n:9/9` |
| titled post, inline | about 1650 characters |
| relays, `sos` and `warning` | 9 |
| relays, everything else | 3 |
| incomplete set of parts held | 10 minutes |
| challenge answered within | 60 seconds |
| group name | 1 to 16 characters, uppercase |
| callsign | any length, uppercase |

### Private use

Keys, and `q:` and `s:` words, beginning with `z` are never assigned by this
document.

---

## 36. Publishing, and the indexers you choose

APRS-IS is a server you connect to. Everything you send becomes everyone's,
everywhere, and everything anyone sends comes back at you as a firehose you
filter locally. It works, it has worked for decades, and it has one centre.

This section describes the same service without the centre: **a station keeps
its own publications and hands them to the indexers its operator chose.** No
station is obliged to have an indexer, and no indexer sees traffic from a
station that did not pick it.

### 36.1 What a publication is

An indexer holds two different things, and the difference is `d:`.

| | What it is | What the indexer does with it |
|---|---|---|
| **A publication** — no `d:`, and a type from the list below | offered to whoever is interested | answers queries about it, to anybody |
| **Mail** — anything carrying `d:` | addressed to one station | holds it for that station and tells them it is there; never offers it to a third party (section 36.7) |

Publication types: `blog`, `passage`, `event`, `offer`, `need`, `place`,
`poll`, `track`, `warning`, `info`, `status`, `channel`, `service`, `file`,
`sos`, `observation`, `identity`.

The last two are what makes a gateway useful to anyone beyond its own hill. A
gateway publishing its OWN `t:observation` is publishing a reachability
record: `f:` says which gateway, `hears:` says which radio-only stations are
at its ear right now, and `ts:` says how fresh that claim is — the whole
"where can X1BOA3 be reached" question answered by a packet that already
existed. And a gateway passes on the `t:identity` (and `t:mailbox`) packets
of the stations it hears verbatim, which section 36.2 already makes safe:
the author's signature travels with the packet, so an indexer's copy proves
itself against the author's key, not against the gateway's honesty.

Neither published nor held: `ping` and `pong`. They measure whether a path is
alive right now, and a stale one answers a question nobody is still asking.

**Addressing decides, not the type.** A rule that named types would have to be
re-litigated every time a type gains a `d:`, and the packet already says who it
is for. So a `t:message` is mail, a `t:command` to a station that is asleep is
mail, and a `t:warning` with no `d:` is a publication — which is what each of
them plainly is.

### 36.2 The indexer is sent the packet, not a description of it

An indexer receives the publication **exactly as it was composed and signed**:

```
t:warning f:X3RLY7 pos:39.40,-8.20 rad:5km dest:38.72,-9.14 near:40km urg:urgent kind:fire sev:danger until:2026-08-10_00:00:00 ts:2026-08-08_14:26:40
```

150 bytes — the section 16 example, unchanged, because nothing about publishing
changes a packet. There is no envelope format, no summary record and no
transformation step, which means there is also no second schema to design, keep
in step with the first, and get subtly wrong.

**Why this is affordable, when the file layer's answer was the opposite.** The
DHT stores pointers and never content, because a file is megabytes and a pointer
is 176 bytes. A publication is at most 250 bytes. Pointer and content are the
same order of size, so paying for a pointer *and then* a fetch costs more than
handing over the thing itself. The rule is not "always send pointers"; it is
"send whichever is smaller", and for XPRS that is the packet. The inline file
lane (section 6.7.4) is the same rule applied once more: under ~900 bytes the
content IS the smaller thing, and it rides the packets.

**Everything a query needs is already in it.** `t:` the type, `f:` the author,
`ts:` when it was composed, `pos:` where it is, `dest:` and `near:` the region
it is addressed to, `until:` when it stops mattering, `scope:` how far it may
travel. An indexer answers by reading fields it was handed.

**And the signature travels with it.** An indexer passing on a third party's
publication can neither forge it, retarget it nor resurrect it, and the receiver
verifies against the author's key rather than trusting the indexer that handed
it over. That is what makes gossip between indexers safe, and it is the same
property section 9.1 already gives every signed packet.

### 36.3 You choose your indexers

**A station pushes to the indexers its operator picked, and to no others.**

- The list is configuration: editable, with defaults, and adding or removing an
  indexer is an ordinary act rather than a reinstall.
- **Zero indexers is a valid, working configuration.** Such a station keeps its
  publications and serves them to anyone who asks over the radio (section 36.5).
  It is simply not findable by somebody who was not listening at the time. That
  is a fair trade and it must remain available: a station that talks only to the
  people in range of it is not a degraded station, it is a private one.
- The choice is **per station, not per operator**. One person's phone may push
  to two indexers while their node in the shed pushes to none.
- An indexer may decline what it is offered. Its disk, its bandwidth, its
  decision — the same rule section 31.2 states for serving strangers.

The station remembers **what each indexer has already had**, as a position in
its own log rather than a time (section 13 makes the same argument for cursors:
a position cannot skew, and a device with no clock can still persist one). A
reconnect resumes; it does not re-send.

### 36.4 When to push

**When there is a link and it is cheap.** Publishing is not urgent traffic: a
blog post that reaches the index four hours late has lost nothing, and a station
that spends its LoRa duty cycle pushing publications has spent it on the wrong
thing (section 31.1).

So the push belongs to the bearer that is cheap and plentiful — internet or a
wired link — and the radio carries publications the way it always did: as
packets, to whoever is listening, once.

### 36.5 Asking a station directly

A station that heard something and wants the rest asks the author, with a verb
that already exists:

```
t:command f:X1BOA3 d:X3RLY7 ts:2026-08-08_14:26:40 cmd:history since:2026-08-04_00:00:00 sig:<60 characters>
```

153 bytes (section 25.2). It is already metered by the airtime rules, already
refusable with `code:429`, and already the answer to "I was not here, what did I
miss". Publishing adds no verb of its own.

### 36.6 What replaces the filter

An APRS-IS client subscribes with a filter and receives a stream. Here a reader
**asks an indexer a question** and gets the packets that answer it: by author,
by type, by region and radius, by time window. Every one of those reads a field
the packet already carries, so the query surface needs no vocabulary of its own
and cannot drift from the format it queries.

One reading rule makes the reachability question askable without any new
word: **`only:` matches a callsign wherever the packet carries it** — as
author, as addressee, or inside a list field (`hears:`, `hold:`, `via:`,
`grant:`). "Everything about X1BOA3" naturally includes the gateway
observations that list it as heard, which is the answer to "where can X1BOA3
be reached". Worked, against an indexer:

```
165  t:command f:X1QZ3N d:X3IDX1 ts:2026-08-17_14:00:00 cmd:history only:X1BOA3 since:2026-08-17_13:00:00 sig:<60 characters>
```

The reply is the section 25.2.1 replay — `code:202`, the original packets,
`code:200` — and among them:

```
169  t:observation f:X3RLY7 link:lora peers:6 hears:X1BOA3,CT1ABC-9,X5A3F2 uptime:9day ts:2026-08-17_13:59:20 sig:<60 characters>
```

The gateway's own packet, unchanged, signature and all: X1BOA3 was at
X3RLY7's ear forty seconds before the ask. The reader now knows which
internet-connected station is one radio hop from the recipient, and how
stale that knowledge is — `ts:` is the freshness, and a reader that gets
three gateways back simply prefers the newest.

The difference that matters is not the syntax. It is that the reader chose the
indexer, the publisher chose the indexer, and neither had to be the same choice
for the network to work.

### 36.7 An indexer is also a mailbox

**The sender is usually gone.** Somebody writes a message on a phone, the phone
is put in a pocket, the screen goes off and the radio with it. If delivery
depended on that phone still being reachable when the recipient next wakes up,
most messages between people who are not simultaneously awake would never
arrive. That is the whole reason store-and-forward exists (section 13.3), and an
indexer is the best carrier on the network for it: always on, addressable, and
chosen deliberately.

So **mail is handed to an indexer too**, and the indexer tells the recipient
there is something waiting. An indexer is therefore a natural entry in a
station's `hold:` list (section 13.12) — that mechanism already exists and needs
nothing added.

**Privacy is the content's problem, and the format already solved it.** Seal the
body with `x:` (section 9.2) and the indexer stores something it cannot read:

```
t:message f:X1QZ3N d:X1RD89 ts:2026-08-13_10:14:00 x:pQ4m9xT2vB8kR until:2026-08-20_00:00:00 sig:<60 characters>
```

157 bytes. **Be clear about what that does and does not hide.** `t:`, `f:`, `d:`
and `ts:` stay in cleartext, because a station that cannot see who a packet is
for cannot deliver it. The indexer therefore learns that X1QZ3N wrote to X1RD89
at that minute, and how often the two of them do that — and so did every
APRS-IS server, for every message, in full. Encryption protects the contents;
choosing your indexer is what protects the pattern.

**It is a hold, not an archive.** `until:` bounds it, and the indexer releases
its copy the moment it hears a receipt whose signature it has verified — the
rule section 7 already states for every carrier, and the reason section 13.7.1
insists a receipt be signed: an unsigned one would let a stranger delete other
people's undelivered mail from every indexer holding it.

An indexer may of course refuse to carry mail at all, or carry it only for
stations it knows. Its disk, its bandwidth, its decision (section 31.2).

### 36.8 The gateway is the last mile

Sections 36.1 and 36.6 built the outbound half: the gateway told the indexer
who it hears, and a sender found the gateway. This section is the return leg
— how mail deposited at an indexer reaches a station that has never touched
the internet and never will.

The tension is real and must be stated before it is resolved. Section 36.7
says mail is never offered to a third party, and a gateway asking for
somebody else's mail IS a third party. Section 13.12 solves it only for
stations that declared a mailbox — and a solar tracker on a ridge has had no
way to declare anything to an indexer it cannot reach.

The resolution splits on what the mail is:

- **Sealed mail travels on the strength of the seal.** A packet whose body is
  `x:` (section 9.2) is ciphertext to everyone but the recipient; carrying it
  is what custody already is (section 13.6), and handing it to one more
  carrier discloses nothing the airwaves would not. An indexer releases
  sealed mail to a station whose own published observation currently lists
  the recipient in `hears:` — the gateway one radio hop from delivering. A
  false `hears:` buys an attacker a copy of ciphertext and the envelope
  metadata the indexer already held, which section 36.7 already priced.
- **Clear mail is released only to a declared holder** (`hold:`, section
  13.12) or fetched by the recipient itself. Plaintext is disclosure, and
  disclosure follows the recipient's stated arrangements or nobody's.

The delivery is then ordinary. The sender seals and deposits:

```
162  t:message f:X1QZ3N d:X1BOA3 ts:2026-08-17_14:02:00 x:pQ4m9xT2vB8kRZ7cW0yLuJ3gRhN8sEiDoQ6vXaB1MnYw sig:<60 characters>
```

The gateway X3RLY7, whose observation listed X1BOA3, collects it, airs it on
the radio under the custody rules of section 13, and the receipt comes back
the same path:

```
130  t:receipt f:X1BOA3 d:X1QZ3N r:b47210 ts:2026-08-17_14:19:12 s:ack sig:<60 characters>
```

The receipt is signed by the recipient, so the indexer verifies it and
releases its held copy (section 36.7), the gateway archives its own, and the
sender — three networks away — knows the tracker on the ridge has the
message. Nothing in the chain trusted the gateway with anything but
ciphertext and effort. This is APRS's iGate rebuilt with the trust turned
the right way around: the iGate proved useful by what it heard and carried,
never by what it could read.

---

## 37. Implementation status

| Element | State |
|---|---|
| **On the air** | **implemented** on the Flutter side: the discovery beacon is an XPRS `t:observation` on its own BLE5 subtype `0x58` (`docs/ble5.md`), carrying `peers:`, `hears:` and `mail:`; `MeshCourier` emits XPRS for every carried message, and custody reads it. The **chat wapp emits XPRS too** since 0.4.38 — 1:1, group, broadcast and position (`wapps/chat/xprs.c`, `docs/aprs-xt.md` section 2.2) — keeping the compact frame only for its own control frames (`?MAIL`, `?IGATE`, `?PING`) and for a body over 250 bytes. Every receiver still reads both, so an un-ported peer keeps working. The ESP32 T-Dongle (`esp32/rns_ble5`) speaks XPRS too via `esp32/components/geogram_xprs`, a C mirror of `lib/services/xprs/` replaying the same 205-example corpus: it reads both subtypes, parks `t:message` mail by derived identifier, relays with `via:`, answers `t:ping` with `t:pong rssi:` (rate-limited per section 31.2), refuses `scope:local` at custody admission, dates its packets `epoch:` (section 10.7, NVS boot counter) and transmits unsigned |
| **The packet format itself** | **implemented**; `lib/services/xprs/` parses, encodes, derives identifiers and signs. Every example packet in this document is a test fixture: `test/xprs_packet_test.dart` round-trips all 201 byte-exact, checks each stated byte count, and cross-checks every identifier against an independent Python implementation |
| Section 5 identifiers | **implemented** |
| Section 9.1 signatures, and surviving a relay | **implemented**; `test/xprs_sig_test.dart` signs, relays three hops and re-verifies |
| Section 13.1 relay budget, 13.2 loop check | **implemented** in the codec (`xprsMayRelay`, `xprsWouldLoop`); nothing transmits `via:` yet, so nothing calls them on the air |
| Section 13.11.3, `scope:local` is never carried | **implemented**; refused at custody admission in `MeshCustodyDelegate` |
| Callsigns, signatures, verification | implemented |
| Signing by default on every packet type | not implemented; signing exists and is opt-in |
| Direct, group and broadcast messages | implemented |
| Replies and reactions | implemented |
| Receipts and carrier release | implemented, for receipts that were asked for with `q:` |
| Section 36.7, an indexer holding mail | **specified, not implemented** as an indexer role, but the parts are live elsewhere: `MeshStore` already parks a frame for an absent station and releases it on delivery, and the LXMF propagation mailbox already holds what could not be pushed and serves it when the recipient pulls. What is missing is an indexer being a station's declared `hold:` and telling a recipient that something is waiting |
| Section 36, publishing to chosen indexers | **specified, not implemented.** Every piece it is built from exists — the signed-record discipline, the append-only log with an (epoch, seq) cursor, indexer-to-indexer catch-up and indexers as the DHT's anchors are all live for FILES (`files/dht/`, `social/relay_node.dart`) — but nothing yet keeps a publication log, pushes packets to a chosen indexer, or answers a query from their fields. The section deliberately adds no packet type and no key, so there is nothing on the wire to implement: the work is all plumbing |
| Section 36.1, gateway reachability publications (`observation`/`identity` to an indexer) | **specified, not implemented** as a push; the raw material is live — every phone beacons `hears:` and the ESP32 digipeats — but no gateway publishes its observation to an indexer and no indexer answers for one |
| Section 36.6, `only:` matching inside list fields | **partly implemented**: the shipped history responder matches `only:` against author and addressee (`xprs_archive.dart` query); `hears:`/`hold:`/`via:`/`grant:` containment is not searched yet |
| Section 36.8, sealed-mail release to a hearing gateway | **specified, not implemented**; the nearest live relatives are the chat iGate mailbox (mail pulled from APRS-IS by an in-range station) and MeshStore custody, neither of which is driven by a published `hears:` claim |
| Section 3.1, one person on several devices | **specified, not implemented.** Nothing numbers a device today: a station wears its bare callsign, and the chat wapp matches `d:` against that alone. The pieces the rule needs are already on the air — a beacon carries `f:` and `lx:`, so a device can see a sibling and tell it apart — but no code adopts a suffix, prefers the conventional number for its `type:`, or refuses a command addressed to a person |
| Section 13.7.1, receipts signed by default | **specified, not implemented.** Signing exists (section 9.1) and receipts do not use it yet, which leaves the forged-`s:ack` deletion described there open on any station that honours the section 7 carrier release. The Reticulum side is not exposed to it — its acknowledgement is a link, not an XPRS packet — but an XPRS-native carrier would be |
| Section 13.7.2, parking a retry with no evidence | **implemented** on the Reticulum side: a retry is spent only against a live path or a beacon heard in the last three minutes (`RnsService._peerReachable`), otherwise the entry parks without burning a rung and the copy stays held |
| Section 13.7.1, receipts without asking | **specified, not yet on the air.** The rule and its exclusions are settled and the two example packets are test fixtures; no station sends an unasked `s:ack` yet. What made it necessary is fixed already on the Reticulum side: an unacknowledged single-packet delivery no longer reports itself as delivered, and the sender retries at 20s/60s/5min before leaving the copy held (`lxmf_router.dart`) |
| Long messages in parts | implemented |
| Encryption and the sealed-body band rule | implemented |
| Section 9.4.1, no self-generated callsign onto licensed spectrum | not implemented, and violated today: the ESP32 iGate computes an APRS-IS passcode for an `X3` callsign and states in `esp32/components/geogram_aprsis/aprsis.h` that no licence is needed for one |
| Section 9.4.2, an issued callsign bound to a key by `t:identity` | not implemented; identity announcements are not built, and no user interface offers to enter a licensed callsign |
| File references by content hash | **implemented**, in the base64url form this document now specifies (`MediaRef`); the older 64-hex form is still read |
| Identity announcement | implemented |
| `key:value` fields separated by spaces | **implemented** everywhere the device transmits: the beacon, carried mail, and the chat wapp since 0.4.38. The three-`0x1F`-field frame remains only as a fallback that is still read, and that chat still sends for its control frames |
| `t:` packet type as the first field | **implemented**; chat's own routing (a callsign, a `#group`, `!` for a position, empty for in-range) is now expressed as `t:` plus `d:`, not inferred from one overloaded field |
| Derived identifiers | not implemented; the current wire hashes message content without a timestamp, so every `OK` collides, and carries a separate receipt identifier |
| `ts:` on messages | **implemented** on the chat wire since 0.4.38: a message now states when it was written, so one that waited in a mailbox no longer shows the minute it arrived. A packet with no `ts:` is still read (section 10.7) |
| `q:` and `s:` | not implemented; receipts exist, requests do not |
| `via:` instead of rewriting `f:` | not implemented; a carrier currently retransmits under its own callsign, which breaks both authorship and the identifier |
| Relay limit by packet type | not implemented; custody re-airs a fixed three times with no path recorded |
| `t:track` tracks | not implemented; no track is recorded or published |
| `t:sos` calls for help | not implemented; the current wire has an `sos` station symbol, which is a different thing and is not relayed further than any other packet |
| `t:warning` warnings | not implemented; no source |
| `t:info` notices | not implemented; no source |
| `t:blog` posts | not implemented |
| `wave`, `swell`, `seatemp`, `vis` | not implemented; no source |
| `t:passage`, `t:event`, `t:offer`, `t:need` | not implemented |
| `price:` | not implemented |
| `cw:` content warnings | not implemented |
| `t:channel` | not implemented |
| Carrying toward a place (`dest:` on a message) | not implemented; custody currently carries only to a known callsign |
| `urg:` | not implemented |
| `scope:` | not implemented; every bearer currently forwards everything it can |
| `lang:` | not implemented |
| `nick:` and signed identity | not implemented; identity is announced unsigned today |
| `t:mailbox` | **partly implemented**: a receiving station records verified declarations naming it (windows and `remove:mailbox` included, `lib/services/xprs/xprs_archive.dart`) and uses them to gate what the internet lane may deposit in its spool; no station composes one yet, and custody still has no notion of a preferred carrier |
| Several mailboxes with windows, and cancellation | **implemented on the receiving side** (see `t:mailbox` above); not composed |
| `t:service` | not implemented; no station advertises what it does |
| `t:command` and `t:result` | **implemented** for `cmd:history`: the phone and desktop host answer a command addressed to them with signed results (`lib/services/xprs/xprs_history_server.dart`); no other command is acted on yet |
| `cmd:history`, backfill by replay | **implemented**: every device keeps a spool by default (500 MB or a year, the owner's numbers per section 31.3) and re-airs the original packets newest first on request — `code:202`, the page, then `code:200` or `code:206` — metered per section 31.2 and paced for the advert channel |
| `cmd:file`, fetching bytes by hash | **specified** (with `off:` resume and concrete reply codes, section 25.2), not implemented as a command; the resolution ladder underneath it is built and works (Reticulum direct, DHT, LAN, I2P, BitTorrent -- `reticulum-dart/doc/file-sharing.md`), so this is an ask the format lacked rather than a transport it lacks |
| `cmd:put`, depositing bytes | **specified, not implemented** as a command; the machinery exists as the Reticulum deposit session (`FileDepositSession`) and the MSP bulk lane's accept-at-size handshake — what is missing is the XPRS ask in front of them |
| `q:have` / `s:have`, who holds a file | **specified, not implemented**; the internet overlay's equivalent (signed DHT provider records) is live, the radio-side question is not asked yet |
| Listings (`XFL1`), folders as snapshots | **specified, not implemented** in this format; the shipped folders lane keeps piece hashes as a headerless binary blob and syncs live folders by signed op-log — the XFL1 text listing is the packet-layer snapshot form |
| Inline files in `b:` | **specified, not implemented**; nothing splits or reassembles `b:` yet |
| Deterministic torrents, `ih:` derivable | **implemented** (`lib/services/torrent_service.dart` builds byte-identical torrents from content, so every holder derives one infohash) |
| `serve:history` | **implemented**: the spool is on by default and the discovery beacon says so; turning the preference off drops the claim and the answers together |
| Section 24.4, one port for Reticulum and XPRS | **implemented** on the TCP hub listener: port 4242 answers HDLC-framed Reticulum and line-oriented XPRS on one socket, told apart by the first byte |
| Retention policy, and keeping by worth rather than by age | deliberately unspecified (section 31.3); the shipping custody store bounds itself at 100 MB or 7 days and evicts `ORDER BY urg, ts`, which is exactly the kind of local decision this format leaves alone |
| Paged replies, `code:206` | **implemented** by the history responder: twelve packets a page over the air, the probe row deciding 206 against 200, and the requester continuing by moving `until:` |
| `t:poll` and `vote:` | not implemented; nothing puts a question or counts an answer |
| `@CALLSIGN` mentions | not implemented; no wapp scans `m:` for them and nothing notifies on being named |
| `root:` on a reply | not implemented; the chat wapp threads by parent pointer only (`docs/aprs-xt.md`), so a lost middle orphans the rest |
| `t:file` and `size:` (now also `name:`, `ph:`, `kind:folder`, `count:`) | not implemented as a packet; the equivalent exists as NOSTR kind-1063 metadata indexed in FTS5 (`reticulum-dart/doc/file-sharing.md`) |
| `link:`, `busy:` and `txtime:` | not implemented; the Reticulum side tracks announce cadence and the LoRa drivers know the duty cycle, but nothing measures or publishes channel occupancy |
| `hears:` | not implemented; `hal_rns_nodes` lists observed nodes but, per `docs/store-and-forward.md`, a hub replays its whole announce cache so the list is not "heard directly" |
| `t:report` | not implemented; the chat wapp has moderation ops but no way for an ordinary station to flag anything |
| `add:repost` | not implemented; the chat wapp has reactions (`add:like`) and no repost |
| `t:place` | not implemented; nothing in the codebase reports a thing that is not the sender |
| Avatar and description on `t:identity` | not implemented; the Social wapp renders NOSTR kind-0 profiles, which are a different mechanism |
| Section 31, airtime | not implemented as stated here, though the Reticulum side has real cadences (30 s charging, 5 min on battery) and the NOSTR side has stranger-serving budgets |
| `t:status` | not implemented; the Social wapp has a feed, but it is NOSTR kind-1 notes over the internet and Reticulum rather than XPRS packets (`docs/social.md`) |
| `mood:` and client theming | not implemented; nothing reads a mood and no client changes appearance for one |
| `X5` group callsigns and `t:moderate` | not implemented; groups are plain names with no member list anywhere |
| Subgroups, `role:sub` nested five levels deep | not implemented; the chat wapp has a sub-room tree, but on NOSTR rooms and with authority inherited down the tree rather than stopping at each key |
| Never filtering `sos`, `warning` and `info` by membership | not implemented; there is no membership filter to exempt them from |
| The chat wapp's own moderation | **implemented, and by a different design**: NIP-72 rooms with a NOSTR kind-9078 op-log, authority from the room event's author rather than a group keypair, and no roster at all (`docs/chat-rooms.md`). Nothing in section 26 is built, and reconciling the two is not attempted here |
| `cmd:interpret` | not implemented; no station interprets natural language |
| `near:`, regional delivery, `route:` in a receipt | not implemented |
| `q:sign` and signed receipts | not implemented |
| Recurring windows, `site:`, `supply:`, `range:` | not implemented |
| `t:challenge` and `t:response` | not implemented; no challenge exists, and a spoofed authority-issued callsign is currently undetectable |
| Periodic `t:identity` | partly; a key is announced but not on a fixed period |
| `since:` and `until:` | not implemented; nothing in the current wire carries an event duration, and nothing expires on its own |
| `type:` vehicle set | partly; the current wire carries a handful of symbols and none of the rail, air or cycle values |
| Variable-length and authority-issued callsigns | not implemented; the current wire assumes the six-character `X1`/`X3` form |
| `pos:` coordinates | implemented in a different encoding |
| `age:` and `epoch:` time | not implemented; requires an epoch counter in non-volatile storage |
| `alt`, `acc`, `spd`, `dir`, `o`, `climb` movement | not implemented; the platform supplies these values and the location layer currently retains only latitude and longitude |
| `temp`, `hum` weather | one hardware sensor exists and reaches a local display only |
| `intemp`, `inhum` weather | not implemented; the one sensor that exists is indoors and is reported as if it were outdoors |
| `press`, `wind`, `wdir`, `gust`, `rain1`, `rain24`, `solar` weather | no source |
| `batt`, `volt` telemetry | not implemented; charging state is tracked, charge level is not |
| `rssi`, `snr` telemetry | implemented on the receive paths |
| `uptime`, `lifetime` telemetry | implemented on the ESP32 T-Dongle beacon (`esp32/rns_ble5`, lifetime accumulated in NVS); the phone beacon does not carry them yet |
| `dose`, `lifedose`, `radon`, `rf`, `efield`, `mfield` radiation (section 10.5.1), `odometer` | specified; no shipping station has a sensor for any of them yet |
