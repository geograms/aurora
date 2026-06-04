#!/bin/bash
# Flash firmware to ESP32-C3 (PlatformIO)
# Usage: ./flash-c3.sh

set -e


ENV="esp32c3_mini"

echo "=== Geogram ESP32-C3 Flash ==="
~/.platformio/penv/bin/pio run -e "$ENV" -t upload
