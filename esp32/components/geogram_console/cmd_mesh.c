/**
 * @file cmd_mesh.c
 * @brief Mesh networking commands for serial console
 *
 * Provides commands for testing and debugging ESP-MESH networking:
 * - mesh: Show mesh status
 * - mesh_start: Start mesh networking
 * - mesh_stop: Stop mesh networking
 * - mesh_nodes: List mesh nodes
 * - mesh_send: Send test message to another node
 * - mesh_broadcast: Broadcast message to all nodes
 * - mesh_ping: Ping another mesh node
 * - mesh_bridge: Show bridge statistics
 * - mesh_debug: Enable/disable debug logging
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "console.h"
#include "esp_console.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "argtable3/argtable3.h"
#include "app_config.h"
#include "nostr_keys.h"

#ifdef CONFIG_GEOGRAM_MESH_ENABLED
#include "mesh_bsp.h"
#include "mesh_chat.h"

static const char *TAG = "cmd_mesh";

// Debug mode flag
static bool s_debug_enabled = true;

// Test message protocol
#define MESH_TEST_MSG_MAGIC     0x54455354  // "TEST"
#define MESH_TEST_MSG_PING      1
#define MESH_TEST_MSG_PONG      2
#define MESH_TEST_MSG_TEXT      3
#define MESH_TEST_MSG_BROADCAST 4

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint8_t type;
    uint32_t seq;
    uint32_t timestamp;
    uint16_t payload_len;
    uint8_t payload[];
} mesh_test_msg_t;

// Sequence number for messages
static uint32_t s_msg_seq = 0;

// Callback for received test messages
static void mesh_test_rx_callback(const uint8_t *src_mac, const void *data, size_t len);

// ============================================================================
// mesh command (status)
// ============================================================================

static int cmd_mesh_status(int argc, char **argv)
{
    geogram_mesh_status_t status = geogram_mesh_get_status();

    if (console_get_output_mode() == CONSOLE_OUTPUT_JSON) {
        const char *status_str;
        switch (status) {
            case GEOGRAM_MESH_STATUS_STOPPED:    status_str = "stopped"; break;
            case GEOGRAM_MESH_STATUS_STARTED:    status_str = "started"; break;
            case GEOGRAM_MESH_STATUS_CONNECTED:  status_str = "connected"; break;
            case GEOGRAM_MESH_STATUS_DISCONNECTED: status_str = "disconnected"; break;
            case GEOGRAM_MESH_STATUS_ROOT:       status_str = "root"; break;
            case GEOGRAM_MESH_STATUS_ERROR:      status_str = "error"; break;
            default:                              status_str = "unknown"; break;
        }

        char ip_str[16] = {0};
        geogram_mesh_get_external_ap_ip(ip_str, sizeof(ip_str));

        printf("{\"status\":\"%s\",\"is_root\":%s,\"layer\":%d,\"nodes\":%zu,"
               "\"subnet_id\":%d,\"ip\":\"%s\",\"ap_running\":%s,\"ap_clients\":%d,"
               "\"bridge_enabled\":%s}\n",
               status_str,
               geogram_mesh_is_root() ? "true" : "false",
               geogram_mesh_get_layer(),
               geogram_mesh_get_node_count(),
               geogram_mesh_get_subnet_id(),
               ip_str,
               geogram_mesh_external_ap_is_running() ? "true" : "false",
               geogram_mesh_get_external_ap_client_count(),
               geogram_mesh_bridge_is_enabled() ? "true" : "false");
    } else {
        printf("\n=== Mesh Network Status ===\n");

        const char *status_str;
        switch (status) {
            case GEOGRAM_MESH_STATUS_STOPPED:    status_str = "Stopped"; break;
            case GEOGRAM_MESH_STATUS_STARTED:    status_str = "Started (scanning)"; break;
            case GEOGRAM_MESH_STATUS_CONNECTED:  status_str = "Connected"; break;
            case GEOGRAM_MESH_STATUS_DISCONNECTED: status_str = "Disconnected"; break;
            case GEOGRAM_MESH_STATUS_ROOT:       status_str = "Connected (ROOT)"; break;
            case GEOGRAM_MESH_STATUS_ERROR:      status_str = "Error"; break;
            default:                              status_str = "Unknown"; break;
        }

        printf("Status:      %s\n", status_str);
        printf("Is Root:     %s\n", geogram_mesh_is_root() ? "YES" : "no");
        printf("Layer:       %d\n", geogram_mesh_get_layer());
        printf("Subnet ID:   %d (192.168.%d.0/24)\n",
               geogram_mesh_get_subnet_id(), 10 + geogram_mesh_get_subnet_id());
        printf("Node Count:  %zu\n", geogram_mesh_get_node_count());

        // Parent info
        uint8_t parent_mac[6];
        if (geogram_mesh_get_parent_mac(parent_mac) == ESP_OK) {
            printf("Parent:      %02X:%02X:%02X:%02X:%02X:%02X\n",
                   parent_mac[0], parent_mac[1], parent_mac[2],
                   parent_mac[3], parent_mac[4], parent_mac[5]);
        }

        printf("\n--- External AP ---\n");
        printf("Running:     %s\n", geogram_mesh_external_ap_is_running() ? "yes" : "no");
        if (geogram_mesh_external_ap_is_running()) {
            char ip_str[16] = {0};
            geogram_mesh_get_external_ap_ip(ip_str, sizeof(ip_str));
            printf("IP Address:  %s\n", ip_str);
            printf("Clients:     %d\n", geogram_mesh_get_external_ap_client_count());
        }

        printf("\n--- IP Bridge ---\n");
        printf("Enabled:     %s\n", geogram_mesh_bridge_is_enabled() ? "yes" : "no");
        if (geogram_mesh_bridge_is_enabled()) {
            uint32_t pkts_tx, pkts_rx, bytes_tx, bytes_rx;
            geogram_mesh_bridge_get_stats(&pkts_tx, &pkts_rx, &bytes_tx, &bytes_rx);
            printf("Packets TX:  %lu\n", (unsigned long)pkts_tx);
            printf("Packets RX:  %lu\n", (unsigned long)pkts_rx);
            printf("Bytes TX:    %lu\n", (unsigned long)bytes_tx);
            printf("Bytes RX:    %lu\n", (unsigned long)bytes_rx);
        }

        printf("\n");
    }

    return 0;
}

// ============================================================================
// mesh_start command
// ============================================================================

static struct {
    struct arg_int *channel;
    struct arg_lit *root;
    struct arg_end *end;
} mesh_start_args;

static int cmd_mesh_start(int argc, char **argv)
{
    int nerrors = arg_parse(argc, argv, (void **)&mesh_start_args);
    if (nerrors != 0) {
        arg_print_errors(stderr, mesh_start_args.end, argv[0]);
        return 1;
    }

    if (geogram_mesh_is_connected()) {
        printf("Mesh already running\n");
        return 0;
    }

    printf("Starting mesh network...\n");

    // Initialize mesh if needed
    esp_err_t ret = geogram_mesh_init();
    if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
        printf("Error: Failed to initialize mesh: %s\n", esp_err_to_name(ret));
        return 1;
    }

    // Configure
    geogram_mesh_config_t cfg = {
        .mesh_id = {'g', 'e', 'o', 'm', 's', 'h'},
        .password = "",
        .channel = mesh_start_args.channel->count > 0 ?
                   (uint8_t)mesh_start_args.channel->ival[0] : 1,
        .max_layer = 6,
        .allow_root = mesh_start_args.root->count > 0,
        .callback = NULL
    };

    printf("Channel: %d, Allow root: %s\n", cfg.channel, cfg.allow_root ? "yes" : "no");

    // Register test message callback
    geogram_mesh_register_data_callback(mesh_test_rx_callback);

    ret = geogram_mesh_start(&cfg);
    if (ret != ESP_OK) {
        printf("Error: Failed to start mesh: %s\n", esp_err_to_name(ret));
        return 1;
    }

    printf("Mesh started, scanning for network...\n");
    return 0;
}

// ============================================================================
// mesh_stop command
// ============================================================================

static int cmd_mesh_stop(int argc, char **argv)
{
    if (!geogram_mesh_is_connected() && geogram_mesh_get_status() == GEOGRAM_MESH_STATUS_STOPPED) {
        printf("Mesh not running\n");
        return 0;
    }

    printf("Stopping mesh network...\n");
    esp_err_t ret = geogram_mesh_stop();
    if (ret != ESP_OK) {
        printf("Error: %s\n", esp_err_to_name(ret));
        return 1;
    }

    printf("Mesh stopped\n");
    return 0;
}

// ============================================================================
// mesh_nodes command
// ============================================================================

static int cmd_mesh_nodes(int argc, char **argv)
{
    geogram_mesh_node_t nodes[20];
    size_t count = 0;

    esp_err_t ret = geogram_mesh_get_nodes(nodes, 20, &count);
    if (ret != ESP_OK) {
        printf("Error: Failed to get nodes: %s\n", esp_err_to_name(ret));
        return 1;
    }

    if (count == 0) {
        printf("No mesh nodes found (mesh may not be connected)\n");
        return 0;
    }

    printf("\n=== Mesh Nodes (%zu) ===\n", count);
    printf("%-20s  %-8s  %-10s  %-8s\n", "MAC Address", "Layer", "Subnet", "Root");
    printf("%-20s  %-8s  %-10s  %-8s\n", "-------------------", "-----", "------", "----");

    for (size_t i = 0; i < count; i++) {
        char mac_str[18];
        snprintf(mac_str, sizeof(mac_str), "%02X:%02X:%02X:%02X:%02X:%02X",
                 nodes[i].mac[0], nodes[i].mac[1], nodes[i].mac[2],
                 nodes[i].mac[3], nodes[i].mac[4], nodes[i].mac[5]);

        char subnet_str[20];
        snprintf(subnet_str, sizeof(subnet_str), "192.168.%d.x", 10 + nodes[i].subnet_id);

        printf("%-20s  %-8d  %-10s  %-8s\n",
               mac_str, nodes[i].layer, subnet_str,
               nodes[i].is_root ? "YES" : "");
    }

    printf("\n");
    return 0;
}

// ============================================================================
// mesh_send command - Send test message to specific node
// ============================================================================

static struct {
    struct arg_str *mac;
    struct arg_str *message;
    struct arg_end *end;
} mesh_send_args;

static int cmd_mesh_send(int argc, char **argv)
{
    int nerrors = arg_parse(argc, argv, (void **)&mesh_send_args);
    if (nerrors != 0) {
        arg_print_errors(stderr, mesh_send_args.end, argv[0]);
        return 1;
    }

    if (!geogram_mesh_is_connected()) {
        printf("Error: Mesh not connected\n");
        return 1;
    }

    // Parse MAC address
    uint8_t dest_mac[6];
    if (sscanf(mesh_send_args.mac->sval[0], "%hhx:%hhx:%hhx:%hhx:%hhx:%hhx",
               &dest_mac[0], &dest_mac[1], &dest_mac[2],
               &dest_mac[3], &dest_mac[4], &dest_mac[5]) != 6) {
        printf("Error: Invalid MAC address format (use XX:XX:XX:XX:XX:XX)\n");
        return 1;
    }

    const char *message = mesh_send_args.message->sval[0];
    size_t msg_len = strlen(message);

    // Build test message
    size_t total_len = sizeof(mesh_test_msg_t) + msg_len + 1;
    mesh_test_msg_t *msg = malloc(total_len);
    if (!msg) {
        printf("Error: Out of memory\n");
        return 1;
    }

    msg->magic = MESH_TEST_MSG_MAGIC;
    msg->type = MESH_TEST_MSG_TEXT;
    msg->seq = ++s_msg_seq;
    msg->timestamp = (uint32_t)(esp_timer_get_time() / 1000);
    msg->payload_len = msg_len + 1;
    memcpy(msg->payload, message, msg_len + 1);

    printf("[SEND] To: %02X:%02X:%02X:%02X:%02X:%02X, Seq: %lu, Message: \"%s\"\n",
           dest_mac[0], dest_mac[1], dest_mac[2],
           dest_mac[3], dest_mac[4], dest_mac[5],
           (unsigned long)msg->seq, message);

    esp_err_t ret = geogram_mesh_send_to_node(dest_mac, msg, total_len);
    free(msg);

    if (ret != ESP_OK) {
        printf("[SEND] FAILED: %s\n", esp_err_to_name(ret));
        return 1;
    }

    printf("[SEND] SUCCESS\n");
    return 0;
}

// ============================================================================
// mesh_broadcast command - Broadcast message to all nodes
// ============================================================================

static struct {
    struct arg_str *message;
    struct arg_end *end;
} mesh_broadcast_args;

static int cmd_mesh_broadcast(int argc, char **argv)
{
    int nerrors = arg_parse(argc, argv, (void **)&mesh_broadcast_args);
    if (nerrors != 0) {
        arg_print_errors(stderr, mesh_broadcast_args.end, argv[0]);
        return 1;
    }

    if (!geogram_mesh_is_connected()) {
        printf("Error: Mesh not connected\n");
        return 1;
    }

    const char *message = mesh_broadcast_args.message->sval[0];
    size_t msg_len = strlen(message);

    // Build broadcast message
    size_t total_len = sizeof(mesh_test_msg_t) + msg_len + 1;
    mesh_test_msg_t *msg = malloc(total_len);
    if (!msg) {
        printf("Error: Out of memory\n");
        return 1;
    }

    msg->magic = MESH_TEST_MSG_MAGIC;
    msg->type = MESH_TEST_MSG_BROADCAST;
    msg->seq = ++s_msg_seq;
    msg->timestamp = (uint32_t)(esp_timer_get_time() / 1000);
    msg->payload_len = msg_len + 1;
    memcpy(msg->payload, message, msg_len + 1);

    printf("[BROADCAST] Seq: %lu, Message: \"%s\"\n",
           (unsigned long)msg->seq, message);

    // Get all nodes and send to each
    geogram_mesh_node_t nodes[20];
    size_t count = 0;
    geogram_mesh_get_nodes(nodes, 20, &count);

    int success = 0, failed = 0;
    for (size_t i = 0; i < count; i++) {
        esp_err_t ret = geogram_mesh_send_to_node(nodes[i].mac, msg, total_len);
        if (ret == ESP_OK) {
            success++;
            printf("[BROADCAST] Sent to %02X:%02X:%02X:%02X:%02X:%02X\n",
                   nodes[i].mac[0], nodes[i].mac[1], nodes[i].mac[2],
                   nodes[i].mac[3], nodes[i].mac[4], nodes[i].mac[5]);
        } else {
            failed++;
            printf("[BROADCAST] Failed to send to %02X:%02X:%02X:%02X:%02X:%02X: %s\n",
                   nodes[i].mac[0], nodes[i].mac[1], nodes[i].mac[2],
                   nodes[i].mac[3], nodes[i].mac[4], nodes[i].mac[5],
                   esp_err_to_name(ret));
        }
    }

    free(msg);
    printf("[BROADCAST] Sent to %d/%zu nodes\n", success, count);
    return 0;
}

// ============================================================================
// mesh_ping command - Ping a mesh node
// ============================================================================

static struct {
    struct arg_str *mac;
    struct arg_end *end;
} mesh_ping_args;

static int cmd_mesh_ping(int argc, char **argv)
{
    int nerrors = arg_parse(argc, argv, (void **)&mesh_ping_args);
    if (nerrors != 0) {
        arg_print_errors(stderr, mesh_ping_args.end, argv[0]);
        return 1;
    }

    if (!geogram_mesh_is_connected()) {
        printf("Error: Mesh not connected\n");
        return 1;
    }

    // Parse MAC address
    uint8_t dest_mac[6];
    if (sscanf(mesh_ping_args.mac->sval[0], "%hhx:%hhx:%hhx:%hhx:%hhx:%hhx",
               &dest_mac[0], &dest_mac[1], &dest_mac[2],
               &dest_mac[3], &dest_mac[4], &dest_mac[5]) != 6) {
        printf("Error: Invalid MAC address format (use XX:XX:XX:XX:XX:XX)\n");
        return 1;
    }

    // Build ping message
    mesh_test_msg_t msg = {
        .magic = MESH_TEST_MSG_MAGIC,
        .type = MESH_TEST_MSG_PING,
        .seq = ++s_msg_seq,
        .timestamp = (uint32_t)(esp_timer_get_time() / 1000),
        .payload_len = 0
    };

    printf("[PING] To: %02X:%02X:%02X:%02X:%02X:%02X, Seq: %lu, Time: %lu ms\n",
           dest_mac[0], dest_mac[1], dest_mac[2],
           dest_mac[3], dest_mac[4], dest_mac[5],
           (unsigned long)msg.seq, (unsigned long)msg.timestamp);

    esp_err_t ret = geogram_mesh_send_to_node(dest_mac, &msg, sizeof(msg));
    if (ret != ESP_OK) {
        printf("[PING] FAILED: %s\n", esp_err_to_name(ret));
        return 1;
    }

    printf("[PING] Sent, waiting for PONG...\n");
    return 0;
}

// ============================================================================
// mesh_bridge command - Show bridge statistics
// ============================================================================

static int cmd_mesh_bridge(int argc, char **argv)
{
    uint32_t pkts_tx, pkts_rx, bytes_tx, bytes_rx;
    geogram_mesh_bridge_get_stats(&pkts_tx, &pkts_rx, &bytes_tx, &bytes_rx);

    if (console_get_output_mode() == CONSOLE_OUTPUT_JSON) {
        printf("{\"enabled\":%s,\"packets_tx\":%lu,\"packets_rx\":%lu,"
               "\"bytes_tx\":%lu,\"bytes_rx\":%lu}\n",
               geogram_mesh_bridge_is_enabled() ? "true" : "false",
               (unsigned long)pkts_tx, (unsigned long)pkts_rx,
               (unsigned long)bytes_tx, (unsigned long)bytes_rx);
    } else {
        printf("\n=== IP Bridge Statistics ===\n");
        printf("Status:      %s\n", geogram_mesh_bridge_is_enabled() ? "Enabled" : "Disabled");
        printf("Packets TX:  %lu\n", (unsigned long)pkts_tx);
        printf("Packets RX:  %lu\n", (unsigned long)pkts_rx);
        printf("Bytes TX:    %lu\n", (unsigned long)bytes_tx);
        printf("Bytes RX:    %lu\n", (unsigned long)bytes_rx);
        printf("\n");
    }

    return 0;
}

// ============================================================================
// mesh_ap command - Start/stop external AP
// ============================================================================

static struct {
    struct arg_lit *stop;
    struct arg_str *ssid;
    struct arg_end *end;
} mesh_ap_args;

static int cmd_mesh_ap(int argc, char **argv)
{
    int nerrors = arg_parse(argc, argv, (void **)&mesh_ap_args);
    if (nerrors != 0) {
        arg_print_errors(stderr, mesh_ap_args.end, argv[0]);
        return 1;
    }

    if (mesh_ap_args.stop->count > 0) {
        printf("Stopping external AP...\n");
        esp_err_t ret = geogram_mesh_stop_external_ap();
        if (ret != ESP_OK) {
            printf("Error: %s\n", esp_err_to_name(ret));
            return 1;
        }
        printf("External AP stopped\n");
        return 0;
    }

    if (!geogram_mesh_is_connected()) {
        printf("Error: Mesh not connected\n");
        return 1;
    }

    // Build SSID: geogram-{callsign} or custom if provided
    char ap_ssid[32];
    if (mesh_ap_args.ssid->count > 0) {
        strncpy(ap_ssid, mesh_ap_args.ssid->sval[0], sizeof(ap_ssid) - 1);
        ap_ssid[sizeof(ap_ssid) - 1] = '\0';
    } else {
        const char *callsign = nostr_keys_get_callsign();
        if (callsign && strlen(callsign) > 0) {
            snprintf(ap_ssid, sizeof(ap_ssid), "geogram-%s", callsign);
        } else {
            strncpy(ap_ssid, "geogram-mesh", sizeof(ap_ssid));
        }
    }

    // Default password is "geogram"
    const char *password = "geogram";

    printf("Starting external AP...\n");
    printf("  SSID: %s\n", ap_ssid);
    printf("  Password: %s\n", password);

    esp_err_t ret = geogram_mesh_start_external_ap(ap_ssid, password, 4);
    if (ret != ESP_OK) {
        printf("Error: %s\n", esp_err_to_name(ret));
        return 1;
    }

    char ip_str[16];
    geogram_mesh_get_external_ap_ip(ip_str, sizeof(ip_str));
    printf("External AP started at %s\n", ip_str);

    return 0;
}

// ============================================================================
// mesh_debug command - Enable/disable debug output
// ============================================================================

static struct {
    struct arg_lit *on;
    struct arg_lit *off;
    struct arg_end *end;
} mesh_debug_args;

static int cmd_mesh_debug(int argc, char **argv)
{
    int nerrors = arg_parse(argc, argv, (void **)&mesh_debug_args);
    if (nerrors != 0) {
        arg_print_errors(stderr, mesh_debug_args.end, argv[0]);
        return 1;
    }

    if (mesh_debug_args.on->count > 0) {
        s_debug_enabled = true;
        esp_log_level_set("mesh", ESP_LOG_DEBUG);      // Internal ESP-MESH
        esp_log_level_set("mesh_bsp", ESP_LOG_DEBUG);  // Our mesh component
        esp_log_level_set("mesh_bridge", ESP_LOG_DEBUG);
        printf("Mesh debug logging ENABLED\n");
    } else if (mesh_debug_args.off->count > 0) {
        s_debug_enabled = false;
        esp_log_level_set("mesh", ESP_LOG_WARN);       // Suppress internal scanning logs
        esp_log_level_set("mesh_bsp", ESP_LOG_INFO);   // Our mesh component
        esp_log_level_set("mesh_bridge", ESP_LOG_INFO);
        printf("Mesh debug logging DISABLED\n");
    } else {
        printf("Debug mode: %s\n", s_debug_enabled ? "ON" : "OFF");
        printf("Usage: mesh_debug --on | --off\n");
    }

    return 0;
}

// ============================================================================
// Receive callback for test messages
// ============================================================================

static void mesh_test_rx_callback(const uint8_t *src_mac, const void *data, size_t len)
{
    if (len < sizeof(mesh_test_msg_t)) {
        if (s_debug_enabled) {
            printf("[MESH RX] Too small (%zu bytes)\n", len);
        }
        return;
    }

    const mesh_test_msg_t *msg = (const mesh_test_msg_t *)data;

    // Check if this is a test message
    if (msg->magic != MESH_TEST_MSG_MAGIC) {
        if (s_debug_enabled) {
            printf("[MESH RX] Not a test message (magic: 0x%08lx)\n", (unsigned long)msg->magic);
        }
        return;
    }

    uint32_t now = (uint32_t)(esp_timer_get_time() / 1000);
    uint32_t latency = now - msg->timestamp;

    printf("\n[MESH RX] From: %02X:%02X:%02X:%02X:%02X:%02X\n",
           src_mac[0], src_mac[1], src_mac[2],
           src_mac[3], src_mac[4], src_mac[5]);
    printf("[MESH RX] Seq: %lu, Latency: %lu ms\n",
           (unsigned long)msg->seq, (unsigned long)latency);

    switch (msg->type) {
        case MESH_TEST_MSG_PING:
            printf("[MESH RX] Type: PING - sending PONG\n");
            // Send PONG back
            {
                mesh_test_msg_t pong = {
                    .magic = MESH_TEST_MSG_MAGIC,
                    .type = MESH_TEST_MSG_PONG,
                    .seq = msg->seq,
                    .timestamp = msg->timestamp,
                    .payload_len = 0
                };
                geogram_mesh_send_to_node(src_mac, &pong, sizeof(pong));
            }
            break;

        case MESH_TEST_MSG_PONG:
            printf("[MESH RX] Type: PONG (RTT: %lu ms)\n", (unsigned long)(latency * 2));
            break;

        case MESH_TEST_MSG_TEXT:
            printf("[MESH RX] Type: TEXT\n");
            printf("[MESH RX] Message: \"%s\"\n", (const char *)msg->payload);
            break;

        case MESH_TEST_MSG_BROADCAST:
            printf("[MESH RX] Type: BROADCAST\n");
            printf("[MESH RX] Message: \"%s\"\n", (const char *)msg->payload);
            break;

        default:
            printf("[MESH RX] Type: Unknown (%d)\n", msg->type);
            break;
    }

    printf("\n");
}

// ============================================================================
// chat command - Send a chat message
// ============================================================================

static struct {
    struct arg_str *message;
    struct arg_end *end;
} chat_args;

static int cmd_chat(int argc, char **argv)
{
    int nerrors = arg_parse(argc, argv, (void **)&chat_args);
    if (nerrors != 0) {
        arg_print_errors(stderr, chat_args.end, argv[0]);
        return 1;
    }

    if (chat_args.message->count == 0) {
        printf("Usage: chat <message>\n");
        printf("Max message length: %d characters\n", MESH_CHAT_MAX_MESSAGE_LEN);
        return 1;
    }

    const char *message = chat_args.message->sval[0];
    size_t len = strlen(message);

    if (len > MESH_CHAT_MAX_MESSAGE_LEN) {
        printf("Message too long (%zu > %d characters)\n", len, MESH_CHAT_MAX_MESSAGE_LEN);
        printf("Message will be truncated.\n");
    }

    // Initialize chat if needed
    mesh_chat_init();

    esp_err_t ret = mesh_chat_send(message);
    if (ret != ESP_OK) {
        printf("Failed to send: %s\n", esp_err_to_name(ret));
        return 1;
    }

    const char *callsign = nostr_keys_get_callsign();
    printf("[%s] %s\n", callsign ? callsign : "ME", message);

    return 0;
}

// ============================================================================
// chat_history command - Show recent messages
// ============================================================================

static int cmd_chat_history(int argc, char **argv)
{
    // Initialize chat if needed
    mesh_chat_init();

    mesh_chat_message_t messages[MESH_CHAT_HISTORY_SIZE];
    size_t count = mesh_chat_get_history(messages, MESH_CHAT_HISTORY_SIZE, 0);

    if (count == 0) {
        printf("No chat messages yet.\n");
        printf("Use 'chat <message>' to send a message.\n");
        return 0;
    }

    printf("\n=== Chat History (%zu messages) ===\n", count);
    printf("Max message length: %d characters\n\n", MESH_CHAT_MAX_MESSAGE_LEN);

    for (size_t i = 0; i < count; i++) {
        // Format timestamp
        time_t ts = (time_t)messages[i].timestamp;
        struct tm *tm_info = localtime(&ts);
        char time_str[16];
        if (tm_info) {
            strftime(time_str, sizeof(time_str), "%H:%M:%S", tm_info);
        } else {
            snprintf(time_str, sizeof(time_str), "%lu", (unsigned long)messages[i].timestamp);
        }

        printf("[%s] <%s>%s %s\n",
               time_str,
               messages[i].callsign,
               messages[i].is_local ? "*" : "",
               messages[i].text);
    }

    printf("\n(* = sent from this node)\n");

    return 0;
}

// ============================================================================
// Callback for displaying received chat messages
// ============================================================================

static void chat_message_callback(const mesh_chat_message_t *msg)
{
    if (!msg || msg->is_local) {
        return;  // Don't print our own messages again
    }

    // Print received message to console
    time_t ts = (time_t)msg->timestamp;
    struct tm *tm_info = localtime(&ts);
    char time_str[16];
    if (tm_info) {
        strftime(time_str, sizeof(time_str), "%H:%M:%S", tm_info);
    } else {
        snprintf(time_str, sizeof(time_str), "%lu", (unsigned long)msg->timestamp);
    }

    printf("\n[CHAT] [%s] <%s> %s\n", time_str, msg->callsign, msg->text);
    printf("geogram> ");  // Reprint prompt
    fflush(stdout);
}

// ============================================================================
// Register all mesh commands
// ============================================================================

void register_mesh_commands(void)
{
    // mesh (status)
    const esp_console_cmd_t mesh_cmd = {
        .command = "mesh",
        .help = "Show mesh network status",
        .hint = NULL,
        .func = &cmd_mesh_status,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&mesh_cmd));

    // mesh_start
    mesh_start_args.channel = arg_int0("c", "channel", "<1-13>", "WiFi channel (default: 1)");
    mesh_start_args.root = arg_lit0("r", "root", "Allow this node to become root");
    mesh_start_args.end = arg_end(2);
    const esp_console_cmd_t mesh_start_cmd = {
        .command = "mesh_start",
        .help = "Start mesh networking",
        .hint = NULL,
        .func = &cmd_mesh_start,
        .argtable = &mesh_start_args,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&mesh_start_cmd));

    // mesh_stop
    const esp_console_cmd_t mesh_stop_cmd = {
        .command = "mesh_stop",
        .help = "Stop mesh networking",
        .hint = NULL,
        .func = &cmd_mesh_stop,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&mesh_stop_cmd));

    // mesh_nodes
    const esp_console_cmd_t mesh_nodes_cmd = {
        .command = "mesh_nodes",
        .help = "List mesh nodes",
        .hint = NULL,
        .func = &cmd_mesh_nodes,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&mesh_nodes_cmd));

    // mesh_send
    mesh_send_args.mac = arg_str1(NULL, NULL, "<mac>", "Destination MAC (XX:XX:XX:XX:XX:XX)");
    mesh_send_args.message = arg_str1(NULL, NULL, "<message>", "Message to send");
    mesh_send_args.end = arg_end(2);
    const esp_console_cmd_t mesh_send_cmd = {
        .command = "mesh_send",
        .help = "Send test message to mesh node",
        .hint = NULL,
        .func = &cmd_mesh_send,
        .argtable = &mesh_send_args,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&mesh_send_cmd));

    // mesh_broadcast
    mesh_broadcast_args.message = arg_str1(NULL, NULL, "<message>", "Message to broadcast");
    mesh_broadcast_args.end = arg_end(1);
    const esp_console_cmd_t mesh_broadcast_cmd = {
        .command = "mesh_broadcast",
        .help = "Broadcast message to all mesh nodes",
        .hint = NULL,
        .func = &cmd_mesh_broadcast,
        .argtable = &mesh_broadcast_args,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&mesh_broadcast_cmd));

    // mesh_ping
    mesh_ping_args.mac = arg_str1(NULL, NULL, "<mac>", "Target MAC (XX:XX:XX:XX:XX:XX)");
    mesh_ping_args.end = arg_end(1);
    const esp_console_cmd_t mesh_ping_cmd = {
        .command = "mesh_ping",
        .help = "Ping a mesh node",
        .hint = NULL,
        .func = &cmd_mesh_ping,
        .argtable = &mesh_ping_args,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&mesh_ping_cmd));

    // mesh_bridge
    const esp_console_cmd_t mesh_bridge_cmd = {
        .command = "mesh_bridge",
        .help = "Show IP bridge statistics",
        .hint = NULL,
        .func = &cmd_mesh_bridge,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&mesh_bridge_cmd));

    // mesh_ap
    mesh_ap_args.stop = arg_lit0("s", "stop", "Stop external AP");
    mesh_ap_args.ssid = arg_str0(NULL, NULL, "[ssid]", "AP SSID (default: geogram-test)");
    mesh_ap_args.end = arg_end(2);
    const esp_console_cmd_t mesh_ap_cmd = {
        .command = "mesh_ap",
        .help = "Start/stop external SoftAP",
        .hint = NULL,
        .func = &cmd_mesh_ap,
        .argtable = &mesh_ap_args,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&mesh_ap_cmd));

    // mesh_debug
    mesh_debug_args.on = arg_lit0(NULL, "on", "Enable debug logging");
    mesh_debug_args.off = arg_lit0(NULL, "off", "Disable debug logging");
    mesh_debug_args.end = arg_end(2);
    const esp_console_cmd_t mesh_debug_cmd = {
        .command = "mesh_debug",
        .help = "Enable/disable mesh debug logging",
        .hint = NULL,
        .func = &cmd_mesh_debug,
        .argtable = &mesh_debug_args,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&mesh_debug_cmd));

    // chat - send a chat message
    chat_args.message = arg_str1(NULL, NULL, "<message>", "Message to send (max 200 chars)");
    chat_args.end = arg_end(1);
    const esp_console_cmd_t chat_cmd = {
        .command = "chat",
        .help = "Send a chat message to all mesh nodes",
        .hint = NULL,
        .func = &cmd_chat,
        .argtable = &chat_args,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&chat_cmd));

    // chat_history - show recent messages
    const esp_console_cmd_t chat_history_cmd = {
        .command = "chat_history",
        .help = "Show recent chat messages",
        .hint = NULL,
        .func = &cmd_chat_history,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&chat_history_cmd));

    // Initialize chat system and register callback
    mesh_chat_init();
    mesh_chat_register_callback(chat_message_callback);

    ESP_LOGI(TAG, "Mesh commands registered");
}

#else  // CONFIG_GEOGRAM_MESH_ENABLED not defined

void register_mesh_commands(void)
{
    // Mesh support not compiled in - no commands to register
}

#endif  // CONFIG_GEOGRAM_MESH_ENABLED
