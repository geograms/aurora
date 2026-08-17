/**
 * @file xprsnow.h
 * @brief XPRS over ESP-NOW — every ESP32 already has this radio.
 *
 * ESP-NOW is Espressif's connectionless mode: 802.11 action frames, no
 * association, no AP, no DHCP. A frame carries **250 bytes**
 * (`ESP_NOW_MAX_DATA_LEN`), which is exactly the longest XPRS packet
 * (`docs/XPRS.md` §4) — so one packet is one frame, verbatim, and nothing is
 * ever fragmented. `link:espnow` is an assigned bearer word (§10.6.1) and
 * `docs/espnow.md` is this bearer's page.
 *
 * ── Why this is not a hotspot ───────────────────────────────────────────────
 *
 * Nobody connects. A SoftAP has a client ceiling and shares one channel's
 * bandwidth between everyone associated to it; ESP-NOW broadcast has neither
 * problem, because there is no association to run out of. The peer table needs
 * exactly ONE entry — the broadcast address — so `ESP_NOW_MAX_TOTAL_PEER_NUM`
 * (20) never binds however many stations are listening.
 *
 * Promiscuous mode is not used and is not needed: broadcast frames reach every
 * ESP-NOW device on the channel through the ordinary receive path, and the RSSI
 * that sniffing would have been for arrives with them (`rx_ctrl`).
 *
 * ── The one real constraint ─────────────────────────────────────────────────
 *
 * **ESP-NOW rides the channel the WiFi station is already on.** Two devices on
 * different channels do not hear each other and nothing reports an error —
 * `esp_now_send` succeeds, and the only symptom is a peer count that stays at
 * zero. When the station is associated to an access point, that is the AP's
 * channel; when it is not, it is whatever channel was last set.
 *
 * Moving a pair to a channel of their own, and to the long-range PHY, is
 * §23.7's `t:channel` invitation, and is not this file's job.
 *
 * ── Where the work happens ──────────────────────────────────────────────────
 *
 * ESP-NOW delivers into a callback that runs **in the WiFi task, on core 0** —
 * beside the radios, on the processor `docs/esp32.md` spends its length
 * defending. Deriving a §5 identifier is a SHA-256 and must not happen there.
 * So the callback copies the frame into a queue and returns; everything else
 * runs on the bearer task through `geogram_xprsbearer`'s drain hook.
 */

#ifndef GEOGRAM_XPRSNOW_H
#define GEOGRAM_XPRSNOW_H

#include <stdint.h>
#include <stdbool.h>

#ifdef XPRSNOW_HOST_TEST
typedef int esp_err_t;
#else
#include "esp_err.h"
#endif

#ifdef __cplusplus
extern "C" {
#endif

/** Longest XPRS packet, and exactly one ESP-NOW frame. */
#define XPRSNOW_WIRE_MAX   250

/** Frames the receive callback may hold before the bearer task drains them.
 *  Four is a burst; a fifth is dropped and counted rather than made to wait in
 *  the WiFi task. */
#define XPRSNOW_RX_QUEUE   4

/**
 * @brief One packet heard on ESP-NOW.
 * @param mac  the sender's address, 6 bytes; valid only during the call
 * @param rssi dBm, as the radio measured it
 */
typedef void (*xprsnow_rx_cb_t)(const char *wire, int len,
                                const uint8_t mac[6], int rssi);

/** Told the §5 identifier of every valid packet, duplicates included. */
typedef void (*xprsnow_heard_cb_t)(const char *id, const char *wire, int len);

/** Build this station's periodic beacon. Return its length, or 0. */
typedef int (*xprsnow_beacon_cb_t)(char *out, int cap);

/**
 * @brief Bring the bearer up. WiFi must already be started (`esp_wifi_start`);
 *        it need not be associated.
 *
 * Turns modem sleep OFF: a station that sleeps misses ESP-NOW frames, which
 * Espressif's own example warns about. That is a coexistence decision as much
 * as a power one on a board that also runs Bluetooth.
 *
 * @param callsign this station, used for `via:` when relaying. Copied.
 */
esp_err_t xprsnow_start(const char *callsign);
void      xprsnow_stop(void);
bool      xprsnow_is_active(void);

void xprsnow_set_rx_cb(xprsnow_rx_cb_t cb);
void xprsnow_set_heard_cb(xprsnow_heard_cb_t cb);
void xprsnow_set_beacon(xprsnow_beacon_cb_t cb, uint32_t interval_sec,
                        uint32_t first_delay_sec);

/** Air one packet of OUR OWN, now, with no `via:` — it has taken no hops. */
bool xprsnow_send(const char *wire, int len);

/** Offer a packet heard on another bearer for re-airing here (§13.2.1). */
void xprsnow_offer(const char *wire, int len);

/** Stations heard within [max_age_sec]. */
int xprsnow_peer_count(uint32_t max_age_sec);

/** The channel this bearer is actually on — the STA's, whatever that is. */
uint8_t xprsnow_channel(void);

/** @param dropped frames the receive callback had nowhere to put. */
void xprsnow_stats(uint32_t *rx, uint32_t *tx, uint32_t *cancelled,
                   uint32_t *dropped);

#ifdef __cplusplus
}
#endif
#endif /* GEOGRAM_XPRSNOW_H */
