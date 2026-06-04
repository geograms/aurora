/**
 * @file geogram_ssh.h
 * @brief SSH server wrapper for Geogram ESP32
 *
 * Provides SSH access to the CLI with optional password authentication.
 * By default, passwordless login is allowed. Users can set a password
 * via the CLI which is stored in NVS.
 */

#ifndef GEOGRAM_SSH_H
#define GEOGRAM_SSH_H

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define GEOGRAM_SSH_DEFAULT_PORT 22

/**
 * @brief Start the SSH server
 *
 * Starts the SSH server on the specified port. If no host key exists,
 * one will be generated and stored in NVS.
 *
 * @param port TCP port to listen on (use GEOGRAM_SSH_DEFAULT_PORT for 22)
 * @return ESP_OK on success
 */
esp_err_t geogram_ssh_start(uint16_t port);

/**
 * @brief Stop the SSH server
 *
 * @return ESP_OK on success
 */
esp_err_t geogram_ssh_stop(void);

/**
 * @brief Check if SSH server is running
 *
 * @return true if server is running
 */
bool geogram_ssh_is_running(void);

/**
 * @brief Set SSH password
 *
 * Sets a password for SSH authentication. The password is stored in NVS
 * and persists across reboots. Set to empty string or NULL to allow
 * passwordless login.
 *
 * @param password Password string (or NULL/empty for passwordless)
 * @return ESP_OK on success
 */
esp_err_t geogram_ssh_set_password(const char *password);

/**
 * @brief Clear SSH password (enable passwordless login)
 *
 * @return ESP_OK on success
 */
esp_err_t geogram_ssh_clear_password(void);

/**
 * @brief Check if password is set
 *
 * @return true if a password is configured
 */
bool geogram_ssh_has_password(void);

/**
 * @brief Get the SSH server port
 *
 * @return Port number, or 0 if not running
 */
uint16_t geogram_ssh_get_port(void);

/**
 * @brief Get the host key fingerprint
 *
 * Returns the SHA256 fingerprint of the host key for verification.
 *
 * @param fingerprint Buffer to store fingerprint string (at least 64 bytes)
 * @return ESP_OK on success
 */
esp_err_t geogram_ssh_get_fingerprint(char *fingerprint);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_SSH_H
