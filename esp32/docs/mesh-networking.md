# ESP32 Wi-Fi Mesh Networking

This document describes the ESP-MESH networking support for Geogram ESP32 devices. The mesh network enables multiple ESP32 boards to communicate with each other while each providing a SoftAP for phone connections.

## Overview

ESP-MESH creates a self-organizing wireless network where:
- ESP32 boards automatically discover and connect to each other
- Each board runs a SoftAP that phones can connect to
- Full IP traffic from phones on one node can reach phones on other nodes
- Works offline without external internet

## Architecture

```
Phone A (192.168.10.x)           Phone B (192.168.11.x)
        |                                |
        v                                v
  Node1 SoftAP                     Node2 SoftAP
  (192.168.10.1)                  (192.168.11.1)
        |                                |
        +-------- ESP-MESH Network ------+
                 (Self-organized)
```

### Key Design Decisions

- **Local mesh only** - No external router or internet required
- **Full IP bridging** - NAT-like forwarding between nodes
- **ESP32-C3 supported** - With reduced limits (2 phones, 3 layers)
- **Unique subnets** - Each node gets `192.168.{10+node_id}.0/24`

### Network Topology

The mesh uses ESP-MESH's self-organized tree topology:
- One node automatically becomes the root (can be fixed)
- Other nodes connect as children forming a tree structure
- Maximum 6 layers deep (3 on ESP32-C3)

## API Reference

### Initialization

```c
#include "mesh_bsp.h"

// Initialize mesh subsystem (call once at startup)
esp_err_t geogram_mesh_init(void);

// Clean up mesh resources
esp_err_t geogram_mesh_deinit(void);
```

### Starting/Stopping Mesh

```c
// Configuration structure
typedef struct {
    char mesh_id[6];           // 6-byte mesh network ID
    char password[64];         // Mesh network password
    uint8_t channel;           // WiFi channel (1-13)
    uint8_t max_layer;         // Maximum tree depth
    bool allow_root;           // Can this node become root?
    geogram_mesh_event_cb_t callback;  // Event callback
} geogram_mesh_config_t;

// Start mesh network
esp_err_t geogram_mesh_start(const geogram_mesh_config_t *config);

// Stop mesh network
esp_err_t geogram_mesh_stop(void);
```

### Status Queries

```c
// Get current mesh status
typedef enum {
    GEOGRAM_MESH_STATUS_STOPPED = 0,
    GEOGRAM_MESH_STATUS_STARTED,
    GEOGRAM_MESH_STATUS_CONNECTED,
    GEOGRAM_MESH_STATUS_DISCONNECTED,
    GEOGRAM_MESH_STATUS_ROOT,
    GEOGRAM_MESH_STATUS_ERROR
} geogram_mesh_status_t;

geogram_mesh_status_t geogram_mesh_get_status(void);

// Check if this node is the root
bool geogram_mesh_is_root(void);

// Get current layer in mesh tree (1 = root, 2 = child of root, etc.)
uint8_t geogram_mesh_get_layer(void);

// Check if mesh is connected
bool geogram_mesh_is_connected(void);
```

### External SoftAP (for phones)

```c
// Start SoftAP for phone connections
esp_err_t geogram_mesh_start_external_ap(
    const char *ssid,
    const char *password,
    uint8_t max_connections
);

// Stop external SoftAP
esp_err_t geogram_mesh_stop_external_ap(void);

// Get external AP IP address
esp_err_t geogram_mesh_get_external_ap_ip(char *ip_str, size_t len);
```

### IP Bridging

```c
// Enable IP packet forwarding between mesh nodes
esp_err_t geogram_mesh_enable_bridge(void);

// Disable IP bridging
esp_err_t geogram_mesh_disable_bridge(void);

// Check if bridging is active
bool geogram_mesh_bridge_is_enabled(void);
```

### Node Discovery

```c
// Node information structure
typedef struct {
    uint8_t mac[6];            // Node MAC address
    uint8_t layer;             // Layer in mesh tree
    uint8_t subnet_id;         // Assigned subnet (10 + subnet_id)
    int8_t rssi;               // Signal strength
    bool is_root;              // True if this is the root node
} geogram_mesh_node_t;

// Get list of known mesh nodes
esp_err_t geogram_mesh_get_nodes(
    geogram_mesh_node_t *nodes,
    size_t max_nodes,
    size_t *node_count
);

// Get this node's subnet ID
uint8_t geogram_mesh_get_subnet_id(void);
```

### Configuration Persistence

```c
// Save mesh config to NVS
esp_err_t geogram_mesh_save_config(void);

// Load mesh config from NVS
esp_err_t geogram_mesh_load_config(geogram_mesh_config_t *config);
```

### Event Callback

```c
// Event types passed to callback
typedef enum {
    GEOGRAM_MESH_EVENT_STARTED,
    GEOGRAM_MESH_EVENT_STOPPED,
    GEOGRAM_MESH_EVENT_CONNECTED,
    GEOGRAM_MESH_EVENT_DISCONNECTED,
    GEOGRAM_MESH_EVENT_ROOT_CHANGED,
    GEOGRAM_MESH_EVENT_CHILD_CONNECTED,
    GEOGRAM_MESH_EVENT_CHILD_DISCONNECTED,
    GEOGRAM_MESH_EVENT_ROUTE_TABLE_CHANGE,
    GEOGRAM_MESH_EVENT_EXTERNAL_STA_CONNECTED,
    GEOGRAM_MESH_EVENT_EXTERNAL_STA_DISCONNECTED
} geogram_mesh_event_t;

// Event callback signature
typedef void (*geogram_mesh_event_cb_t)(
    geogram_mesh_event_t event,
    void *event_data
);
```

## Usage Example

```c
#include "mesh_bsp.h"

static void mesh_event_handler(geogram_mesh_event_t event, void *data)
{
    switch (event) {
        case GEOGRAM_MESH_EVENT_CONNECTED:
            ESP_LOGI(TAG, "Mesh connected, layer: %d", geogram_mesh_get_layer());

            // Start external AP for phone connections
            geogram_mesh_start_external_ap("geogram-X3ABCD", "", 4);

            // Enable IP bridging
            geogram_mesh_enable_bridge();
            break;

        case GEOGRAM_MESH_EVENT_ROOT_CHANGED:
            ESP_LOGI(TAG, "I am now %s", geogram_mesh_is_root() ? "ROOT" : "CHILD");
            break;

        case GEOGRAM_MESH_EVENT_EXTERNAL_STA_CONNECTED:
            ESP_LOGI(TAG, "Phone connected to my AP");
            break;

        default:
            break;
    }
}

void app_main(void)
{
    // Initialize mesh subsystem
    geogram_mesh_init();

    // Configure mesh network
    geogram_mesh_config_t config = {
        .mesh_id = "geomsh",         // 6-byte mesh ID
        .password = "geogram-mesh",  // Mesh network password
        .channel = 1,
        .max_layer = 6,
        .allow_root = true,
        .callback = mesh_event_handler
    };

    // Start mesh
    geogram_mesh_start(&config);
}
```

## Configuration (Kconfig)

The mesh component provides Kconfig options:

```
CONFIG_GEOGRAM_MESH_ENABLED        - Enable/disable mesh support
CONFIG_GEOGRAM_MESH_CHANNEL        - Default WiFi channel (1-13)
CONFIG_GEOGRAM_MESH_MAX_LAYER      - Maximum mesh tree depth
CONFIG_GEOGRAM_MESH_EXTERNAL_AP_MAX_CONN - Max phones per node
```

### Board-Specific Limits (ESP32-C3)

Due to memory constraints, ESP32-C3 has reduced limits:
- `CONFIG_MESH_MAX_LAYER=3` (vs 6 on ESP32-S3)
- `CONFIG_MESH_ROUTE_TABLE_SIZE=20` (vs 50)
- `CONFIG_GEOGRAM_MESH_EXTERNAL_AP_MAX_CONN=2` (vs 4)

## IP Bridging Protocol

### Subnet Assignment

Each mesh node gets a unique subnet based on its MAC address:
```
Subnet = 192.168.{10 + (MAC[5] % 240)}.0/24
```

This ensures:
- Deterministic subnet assignment (same MAC = same subnet)
- No coordinator needed for subnet allocation
- Up to 240 unique subnets

### Bridge Packet Format

IP packets are encapsulated in mesh data frames:

```c
typedef struct {
    uint8_t dest_mac[6];      // Target mesh node MAC
    uint8_t src_subnet;       // Source subnet ID
    uint16_t payload_len;     // IP packet length
    uint8_t ip_packet[];      // Original IP packet (variable)
} mesh_bridge_packet_t;
```

### Routing

1. Source node captures IP packet from SoftAP interface
2. Extracts destination IP, determines target subnet
3. Looks up mesh node owning that subnet
4. Encapsulates and sends via mesh data channel
5. Destination node decapsulates and injects to local SoftAP

## Serial Console Commands

The mesh component provides console commands for testing and debugging:

### mesh
Show current mesh network status.
```
geogram> mesh

=== Mesh Network Status ===
Status:      Connected
Is Root:     no
Layer:       2
Subnet ID:   42 (192.168.52.0/24)
Node Count:  3
Parent:      AA:BB:CC:DD:EE:FF

--- External AP ---
Running:     yes
IP Address:  192.168.52.1
Clients:     1

--- IP Bridge ---
Enabled:     yes
Packets TX:  142
Packets RX:  89
Bytes TX:    12450
Bytes RX:    7820
```

### mesh_start
Start mesh networking.
```
geogram> mesh_start -c 6 -r
Channel: 6, Allow root: yes
Mesh started, scanning for network...
```
Options:
- `-c, --channel <1-13>`: WiFi channel (default: 1)
- `-r, --root`: Allow this node to become root

### mesh_stop
Stop mesh networking.
```
geogram> mesh_stop
Stopping mesh network...
Mesh stopped
```

### mesh_nodes
List all known mesh nodes.
```
geogram> mesh_nodes

=== Mesh Nodes (3) ===
MAC Address           Layer     Subnet      Root
-------------------   -----     ------      ----
AA:BB:CC:DD:EE:FF     1         192.168.10.x  YES
11:22:33:44:55:66     2         192.168.42.x
77:88:99:AA:BB:CC     2         192.168.15.x
```

### mesh_send
Send a test message to a specific mesh node.
```
geogram> mesh_send AA:BB:CC:DD:EE:FF "Hello from node 2!"
[SEND] To: AA:BB:CC:DD:EE:FF, Seq: 1, Message: "Hello from node 2!"
[SEND] SUCCESS
```

### mesh_broadcast
Broadcast a message to all mesh nodes.
```
geogram> mesh_broadcast "Hello everyone!"
[BROADCAST] Seq: 2, Message: "Hello everyone!"
[BROADCAST] Sent to AA:BB:CC:DD:EE:FF
[BROADCAST] Sent to 77:88:99:AA:BB:CC
[BROADCAST] Sent to 2/2 nodes
```

### mesh_ping
Ping a mesh node and measure round-trip time.
```
geogram> mesh_ping AA:BB:CC:DD:EE:FF
[PING] To: AA:BB:CC:DD:EE:FF, Seq: 3, Time: 123456 ms
[PING] Sent, waiting for PONG...

[MESH RX] From: AA:BB:CC:DD:EE:FF
[MESH RX] Seq: 3, Latency: 15 ms
[MESH RX] Type: PONG (RTT: 30 ms)
```

### mesh_bridge
Show IP bridge statistics.
```
geogram> mesh_bridge

=== IP Bridge Statistics ===
Status:      Enabled
Packets TX:  142
Packets RX:  89
Bytes TX:    12450
Bytes RX:    7820
```

### mesh_ap
Start or stop the external SoftAP for phone connections.
```
geogram> mesh_ap
Starting external AP...
  SSID: geogram-X3ABCD
  Password: geogram
External AP started at 192.168.52.1

geogram> mesh_ap --stop
Stopping external AP...
External AP stopped
```
Options:
- `-s, --stop`: Stop the external AP
- `[ssid]`: Custom SSID (default: geogram-{callsign})

### mesh_debug
Enable or disable verbose debug logging.
```
geogram> mesh_debug --on
Mesh debug logging ENABLED

geogram> mesh_debug --off
Mesh debug logging DISABLED
```

## External AP Configuration

When a node joins the mesh network, it automatically starts a SoftAP for phone connections:
- **SSID**: `geogram-{callsign}` (e.g., `geogram-X3ABCD`)
- **Password**: `geogram`
- **IP**: `192.168.{10+subnet_id}.1`

Phones connecting to this AP receive IPs via DHCP in the range `192.168.{10+subnet_id}.2-254`.

## HTTP API Endpoints

When mesh is enabled, the following endpoints are available:

### GET /api/mesh/status

Returns current mesh status:

```json
{
    "enabled": true,
    "connected": true,
    "is_root": false,
    "layer": 2,
    "node_count": 3,
    "subnet_id": 12,
    "ip": "192.168.12.1",
    "external_ap_ssid": "geogram-X3ABCD",
    "external_ap_clients": 1,
    "bridge_enabled": true,
    "packets_forwarded": 142
}
```

### GET /api/mesh/nodes

Returns list of known mesh nodes:

```json
{
    "nodes": [
        {
            "mac": "AA:BB:CC:DD:EE:FF",
            "layer": 1,
            "subnet_id": 10,
            "is_root": true,
            "rssi": -45
        },
        {
            "mac": "11:22:33:44:55:66",
            "layer": 2,
            "subnet_id": 12,
            "is_root": false,
            "rssi": -62
        }
    ],
    "total": 2
}
```

## Mesh Chat

The mesh network includes a built-in chat system that allows text messaging between all connected devices. Messages are broadcast to all mesh nodes and displayed to any phones connected to the network.

### Chat Features

- **Maximum message length**: 200 characters (fits in single mesh packet)
- **History size**: 20 messages stored locally per node
- **Callsign identification**: Uses NOSTR-derived callsign (X3XXXX format)
- **Web interface**: Phones see a chat UI when connecting to any node

### Chat Console Commands

#### chat
Send a chat message from the serial console.
```
geogram> chat Hello from Node 1!
[CHAT TX] Sending message #1: "Hello from Node 1!"
[CHAT TX] Broadcast to 2/2 nodes
```

#### chat_history
Display recent chat messages.
```
geogram> chat_history
=== Chat History (3 messages) ===
[1] 14:23:05 X3ABCD: Hello everyone!
[2] 14:23:12 X3DEFG: Hi there!
[3] 14:23:45 X3ABCD: How's the signal?
```

### Chat HTTP API

#### GET /api/chat/messages

Returns chat messages. Use `since` parameter for polling.

**Request:**
```
GET /api/chat/messages?since=0
```

**Response:**
```json
{
    "messages": [
        {
            "id": 1,
            "ts": 1705678985,
            "from": "X3ABCD",
            "text": "Hello everyone!",
            "local": true
        },
        {
            "id": 2,
            "ts": 1705678992,
            "from": "X3DEFG",
            "text": "Hi there!",
            "local": false
        }
    ],
    "latest_id": 2,
    "my_callsign": "X3ABCD",
    "max_len": 200
}
```

#### POST /api/chat/send

Send a chat message.

**Request:**
```
POST /api/chat/send
Content-Type: application/x-www-form-urlencoded

text=Hello%20world!
```

**Response:**
```json
{"ok": true}
```

### Web Chat Interface

When a phone connects to the mesh network and opens a browser:

1. Navigate to the node's IP (e.g., `http://192.168.12.1/`)
2. The chat interface loads automatically
3. Your node's callsign is displayed in the header
4. Messages from all mesh nodes appear in real-time
5. Type a message and tap Send to broadcast

The web interface:
- Polls for new messages every 2 seconds
- Displays your messages on the right (blue)
- Displays remote messages on the left (dark)
- Shows timestamps in local time format
- Works on any mobile browser

## Memory Budget

### ESP32-S3 (320KB SRAM + PSRAM)

| Component | RAM Usage |
|-----------|-----------|
| WiFi base | ~25KB |
| Mesh overhead | ~15KB |
| External AP | ~8KB |
| Bridge buffers | ~8KB |
| Route table (50) | ~4KB |
| **Total** | ~60KB |

### ESP32-C3 (400KB SRAM, no PSRAM)

| Component | RAM Usage |
|-----------|-----------|
| WiFi base | ~25KB |
| Mesh overhead | ~12KB |
| External AP | ~5KB |
| Bridge buffers | ~4KB |
| Route table (20) | ~2KB |
| **Total** | ~48KB |

## Testing

### Build Verification

```bash
cd code && ~/.platformio/penv/bin/pio run -e esp32c3_mini
```

### Hardware Test Setup (3 boards)

1. Flash all boards with mesh-enabled firmware
2. Power on all boards
3. Observe serial logs for mesh formation:

```
[mesh] Mesh initialized
[mesh] Starting self-organized mesh on channel 1
[mesh] Connected to mesh, layer: 2
[mesh] Parent: AA:BB:CC:DD:EE:FF (RSSI: -45)
[mesh] External AP started: geogram-X3ABCD (192.168.12.1)
```

4. Connect phones to different nodes' SoftAPs
5. Test connectivity:
   - Phone A pings Phone B: `ping 192.168.11.x`
   - HTTP requests across mesh

### Expected Serial Output

```
[mesh] Mesh initialized
[mesh] Starting self-organized mesh on channel 1
[mesh] Scanning for mesh network...
[mesh] Found mesh root, connecting...
[mesh] Connected to mesh, layer: 2
[mesh] External AP started: geogram-X3ABCD (192.168.12.1)
[mesh] Phone connected to external AP (1 total)
[bridge] Packet from 192.168.12.5 -> 192.168.11.3
[bridge] Forwarding to node AA:BB:CC:DD:EE:FF
```

## Troubleshooting

### Mesh Not Forming

- Verify all nodes use same `mesh_id` and `password`
- Check WiFi channel is identical
- Ensure no external WiFi on same channel causing interference

### IP Bridging Not Working

- Confirm `geogram_mesh_enable_bridge()` was called
- Check route table: `GET /api/mesh/nodes`
- Verify subnet IDs don't conflict

### Memory Issues on ESP32-C3

- Reduce `CONFIG_MESH_MAX_LAYER` to 3
- Reduce `CONFIG_MESH_ROUTE_TABLE_SIZE` to 20
- Limit external AP connections to 2

## Files Reference

| File | Description |
|------|-------------|
| `components/geogram_mesh/mesh_bsp.h` | Public API header |
| `components/geogram_mesh/mesh_bsp.c` | Core mesh implementation |
| `components/geogram_mesh/mesh_bridge.c` | IP bridging implementation |
| `components/geogram_mesh/mesh_chat.h` | Chat API header |
| `components/geogram_mesh/mesh_chat.c` | Chat protocol and message store |
| `components/geogram_mesh/Kconfig.projbuild` | Configuration options |
| `components/geogram_console/cmd_mesh.c` | Serial console commands |
| `code/src/main.cpp` | Mesh initialization code |
| `components/geogram_http/http_server.c` | Mesh and Chat API endpoints |
| `components/geogram_station/station.c` | Mesh status in station API |
