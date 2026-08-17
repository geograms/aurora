# The T-Dongle-S3 as an XPRS station

What this device does, what of [XPRS.md](XPRS.md) it actually implements, and —
just as usefully — what it does not. `docs/esp32.md` is the maintainer's page
for the firmware; this is the operator's page for the device.

## The device

| | |
|---|---|
| Board | LilyGo T-Dongle-S3 (ESP32-S3, USB-A stick) |
| Firmware | `esp32/rns_ble5/` (`pio run` inside that directory). The older `esp32/` env `tdongle_s3` is the legacy-BLE APRS build and is no longer what ships here |
| Radios | WiFi 2.4 GHz (STA + SoftAP) and Bluetooth LE — **one antenna, shared** |
| Bluetooth | **BLE5 extended advertising**, one AD structure up to 254 B. A legacy connectable advert is kept on a second instance for GATT |
| Storage | microSD under the USB-A cap, FAT, mounted at `/sdcard` |
| Display | ST7735 160×80 |
| Memory | no PSRAM. ~15 KB of free heap in normal operation |
| Power | USB-A. It is a stick you leave plugged into a charger or a hub |

It is meant to be left somewhere with power: it hears, it keeps, and it answers.

## What it is

**An indexer** ([indexer.md](indexer.md), [XPRS.md](XPRS.md) §36) — every XPRS
packet it hears goes to the card verbatim and can be asked about afterwards.

**A bridge** between Bluetooth and the local network — a phone with no internet
reaches every machine on the WiFi through it, and the other way round.

**An APRS iGate**, which is a separate job on separate paths and is not XPRS.

It is **not** a router. It signs what it says and checks what it keeps, but it
is not an authority: a `verified` here means the signature matched a key this
device happened to learn off the air, which is a smaller claim than it sounds
(see the limits below).

## Bearers

| Bearer | Direction | Carries |
|---|---|---|
| BLE legacy advert, subtype `0x58` | receive | one XPRS packet, verbatim |
| BLE compact frame, subtype `0x41` | receive | `FROM 0x1F TO 0x1F TEXT`; an XPRS packet inside `TEXT` is taken |
| BLE broadcast-parcel chunks (`0x50`/`0x51`, NACK `0x52`) | receive + transmit | reassembled payloads up to 300 B — how a packet is put back on the BLE air |
| BLE GATT (`FFE0`, write `FFF1`, notify `FFF2`) | both | parcels from phones, and the query verbs below |
| ESP-NOW broadcast, on the station's WiFi channel | both | one XPRS packet per frame, verbatim ([espnow.md](espnow.md)). 250 bytes fits exactly, and the frame carries RSSI |
| LAN, UDP broadcast port **4242** | both | one XPRS packet per datagram ([lan.md](lan.md)) — the port XPRS answers on over TCP too (§24.4) |
| APRS-IS over the internet | both | **APRS only, never XPRS** |

No LoRa on this board. ESP-NOW only reaches devices on the same WiFi channel,
which for an associated station is its access point's — two dongles on different
networks never hear each other and nothing says so. Reticulum's LAN discovery (UDP 42671) is listened to for
device presence only and is a different protocol.

## What of XPRS is implemented

### Yes

| Capability | Detail |
|---|---|
| Parse and validate packets | `geogram_xprs`: `key:value`, `t:` first, `m:` greedy last, ≤250 B |
| §5 identifiers | first 6 hex of sha256 with `sig:` and `via:` removed, so a relayed copy is recognisably the same packet |
| Store everything heard | 320-byte records, packet kept **verbatim** — what was composed and signed is what comes back |
| §36.1 publication vs mail | decided by `d:`, not by type |
| §36.1 mail privacy | a packet with `d:` is stored and **never served to a third party**; the rule is enforced inside the store, not left to callers |
| `ping`/`pong` refused | not stored, not served — a stale liveness probe answers a question nobody is still asking |
| §13 relaying | `xprs_append_via()` appends this station and refuses when it is already in the path or the type's hop budget is spent (`sos`/`warning` 9, everything else 3) |
| §13.2.1 re-air timing | a bridged packet waits 200–1200 ms at random and is dropped if heard from somebody else meanwhile |
| §10.6 own beacon | `t:observation f:<call> link:lan peers:N` on the LAN every 5 minutes |
| Duplicate suppression | 32-entry identifier ring, plus a 60 s heard-window on the LAN |
| Query by type, time, author | see the query surface below |
| §36.9 `serve:index` announcement | every 10 minutes on BLE5 and the LAN: `t:service f:<call> serve:index,history,mailbox count:<n>` — how a station discovers this indexer exists at all |
| §36.9 XDIR1 directory | who it archives, one `call ts` line per station, sorted; served at `GET /api/xprs/dir` |
| §36.9 content never crosses | it archives only what it hears on its own bearers; it imports nothing from another indexer |
| §25.2 `cmd:history` | **it answers over the air**, on the bearer the ask arrived on: `t:result code:202`, the stored packets verbatim with the author's own signature, then `code:200` — or `206` when more is held, `404` for an empty window, `429` over budget. Paced one packet per 1.5 s, one replay at a time, and metered per asker (6/hour known, 2/hour stranger, 12/hour globally). `only:` matches a callsign anywhere in a packet, including inside `hears:` (§36.6), which is how "where can X be reached" is asked |
| §11.6 `ping`/`pong` | answers a `t:ping` addressed to it (or to nobody) with a signed `t:pong` carrying the signal it arrived with. Rate limited: one per caller per minute, one globally per 5 s |
| §9.1 signatures | **it signs** everything it originates — identity, service announcements, beacons, pongs — with the 48-byte short-Schnorr over secp256k1 that `sig:` carries as 60 base85 characters |
| §9.1 verifying | **it checks what it keeps.** Every signed packet is verified against the author's key one step before it is written — on the store's writer task, core 1, never where the packet was heard. A record is stored `verified` or `unverified` (no key for that author: not a verdict), and a signature that FAILS against a key it holds is **refused, not stored** — an indexer that kept a forgery would hand it on later under the name it impersonates. `GET /api/xprs` reports the verdict per record; the console heartbeat reports `sig ok=/unverified=/forged=` |
| callsign→key | learned from the `t:identity` packets it hears (§9.3), first speaker wins, up to 16 stations. Reloaded at boot from the identities already on the card, so a station known for weeks is not unverifiable for the first ten minutes after a restart |
| §9.3 `t:identity` | announced every 10 minutes: `t:identity f:<call> ts:… k:npub1… sig:…`, self-signed. A receiver stores the callsign→key binding and can then verify everything else this station says |
| §3 callsign binding | the callsign IS derived from the npub, so a receiver re-derives it and sees that name and key belong together. A station carrying an older auto-derived callsign migrates once |
| Identity | the station's **NOSTR key** (`geogram_nostr`): secp256k1, npub, NVS, and the callsign derivation — one key for the callsign, the signature and the identity packet |

**Types it knows** (30, plus `other` for anything it does not): `message`,
`observation`, `receipt`, `reaction`, `request`, `identity`, `track`, `sos`,
`warning`, `info`, `challenge`, `response`, `blog`, `passage`, `event`, `offer`,
`need`, `channel`, `mailbox`, `service`, `command`, `result`, `moderate`,
`status`, `place`, `poll`, `file`, `report`, `ping`, `pong`.

An unknown type is still **stored and served** — it is only the fast per-type
index that does not know it.

### No — and it matters

| Missing | What that means for you |
|---|---|
| **A key is only as good as where it came from** | bindings are learned from unauthenticated `t:identity` packets, first speaker wins. A station that speaks a callsign before its owner does owns that callsign here until reboot. `verified` means "matches the key we associate with this name", not "is who they say" — the far end should still check against a key it trusts |
| **Only 16 stations** | past that the table is full and everything else reads `unverified`. Old records are never re-judged, so what was stored before a key was known stays unverified |
| **No decryption** | `x:` sealed bodies pass through and are stored opaque, which is the intended behaviour, but the device cannot read or check them |
| **No `scope:` enforcement** | `scope:local` is not inspected before re-airing. In practice nothing here gateways XPRS to the internet, so a `local` packet does not escape — but that is the topology, not a check |
| **It does not push to other indexers** | §36.3 is a publisher choosing indexers and pushing to them with a per-indexer cursor. This device indexes only what it happens to overhear |
| **No indexer↔indexer sync** | it never gossips its store to a peer |
| **Mail is held, not delivered** | mail is stored and kept private, but the device does not announce it, does not appear in a `hold:` list, and does not release it on a verified receipt |
| **No eviction** | the store grows until the card is full. At 320 B a record a 32 GB card is a very long time, but nothing deletes anything yet |
| **The directory is not a content-addressed file** | §36.9 has it named by `file:<ref>.xdir` in the announcement and fetched with `cmd:file`. There is no file transfer here yet, so the same bytes are served over HTTP instead |
| **No `m:try` redirect, no peer directories** | a miss is simply a miss; it neither names peers that hold a callsign nor fetches anybody else's directory |
| **Not a §36.8 gateway** | it does not release sealed mail to a station whose observation lists the recipient in `hears:` — mail is held and served only to a matching asker |

## Asking it questions

### Over HTTP

```
GET /api/xprs/dir                      # the XDIR1 directory (§36.9)
GET /api/xprs?type=warning&recent=1&limit=20
GET /api/xprs?since=<epoch>&until=<epoch>&limit=50
GET /api/xprs?days=7&from=X1A67X&limit=20
GET /api/xprs?type=message&asker=X1RD89&recent=1
```

| Parameter | Meaning |
|---|---|
| `type` | a type name; omitted means any |
| `recent=1` | newest first — the "most recent N" shape |
| `since`, `until` | epoch seconds, on the packet's own `ts:` |
| `days` | a window ending now, when the clock is set |
| `from` | author callsign |
| `asker` | who is asking; **mail is only returned when this matches its `d:` or `f:`** |
| `limit` | capped at 200, default 30 |

The reply carries the store's `epoch` letter and `count`, the records with their
`wire` verbatim, and `us` — the query's own time on the device, so you can see
what a question cost rather than take a claim for it.

The APRS archives are separate endpoints: `/api/aprs`, `/api/beacons`,
`/api/igate`.

### Over GATT

Write `{"type":"xprs_query", "pkt":"warning", "recent":true, "limit":10,
"since":…, "until":…, "from":…, "asker":…}` to `FFF1`; the answer comes back on
`FFF2` as one `xprs_page` notification sized to the negotiated MTU.

**The `asker` is self-declared on both paths.** There is no authenticated
identity on an HTTP request or a GATT write, so it stops the station handing a
stranger's mail to a passer-by and is not proof of who is asking. The body of
sealed mail is unreadable to the device either way.

## Numbers

| | |
|---|---|
| Longest packet | 250 B |
| Record on disk | 320 B, packet verbatim |
| Segment | 4096 records = 1.31 MB |
| Retention | the card (29 GB on the test unit); no eviction yet |
| Write path | decided on arrival, queued in RAM, drained to the card in bursts every 2 s |
| "20 most recent warnings" | **~19–28 ms** |
| "50 records across a year" | **~123 ms** |
| Newest record | **2–9 ms** |
| Author filter without a type | **seconds** — nothing indexes authors, so it scans |

## Operating it

- **It lives on about 15 KB of free heap.** Adding a task or a buffer can take
  the station off the air; the console prints a heartbeat every 15 s with free
  heap and its low-water mark, and that is the first thing to read.
- **Opening the USB serial port reboots it.** Probe it over the network instead,
  and give it ~30 s after a reset before believing any measurement.
- **A stack overflow presents as a reboot loop**, which from the network is
  indistinguishable from a flaky link. Check the console for
  `***ERROR*** A stack overflow in task` before blaming WiFi.
- **The SD card and the radios share a processor.** Everything that writes to
  the card runs on core 1 for that reason; see `docs/esp32.md`.
- Without a card it still relays and bridges; it simply keeps nothing.

## See also

- [XPRS.md](XPRS.md) — the format and the rules this device follows
- [indexer.md](indexer.md) — what an indexer is for, and the Flutter side
- [lan.md](lan.md) — the UDP bearer in detail
- [ble5.md](ble5.md) — the Bluetooth bearer (extended advertising is `rns_ble5`)
- [esp32.md](esp32.md) — firmware layout, constraints and traps
