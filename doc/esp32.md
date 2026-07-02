# ESP32 firmware — map & special characteristics

Read this before touching `esp32/` — it saves re-reading the tree. Covers the
project layout, which firmware is which, the BLE protocol state, and the traps.

## Two projects, one component library

| | Main multi-board project (`esp32/`) | `esp32/rns_ble5/` |
|---|---|---|
| Build | PlatformIO, `platformio.ini` with 8 envs (`pio run -e <env>`) | Own PlatformIO project, single env (`pio run` inside the dir) |
| Framework | ESP-IDF **5.2.1** (espressif32@6.7.0) — pinned, see memory note about needing a real framework dir | same |
| App | `src/main.cpp` (one binary, `HAS_*`/`FEATURE_*` gates per board) | `src/main.c` + `tweetnacl.c` |
| BLE | **Legacy advertising only** (31 B) — `geogram_ble_hello` | **BLE5 extended advertising** (`CONFIG_BT_NIMBLE_EXT_ADV=y`) |
| Boards | epaper-S3 (default env!), generic, C3, KV4P, Heltec v1/v2/v3, tdongle_s3 | T-Dongle-S3 (board id `esp32s3-devkitc-1`) |

**The mesh/BLE5-capable dongle firmware is `rns_ble5`** — the main project's
T-Dongle env is the older legacy-BLE APRS firmware. They cannot be merged
casually: NimBLE's legacy GAP API changes/goes away when `EXT_ADV` is enabled,
which is exactly why they are separate binaries.

Components live in `esp32/components/` (50+, prefix `geogram_*`); `rns_ble5`
reuses them via **symlinks in `rns_ble5/components/`** (PlatformIO fails on
`EXTRA_COMPONENT_DIRS` outside the project dir — always symlink instead).
Component CMake gates by **IDF_TARGET, not CONFIG_** (early-expansion gotcha,
see `geogram_msgstore/CMakeLists.txt`).

## Radio capability per chip (mesh implications)

- **Original ESP32** (Heltec v1/v2, KV4P): **no BLE5 extended advertising** —
  those boards can never join the extended-advert mesh plane; legacy 31 B only.
- **S3 / C3 class** (T-Dongle-S3, Heltec v3, C3-mini): extended advertising OK,
  one AD structure ≤ **254 B** (`EXT_ADV_MAX_SIZE=1650` is the chain cap; we
  keep every frame in a single AD ≤254 B so phones with ~247 B controller caps
  hear it).
- The dongle runs **one ext-adv instance**; `relay_task` rotates what's on air
  every 1.5 s: queued relayed frames first, else (idle) alternating our signed
  RNS announce and the mesh route beacon every 8 s.

## BLE wire protocols (all under company id 0xFFFF, marker 0x3E)

| Subtype | Meaning | Who |
|---|---|---|
| `0x55` | Reticulum packet (announces relayed blind, HEADER_2 hops+1) | rns_ble5 |
| `0x41` | APRS broadcast parcel, compact `from\x1F to\x1F text` | both projects + phones |
| `0x4D` | **street-mesh route beacon** (doc/mesh.md §3) | rns_ble5 (`geogram_blemesh`) + phones |
| `0x47` | phone GATT presence beacon | phones only (not implemented on ESP32) |
| `0x50/0x51/0x52` | legacy broadcast-parcel chunks + NACK (13-17 B payloads) | legacy firmware + legacy-phone path |
| `0x42` | legacy SCAN_RSP continuation | legacy firmware |

Legacy firmware advert caps are compile-time (`ADV_MFG_CAP=20`,
`APRS_MFG_MAX=44` with SCAN_RSP); the phones' extended frames are simply
invisible to it.

## geogram_blemesh (the reusable mesh core)

`components/geogram_blemesh/` — pure C, deps mbedtls+log only, **no radio/
storage/UI** (firmware wires those), so it ports to any ESP32 target:

- `blemesh_beacon.c` — 0x4D codec, wire-compatible with
  `aurora/lib/services/mesh/mesh_beacon.dart` (ver 1, class byte, cond byte,
  3-byte SHA-256 callsign hash + cost DV entries, bloom slot reserved).
- `blemesh_table.c` — neighbors (24) + DV routes (64), bidirectional-confirmed
  next-hops, cost cap 6, 300 s aging, DV export (neighbors at cost 1 first).
- `blemesh_scf.c` — store-and-forward custody: parks heard 1:1 `0x41` frames
  keyed by their `am:` receipt id, purges on overheard `?ACK <am>`, re-airs
  when the target's beacon/frame is heard again (60 s per-sighting rate
  limit), 7-day TTL, optional stdio persistence (`/sdcard/mesh/pending.bin`).

Firmware glue lives in `rns_ble5/src/main.c`: scan demux → `handle_mesh`,
`mesh_beacon_air` (class `esp32`, powered, stationary, storage bucket from SD),
SCF hooks inside `handle_aprs`, init in `app_main` after `igate_start` (the
mesh identity is the iGate callsign from NVS, fallback `TDONGLE`).

## Current-protocol rules the firmware honours (don't regress)

- **1:1 receipts**: messages carry a prepended `am:<6hex> ` token; receipts are
  `?ACK <am> d|r` frames. The dongle parks 1:1 frames by `am` and purges on
  `?ACK`. It never generates receipts (it is a carrier, not an endpoint).
- **Control frames never reach APRS-IS**: any text starting `?` (`?ACK`,
  `?PING`, `?MAIL`…) is not uplinked.
- **ENC1 ciphertext never reaches APRS-IS**: the phones deliberately keep
  encrypted 1:1 off the 7-bit APRS-IS air (it arrives as undecryptable
  garbage). The dongle checks the text after the optional `am:` token.
- Everything else is **relayed blind** (content-dedup ring 32/600 s), extending
  BLE coverage one hop — including `?ACK` frames and ENC1 payloads over BLE.

## Ops / hardware traps

- T-Dongle-S3 flashes over native USB-JTAG (`/dev/ttyACM0`); after flashing it
  needs `--after hard_reset` (default) — the port re-enumerates.
- LCD is ST7735 160×80 via LVGL 8.3.11 (`geogram_tdongle_ui`); LVGL is
  single-task — UI updates only via the queue → `ui_task`.
- SD is the T-Dongle's hidden microSD slot (under the USB-A cap); mounted at
  `/sdcard` via `geogram_sdcard` (SDMMC). Absent card must degrade gracefully.
- WiFi + BLE coexist: the ext scan runs at 60% duty (0x60 itvl / 0x50 window)
  deliberately, so WiFi (iGate) still gets airtime.
- Secrets (`igate_secrets.h`) are gitignored; provisioning writes them to NVS
  on first boot and NVS is the source of truth afterwards.
- `build.sh` menu does NOT list tdongle_s3 or rns_ble5 — build those directly
  (`pio run -e tdongle_s3` at the root, or `pio run` inside `rns_ble5/`).
- A full cold build takes >10 min (IDF from scratch); incremental is fast.

## Known gaps / next steps

- Legacy T-Dongle firmware (`geogram_ble_hello`) knows nothing of `am:`/`?ACK`/
  `ENC1:`/0x4D — fine as long as it's used for legacy-only deployments.
- GATT multi-parcel RX is unimplemented in the legacy firmware (single parcel
  only); rns_ble5 has no GATT server at all (broadcast + scan only), so >254 B
  payloads cannot reach the dongle.
- Beacon has no have-digest bloom yet (slot reserved on the wire).
- Duplicate-delivery edge: SCF re-air more than ~60 min after the receiver
  already got the message can re-show it (phone content-dedup window) — the
  `?ACK` purge covers the normal case.
- The old `geogram_mesh` component is the DISABLED ESP-WIFI-MESH bridge
  (`FEATURE_MESH=0`), unrelated to the BLE street mesh — don't confuse the two.
