/**
 * @file http_server.h
 * @brief HTTP server for WiFi configuration and Geogram Station API
 */

#ifndef HTTP_SERVER_H
#define HTTP_SERVER_H

#include "esp_err.h"
#include "esp_http_server.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief WiFi credentials received callback
 *
 * @param ssid SSID to connect to
 * @param password WiFi password
 */
typedef void (*wifi_config_callback_t)(const char *ssid, const char *password);

/**
 * @brief Start the HTTP configuration server
 *
 * Starts an HTTP server that serves a WiFi configuration page.
 *
 * @param callback Callback to invoke when WiFi credentials are submitted
 * @return esp_err_t ESP_OK on success
 */
esp_err_t http_server_start(wifi_config_callback_t callback);

/**
 * @brief Start the HTTP server with Station API endpoints
 *
 * Starts an HTTP server with:
 * - WiFi configuration endpoints (/, /connect)
 * - Station API endpoints (/api/status)
 * - WebSocket endpoint (/ws)
 *
 * @param callback Callback to invoke when WiFi credentials are submitted (can be NULL)
 * @param enable_station_api Enable Station API and WebSocket endpoints
 * @return esp_err_t ESP_OK on success
 */
esp_err_t http_server_start_ex(wifi_config_callback_t callback, bool enable_station_api);

/**
 * @brief Stop the HTTP configuration server
 *
 * @return esp_err_t ESP_OK on success
 */
esp_err_t http_server_stop(void);

/**
 * @brief Check if HTTP server is running
 *
 * @return true if server is running
 */
bool http_server_is_running(void);

/**
 * @brief Get the HTTP server handle
 *
 * @return httpd_handle_t Server handle or NULL if not running
 */
httpd_handle_t http_server_get_handle(void);

#ifdef __cplusplus
}
#endif

#endif // HTTP_SERVER_H
