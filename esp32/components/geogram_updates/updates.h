/**
 * @file updates.h
 * @brief Update mirror service - fetches releases from GitHub and serves to clients
 *
 * This component allows the ESP32 station to act as an update mirror for Geogram clients.
 * It periodically fetches the latest release from GitHub and caches the binaries on SD card,
 * allowing clients to download updates directly from the station (offgrid-first approach).
 */

#pragma once

#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"
#include "esp_http_server.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Release asset types
 */
typedef enum {
    UPDATE_ASSET_ANDROID_APK,
    UPDATE_ASSET_ANDROID_AAB,
    UPDATE_ASSET_LINUX_DESKTOP,
    UPDATE_ASSET_LINUX_CLI,
    UPDATE_ASSET_WINDOWS_DESKTOP,
    UPDATE_ASSET_MACOS_DESKTOP,
    UPDATE_ASSET_IOS_UNSIGNED,
    UPDATE_ASSET_WEB,
    UPDATE_ASSET_UNKNOWN,
    UPDATE_ASSET_COUNT
} update_asset_type_t;

/**
 * @brief Release asset information
 */
typedef struct {
    char filename[64];          /**< Original filename from GitHub */
    char local_path[192];       /**< Local path on SD card */
    size_t size_bytes;          /**< File size in bytes */
    bool downloaded;            /**< Whether file is downloaded */
    update_asset_type_t type;   /**< Asset type */
} update_asset_t;

/**
 * @brief Cached release information
 */
typedef struct {
    char version[32];           /**< Version string (e.g., "1.6.24") */
    char tag_name[32];          /**< Git tag (e.g., "v1.6.24") */
    char name[128];             /**< Release name */
    char published_at[32];      /**< ISO8601 timestamp */
    char html_url[256];         /**< GitHub release URL */
    update_asset_t assets[UPDATE_ASSET_COUNT]; /**< Available assets */
    int asset_count;            /**< Number of assets */
    bool valid;                 /**< Whether release info is valid */
} update_release_t;

/**
 * @brief Update mirror statistics
 */
typedef struct {
    uint32_t checks_performed;      /**< Number of GitHub checks */
    uint32_t downloads_started;     /**< Number of downloads started */
    uint32_t downloads_completed;   /**< Number of downloads completed */
    uint32_t downloads_failed;      /**< Number of downloads failed */
    uint32_t files_served;          /**< Number of files served to clients */
    uint64_t bytes_served;          /**< Total bytes served to clients */
} update_stats_t;

/**
 * @brief Initialize the update mirror service
 *
 * Requires SD card to be mounted. Creates /sdcard/updates directory.
 *
 * @return ESP_OK on success
 */
esp_err_t updates_init(void);

/**
 * @brief Check if update service is available
 *
 * @return true if initialized and SD card is available
 */
bool updates_is_available(void);

/**
 * @brief Check for new release from GitHub
 *
 * Downloads release metadata from GitHub API. If a new version is found,
 * triggers background download of binaries.
 *
 * @return ESP_OK on success, ESP_ERR_NOT_FOUND if no new version
 */
esp_err_t updates_check_github(void);

/**
 * @brief Start background update polling
 *
 * Starts a task that periodically checks GitHub for new releases
 * and downloads binaries in the background.
 *
 * @param interval_seconds Polling interval (minimum 60 seconds)
 * @return ESP_OK on success
 */
esp_err_t updates_start_polling(int interval_seconds);

/**
 * @brief Stop background update polling
 */
void updates_stop_polling(void);

/**
 * @brief Get cached release information
 *
 * @param release Pointer to receive release info (can be NULL to just check validity)
 * @return ESP_OK if release is cached, ESP_ERR_NOT_FOUND if no cache
 */
esp_err_t updates_get_release(update_release_t *release);

/**
 * @brief Get update service statistics
 *
 * @param stats Pointer to receive statistics
 * @return ESP_OK on success
 */
esp_err_t updates_get_stats(update_stats_t *stats);

/**
 * @brief Build JSON response for /api/updates/latest
 *
 * @param buffer Output buffer
 * @param buffer_size Buffer size
 * @return Number of bytes written
 */
size_t updates_build_latest_json(char *buffer, size_t buffer_size);

/**
 * @brief Register HTTP handlers for update endpoints
 *
 * Registers:
 * - GET /api/updates/latest - Returns cached release info
 * - GET /updates/{version}/{filename} - Serves binary files
 *
 * @param server HTTP server handle
 * @return ESP_OK on success
 */
esp_err_t updates_register_http_handlers(httpd_handle_t server);

/**
 * @brief Get asset type from filename
 *
 * @param filename Asset filename
 * @return Asset type enum
 */
update_asset_type_t updates_asset_type_from_filename(const char *filename);

/**
 * @brief Get asset type string for JSON
 *
 * @param type Asset type
 * @return String like "android-apk", "linux-desktop", etc.
 */
const char *updates_asset_type_to_string(update_asset_type_t type);

#ifdef __cplusplus
}
#endif
