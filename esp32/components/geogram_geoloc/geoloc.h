/**
 * @file geoloc.h
 * @brief IP-based geolocation for timezone and coordinates
 *
 * Uses ip-api.com to determine location based on public IP address.
 * Provides timezone string for NTP and coordinates for station status.
 */

#ifndef GEOGRAM_GEOLOC_H
#define GEOGRAM_GEOLOC_H

#include "esp_err.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GEOLOC_TIMEZONE_LEN     48
#define GEOLOC_COUNTRY_LEN      64
#define GEOLOC_CITY_LEN         64

/**
 * @brief Geolocation data structure
 */
typedef struct {
    double latitude;
    double longitude;
    char timezone[GEOLOC_TIMEZONE_LEN];     // e.g., "Europe/Lisbon"
    char country[GEOLOC_COUNTRY_LEN];       // e.g., "Portugal"
    char city[GEOLOC_CITY_LEN];             // e.g., "Lisbon"
    int32_t utc_offset;                     // Offset in seconds from UTC
    bool valid;                             // True if data was successfully fetched
} geoloc_data_t;

/**
 * @brief Fetch geolocation data from IP-based service
 *
 * Makes HTTP request to ip-api.com to get location data.
 * This should be called after WiFi is connected.
 *
 * @param data Pointer to store geolocation data
 * @return ESP_OK on success, error code otherwise
 */
esp_err_t geoloc_fetch(geoloc_data_t *data);

/**
 * @brief Get cached geolocation data
 *
 * Returns pointer to internally cached data from last successful fetch.
 *
 * @return Pointer to cached data, or NULL if not yet fetched
 */
const geoloc_data_t *geoloc_get_cached(void);

/**
 * @brief Check if geolocation data is available
 *
 * @return true if valid geolocation data is cached
 */
bool geoloc_is_valid(void);

/**
 * @brief Get POSIX timezone string for setenv("TZ", ...)
 *
 * Converts the IANA timezone (e.g., "Europe/Lisbon") to a POSIX
 * timezone string that can be used with setenv("TZ", ...).
 *
 * @param iana_tz IANA timezone name
 * @param posix_tz Buffer to store POSIX timezone string
 * @param size Size of buffer
 * @return ESP_OK on success
 */
esp_err_t geoloc_iana_to_posix_tz(const char *iana_tz, char *posix_tz, size_t size);

/**
 * @brief Apply timezone from geolocation
 *
 * Sets the system timezone based on cached geolocation data.
 * Should be called after geoloc_fetch() succeeds.
 *
 * @return ESP_OK on success
 */
esp_err_t geoloc_apply_timezone(void);

/**
 * @brief Get latitude from cached data
 * @return Latitude or 0.0 if not available
 */
double geoloc_get_latitude(void);

/**
 * @brief Get longitude from cached data
 * @return Longitude or 0.0 if not available
 */
double geoloc_get_longitude(void);

/**
 * @brief Get timezone string from cached data
 * @return Timezone string or "UTC" if not available
 */
const char *geoloc_get_timezone(void);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_GEOLOC_H
