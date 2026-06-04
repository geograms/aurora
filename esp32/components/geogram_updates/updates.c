/**
 * @file updates.c
 * @brief Update mirror service implementation
 */

#include "sdkconfig.h"

#if CONFIG_GEOGRAM_BOARD_EPAPER_1IN54

#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <dirent.h>
#include "updates.h"
#include "sdcard.h"
#include "http_client_async.h"
#include "json_utils.h"
#include "esp_log.h"
#include "cJSON.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "updates";

// GitHub API endpoint for latest release
#define GITHUB_API_URL "https://api.github.com/repos/geograms/geogram-desktop/releases/latest"

// Storage paths
#define UPDATES_BASE_PATH   "/sdcard/updates"
#define RELEASE_JSON_PATH   "/sdcard/updates/release.json"

// Download buffer size
#define DOWNLOAD_BUFFER_SIZE    (64 * 1024)

// Max response size for GitHub API
#define API_RESPONSE_SIZE       (24 * 1024)

// Polling task
static TaskHandle_t s_poll_task = NULL;
static int s_poll_interval = 0;
static bool s_polling_active = false;

// Cached release
static update_release_t s_release = {0};
static bool s_initialized = false;

// Statistics
static update_stats_t s_stats = {0};

/**
 * @brief Get asset type from filename
 */
update_asset_type_t updates_asset_type_from_filename(const char *filename)
{
    if (filename == NULL) return UPDATE_ASSET_UNKNOWN;

    if (strstr(filename, ".apk") != NULL) {
        return UPDATE_ASSET_ANDROID_APK;
    } else if (strstr(filename, ".aab") != NULL) {
        return UPDATE_ASSET_ANDROID_AAB;
    } else if (strstr(filename, "linux") != NULL && strstr(filename, ".tar.gz") != NULL) {
        if (strstr(filename, "cli") != NULL) {
            return UPDATE_ASSET_LINUX_CLI;
        }
        return UPDATE_ASSET_LINUX_DESKTOP;
    } else if (strstr(filename, "windows") != NULL || strstr(filename, ".exe") != NULL ||
               (strstr(filename, ".zip") != NULL && strstr(filename, "win") != NULL)) {
        return UPDATE_ASSET_WINDOWS_DESKTOP;
    } else if (strstr(filename, "macos") != NULL || strstr(filename, "darwin") != NULL ||
               strstr(filename, ".dmg") != NULL) {
        return UPDATE_ASSET_MACOS_DESKTOP;
    } else if (strstr(filename, ".ipa") != NULL) {
        return UPDATE_ASSET_IOS_UNSIGNED;
    } else if (strstr(filename, "web") != NULL) {
        return UPDATE_ASSET_WEB;
    }

    return UPDATE_ASSET_UNKNOWN;
}

/**
 * @brief Get asset type string
 */
const char *updates_asset_type_to_string(update_asset_type_t type)
{
    switch (type) {
        case UPDATE_ASSET_ANDROID_APK:    return "android-apk";
        case UPDATE_ASSET_ANDROID_AAB:    return "android-aab";
        case UPDATE_ASSET_LINUX_DESKTOP:  return "linux-desktop";
        case UPDATE_ASSET_LINUX_CLI:      return "linux-cli";
        case UPDATE_ASSET_WINDOWS_DESKTOP: return "windows-desktop";
        case UPDATE_ASSET_MACOS_DESKTOP:  return "macos-desktop";
        case UPDATE_ASSET_IOS_UNSIGNED:   return "ios-unsigned";
        case UPDATE_ASSET_WEB:            return "web";
        default:                          return "unknown";
    }
}

/**
 * @brief Create directory if not exists
 */
static esp_err_t ensure_dir(const char *path)
{
    struct stat st;
    if (stat(path, &st) == 0) {
        return ESP_OK;
    }
    if (mkdir(path, 0755) != 0) {
        ESP_LOGE(TAG, "Failed to create directory: %s", path);
        return ESP_FAIL;
    }
    return ESP_OK;
}

/**
 * @brief Save release info to JSON file
 */
static esp_err_t save_release_json(const update_release_t *release)
{
    cJSON *root = cJSON_CreateObject();
    if (root == NULL) return ESP_ERR_NO_MEM;

    cJSON_AddStringToObject(root, "version", release->version);
    cJSON_AddStringToObject(root, "tagName", release->tag_name);
    cJSON_AddStringToObject(root, "name", release->name);
    cJSON_AddStringToObject(root, "publishedAt", release->published_at);
    cJSON_AddStringToObject(root, "htmlUrl", release->html_url);

    cJSON *assets = cJSON_CreateArray();
    for (int i = 0; i < release->asset_count; i++) {
        cJSON *asset = cJSON_CreateObject();
        cJSON_AddStringToObject(asset, "filename", release->assets[i].filename);
        cJSON_AddStringToObject(asset, "localPath", release->assets[i].local_path);
        cJSON_AddNumberToObject(asset, "sizeBytes", release->assets[i].size_bytes);
        cJSON_AddBoolToObject(asset, "downloaded", release->assets[i].downloaded);
        cJSON_AddNumberToObject(asset, "type", release->assets[i].type);
        cJSON_AddItemToArray(assets, asset);
    }
    cJSON_AddItemToObject(root, "assets", assets);

    char *json_str = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);

    if (json_str == NULL) return ESP_ERR_NO_MEM;

    esp_err_t ret = sdcard_write_file(RELEASE_JSON_PATH, (uint8_t *)json_str, strlen(json_str));
    free(json_str);

    return ret;
}

/**
 * @brief Load release info from JSON file
 */
static esp_err_t load_release_json(update_release_t *release)
{
    uint8_t *buffer = malloc(API_RESPONSE_SIZE);
    if (buffer == NULL) return ESP_ERR_NO_MEM;

    size_t len = 0;
    esp_err_t ret = sdcard_read_file(RELEASE_JSON_PATH, buffer, API_RESPONSE_SIZE - 1, &len);
    if (ret != ESP_OK) {
        free(buffer);
        return ret;
    }
    buffer[len] = '\0';

    cJSON *root = cJSON_Parse((char *)buffer);
    free(buffer);

    if (root == NULL) {
        ESP_LOGE(TAG, "Failed to parse release.json");
        return ESP_FAIL;
    }

    memset(release, 0, sizeof(update_release_t));

    cJSON *item;
    if ((item = cJSON_GetObjectItem(root, "version")) && cJSON_IsString(item)) {
        strlcpy(release->version, item->valuestring, sizeof(release->version));
    }
    if ((item = cJSON_GetObjectItem(root, "tagName")) && cJSON_IsString(item)) {
        strlcpy(release->tag_name, item->valuestring, sizeof(release->tag_name));
    }
    if ((item = cJSON_GetObjectItem(root, "name")) && cJSON_IsString(item)) {
        strlcpy(release->name, item->valuestring, sizeof(release->name));
    }
    if ((item = cJSON_GetObjectItem(root, "publishedAt")) && cJSON_IsString(item)) {
        strlcpy(release->published_at, item->valuestring, sizeof(release->published_at));
    }
    if ((item = cJSON_GetObjectItem(root, "htmlUrl")) && cJSON_IsString(item)) {
        strlcpy(release->html_url, item->valuestring, sizeof(release->html_url));
    }

    cJSON *assets = cJSON_GetObjectItem(root, "assets");
    if (assets && cJSON_IsArray(assets)) {
        int count = cJSON_GetArraySize(assets);
        if (count > UPDATE_ASSET_COUNT) count = UPDATE_ASSET_COUNT;
        release->asset_count = count;

        for (int i = 0; i < count; i++) {
            cJSON *asset = cJSON_GetArrayItem(assets, i);
            if (asset) {
                if ((item = cJSON_GetObjectItem(asset, "filename")) && cJSON_IsString(item)) {
                    strlcpy(release->assets[i].filename, item->valuestring, sizeof(release->assets[i].filename));
                }
                if ((item = cJSON_GetObjectItem(asset, "localPath")) && cJSON_IsString(item)) {
                    strlcpy(release->assets[i].local_path, item->valuestring, sizeof(release->assets[i].local_path));
                }
                if ((item = cJSON_GetObjectItem(asset, "sizeBytes")) && cJSON_IsNumber(item)) {
                    release->assets[i].size_bytes = (size_t)item->valuedouble;
                }
                if ((item = cJSON_GetObjectItem(asset, "downloaded")) && cJSON_IsBool(item)) {
                    release->assets[i].downloaded = cJSON_IsTrue(item);
                }
                if ((item = cJSON_GetObjectItem(asset, "type")) && cJSON_IsNumber(item)) {
                    release->assets[i].type = (update_asset_type_t)item->valueint;
                }
            }
        }
    }

    release->valid = true;
    cJSON_Delete(root);

    ESP_LOGI(TAG, "Loaded cached release: %s", release->version);
    return ESP_OK;
}

/**
 * @brief Download a binary file from URL to SD card
 */
static esp_err_t download_binary(const char *url, const char *local_path, size_t *downloaded_size)
{
    ESP_LOGI(TAG, "Downloading: %s", url);

    uint8_t *buffer = malloc(DOWNLOAD_BUFFER_SIZE);
    if (buffer == NULL) {
        ESP_LOGE(TAG, "Failed to allocate download buffer");
        return ESP_ERR_NO_MEM;
    }

    http_client_request_t request = http_client_default_config();
    request.url = url;
    request.timeout_ms = 60000;  // 60 second timeout for large files
    request.user_agent = "Geogram-ESP32/1.0";

    http_client_response_t response = {
        .data = buffer,
        .buffer_size = DOWNLOAD_BUFFER_SIZE,
        .data_len = 0,
        .status_code = 0,
    };

    s_stats.downloads_started++;

    esp_err_t ret = http_client_get_async(&request, &response);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Download failed: %s", esp_err_to_name(ret));
        free(buffer);
        s_stats.downloads_failed++;
        return ret;
    }

    if (response.status_code != 200) {
        ESP_LOGE(TAG, "HTTP error %d", response.status_code);
        free(buffer);
        s_stats.downloads_failed++;
        return ESP_FAIL;
    }

    // Save to SD card
    ret = sdcard_write_file(local_path, buffer, response.data_len);
    free(buffer);

    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to save file: %s", local_path);
        s_stats.downloads_failed++;
        return ret;
    }

    *downloaded_size = response.data_len;
    s_stats.downloads_completed++;

    ESP_LOGI(TAG, "Downloaded %zu bytes to %s", response.data_len, local_path);
    return ESP_OK;
}

/**
 * @brief Parse GitHub release JSON and download assets
 */
static esp_err_t parse_and_download_release(const char *json_str)
{
    cJSON *root = cJSON_Parse(json_str);
    if (root == NULL) {
        ESP_LOGE(TAG, "Failed to parse GitHub API response");
        return ESP_FAIL;
    }

    update_release_t new_release = {0};

    // Parse version from tag_name (strip 'v' prefix)
    cJSON *tag_name = cJSON_GetObjectItem(root, "tag_name");
    if (tag_name && cJSON_IsString(tag_name)) {
        const char *tag = tag_name->valuestring;
        if (tag[0] == 'v') tag++;
        strlcpy(new_release.version, tag, sizeof(new_release.version));
        strlcpy(new_release.tag_name, tag_name->valuestring, sizeof(new_release.tag_name));
    }

    // Check if we already have this version
    if (s_release.valid && strcmp(s_release.version, new_release.version) == 0) {
        ESP_LOGI(TAG, "Already have version %s", new_release.version);
        cJSON_Delete(root);
        return ESP_ERR_NOT_FOUND;
    }

    ESP_LOGI(TAG, "New release found: %s", new_release.version);

    // Parse other fields
    cJSON *item;
    if ((item = cJSON_GetObjectItem(root, "name")) && cJSON_IsString(item)) {
        strlcpy(new_release.name, item->valuestring, sizeof(new_release.name));
    }
    if ((item = cJSON_GetObjectItem(root, "published_at")) && cJSON_IsString(item)) {
        strlcpy(new_release.published_at, item->valuestring, sizeof(new_release.published_at));
    }
    if ((item = cJSON_GetObjectItem(root, "html_url")) && cJSON_IsString(item)) {
        strlcpy(new_release.html_url, item->valuestring, sizeof(new_release.html_url));
    }

    // Create version directory
    char version_dir[128];
    snprintf(version_dir, sizeof(version_dir), "%s/%s", UPDATES_BASE_PATH, new_release.version);
    ensure_dir(version_dir);

    // Parse and download assets
    cJSON *assets = cJSON_GetObjectItem(root, "assets");
    if (assets && cJSON_IsArray(assets)) {
        int asset_idx = 0;
        cJSON *asset;
        cJSON_ArrayForEach(asset, assets) {
            if (asset_idx >= UPDATE_ASSET_COUNT) break;

            cJSON *name = cJSON_GetObjectItem(asset, "name");
            cJSON *download_url = cJSON_GetObjectItem(asset, "browser_download_url");
            cJSON *size = cJSON_GetObjectItem(asset, "size");

            if (name && cJSON_IsString(name) && download_url && cJSON_IsString(download_url)) {
                update_asset_type_t type = updates_asset_type_from_filename(name->valuestring);

                // Only download known asset types (APK is most important for mobile clients)
                if (type == UPDATE_ASSET_UNKNOWN) {
                    continue;
                }

                update_asset_t *a = &new_release.assets[asset_idx];
                strlcpy(a->filename, name->valuestring, sizeof(a->filename));
                // Use version_dir to avoid overlap warning
                snprintf(a->local_path, sizeof(a->local_path), "%s/%s",
                         version_dir, name->valuestring);
                a->type = type;
                a->size_bytes = size ? (size_t)size->valuedouble : 0;

                // Download the binary
                size_t downloaded = 0;
                if (download_binary(download_url->valuestring, a->local_path, &downloaded) == ESP_OK) {
                    a->downloaded = true;
                    a->size_bytes = downloaded;
                }

                asset_idx++;
            }
        }
        new_release.asset_count = asset_idx;
    }

    cJSON_Delete(root);

    // Save and cache the new release
    new_release.valid = true;
    memcpy(&s_release, &new_release, sizeof(update_release_t));
    save_release_json(&s_release);

    return ESP_OK;
}

esp_err_t updates_init(void)
{
    if (s_initialized) {
        return ESP_OK;
    }

    if (!sdcard_is_mounted()) {
        ESP_LOGW(TAG, "SD card not mounted - update mirror unavailable");
        return ESP_ERR_INVALID_STATE;
    }

    // Create updates directory
    esp_err_t ret = ensure_dir(UPDATES_BASE_PATH);
    if (ret != ESP_OK) {
        return ret;
    }

    // Try to load cached release
    if (load_release_json(&s_release) == ESP_OK) {
        ESP_LOGI(TAG, "Loaded cached release: %s (%d assets)",
                 s_release.version, s_release.asset_count);
    }

    s_initialized = true;
    ESP_LOGI(TAG, "Update mirror initialized at %s", UPDATES_BASE_PATH);
    return ESP_OK;
}

bool updates_is_available(void)
{
    return s_initialized && sdcard_is_mounted();
}

esp_err_t updates_check_github(void)
{
    if (!s_initialized) {
        return ESP_ERR_INVALID_STATE;
    }

    ESP_LOGI(TAG, "Checking GitHub for updates...");
    s_stats.checks_performed++;

    uint8_t *buffer = malloc(API_RESPONSE_SIZE);
    if (buffer == NULL) {
        return ESP_ERR_NO_MEM;
    }

    http_client_request_t request = http_client_default_config();
    request.url = GITHUB_API_URL;
    request.timeout_ms = 30000;
    request.user_agent = "Geogram-ESP32/1.0";

    http_client_response_t response = {
        .data = buffer,
        .buffer_size = API_RESPONSE_SIZE - 1,
        .data_len = 0,
        .status_code = 0,
    };

    esp_err_t ret = http_client_get_async(&request, &response);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "GitHub API request failed: %s", esp_err_to_name(ret));
        free(buffer);
        return ret;
    }

    if (response.status_code != 200) {
        ESP_LOGE(TAG, "GitHub API error: %d", response.status_code);
        free(buffer);
        return ESP_FAIL;
    }

    buffer[response.data_len] = '\0';
    ret = parse_and_download_release((char *)buffer);
    free(buffer);

    return ret;
}

/**
 * @brief Polling task
 */
static void poll_task(void *arg)
{
    // Initial delay before first check (1 minute after boot)
    ESP_LOGI(TAG, "First GitHub check in 60 seconds...");
    vTaskDelay(pdMS_TO_TICKS(60000));

    while (s_polling_active) {
        updates_check_github();

        // Wait for next poll interval
        for (int i = 0; i < s_poll_interval && s_polling_active; i++) {
            vTaskDelay(pdMS_TO_TICKS(1000));
        }
    }

    s_poll_task = NULL;
    vTaskDelete(NULL);
}

esp_err_t updates_start_polling(int interval_seconds)
{
    if (!s_initialized) {
        return ESP_ERR_INVALID_STATE;
    }

    if (s_poll_task != NULL) {
        ESP_LOGW(TAG, "Polling already active");
        return ESP_OK;
    }

    if (interval_seconds < 60) {
        interval_seconds = 60;  // Minimum 1 minute
    }

    s_poll_interval = interval_seconds;
    s_polling_active = true;

    BaseType_t ret = xTaskCreate(poll_task, "updates_poll", 4096, NULL, 3, &s_poll_task);
    if (ret != pdPASS) {
        ESP_LOGE(TAG, "Failed to create polling task");
        s_polling_active = false;
        return ESP_ERR_NO_MEM;
    }

    ESP_LOGI(TAG, "Update polling started (interval: %d seconds)", interval_seconds);
    return ESP_OK;
}

void updates_stop_polling(void)
{
    s_polling_active = false;
    // Task will delete itself
}

esp_err_t updates_get_release(update_release_t *release)
{
    if (!s_release.valid) {
        return ESP_ERR_NOT_FOUND;
    }

    if (release != NULL) {
        memcpy(release, &s_release, sizeof(update_release_t));
    }
    return ESP_OK;
}

esp_err_t updates_get_stats(update_stats_t *stats)
{
    if (stats == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    memcpy(stats, &s_stats, sizeof(update_stats_t));
    return ESP_OK;
}

size_t updates_build_latest_json(char *buffer, size_t buffer_size)
{
    geo_json_builder_t builder;
    geo_json_init(&builder, buffer, buffer_size);

    geo_json_object_start(&builder);

    if (!s_release.valid) {
        geo_json_add_string(&builder, "status", "no_updates_cached");
    } else {
        geo_json_add_string(&builder, "status", "available");
        geo_json_add_string(&builder, "version", s_release.version);
        geo_json_add_string(&builder, "tagName", s_release.tag_name);
        geo_json_add_string(&builder, "name", s_release.name);
        geo_json_add_string(&builder, "publishedAt", s_release.published_at);
        geo_json_add_string(&builder, "htmlUrl", s_release.html_url);

        // Build assets array with objects
        geo_json_array_start(&builder, "assets");
        for (int i = 0; i < s_release.asset_count; i++) {
            if (s_release.assets[i].downloaded) {
                geo_json_object_start(&builder);
                geo_json_add_string(&builder, "type", updates_asset_type_to_string(s_release.assets[i].type));
                char url[128];
                snprintf(url, sizeof(url), "/updates/%s/%s",
                         s_release.version, s_release.assets[i].filename);
                geo_json_add_string(&builder, "url", url);
                geo_json_add_string(&builder, "filename", s_release.assets[i].filename);
                geo_json_object_end(&builder);
            }
        }
        geo_json_array_end(&builder);
    }

    geo_json_object_end(&builder);
    return geo_json_get_length(&builder);
}

/**
 * @brief HTTP handler for /api/updates/latest
 */
static esp_err_t updates_latest_handler(httpd_req_t *req)
{
    char response[1024];
    size_t len = updates_build_latest_json(response, sizeof(response));

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_send(req, response, len);
    return ESP_OK;
}

/**
 * @brief HTTP handler for /updates/{version}/{filename}
 */
static esp_err_t updates_file_handler(httpd_req_t *req)
{
    if (!updates_is_available()) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Update service not available");
        return ESP_FAIL;
    }

    // Parse URI: /updates/{version}/{filename}
    char uri[128];  // Limit URI length
    strlcpy(uri, req->uri, sizeof(uri));

    // Remove query string
    char *query = strchr(uri, '?');
    if (query) *query = '\0';

    // Build local path: /sdcard/updates/... (max 7 + 127 = 134 < 256)
    char local_path[256];
    snprintf(local_path, sizeof(local_path), "/sdcard%.*s", (int)(sizeof(local_path) - 8), uri);

    // Check if file exists
    if (!sdcard_file_exists(local_path)) {
        ESP_LOGW(TAG, "File not found: %s", local_path);
        httpd_resp_send_err(req, HTTPD_404_NOT_FOUND, "File not found");
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "Serving file: %s", local_path);

    // Determine content type
    const char *content_type = "application/octet-stream";
    if (strstr(uri, ".apk")) {
        content_type = "application/vnd.android.package-archive";
    } else if (strstr(uri, ".zip")) {
        content_type = "application/zip";
    } else if (strstr(uri, ".tar.gz") || strstr(uri, ".tgz")) {
        content_type = "application/gzip";
    } else if (strstr(uri, ".dmg")) {
        content_type = "application/x-apple-diskimage";
    } else if (strstr(uri, ".ipa")) {
        content_type = "application/octet-stream";
    }

    // Get filename for Content-Disposition
    const char *filename = strrchr(uri, '/');
    if (filename) filename++;
    else filename = "download";

    // Read and send file
    uint8_t *buffer = malloc(DOWNLOAD_BUFFER_SIZE);
    if (buffer == NULL) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Memory allocation failed");
        return ESP_FAIL;
    }

    size_t file_size = 0;
    esp_err_t ret = sdcard_read_file(local_path, buffer, DOWNLOAD_BUFFER_SIZE, &file_size);
    if (ret != ESP_OK) {
        free(buffer);
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Failed to read file");
        return ESP_FAIL;
    }

    // Set headers
    httpd_resp_set_type(req, content_type);
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

    char disposition[128];
    snprintf(disposition, sizeof(disposition), "attachment; filename=\"%s\"", filename);
    httpd_resp_set_hdr(req, "Content-Disposition", disposition);

    // Send file
    httpd_resp_send(req, (char *)buffer, file_size);
    free(buffer);

    s_stats.files_served++;
    s_stats.bytes_served += file_size;

    ESP_LOGI(TAG, "Served %zu bytes", file_size);
    return ESP_OK;
}

static const httpd_uri_t updates_latest_uri = {
    .uri = "/api/updates/latest",
    .method = HTTP_GET,
    .handler = updates_latest_handler,
    .user_ctx = NULL
};

static const httpd_uri_t updates_file_uri = {
    .uri = "/updates/*",
    .method = HTTP_GET,
    .handler = updates_file_handler,
    .user_ctx = NULL
};

esp_err_t updates_register_http_handlers(httpd_handle_t server)
{
    if (server == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    esp_err_t ret = httpd_register_uri_handler(server, &updates_latest_uri);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to register /api/updates/latest handler");
        return ret;
    }

    ret = httpd_register_uri_handler(server, &updates_file_uri);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to register /updates/* handler");
        return ret;
    }

    ESP_LOGI(TAG, "Update HTTP handlers registered");
    return ESP_OK;
}

#else // !CONFIG_GEOGRAM_BOARD_EPAPER_1IN54

// Stubs for boards without SD card
#include "updates.h"

esp_err_t updates_init(void) { return ESP_ERR_NOT_SUPPORTED; }
bool updates_is_available(void) { return false; }
esp_err_t updates_check_github(void) { return ESP_ERR_NOT_SUPPORTED; }
esp_err_t updates_start_polling(int interval_seconds) { return ESP_ERR_NOT_SUPPORTED; }
void updates_stop_polling(void) {}
esp_err_t updates_get_release(update_release_t *release) { return ESP_ERR_NOT_FOUND; }
esp_err_t updates_get_stats(update_stats_t *stats) { return ESP_ERR_NOT_SUPPORTED; }
size_t updates_build_latest_json(char *buffer, size_t buffer_size) {
    if (buffer && buffer_size > 2) { buffer[0] = '{'; buffer[1] = '}'; buffer[2] = '\0'; return 2; }
    return 0;
}
esp_err_t updates_register_http_handlers(httpd_handle_t server) { return ESP_ERR_NOT_SUPPORTED; }
update_asset_type_t updates_asset_type_from_filename(const char *filename) { return 0; }
const char *updates_asset_type_to_string(update_asset_type_t type) { return "unknown"; }

#endif // CONFIG_GEOGRAM_BOARD_EPAPER_1IN54
