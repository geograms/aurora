# BLE5 — how bytes actually leave the device

Aurora's off-grid plane is Bluetooth 5 **extended advertising**: connectionless,
one-to-many, no pairing, no connection. Everything else on Bluetooth (GATT
links, MSP sessions, file transfer) exists because some payloads do not fit in
an advert.

This document is what a person needs to know before changing anything that
touches the radio. Companion docs: [ble.md](ble.md) (the older transport
overview), [mesh.md](mesh.md) (routing), [store-and-forward.md](store-and-forward.md)
(delivery to absent peers), [architecture.md](architecture.md) (who owns what).

---

## 1. One radio, one advertising set, many frames

An Android phone presents **one advertising set**. Every frame Aurora wants on
the air shares it, round-robin, at `ROTATE_MS = 1200` (`android/app/src/main/
kotlin/com/example/iwi/Ble5.kt`). So:

- with N frames registered, each is on air roughly **1/N of the time**;
- a receiver scanning in bursts sees a given frame only if its burst overlaps
  one of that frame's slots;
- **airing something once is a lottery.** This is the single most common cause
  of "it works on my desk, not in the test" (see [§5](#5-the-traps)).

Frames are **keyed and TTL'd**, not fire-and-forget:

```dart
Ble5Bus.instance.advertiseFrame(key, subtype, payload, ttl: ..., prio: false)
```

Re-registering the same key refreshes the TTL and replaces the data. `prio`
puts traffic (a handshake, a message) ahead of presence beacons in the
rotation.

## 2. Framing

All Aurora frames ride manufacturer data under company id `0xFFFF`, marker
`0x3E`, then a one-byte **subtype** (`Ble5Subtype`):

| Subtype | Name | Carries |
|---|---|---|
| `0x55` | `rns` | one Reticulum packet |
| `0x56` | `rnsChunk` | a fragment of a Reticulum packet too big for one advert |
| `0x41` | `aprs` | the compact 1:1/group text frame (below) |
| `0x47` | `presence` | GATT presence beacon: callsign, "I am connectable" |
| `0x4D` | `mesh` | street-mesh route beacon (gossip, DV costs) |
| `0x57` | `wfd` | WiFi-Direct negotiation |

### The compact frame (`0x41`)

```
FROM \x1F TO \x1F TEXT
```

Three fields, unit-separator delimited, ASCII. `TO` is a callsign, `#group`,
`!` (position) or a `?` control word. Everything layered on top — receipt ids,
signatures, ciphertext, the courier's `sd:` address — lives inside `TEXT`, so
**every custodian can read the envelope without understanding the payload**.
That is deliberate: a carrier that cannot see who a message is for cannot
decide whom to hand it to.

## 3. The size router

`BleService.enqueueAdvert(owner, payload, ttl:)` is the single entry point for
outbound broadcast, and it routes by size:

```
payload.length <= maxPayload   → BLE5 extended advert (connectionless)
payload.length >  maxPayload   → GATT (auto-paired transient link)
```

### These are controller ceilings, not BLE5 limits

Worth being precise, because the numbers look small for BLE5 and invite the
wrong conclusion:

- **BLE5 extended advertising allows up to 1650 B** of advertising data, spread
  over chained AUX PDUs. That is the protocol.
- **A controller decides how much of that it will actually do**, and Android
  reports the truth: `BluetoothAdapter.leMaximumAdvertisingDataLength`.
  `Ble5.kt` asks it and returns `that - 8` (our envelope) as `maxPayload`.
- Measured on the two test devices, both genuinely on BLE5 (`setLegacyMode(false)`,
  non-connectable, non-scannable extended sets, `ble5: true`, zero advert
  refusals): **TANK2 → 296 B usable (304 reported)**, **the test tablet → 184 B
  usable (192 reported)**. Cheap chipsets report small ceilings; capable ones
  report 1650. Nothing here is legacy 31-byte advertising — that path only
  exists as `kBleBcastMax = 300` chunked broadcast parcels for devices without
  extended advertising at all, plus the separate *legacy connectable presence
  beacon* used for GATT discovery.
- `Ble5Bus.maxFrame = 450` is **ours**, not the spec's, and it would bind first
  on a phone that reports 1650. Nothing in the fleet does today; raise it when
  something does.

So a small `maxPayload` means "this radio is modest", never "we are on old
BLE".

Two consequences that have each cost a debugging session:

- **An over-cap frame is refused, not truncated.** The native call returns
  false; `enqueueAdvert` honours that and reroutes to GATT. Code that ignores
  the return value broadcasts into nothing while still believing BLE5 is up.
- **The custody tap runs BEFORE the router** (`MeshCustodyDelegate.onAirFrame`),
  so an over-cap frame is parked locally and sent point-to-point — the mesh
  never hears it. Watch for `routing point-to-point` in the log.

### Budgets, end to end

| Limit | Value | Set by | Kind of limit |
|---|---|---|---|
| BLE5 extended advertising data | 1650 B | the spec | protocol |
| This controller's advert payload | 184 B / 296 B measured | runtime `leMaximumAdvertisingDataLength - 8` | hardware |
| Our own frame ceiling | 450 B | `Ble5Bus.maxFrame` | ours, arbitrary |
| Chunked parcel (no extended advertising) | 300 B | `kBleBcastMax` | fallback path |
| What a phone will park for custody | 480 B | `MeshStore.maxWire` | ours |
| **What the ESP32 dongle will park** | **252 B** | `BLEMESH_SCF_FRAME_MAX` | one un-chained AUX PDU |
| What the courier will air | **240 B** | `MeshCourier.maxWire` | mesh interop |

The courier's 240 is the binding one **for carried mail**, and it is a mesh
interop number, not a radio one: it sits under the dongle's 252 because a frame
the phones accept but the dongle drops is exactly the mule you were counting on
refusing the job. Direct phone-to-phone broadcast is free to use the whole
`maxPayload`.

## 4. Receiving

`_onBle5Aprs` (`lib/connections/bluetooth/ble_service_io.dart`) is the inbound
choke point for `0x41`:

1. dedup by payload hash within `kBleBcastDedup = 130 s` — a sender re-airs the
   same bytes for its whole TTL, and the receiver must show it once;
2. `LogService: BLE5 rx aprs <n>B rssi=<r>` — always logged, post-dedup. This
   one line answers "did the frame reach this phone at all", which is otherwise
   unanswerable;
3. custody tap (`MeshCustodyDelegate.onAirFrame`) — receipts purge, mail for
   others is parked, mail for us is delivered;
4. the frame goes onto the `inbound` stream that wapps read via
   `hal_ble_scan_read`.

The **scan is never gated**. Pausing the extended scan while a GATT link is up
was measured as the difference between 10/10 and 0/10 message delivery: peers
stop hearing announces, Reticulum paths expire, and everything above it fails
in ways that look unrelated. `_scanWatchdog` re-arms it every 2 s; leave it
alone.

## 5. The traps

**Aired once ≠ delivered.** Register the frame for minutes and refresh it. The
courier airs at 0, +90 s and +180 s with a 300 s TTL. The reason the old
wapp-side path looked reliable is that its digipeater happened to re-air at
+75 s and +150 s — remove that by accident and delivery becomes a coin flip.

**A dongle in a GATT session is deaf.** While the ESP32 is serving an MSP
session it is not scanning; a whole batch aired during that window is simply
never heard. Not a bug in the sender.

**`scf=24` on the dongle means FULL, not "24 parked for you".** The store holds
24 entries and evicts the oldest, so the number stops moving exactly when
things are busiest. Use the `scf` console command to list what is actually held
(target, `am`, size, age) and `scfclear` to start a test from empty.

**Asymmetric links are normal.** The tablet hearing the dongle does not mean
the dongle hears the tablet. Check both sides (`neigh=` on the dongle,
`.mesh.neighbors` on the phone) before concluding anything about the code.

**Android dedups scan results.** A peer is reported once and then suppressed
for a while, so "we saw it, then never again" is the stack, not the peer
leaving. This is why the dial registry remembers the last verified address
instead of requiring a fresh discovery.

**`hal_log` from a foreground page engine does not reach LogService.** Debug a
wapp through its own log panel or through the host's `wapp <name>: cmd …`
lines, not by adding `hal_log` and waiting for `/api/log`.

## 6. Observing it

```sh
adb -s <dev> forward tcp:3458 tcp:3456
curl -s localhost:3458/api/status | jq '.mesh'      # neighbours, custody, courier
curl -s localhost:3458/api/log?limit=200            # BLE5 rx aprs, Courier, Mesh lines
```

On the dongle (115200 baud): `status`, `scf`, `scfclear`, `msg <to> <text>`,
`ack <am>`, `beacon`, `transfers`.

The phone's radio will also report on itself — attempts, refusals and how long
since it heard *any* advert — via `Ble5Bus.radioStatus()`, surfaced in
`.mesh.gatt` (`advertFailures`, `maxPayload`, `ble5`). "Heard nothing" and
"nobody is around" are indistinguishable without it.
