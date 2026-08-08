# OPRS — Open Packet Reporting System

> APRS is Automatic. This one is Open.
>
> An APRS-shaped network for the people who do not have a licence.
>
> Companion docs: [oprs-data.md](oprs-data.md) (**the wire format**: messages,
> receipts, parcels, signing, position, weather, telemetry),
> [aprs.md](aprs.md) (the real APRS transport we speak),
> [aprs-xt.md](aprs-xt.md) (the message conventions), [mesh.md](mesh.md) (the
> BLE street mesh), [store-and-forward.md](store-and-forward.md) (custody),
> [ble5.md](ble5.md) (how bytes leave the device), [NOSTR.md](NOSTR.md) (the
> identity and relay model), [dht.md](../../reticulum-dart/doc/dht.md) (the
> who-has layer), [architecture.md](architecture.md) (what belongs where).
>
> Like NOSTR.md, this file is **vision plus an honest gap analysis**. Every
> claim is marked BUILT / PARTIAL / NOT BUILT and points at the code.

---

## 1. Why this exists

APRS is good at what it does. Thirty years of digipeaters, iGates and beacons,
a working global backbone in APRS-IS, and a culture that maintains it — for a
licensed amateur it is a proven network and this document is not a complaint
about it. Where a OPRS device meets APRS, it should be a polite guest (§9).

But APRS stands on two things, and both are doors with a lock:

1. **Amateur spectrum.** VHF/UHF packet and the HF gateways are licensed bands.
   Transmitting there without a licence is illegal nearly everywhere.
2. **An authority-issued callsign.** APRS-IS enforces this in the only way it
   can: the passcode is *derived from* the callsign, and a gateway putting
   traffic on the air does so under a real operator's identity.

Those rules are correct for a licensed service. They also mean that the person
who never sat an exam — most of the planet — cannot use any of it. Not the
messaging, not the position reports, not the store-and-forward, not the
community infrastructure. The technology is not the barrier. The licence is.

**OPRS is the same set of ideas built on spectrum and infrastructure that need
no licence at all**: Bluetooth and LoRa in the ISM bands, WiFi, and the
internet. Identity comes from a keypair the user generates in three seconds
instead of a national register.

And because we are not on amateur bands, one more rule falls away: **amateur
radio forbids obscuring the meaning of a message, so APRS is unencrypted by
regulation.** OPRS is not bound by that. It can be public where public is
useful, and private where privacy matters (§5).

### The name

APRS is the **Automatic** Packet Reporting System. OPRS is the **Open** one —
one letter, and it is the only letter that matters here. Everything else in
this document is an argument that the rest of the system can stay the same
shape.

---

## 2. What OPRS is, in one paragraph

OPRS is Reticulum, plus the conventions that make it behave like a packet-radio
network: every device has a callsign derived from its own public key, announces
itself, carries other people's traffic when it can, holds mail for peers that
are out of reach, and speaks the same messages over Bluetooth, over the
internet, and (once §8.1 lands) over LoRa. There is no membership list, no
registration, and no server that must stay up for the network to exist.

---

## 3. The equivalence table

The spine of this document. Each row: the APRS concept, our equivalent, and
whether it exists.

| APRS concept | OPRS equivalent | Status |
|---|---|---|
| ITU callsign, issued by an authority | `X1`/`X3` callsign derived from a NOSTR npub — `reticulum-dart/.../nostr_key_generator.dart:25-48` | **BUILT** |
| APRS-IS passcode (derived from the callsign, trivially forgeable) | real signatures: short-Schnorr on frames (`aprx_sign.dart`), Ed25519 on announces and DHT records, BIP-340 on events | **BUILT** |
| APRS-IS server tier | Reticulum transport nodes; anyone can run one and they hold **no application state** | **BUILT** — caveat in §6 |
| Server-side filter `g/ b/ r/` | `InterestSet{topics, authorPrefixes, wide}` — `relay_role.dart:53-77` | **PARTIAL** — no geographic filter (§8.4) |
| Digipeater, `WIDEn-n` path | BLE street mesh: `0x4D` route beacons + distance-vector, dongle blind re-air (`esp32/rns_ble5/src/main.c:604-613`), staggered repeat in the chat wapp (`wapps/chat/main.c:5774`) | **BUILT** |
| iGate (RF ⇄ internet) | edge bridge: an internet-attached node carries BLE-only peers onto the hubs — `rns_service.dart:1186-1234`, `rns_transport.dart:120-129` | **BUILT** for BLE; LoRa missing (§8.1) |
| *(APRS has no equivalent)* | **custody store-and-forward** — a device carries a stranger's message until it meets the recipient: `mesh_courier.dart`, `mesh_store.dart`, dongle SCF on SD | **BUILT**, device-validated |
| Message + `{seq` / `ackN` | LXMF (wire-compatible with Sideband/NomadNet) + `am:` receipts + `?ACK` | **BUILT** |
| Bulletin `BLN<n><GROUP>` | `#group` broadcast over Reticulum + BLE — `wapps/chat/main.c:3044` | **BUILT** |
| Position report `!lat/lon` | one observation frame — position, motion, weather and telemetry in one token vocabulary ([oprs-data.md](oprs-data.md)) | **SPECIFIED**, mostly unbuilt (§8.2) |
| aprs.fi / findu — "where is this station?" | DHT + Indexers — `dht_node.dart`, `publishAuthorProvider` (`rns_service.dart:4296`) | **BUILT** for keys; no *people/place* query (§8.3) |
| q-constructs (`qAR`, `qAC`) — who gated this | provenance: `HolderHint` (first-hand vs told-by-another), `relayerHex`, `hops`, `via` | **PARTIAL** |
| Objects, Items, telemetry, weather | — | **NOT BUILT** |
| Symbol table | — | **NOT BUILT** |

---

## 4. Identity without an authority

A callsign is `X1` or `X3` followed by **bech32 characters 5–9 of the npub**,
uppercased (`nostr_key_generator.dart:37-48`):

```
npub1qz3n…  →  X1QZ3N
X1 = a person / operator      X3 = a station / relay
```

Three consequences the network has to live with:

- **It is a 20-bit handle, not an identity.** Four bech32 characters is ~1
  million values; collisions are findable on purpose by anyone who wants one.
  The rule from [aprs-xt.md](aprs-xt.md) §14.6 stands everywhere in OPRS:
  *the callsign is a label — always verify against the full public key.* This is
  why messages are signed and why the courier drops a frame whose signature
  fails when the sender's key is known (`mesh_courier.dart:315-323`).
- **Some letters can never appear.** The characters come from bech32, whose
  alphabet excludes `b`, `i`, `o` and `1` (`kCallsignAlphabet`,
  `lib/profile/vanity_callsign_page.dart:40`). A callsign with a B in it is not
  one of ours.
- **Nobody can take it away, and nobody had to grant it.** The flip side is
  that nobody vouches for it either. Reputation in OPRS is built from
  signatures and observed behaviour, not from a register.

**Where APRS has a passcode, OPRS has cryptography.** The APRS-IS passcode is a
16-bit checksum of the callsign — it exists to keep honest software honest, not
to stop anyone. Every OPRS-carried artefact is signed by the key the callsign is
derived from: frames (short-Schnorr, 48 bytes, base85 — `aprs-xt.md` §14),
announces and DHT provider records (Ed25519), NOSTR events (BIP-340).

---

## 5. Public by default, private when it matters

APRS is public because the regulator requires it. OPRS is public **because it is
useful** — a position beacon nobody can read is pointless, and a mesh where
carriers cannot see who a message is for cannot route it. So OPRS keeps a
genuinely public plane, and it already exists in the code:

| Primitive | What it is | Where |
|---|---|---|
| **Announce app_data** | signed but **cleartext** — carries the callsign, the node's role, capabilities and hardware profile. This is the closest thing OPRS has to an APRS beacon. | `rns_announce.dart:3-9`; emitted `rns_service.dart:3475-3501` |
| **`sendPlainTo`** | one connectionless PLAIN packet: no link, no handshake, no Reticulum-layer encryption. Routes multi-hop like anything else. | `rns_transport.dart:520-532` |
| **NPD** | a probe datagram whose 60-byte header is **deliberately readable** so traffic stays classifiable on the wire, with an encrypted body. Scoped to public data only. | `npd.dart:29-58` |
| **`hal_rns_broadcast`** | the wapp-facing broadcast: reaches every peer, transits transport nodes. | `wapp_engine.dart:2667-2676` |
| **The compact `0x41` frame** | `FROM \x1F TO \x1F TEXT` — envelope public so any custodian can route it, body optionally sealed. | [ble5.md](ble5.md) §2 |

And where APRS *cannot* go, OPRS does: a 1:1 message is encrypted end to end
(`ENC1:` over ECDH+AES, or LXMF's own encryption), while the envelope stays
readable so the mesh can still carry it. **Public where it helps, private where
it matters** — a choice, not a regulation.

---

## 6. "No servers" — said honestly

APRS-IS is a tier of servers. They are well run, but they are servers: they hold
the routing, the filters and the traffic, and a client without one is alone.

OPRS's equivalent is a **transport node**, and the difference is what it holds:
a transport node forwards packets and keeps no application state. Any device can
be one. Take it away and the network loses a route, not a record.

**But the honest part.** Two internet nodes today only meet if they share a
bootstrap hub — [peer-discovery.md](../../reticulum-dart/doc/peer-discovery.md)
§"the three requirements" is blunt about it: different community hubs do not
reliably bridge announces to each other, so a node must mesh with *all*
configured hubs, not the first that answers. That bootstrap list is a real
dependency and pretending otherwise would be dishonest.

Two things make it less load-bearing than an APRS-IS server:

- **Anyone can run one**, and adding one to the list is a settings change.
- **The radio paths need no hub at all.** Two phones in a street meet over BLE;
  a dongle carries mail between people who never meet; once LoRa lands (§8.1) a
  village works with no internet in it. That is the part APRS-IS structurally
  cannot do, because its backbone *is* the internet.

---

## 7. Where OPRS is already ahead

Not a boast — these are the parts that justify building a second network rather
than asking everyone to get licensed:

- **Custody store-and-forward.** APRS has no held mail: if the recipient was not
  listening, the packet is gone. OPRS hands the message to whatever device is
  nearby, which carries it — for days if needed — and delivers it when it meets
  the recipient. Bounded by quota (100 MB), TTL (7 days) and priority so a
  stranger's mail is shed before your own. Validated on hardware: tablet →
  T-Dongle → phone, with the **sender's radio switched off** before delivery, so
  only the custodian could have done it ([store-and-forward.md](store-and-forward.md) §8).
- **Real authorship.** An APRS callsign in a packet is a claim. A OPRS callsign
  is checkable against a signature.
- **Encryption when wanted**, without leaving the network.
- **One identity across radio and internet.** The same key signs a BLE frame,
  a LoRa frame, an LXMF message and a NOSTR event.
- **No licence, no exam, no register** — the entire point.

---

## 8. What to build next

Ordered by how much each one blocks the promise above.

### 8.1 LoRa on the data path — the number one gap

**OPRS has no long-range radio today, and long-range radio is most of what APRS
is.** Bluetooth reaches across a street. LoRa reaches across a valley.

The honest state: the drivers exist and route nothing.

| Piece | Reality |
|---|---|
| `esp32/components/geogram_sx1276/sx1276.c`, `geogram_sx1262/sx1262.c` | real, complete drivers |
| Their callers | **none** — `model_get_lora()` is used only to print "LoRa: OK" on the boot splash (`esp32/src/main.cpp:1662`) |
| `lib/connections/lora/lora_connection.dart` | capability-declaring stub, `status => unavailable` |
| `hal_lora_*` | four WASM imports, all stubs returning 0/-1 |
| An RNS LoRa interface | **does not exist** — the interfaces are TCP, TCP-server, UDP, LAN, BLE, Auto. There is no `rns_lora_interface.dart` in either repo |

What it needs: an `RnsLoRaInterface` in reticulum-dart (framing, duty cycle,
the MTU story — a LoRa frame is far smaller than a BLE advert, so the courier's
240-byte budget gets tighter), and an ESP32 firmware that runs the existing
driver as a real Reticulum interface rather than a splash-screen string. The
Heltec boards already initialise the radio at 868 MHz / SF7 / BW125.

### 8.2 A position report that is a first-class object

**The format is now defined — see [oprs-data.md](oprs-data.md).** Position,
movement, weather and device telemetry share one token vocabulary in one frame:
decimal coordinates, SI units, an explicit accuracy, and a mandatory time field
(including an epoch form for nodes with no clock, so a message carried for days
is still datable). What remains is to build it — the platform already hands the
app altitude, accuracy, speed and heading and the location service discards
them, and the sensor HAL reports "not available" on every platform.

### 8.3 Coverage in the announce — "where is the gateway on the hill?"

APRS gets this for free: digipeaters beacon their position, so you can see the
infrastructure. OPRS nodes announce their *capabilities* but not their *reach*.

The design already exists and is not built — [NOSTR.md](NOSTR.md) §"Coverage:
where a node is useful": a coarse geohash `gh` plus **one entry per radio**
(`rx[]` — which link, range in km, listening frequency), because a node with
Bluetooth and a LoRa gateway has two very different footprints and collapsing
them into one number lies in both directions.

### 8.4 Geographic interest — the equivalent of `r/lat/lon/km`

`InterestSet` shards by topic and author prefix (`relay_role.dart:53-77`). APRS-IS
also shards by **place**, which is the natural filter for a beacon network. Add a
geohash to the interest set so a node can say "I carry traffic for this region"
and an asker can find it.

### 8.5 `?ACK` generation belongs in the core

The receipt that closes the custody loop is *purged* by the core on both phone
and dongle, but only **generated** inside the chat wapp
(`wapps/chat/main.c:1266`). That is backwards under
[architecture.md](architecture.md): delivery is a transport concern, so a
message carried for any wapp should close its own loop. Today a courier-carried
message relies on the have-bloom instead.

### 8.6 Multi-custodian replication

[mesh.md](mesh.md) §"replicate to the top 1–2 custodians, bounded by advertised
storage headroom" is documented and **not built** — the hand-off is
opportunistic, one peer per session. One custodian that walks into a tunnel is
currently a single point of failure for that message.

---

## 9. Meeting real APRS: be a polite guest

A licensed amateur may want to bridge the two worlds, and that is legitimate —
under **their** callsign, on their responsibility. The rules the code already
enforces:

- APRS-IS is **off by default** and needs a licensed callsign plus its verified
  passcode ([aprs.md](aprs.md) §1).
- The gateway **refuses to originate an `X1`/`X3` sender onto APRS-IS**
  (`wapps/chat/main.c:7043`, `:7099`), and refuses anything that arrived over
  Reticulum, whose originators are presumed unlicensed.
- Ciphertext is never put on APRS-IS — partly because APRS is a 7-bit protocol
  that would mangle it, and partly because obscured meaning does not belong on
  amateur bands.

**One inconsistency to fix.** The ESP32 iGate firmware states the opposite:
`esp32/components/geogram_aprsis/aprsis.h:5-6` describes connecting with
"computed passcode, **no licence needed for an X3 callsign**", and gates BLE
traffic upward with a `qAR` construct (`aprsis.c:391-426`). An `X3` callsign is
auto-generated by us and assigned by nobody — that path can put unlicensed
traffic onto licensed amateur infrastructure, which is exactly what §9 exists to
prevent. It should be brought in line with the wapp's rule: **gate up only under
a licensed callsign the operator entered.** (Fix tracked separately; noted here
so it is not forgotten.)

---

## 10. Status at a glance

| Area | State |
|---|---|
| Identity, callsigns, signatures | **BUILT** |
| Messaging 1:1 (LXMF, receipts, encryption) | **BUILT** |
| Group bulletins | **BUILT** |
| BLE mesh: beacons, digipeat, DV routing | **BUILT** |
| Custody store-and-forward (phone + dongle + SD) | **BUILT**, device-validated |
| Edge bridge (BLE peers → internet) | **BUILT** |
| Directory: DHT, Indexers, provider records | **BUILT** for keys; "where is a person/place" missing |
| Public plaintext plane (announce, PLAIN, NPD) | **BUILT** |
| Interest filtering | **PARTIAL** — topics and authors, no geography |
| Position / telemetry as a real object | **SPECIFIED** ([oprs-data.md](oprs-data.md)); producers mostly missing |
| Node coverage in the announce | **NOT BUILT** — designed in NOSTR.md |
| **LoRa anywhere in the message path** | **NOT BUILT** — drivers exist, nothing routes over them |
| Objects, items, weather, symbols | **NOT BUILT** |

The one-sentence version: **everything APRS does over licensed radio, OPRS does
over radio anyone may use — and it already works, except on the radio that
reaches furthest.**
