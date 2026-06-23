---
name: c61-budget-phone-release-only
description: OUKITEL C61 test phone ANRs/OOMs on debug Flutter builds; install release on it
metadata:
  type: project
---

The OUKITEL **C61** (adb serial `C61000000004616`, ~3.8GB RAM, profile callsign
X1RTP2) cannot run a **debug** Flutter build of Aurora: at startup the main
isolate saturates the CPU (JIT + wasm/RNS init) and Android raises an
"Application Not Responding" / out-of-memory — observed live 2026-06-21. The fast
**TANK2** (serial `TANK200000007933`, callsign X16WMN) handles debug fine.

**Why:** debug Flutter is 5–10× heavier (JIT, no tree-shake, asserts) than the
AOT release build; the budget C61 can't keep up during the heavy startup burst.

**How to apply:** install the **release** APK on C61
(`flutter build apk --release --split-per-abi --target-platform android-arm64`
then `adb -s C61000000004616 install -r app-arm64-v8a-release.apk`). Release is
signed with the debug key so it installs, but is NOT debuggable — `run-as` (DB
inspection) won't work on it; do DB-level verification on TANK2 (debug) instead.
Drive both phones headlessly via the in-app remote API over `adb forward`. See
[[circles-wapp]].
