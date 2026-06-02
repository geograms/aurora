#!/bin/sh
# Aurora — Linux build + launch
#
# Compiles the Flutter Linux desktop bundle and launches the resulting
# binary. The binary is run with the project root as its working
# directory so the launcher's wapp scan (`$cwd/../wapps`) resolves to
# the sibling /home/brito/code/geogram/wapps/ folder.
#
# Usage:
#   ./launch-linux.sh            # debug build, then launch
#   ./launch-linux.sh release    # release build, then launch
#   ./launch-linux.sh --build    # build only, don't launch
#
# For an iterative dev loop with hot reload use launch-desktop.sh
# (flutter run -d linux) instead.

set -e

FLUTTER_BIN="${FLUTTER_BIN:-$HOME/flutter/bin/flutter}"
if [ ! -x "$FLUTTER_BIN" ]; then
    echo "Error: flutter not found at $FLUTTER_BIN"
    echo "Set FLUTTER_BIN or install Flutter first."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ── Parse args ───────────────────────────────────────────────────────
MODE="debug"
BUILD_ONLY=0
for arg in "$@"; do
    case "$arg" in
        release|--release) MODE="release" ;;
        debug|--debug)     MODE="debug" ;;
        --build|--build-only) BUILD_ONLY=1 ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# ── Build ────────────────────────────────────────────────────────────
echo "Building Flutter Linux bundle ($MODE)..."
"$FLUTTER_BIN" build linux "--$MODE"

# ── Locate the compiled binary ───────────────────────────────────────
# Architecture dir (x64/arm64) is chosen by Flutter; glob for whichever
# one this build produced.
BINARY=""
for cand in "$SCRIPT_DIR"/build/linux/*/"$MODE"/bundle/aurora; do
    [ -x "$cand" ] && BINARY="$cand" && break
done

if [ -z "$BINARY" ]; then
    echo "Error: could not find the compiled 'aurora' binary under"
    echo "       build/linux/*/$MODE/bundle/"
    exit 1
fi

echo "Built: $BINARY"

if [ "$BUILD_ONLY" -eq 1 ]; then
    exit 0
fi

# ── Launch ───────────────────────────────────────────────────────────
# Run from the project root so the wapp scan finds ../wapps.
echo "Launching aurora..."
exec "$BINARY"
