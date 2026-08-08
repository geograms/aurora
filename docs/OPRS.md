# OPRS, Open Packet Reporting System

An APRS-shaped network for operators who do not hold an amateur licence.

Wire format: [oprs-data.md](oprs-data.md).

Related documents: [aprs.md](aprs.md) (the APRS transport this software also
speaks), [mesh.md](mesh.md) (the BLE street mesh),
[store-and-forward.md](store-and-forward.md) (custody), [ble5.md](ble5.md)
(transmission budgets), [NOSTR.md](NOSTR.md) (identity and relay model),
[dht.md](../../reticulum-dart/doc/dht.md) (the who-has layer),
[architecture.md](architecture.md) (component boundaries).

This document states the design and marks every claim BUILT, PARTIAL or
NOT BUILT with a reference to the implementing code.

---

## 1. Rationale

APRS is a proven network. Thirty years of digipeaters, iGates and beacons, a
working global backbone in APRS-IS, and an active operator community maintain
it. Nothing here is a criticism of it, and an OPRS station meeting APRS
infrastructure operates under APRS rules (section 9).

APRS has two prerequisites:

1. **Amateur spectrum.** VHF and UHF packet, and the HF gateways, are licensed
   bands. Transmitting on them without a licence is unlawful in nearly every
   jurisdiction.
2. **An authority-issued callsign.** APRS-IS enforces this through a passcode
   derived from the callsign, and a gateway placing traffic on air does so under
   a licensed operator's identity.

Both are correct for a licensed service. They also exclude everyone without a
licence from the messaging, the position reporting, the store-and-forward and
the community infrastructure. The constraint is regulatory, not technical.

OPRS applies the same design to spectrum and infrastructure that require no
licence: Bluetooth and LoRa in the ISM bands, WiFi, and the internet. Identity
is a keypair generated on the device rather than an entry in a national
register.

One further consequence: amateur regulations prohibit obscuring the meaning of a
transmission, so APRS is unencrypted by requirement. OPRS is not subject to that
rule and can carry public and private traffic as appropriate (section 5).

### Name

APRS is the Automatic Packet Reporting System. OPRS is the Open one.

---

## 2. Definition

OPRS is Reticulum plus the conventions that make it behave as a packet radio
network. Every device holds a callsign derived from its own public key,
announces itself, relays traffic when able, holds mail for stations that are out
of reach, and carries the same messages over Bluetooth, over the internet, and
over LoRa once section 8.1 is implemented. There is no membership list, no
registration, and no server whose continued operation the network depends on.

---

## 3. Equivalence with APRS

| APRS concept | OPRS equivalent | Status |
|---|---|---|
| ITU callsign issued by an authority | `X1` or `X3` callsign derived from a NOSTR npub, `reticulum-dart/.../nostr_key_generator.dart:25-48` | BUILT |
| APRS-IS passcode, derived from the callsign | signatures: short-Schnorr on frames, Ed25519 on announces and DHT records, BIP-340 on events | BUILT |
| APRS-IS server tier | Reticulum transport nodes; any device can run one and none holds application state | BUILT, see section 6 |
| Server-side filter `g/ b/ r/` | `InterestSet{topics, authorPrefixes, wide}`, `relay_role.dart:53-77` | PARTIAL, no geographic filter (section 8.4) |
| Digipeater and `WIDEn-n` paths | BLE street mesh: `0x4D` route beacons with distance-vector routing, dongle re-air (`esp32/rns_ble5/src/main.c:604-613`), staggered repeat (`wapps/chat/main.c:5774`) | BUILT |
| iGate between RF and internet | edge bridge: an internet-attached node carries BLE-only peers onto the hubs, `rns_service.dart:1186-1234`, `rns_transport.dart:120-129` | BUILT for BLE, LoRa missing (section 8.1) |
| No APRS equivalent | custody store-and-forward: a station carries another station's message until it meets the recipient, `mesh_courier.dart`, `mesh_store.dart`, dongle SCF on SD | BUILT, device-validated |
| Message with `{seq` and `ackN` | LXMF, wire-compatible with Sideband and NomadNet, plus `am:` receipts and `?ACK` | BUILT |
| Bulletin `BLN<n><GROUP>` | `#group` broadcast over Reticulum and BLE, `wapps/chat/main.c:3044` | BUILT |
| Position report `!lat/lon` | one observation frame carrying position, movement, weather and telemetry in a single token vocabulary, [oprs-data.md](oprs-data.md) | SPECIFIED, producers mostly missing (section 8.2) |
| aprs.fi and findu station lookup | DHT and Indexers, `dht_node.dart`, `publishAuthorProvider` (`rns_service.dart:4296`) | BUILT for keys, no station or place query (section 8.3) |
| q-constructs `qAR` and `qAC` | provenance: `HolderHint` first-hand or relayed, `relayerHex`, `hops`, `via` | PARTIAL |
| Objects, items, weather, symbols | see [oprs-data.md](oprs-data.md) section 7 | SPECIFIED, producers missing |

---

## 4. Identity

A callsign is `X1` or `X3` followed by bech32 characters 5 to 9 of the npub,
uppercased (`nostr_key_generator.dart:37-48`):

```
npub1qz3n...   ->   X1QZ3N
X1 = person or operator        X3 = station or relay
```

Three properties follow.

**A callsign is a label, not an identity.** Four bech32 characters is about one
million values, so collisions can be produced deliberately. Every OPRS
implementation verifies against the full public key rather than the callsign.
Messages are signed for this reason, and the courier discards a frame whose
signature fails when the sender's key is known (`mesh_courier.dart:315-323`).

**Some characters cannot occur.** The bech32 alphabet excludes `b`, `i`, `o` and
`1` (`kCallsignAlphabet`, `lib/profile/vanity_callsign_page.dart:40`), so a
callsign containing any of them is not an OPRS callsign.

**No authority issues or revokes it.** No authority vouches for it either.
Reputation derives from signatures and observed behaviour.

The APRS-IS passcode is a 16-bit checksum of the callsign and provides no
cryptographic assurance. Every OPRS artefact is signed by the key from which the
callsign is derived: frames with short-Schnorr, announces and DHT provider
records with Ed25519, NOSTR events with BIP-340.

---

## 5. Public and private traffic

APRS is public by regulation. OPRS is public where public serves a purpose: a
position beacon that cannot be read has no value, and a mesh whose relays cannot
see the intended recipient cannot route. The public plane is implemented:

| Primitive | Description | Location |
|---|---|---|
| Announce app_data | signed and cleartext, carrying the callsign, role, capabilities and hardware profile. The nearest equivalent to an APRS beacon | `rns_announce.dart:3-9`, emitted at `rns_service.dart:3475-3501` |
| `sendPlainTo` | one connectionless PLAIN packet with no link, no handshake and no Reticulum-layer encryption, routed multi-hop | `rns_transport.dart:520-532` |
| NPD | probe datagram with a readable 60-byte header, so traffic remains classifiable on the wire, and an encrypted body. Public data only | `npd.dart:29-58` |
| `hal_rns_broadcast` | wapp-facing broadcast reaching every peer and transiting transport nodes | `wapp_engine.dart:2667-2676` |
| Compact `0x41` frame | `FROM 0x1F TO 0x1F TEXT`, envelope public so any station can route it, body optionally sealed | [oprs-data.md](oprs-data.md) section 3 |

Direct messages are encrypted end to end with `ENC1:` or LXMF encryption, while
the envelope remains readable so the mesh can carry them. The choice is per
message rather than fixed by regulation, subject to the band rules in
[oprs-data.md](oprs-data.md) section 6.3.

---

## 6. Infrastructure dependencies

APRS-IS is a tier of servers holding routing, filters and traffic. A client
without one is isolated.

The OPRS equivalent is a transport node, which forwards packets and holds no
application state. Any device can act as one, and removing it costs a route
rather than a record.

There is a real dependency to state. Two internet-connected nodes meet only if
they share a bootstrap hub. As
[peer-discovery.md](../../reticulum-dart/doc/peer-discovery.md) records,
community hubs do not reliably bridge announces between each other, so a node
must mesh with all configured hubs rather than the first that answers. The
bootstrap list is therefore load-bearing for internet-only paths.

Two factors limit that dependency:

- Any operator can run a hub, and adding one is a settings change.
- The radio paths require no hub. Two phones meet over BLE, a dongle carries
  mail between stations that never meet, and once LoRa is implemented (section
  8.1) a locality functions with no internet present. APRS-IS cannot do this,
  since its backbone is the internet.

---

## 7. Capabilities beyond APRS

- **Custody store-and-forward.** APRS holds no mail: a packet transmitted while
  the recipient was not listening is lost. OPRS hands the message to a nearby
  station, which carries it for up to seven days and delivers it on meeting the
  recipient. Bounded by a 100 MB quota, a 7-day TTL and a priority rule that
  sheds other stations' mail before the operator's own. Validated on hardware,
  tablet to T-Dongle to phone, with the sender's radio switched off before
  delivery so that only the custodian could have delivered it
  ([store-and-forward.md](store-and-forward.md) section 8).
- **Verifiable authorship.** An APRS callsign in a packet is an assertion. An
  OPRS callsign is checkable against a signature.
- **Optional encryption** without leaving the network.
- **One identity across radio and internet.** The same key signs a BLE frame, a
  LoRa frame, an LXMF message and a NOSTR event.
- **No licence requirement.**

---

## 8. Outstanding work

Ordered by impact.

### 8.1 LoRa on the data path

OPRS has no long-range radio in service. Bluetooth covers a street; LoRa covers
a valley. The drivers exist and carry no traffic:

| Component | State |
|---|---|
| `esp32/components/geogram_sx1276/sx1276.c`, `geogram_sx1262/sx1262.c` | complete drivers |
| Callers | none. `model_get_lora()` is used only to print "LoRa: OK" on the boot splash (`esp32/src/main.cpp:1662`) |
| `lib/connections/lora/lora_connection.dart` | capability-declaring stub, `status => unavailable` |
| `hal_lora_*` | four WASM imports, all stubs returning 0 or -1 |
| RNS LoRa interface | does not exist. The interfaces are TCP, TCP-server, UDP, LAN, BLE and Auto |

Required: an `RnsLoRaInterface` in reticulum-dart covering framing and duty
cycle, and ESP32 firmware that runs the existing driver as a Reticulum
interface. The Heltec boards already initialise the radio at 868 MHz, SF7,
BW125.

### 8.2 Observation producers

The format is specified in [oprs-data.md](oprs-data.md): position, movement,
weather and telemetry in one token vocabulary, with decimal coordinates, SI
units, explicit accuracy and a mandatory time field including an epoch form for
stations without a clock.

The producers are missing. The platform supplies altitude, accuracy, speed and
heading, and the location service retains only latitude and longitude. The
sensor HAL reports not-available on every platform. See
[oprs-data.md](oprs-data.md) section 12 for the field-by-field state.

### 8.3 Coverage in the announce

APRS obtains this implicitly, since digipeaters beacon their position. OPRS
nodes announce capabilities but not reach.

The design exists in [NOSTR.md](NOSTR.md) under "Coverage": a coarse geohash
`gh` plus one entry per radio in `rx[]` giving link type, range in kilometres
and listening frequency. One range figure cannot describe a node with both
Bluetooth and a LoRa gateway, so the entries are per radio.

Partially addressed: the coverage geohash is now computed from the device
position rather than stored as a fixed constant (`lib/util/geohash.dart`). The
`rx[]` radio entries remain unimplemented.

### 8.4 Geographic interest

`InterestSet` shards by topic and author prefix (`relay_role.dart:53-77`).
APRS-IS also shards by place, which is the natural filter for a beacon network.
Adding a geohash to the interest set allows a node to declare the region it
carries traffic for.

### 8.5 Receipt generation in the core

The receipt closing the custody loop is purged by the core on both phone and
dongle but generated only inside the chat wapp (`wapps/chat/main.c:1266`). Under
[architecture.md](architecture.md) delivery is a transport concern, so a message
carried on behalf of any wapp should close its own loop. A courier-carried
message currently relies on the have-bloom instead.

### 8.6 Multi-custodian replication

[mesh.md](mesh.md) specifies replication to the best one or two custodians
bounded by advertised storage headroom. It is not implemented; hand-off is
opportunistic and single-peer, so one custodian moving out of range is a single
point of failure for that message.

---

## 9. Operating alongside APRS

A licensed amateur may bridge the two networks under their own callsign and
responsibility. The implemented rules:

- APRS-IS is off by default and requires a licensed callsign and its verified
  passcode ([aprs.md](aprs.md) section 1).
- The gateway does not originate an `X1` or `X3` sender onto APRS-IS
  (`wapps/chat/main.c:7043`, `:7099`), and does not gate traffic that arrived
  over Reticulum, whose originators are presumed unlicensed.
- Ciphertext is never placed on APRS-IS, both because APRS is a 7-bit protocol
  that would corrupt it and because obscured meaning is not permitted on amateur
  bands.

**Open defect.** The ESP32 iGate firmware states the opposite:
`esp32/components/geogram_aprsis/aprsis.h:5-6` describes connecting with a
"computed passcode, no licence needed for an X3 callsign" and gates BLE traffic
upward with a `qAR` construct (`aprsis.c:391-426`). An `X3` callsign is
auto-generated and assigned by no authority, so that path can place unlicensed
traffic on licensed amateur infrastructure. It must be changed to gate only
under a licensed callsign entered by the operator.

---

## 10. Status summary

| Area | State |
|---|---|
| Identity, callsigns, signatures | BUILT |
| Direct messaging (LXMF, receipts, encryption) | BUILT |
| Group messages | BUILT |
| BLE mesh: beacons, repeat, DV routing | BUILT |
| Custody store-and-forward (phone, dongle, SD) | BUILT, device-validated |
| Edge bridge from BLE peers to the internet | BUILT |
| Directory: DHT, Indexers, provider records | BUILT for keys; station and place lookup missing |
| Public cleartext plane (announce, PLAIN, NPD) | BUILT |
| Wire format for messages and observations | SPECIFIED, [oprs-data.md](oprs-data.md) |
| Interest filtering | PARTIAL, topics and authors only |
| Observation producers (altitude, speed, weather) | NOT BUILT |
| Node coverage: geohash | BUILT; per-radio `rx[]` entries NOT BUILT |
| LoRa in the message path | NOT BUILT |
