/**
 * @file dns_server.h
 * @brief Simple DNS server for captive portal
 *
 * Responds to DNS queries with the AP's IP address.
 * This enables accessing the device via hostname when connected to its AP.
 */

#ifndef GEOGRAM_DNS_SERVER_H
#define GEOGRAM_DNS_SERVER_H

#include "esp_err.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DNS_SERVER_PORT 53

/**
 * @brief Start the DNS server
 *
 * @param ap_ip The IP address to return for all DNS queries (typically AP IP)
 * @return ESP_OK on success
 */
esp_err_t dns_server_start(uint32_t ap_ip);

/**
 * @brief Stop the DNS server
 *
 * @return ESP_OK on success
 */
esp_err_t dns_server_stop(void);

/**
 * @brief Check if DNS server is running
 *
 * @return true if running
 */
bool dns_server_is_running(void);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_DNS_SERVER_H
