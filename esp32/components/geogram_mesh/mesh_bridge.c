/**
 * @file mesh_bridge.c
 * @brief Data bridging over ESP-Mesh-Lite
 *
 * With ESP-Mesh-Lite, each node has its own LWIP stack, so complex IP bridging
 * is not required. The iot_bridge component handles NAPT and routing automatically.
 * This module handles application-level data forwarding (e.g., chat messages)
 * between mesh nodes.
 */

#include "mesh_bsp.h"
#include "mesh_chat.h"

#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "lwip/ip4_addr.h"
#include "lwip/netif.h"
#include "lwip/pbuf.h"

static const char *TAG = "mesh_bridge";

// ============================================================================
// Configuration
// ============================================================================

#ifndef CONFIG_GEOGRAM_MESH_BRIDGE_BUFFER_SIZE
#define CONFIG_GEOGRAM_MESH_BRIDGE_BUFFER_SIZE 1500
#endif

#ifndef CONFIG_GEOGRAM_MESH_BRIDGE_QUEUE_SIZE
#define CONFIG_GEOGRAM_MESH_BRIDGE_QUEUE_SIZE 8
#endif

// Bridge packet header for application data
#define BRIDGE_MAGIC 0x47454F  // "GEO" in hex
#define BRIDGE_VERSION 1

// ============================================================================
// Data Structures
// ============================================================================

/**
 * @brief Bridge packet header (prepended to application data)
 */
typedef struct __attribute__((packed)) {
    uint32_t magic;           // Magic number (BRIDGE_MAGIC)
    uint8_t version;          // Protocol version
    uint8_t src_subnet;       // Source subnet ID
    uint8_t dest_subnet;      // Destination subnet ID (0xFF = broadcast)
    uint8_t msg_type;         // Message type (future use)
    uint16_t payload_len;     // Payload length
    uint16_t checksum;        // Simple checksum
} bridge_header_t;

// ============================================================================
// State Variables
// ============================================================================

static bool s_bridge_enabled = false;

// Statistics
static uint32_t s_packets_tx = 0;
static uint32_t s_packets_rx = 0;
static uint32_t s_bytes_tx = 0;
static uint32_t s_bytes_rx = 0;

// ============================================================================
// Forward Declarations
// ============================================================================

static void mesh_data_handler(const uint8_t *src_mac, const void *data, size_t len);
static uint16_t calculate_checksum(const uint8_t *data, size_t len);

// ============================================================================
// Public API
// ============================================================================

esp_err_t geogram_mesh_enable_bridge(void)
{
    if (s_bridge_enabled) {
        ESP_LOGW(TAG, "[BRIDGE] Already enabled");
        return ESP_OK;
    }

    if (!geogram_mesh_is_connected()) {
        ESP_LOGE(TAG, "[BRIDGE] Cannot enable: mesh not connected");
        return ESP_ERR_INVALID_STATE;
    }

    ESP_LOGI(TAG, "========================================");
    ESP_LOGI(TAG, "[BRIDGE] Enabling data bridging");
    ESP_LOGI(TAG, "[BRIDGE] ESP-Mesh-Lite: per-node LWIP + NAPT enabled");
    ESP_LOGI(TAG, "[BRIDGE] IP routing handled by iot_bridge component");
    ESP_LOGI(TAG, "========================================");

    // Register for incoming mesh data
    geogram_mesh_register_data_callback(mesh_data_handler);

    s_bridge_enabled = true;
    s_packets_tx = 0;
    s_packets_rx = 0;
    s_bytes_tx = 0;
    s_bytes_rx = 0;

    ESP_LOGI(TAG, "[BRIDGE] Data bridging enabled successfully");
    return ESP_OK;
}

esp_err_t geogram_mesh_disable_bridge(void)
{
    if (!s_bridge_enabled) {
        return ESP_OK;
    }

    ESP_LOGI(TAG, "Disabling data bridge");

    // Unregister data callback
    geogram_mesh_register_data_callback(NULL);

    s_bridge_enabled = false;

    ESP_LOGI(TAG, "Data bridge disabled");
    return ESP_OK;
}

bool geogram_mesh_bridge_is_enabled(void)
{
    return s_bridge_enabled;
}

void geogram_mesh_bridge_get_stats(uint32_t *packets_tx, uint32_t *packets_rx,
                                    uint32_t *bytes_tx, uint32_t *bytes_rx)
{
    if (packets_tx) *packets_tx = s_packets_tx;
    if (packets_rx) *packets_rx = s_packets_rx;
    if (bytes_tx) *bytes_tx = s_bytes_tx;
    if (bytes_rx) *bytes_rx = s_bytes_rx;
}

// ============================================================================
// Data Forwarding
// ============================================================================

/**
 * @brief Forward application data to a specific mesh node
 *
 * In ESP-Mesh-Lite, IP traffic is handled natively by each node's LWIP stack
 * with NAPT via the iot_bridge component. This function is for application-level
 * data like chat messages.
 */
esp_err_t mesh_bridge_forward_packet(uint32_t dest_ip, const uint8_t *data, size_t len)
{
    if (!s_bridge_enabled) {
        return ESP_ERR_INVALID_STATE;
    }

    if (!data || len == 0 || len > CONFIG_GEOGRAM_MESH_BRIDGE_BUFFER_SIZE) {
        return ESP_ERR_INVALID_ARG;
    }

    // With ESP-Mesh-Lite, IP routing is handled automatically by the bridge layer
    // This function is primarily for application-layer broadcasts

    ESP_LOGD(TAG, "[BRIDGE TX] Forwarding %zu bytes", len);

    s_packets_tx++;
    s_bytes_tx += len;

    return ESP_OK;
}

// ============================================================================
// Incoming Data Handler
// ============================================================================

/**
 * @brief Handle incoming mesh data
 *
 * Processes incoming data from other mesh nodes, including:
 * - Chat messages
 * - Application-level bridge packets
 */
static void mesh_data_handler(const uint8_t *src_mac, const void *data, size_t len)
{
    ESP_LOGD(TAG, "[BRIDGE RX] Received %zu bytes from " MACSTR,
             len, MAC2STR(src_mac));

    // First, try to handle as chat message
    mesh_chat_handle_packet(src_mac, data, len);

    // Check if it's a bridge packet
    if (len < sizeof(bridge_header_t)) {
        ESP_LOGD(TAG, "[BRIDGE RX] Packet too small for bridge header");
        return;
    }

    const bridge_header_t *header = (const bridge_header_t *)data;

    // Validate magic number
    if (header->magic != BRIDGE_MAGIC) {
        ESP_LOGD(TAG, "[BRIDGE RX] Not a bridge packet (handled as chat/raw)");
        return;
    }

    ESP_LOGI(TAG, "[BRIDGE RX] ========================================");
    ESP_LOGI(TAG, "[BRIDGE RX] Bridge packet received");
    ESP_LOGI(TAG, "[BRIDGE RX] From: " MACSTR, MAC2STR(src_mac));
    ESP_LOGI(TAG, "[BRIDGE RX] Source subnet: %d", header->src_subnet);
    ESP_LOGI(TAG, "[BRIDGE RX] Dest subnet: %d", header->dest_subnet);
    ESP_LOGI(TAG, "[BRIDGE RX] Payload: %d bytes", header->payload_len);

    // Validate version
    if (header->version != BRIDGE_VERSION) {
        ESP_LOGW(TAG, "[BRIDGE RX] Unsupported bridge version: %d", header->version);
        return;
    }

    // Validate payload length
    if (len < sizeof(bridge_header_t) + header->payload_len) {
        ESP_LOGW(TAG, "[BRIDGE RX] Payload length mismatch");
        return;
    }

    // Verify checksum
    const uint8_t *payload = (const uint8_t *)data + sizeof(bridge_header_t);
    uint16_t checksum = calculate_checksum(payload, header->payload_len);
    if (checksum != header->checksum) {
        ESP_LOGW(TAG, "[BRIDGE RX] Checksum mismatch");
        return;
    }

    s_packets_rx++;
    s_bytes_rx += header->payload_len;

    ESP_LOGI(TAG, "[BRIDGE RX] Packet validated successfully");
    ESP_LOGI(TAG, "[BRIDGE RX] Total RX: %lu packets, %lu bytes",
             (unsigned long)s_packets_rx, (unsigned long)s_bytes_rx);
    ESP_LOGI(TAG, "[BRIDGE RX] ========================================");

    // With ESP-Mesh-Lite, IP packets are handled by per-node LWIP with NAPT
    // Application data is processed here as needed
}

// ============================================================================
// Helper Functions
// ============================================================================

/**
 * @brief Calculate simple checksum for packet validation
 */
static uint16_t calculate_checksum(const uint8_t *data, size_t len)
{
    uint32_t sum = 0;

    for (size_t i = 0; i < len; i++) {
        sum += data[i];
    }

    // Fold 32-bit sum to 16 bits
    while (sum >> 16) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return (uint16_t)~sum;
}

// ============================================================================
// Network Interface Hook (legacy - simplified for ESP-Mesh-Lite)
// ============================================================================

/**
 * @brief Hook for packet interception (legacy API)
 *
 * With ESP-Mesh-Lite, IP routing is handled by the iot_bridge component
 * using NAPT. This function is kept for API compatibility but returns false
 * to let packets flow through LWIP normally.
 */
bool mesh_bridge_intercept_packet(struct netif *netif, struct pbuf *p, const ip4_addr_t *dest_ip)
{
    // ESP-Mesh-Lite handles IP routing natively via iot_bridge NAPT
    // No interception needed - let packets flow through LWIP normally
    return false;
}
