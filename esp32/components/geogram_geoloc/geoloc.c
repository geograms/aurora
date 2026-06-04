/**
 * @file geoloc.c
 * @brief IP-based geolocation implementation
 */

#include "geoloc.h"
#include "esp_log.h"
#include "esp_http_client.h"
#include "cJSON.h"
#include <string.h>
#include <time.h>
#include <sys/time.h>

static const char *TAG = "geoloc";

// ip-api.com endpoint (free, no API key needed, 45 requests/minute limit)
// Fields: lat, lon, timezone, country, city, offset
#define GEOLOC_API_URL "http://ip-api.com/json/?fields=status,message,country,city,lat,lon,timezone,offset"

// Response buffer
#define RESPONSE_BUFFER_SIZE 512

// Cached geolocation data
static geoloc_data_t s_geoloc = {0};
static char s_response_buffer[RESPONSE_BUFFER_SIZE];
static int s_response_len = 0;

/**
 * @brief HTTP event handler for collecting response
 */
static esp_err_t http_event_handler(esp_http_client_event_t *evt)
{
    switch (evt->event_id) {
        case HTTP_EVENT_ON_DATA:
            if (s_response_len + evt->data_len < RESPONSE_BUFFER_SIZE - 1) {
                memcpy(s_response_buffer + s_response_len, evt->data, evt->data_len);
                s_response_len += evt->data_len;
                s_response_buffer[s_response_len] = '\0';
            }
            break;
        default:
            break;
    }
    return ESP_OK;
}

esp_err_t geoloc_fetch(geoloc_data_t *data)
{
    if (data == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    memset(data, 0, sizeof(geoloc_data_t));
    s_response_len = 0;
    s_response_buffer[0] = '\0';

    ESP_LOGI(TAG, "Fetching geolocation from ip-api.com...");

    esp_http_client_config_t config = {
        .url = GEOLOC_API_URL,
        .event_handler = http_event_handler,
        .timeout_ms = 10000,
    };

    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) {
        ESP_LOGE(TAG, "Failed to initialize HTTP client");
        return ESP_FAIL;
    }

    esp_err_t err = esp_http_client_perform(client);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "HTTP request failed: %s", esp_err_to_name(err));
        esp_http_client_cleanup(client);
        return err;
    }

    int status_code = esp_http_client_get_status_code(client);
    esp_http_client_cleanup(client);

    if (status_code != 200) {
        ESP_LOGE(TAG, "HTTP request returned status %d", status_code);
        return ESP_FAIL;
    }

    ESP_LOGD(TAG, "Response: %s", s_response_buffer);

    // Parse JSON response
    cJSON *root = cJSON_Parse(s_response_buffer);
    if (root == NULL) {
        ESP_LOGE(TAG, "Failed to parse JSON response");
        return ESP_FAIL;
    }

    // Check status
    cJSON *status = cJSON_GetObjectItem(root, "status");
    if (status == NULL || strcmp(status->valuestring, "success") != 0) {
        cJSON *message = cJSON_GetObjectItem(root, "message");
        ESP_LOGE(TAG, "API error: %s", message ? message->valuestring : "unknown");
        cJSON_Delete(root);
        return ESP_FAIL;
    }

    // Extract fields
    cJSON *lat = cJSON_GetObjectItem(root, "lat");
    cJSON *lon = cJSON_GetObjectItem(root, "lon");
    cJSON *timezone = cJSON_GetObjectItem(root, "timezone");
    cJSON *country = cJSON_GetObjectItem(root, "country");
    cJSON *city = cJSON_GetObjectItem(root, "city");
    cJSON *offset = cJSON_GetObjectItem(root, "offset");

    if (lat && cJSON_IsNumber(lat)) {
        data->latitude = lat->valuedouble;
    }
    if (lon && cJSON_IsNumber(lon)) {
        data->longitude = lon->valuedouble;
    }
    if (timezone && cJSON_IsString(timezone)) {
        strncpy(data->timezone, timezone->valuestring, GEOLOC_TIMEZONE_LEN - 1);
    }
    if (country && cJSON_IsString(country)) {
        strncpy(data->country, country->valuestring, GEOLOC_COUNTRY_LEN - 1);
    }
    if (city && cJSON_IsString(city)) {
        strncpy(data->city, city->valuestring, GEOLOC_CITY_LEN - 1);
    }
    if (offset && cJSON_IsNumber(offset)) {
        data->utc_offset = (int32_t)offset->valueint;
    }

    data->valid = true;

    cJSON_Delete(root);

    // Cache the data
    memcpy(&s_geoloc, data, sizeof(geoloc_data_t));

    ESP_LOGI(TAG, "Geolocation: %s, %s (%.4f, %.4f) TZ: %s (UTC%+ld)",
             data->city, data->country,
             data->latitude, data->longitude,
             data->timezone, (long)(data->utc_offset / 3600));

    return ESP_OK;
}

const geoloc_data_t *geoloc_get_cached(void)
{
    return s_geoloc.valid ? &s_geoloc : NULL;
}

bool geoloc_is_valid(void)
{
    return s_geoloc.valid;
}

esp_err_t geoloc_iana_to_posix_tz(const char *iana_tz, char *posix_tz, size_t size)
{
    if (iana_tz == NULL || posix_tz == NULL || size == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    // For ESP-IDF, we can use the IANA timezone directly if timezone database is available
    // Otherwise, we construct a simple POSIX string from the offset

    // If we have cached offset, use it to construct POSIX timezone
    if (s_geoloc.valid && s_geoloc.utc_offset != 0) {
        // POSIX timezone format: STDoffset or STDoffsetDST
        // Note: POSIX offset is opposite sign from UTC offset
        int hours = -s_geoloc.utc_offset / 3600;
        int mins = abs(s_geoloc.utc_offset % 3600) / 60;

        if (mins != 0) {
            snprintf(posix_tz, size, "UTC%+d:%02d", hours, mins);
        } else {
            snprintf(posix_tz, size, "UTC%+d", hours);
        }
    } else {
        // Default to UTC
        strncpy(posix_tz, "UTC0", size - 1);
        posix_tz[size - 1] = '\0';
    }

    return ESP_OK;
}

esp_err_t geoloc_apply_timezone(void)
{
    if (!s_geoloc.valid) {
        ESP_LOGW(TAG, "No valid geolocation data, using UTC");
        setenv("TZ", "UTC0", 1);
        tzset();
        return ESP_ERR_INVALID_STATE;
    }

    char posix_tz[32];
    esp_err_t err = geoloc_iana_to_posix_tz(s_geoloc.timezone, posix_tz, sizeof(posix_tz));
    if (err != ESP_OK) {
        return err;
    }

    ESP_LOGI(TAG, "Setting timezone: %s (POSIX: %s)", s_geoloc.timezone, posix_tz);
    setenv("TZ", posix_tz, 1);
    tzset();

    return ESP_OK;
}

double geoloc_get_latitude(void)
{
    return s_geoloc.valid ? s_geoloc.latitude : 0.0;
}

double geoloc_get_longitude(void)
{
    return s_geoloc.valid ? s_geoloc.longitude : 0.0;
}

const char *geoloc_get_timezone(void)
{
    return s_geoloc.valid ? s_geoloc.timezone : "UTC";
}
