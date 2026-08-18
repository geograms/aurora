# ESP32 firmware -- map & special characteristics

**Looking for what a device supports rather than how the firmware is built?**
[device-tdongle.md](device-tdongle.md) is the T-Dongle-S3's own page: its
bearers, what of XPRS it implements, what it deliberately does not, and how to
ask it questions.

Read this before touching `esp32/` -- it saves re-reading the tree. Covers the
project layout, which firmware is which, the BLE protocol state, the traps, and
the three constraints this board keeps punishing people for: **which processor
the work runs on**, **when the SD card is allowed to run**, and **how little
memory is left**.

## Three projects, one component library

| | Main multi-board project (`esp32/`) | `esp32/rns_ble5/` | `esp32/m5stack/` |
|---|---|---|---|
| Build | PlatformIO, `platformio.ini` with 8 envs (`pio run -e <env>`) | Own PlatformIO project, single env (`pio run` inside the dir) | same, `pio run` inside `esp32/m5stack/` |
| Framework | ESP-IDF **5.2.1** (espressif32@6.7.0) -- pinned, see memory note about needing a real framework dir | same | same |
| App | `src/main.cpp` (one binary, `HAS_*`/`FEATURE_*` gates per board) | `src/main.c` + `tweetnacl.c` | `src/main.c`, ~200 lines |
| BLE | **Legacy advertising only** (31 B) -- `geogram_ble_hello` | **BLE5 extended advertising** (`CONFIG_BT_NIMBLE_EXT_ADV=y`) | **none** -- this chip has no ext-adv |
| Boards | epaper-S3 (default env!), generic, C3, KV4P, Heltec v1/v2/v3, tdongle_s3 | T-Dongle-S3 (board id `esp32s3-devkitc-1`) | M5Stack Core, original ESP32-D0WDQ6, CP2104 at `/dev/ttyUSB0` |

`esp32/m5stack/` exists to be a **second voice on the air**: testing a bearer
with one device only proves that its loopback works. It shares the
communication components by symlink (`geogram_xprs`, `geogram_xprsbearer`,
`geogram_xprsnow`, `geogram_xprslan`) and runs XPRS over ESP-NOW and the LAN.
Its WiFi credentials live in a gitignored `src/wifi_secrets.h`, and they matter
for one reason: **ESP-NOW rides the channel the station is on**, so associating
to the same access point as the dongle is what puts both on the same channel
without anybody guessing one.

**The mesh/BLE5-capable dongle firmware is `rns_ble5`** -- the main project's
T-Dongle env is the older legacy-BLE APRS firmware. They cannot be merged
casually: NimBLE's legacy GAP API changes/goes away when `EXT_ADV` is enabled,
which is exactly why they are separate binaries.

Components live in `esp32/components/` (50+, prefix `geogram_*`); `rns_ble5`
reuses them via **symlinks in `rns_ble5/components/`** (PlatformIO fails on
`EXTRA_COMPONENT_DIRS` outside the project dir -- always symlink instead).
Component CMake gates by **IDF_TARGET, not CONFIG_** (early-expansion gotcha,
see `geogram_msgstore/CMakeLists.txt`).

## Radio capability per chip (mesh implications)

- **Original ESP32** (Heltec v1/v2, KV4P): **no BLE5 extended advertising** --
  those boards can never join the extended-advert mesh plane; legacy 31 B only.
- **S3 / C3 class** (T-Dongle-S3, Heltec v3, C3-mini): extended advertising OK,
  one AD structure <= **254 B** (`EXT_ADV_MAX_SIZE=1650` is the chain cap; we
  keep every frame in a single AD <=254 B so phones with ~247 B controller caps
  hear it).
- The dongle runs **one ext-adv instance**; `relay_task` rotates what's on air
  every 1.5 s: queued relayed frames first, else (idle) alternating our signed
  RNS announce and the mesh route beacon every 8 s.

## BLE wire protocols (all under company id 0xFFFF, marker 0x3E)

| Subtype | Meaning | Who |
|---|---|---|
| `0x55` | Reticulum packet (announces relayed blind, HEADER_2 hops+1) | rns_ble5 |
| `0x41` | APRS broadcast parcel, compact `from\x1F to\x1F text` | both projects + phones |
| `0x4D` | **street-mesh route beacon** (docs/mesh.md section 3) | rns_ble5 (`geogram_blemesh`) + phones |
| `0x47` | phone GATT presence beacon | phones only (not implemented on ESP32) |
| `0x50/0x51/0x52` | legacy broadcast-parcel chunks + NACK (13-17 B payloads) | legacy firmware + legacy-phone path |
| `0x42` | legacy SCAN_RSP continuation | legacy firmware |

Legacy firmware advert caps are compile-time (`ADV_MFG_CAP=20`,
`APRS_MFG_MAX=44` with SCAN_RSP); the phones' extended frames are simply
invisible to it.

## geogram_blemesh (the reusable mesh core)

`components/geogram_blemesh/` -- pure C, deps mbedtls+log only, **no radio/
storage/UI** (firmware wires those), so it ports to any ESP32 target:

- `blemesh_beacon.c` -- 0x4D codec, wire-compatible with
  `aurora/lib/services/mesh/mesh_beacon.dart` (ver 1, class byte, cond byte,
  3-byte SHA-256 callsign hash + cost DV entries, bloom slot reserved).
- `blemesh_table.c` -- neighbors (24) + DV routes (64), bidirectional-confirmed
  next-hops, cost cap 6, 300 s aging, DV export (neighbors at cost 1 first).
- `blemesh_scf.c` -- store-and-forward custody: parks heard 1:1 `0x41` frames
  keyed by their `am:` receipt id, purges on overheard `?ACK <am>`, re-airs
  when the target's beacon/frame is heard again (60 s per-sighting rate
  limit), 7-day TTL, optional stdio persistence (`/sdcard/mesh/pending.bin`).

Firmware glue lives in `rns_ble5/src/main.c`: scan demux -> `handle_mesh`,
`mesh_beacon_air` (class `esp32`, powered, stationary, storage bucket from SD),
SCF hooks inside `handle_aprs`, init in `app_main` after `igate_start` (the
mesh identity is the iGate callsign from NVS, fallback `TDONGLE`).

## Current-protocol rules the firmware honours (don't regress)

- **1:1 receipts**: messages carry a prepended `am:<6hex> ` token; receipts are
  `?ACK <am> d|r` frames. The dongle parks 1:1 frames by `am` and purges on
  `?ACK`. It never generates receipts (it is a carrier, not an endpoint).
- **Control frames never reach APRS-IS**: any text starting `?` (`?ACK`,
  `?PING`, `?MAIL`...) is not uplinked.
- **ENC1 ciphertext never reaches APRS-IS**: the phones deliberately keep
  encrypted 1:1 off the 7-bit APRS-IS air (it arrives as undecryptable
  garbage). The dongle checks the text after the optional `am:` token.
- Everything else is **relayed blind** (content-dedup ring 32/600 s), extending
  BLE coverage one hop -- including `?ACK` frames and ENC1 payloads over BLE.

## Ops / hardware traps

- T-Dongle-S3 flashes over native USB-JTAG (`/dev/ttyACM0`); after flashing it
  needs `--after hard_reset` (default) -- the port re-enumerates.
- LCD is ST7735 160x80 via LVGL 8.3.11 (`geogram_tdongle_ui`); LVGL is
  single-task -- UI updates only via the queue -> `ui_task`.
- SD is the T-Dongle's hidden microSD slot (under the USB-A cap); mounted at
  `/sdcard` via `geogram_sdcard` (SDMMC). Absent card must degrade gracefully.
- WiFi + BLE coexist: the ext scan runs at 60% duty (0x60 itvl / 0x50 window)
  deliberately, so WiFi (iGate) still gets airtime. That duty is about the
  handshake, not about throughput -- when WiFi collapses later, the cause is
  almost certainly the processor, not the antenna. See "The two processors".
- Secrets (`igate_secrets.h`) are gitignored; provisioning writes them to NVS
  on first boot and NVS is the source of truth afterwards.
- `build.sh` menu does NOT list tdongle_s3 or rns_ble5 -- build those directly
  (`pio run -e tdongle_s3` at the root, or `pio run` inside `rns_ble5/`).
- A full cold build takes >10 min (IDF from scratch); incremental is fast.

## The two processors -- the rule that matters most

This chip has two cores and this firmware puts everything that matters on one
of them:

| Core 0 | Core 1 |
|---|---|
| BLE controller (`CONFIG_BT_CTRL_PINNED_TO_CORE 0`) | `xprsidx_wr` -- the index's writer |
| NimBLE host (`CONFIG_BT_NIMBLE_PINNED_TO_CORE 0`) | `rns_relay` -- signing, and the `cmd:history` replay |
| WiFi task (IDF default) | `rns_tcp`, `heartbeat`, the httpd worker |
| `app_main` and everything it calls (`CONFIG_ESP_MAIN_TASK_AFFINITY 0x0`) | |

`xTaskCreate()` leaves a task with no affinity, which is not the same as putting
it on core 1. **Anything that blocks for milliseconds at a time -- SD, FATFS,
crypto over big buffers -- must be pinned to core 1**:

```c
xTaskCreatePinnedToCore(task, "name", stack, arg, prio, NULL, 1);
```

### It came back, wearing a different hat

Writing this page down did not stop it happening again. `cmd:history` -- an
indexer answering "what have you heard" -- was written to answer inline, on
whatever task heard the ask. That put a FatFs query on the **NimBLE host task**
(priority 21, core 0) for a Bluetooth ask and on the LAN bearer's task for a UDP
one, and it put the replay's record reads on `rns_relay`, which was created with
a bare `xTaskCreate` and therefore had no affinity at all.

It did not look like this section. It looked like heap: `wifi:m f null`, the
station associating and dropping a minute later, `ext_adv_set_data rc=519` from
the controller, and a low-water mark of **756 bytes**. It was diagnosed as heap
and "fixed" as heap, twice, before anyone re-read this page.

What it actually needed was the split this section already prescribes -- the
receive task decides *whether* to answer (parse, dedupe, budget: all RAM), and a
core-1 task does the query, the signature and every reply -- plus one line
turning `xTaskCreate` into `xTaskCreatePinnedToCore(..., 1)`.

| | Before | After |
|---|---|---|
| Reachability, idle | -- | 120 of 120 |
| Reachability, during a replay | station dropped off | **120 of 120** |
| Free heap | 8,320 | 26,828 |
| Low-water mark | **756** | 19,996 |
| Largest free block | 7,680 | 14,336 |

The heap half of that came from `CONFIG_LV_MEM_SIZE_KILOBYTES` 32 -> 16: LVGL's
pool was the largest single buffer in the build and this display is a 160x80
text dashboard. Two things are worth taking from it. **A file handle is not
free** -- `CONFIG_FATFS_SECTOR_4096` with `CONFIG_FATFS_PER_FILE_CACHE` means
every open `FILE` holds a 4 KB sector cache, and a store that keeps three open
and a query that opens two more wants 16-20 KB it has to borrow from WiFi. And
**a task that fails to start says nothing**: `xTaskCreate`'s result was ignored,
so three kilobytes of new static silently meant no relay task at all -- no
beacons, no announcements, no replay, and a board that looked healthy from
every other angle. Check the result and log it.

### What this looked like when it was wrong

The XPRS index wrote a 320-byte record to microSD for every packet heard, from
the receive path. The WiFi station stayed associated and could not transmit:
`wifi:m f null` repeating, DNS timing out, the device unreachable. Measured by
pinging once a second:

| Configuration | Reachable |
|---|---|
| BLE on, SD on, writes on core 0 | **1 of 96** |
| BLE on, SD off | 159 of 162 |
| BLE on, SD on, writes on **core 1** | **178 of 182** |

### What did not work, so nobody repeats it

The symptom reads exactly like a radio problem, and the firmware's own comment
about the SDMMC bus desensitising the 2.4 GHz radio encourages that reading. All
four of these were tried against the 1-of-96 baseline and **none of them changed
anything**:

- `esp_wifi_set_ps(WIFI_PS_MIN_MODEM)` -- what ESP-IDF's own coexistence example
  marks "must call this"
- the BLE scan cut from 60% to 10% duty (20 ms window / 200 ms interval)
- `esp_coex_preference_set(ESP_COEX_PREFER_WIFI)` instead of `BALANCE`
- stopping BLE entirely (advertising, scanning and any open connection) for the
  duration of the WPA2 handshake

They are all defensible; none of them is the bug. The bug was the processor.

### The web server belongs there too

`config.core_id = 1` on the **httpd** task, for the same reason: every handler
on this board reads the SD card, and httpd has **one worker task**, so whatever
that task waits for takes down every endpoint rather than just its own.

Two consequences worth building around:

- a handler must never queue behind a batch of SD writes. `geogram_xprsindex`
  therefore takes its lock **per record**, and offers `xprsindex_pause_writes()`
  so a reader can hold the writer off the card for the length of a request and
  give it straight back. Records keep arriving into RAM meanwhile.
- an endpoint that stops answering is **not** evidence of a wedged server. On
  this board it is usually the station having dropped off the WiFi: `curl`
  reports a timeout, and `ping` -- checked in the same breath -- reports "no route
  to host". Check reachability before you debug the server. That confusion cost
  a day here.

## The SD card

- The T-Dongle's microSD is under the USB-A cap, SDMMC, mounted at `/sdcard`.
  An absent card must degrade gracefully -- several components run without one.
- **Never write from a receive path.** Decide on the caller's thread (parse,
  identify, deduplicate -- all cheap) and hand the finished record to a queue
  that a core-1 task drains.
- **Drain in bursts, not as a trickle.** A writer waking ten times a second
  keeps the FATFS layer busy and every other reader of the card queues behind
  it -- including unrelated endpoints like `/api/beacons`. Two seconds between
  bursts is enough to keep the card free the rest of the time.
- **FatFs is not thread-safe and this is not theoretical.** Two tasks adding
  records while two servers read them, through one `FILE*`, returns records that
  are half another task's seek. Stores need their own mutex.
- **A file's size lives in its directory entry, and FatFs writes that on sync or
  close.** Two consequences, both cost a day to find:
  - a second `fopen()` of the segment currently being appended sees the size
    from the last sync -- usually zero -- so records just written read back empty.
    Read the active file through the handle that is writing it.
  - nothing closes that handle when the power goes, so without an `fsync()` the
    whole active file is invisible after a reboot. 2000 records were lost to a
    reset exactly this way.

## Heap is the binding constraint -- check it first

Every mysterious failure on this board so far has been heap. The symptoms do not
look like memory:

| What you see | What it actually is |
|---|---|
| `wifi:m f null` repeating | the driver cannot allocate its keepalive frame |
| ping fails while the log says the station is associated | lwip has no buffers |
| HTTP accepts TCP and never answers | the handler's 2-3 KB response `malloc` fails |
| `APRS-IS iGate init failed: ESP_FAIL` at boot | nothing left to start it with |
| a reboot every ~14 s | a task stack overflowed |
| `esp_now_send` returns `ESP_ERR_ESPNOW_NO_MEM` for every packet | the driver cannot get a send buffer |
| `BLE_INIT: Malloc failed` + `ext_adv_set_data rc=519` | the same, on the other radio |
| the station beacons never, answers nothing, and otherwise looks fine | a task never started -- see below |

**Create the big task stacks first.** `relay_task` asks for 8 KB in one piece.
It used to be created from `on_sync()`, which runs after WiFi, NimBLE, the SD
card, the HTTP server and the Reticulum hub have each taken their share: 15,308
bytes free but the largest block only **7,680**, so `xTaskCreatePinnedToCore`
returned `pdFAIL` and the station ran on with no beacons, no service
announcements, no `cmd:history` replay and no section 23.7 clock, while every other
task carried on and the heartbeat looked healthy. One `ESP_LOGE` at boot was the
entire evidence, and it scrolled past.

It is now claimed at the top of `app_main()`, where the heap is untouched
(172 KB in one block), and blocks on a flag until `on_sync()` releases it. The
heartbeat prints `relay=<loops>` so a task that stops is visible without
reading a boot log. **Check the return of every `xTaskCreate`, and prefer
claiming a large stack early over hoping it fits later.**

Measured heap by boot stage on the T-Dongle-S3 (`heap_mark()` in `main.c`), which
is how the above was found and the first thing to re-run when it recurs:

| after | free | largest block |
|---|---|---|
| boot | 234,244 | 172,032 |
| `model_init` (NVS + LCD) | 205,096 | 139,264 |
| `nimble_port_init` | 158,136 | 94,208 |
| `igate_start` (WiFi STA + lwip) | 90,952 | 31,744 |
| `sdcard_init` | 59,224 | 31,744 |
| the three XPRS bearers | 48,648 | 31,744 |
| `api_start` (httpd) | 39,792 | 31,744 |
| `rns_tcp_start` | 27,128 | 18,432 |

WiFi (62 KB), NimBLE (47 KB) and the SD card (32 KB) are the three that matter;
everything else is noise beside them. Steady state after association is around
13 KB, so **there is no room for a new 8 KB anything** -- take it at boot or
reclaim first (`sdkconfig` buffer counts) and measure again.

A queue is heap too. `XPRSNOW_RX_QUEUE` was widened from 4 to 16 to stop
drops -- 264 bytes an entry, so four kilobytes out of the eight the board had --
and ESP-NOW then refused every transmission for want of a buffer while the drop
counter it was widened to protect sat at zero throughout.

BLE is the reason there is nothing left. Measured on the T-Dongle:

```
heap after nostr init:   164,516
heap after WiFi AP/STA:  120,848
heap after httpd start:  103,928
heap after BLE init:      11,432   <- NimBLE and the controller take ~90 KB
```

Eleven kilobytes is what the whole rest of the firmware had to live in, and any
task stack added to it took the station off the air -- 117 of 117 pings answered
became 1 of 86 by adding two background tasks.

**Where the 90 KB was hiding.** The defaults are sized for a busy central, not
for a station that advertises, scans and holds at most one connection:

| Setting | Was | Now | Frees |
|---|---|---|---|
| `BT_NIMBLE_MSYS_2_BLOCK_COUNT` | 24 x 320 B | 8 | ~5 KB |
| `BT_NIMBLE_TRANSPORT_ACL_FROM_LL_COUNT` | 24 x 255 B | 8 | ~4 KB |
| `BT_NIMBLE_HOST_TASK_STACK_SIZE` | 8192 | 5120 | 3 KB |
| `BT_CTRL_BLE_MAX_ACT` | 6 | 3 | |
| `BT_CTRL_SCAN_DUPL_CACHE_SIZE` | 100 | 20 | |
| `BT_NIMBLE_ROLE_CENTRAL` | on | off (we never dial out) | |

Free heap after BLE init went **11,432 -> 29,408**, largest block 7,680 -> 21,504.
With that, reachability is 137/137, the iGate connects for the first time, and
every HTTP endpoint answers including the SD-backed ones.

**The file that matters is `esp32/sdkconfig.tdongle_s3`**, not
`boards/sdkconfig.tdongle_s3`. The board fragment is a defaults seed; PlatformIO
maintains the generated one at the project root and that is what the build uses.
The fragment had asked for `MSYS_1=6` and no central role for who knows how
long, and the build had 12 and central enabled.

### Task stacks are heap, and these are the measured floors

Every stack on this board comes out of the same ~15 KB, so they get trimmed --
and trimming them past what the task actually does turns a memory problem into a
reboot. Measured by overflowing them:

| Task | Floor | What costs the stack |
|---|---|---|
| `xprsidx_wr` | 4096 | FATFS and the SDMMC driver; 3072 overflowed under a burst |
| `xprslan` | 5120 | two SHA-256 derivations per datagram, a BLE re-air and a log line; 4096 overflowed |
| `aprsis` | 6144 | line parsing, DNS, socket; 4096 overflowed |
| `heartbeat` | 3072 | `ESP_LOG` with ten arguments is almost all of it; 2048 overflowed |

**`ESP_LOG` is the most stack-hungry thing a small task does.** A diagnostic
that crashes the board is worse than no diagnostic, and this one did, twice.

A stack overflow here presents as a **reboot loop of a few tens of seconds** --
which from the network looks exactly like a station that answers, then stops,
then answers again. Check the console for `***ERROR*** A stack overflow in task`
before believing anything about the network.

## Memory budget (no PSRAM)

`CONFIG_SPIRAM` is **not** set on the T-Dongle, so everything comes out of
internal SRAM, and the app partition is nearly full:

| | |
|---|---|
| App partition | 1,966,080 B |
| Current app | ~1,860,000 B (~105 KB spare) |
| Free heap after httpd starts | ~104 KB, largest block ~40 KB |

Consequences that have already bitten:

- an 8 KB request-time `malloc()` in an HTTP handler fails outright -- 2-3 KB is
  the realistic ceiling
- the httpd task stack is trimmed to **5120 B** on this board, so a handler that
  puts a couple of 600-byte buffers on the stack can take the server down; build
  responses straight into the response buffer
- SQLite does not fit, which is why `geogram_xprsindex` is what it is

## What the T-Dongle stores and speaks

- `geogram_msgstore` -- the APRS archives (`/sdcard/aprs/msg`, `.../beacon`),
  192-byte records, served by `/api/aprs` and `/api/beacons`.
- `geogram_xprsindex` -- every XPRS packet heard, verbatim, 320-byte records in
  segments, with a zone map for time ranges and a tail index per type. Serves
  `/api/xprs` and the GATT `xprs_query`. Section 36 of `XPRS.md` is enforced in
  the store: a packet with `d:` is held and never handed to a third party.
- `geogram_xprslan` -- XPRS as UDP broadcast on the LAN, port 4242, the same
  number XPRS answers on over TCP (`XPRS.md` section 24.4). See [lan.md](lan.md). Not
  Reticulum (that is UDP 42671, `geogram_lanwatch`, listen only) and not the
  internet.

## Validating on the device

- **Opening `/dev/ttyACM0` reboots the board.** `monitor-capture.sh` asserts DTR
  whether or not `-r` is passed, and the board needs ~28 s afterwards before it
  is on the network again. A probe sent during a capture hits a rebooting
  device, and the result means nothing.
- So **measure over the network** -- ping, curl, UDP -- with no serial open. Use
  serial only for facts that are only visible at boot: heap sizes, "HTTP server
  started", WiFi disconnect reasons.
- Reachability is the honest metric for anything touching the radio. One ping a
  second for three minutes, reported as *n* of *m*, is what turned a week of
  plausible theories into the table above.
- Change one thing at a time and keep the baseline. Four radio settings were
  changed on a wrong hypothesis before an A/B against `FEATURE_SDCARD=0` showed
  where the problem actually was.

### Open

- SD-backed HTTP endpoints (`/api/xprs`, and the pre-existing `/api/beacons`)
  time out in longer runs even though httpd starts cleanly with ~104 KB free.
  Not diagnosed.
- Reachability has been measured at 178/182 and, an hour later on the same
  firmware, 0/70 with the STA failing to associate (reasons 202/205). Whether
  that is the access point or a late regression is unresolved -- re-measure
  before trusting a single run.

## Known gaps / next steps

- Legacy T-Dongle firmware (`geogram_ble_hello`) knows nothing of `am:`/`?ACK`/
  `ENC1:`/0x4D -- fine as long as it's used for legacy-only deployments.
- GATT multi-parcel RX is unimplemented in the legacy firmware (single parcel
  only). rns_ble5 HAS a full MSP GATT server since M2 (`src/gatt_mesh.c`):
  FFE0/FFF1/FFF2, legacy connectable advert on ext-adv instance 1
  (NIMBLE_ROLE_PERIPHERAL=y, MAX_EXT_ADV_INSTANCES=2, MAX_CONNECTIONS=1),
  notify TX ring paced by NOTIFY_TX + 5 s in-flight watchdog, idle-central
  reaper, SD bulk spool at /sdcard/mesh/bulk with a RAM-FIRST index (the FAT
  VFS readdir deadlocks against concurrent SD writers -- never walk the dir
  outside boot), console `sendfile <to> <path>` / `transfers` / `recv`
  (base64 file upload over USB) / `advon|advoff` / `scankick` / `wifioff`.
  TRAPS: CONFIG_BT_CTRL_BLE_SCAN_DUPL must be n (the controller dedups scan
  reports BY ADDRESS -- fixed-address phones are reported once per boot and
  then never again); NimBLE may fail to route connection GAP events to the
  adv-instance callback -- register a ble_gap_event_listener instead; an ESP
  reset does NOT power-cycle a wedged SD card (physical replug only).
- Beacon carries the [pending_msgs][pending_bulk] trailer since M2; the
  have-digest bloom stays empty on the dongle (a carrier receives no 1:1s).
- Duplicate-delivery edge: SCF re-air more than ~60 min after the receiver
  already got the message can re-show it (phone content-dedup window) -- the
  `?ACK` purge covers the normal case.
- The old `geogram_mesh` component is the DISABLED ESP-WIFI-MESH bridge
  (`FEATURE_MESH=0`), unrelated to the BLE street mesh -- don't confuse the two.
