# BLE transport — off‑grid messaging and file links

Bluetooth Low Energy is Aurora's **off‑grid** transport: it works with no
internet, no cell signal, and no infrastructure. It is used two very different
ways depending on payload size, and a **size router** picks between them:

- **small payloads (chat, positions, control)** → **connectionless broadcast**:
  one advertisement per message, heard by everyone in range, no pairing;
- **large payloads (files)** → a **GATT Reticulum link**: a point‑to‑point
  connection that carries an encrypted [Reticulum](reticulum.md) Resource.

This split is deliberate: APRS‑style chat wants cheap one‑to‑many broadcast that
also reaches an ESP32 node, while a file needs a reliable byte pipe. The two
share the same radio.

Code: the APRS wapp's `ble.c` / `main.c` (compact APRS frames), the native BLE5
layer (`Ble5.kt` on Android), and `rns_ble_interface.dart` (Reticulum over BLE).

---

## 1. The size router

| Payload | Transport | Why |
|---------|-----------|-----|
| ≤ ~300 B | **Connectionless broadcast** (advert chunks `0x50`/`0x51`) | one‑to‑many, no pairing, reaches ESP32 nodes |
| > ~300 B | **GATT unicast link** | reliable, ordered, carries a Reticulum Resource |

Reticulum's BLE interface (`rns_ble_interface.dart`) broadcasts any RNS packet
that fits the connectionless cap and falls back to the GATT path for larger
ones, so the same router serves both the APRS chat and the RNS overlay.

## 2. Compact APRS frame (broadcast path)

A legacy BLE advertisement holds only ~31 bytes, far less than a TNC2 frame, so
over BLE Aurora uses a **compact** form (`ble_pack` in `main.c`):

```
<from>\x1f<to>\x1f<text>          (\x1f = 0x1F unit separator)
```

The `to` field encodes the routing, mirroring APRS semantics:

| `to` | Meaning |
|------|---------|
| a callsign | 1:1 direct message |
| `#GROUP` | group bulletin (in‑range ⇒ treated as local) |
| `!` | position; `text = "lat,lon[,comment]"` |
| *(empty)* | area / geo‑chat broadcast text |
| `?PING` / `?PONG` | reach‑test ping/pong (own ttl forwarding) |
| `?MAIL` / `?IGATE` | store‑and‑forward control (see [aprs.md](aprs.md) §4) |

Messages larger than one advert are chunked (`0x50` = data chunk, `0x51` =
scan‑response chunk) and reassembled by the receiver. The same APRX payload
markers (`+<mid>`, `<mid>:like`, `~<sig>`, `ENC1:`, `file:…`) ride inside `text`
exactly as on APRS‑IS — see [aprx.md](aprx.md).

## 3. Receiving, dedup, digipeating (`ble_handle`)

Every inbound compact frame:

1. is recorded in the **seen‑devices** registry (`sdev_touch`) — this is what
   makes a station "spotted" so the iGate can pull its mail and gate its inbound
   traffic ([aprs.md](aprs.md) §4). A newly spotted station is also surfaced in
   the Activity feed.
2. is **content‑deduped** by a time‑windowed frame ring (`fseen`, 60‑min window)
   so a message heard on both transports — or re‑broadcast by the mesh — is
   handled once.
3. is **digipeated** once, after a short per‑frame‑staggered delay, unless the
   same content was already repeated recently — this widens reach while a
   hash‑derived stagger cuts collisions.

Control frames (`?PING`, `?MAIL`, `?IGATE`) are handled on every receipt (they
carry no unique body) and are never digipeated verbatim or gated to APRS‑IS.

## 4. Position beacons

While BLE is on and a position is known (live GPS via `hal_sensor_gps_*`, else
the configured station position), the node periodically broadcasts a compact
position frame (`to = "!"`), so nearby stations and ESP32 nodes can place it on
their map.

## 5. Reticulum over BLE (file path)

For files (and any RNS packet over the broadcast cap), the GATT path carries a
normal **Reticulum link**: the BLE interface is just another `RnsInterface`, so
the link handshake, encryption and Resource transfer described in
[reticulum.md](reticulum.md) §6–7 run unchanged over Bluetooth. This is how two
phones, or a phone and the ESP32 dongle, move a file off‑grid: discovery by hash
([dht.md](dht.md)) if reachable, otherwise a direct link to a known holder.

## 6. The ESP32 node

An ESP32‑S3 "T‑Dongle" runs a full BLE5 Reticulum node (`esp32/rns_ble5`) with
on‑device crypto: it transmits signed announces that phones accept, receives, and
can act as a blind relay — forwarding encrypted traffic it can't read, with its
screen used only as a metadata status dashboard. On the APRS side it can receive
Aurora's APRS‑over‑BLE and show it on a rolling chat, and persist APRS to a
microSD message store queryable over HTTP/BLE.

---

See also: [aprs.md](aprs.md) (the internet transport and the iGate that bridges
to it), [aprx.md](aprx.md) (the message conventions carried over BLE), and
[reticulum.md](reticulum.md) (the link/resource layer used for files).
