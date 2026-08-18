/**
 * @file xprsbearer.h
 * @brief What every XPRS bearer does, minus the radio.
 *
 * A bearer is a way of putting a 250-byte packet in front of whoever is
 * listening. The differences between them are small — a socket, a advertising
 * set, an ESP-NOW frame — and the part that is hard is identical: when to
 * re-air somebody else's packet, when to shut up because they got there first,
 * which identifiers have been seen, and when to beacon.
 *
 * That part was written twice before this file existed — once in
 * `geogram_xprslan` and once inline in the dongle's BLE relay, with the same
 * 200–1200 ms jitter and the same eight slots — and a third copy was about to
 * be written for ESP-NOW. This is that logic, once, with the radio behind five
 * function pointers.
 *
 * ── What a bearer supplies ──────────────────────────────────────────────────
 *
 * `air` puts bytes on the medium. `now_ms` and `random` are the clock and the
 * jitter. `lock`/`unlock` serialise transmission, because on a real station
 * several tasks air on one bearer: its own beacons, a reply from whichever task
 * heard the ask, and this file's re-air queue.
 *
 * ── What it does NOT decide ─────────────────────────────────────────────────
 *
 * Whether a packet may be relayed at all belongs to `geogram_xprs`
 * (`xprs_append_via`, §13.1 hop budgets and §13.2 loop prevention). This file
 * asks and obeys; it never second-guesses.
 *
 * No ESP-IDF here, deliberately: the whole file compiles on a host, which is
 * where the timing and the cancel rule are actually tested.
 */

#ifndef GEOGRAM_XPRSBEARER_H
#define GEOGRAM_XPRSBEARER_H

#include <stdint.h>
#include <stdbool.h>

#include "xprs.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Longest XPRS packet (docs/XPRS.md §4) — the same on every bearer. */
#define XB_WIRE_MAX      XPRS_MAX_WIRE
#define XB_ID_LEN        XPRS_ID_LEN

/**
 * How long a re-aired packet waits, and the window in which hearing it from
 * somebody else cancels it (§13.2.1). Random inside the window, because the
 * whole point is that stations hearing the same packet do not answer together.
 */
#define XB_JITTER_MIN_MS 200
#define XB_JITTER_MAX_MS 1200

#define XB_QUEUE_MAX     8     /* packets waiting to be re-aired */
#define XB_PEERS_MAX     16    /* distinct stations remembered */
#define XB_SEEN_RING     32    /* identifiers remembered, per ring */
#define XB_SEEN_MS       60000u/* how long "already heard" lasts */

/**
 * One packet heard.
 *
 * @p peer identifies the sender on this bearer's own terms — an IPv4 address, a
 * MAC, 0 when the bearer cannot say. @p rssi is dBm, or 0 for a bearer with no
 * signal to report: a network has none, a radio does.
 */
typedef void (*xb_rx_cb_t)(const char *wire, int len, uint64_t peer, int rssi);

/**
 * Told the §5 identifier of EVERY valid packet heard, including the duplicates
 * the rx callback swallows.
 *
 * A station that queued its own copy for ANOTHER bearer has to know when
 * somebody else airs it, and "somebody else is saying it" arrives as a repeat.
 * Without this the §13.2.1 cancel only works one bearer at a time.
 */
typedef void (*xb_heard_cb_t)(const char *id, const char *wire, int len);

/** Build this station's periodic beacon (§10.6). Return its length, or 0. */
typedef int (*xb_beacon_cb_t)(char *out, int cap);

/** The radio, and the clock it runs on. */
typedef struct {
    bool     (*air)(void *ctx, const char *wire, int len);
    uint32_t (*now_ms)(void);
    uint32_t (*random)(void);
    void     (*lock)(void *ctx);      /* may be NULL on a single-task bearer */
    void     (*unlock)(void *ctx);
    /**
     * Empty whatever the receive path filled, calling xb_on_wire() for each.
     * NULL for a bearer that delivers on its own task.
     *
     * This exists because ESP-NOW hands packets to a callback running in the
     * WiFi task, on core 0, where the SHA-256 an identifier costs must never
     * happen. The callback copies and returns; this runs on the bearer task.
     */
    void     (*drain)(void *ctx);
    void      *ctx;
    const char *name;                 /* "lan", "espnow" — for logs only */
} xb_ops_t;

typedef struct {
    char     wire[XB_WIRE_MAX + 1];
    int      len;
    char     id[XB_ID_LEN];
    uint32_t due_ms;
    bool     used;
} xb_queued_t;

typedef struct {
    char     id[XB_ID_LEN];
    uint32_t t_ms;
} xb_seen_t;

typedef struct {
    uint64_t peer;
    uint32_t t_ms;
} xb_peer_t;

/**
 * One bearer's state. Held by the bearer, not allocated here — every byte of
 * heap on this board is spoken for, and a caller that can see the struct can
 * see what it costs.
 */
typedef struct {
    xb_ops_t     ops;
    char         call[16];
    bool         active;
    xb_queued_t  queue[XB_QUEUE_MAX];
    xb_seen_t    heard[XB_SEEN_RING];   /* seen on this bearer */
    int          heard_pos;
    xb_seen_t    aired[XB_SEEN_RING];   /* put on this bearer by us */
    int          aired_pos;
    xb_peer_t    peers[XB_PEERS_MAX];
    xb_rx_cb_t     rx_cb;
    xb_heard_cb_t  heard_cb;
    xb_beacon_cb_t beacon_cb;
    uint32_t     beacon_every_ms, beacon_due_ms;
    uint32_t     rx_count, tx_count, cancelled, dupes;
} xb_t;

/** Bring a bearer up. @p call is this station, used for `via:` when relaying. */
void xb_init(xb_t *b, const xb_ops_t *ops, const char *call);
void xb_stop(xb_t *b);
bool xb_is_active(const xb_t *b);

void xb_set_rx_cb(xb_t *b, xb_rx_cb_t cb);
void xb_set_heard_cb(xb_t *b, xb_heard_cb_t cb);

/**
 * Air @p cb every @p interval_sec, first after @p first_delay_sec.
 *
 * Called from whatever task drives xb_tick(), never from a timer: building a
 * beacon derives a §5 identifier, which is a SHA-256, and a timer task's stack
 * is not sized for that — putting it there hung the dongle.
 */
void xb_set_beacon(xb_t *b, xb_beacon_cb_t cb, uint32_t interval_sec,
                   uint32_t first_delay_sec);

/**
 * Air one packet of OUR OWN, now, with no jitter and no `via:` — it has taken
 * no hops yet. Use xb_offer() for anything heard elsewhere.
 */
bool xb_send(xb_t *b, const char *wire, int len);

/**
 * Offer a packet heard on ANOTHER bearer for re-airing on this one.
 *
 * Appends this station to `via:` and queues it with the jitter above. Silently
 * does nothing when the packet must not be relayed — that decision belongs to
 * `geogram_xprs`, not here.
 */
void xb_offer(xb_t *b, const char *wire, int len);

/** One packet arrived on the medium. Called by the bearer's receive path. */
void xb_on_wire(xb_t *b, const char *wire, int len, uint64_t peer, int rssi);

/** Air anything whose moment has come, and the beacon when it is due. */
void xb_tick(xb_t *b, uint32_t now_ms);

/**
 * Ask to be ticked by whatever task is already driving bearers.
 *
 * Pumping a queue means waking every hundred milliseconds, and on this board a
 * task is 5 KB of a heap that has been down to hundreds of bytes. One task can
 * drive every bearer — the granularity a 200–1200 ms jitter needs is the same
 * for all of them — so a bearer registers here instead of starting its own.
 *
 * The bearer that OWNS the task calls xb_tick_all(). If none does, nothing is
 * pumped, which is why a bearer that registers must say so out loud rather than
 * discover it in the field.
 */
void xb_register_ticked(xb_t *b);
void xb_tick_all(uint32_t now_ms);

/** Whether any task has claimed the job of calling xb_tick_all(). */
bool xb_has_driver(void);
void xb_set_driver(bool yes);

/** Stations heard within [max_age_sec]. */
int  xb_peer_count(const xb_t *b, uint32_t max_age_sec);

void xb_stats(const xb_t *b, uint32_t *rx, uint32_t *tx, uint32_t *cancelled);

#ifdef __cplusplus
}
#endif
#endif /* GEOGRAM_XPRSBEARER_H */
