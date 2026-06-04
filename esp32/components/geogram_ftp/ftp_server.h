/**
 * @file ftp_server.h
 * @brief FTP server for SD card file management
 *
 * Provides FTP access to the SD card for remote file upload/download.
 * Authentication follows device config - if password is set in NVS,
 * it's required; otherwise anonymous access is allowed.
 */

#ifndef FTP_SERVER_H
#define FTP_SERVER_H

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define FTP_DEFAULT_PORT    21
#define FTP_DEFAULT_USER    "geogram"

/**
 * @brief Start the FTP server
 *
 * Starts FTP server on specified port, serving the /sdcard directory.
 * Requires SD card to be mounted.
 *
 * @param port TCP port to listen on (use FTP_DEFAULT_PORT for 21)
 * @return ESP_OK on success
 */
esp_err_t ftp_server_start(uint16_t port);

/**
 * @brief Stop the FTP server
 */
void ftp_server_stop(void);

/**
 * @brief Check if FTP server is running
 *
 * @return true if server is running
 */
bool ftp_server_is_running(void);

/**
 * @brief Get the FTP server port
 *
 * @return Port number, or 0 if not running
 */
uint16_t ftp_server_get_port(void);

/**
 * @brief Check if a client is currently connected
 *
 * @return true if a client is connected
 */
bool ftp_server_is_client_connected(void);

/**
 * @brief Get connected client IP address
 *
 * @param ip_str Buffer to store IP string (at least 16 bytes)
 * @return ESP_OK if client connected, ESP_ERR_NOT_FOUND otherwise
 */
esp_err_t ftp_server_get_client_ip(char *ip_str);

#ifdef __cplusplus
}
#endif

#endif // FTP_SERVER_H
