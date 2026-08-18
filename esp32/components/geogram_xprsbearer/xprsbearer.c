/*
 * xprsbearer — the half of a bearer that has nothing to do with the radio.
 *
 * Lifted verbatim from geogram_xprslan, which had already isolated it behind
 * three hooks; the only real change is that the state is now per-instance and
 * a peer is an opaque 64-bit number rather than an IPv4 address, so a MAC fits.
 *
 * Read xprsbearer.h first. The two rules worth knowing before changing
 * anything here:
 *
 *   - a copy that has ALREADY been relayed cancels ours; the origin repeating
 *     itself does the opposite (xb_on_wire)
 *   - whether a packet may be relayed at all is xprs_append_via's decision
 */

#include "xprsbearer.h"

#include <string.h>
#include <stdio.h>

#ifdef XB_HOST_TEST
#define XB_LOGI(fmt, ...) ((void)0)
#define XB_LOGW(fmt, ...) ((void)0)
#else
#include "esp_log.h"
static const char *TAG = "xprsbearer";
#define XB_LOGI(fmt, ...) ESP_LOGI(TAG, fmt, ##__VA_ARGS__)
#define XB_LOGW(fmt, ...) ESP_LOGW(TAG, fmt, ##__VA_ARGS__)
#endif

#define XB_LOCK(b)   do { if ((b)->ops.lock) (b)->ops.lock((b)->ops.ctx); } while (0)
#define XB_UNLOCK(b) do { if ((b)->ops.unlock) (b)->ops.unlock((b)->ops.ctx); } while (0)

/* ── Identifier rings ───────────────────────────────────────────────────── */

static bool xb_ring_has(const xb_seen_t *ring, const char *id, uint32_t now)
{
    for (int i = 0; i < XB_SEEN_RING; i++) {
        if (!ring[i].id[0]) continue;
        if (now - ring[i].t_ms >= XB_SEEN_MS) continue;
        if (strcmp(ring[i].id, id) == 0) return true;
    }
    return false;
}

static void xb_ring_add(xb_seen_t *ring, int *pos, const char *id, uint32_t now)
{
    snprintf(ring[*pos].id, XB_ID_LEN, "%s", id);
    ring[*pos].t_ms = now;
    *pos = (*pos + 1) % XB_SEEN_RING;
}

/* ── The queue ──────────────────────────────────────────────────────────── */

/* Somebody aired this identifier. Anything of ours waiting to say the same
 * thing is now pointless — this is the whole reason for the delay. */
static void xb_cancel(xb_t *b, const char *id)
{
    for (int i = 0; i < XB_QUEUE_MAX; i++) {
        if (!b->queue[i].used) continue;
        if (strcmp(b->queue[i].id, id) != 0) continue;
        b->queue[i].used = false;
        b->cancelled++;
        XB_LOGI("%s: %s already aired by somebody else — dropping our copy",
                b->ops.name ? b->ops.name : "?", id);
    }
}

static int xb_pump(xb_t *b, uint32_t now)
{
    int sent = 0;
    for (int i = 0; i < XB_QUEUE_MAX; i++) {
        if (!b->queue[i].used) continue;
        if ((int32_t)(now - b->queue[i].due_ms) < 0) continue;
        b->queue[i].used = false;
        XB_LOCK(b);
        bool ok = b->ops.air(b->ops.ctx, b->queue[i].wire, b->queue[i].len);
        if (ok) {
            xb_ring_add(b->aired, &b->aired_pos, b->queue[i].id, now);
            b->tx_count++;
        }
        XB_UNLOCK(b);
        if (ok) sent++;
    }
    return sent;
}

static void xb_queue_push(xb_t *b, const char *wire, int len, const char *id,
                          uint32_t now)
{
    uint32_t span = XB_JITTER_MAX_MS - XB_JITTER_MIN_MS;
    uint32_t due = now + XB_JITTER_MIN_MS + (b->ops.random() % (span + 1));

    int slot = -1;
    for (int i = 0; i < XB_QUEUE_MAX; i++) {
        if (!b->queue[i].used) { slot = i; break; }
    }
    if (slot < 0) {                     /* full — the one closest to its moment
                                           has waited longest, so keep it */
        slot = 0;
        for (int i = 1; i < XB_QUEUE_MAX; i++) {
            if ((int32_t)(b->queue[i].due_ms - b->queue[slot].due_ms) > 0) slot = i;
        }
        XB_LOGW("%s: re-air queue full — dropping %s for %s",
                b->ops.name ? b->ops.name : "?", b->queue[slot].id, id);
    }
    memcpy(b->queue[slot].wire, wire, (size_t)len);
    b->queue[slot].wire[len] = 0;
    b->queue[slot].len = len;
    snprintf(b->queue[slot].id, XB_ID_LEN, "%s", id);
    b->queue[slot].due_ms = due;
    b->queue[slot].used = true;
}

/* ── Offering a packet from another bearer ──────────────────────────────── */

void xb_offer(xb_t *b, const char *wire, int len)
{
    if (!b || !b->active || !wire || len <= 0 || len > XB_WIRE_MAX) return;
    if (!xprs_looks_like((const uint8_t *)wire, len)) return;

    char id[XB_ID_LEN];
    if (!xprs_id_of(wire, len, id)) return;

    uint32_t now = b->ops.now_ms();
    /* Already on this bearer, from us or from anybody: nothing to add. */
    if (xb_ring_has(b->aired, id, now) || xb_ring_has(b->heard, id, now)) return;
    for (int i = 0; i < XB_QUEUE_MAX; i++) {
        if (b->queue[i].used && strcmp(b->queue[i].id, id) == 0) return;
    }

    /* Whether this may be relayed at all is geogram_xprs's decision, not ours:
     * -1 means we are already in via: (§13.2) or the type's budget is spent
     * (§13.1). Relaying is also what puts us in the path for everyone else. */
    char out[XB_WIRE_MAX + 1];
    int n = xprs_append_via(wire, len, b->call, out, (int)sizeof out);
    if (n <= 0) return;

    xb_queue_push(b, out, n, id, now);
}

/* ── Receiving ──────────────────────────────────────────────────────────── */

static void xb_peer_touch(xb_t *b, uint64_t peer, uint32_t now)
{
    int slot = -1, oldest = 0;
    for (int i = 0; i < XB_PEERS_MAX; i++) {
        if (b->peers[i].peer == peer || b->peers[i].peer == 0) { slot = i; break; }
        if ((int32_t)(b->peers[i].t_ms - b->peers[oldest].t_ms) < 0) oldest = i;
    }
    if (slot < 0) slot = oldest;
    b->peers[slot].peer = peer;
    b->peers[slot].t_ms = now;
}

void xb_on_wire(xb_t *b, const char *wire, int len, uint64_t peer, int rssi)
{
    if (!b || len <= 0 || len > XB_WIRE_MAX) return;
    if (!xprs_looks_like((const uint8_t *)wire, len)) return;

    char id[XB_ID_LEN];
    if (!xprs_id_of(wire, len, id)) return;

    uint32_t now = b->ops.now_ms();
    if (peer) xb_peer_touch(b, peer, now);
    b->rx_count++;

    /* Only a copy that has ALREADY been relayed cancels ours. The origin
     * repeating itself is the opposite signal — it means nobody has carried the
     * packet yet, which is exactly when a digipeater should — so `via:` is what
     * distinguishes "somebody else got there first" from "say it again". */
    xprs_t hp;
    bool relayed_by_other = xprs_parse(wire, len, &hp) && xprs_via_count(&hp) > 0;
    if (relayed_by_other) xb_cancel(b, id);
    /* Every hearing, duplicates included — an owner with its own queue on
     * another bearer needs the repeats, which is exactly what the line below
     * throws away. */
    if (b->heard_cb) b->heard_cb(id, wire, len);

    if (xb_ring_has(b->heard, id, now)) {
        /* Say so, rate-limited. Silent duplicate-suppression hid a real bug:
         * §23.7's step 4 re-airs the SAME packet deliberately, and it died here
         * without a word for as long as it took to read the code. */
        b->dupes++;
        if (b->dupes == 1 || (b->dupes % 32) == 0) {
            XB_LOGI("%s: %s heard again — swallowed (%u so far)",
                    b->ops.name ? b->ops.name : "?", id, (unsigned)b->dupes);
        }
        return;
    }
    xb_ring_add(b->heard, &b->heard_pos, id, now);

    if (b->rx_cb) b->rx_cb(wire, len, peer, rssi);
}

/* ── Our own packets ────────────────────────────────────────────────────── */

bool xb_send(xb_t *b, const char *wire, int len)
{
    if (!b || !b->active || !wire || len <= 0 || len > XB_WIRE_MAX) return false;
    if (!xprs_looks_like((const uint8_t *)wire, len)) return false;

    uint32_t now = b->ops.now_ms();
    char id[XB_ID_LEN];
    bool have_id = xprs_id_of(wire, len, id);   /* a SHA-256: outside the lock */

    XB_LOCK(b);
    if (have_id) xb_ring_add(b->aired, &b->aired_pos, id, now);
    bool ok = b->ops.air(b->ops.ctx, wire, len);
    if (ok) b->tx_count++;
    XB_UNLOCK(b);
    return ok;
}

/* ── Beacon and tick ────────────────────────────────────────────────────── */

void xb_set_rx_cb(xb_t *b, xb_rx_cb_t cb)       { if (b) b->rx_cb = cb; }
void xb_set_heard_cb(xb_t *b, xb_heard_cb_t cb) { if (b) b->heard_cb = cb; }

void xb_set_beacon(xb_t *b, xb_beacon_cb_t cb, uint32_t interval_sec,
                   uint32_t first_delay_sec)
{
    if (!b) return;
    b->beacon_cb = cb;
    b->beacon_every_ms = interval_sec * 1000u;
    b->beacon_due_ms = b->ops.now_ms() + first_delay_sec * 1000u;
}

static void xb_beacon_tick(xb_t *b, uint32_t now)
{
    if (!b->beacon_cb || !b->beacon_every_ms) return;
    if ((int32_t)(now - b->beacon_due_ms) < 0) return;
    b->beacon_due_ms = now + b->beacon_every_ms;

    char wire[XB_WIRE_MAX + 1];
    int n = b->beacon_cb(wire, (int)sizeof wire);
    if (n > 0) xb_send(b, wire, n);
}

void xb_tick(xb_t *b, uint32_t now_ms)
{
    if (!b || !b->active) return;
    /* Inbound first: a packet heard this tick can still cancel a re-air that
     * was due this tick, which is the whole point of §13.2.1. */
    if (b->ops.drain) b->ops.drain(b->ops.ctx);
    xb_pump(b, now_ms);
    xb_beacon_tick(b, now_ms);
}

/* Every bearer that asked to be driven by somebody else's task. Four is more
 * than this firmware has bearers; the array exists so the driver does not need
 * to know who they are. */
#define XB_TICKED_MAX 4
static xb_t *s_ticked[XB_TICKED_MAX];
static int   s_ticked_n;
static bool  s_have_driver;

void xb_register_ticked(xb_t *b)
{
    if (!b) return;
    for (int i = 0; i < s_ticked_n; i++) if (s_ticked[i] == b) return;
    if (s_ticked_n >= XB_TICKED_MAX) {
        XB_LOGW("no room to drive %s — it will not re-air or beacon",
                b->ops.name ? b->ops.name : "?");
        return;
    }
    s_ticked[s_ticked_n++] = b;
}

void xb_tick_all(uint32_t now_ms)
{
    for (int i = 0; i < s_ticked_n; i++) xb_tick(s_ticked[i], now_ms);
}

bool xb_has_driver(void) { return s_have_driver; }
void xb_set_driver(bool yes) { s_have_driver = yes; }

/* ── Lifecycle and observation ──────────────────────────────────────────── */

void xb_init(xb_t *b, const xb_ops_t *ops, const char *call)
{
    if (!b || !ops || !ops->air || !ops->now_ms || !ops->random) return;
    memset(b, 0, sizeof *b);
    b->ops = *ops;
    snprintf(b->call, sizeof b->call, "%s", call ? call : "");
    b->active = true;
}

void xb_stop(xb_t *b) { if (b) b->active = false; }
bool xb_is_active(const xb_t *b) { return b && b->active; }

int xb_peer_count(const xb_t *b, uint32_t max_age_sec)
{
    if (!b) return 0;
    uint32_t now = b->ops.now_ms();
    int n = 0;
    for (int i = 0; i < XB_PEERS_MAX; i++) {
        if (!b->peers[i].peer) continue;
        if (max_age_sec && (now - b->peers[i].t_ms) >= max_age_sec * 1000u) continue;
        n++;
    }
    return n;
}

void xb_stats(const xb_t *b, uint32_t *rx, uint32_t *tx, uint32_t *cancelled)
{
    if (rx) *rx = b ? b->rx_count : 0;
    if (tx) *tx = b ? b->tx_count : 0;
    if (cancelled) *cancelled = b ? b->cancelled : 0;
}
