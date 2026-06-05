#!/usr/bin/env bash
# =============================================================================
# allow-btmon.sh — let `btmon` (the BlueZ HCI monitor) run without sudo.
#
# btmon needs CAP_NET_RAW + CAP_NET_ADMIN to bind the HCI monitor channel.
# This grants those file capabilities to the btmon binary, one time. After
# running it, `btmon` works as your normal user (useful for capturing BLE
# advertising at the HCI level when debugging).
#
# Usage:   sudo ./allow-btmon.sh
# Revert:  sudo ./allow-btmon.sh --revert
# =============================================================================
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo:  sudo $0 ${*:-}"; exit 1
fi

BTMON="$(command -v btmon || echo /usr/bin/btmon)"
if [ ! -x "$BTMON" ]; then
  echo "btmon not found — install it with:  sudo apt-get install bluez"; exit 1
fi

if [ "${1:-}" = "--revert" ]; then
  setcap -r "$BTMON" 2>/dev/null || true
  echo "Removed capabilities from $BTMON"
  getcap "$BTMON" || echo "(no capabilities set — btmon now needs sudo again)"
  exit 0
fi

setcap 'cap_net_raw,cap_net_admin+eip' "$BTMON"
echo "Granted cap_net_raw,cap_net_admin to $BTMON:"
getcap "$BTMON"
echo
echo "btmon can now run without sudo. To capture BLE adverts:"
echo "  btmon            # in one terminal (or:  btmon -w capture.snoop)"
echo "  bluetoothctl scan on   # in another, so the controller reports adverts"
echo "Revert with:  sudo $0 --revert"
