/**
 * @file xprslan.h
 * @brief XPRS over the local network — broadcast to everyone on the wire.
 *
 * A fourth bearer beside Bluetooth and the radios. The station puts XPRS
 * packets on the LAN as UDP broadcasts and listens for everybody else's, so a
 * desktop on the same WiFi is reachable without the packet leaving the
 * building. `docs/XPRS.md` already assigns it: `link:lan` is a bearer (§10.6)
 * and `scope:local` explicitly permits "the network it is attached to"
 * (§13.11.1). `docs/lan.md` is this bearer's page.
 *
 * ── What this is not ────────────────────────────────────────────────────────
 *
 * Not Reticulum and not the internet. No links, no identities, no routing, no
 * gateway. `geogram_lanwatch` listens to Reticulum's LAN discovery on UDP 42671
 * and is untouched by this; that is a different socket and a different protocol
 * that happens to travel on the same wire.
 *
 * ── The wire ────────────────────────────────────────────────────────────────
 *
 * One XPRS packet per datagram, verbatim, with no header of our own — the
 * packet is what was composed and signed and it arrives that way. A datagram is
 * XPRS if xprs_looks_like() and xprs_parse() accept it and is dropped
 * otherwise, so there is nothing to version and any future station joins by
 * opening a socket.
 *
 * ── Re-airing without everyone shouting at once ─────────────────────────────
 *
 * Every station on the LAN hears the same packet and would relay it in the same
 * instant. So a bridged packet is never aired straight away: it waits a random
 * XPRSLAN_JITTER_MIN_MS..XPRSLAN_JITTER_MAX_MS, and if its identifier is heard
 * again from anybody while it waits, our copy is dropped — somebody else got
 * there first. That works because a §5 identifier is computed with `sig:` and
 * `via:` removed, so the same packet relayed by a different station carries the
 * same identifier.
 */

#ifndef GEOGRAM_XPRSLAN_H
#define GEOGRAM_XPRSLAN_H

#include <stdint.h>
#include <stdbool.h>

#ifdef XPRSLAN_HOST_TEST
typedef int esp_err_t;      /* the host harness has no ESP-IDF headers */
#else
#include "esp_err.h"
#endif

#ifdef __cplusplus
extern "C" {
#endif

/**
 * The XPRS LAN port — the same 4242 a station answers XPRS on over TCP (§24.4),
 * here on UDP. Two different sockets that never collide, and one number to
 * remember for "this is where XPRS is spoken".
 *
 * Reticulum's LAN discovery keeps UDP 42671, which is neither of these.
 */
#define XPRSLAN_PORT          4242

/** Longest XPRS packet (docs/XPRS.md §4). */
#define XPRSLAN_WIRE_MAX      250

/** How long a bridged packet waits before it is aired, and the window in which
 *  hearing it from somebody else cancels it. */
#define XPRSLAN_JITTER_MIN_MS 200
#define XPRSLAN_JITTER_MAX_MS 1200

#define XPRSLAN_QUEUE_MAX     8    /* packets waiting to be re-aired */
#define XPRSLAN_PEERS_MAX     16   /* distinct stations remembered */

/**
 * @brief One packet heard on the LAN. Strings are valid only during the call.
 *
 * @param wire  the packet, verbatim and NUL-terminated
 * @param len   its length
 * @param ip    source address, network byte order
 */
typedef void (*xprslan_rx_cb_t)(const char *wire, int len, uint32_t ip);

/**
 * @brief Open the socket and start the task. Safe to call before an IP exists —
 *        datagrams simply start arriving when the interface joins a network.
 * @param callsign  this station, used for `via:` when bridging. Copied.
 */
esp_err_t xprslan_start(const char *callsign);
void      xprslan_stop(void);
bool      xprslan_is_active(void);

/** Called for every XPRS packet heard. NULL disables. */
void xprslan_set_rx_cb(xprslan_rx_cb_t cb);

/**
 * @brief Told the §5 identifier of EVERY valid XPRS datagram, including the
 *        duplicates the rx callback never sees.
 *
 * A station that queues its own copy of a packet for another bearer has to know
 * when somebody else airs it, and "somebody else is saying it" arrives here as
 * a repeat — which the rx path deliberately swallows. Without this the cancel
 * in §13.2.1 only works for one bearer.
 */
typedef void (*xprslan_heard_cb_t)(const char *id, const char *wire, int len);
void xprslan_set_heard_cb(xprslan_heard_cb_t cb);

/**
 * @brief Air one packet of OUR OWN, now, with no jitter and no `via:` — it has
 *        taken no hops yet. Use xprslan_offer() for anything heard elsewhere.
 * @return false when the socket is down or the packet is not XPRS.
 */
bool xprslan_send(const char *wire, int len);

/**
 * @brief Offer a packet heard on another bearer for re-airing on the LAN.
 *
 * Appends this station to `via:` (xprs_append_via, which refuses when we are
 * already in the path or the relay budget is spent), then queues it with the
 * jitter above. Silently does nothing when the packet must not be relayed —
 * that decision belongs to `geogram_xprs`, not to callers.
 */
void xprslan_offer(const char *wire, int len);

/**
 * @brief Build this station's periodic beacon into @p out (docs/XPRS.md §10.6).
 * @return its length, or 0 to say nothing this time.
 */
typedef int (*xprslan_beacon_cb_t)(char *out, int cap);

/**
 * @brief Air @p cb every @p interval_sec, on the bearer's own task.
 *
 * It runs there rather than on an esp_timer because building a beacon derives a
 * §5 identifier, which is a SHA-256, and the timer task's stack is not sized for
 * that — putting it there hung the dongle. One task owns the socket and
 * everything that writes to it.
 *
 * The first beacon waits @p first_delay_sec, which is how long DHCP needs
 * before anybody would receive it.
 */
void xprslan_set_beacon(xprslan_beacon_cb_t cb, uint32_t interval_sec,
                        uint32_t first_delay_sec);

/** Stations heard on the LAN within [max_age_sec]. */
int xprslan_peer_count(uint32_t max_age_sec);

/** Datagrams sent and received since boot (diagnostics). */
void xprslan_stats(uint32_t *out_rx, uint32_t *out_tx, uint32_t *out_cancelled);

#ifdef __cplusplus
}
#endif
#endif /* GEOGRAM_XPRSLAN_H */
