# Performance

How Aurora burns CPU and memory, what we fixed, how to measure it, and what is
still on the table. Written after a day that started with the app frozen solid
for hours on a phone and ended with it idling at 8% of a core.

Everything here is measured, not assumed. Where a number appears, the method
that produced it is given, because **the wrong method produces confident
nonsense** — see [Measurement discipline](#measurement-discipline).

---

## 1. The architecture, in CPU terms

Aurora runs a full Reticulum node, a NOSTR relay/engine, a BLE mesh and a WASM
wapp runtime inside a Flutter app. Almost all of that used to sit on the **UI
isolate**. It doesn't any more:

| Isolate | Owns | Spawned by |
|---|---|---|
| `main` | UI, wapp engines, LXMF/files/relay subsystems, all the sqlite stores except the NOSTR feed | Flutter |
| `rns-transport` | RnsTransport: announce validation, dedup, path table, transit forwarding, rebroadcast, passive governor | `RnsTransportClient.spawn` (`rns_transport_engine.dart`) |
| `rns-crypto` | Every hot Curve25519 op (verify / sign / derive / ECDH / keygen), keypair cache, bounded queue | `_CryptoWorker` (`rns_crypto.dart`) — one per isolate that uses RnsCrypto, so there are normally two |
| `nostr-engine` | Public-relay firehose: WS receive, decode, verify, `nostr_feed.sqlite3`, like/reply tallies | `NostrClient.spawn` (`nostr_engine.dart`) |
| `i2p` (opt-in) | The I2P node | `i2p_worker.dart` |

Two things follow from this and are easy to forget:

1. **Main-isolate metrics can look perfectly clean while a worker burns a
   core.** The task monitor only measures main. A worker at 100% shows up as
   *zero* stalls and *zero* task CPU. This actually happened — see §3.2.
2. **Radios stay on the root isolate.** BLE5 and WiFi-Direct are plugin
   (MethodChannel) bound and cannot move; there is no
   `BackgroundIsolateBinaryMessenger` anywhere in the tree. Anything that needs
   them bridges raw bytes over ports. That is why the transport engine registers
   the owner's sockets/radios as *external* interfaces rather than owning them.

---

## 2. Telemetry — read this before profiling anything

All of it lands in the in-app log ring, served by `GET /api/log`. None of it
needs a debug build.

| Line | Source | Tells you |
|---|---|---|
| `perf: main isolate stalled ~Nms` | `main.dart` 500ms heartbeat | The UI event loop blocked for N ms. Steady state should be **zero**. |
| `perf: cpu tasks total …` | `TaskMonitorService.startCpuSummary` | Per-task **main-isolate** CPU, ranked, every 60s. |
| `perf: crypto-worker edVerify=… x25519Gen=… edSign=…` | `RnsCrypto.drainCryptoStats` | Curve25519 ops per minute **by type**. The composition is the diagnosis (see §3.4). |
| `perf: nostr-engine seen=… stored=… reactions=… profileLookups=…` | `NostrRelayHub.drainEventStats` | Relay firehose volume + how much sqlite it is provoking. |
| `perf: rns-transport announces/s=… paths=… passive=…` | `RnsService` | The announce flood the transport engine is chewing. |
| `perf: <task> tick took Nms` | `TaskMonitorService.reportSuccess` | Any monitored tick over 48ms. |
| `vmService` in `GET /api/status` | `main.dart` + `LogService.vmServiceUri` | The Dart VM service URI **with its auth token**. |

**Why `vmService` is pinned in `/api/status`:** when the app wedges, live isolate
stacks are the only way in, and the URI scrolls out of both logcat and the log
ring within minutes on a busy node — gone exactly when you need it. It is now
always one request away.

### Getting live isolate stacks / heaps

```sh
adb forward tcp:13456 tcp:3456
URI=$(curl -s http://127.0.0.1:13456/api/status | python3 -c "import json,sys;print(json.load(sys.stdin)['vmService'])")
PORT=${URI#http://127.0.0.1:}; PORT=${PORT%%/*}
TOKEN=$(echo "$URI" | sed "s|http://127.0.0.1:$PORT/||;s|/$||")
adb forward tcp:14990 tcp:$PORT
# then talk JSON-RPC to ws://127.0.0.1:14990/$TOKEN/ws :
#   getVM, getStack, getMemoryUsage, getAllocationProfile, pause/resume
```

`getStack` on a paused isolate is the poor-man's profiler and it found two of
the bugs below. **The CPU profiler (`getCpuSamples`) is compiled out of our
debug builds** and returns "Profiler is disabled"; `setFlag('profiler', true)`
reports success but still yields zero samples. Don't burn time on it.

**A profiled isolate showing 0 frames while its thread burns 100% CPU means it
is inside a native FFI call** (sqlite3, wasmtime) — the Dart profiler cannot see
those frames. That signature is itself the clue.

---

## 3. Fixed: what was actually wrong

### 3.1 The freeze (`rns_crypto.dart`)

The app hard-froze for hours: main thread pegged, one DartWorker at 100% whose
**TID rotated**, heap climbing, event loop dead.

Cause: `ed25519Verify` was doing `Isolate.run` **per verification**, serialized
through a cap-1 semaphore with an **unbounded waiter queue**. Per-verify isolate
spawn/teardown churned the main isolate (hence the rotating worker), and the
backlog held key/message copies alive (hence the heap → GC spiral).

Then, with verifies offloaded, live stacks caught main *inside* `ed25519Sign`'s
per-call keypair derivation, and then inside `x25519Generate` — the responder's
ephemeral keypair for **every inbound link request**.

Fix: **one persistent `rns-crypto` worker isolate** for all of it, keypair cache
by seed, bounded pending map. Inbound verifies shed under backlog (fail closed —
a forged signature can never pass); our own ops queue with backpressure.

> **Rule: never `Isolate.run` per item on a hot path.** The spawn/teardown cost
> lands on the caller and an unbounded backlog is a memory leak with extra steps.
> Use one long-lived worker + a bounded queue.

### 3.2 The pegged core with nothing to show for it (`nostr_engine.dart`)

A DartWorker sat at 100% while *every* counter said idle. Invisible to the Dart
profiler because it was inside native sqlite. Three causes, all **work redone
forever**:

- **`_syncMyFollows()` ran on every 400ms tick**: a sqlite query for our kind-3
  contact list, then a re-parse of every `p` tag in it (contact lists routinely
  carry thousands). The dedup guard suppressed only the outbound *message* —
  never the work. Now gated on the stored event: the hub flags it dirty when a
  new kind-3 of ours actually lands.
- **Profile lookups cached only hits.** Every author whose kind-0 never arrives —
  most of a public firehose — was re-queried against sqlite on every tick,
  forever. Now misses are remembered too (5-min retry), and lookups per tick are
  bounded.
- **Reaction receipts were persisted for the entire kind-7 firehose** (a
  regression introduced the same day): one unbatched INSERT per inbound reaction,
  *ahead of the rate cap*, for rows nobody would ever read. Now persisted only
  for posts we actually track — exactly the ones the UI shows.

> **Rule: cache the miss, not just the hit.** A cache that only remembers
> successes re-does the failure forever, and failures are the common case on a
> public network.

### 3.3 The log ring held ~50MB (`log_service.dart`)

Allocation profiling found ~50MB of heap in ~2,200 giant strings. The 2,000-line
ring retained full announce dumps, and profile announces embed **base64 avatars**
— single lines ran tens of KB (UTF-16 for anything with an emoji). That standing
heap kept old-space GC churning: the residual ~1s stalls after the isolate
migration. Lines are now capped at 512 chars with an elided-byte marker.
Reclaimed ~300MB RES.

### 3.4 The idle-node CPU: a keypair we threw away (`rns_link.dart`)

Screen-off CPU sat at 17–44% of a core on an *idle* node. The crypto counters
gave it away by their **composition**:

```
perf: crypto-worker x25519Gen=37 edGen=37 x25519Shared=29 edSign=33 edVerify=16
                    ^^^^^^^^^^^^^^^^^^^^^ identical counts → paired → a full keypair mint
```

~37 link handshakes/minute — peers across the network querying this phone's
relay index, and the log showed most answered `relay: answered REQ -> 0
event(s)`. Each handshake cost **four Curve25519 scalar multiplications** in pure
Dart.

One of the four was pure waste: the per-link Ed25519 keypair's **private half is
never used**. The proof is signed with the *identity* key (`rns_link.dart`
`buildProof`); the ephemeral `_edPub` only ever goes onto the wire. We minted a
full keypair per link to produce a key we immediately discarded.

Fix: share one ephemeral Ed25519 public key across links, rotated every 10
minutes so it stays short-lived rather than a permanent cross-link identifier.
The **X25519 pair stays fresh per link** — it is the ECDH half and reusing it
would destroy forward secrecy.

**Screen-off CPU: 17–44% → 8% of a core.**

### 3.5 Smaller, still real

- **Image cache**: Flutter's default is 100MB / 1000 images — desktop-sized. The
  launcher's carousel feeds it full-resolution network photos. Capped to 32MB /
  100 on Android+iOS (`main.dart`).
- **Wapp SVG icons were re-read from disk on every build** (a platform-channel
  round trip per tile, per frame — 700ms build frames while dragging the app
  sheet). Cached and prewarmed after the scan.
- **discoF subscription leak**: the NOSTR discovery fetch created a subscription
  every 3s and never unsubscribed. The filter set grew forever and every inbound
  event paid an O(subs) match. TTL-reaped at 30s.

---

## 4. Measurement discipline

**This section exists because ignoring it produced a confidently wrong
conclusion.** Mid-investigation, a 45-second A/B "showed" the background chat
wapp cost 78% of a core. Proper 5-minute windows: chat running **17%**, chat
stopped **18%**. Chat costs essentially nothing. The 45s windows had landed on
bursts.

Rules:

1. **App CPU is bursty. Use ≥5-minute windows for any CPU claim.** Anything
   shorter is noise. Announce floods, DHT replication and relay queries arrive in
   clumps.
2. **Measure screen-OFF for battery claims,** and *verify* the screen is actually
   off — the human may have woken the phone:
   ```sh
   adb shell dumpsys power | grep -o "mWakefulness=[A-Za-z]*"   # want: Asleep
   ```
   Screen-on adds ~5% raster + GPU purely from the carousel animating. That is
   not a bug; it is a screen being on.
3. **Read process CPU and per-thread CPU in ONE device-side command.** Iterating
   `/proc/$PID/task/*` over adb takes long enough that the process window and the
   thread windows no longer line up, and the totals stop reconciling.
   ```sh
   adb shell "P1=\$(awk '{print \$14+\$15}' /proc/$PID/stat)
     for t in /proc/$PID/task/*; do echo \"A \$(basename \$t) \$(cat \$t/comm) \$(awk '{print \$14+\$15}' \$t/stat)\"; done
     sleep 300
     P2=\$(awk '{print \$14+\$15}' /proc/$PID/stat)
     for t in /proc/$PID/task/*; do echo \"B \$(basename \$t) \$(cat \$t/comm) \$(awk '{print \$14+\$15}' \$t/stat)\"; done
     echo \"PROC \$P1 \$P2\""
   ```
   Ticks are 100/s; `delta*100/(seconds*100)` = % of one core.
4. **A/B by turning things off.** `POST /api/wapp/stop {"wapp":"chat"}` is the
   cleanest lever the app has. Just do it over long windows.
5. **Thread names matter.** `.geogram.aurora` is the platform/main thread,
   `1.raster` is Flutter's rasteriser, `DartWorker` are isolate threads (the VM
   pool reuses them, so a name does not identify an isolate), `mali-*` is the GPU
   driver.

---

## 5. Build & device traps (each of these cost real time)

- **`adb uninstall` WIPES app data.** The identity survives (`identity-backup.json`
  in shared storage → "Restore <callsign>" card on next launch), **wapp data does
  not**. Do not reach for uninstall to resolve an install conflict.
- **The CI/release build is signed with the release key.** A debug APK cannot
  update it (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`). Build a **release-signed**
  APK instead and it updates in place, data intact.
- **versionCode**: debug builds are `278` (from `pubspec.yaml`), the CI release is
  `21541+` → `INSTALL_FAILED_VERSION_DOWNGRADE`. Pass
  `--build-number=NNNNN` (higher than installed).
- **Profile builds are now release-signed** (`android/app/build.gradle.kts`), so
  they update an installed release in place *and* carry the Dart VM service at
  release-grade AOT speed. **This is the build to profile with** — debug numbers
  are distorted by JIT (~45MB of extra heap in `Instructions`/`Code`/`ICData`
  alone).
- **`cd android` inside a shell persists across commands.** `build/` then resolves
  to `android/build/` and the APK looks "missing" while Flutter cheerfully reports
  it built.
- **`adb monkey` injects a random tap** after launching. Use
  `am start -n com.geogram.aurora/.MainActivity`.

---

## 6. Open ideas, roughly by value

### 6.1 Native crypto (the big one)

The remaining ~90 crypto ops/min (x25519Gen + x25519Shared + edSign + edVerify)
are *inherent* to answering link handshakes — with **pure-Dart curve math**, tens
of ms each. `cryptography_flutter` swaps in platform BoringSSL/Conscrypt behind
the identical `cryptography` API: same algorithms, same wire bytes, typically
10–100× faster. It would collapse essentially all remaining crypto CPU and make
the whole shed/budget apparatus mostly unnecessary.

Against it: it adds a native dependency, and the package header states the design
principle "*All pure Dart, no native binaries*" (chosen for portability —
desktop, web, and wire-compat confidence). This is an **architecture decision, not
a patch** — hence flagged here rather than taken.

If adopted: keep the pure-Dart path as the fallback (`cryptography` already does
this), and verify wire compatibility against the Python reference before shipping.

### 6.2 Should a phone be a relay indexer at all?

We answer strangers' relay queries, mostly with **zero events**, and pay a full
link handshake for each. On a phone that is a battery cost with no user benefit.
Options: don't advertise indexer capacity on mobile; rate-limit inbound links;
or answer cheaply (reject before the handshake) when we hold no matching data.
This is a **product decision** about what a phone node owes the network.

### 6.3 Cheap wins not yet taken

- **Pause UI-only timers when the app is not visible.** The connection indicator
  polls `setState` every 2s and the carousel auto-advances every 6s regardless of
  visibility. Harmless while the screen is off (Flutter stops rendering), but it
  is pointless work and trivially lifecycle-gated.
- **`nostr-engine` pushes a relays snapshot every 400ms tick** whether or not it
  changed. Send on change.
- **`RnsService` still owns the LXMF / files / relay / DHT subsystems and ~10
  sqlite stores on main.** After the transport migration the main isolate idles,
  so there is *no measured reason* to move them — recorded here so nobody
  "optimises" it on instinct. Revisit only if a measurement says so.

### 6.4 Explicitly NOT worth doing (measured)

- **Moving background wapp WASM engines to a worker isolate.** The background
  chat wapp's tick costs **0.2–0.3% of main**. Doing this means routing ~114
  main-isolate singleton touchpoints through port bridges *inside the messaging
  path* — a real risk of dropped messages — to reclaim a third of a percent. The
  WASM runtime (`wasm_run`/wasmtime) is synchronous and runs on the calling
  isolate, and the HAL is soaked in `RnsService.instance` (61 references),
  `ProfileService`, `BleService`. Several HAL calls are *synchronously* answered
  from main state (`hal_rns_available`, `nostr_subscribe`, `event_recv`) and have
  no cheap port equivalent. **Don't revive this without new data.**

---

## 7. Current numbers (C61, release-grade AOT, busy public hub + BLE peer)

| | frozen (before) | now |
|---|---|---|
| main-isolate stalls | wedged solid | **0** |
| main thread CPU | ~100% pegged | ~0–7% |
| screen-off process CPU | — | **8% of one core** |
| RES | 890MB, climbing | ~250–300MB, flat |
| `/api/log` during load | dead | alive |

Regressions to watch for, in one command:

```sh
curl -s http://127.0.0.1:3456/api/log?n=800 | grep -aoE 'perf: [^"]*' | tail -20
```

If `main isolate stalled` reappears, or `crypto-worker` shows a paired
`xGen`/`edGen` count again, or `nostr-engine profileLookups` climbs — something
regressed to a pattern documented above.
