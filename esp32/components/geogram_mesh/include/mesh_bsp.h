/**
 * @file mesh_bsp.h
 * @brief Geogram ESP-MESH networking public API
 *
 * Provides ESP-MESH networking with IP bridging for phone connectivity.
 * Each mesh node can run a SoftAP for phones while forwarding IP traffic
 * to phones connected to other mesh nodes.
 */

#ifndef GEOGRAM_MESH_BSP_H
#define GEOGRAM_MESH_BSP_H

#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Mesh network status
 */
typedef enum {
    GEOGRAM_MESH_STATUS_STOPPED = 0,    /**< Mesh not started */
    GEOGRAM_MESH_STATUS_STARTED,         /**< Mesh started, scanning */
    GEOGRAM_MESH_STATUS_CONNECTED,       /**< Connected to mesh network */
    GEOGRAM_MESH_STATUS_DISCONNECTED,    /**< Disconnected from mesh */
    GEOGRAM_MESH_STATUS_ROOT,            /**< This node is the root */
    GEOGRAM_MESH_STATUS_ERROR            /**< Error state */
} geogram_mesh_status_t;

/**
 * @brief Mesh event types
 */
typedef enum {
    GEOGRAM_MESH_EVENT_STARTED,              /**< Mesh started */
    GEOGRAM_MESH_EVENT_STOPPED,              /**< Mesh stopped */
    GEOGRAM_MESH_EVENT_CONNECTED,            /**< Connected to mesh */
    GEOGRAM_MESH_EVENT_DISCONNECTED,         /**< Disconnected from mesh */
    GEOGRAM_MESH_EVENT_ROOT_CHANGED,         /**< Root status changed */
    GEOGRAM_MESH_EVENT_CHILD_CONNECTED,      /**< Child node connected */
    GEOGRAM_MESH_EVENT_CHILD_DISCONNECTED,   /**< Child node disconnected */
    GEOGRAM_MESH_EVENT_ROUTE_TABLE_CHANGE,   /**< Route table updated */
    GEOGRAM_MESH_EVENT_EXTERNAL_STA_CONNECTED,    /**< Phone connected to AP */
    GEOGRAM_MESH_EVENT_EXTERNAL_STA_DISCONNECTED  /**< Phone disconnected */
} geogram_mesh_event_t;

/**
 * @brief Mesh event callback function type
 * @param event Event type
 * @param event_data Event-specific data (may be NULL)
 */
typedef void (*geogram_mesh_event_cb_t)(geogram_mesh_event_t event, void *event_data);

/**
 * @brief Mesh configuration structure
 */
typedef struct {
    uint8_t mesh_id[6];         /**< 6-byte mesh network ID */
    char password[64];          /**< Mesh network password */
    uint8_t channel;            /**< WiFi channel (1-13) */
    uint8_t max_layer;          /**< Maximum tree depth */
    bool allow_root;            /**< Can this node become root */
    geogram_mesh_event_cb_t callback;  /**< Event callback */
} geogram_mesh_config_t;

/**
 * @brief Mesh node information
 */
typedef struct {
    uint8_t mac[6];             /**< Node MAC address */
    uint8_t layer;              /**< Layer in mesh tree */
    uint8_t subnet_id;          /**< Assigned subnet (10 + subnet_id) */
    int8_t rssi;                /**< Signal strength */
    bool is_root;               /**< True if this is root node */
} geogram_mesh_node_t;

/**
 * @brief External AP client information
 */
typedef struct {
    uint8_t mac[6];             /**< Client MAC address */
    uint32_t ip;                /**< Client IP address */
} geogram_mesh_external_sta_t;

// ============================================================================
// Initialization
// ============================================================================

/**
 * @brief Initialize mesh subsystem
 * @return ESP_OK on success
 */
esp_err_t geogram_mesh_init(void);

/**
 * @brief Deinitialize mesh subsystem
 * @return ESP_OK on success
 */
esp_err_t geogram_mesh_deinit(void);

// ============================================================================
// Mesh Control
// ============================================================================

/**
 * @brief Start mesh network
 * @param config Mesh configuration
 * @return ESP_OK on success
 */
esp_err_t geogram_mesh_start(const geogram_mesh_config_t *config);

/**
 * @brief Stop mesh network
 * @return ESP_OK on success
 */
esp_err_t geogram_mesh_stop(void);

// ============================================================================
// Status Queries
// ============================================================================

/**
 * @brief Get current mesh status
 * @return Current status
 */
geogram_mesh_status_t geogram_mesh_get_status(void);

/**
 * @brief Check if mesh is connected
 * @return true if connected to mesh
 */
bool geogram_mesh_is_connected(void);

/**
 * @brief Check if this node is the root
 * @return true if this is the root node
 */
bool geogram_mesh_is_root(void);

/**
 * @brief Get current layer in mesh tree
 * @return Layer number (1 = root)
 */
uint8_t geogram_mesh_get_layer(void);

/**
 * @brief Get this node's subnet ID
 * @return Subnet ID (subnet = 192.168.{10+id}.0/24)
 */
uint8_t geogram_mesh_get_subnet_id(void);

/**
 * @brief Get parent node MAC address
 * @param mac Buffer to store MAC (6 bytes)
 * @return ESP_OK if parent exists
 */
esp_err_t geogram_mesh_get_parent_mac(uint8_t *mac);

/**
 * @brief Check if this node has a parent (connected to mesh)
 * @return true if connected to a parent mesh node
 */
bool geogram_mesh_has_parent(void);

/**
 * @brief Get number of other mesh nodes we're connected to
 * @return Number of peer mesh nodes (total mesh nodes - 1)
 */
size_t geogram_mesh_get_peer_count(void);

// ============================================================================
// External SoftAP (for phones)
// ============================================================================

/**
 * @brief Start external SoftAP for phone connections
 * @param ssid AP SSID (max 32 chars)
 * @param password AP password (empty for open)
 * @param max_connections Maximum phone connections
 * @return ESP_OK on success
 */
esp_err_t geogram_mesh_start_external_ap(const char *ssid, const char *password,
                                          uint8_t max_connections);

/**
 * @brief Stop external SoftAP
 * @return ESP_OK on success
 */
esp_err_t geogram_mesh_stop_external_ap(void);

/**
 * @brief Check if external AP is running
 * @return true if AP is running
 */
bool geogram_mesh_external_ap_is_running(void);

/**
 * @brief Get external AP IP address string
 * @param ip_str Buffer for IP string (min 16 bytes)
 * @param len Buffer length
 * @return ESP_OK on success
 */
esp_err_t geogram_mesh_get_external_ap_ip(char *ip_str, size_t len);

/**
 * @brief Get external AP IP address as uint32_t
 * @param ip Pointer to store IP
 * @return ESP_OK on success
 */
esp_err_t geogram_mesh_get_external_ap_ip_addr(uint32_t *ip);

/**
 * @brief Get number of clients connected to external AP
 * @return Number of connected clients
 */
uint8_t geogram_mesh_get_external_ap_client_count(void);

// ============================================================================
// Node Discovery
// ============================================================================

/**
 * @brief Get list of known mesh nodes
 * @param nodes Buffer for node info
 * @param max_nodes Maximum nodes to return
 * @param node_count Actual count returned
 * @return ESP_OK on success
 */
esp_err_t geogram_mesh_get_nodes(geogram_mesh_node_t *nodes, size_t max_nodes,
                                  size_t *node_count);

/**
 * @brief Get total number of nodes in mesh
 * @return Node count
 */
size_t geogram_mesh_get_node_count(void);

/**
 * @brief Find node by subnet ID
 * @param subnet_id Subnet ID to find
 * @param node Buffer for node info
 * @return ESP_OK if found
 */
esp_err_t geogram_mesh_find_node_by_subnet(uint8_t subnet_id, geogram_mesh_node_t *node);

// ============================================================================
// IP Bridging
// ============================================================================

/**
 * @brief Enable IP packet bridging between mesh nodes
 * @return ESP_OK on success
 */
esp_err_t geogram_mesh_enable_bridge(void);

/**
 * @brief Disable IP packet bridging
 * @return ESP_OK on success
 */
esp_err_t geogram_mesh_disable_bridge(void);

/**
 * @brief Check if bridging is enabled
 * @return true if bridging is active
 */
bool geogram_mesh_bridge_is_enabled(void);

/**
 * @brief Get bridge statistics
 * @param packets_tx Packets transmitted (may be NULL)
 * @param packets_rx Packets received (may be NULL)
 * @param bytes_tx Bytes transmitted (may be NULL)
 * @param bytes_rx Bytes received (may be NULL)
 */
void geogram_mesh_bridge_get_stats(uint32_t *packets_tx, uint32_t *packets_rx,
                                    uint32_t *bytes_tx, uint32_t *bytes_rx);

// ============================================================================
// Configuration Persistence
// ============================================================================

/**
 * @brief Save current mesh config to NVS
 * @return ESP_OK on success
 */
esp_err_t geogram_mesh_save_config(void);

/**
 * @brief Load mesh config from NVS
 * @param config Configuration to fill
 * @return ESP_OK on success
 */
esp_err_t geogram_mesh_load_config(geogram_mesh_config_t *config);

// ============================================================================
// Internal Bridge API (used by mesh_bridge.c)
// ============================================================================

/**
 * @brief Send data to specific mesh node
 * @param dest_mac Destination node MAC
 * @param data Data buffer
 * @param len Data length
 * @return ESP_OK on success
 */
esp_err_t geogram_mesh_send_to_node(const uint8_t *dest_mac, const void *data, size_t len);

/**
 * @brief Register callback for incoming mesh data
 * @param callback Function to call with received data
 */
typedef void (*geogram_mesh_data_cb_t)(const uint8_t *src_mac, const void *data, size_t len);
void geogram_mesh_register_data_callback(geogram_mesh_data_cb_t callback);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_MESH_BSP_H
