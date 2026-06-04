/**
 * @file tiles.h
 * @brief Tile cache manager for Geogram Station
 *
 * Provides tile caching functionality:
 * - Stores tiles on SD card at /sdcard/tiles/{layer}/{z}/{x}/{y}.png
 * - Downloads tiles from OSM (standard) or Esri (satellite)
 * - Serves tiles via HTTP API
 */

#ifndef GEOGRAM_TILES_H
#define GEOGRAM_TILES_H

#include "esp_err.h"
#include "esp_http_server.h"
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Tile layer type
 */
typedef enum {
    TILE_LAYER_STANDARD,    // OpenStreetMap tiles
    TILE_LAYER_SATELLITE    // Esri satellite imagery
} tile_layer_t;

/**
 * @brief Tile cache statistics
 */
typedef struct {
    uint32_t cache_hits;        // Tiles served from cache
    uint32_t cache_misses;      // Tiles fetched from remote
    uint32_t download_errors;   // Failed downloads
    uint32_t total_tiles;       // Total tiles in cache (estimated)
    uint32_t cache_size_bytes;  // Total cache size in bytes (estimated)
} tile_cache_stats_t;

/**
 * @brief Initialize tile cache
 *
 * Creates necessary directories on SD card.
 * Must be called after sdcard_init().
 *
 * @return ESP_OK on success, error if SD card not available
 */
esp_err_t tiles_init(void);

/**
 * @brief Check if tile server is available
 *
 * @return true if SD card is mounted and tile directories exist
 */
bool tiles_is_available(void);

/**
 * @brief Get a tile from cache or download it
 *
 * @param z Zoom level (0-18)
 * @param x X tile coordinate
 * @param y Y tile coordinate
 * @param layer Tile layer (standard or satellite)
 * @param buffer Buffer to store tile data
 * @param buffer_size Size of buffer
 * @param tile_size Actual tile size returned
 * @return ESP_OK on success
 */
esp_err_t tiles_get(int z, int x, int y, tile_layer_t layer,
                    uint8_t *buffer, size_t buffer_size, size_t *tile_size);

/**
 * @brief Register tile HTTP endpoint with server
 *
 * Registers handler for /tiles/{z}/{x}/{y}.png
 * Supports ?layer=standard|satellite query parameter
 *
 * @param server HTTP server handle
 * @return ESP_OK on success
 */
esp_err_t tiles_register_http_handler(httpd_handle_t server);

/**
 * @brief Get tile cache statistics
 *
 * @param stats Pointer to stats structure to fill
 * @return ESP_OK on success
 */
esp_err_t tiles_get_stats(tile_cache_stats_t *stats);

/**
 * @brief Clear tile cache
 *
 * Removes all cached tiles from SD card.
 *
 * @return ESP_OK on success
 */
esp_err_t tiles_clear_cache(void);

/**
 * @brief Get estimated cache size in bytes
 *
 * @return Cache size in bytes
 */
uint32_t tiles_get_cache_size(void);

/**
 * @brief Get estimated tile count
 *
 * @return Number of cached tiles
 */
uint32_t tiles_get_cache_count(void);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_TILES_H
