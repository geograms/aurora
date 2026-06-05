/**
 * @file ble_hello.h
 * @brief Standalone BLE HELLO protocol for Geogram devices.
 *
 * Provides:
 *   - BLE advertising with Geogram manufacturer data (callsign + device ID)
 *   - Passive scanning for nearby Geogram devices (0x3E marker)
 *   - GATT server for HELLO / HELLO_ACK handshake
 *
 * No dependencies on mesh, aprs, radio_tx, or station.
 */

#ifndef GEOGRAM_BLE_HELLO_H
#define GEOGRAM_BLE_HELLO_H

#include "esp_err.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Start BLE advertising, scanning, and GATT server.
 *
 * @param callsign  Station callsign (e.g. "X3ABCD"), copied internally.
 * @return ESP_OK on success
 */
esp_err_t ble_hello_init(const char *callsign);

/**
 * @brief Stop BLE hello (advertising + scanning + GATT).
 */
void ble_hello_stop(void);

/**
 * @brief Number of nearby Geogram devices seen in the last 60 seconds.
 */
int ble_hello_device_count(void);

/**
 * @brief Whether the BLE hello subsystem is active.
 */
bool ble_hello_is_active(void);

/**
 * @brief Callback for a received Aurora APRS-over-BLE frame.
 *
 * Aurora desktops/peers advertise compact APRS frames in manufacturer data
 * (company 0xFFFF, NO 0x3E marker) with the payload `<from>\x1f<to>\x1f<text>`.
 * `to` may be a callsign (1:1), "#GRP" (group), "!" (position; text=lat,lon),
 * or empty (geo-chat). All strings are NUL-terminated and only valid during the
 * call — copy if retained.
 */
typedef void (*ble_hello_aprs_cb_t)(const char *from, const char *to,
                                    const char *text, int rssi);

/**
 * @brief Register a callback for received Aurora APRS-over-BLE frames.
 *        Pass NULL to disable. Keeps this component UI-agnostic.
 */
void ble_hello_set_aprs_cb(ble_hello_aprs_cb_t cb);

#ifdef __cplusplus
}
#endif

#endif /* GEOGRAM_BLE_HELLO_H */
