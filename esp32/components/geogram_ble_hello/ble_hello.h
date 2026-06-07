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

/**
 * @brief Copy the callsigns heard over BLE in the last [max_age_sec] seconds
 *        (presence beacons + APRS frame senders) into [calls].
 *
 * Used by the APRS-IS iGate to build its server-side message filter so it only
 * pulls traffic addressed to locally-heard stations.
 *
 * @param calls       Output array of fixed-width (8-byte) callsign slots.
 * @param max         Capacity of [calls].
 * @param max_age_sec Only return calls heard within this window (0 = any age).
 * @return Number of callsigns written (<= max).
 */
int ble_hello_get_heard(char calls[][8], int max, uint32_t max_age_sec);

/**
 * @brief Relay an APRS frame out over BLE as a compact Aurora frame
 *        (`<from>\x1f<to>\x1f<text>`), so nearby BLE devices receive it.
 *
 * Built for the iGate's APRS-IS -> BLE path. The frame is queued into the same
 * rebroadcast rotation used by the mesh repeater and is content-deduped, so a
 * message gated repeatedly by APRS-IS is only put on air once per window. The
 * BLE legacy advert is small (~24 B of manufacturer data); [text] is truncated
 * to fit. `to` may be a callsign, "#GRP", "!" (position; text="lat,lon"), or "".
 *
 * @return true if the frame was queued (false if duplicate/too large/inactive).
 */
bool ble_hello_relay_aprs(const char *from, const char *to, const char *text);

#ifdef __cplusplus
}
#endif

#endif /* GEOGRAM_BLE_HELLO_H */
