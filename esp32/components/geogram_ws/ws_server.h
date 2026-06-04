#ifndef GEOGRAM_WS_SERVER_H
#define GEOGRAM_WS_SERVER_H

#include <esp_http_server.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Maximum WebSocket frame size
#define WS_MAX_FRAME_SIZE 4096

// Maximum connected clients
#define WS_MAX_CLIENTS 10

// WebSocket message types
typedef enum {
    WS_MSG_HELLO,           // Client hello with ID
    WS_MSG_FILE_REQUEST,    // Request file by SHA1
    WS_MSG_FILE_AVAILABLE,  // Announce file availability
    WS_MSG_FILE_FETCH,      // Request file transfer from a peer
    WS_MSG_FILE_CHUNK,      // File chunk transfer
    WS_MSG_FILE_COMPLETE,   // File transfer complete
    WS_MSG_RTC_OFFER,       // WebRTC offer
    WS_MSG_RTC_ANSWER,      // WebRTC answer
    WS_MSG_RTC_ICE,         // WebRTC ICE candidate
    WS_MSG_PING,
    WS_MSG_UNKNOWN
} ws_message_type_t;

// Client info structure
typedef struct {
    int fd;                 // Socket file descriptor
    char id[16];           // Client-assigned ID
    bool active;
} ws_client_t;

// Register WebSocket handler with HTTP server
esp_err_t ws_server_register(httpd_handle_t server);

// Send text message to a specific client
esp_err_t ws_send_text(httpd_handle_t server, int fd, const char *message, size_t len);

// Broadcast text message to all connected clients (except sender)
void ws_broadcast_text(httpd_handle_t server, const char *message, size_t len);

// Broadcast text message to all connected clients including sender
void ws_broadcast_all(httpd_handle_t server, const char *message, size_t len);

// Send message to a specific client by ID
esp_err_t ws_send_to_client(httpd_handle_t server, const char *client_id, const char *message, size_t len);

// Parse incoming message type
ws_message_type_t ws_parse_message_type(const char *data, size_t len);

// Get number of connected clients
int ws_get_client_count(void);

#ifdef CONFIG_GEOGRAM_MESH_ENABLED
// Handle file request from mesh network (called by mesh data callback)
void ws_handle_mesh_file_request(const uint8_t *src_mac, const void *data, size_t len);
#endif

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_WS_SERVER_H
