# Geogram ESP32 Development Context

This document captures important implementation details and constraints for AI assistants working on this codebase.

## Project Overview

Geogram is an **offline-first mesh communication system** for ESP32 devices. Key features:
- **ESP-Mesh-Lite** for router-less mesh networking
- **Nostr protocol** for cryptographic identity and message signing
- **Web UI** served via captive portal for phone/laptop access
- **Serial console** for debugging and configuration

### Hardware

Primary development board: **ESP32-C3-mini**
- RISC-V single-core @ 160MHz
- 400KB SRAM, 4MB Flash
- Built-in USB-CDC (no external UART chip)
- WS2812 RGB LED on GPIO8

Two test devices typically connected:
- Node 0: MAC `48:f6:ee:e2:d5:18` (STA) / `48:f6:ee:e2:d5:19` (AP)
- Node 1: MAC `48:f6:ee:e2:dc:d0` (STA) / `48:f6:ee:e2:dc:d1` (AP)

### Project Structure

```
code/
├── src/                    # Main application (main.cpp)
├── components/
│   ├── geogram_mesh/       # Mesh networking (mesh_bsp.c)
│   ├── geogram_console/    # Serial console commands
│   ├── geogram_http/       # HTTP server and WebSocket
│   ├── geogram_nostr/      # Nostr keys and signing
│   └── ...
├── boards/                 # Board-specific sdkconfig files
├── managed_components/     # ESP-IDF components (esp-mesh-lite, iot-bridge)
├── docs/                   # Documentation
├── monitor-capture.sh      # Safe serial monitoring script
└── platformio.ini          # Build configuration
```

## Serial Console Monitoring

**IMPORTANT:** Never use `pio device monitor` or `./monitor.sh` directly - these stream indefinitely and will cause timeouts or memory exhaustion.

### Safe Monitoring with `monitor-capture.sh`

Use the bounded capture script for all serial monitoring:

```bash
# Basic usage (10 seconds, max 1000 lines)
./monitor-capture.sh

# Time-limited capture
./monitor-capture.sh -t 5              # 5 seconds

# Line-limited capture
./monitor-capture.sh -n 100            # Max 100 lines

# Combined limits
./monitor-capture.sh -t 30 -n 500      # 30s or 500 lines, whichever first

# Reset device and capture boot logs
./monitor-capture.sh -r -t 15          # Reset, then capture 15s

# Specify port explicitly
./monitor-capture.sh /dev/ttyACM0
./monitor-capture.sh -r -t 10 /dev/ttyACM1
```

### Multiple Devices

When two ESP32 devices are connected:
- `/dev/ttyACM0` - First device
- `/dev/ttyACM1` - Second device

Capture from both in parallel:
```bash
./monitor-capture.sh -r -t 20 /dev/ttyACM0 &
./monitor-capture.sh -r -t 20 /dev/ttyACM1 &
wait
```

## ESP-Mesh-Lite Configuration

### SSID Requirement: Must Be "geogram"

**All mesh nodes MUST broadcast the same SSID "geogram"** for phone auto-connect functionality.

Why this matters:
- Users expect to connect to "geogram" network automatically
- Phones remember the network and reconnect when in range
- Different SSIDs per node would require manual connection each time

### How Mesh Discovery Works

Despite all nodes having the same SSID, mesh peers find each other through:

1. **Vendor Information Elements (IEs)** - Embedded in WiFi beacon frames
2. **BSSID targeting** - Nodes connect to specific MAC addresses, not SSIDs
3. **Mesh ID matching** - Configured as `0x67` ('g') in `CONFIG_MESH_LITE_ID`

The `mesh_get_ssid_by_mac()` callback tells mesh-lite to use "geogram" for all peer connections.

### Root Election

ESP-Mesh-Lite requires explicit root designation (no automatic election in router-less mesh).

Current implementation uses MAC-based deterministic election:
- **Lower MAC ID** → ROOT (level 1)
- **Higher MAC ID** → CHILD (level 2+)

Threshold defined in `mesh_bsp.c`:
```c
const uint32_t root_threshold = 0xe2d800;
bool should_be_root = (my_id < root_threshold);
```

This ensures exactly one root node in any mesh topology.

### Key Configuration Files

| File | Purpose |
|------|---------|
| `sdkconfig.defaults` | Base mesh configuration |
| `boards/sdkconfig.esp32c3_mini` | Board-specific overrides |
| `components/geogram_mesh/mesh_bsp.c` | Mesh initialization and event handling |

### Important Config Options

```
CONFIG_BRIDGE_SOFTAP_SSID="geogram"           # Common SSID for all nodes
CONFIG_MESH_LITE_ID=103                        # Mesh network ID (0x67 = 'g')
CONFIG_JOIN_MESH_WITHOUT_CONFIGURED_WIFI=y    # Join mesh without router
CONFIG_JOIN_MESH_IGNORE_ROUTER_STATUS=y       # Operate without internet
```

**Do NOT enable** `CONFIG_BRIDGE_SOFTAP_SSID_END_WITH_THE_MAC` - this breaks phone auto-connect.

## Building and Flashing

```bash
# Build
pio run -e esp32c3_mini

# Flash specific device
pio run -e esp32c3_mini -t upload --upload-port /dev/ttyACM0
pio run -e esp32c3_mini -t upload --upload-port /dev/ttyACM1

# Clean build (when changing sdkconfig)
rm -f sdkconfig.esp32c3_mini && pio run -e esp32c3_mini
```

## Testing Mesh Connectivity

1. Flash both devices
2. Reset and capture logs:
   ```bash
   ./monitor-capture.sh -r -t 25 -n 300 /dev/ttyACM0
   ./monitor-capture.sh -r -t 25 -n 300 /dev/ttyACM1
   ```
3. Verify in logs:
   - Root node: `[EVENT] Level: 1, Is Root: YES`
   - Child node: `wifi:connected with geogram` + `[STA] Got IP: 192.168.5.2`
4. Verify SSIDs from host:
   ```bash
   nmcli dev wifi list | grep geogram
   ```
   Both should show SSID "geogram" (no MAC suffix).

## Nostr Integration

Each device has a unique Nostr keypair stored in NVS:
- **npub** - Public key (used for identity)
- **nsec** - Private key (used for signing)
- **Callsign** - Derived from npub, format: `X3XXXX` (e.g., `X3KEXD`)

Keys are generated on first boot if not present. The callsign is displayed in the web UI and used to identify message authors.

## Web Interface

The device serves a captive portal web UI:
- **HTTP server** on port 80
- **WebSocket** at `/ws` for real-time chat
- **REST API** for chat messages, file transfers, station info

Key endpoints:
- `GET /` - Main web UI (chat interface)
- `GET /api/station` - Device info (callsign, mesh status)
- `GET /api/messages` - Chat history
- `POST /api/messages` - Send message
- `WS /ws` - Real-time message updates

## Serial Console Commands

Available via USB serial (115200 baud):

```
help              - List all commands
mesh status       - Show mesh connection status
mesh info         - Show detailed mesh info
mesh chat <msg>   - Send chat message
wifi scan         - Scan for WiFi networks
wifi status       - Show WiFi status
config show       - Show current configuration
reboot            - Restart device
```

## Known Constraints

### ESP-Mesh-Lite Limitations

1. **No automatic root election** - Must use MAC-based or explicit configuration
2. **Vendor IE errors (4354)** - Normal at startup, indicates NVS not populated yet
3. **RTC store** - Mesh-lite caches parent info in RTC memory for fast reconnection

### Driver Coexistence Warnings

The firmware uses patched ESP-IDF drivers to allow legacy and new driver coexistence. Warnings like `GEOGRAM_PATCHED: legacy temp sensor driver...` are expected and harmless.

### Memory Considerations

- Free heap typically ~150KB after boot
- WebSocket connections consume ~2-3KB each
- Maximum 4 simultaneous SoftAP clients

## Debugging Tips

1. **Mesh not connecting?** Check:
   - Both nodes have same Mesh ID (0x67)
   - Root election is working (one ROOT, one CHILD)
   - Both on same WiFi channel (default: 1)

2. **Web UI not loading?** Check:
   - Connected to "geogram" WiFi
   - HTTP server started (look for `HTTP server started` in logs)
   - Try `http://192.168.4.1` or `http://192.168.5.1`

3. **Messages not syncing?** Check:
   - Mesh bridge enabled (`[BRIDGE] Data bridging enabled`)
   - Both nodes have IP connectivity
   - WebSocket connected on web client
