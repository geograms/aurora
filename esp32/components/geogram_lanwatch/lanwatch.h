/*
 * lanwatch — passive LAN presence watcher for geogram/Aurora devices.
 *
 * Aurora nodes on the same LAN run a UDP discovery interface (aurora
 * rns_lan_interface.dart): every node broadcasts its Reticulum ANNOUNCE
 * packets to 255.255.255.255 on a shared port (42671), one raw RNS packet
 * per datagram. This component just LISTENS on that socket — it never
 * transmits — and keeps a small freshness-windowed registry of the devices
 * heard, keyed by source IP (one entry per device, however many destinations
 * it announces). The plaintext app_data of a chat/LXMF announce is the
 * device callsign, so most entries carry a human-readable name too.
 *
 * Pure observer: lwip + freertos only, no radio/UI — reusable on any target
 * with WiFi up.
 */
#ifndef GEOGRAM_LANWATCH_H
#define GEOGRAM_LANWATCH_H

#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Shared Aurora LAN discovery port (rns_service.dart _lanDiscoveryPort). */
#define LANWATCH_DEFAULT_PORT  42671

#define LANWATCH_CALLSIGN_MAX  12   /* chars (buffers are MAX+1 for the NUL) */
#define LANWATCH_PEERS_MAX     16

typedef struct {
    uint32_t ip;                              /* IPv4, network byte order */
    char     callsign[LANWATCH_CALLSIGN_MAX + 1]; /* "" until an announce
                                                     with a plaintext name */
    uint32_t age_sec;                         /* seconds since last heard */
} lanwatch_peer_t;

/* Bind the UDP socket and start the listener task. Call once WiFi/lwip is
 * initialised (an IP is not required yet — datagrams simply start arriving
 * when the STA joins the LAN). [port] 0 = LANWATCH_DEFAULT_PORT. */
esp_err_t lanwatch_start(uint16_t port);

/* Number of distinct devices heard within [max_age_sec]. */
int lanwatch_count(uint32_t max_age_sec);

/* Snapshot the devices heard within [max_age_sec] into [out] (up to [max]).
 * Returns the number written. */
int lanwatch_peers(lanwatch_peer_t *out, int max, uint32_t max_age_sec);

#ifdef __cplusplus
}
#endif
#endif /* GEOGRAM_LANWATCH_H */
