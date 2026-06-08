/**
 * @file aprsis.h
 * @brief APRS-IS iGate for the T-Dongle — bridges APRS-IS <-> BLE.
 *
 * Connects to an APRS-IS server over WiFi (computed passcode, no licence
 * needed for an X3 callsign), and:
 *
 *   - RX (Internet -> BLE): pulls APRS messages addressed to callsigns this
 *     node has heard over BLE (and itself), plus — only when the node's
 *     coordinates are defined — nearby position traffic, and re-broadcasts them
 *     over BLE so local devices receive them.
 *   - TX (BLE -> Internet): gates frames heard locally over BLE up to APRS-IS
 *     (third-party format), so messages from BLE-only devices reach the world.
 *
 * Mirrors the Aurora desktop/Android APRS client (same passcode + TNC2 logic).
 * Runs on its own FreeRTOS task; safe to start once at boot.
 */
#ifndef GEOGRAM_APRSIS_H
#define GEOGRAM_APRSIS_H

#include "esp_err.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Start the APRS-IS iGate task.
 * @param callsign Station callsign (e.g. "X3WWAJ"), copied internally.
 * @return ESP_OK on success, ESP_ERR_INVALID_STATE if already running.
 */
esp_err_t aprsis_init(const char *callsign);

/**
 * @brief Set (or clear) the station's fixed coordinates.
 *
 * The T-Dongle has no GPS, so "nearby" traffic is only gated once coordinates
 * are provided. Pass (0,0) to mark them undefined — message gating to heard
 * callsigns still works, but no area/position filter is applied.
 */
void aprsis_set_position(double lat, double lon);

/**
 * @brief Gate one frame heard over BLE up to APRS-IS (RF -> Internet).
 *
 * Call from the BLE receive path. `to` may be a callsign, "#GRP", "!"
 * (position; `text` = "lat,lon[,comment]"), or "" (geo-chat, not gated).
 * No-op if not currently connected/logged in. Content-deduped.
 */
void aprsis_uplink(const char *from, const char *to, const char *text);

/** @brief Whether the iGate is currently connected and logged in. */
bool aprsis_is_connected(void);

/** @brief RX diagnostics: total info lines received, of those parsed as APRS
 *  messages, and of those addressed to a local (own/heard) callsign. Any pointer
 *  may be NULL. */
void aprsis_get_rx_stats(uint32_t *lines, uint32_t *msgs, uint32_t *gated);

#ifdef __cplusplus
}
#endif

#endif /* GEOGRAM_APRSIS_H */
