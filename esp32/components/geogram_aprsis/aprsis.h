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
#include <stdint.h>
#include "msgstore.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Start the APRS-IS iGate task.
 * @param callsign Station callsign (e.g. "X3WWAJ"), copied internally.
 * @return ESP_OK on success, ESP_ERR_INVALID_STATE if already running.
 */
esp_err_t aprsis_init(const char *callsign);

/* BLE integration hooks — set so this component does not hard-depend on any one
 * BLE firmware (legacy ble_hello on the main build, BLE5 on the rns_ble5 dongle).
 *   get_heard: fill calls[][8] with up to [max] callsigns heard over BLE within
 *              [max_age_sec]; return the count. Used for the APRS-IS g/ filter
 *              and to decide which downlink traffic to relay. NULL => none heard.
 *   relay    : push one APRS frame (from,to,text) out over BLE (downlink). NULL
 *              => downlink disabled (uplink-only iGate). */
typedef int (*aprsis_get_heard_fn)(char calls[][8], int max, uint32_t max_age_sec);
typedef bool (*aprsis_relay_fn)(const char *from, const char *to, const char *text);
void aprsis_set_ble_hooks(aprsis_get_heard_fn get_heard, aprsis_relay_fn relay);

/**
 * @brief Attach the two archives the iGate writes received traffic to.
 *
 * @param messages store for APRS text messages (live + addressed).
 * @param beacons  store for automated position beacons (in-radius).
 * Either may be NULL to disable that archive.
 */
void aprsis_set_stores(msgstore_t *messages, msgstore_t *beacons);

/**
 * @brief Set (or clear) the station's fixed coordinates and "nearby" radius.
 *
 * The T-Dongle has no GPS, so "nearby" traffic is only gated once coordinates
 * are provided. Pass (0,0) to mark them undefined — message gating to heard
 * callsigns still works, but no area/position filter is applied.
 * @param radius_km nearby radius in km; <=0 keeps the current value.
 */
void aprsis_set_position(double lat, double lon, int radius_km);

/** @brief Read the current coordinates/radius. Any pointer may be NULL. */
void aprsis_get_position(double *lat, double *lon, int *radius_km, bool *have_pos);

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
