/**
 * @file http_client_async.h
 * @brief Async HTTP client for ESP32 - runs requests in separate task with adequate TLS stack
 *
 * ESP-IDF's HTTP client with TLS requires a larger stack than the default httpd task provides.
 * This wrapper runs HTTP requests in a dedicated task with sufficient stack for TLS operations.
 */

#pragma once

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief HTTP request configuration
 */
typedef struct {
    const char *url;            /**< Request URL (required) */
    const char *user_agent;     /**< User agent string (optional, defaults to "ESP32-HTTP/1.0") */
    int timeout_ms;             /**< Request timeout in ms (optional, defaults to 15000) */
    bool skip_cert_verify;      /**< Skip TLS certificate verification (default: true for simplicity) */
} http_client_request_t;

/**
 * @brief HTTP response structure
 */
typedef struct {
    int status_code;            /**< HTTP status code (e.g., 200, 404, 500) */
    uint8_t *data;              /**< Response data (caller must provide buffer) */
    size_t data_len;            /**< Actual length of response data */
    size_t buffer_size;         /**< Size of provided buffer */
} http_client_response_t;

/**
 * @brief Perform HTTP GET request asynchronously (in separate task)
 *
 * This function spawns a temporary task with adequate stack for TLS operations,
 * performs the HTTP request, and returns the response. The caller blocks until
 * the request completes or times out.
 *
 * @param request Request configuration
 * @param response Response buffer (caller provides data buffer)
 * @return ESP_OK on success, ESP_FAIL on HTTP error, ESP_ERR_TIMEOUT on timeout
 */
esp_err_t http_client_get_async(const http_client_request_t *request, http_client_response_t *response);

/**
 * @brief Get default request configuration
 *
 * @return Default request config with sensible defaults
 */
http_client_request_t http_client_default_config(void);

#ifdef __cplusplus
}
#endif
