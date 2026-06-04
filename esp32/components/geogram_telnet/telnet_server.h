/**
 * @file telnet_server.h
 * @brief Telnet server for remote CLI access
 *
 * Provides network access to the Geogram CLI via Telnet protocol.
 * Connects to the same command infrastructure as the serial console.
 */

#ifndef GEOGRAM_TELNET_SERVER_H
#define GEOGRAM_TELNET_SERVER_H

#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define TELNET_DEFAULT_PORT 23

/**
 * @brief Start the Telnet server
 *
 * Starts listening for Telnet connections on the specified port.
 * Only one client can be connected at a time.
 *
 * @param port TCP port to listen on (use TELNET_DEFAULT_PORT for 23)
 * @return ESP_OK on success
 */
esp_err_t telnet_server_start(uint16_t port);

/**
 * @brief Stop the Telnet server
 *
 * Closes any active connections and stops listening.
 *
 * @return ESP_OK on success
 */
esp_err_t telnet_server_stop(void);

/**
 * @brief Check if Telnet server is running
 *
 * @return true if server is listening
 */
bool telnet_server_is_running(void);

/**
 * @brief Check if a client is connected
 *
 * @return true if a client is currently connected
 */
bool telnet_server_client_connected(void);

/**
 * @brief Get the connected client's IP address
 *
 * @param ip_str Buffer to store IP string (at least 16 bytes)
 * @return ESP_OK if client connected and IP retrieved
 */
esp_err_t telnet_server_get_client_ip(char *ip_str);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_TELNET_SERVER_H
