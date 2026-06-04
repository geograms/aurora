#!/bin/bash
# Monitor serial output from ESP32 devices
# Usage: ./monitor.sh [port] [baud]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Default port (auto-detect if not specified)
PORT="$1"
BAUD="${2:-115200}"

# Auto-detect port if not specified
if [ -z "$PORT" ]; then
    # Try to find any ttyACM device (ESP32-S3 built-in USB)
    PORT=$(ls /dev/ttyACM* 2>/dev/null | head -1)

    # Fall back to ttyUSB if no ttyACM found
    if [ -z "$PORT" ]; then
        PORT=$(ls /dev/ttyUSB* 2>/dev/null | head -1)
    fi

    if [ -z "$PORT" ]; then
        echo "Error: No serial port found. Please specify port as argument."
        echo "Usage: $0 [port] [baud]"
        exit 1
    fi
fi

echo "=== Geogram Serial Monitor ==="
echo "Port: $PORT"
echo "Baud: $BAUD"
echo "Press Ctrl+C to exit"
echo ""

~/.platformio/penv/bin/pio device monitor -p "$PORT" -b "$BAUD"
