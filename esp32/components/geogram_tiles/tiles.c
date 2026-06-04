/**
 * @file tiles.c
 * @brief Tile cache manager implementation
 */

#include "sdkconfig.h"

#if CONFIG_GEOGRAM_BOARD_EPAPER_1IN54

#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <dirent.h>
#include "tiles.h"
#include "sdcard.h"
#include "esp_log.h"
#include "http_client_async.h"

static const char *TAG = "tiles";

// Tile storage paths
#define TILES_BASE_PATH     "/sdcard/tiles"
#define TILES_STANDARD_PATH "/sdcard/tiles/standard"
#define TILES_SATELLITE_PATH "/sdcard/tiles/satellite"

// Tile sources
#define OSM_TILE_URL_FMT    "https://tile.openstreetmap.org/%d/%d/%d.png"
#define ESRI_TILE_URL_FMT   "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/%d/%d/%d"

// Max tile size (PNG tiles are typically 10-50KB)
#define MAX_TILE_SIZE       (128 * 1024)

// HTTP timeout
#define HTTP_TIMEOUT_MS     15000

// Cache statistics
static tile_cache_stats_t s_stats = {0};
static bool s_initialized = false;

/**
 * @brief Create directory recursively
 */
static esp_err_t mkdir_recursive(const char *path)
{
    char tmp[256];
    char *p = NULL;
    size_t len;

    snprintf(tmp, sizeof(tmp), "%s", path);
    len = strlen(tmp);
    if (tmp[len - 1] == '/') {
        tmp[len - 1] = 0;
    }

    for (p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            struct stat st;
            if (stat(tmp, &st) != 0) {
                if (mkdir(tmp, 0755) != 0) {
                    ESP_LOGE(TAG, "Failed to create dir: %s", tmp);
                    return ESP_FAIL;
                }
            }
            *p = '/';
        }
    }

    struct stat st;
    if (stat(tmp, &st) != 0) {
        if (mkdir(tmp, 0755) != 0) {
            ESP_LOGE(TAG, "Failed to create dir: %s", tmp);
            return ESP_FAIL;
        }
    }

    return ESP_OK;
}

/**
 * @brief Build path to cached tile
 */
static void build_tile_path(char *path, size_t path_size, int z, int x, int y, tile_layer_t layer)
{
    const char *layer_path = (layer == TILE_LAYER_SATELLITE) ? TILES_SATELLITE_PATH : TILES_STANDARD_PATH;
    snprintf(path, path_size, "%s/%d/%d/%d.png", layer_path, z, x, y);
}

/**
 * @brief Build directory path for tile
 */
static void build_tile_dir(char *path, size_t path_size, int z, int x, tile_layer_t layer)
{
    const char *layer_path = (layer == TILE_LAYER_SATELLITE) ? TILES_SATELLITE_PATH : TILES_STANDARD_PATH;
    snprintf(path, path_size, "%s/%d/%d", layer_path, z, x);
}

/**
 * @brief Build URL to download tile
 */
static void build_tile_url(char *url, size_t url_size, int z, int x, int y, tile_layer_t layer)
{
    if (layer == TILE_LAYER_SATELLITE) {
        // Esri uses z/y/x order
        snprintf(url, url_size, ESRI_TILE_URL_FMT, z, y, x);
    } else {
        // OSM uses z/x/y order
        snprintf(url, url_size, OSM_TILE_URL_FMT, z, x, y);
    }
}

/**
 * @brief Check if tile exists in cache
 */
static bool tile_exists(int z, int x, int y, tile_layer_t layer)
{
    char path[256];
    build_tile_path(path, sizeof(path), z, x, y, layer);
    return sdcard_file_exists(path);
}

/**
 * @brief Read tile from cache
 */
static esp_err_t tile_read_cache(int z, int x, int y, tile_layer_t layer,
                                  uint8_t *buffer, size_t buffer_size, size_t *tile_size)
{
    char path[256];
    build_tile_path(path, sizeof(path), z, x, y, layer);

    esp_err_t ret = sdcard_read_file(path, buffer, buffer_size, tile_size);
    if (ret == ESP_OK) {
        s_stats.cache_hits++;
        ESP_LOGD(TAG, "Cache hit: %s (%zu bytes)", path, *tile_size);
    }
    return ret;
}

/**
 * @brief Download tile from remote server (uses async HTTP client for TLS stack)
 */
static esp_err_t tile_download(int z, int x, int y, tile_layer_t layer,
                                uint8_t *buffer, size_t buffer_size, size_t *tile_size)
{
    char url[256];
    build_tile_url(url, sizeof(url), z, x, y, layer);

    ESP_LOGI(TAG, "Downloading tile: %s", url);

    http_client_request_t request = http_client_default_config();
    request.url = url;
    request.timeout_ms = HTTP_TIMEOUT_MS;
    request.user_agent = "Geogram-ESP32/1.0";

    http_client_response_t response = {
        .data = buffer,
        .buffer_size = buffer_size,
        .data_len = 0,
        .status_code = 0,
    };

    esp_err_t ret = http_client_get_async(&request, &response);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to download tile: %s", esp_err_to_name(ret));
        s_stats.download_errors++;
        return ret;
    }

    if (response.status_code != 200) {
        ESP_LOGE(TAG, "HTTP error %d for %s", response.status_code, url);
        s_stats.download_errors++;
        return ESP_FAIL;
    }

    *tile_size = response.data_len;
    s_stats.cache_misses++;

    ESP_LOGI(TAG, "Downloaded tile: z=%d x=%d y=%d (%zu bytes)", z, x, y, *tile_size);
    return ESP_OK;
}

/**
 * @brief Save tile to cache
 */
static esp_err_t tile_save_cache(int z, int x, int y, tile_layer_t layer,
                                  const uint8_t *buffer, size_t tile_size)
{
    // Create directory structure
    char dir_path[256];
    build_tile_dir(dir_path, sizeof(dir_path), z, x, layer);

    esp_err_t ret = mkdir_recursive(dir_path);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Failed to create tile directory: %s", dir_path);
        return ret;
    }

    // Write tile file
    char file_path[256];
    build_tile_path(file_path, sizeof(file_path), z, x, y, layer);

    ret = sdcard_write_file(file_path, buffer, tile_size);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Failed to save tile: %s", file_path);
        return ret;
    }

    s_stats.total_tiles++;
    s_stats.cache_size_bytes += tile_size;

    ESP_LOGD(TAG, "Cached tile: %s", file_path);
    return ESP_OK;
}

esp_err_t tiles_init(void)
{
    if (s_initialized) {
        return ESP_OK;
    }

    if (!sdcard_is_mounted()) {
        ESP_LOGW(TAG, "SD card not mounted - tile server unavailable");
        return ESP_ERR_INVALID_STATE;
    }

    // Create base directories
    esp_err_t ret = mkdir_recursive(TILES_STANDARD_PATH);
    if (ret != ESP_OK) {
        return ret;
    }

    ret = mkdir_recursive(TILES_SATELLITE_PATH);
    if (ret != ESP_OK) {
        return ret;
    }

    s_initialized = true;
    ESP_LOGI(TAG, "Tile cache initialized at %s", TILES_BASE_PATH);
    return ESP_OK;
}

bool tiles_is_available(void)
{
    return s_initialized && sdcard_is_mounted();
}

esp_err_t tiles_get(int z, int x, int y, tile_layer_t layer,
                    uint8_t *buffer, size_t buffer_size, size_t *tile_size)
{
    if (!s_initialized) {
        return ESP_ERR_INVALID_STATE;
    }

    if (buffer == NULL || buffer_size == 0 || tile_size == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    // Validate zoom level
    if (z < 0 || z > 18) {
        ESP_LOGW(TAG, "Invalid zoom level: %d", z);
        return ESP_ERR_INVALID_ARG;
    }

    // Check cache first
    if (tile_exists(z, x, y, layer)) {
        return tile_read_cache(z, x, y, layer, buffer, buffer_size, tile_size);
    }

    // Download from remote (uses async HTTP client internally for TLS stack)
    esp_err_t ret = tile_download(z, x, y, layer, buffer, buffer_size, tile_size);
    if (ret != ESP_OK) {
        return ret;
    }

    // Save to cache (ignore errors - tile can still be served)
    tile_save_cache(z, x, y, layer, buffer, *tile_size);

    return ESP_OK;
}

esp_err_t tiles_get_stats(tile_cache_stats_t *stats)
{
    if (stats == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    memcpy(stats, &s_stats, sizeof(tile_cache_stats_t));
    return ESP_OK;
}

uint32_t tiles_get_cache_size(void)
{
    return s_stats.cache_size_bytes;
}

uint32_t tiles_get_cache_count(void)
{
    return s_stats.total_tiles;
}

esp_err_t tiles_clear_cache(void)
{
    // TODO: Implement recursive directory deletion
    ESP_LOGW(TAG, "Cache clear not implemented");
    return ESP_ERR_NOT_SUPPORTED;
}

// HTTP handler for /tiles/{z}/{x}/{y}.png
static esp_err_t tiles_http_handler(httpd_req_t *req)
{
    if (!tiles_is_available()) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Tile server not available");
        return ESP_FAIL;
    }

    // Parse URI: /tiles/{z}/{x}/{y}.png
    char uri[128];
    strlcpy(uri, req->uri, sizeof(uri));

    // Remove query string if present
    char *query = strchr(uri, '?');
    if (query) {
        *query = '\0';
    }

    int z, x, y;
    if (sscanf(uri, "/tiles/%d/%d/%d.png", &z, &x, &y) != 3) {
        ESP_LOGW(TAG, "Invalid tile URI: %s", req->uri);
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid tile path");
        return ESP_FAIL;
    }

    // Parse layer from query parameter
    tile_layer_t layer = TILE_LAYER_STANDARD;
    char layer_param[32] = {0};
    if (httpd_req_get_url_query_str(req, layer_param, sizeof(layer_param)) == ESP_OK) {
        char layer_value[16] = {0};
        if (httpd_query_key_value(layer_param, "layer", layer_value, sizeof(layer_value)) == ESP_OK) {
            if (strcmp(layer_value, "satellite") == 0) {
                layer = TILE_LAYER_SATELLITE;
            }
        }
    }

    ESP_LOGI(TAG, "Tile request: z=%d x=%d y=%d layer=%s",
             z, x, y, layer == TILE_LAYER_SATELLITE ? "satellite" : "standard");

    // Allocate buffer for tile data
    uint8_t *tile_buffer = malloc(MAX_TILE_SIZE);
    if (tile_buffer == NULL) {
        ESP_LOGE(TAG, "Failed to allocate tile buffer");
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Memory allocation failed");
        return ESP_FAIL;
    }

    size_t tile_size = 0;
    esp_err_t ret = tiles_get(z, x, y, layer, tile_buffer, MAX_TILE_SIZE, &tile_size);

    if (ret != ESP_OK) {
        free(tile_buffer);
        if (ret == ESP_ERR_INVALID_ARG) {
            httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid tile coordinates");
        } else {
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Failed to get tile");
        }
        return ESP_FAIL;
    }

    // Send tile
    httpd_resp_set_type(req, "image/png");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_hdr(req, "Cache-Control", "public, max-age=86400");
    httpd_resp_send(req, (char *)tile_buffer, tile_size);

    free(tile_buffer);
    return ESP_OK;
}

// URI handler definition
static const httpd_uri_t tiles_uri = {
    .uri = "/tiles/*",
    .method = HTTP_GET,
    .handler = tiles_http_handler,
    .user_ctx = NULL
};

esp_err_t tiles_register_http_handler(httpd_handle_t server)
{
    if (server == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    if (!tiles_is_available()) {
        ESP_LOGW(TAG, "Tile server not available - not registering handler");
        return ESP_ERR_INVALID_STATE;
    }

    esp_err_t ret = httpd_register_uri_handler(server, &tiles_uri);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to register tile handler: %s", esp_err_to_name(ret));
        return ret;
    }

    ESP_LOGI(TAG, "Tile HTTP handler registered at /tiles/*");
    return ESP_OK;
}

#else // !CONFIG_GEOGRAM_BOARD_EPAPER_1IN54

// Stubs for boards without SD card
#include "tiles.h"

esp_err_t tiles_init(void) { return ESP_ERR_NOT_SUPPORTED; }
bool tiles_is_available(void) { return false; }
esp_err_t tiles_get(int z, int x, int y, tile_layer_t layer,
                    uint8_t *buffer, size_t buffer_size, size_t *tile_size) { return ESP_ERR_NOT_SUPPORTED; }
esp_err_t tiles_register_http_handler(httpd_handle_t server) { return ESP_ERR_NOT_SUPPORTED; }
esp_err_t tiles_get_stats(tile_cache_stats_t *stats) { return ESP_ERR_NOT_SUPPORTED; }
esp_err_t tiles_clear_cache(void) { return ESP_ERR_NOT_SUPPORTED; }
uint32_t tiles_get_cache_size(void) { return 0; }
uint32_t tiles_get_cache_count(void) { return 0; }

#endif // CONFIG_GEOGRAM_BOARD_EPAPER_1IN54
