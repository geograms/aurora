/*
 * XPRS over the LAN — see xprslan.h for the bearer, and docs/lan.md for the
 * wire it shares with everything else that speaks it.
 *
 * The socket work is a handful of lines borrowed from geogram_lanwatch. What is
 * worth reading is the queue: a packet bridged onto the LAN waits a random
 * moment and is thrown away if somebody else airs it first.
 *
 * Everything except the socket compiles on the host (XPRSLAN_HOST_TEST), which
 * is where the queue, the rings and the relay decisions are tested — none of
 * that needs a network, and all of it is what actually goes wrong.
 */

#include "xprslan.h"

#include <string.h>
#include <stdio.h>

#include "xprs.h"

#ifdef XPRSLAN_HOST_TEST

#include <stdlib.h>
#define XL_LOGI(fmt, ...) ((void)0)
#define XL_LOGW(fmt, ...) ((void)0)
#define XL_LOGD(fmt, ...) ((void)0)

/* The host drives time and catches what would have gone on the wire. */
uint32_t xl_test_now_ms;
char     xl_test_aired[XPRSLAN_WIRE_MAX + 1];
int      xl_test_aired_len;
int      xl_test_air_count;
uint32_t xl_test_random = 12345;

static uint32_t xl_now_ms(void) { return xl_test_now_ms; }
static uint32_t xl_random(void) { return xl_test_random; }
static bool xl_air(const char *wire, int len)
{
    memcpy(xl_test_aired, wire, (size_t)len);
    xl_test_aired[len] = 0;
    xl_test_aired_len = len;
    xl_test_air_count++;
    return true;
}

#else /* on the device */

#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_random.h"

static const char *TAG = "xprslan";
#define XL_LOGI(fmt, ...) ESP_LOGI(TAG, fmt, ##__VA_ARGS__)
#define XL_LOGW(fmt, ...) ESP_LOGW(TAG, fmt, ##__VA_ARGS__)
#define XL_LOGD(fmt, ...) ESP_LOGD(TAG, fmt, ##__VA_ARGS__)

static int s_fd = -1;

static uint32_t xl_now_ms(void) { return (uint32_t)(esp_timer_get_time() / 1000); }
static uint32_t xl_random(void) { return esp_random(); }

/* One datagram to everyone on the wire. */
static bool xl_air(const char *wire, int len)
{
    if (s_fd < 0) return false;
    struct sockaddr_in to = {
        .sin_family = AF_INET,
        .sin_port = htons(XPRSLAN_PORT),
        .sin_addr.s_addr = htonl(INADDR_BROADCAST),
    };
    int n = sendto(s_fd, wire, (size_t)len, 0, (struct sockaddr *)&to, sizeof to);
    if (n != len) {
        XL_LOGW("sendto failed: errno %d", errno);
        return false;
    }
    return true;
}

#endif

/* ── State ──────────────────────────────────────────────────────────────── */

#define XL_ID_LEN     XPRS_ID_LEN     /* 6 hex + NUL (§5) */
#define XL_SEEN_RING  32              /* identifiers remembered, for both rings */
#define XL_SEEN_MS    60000u          /* how long "already heard" lasts */

typedef struct {
    char     wire[XPRSLAN_WIRE_MAX + 1];
    int      len;
    char     id[XL_ID_LEN];
    uint32_t due_ms;
    bool     used;
} xl_queued_t;

typedef struct {
    char     id[XL_ID_LEN];
    uint32_t t_ms;
} xl_seen_t;

typedef struct {
    uint32_t ip;
    uint32_t t_ms;
} xl_peer_t;

static char        s_call[16];
static bool        s_active;
static xl_queued_t s_queue[XPRSLAN_QUEUE_MAX];
static xl_seen_t   s_heard[XL_SEEN_RING];   /* seen on the LAN */
static int         s_heard_pos;
static xl_seen_t   s_aired[XL_SEEN_RING];   /* put on the LAN by us */
static int         s_aired_pos;
static xl_peer_t   s_peers[XPRSLAN_PEERS_MAX];
static xprslan_rx_cb_t s_rx_cb;
static xprslan_heard_cb_t s_heard_cb;
static xprslan_beacon_cb_t s_beacon_cb;
static uint32_t    s_beacon_every_ms, s_beacon_due_ms;
static uint32_t    s_rx_count, s_tx_count, s_cancelled;

/* ── Identifier rings ───────────────────────────────────────────────────── */

static bool xl_ring_has(const xl_seen_t *ring, const char *id, uint32_t now)
{
    for (int i = 0; i < XL_SEEN_RING; i++) {
        if (!ring[i].id[0]) continue;
        if (now - ring[i].t_ms >= XL_SEEN_MS) continue;
        if (strcmp(ring[i].id, id) == 0) return true;
    }
    return false;
}

static void xl_ring_add(xl_seen_t *ring, int *pos, const char *id, uint32_t now)
{
    snprintf(ring[*pos].id, XL_ID_LEN, "%s", id);
    ring[*pos].t_ms = now;
    *pos = (*pos + 1) % XL_SEEN_RING;
}

/* ── The queue ──────────────────────────────────────────────────────────── */

/* Somebody aired this identifier. Anything of ours waiting to say the same
 * thing is now pointless — this is the whole reason for the delay. */
static void xl_cancel(const char *id)
{
    for (int i = 0; i < XPRSLAN_QUEUE_MAX; i++) {
        if (!s_queue[i].used) continue;
        if (strcmp(s_queue[i].id, id) != 0) continue;
        s_queue[i].used = false;
        s_cancelled++;
        XL_LOGI("%s already aired by somebody else — dropping our copy", id);
    }
}

/* Air everything whose moment has come. Returns how many went out. */
static int xl_pump(uint32_t now)
{
    int sent = 0;
    for (int i = 0; i < XPRSLAN_QUEUE_MAX; i++) {
        if (!s_queue[i].used) continue;
        if ((int32_t)(now - s_queue[i].due_ms) < 0) continue;
        s_queue[i].used = false;
        if (xl_air(s_queue[i].wire, s_queue[i].len)) {
            xl_ring_add(s_aired, &s_aired_pos, s_queue[i].id, now);
            s_tx_count++;
            sent++;
        }
    }
    return sent;
}

static void xl_queue_push(const char *wire, int len, const char *id, uint32_t now)
{
    uint32_t span = XPRSLAN_JITTER_MAX_MS - XPRSLAN_JITTER_MIN_MS;
    uint32_t due = now + XPRSLAN_JITTER_MIN_MS + (xl_random() % (span + 1));

    int slot = -1;
    for (int i = 0; i < XPRSLAN_QUEUE_MAX; i++) {
        if (!s_queue[i].used) { slot = i; break; }
    }
    if (slot < 0) {                     /* full — the one closest to its moment
                                           has waited longest, so keep it */
        slot = 0;
        for (int i = 1; i < XPRSLAN_QUEUE_MAX; i++) {
            if ((int32_t)(s_queue[i].due_ms - s_queue[slot].due_ms) > 0) slot = i;
        }
        XL_LOGW("re-air queue full — dropping %s for %s", s_queue[slot].id, id);
    }
    memcpy(s_queue[slot].wire, wire, (size_t)len);
    s_queue[slot].wire[len] = 0;
    s_queue[slot].len = len;
    snprintf(s_queue[slot].id, XL_ID_LEN, "%s", id);
    s_queue[slot].due_ms = due;
    s_queue[slot].used = true;
}

/* ── Offering a packet from another bearer ──────────────────────────────── */

void xprslan_offer(const char *wire, int len)
{
    if (!s_active || !wire || len <= 0 || len > XPRSLAN_WIRE_MAX) return;
    if (!xprs_looks_like((const uint8_t *)wire, len)) return;

    char id[XL_ID_LEN];
    if (!xprs_id_of(wire, len, id)) return;

    uint32_t now = xl_now_ms();
    /* Already on the LAN, from us or from anybody: nothing to add. */
    if (xl_ring_has(s_aired, id, now) || xl_ring_has(s_heard, id, now)) return;
    for (int i = 0; i < XPRSLAN_QUEUE_MAX; i++) {
        if (s_queue[i].used && strcmp(s_queue[i].id, id) == 0) return;
    }

    /* Whether this may be relayed at all is geogram_xprs's decision, not ours:
     * -1 means we are already in via: (§13.2) or the type's budget is spent
     * (§13.1). Relaying is also what puts us in the path for everyone else. */
    char out[XPRSLAN_WIRE_MAX + 1];
    int n = xprs_append_via(wire, len, s_call, out, (int)sizeof out);
    if (n <= 0) return;

    xl_queue_push(out, n, id, now);
}

/* ── Receiving ──────────────────────────────────────────────────────────── */

static void xl_peer_touch(uint32_t ip, uint32_t now)
{
    int slot = -1, oldest = 0;
    for (int i = 0; i < XPRSLAN_PEERS_MAX; i++) {
        if (s_peers[i].ip == ip || s_peers[i].ip == 0) { slot = i; break; }
        if ((int32_t)(s_peers[i].t_ms - s_peers[oldest].t_ms) < 0) oldest = i;
    }
    if (slot < 0) slot = oldest;
    s_peers[slot].ip = ip;
    s_peers[slot].t_ms = now;
}

/* One datagram. Anything that is not an XPRS packet is not our business. */
static void xl_on_datagram(const char *wire, int len, uint32_t ip)
{
    if (len <= 0 || len > XPRSLAN_WIRE_MAX) return;
    if (!xprs_looks_like((const uint8_t *)wire, len)) return;

    char id[XL_ID_LEN];
    if (!xprs_id_of(wire, len, id)) return;

    uint32_t now = xl_now_ms();
    if (ip) xl_peer_touch(ip, now);
    s_rx_count++;

    /* Only a copy that has ALREADY been relayed cancels ours. The origin
     * repeating itself is the opposite signal — it means nobody has carried the
     * packet yet, which is exactly when a digipeater should — so `via:` is what
     * distinguishes "somebody else got there first" from "say it again". */
    xprs_t hp;
    bool relayed_by_other = xprs_parse(wire, len, &hp) && xprs_via_count(&hp) > 0;
    if (relayed_by_other) xl_cancel(id);
    /* Every hearing, duplicates included — an owner with its own queue on
     * another bearer needs the repeats, which is exactly what the line below
     * throws away. */
    if (s_heard_cb) s_heard_cb(id, wire, len);

    if (xl_ring_has(s_heard, id, now)) return;   /* the LAN repeats itself */
    xl_ring_add(s_heard, &s_heard_pos, id, now);

    if (s_rx_cb) s_rx_cb(wire, len, ip);
}

/* ── Our own packets ────────────────────────────────────────────────────── */

bool xprslan_send(const char *wire, int len)
{
    if (!s_active || !wire || len <= 0 || len > XPRSLAN_WIRE_MAX) return false;
    if (!xprs_looks_like((const uint8_t *)wire, len)) return false;

    uint32_t now = xl_now_ms();
    char id[XL_ID_LEN];
    if (xprs_id_of(wire, len, id)) xl_ring_add(s_aired, &s_aired_pos, id, now);

    if (!xl_air(wire, len)) return false;
    s_tx_count++;
    return true;
}

void xprslan_set_rx_cb(xprslan_rx_cb_t cb) { s_rx_cb = cb; }
void xprslan_set_heard_cb(xprslan_heard_cb_t cb) { s_heard_cb = cb; }

void xprslan_set_beacon(xprslan_beacon_cb_t cb, uint32_t interval_sec,
                        uint32_t first_delay_sec)
{
    s_beacon_cb = cb;
    s_beacon_every_ms = interval_sec * 1000u;
    s_beacon_due_ms = xl_now_ms() + first_delay_sec * 1000u;
}

/* Called from the bearer's task, nowhere else. */
static void xl_beacon_tick(uint32_t now)
{
    if (!s_beacon_cb || !s_beacon_every_ms) return;
    if ((int32_t)(now - s_beacon_due_ms) < 0) return;
    s_beacon_due_ms = now + s_beacon_every_ms;

    char wire[XPRSLAN_WIRE_MAX + 1];
    int n = s_beacon_cb(wire, (int)sizeof wire);
    if (n > 0) xprslan_send(wire, n);
}
bool xprslan_is_active(void) { return s_active; }

int xprslan_peer_count(uint32_t max_age_sec)
{
    uint32_t now = xl_now_ms();
    int n = 0;
    for (int i = 0; i < XPRSLAN_PEERS_MAX; i++) {
        if (!s_peers[i].ip) continue;
        if (max_age_sec && (now - s_peers[i].t_ms) >= max_age_sec * 1000u) continue;
        n++;
    }
    return n;
}

void xprslan_stats(uint32_t *out_rx, uint32_t *out_tx, uint32_t *out_cancelled)
{
    if (out_rx) *out_rx = s_rx_count;
    if (out_tx) *out_tx = s_tx_count;
    if (out_cancelled) *out_cancelled = s_cancelled;
}

/* ── The socket and its task ────────────────────────────────────────────── */

#ifndef XPRSLAN_HOST_TEST

static void xprslan_task(void *arg)
{
    (void)arg;
    static char buf[XPRSLAN_WIRE_MAX + 32];
    for (;;) {
        struct sockaddr_in src;
        socklen_t slen = sizeof src;
        struct timeval tv = { .tv_sec = 0, .tv_usec = 100000 };  /* 100 ms */
        setsockopt(s_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);

        int n = recvfrom(s_fd, buf, sizeof(buf) - 1, 0,
                         (struct sockaddr *)&src, &slen);
        if (n > 0) {
            /* Our own broadcast is not looped back to this socket by lwip, and
             * if a stack ever did, the identifier rings would drop it — so
             * there is no source-address check to get wrong. */
            buf[n] = 0;
            xl_on_datagram(buf, n, src.sin_addr.s_addr);
        }
        /* The same task airs what is due: one place, no locking, and the delay
         * is measured in hundreds of milliseconds so 100 ms of granularity is
         * well inside the jitter it is implementing. */
        uint32_t now = xl_now_ms();
        xl_pump(now);
        xl_beacon_tick(now);
    }
}

esp_err_t xprslan_start(const char *callsign)
{
    if (s_active) return ESP_OK;
    snprintf(s_call, sizeof s_call, "%s", callsign ? callsign : "");

    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
    if (fd < 0) {
        XL_LOGW("socket() failed: errno %d", errno);
        return ESP_FAIL;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, sizeof one);

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(XPRSLAN_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        XL_LOGW("bind(%u) failed: errno %d", XPRSLAN_PORT, errno);
        close(fd);
        return ESP_FAIL;
    }

    s_fd = fd;
    s_active = true;
    /* 5 KB. Every datagram costs two SHA-256 derivations (the identifier here,
     * and again when the index decides on it), a BLE re-air and a log line, all
     * on this stack — 4 KB overflowed under a burst and took the board down. */
    if (xTaskCreate(xprslan_task, "xprslan", 5120, NULL, 3, NULL) != pdPASS) {
        XL_LOGW("task create failed");
        close(fd);
        s_fd = -1;
        s_active = false;
        return ESP_FAIL;
    }
    XL_LOGI("XPRS on the LAN: UDP %u, callsign %s", XPRSLAN_PORT, s_call);
    return ESP_OK;
}

void xprslan_stop(void)
{
    s_active = false;
    if (s_fd >= 0) { close(s_fd); s_fd = -1; }
}

#else /* host: the test drives these directly */

esp_err_t xprslan_start(const char *callsign)
{
    snprintf(s_call, sizeof s_call, "%s", callsign ? callsign : "");
    s_active = true;
    return 0;
}
void xprslan_stop(void) { s_active = false; }

/* Handles the host test reaches for. */
void xl_test_datagram(const char *wire, int len, uint32_t ip)
{
    xl_on_datagram(wire, len, ip);
}
int xl_test_pump(uint32_t now)
{
    int n = xl_pump(now);
    xl_beacon_tick(now);       /* the device runs both from the same task */
    return n;
}
void xl_test_reset(void)
{
    memset(s_queue, 0, sizeof s_queue);
    memset(s_heard, 0, sizeof s_heard);
    memset(s_aired, 0, sizeof s_aired);
    memset(s_peers, 0, sizeof s_peers);
    s_heard_pos = s_aired_pos = 0;
    s_rx_count = s_tx_count = s_cancelled = 0;
    xl_test_air_count = 0;
    xl_test_aired_len = 0;
    xl_test_aired[0] = 0;
}
int xl_test_queue_len(void)
{
    int n = 0;
    for (int i = 0; i < XPRSLAN_QUEUE_MAX; i++) if (s_queue[i].used) n++;
    return n;
}
uint32_t xl_test_queue_due(int i) { return s_queue[i].due_ms; }

#endif
