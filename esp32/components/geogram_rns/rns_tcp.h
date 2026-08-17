/**
 * @file rns_tcp.h
 * @brief One socket to one Reticulum hub — the interface that puts this
 *        station on the wider network.
 *
 * A leaf that opens a TCP interface to a hub inherits the network's routing
 * without being a transport node itself, which is what lets a board with
 * fifteen kilobytes of free heap take part at all.
 *
 * Reconnects on its own, forever: an unreachable hub is a normal condition for
 * a device on domestic WiFi, not an error to give up on.
 */

#ifndef GEOGRAM_RNS_TCP_H
#define GEOGRAM_RNS_TCP_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/** The port Reticulum hubs answer on. */
#define RNS_TCP_DEFAULT_PORT 4242
/** How many hubs may be listed. Tried in turn; one connection at a time. */
#define RNS_TCP_MAX_HUBS 6

/**
 * @brief One received packet, already de-framed.
 *
 * Called with @p frame NULL and @p len 0 the moment a connection is
 * established — that is the cue to announce, because a hub knows nothing about
 * a station that has not spoken since it connected.
 */
typedef void (*rns_tcp_rx_cb_t)(const uint8_t *frame, size_t len, void *ctx);

/** Add a hub to try. Call before rns_tcp_start(), or pass the first to it. */
esp_err_t rns_tcp_add_hub(const char *host, uint16_t port);
/** The hub currently dialled — for a status line. */
const char *rns_tcp_current_hub(void);

esp_err_t rns_tcp_start(const char *host, uint16_t port);
void      rns_tcp_stop(void);
bool      rns_tcp_is_up(void);
void      rns_tcp_set_rx_cb(rns_tcp_rx_cb_t cb, void *ctx);

/** Frame and send one RNS packet. False when the socket is down. */
bool rns_tcp_send(const uint8_t *packet, size_t len);

void rns_tcp_stats(uint32_t *rx, uint32_t *tx, uint32_t *connects,
                   uint32_t *dropped);

#ifdef __cplusplus
}
#endif
#endif /* GEOGRAM_RNS_TCP_H */
