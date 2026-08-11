# BLE5 transmission

The off-grid plane is Bluetooth 5 extended advertising: connectionless,
one-to-many, no pairing and no connection. The remaining Bluetooth machinery
(GATT links, MSP sessions, file transfer) exists for payloads that do not fit in
an advertisement.

Related documents: [ble.md](ble.md) (earlier transport overview),
[mesh.md](mesh.md) (routing), [store-and-forward.md](store-and-forward.md)
(delivery to absent stations), [architecture.md](architecture.md) (component
boundaries).

---

## 1. One radio, one advertising set, and it cannot listen while it talks

**The radio is half duplex.** One antenna, time-shared: every millisecond spent
advertising is a millisecond not receiving. A device that advertises
continuously is deaf for roughly half of every second, and on a mesh that is the
wrong trade — a beacon only has to say "I am here", while everything that
carries a message has to be HEARD.

So transmission is a WINDOW, not a state:

| | |
|---|---|
| `ADV_WINDOW_MS` | 5 000 — the beacon is on air |
| `ADV_PERIOD_MS` | 60 000 — how often that window opens |
| Rest of the minute | receiving |

(`android/app/src/main/kotlin/com/example/iwi/Ble5.kt`.) The window is enforced
by the controller itself — `AdvertisingSet.enableAdvertising(true, duration, 0)`
— so a missed callback cannot leave the device transmitting for a whole minute.
Registering a frame while the radio is listening opens the window immediately
rather than waiting for the next minute: somebody just asked for that to go out.

**The advertising set is created once and kept.** Only its enable state cycles.
Stopping and restarting a set is what makes Android hand out a fresh random
address, and that address churn is what filled peers' address books with several
addresses for one device — and got the same address attributed to two different
callsigns seconds apart. One set, one address, a window that opens and closes.

Within the window, frames still share the set in rotation at `ROTATE_MS = 1200`.
Consequences:

- With N frames registered, each is on air approximately 1/N of the window — so
  N matters far more than it used to. Section 2 explains why only one beacon is
  aired.
- A receiver observes a frame only when its scan overlaps that frame's slot
  inside somebody else's window.
- A frame transmitted once may not be observed at all. This is the most common
  cause of behaviour that differs between a desk test and a field test. See
  section 5. **Anything that must arrive takes a link, not the air.**

Frames are keyed and carry a TTL:

```dart
Ble5Bus.instance.advertiseFrame(key, subtype, payload, ttl: ..., prio: false)
```

Re-registering an existing key refreshes its TTL and replaces its data. `prio`
places traffic such as a handshake or a message ahead of presence beacons in the
rotation.

## 2. Framing

All frames are carried in manufacturer data under company id `0xFFFF`, marker
`0x3E`, followed by a one-byte subtype (`Ble5Subtype`):

| Subtype | Name | Contents |
|---|---|---|
| `0x55` | `rns` | one Reticulum packet |
| `0x56` | `rnsChunk` | a fragment of a Reticulum packet exceeding one advertisement |
| `0x41` | `aprs` | the compact direct or group text frame, and carried XPRS mail |
| `0x47` | `presence` | **declared and never transmitted.** Nothing airs this subtype and nothing handles it; the real presence beacon is the legacy connectable advertisement below |
| `0x4D` | `mesh` | **no longer aired.** The route beacon's distance-vector costs and have-bloom are exchanged in full over an MSP session instead, where they are acknowledged. Still read, so an un-updated peer is understood |
| `0x57` | `wfd` | WiFi-Direct negotiation |
| `0x58` | `xprs` | the XPRS discovery beacon (`docs/XPRS.md` section 10.6) |

### The discovery beacon, subtype `0x58`

```
t:observation f:X1A67X link:ble peers:12 mail:3 hears:X1RD89,X32DVA,CT1ABC-9
```

76 bytes, readable without a decoder, aired on the same cadence as the binary
beacon. `peers:` is how many stations are reachable in total and `hears:` the
ones that fitted, so a truncated list is honest rather than silently short;
`mail:` says how many messages this station holds for other people.

`mail:` is why a carried message no longer needs a broadcast of its own. It used
to be registered on the bus for five minutes and refreshed twice inside that, so
a passer-by might catch a copy -- spending the channel on a message almost every
listener had no use for, and stealing rotation slots from the beacons that make
the mesh work. Now the beacon says there is mail, a neighbour that can reach the
recipient opens a session, and everybody else spends nothing.

**Two frames, because two things do not fit in one.** The DV digest is 4 bytes
per destination and the have-bloom is a flat 128; as XPRS text a DV entry costs
about 10 characters and the bloom base85s to 160, so at the ceilings below the
text fits either the routing table or the bloom and never both. The binary
beacon keeps them; everything a person would read moved to `0x58`.

### Compact frame, subtype `0x41`

```
FROM 0x1F TO 0x1F TEXT
```

Three ASCII fields delimited by the unit separator. `TO` is a callsign,
`#group`, `!` for an observation, or a `?` control word. Receipt identifiers,
signatures, ciphertext and the courier's `sd:` address are carried inside
`TEXT`, so any station can read the envelope without interpreting the payload.
A station that cannot determine the intended recipient cannot decide where to
relay the frame.

**This is what the code transmits today, not the specification.**
[XPRS.md](XPRS.md) defines the payload XPRS stations are to carry, and it is a
different shape: `key:value` fields separated by single spaces, a packet type in
the first field, no unit separators, and no positional fields at all.

```
t:msg f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 q:ack m:meet at the bridge at six
```

Nothing in this document changes when that lands. The subtype, the rotation, the
size router and every budget below are properties of the radio and the
controller; the payload rides on top of them. XPRS.md section 36 lists what is
still outstanding.

## 3. Size routing

`BleService.enqueueAdvert(owner, payload, ttl:)` is the single entry point for
outbound broadcast and routes by size:

```
payload.length <= maxPayload   ->  BLE5 extended advertisement
payload.length >  maxPayload   ->  GATT transient link
```

### Controller ceilings, not protocol limits

The observed values are small relative to the BLE5 specification, which invites
an incorrect conclusion:

- BLE5 extended advertising permits up to 1650 bytes of advertising data across
  chained AUX PDUs. That is the protocol limit.
- The controller determines how much it will carry. Android reports this as
  `BluetoothAdapter.leMaximumAdvertisingDataLength`. `Ble5.kt` reads it and
  returns that value minus 8 bytes of envelope as `maxPayload`.
- Measured on two devices, both running genuine extended advertising
  (`setLegacyMode(false)`, non-connectable, non-scannable, `ble5: true`, zero
  advertisement refusals): TANK2 reports 304 bytes, 296 usable; the test tablet
  reports 192 bytes, 184 usable. Low-cost chipsets report small ceilings.
- Neither figure indicates legacy 31-byte advertising. That path exists only as
  `kBleBcastMax = 300` chunked broadcast parcels for devices without extended
  advertising, and as the separate legacy connectable presence beacon used for
  GATT discovery.
- `Ble5Bus.maxFrame = 450` is a local limit, not a protocol limit, and would
  bind first on a device reporting 1650. No device in use does; raise it when
  one appears.

Two consequences, each of which has caused a debugging session:

- An oversized frame is refused, not truncated. The native call returns false
  and `enqueueAdvert` reroutes to GATT. Code that ignores the return value
  transmits nothing while continuing to report BLE5 as operational.
- The custody tap runs before the size router
  (`MeshCustodyDelegate.onAirFrame`), so an oversized frame is parked locally
  and sent point-to-point, and the mesh does not observe it. The log line
  `routing point-to-point` indicates this case.

### Budgets

| Limit | Value | Defined by | Type |
|---|---|---|---|
| BLE5 extended advertising data | 1650 B | specification | protocol |
| Controller advertisement payload | 184 B and 296 B measured | runtime `leMaximumAdvertisingDataLength - 8` | hardware |
| Local frame ceiling | 450 B | `Ble5Bus.maxFrame` | local |
| Chunked parcel, no extended advertising | 300 B | `kBleBcastMax` | fallback path |
| Phone custody store, per frame | 480 B | `MeshStore.maxWire` | local |
| ESP32 custody store, per frame | 252 B | `BLEMESH_SCF_FRAME_MAX` | one un-chained AUX PDU |
| Courier transmission | 240 B | `MeshCourier.maxWire` | mesh interoperability |

For carried mail the courier's 240 bytes is the binding limit. It is an
interoperability figure rather than a radio limit, set below the ESP32's 252 so
that a frame accepted by the phones is not discarded by the station expected to
carry it. Direct phone-to-phone broadcast may use the full `maxPayload`.

## 4. Reception

`_onBle5Aprs` in `lib/connections/bluetooth/ble_service_io.dart` is the inbound
path for subtype `0x41`:

1. Deduplication by payload hash within `kBleBcastDedup = 130 s`. A sender
   re-transmits identical bytes for the duration of the TTL and the receiver
   presents the frame once.
2. `LogService: BLE5 rx aprs <n>B rssi=<r>`, logged after deduplication. This
   line establishes whether a frame reached the device at all.
3. Custody tap, `MeshCustodyDelegate.onAirFrame`: receipts purge parked copies,
   mail for other stations is parked, mail for this station is delivered.
4. The frame is placed on the `inbound` stream that wapps read through
   `hal_ble_scan_read`.

The scan is never suspended. Pausing the extended scan while a GATT link is
active was measured as the difference between 10 of 10 and 0 of 10 messages
delivered: stations stop receiving announces, Reticulum paths expire, and the
resulting failures appear unrelated to Bluetooth. `_scanWatchdog` re-arms the
scan every 2 seconds.

## 5. Known failure modes

**A frame transmitted once may not arrive.** Register it for minutes and
refresh. The courier transmits at 0, +90 s and +180 s with a 300 s TTL. The
earlier wapp-side path appeared reliable because its repeater re-transmitted at
+75 s and +150 s.

**An ESP32 in a GATT session does not scan.** Frames transmitted during an MSP
session are not received. This is not a sender fault.

**`scf=24` on the ESP32 indicates a full store, not 24 frames for the
observer.** The store holds 24 entries and evicts the oldest, so the count stops
changing under load. Use the `scf` console command to list held entries (target,
`am`, size, age) and `scfclear` to begin a test from empty.

**Asymmetric links are normal.** A device receiving from the ESP32 does not
imply the reverse. Check `neigh=` on the ESP32 and `.mesh.neighbors` on the
phone before attributing a failure to software.

**Android deduplicates scan results.** A station is reported once and then
suppressed, so a peer that appears once and never again is a stack behaviour
rather than a departure. The dial registry therefore retains the last verified
address instead of requiring fresh discovery.

**`hal_log` from a foreground page engine does not reach LogService.** Use the
wapp's own log panel, or the host's `wapp <name>: cmd` lines, rather than adding
`hal_log` and reading `/api/log`.

## 6. Observation

```sh
adb -s <device> forward tcp:3458 tcp:3456
curl -s localhost:3458/api/status | jq '.mesh'   # neighbours, custody, courier
curl -s localhost:3458/api/log?limit=200         # BLE5 rx aprs, Courier, Mesh
```

ESP32 console at 115200 baud: `status`, `scf`, `scfclear`, `msg <to> <text>`,
`ack <am>`, `beacon`, `transfers`.

`Ble5Bus.radioStatus()` reports transmission attempts, refusals and the interval
since any advertisement was last received. It is surfaced under `.mesh.gatt` as
`advertFailures`, `maxPayload` and `ble5`. Without it, a radio receiving nothing
and an environment containing no stations are indistinguishable.
