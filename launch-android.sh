#!/usr/bin/env bash
# =============================================================================
# launch-android.sh — build the Aurora Flutter app and run it on every
# Android device currently connected over ADB (handles several at once).
#
# Builds a small, per-ABI APK (release by default — release is signed with the
# debug key here, so it installs) and installs the split matching each device.
#
# Usage:
#   ./launch-android.sh            # release, split-per-abi (smallest)
#   ./launch-android.sh --debug    # debug build (larger, hot-reload friendly)
#   ./launch-android.sh -- <extra flutter build args...>
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- locate tools ------------------------------------------------------------
if command -v flutter >/dev/null 2>&1; then FLUTTER=flutter
elif [ -x "$HOME/flutter/bin/flutter" ]; then FLUTTER="$HOME/flutter/bin/flutter"
else echo "error: flutter not found (PATH or ~/flutter/bin)"; exit 1; fi

if command -v adb >/dev/null 2>&1; then ADB=adb
elif [ -x "$HOME/Android/Sdk/platform-tools/adb" ]; then ADB="$HOME/Android/Sdk/platform-tools/adb"
elif [ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]; then ADB="$HOME/Library/Android/sdk/platform-tools/adb"
else echo "error: adb not found (PATH or Android SDK platform-tools)"; exit 1; fi

# --- args --------------------------------------------------------------------
BUILD_TYPE=release
EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) BUILD_TYPE=release; shift ;;
    --debug)   BUILD_TYPE=debug;   shift ;;
    --) shift; EXTRA+=("$@"); break ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done

# --- app package id (for launching) -----------------------------------------
PKG="$(grep -oE 'applicationId[[:space:]]*=[[:space:]]*"[^"]+"' \
        android/app/build.gradle.kts 2>/dev/null | grep -oE '"[^"]+"' | tr -d '"' | head -1)"
PKG="${PKG:-com.geogram.aurora}"

# --- connected devices (state == "device") ----------------------------------
mapfile -t DEVICES < <("$ADB" devices | awk 'NR>1 && $2=="device" {print $1}')
if [ "${#DEVICES[@]}" -eq 0 ]; then
  echo "error: no Android devices connected (check 'adb devices' / USB debugging)"
  exit 1
fi
echo ">> ${#DEVICES[@]} device(s): ${DEVICES[*]}"
echo ">> package: $PKG   build: $BUILD_TYPE"

# --- build per-ABI APKs once -------------------------------------------------
echo ">> building APK ($BUILD_TYPE, split-per-abi)..."
"$FLUTTER" build apk --"$BUILD_TYPE" --split-per-abi "${EXTRA[@]}"

APK_DIR="build/app/outputs/flutter-apk"
echo ">> built:"; ls -1sh "$APK_DIR"/app-*-"$BUILD_TYPE".apk 2>/dev/null || true

# Map an Android ABI to its split APK (falls back to a universal APK if the
# split for that ABI wasn't produced).
apk_for_abi() {
  local abi="$1" a="$APK_DIR/app-$1-$BUILD_TYPE.apk"
  [ -f "$a" ] && { echo "$a"; return; }
  echo "$APK_DIR/app-$BUILD_TYPE.apk"   # universal fallback
}

# --- install + launch on each device (in parallel) ---------------------------
deploy() {
  local serial="$1"
  local p="[$serial]"
  local abi apk
  abi="$("$ADB" -s "$serial" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
  apk="$(apk_for_abi "$abi")"
  if [ ! -f "$apk" ]; then echo "$p no APK for ABI '$abi'"; return 1; fi
  echo "$p abi=$abi installing $(basename "$apk")..."
  if ! "$ADB" -s "$serial" install -r -d "$apk" >/dev/null 2>&1; then
    # -d (downgrade) can be rejected on some devices; retry without it
    "$ADB" -s "$serial" install -r "$apk" >/dev/null 2>&1 || {
      echo "$p INSTALL FAILED"; return 1; }
  fi
  echo "$p launching $PKG"
  "$ADB" -s "$serial" shell monkey -p "$PKG" \
        -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || {
    echo "$p LAUNCH FAILED"; return 1; }
  echo "$p OK"
}

rc=0
pids=()
for d in "${DEVICES[@]}"; do deploy "$d" & pids+=($!); done
for pid in "${pids[@]}"; do wait "$pid" || rc=1; done

[ "$rc" -eq 0 ] && echo ">> done." || echo ">> finished with errors."
exit "$rc"
