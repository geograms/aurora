/*
 * blemesh_session — MSP v1 codec + session FSM (see blemesh_session.h).
 *
 * Byte-for-byte mirror of aurora lib/services/mesh/mesh_session.dart. Keep
 * the two in lockstep: any wire change lands in BOTH files and in the shared
 * fixtures (aurora test/mesh_session_test.dart / test_msp_host.c).
 *
 * Divergences from the Dart FSM, deliberate and wire-compatible:
 *  - MSG_ACKs go out immediately (count=1) instead of the phone's 150 ms
 *    batch timer — no timer infra here, and acks are tiny.
 *  - BLEMESH_SEND_BUSY only pauses the bulk chunk pump; a busy transport on
 *    a control frame drops it and relies on stall recovery (WIN_ACK resync,
 *    session stall timeout). GATT notify queues are deep enough in practice.
 */
#include "blemesh_session.h"

#include <string.h>

#include "blemesh.h"

/* ---- have-digest bloom (must match aurora mesh_bloom.dart) ----------------- */
static const uint8_t k_bloom_salts[4] = { 0x00, 0x55, 0xAA, 0xFF };

static uint32_t fnv1a32(uint8_t salt, const char *s)
{
    uint32_t h = 0x811C9DC5u;
    h ^= salt;
    h *= 0x01000193u;
    for (; *s; s++) {
        h ^= (uint8_t)*s;
        h *= 0x01000193u;
    }
    return h;
}

void blemesh_bloom_add(uint8_t bloom[BLEMESH_BLOOM_BYTES], const char *am)
{
    for (int i = 0; i < 4; i++) {
        uint32_t bit = fnv1a32(k_bloom_salts[i], am) % (BLEMESH_BLOOM_BYTES * 8);
        bloom[bit >> 3] |= (uint8_t)(1 << (bit & 7));
    }
}

bool blemesh_bloom_has(const uint8_t *bloom, int len, const char *am)
{
    if (len < BLEMESH_BLOOM_BYTES) return false;
    for (int i = 0; i < 4; i++) {
        uint32_t bit = fnv1a32(k_bloom_salts[i], am) % (BLEMESH_BLOOM_BYTES * 8);
        if (!(bloom[bit >> 3] & (1 << (bit & 7)))) return false;
    }
    return true;
}

/* ---- little-endian writers/readers ---------------------------------------- */
static inline void w16(uint8_t *b, uint16_t v) { b[0] = v & 0xFF; b[1] = v >> 8; }
static inline void w32(uint8_t *b, uint32_t v)
{
    b[0] = v & 0xFF; b[1] = (v >> 8) & 0xFF;
    b[2] = (v >> 16) & 0xFF; b[3] = (v >> 24) & 0xFF;
}
static inline void w64(uint8_t *b, uint64_t v)
{
    for (int i = 0; i < 8; i++) b[i] = (uint8_t)(v >> (8 * i));
}
static inline uint16_t r16(const uint8_t *b) { return (uint16_t)(b[0] | (b[1] << 8)); }
static inline uint32_t r32(const uint8_t *b)
{
    return (uint32_t)b[0] | ((uint32_t)b[1] << 8) |
           ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}
static inline uint64_t r64(const uint8_t *b)
{
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v |= (uint64_t)b[i] << (8 * i);
    return v;
}

/* Callsign-style string: [len u8][ASCII]. Returns bytes consumed or -1. */
static int w_cs(uint8_t *b, const char *s, int max)
{
    int n = 0;
    while (s[n] && n < max) n++;
    b[0] = (uint8_t)n;
    memcpy(b + 1, s, n);
    return 1 + n;
}
static int r_cs(const uint8_t *d, int len, char *out, int out_cap)
{
    if (len < 1) return -1;
    int n = d[0];
    if (n >= out_cap || 1 + n > len) return -1;
    memcpy(out, d + 1, n);
    out[n] = 0;
    return 1 + n;
}

static inline int env(uint8_t *b, uint8_t type)
{
    b[0] = BLEMESH_MSP_MAGIC;
    b[1] = BLEMESH_MSP_VER;
    b[2] = type;
    return 3;
}

/* ---- send helpers ---------------------------------------------------------- */
static void session_end(blemesh_session_t *s, bool clean);

/* Send a control frame. BUSY drops (stall recovery covers it); other
 * negatives kill the session. Returns 0 on success. */
static int ctl_send(blemesh_session_t *s, const uint8_t *f, int len)
{
    int rc = s->ops->send(s->ops->ctx, f, len);
    if (rc == BLEMESH_SEND_BUSY) return -1;
    if (rc < 0) { session_end(s, false); return -1; }
    return 0;
}

static void send_hello(blemesh_session_t *s)
{
    if (s->hello_sent) return;
    s->hello_sent = true;
    uint8_t f[64];
    int o = env(f, MSP_HELLO);
    w16(f + o, s->caps); o += 2;
    o += w_cs(f + o, s->self, BLEMESH_CALLSIGN_MAX);
    w16(f + o, s->max_frame); o += 2;
    w32(f + o, s->spool_free_kb); o += 4;
    w16(f + o, s->pending_msgs); o += 2;
    f[o++] = s->pending_bulk;
    ctl_send(s, f, o);
}

static void send_bye(blemesh_session_t *s, uint8_t reason)
{
    uint8_t f[4];
    int o = env(f, MSP_BYE);
    f[o++] = reason;
    ctl_send(s, f, o);
}

/* ---- custody lane ----------------------------------------------------------- */
static int out_slots_used(const blemesh_session_t *s)
{
    int n = 0;
    for (int i = 0; i < MSP_MSG_OUT_MAX; i++) if (s->out_msgs[i].used) n++;
    return n;
}

static void drain_custody(blemesh_session_t *s)
{
    if (s->state != 1 || !(s->peer_caps & MSP_CAP_MSG)) return;
    while (out_slots_used(s) < MSP_MSG_OUT_MAX) {
        int slot = -1;
        for (int i = 0; i < MSP_MSG_OUT_MAX; i++)
            if (!s->out_msgs[i].used) { slot = i; break; }
        if (slot < 0) break;

        char am[7] = "";
        uint8_t wire[BLEMESH_SCF_FRAME_MAX];
        uint32_t ts = 0;
        int wl = s->ops->msg_pop(s->ops->ctx, s->peer, am, wire, sizeof(wire), &ts);
        if (wl <= 0) break;

        s->next_seq = (uint8_t)(s->next_seq + 1);
        uint8_t seq = s->next_seq;

        uint8_t f[3 + 2 + 6 + 4 + 2 + BLEMESH_SCF_FRAME_MAX];
        int o = env(f, MSP_MSG);
        f[o++] = seq;
        f[o++] = am[0] ? 1 : 0;
        uint8_t amb[6] = {0};
        for (int i = 0; i < 6 && am[i]; i++) amb[i] = (uint8_t)am[i];
        memcpy(f + o, amb, 6); o += 6;
        w32(f + o, ts); o += 4;
        w16(f + o, (uint16_t)wl); o += 2;
        memcpy(f + o, wire, wl); o += wl;
        if (ctl_send(s, f, o) != 0) return;

        s->out_msgs[slot].used = true;
        s->out_msgs[slot].seq = seq;
        memcpy(s->out_msgs[slot].am, am, 7);
    }
    s->custody_drained = true;
}

static void on_msg(blemesh_session_t *s, const uint8_t *d, int len)
{
    if (len < 1 + 1 + 6 + 4 + 2) return;
    uint8_t seq = d[0];
    uint8_t flags = d[1];
    char am[7] = "";
    if (flags & 1) {
        int n = 0;
        for (int i = 0; i < 6; i++) if (d[2 + i]) am[n++] = (char)d[2 + i];
        am[n] = 0;
    }
    uint32_t ts = r32(d + 8);
    int wl = r16(d + 12);
    if (14 + wl > len) return;

    int rc = s->ops->msg_rx(s->ops->ctx, s->peer, am, ts, d + 14, wl);
    if (rc == 0 || rc == MSP_REJ_DUP) {
        uint8_t f[8];
        int o = env(f, MSP_MSG_ACK);
        f[o++] = 1;
        f[o++] = seq;
        ctl_send(s, f, o);
    } else {
        uint8_t f[8];
        int o = env(f, MSP_MSG_REJ);
        f[o++] = seq;
        f[o++] = (uint8_t)rc;
        ctl_send(s, f, o);
    }
}

static void maybe_start_bulk(blemesh_session_t *s, uint32_t now);

static void ack_seq(blemesh_session_t *s, uint8_t seq, bool transferred)
{
    for (int i = 0; i < MSP_MSG_OUT_MAX; i++) {
        if (s->out_msgs[i].used && s->out_msgs[i].seq == seq) {
            if (transferred)
                s->ops->msg_transferred(s->ops->ctx, s->peer, s->out_msgs[i].am);
            s->out_msgs[i].used = false;
            return;
        }
    }
}

/* ---- bulk lane --------------------------------------------------------------- */
static void maybe_start_bulk(blemesh_session_t *s, uint32_t now)
{
    if (s->state != 1 || s->tx_active || s->rx_active) return;
    if (!(s->peer_caps & MSP_CAP_BULK_RX)) return;
    if (now - s->opened_at > MSP_SESSION_CAP) return;

    uint64_t size = 0;
    uint32_t ttl = 0;
    char origin[10] = "", target[10] = "", ext[17] = "", name[65] = "";
    if (!s->ops->bulk_next || !s->ops->bulk_next(s->ops->ctx, s->peer, s->tx_sha,
                                                 &size, &ttl, origin, target,
                                                 ext, name))
        return;

    s->tx_active = true;
    s->tx_size = size;
    s->tx_offset = 0;
    s->tx_window = 0;
    s->tx_done_sent = false;
    s->tx_xfer = (now << 8) ^ (uint32_t)(s->next_seq + 1) ^ (uint32_t)size;

    uint8_t f[3 + 4 + 32 + 8 + 4 + 10 + 10 + 17 + 66];
    int o = env(f, MSP_FILE_OFFER);
    w32(f + o, s->tx_xfer); o += 4;
    memcpy(f + o, s->tx_sha, 32); o += 32;
    w64(f + o, size); o += 8;
    w32(f + o, ttl); o += 4;
    o += w_cs(f + o, origin, BLEMESH_CALLSIGN_MAX);
    o += w_cs(f + o, target, BLEMESH_CALLSIGN_MAX);
    o += w_cs(f + o, ext, 16);
    o += w_cs(f + o, name, 64);
    if (ctl_send(s, f, o) != 0) s->tx_active = false;
}

static int chunk_cap(const blemesh_session_t *s)
{
    int mf = s->max_frame;
    if (s->peer_max_frame && s->peer_max_frame < mf) mf = s->peer_max_frame;
    int c = mf - MSP_CHUNK_HEADER;
    if (c > 501) c = 501;   /* pump_chunks stack buffer bound */
    return c < 16 ? 16 : c;
}

/* Send granted chunks until the window, EOF, or a busy transport. */
static void pump_chunks(blemesh_session_t *s, uint32_t now)
{
    if (!s->tx_active || s->state != 1) return;
    int cap = chunk_cap(s);
    uint8_t f[3 + 4 + 4 + 512];

    while (s->tx_window > 0 && s->tx_offset < s->tx_size) {
        int want = cap;
        if ((uint64_t)want > s->tx_size - s->tx_offset)
            want = (int)(s->tx_size - s->tx_offset);
        int o = env(f, MSP_CHUNK);
        w32(f + o, s->tx_xfer); o += 4;
        w32(f + o, s->tx_offset); o += 4;
        int got = s->ops->bulk_read(s->ops->ctx, s->tx_sha, s->tx_offset,
                                    f + o, want);
        if (got <= 0) {
            uint8_t e[9];
            int eo = env(e, MSP_FILE_FAIL);
            w32(e + eo, s->tx_xfer); eo += 4;
            e[eo++] = MSP_FAIL_IO;
            ctl_send(s, e, eo);
            s->tx_active = false;
            s->ops->bulk_done(s->ops->ctx, s->peer, s->tx_sha, 0, 1);
            return;
        }
        int rc = s->ops->send(s->ops->ctx, f, o + got);
        if (rc == BLEMESH_SEND_BUSY) return;      /* resume on tx_ready */
        if (rc < 0) { session_end(s, false); return; }
        s->tx_offset += (uint32_t)got;
        s->tx_window--;
    }

    if (s->tx_offset >= s->tx_size && !s->tx_done_sent) {
        uint8_t e[8];
        int eo = env(e, MSP_FILE_DONE);
        w32(e + eo, s->tx_xfer); eo += 4;
        if (ctl_send(s, e, eo) == 0) s->tx_done_sent = true;
    }

    /* Politeness: past the cap, stop after the current window — the peer's
     * spool holds the offset and the next session resumes there. */
    if (now - s->opened_at > MSP_SESSION_CAP &&
        s->tx_active && s->tx_offset < s->tx_size && s->tx_window <= 0) {
        send_bye(s, MSP_BYE_POLITENESS);
        session_end(s, true);
    }
}

static void on_offer(blemesh_session_t *s, const uint8_t *d, int len)
{
    if (len < 4 + 32 + 8 + 4 + 4) return;
    uint32_t xfer = r32(d);
    const uint8_t *sha = d + 4;
    uint64_t size = r64(d + 36);
    /* ttl at d+44 (u32) — parsed but unused here; spool TTL is receiver policy */
    int o = 48;
    char origin[10], target[10], ext[17], name[65];
    int n;
    if ((n = r_cs(d + o, len - o, origin, sizeof(origin))) < 0) return;
    o += n;
    if ((n = r_cs(d + o, len - o, target, sizeof(target))) < 0) return;
    o += n;
    if ((n = r_cs(d + o, len - o, ext, sizeof(ext))) < 0) return;
    o += n;
    if ((n = r_cs(d + o, len - o, name, sizeof(name))) < 0) return;

    uint8_t rej = 0;
    if (s->rx_active) {
        rej = MSP_FREJ_BUSY;
    } else if (s->tx_active && s->dialer) {
        /* Simultaneous offers: the dialer wins; served side parks its own. */
        rej = MSP_FREJ_BUSY;
    }
    if (!rej && s->tx_active && !s->dialer) {
        s->tx_active = false;
        s->ops->bulk_done(s->ops->ctx, s->peer, s->tx_sha, 0, 1);
    }

    uint32_t resume = 0;
    if (!rej) {
        int rc = s->ops->bulk_offer_rx(s->ops->ctx, s->peer, sha, size, origin,
                                       target, ext, name, &resume);
        if (rc != 0) rej = (uint8_t)rc;
    }

    if (rej) {
        uint8_t f[9];
        int fo = env(f, MSP_FILE_REJECT);
        w32(f + fo, xfer); fo += 4;
        f[fo++] = rej;
        ctl_send(s, f, fo);
        return;
    }

    if ((uint64_t)resume >= size) {
        /* Already have it — accept-at-size is the dup-suppression handshake. */
        uint8_t f[16];
        int fo = env(f, MSP_FILE_ACCEPT);
        w32(f + fo, xfer); fo += 4;
        w32(f + fo, (uint32_t)size); fo += 4;
        w16(f + fo, 0); fo += 2;
        ctl_send(s, f, fo);
        return;
    }

    s->rx_active = true;
    memcpy(s->rx_sha, sha, 32);
    s->rx_size = size;
    s->rx_xfer = xfer;
    s->rx_offset = resume;
    s->rx_since_ack = 0;
    s->rx_resynced = false;

    uint8_t f[16];
    int fo = env(f, MSP_FILE_ACCEPT);
    w32(f + fo, xfer); fo += 4;
    w32(f + fo, resume); fo += 4;
    w16(f + fo, MSP_WINDOW); fo += 2;
    ctl_send(s, f, fo);
}

static void send_win_ack(blemesh_session_t *s)
{
    uint8_t f[16];
    int o = env(f, MSP_WIN_ACK);
    w32(f + o, s->rx_xfer); o += 4;
    w32(f + o, s->rx_offset); o += 4;
    w16(f + o, MSP_WINDOW); o += 2;
    ctl_send(s, f, o);
}

static void on_chunk(blemesh_session_t *s, const uint8_t *d, int len,
                     uint32_t now)
{
    (void)now;
    if (!s->rx_active || len < 8) return;
    uint32_t xfer = r32(d);
    uint32_t off = r32(d + 4);
    if (xfer != s->rx_xfer) return;
    if (off != s->rx_offset) {
        /* Gap — resync once per gap: restate the offset we want. */
        if (!s->rx_resynced) { s->rx_resynced = true; send_win_ack(s); }
        return;
    }
    s->rx_resynced = false;
    int dl = len - 8;
    if (s->ops->bulk_write(s->ops->ctx, s->rx_sha, off, d + 8, dl) != 0) {
        uint8_t f[9];
        int o = env(f, MSP_FILE_FAIL);
        w32(f + o, xfer); o += 4;
        f[o++] = MSP_FAIL_IO;
        ctl_send(s, f, o);
        s->rx_active = false;
        s->ops->bulk_done(s->ops->ctx, s->peer, s->rx_sha, 0, 0);
        return;
    }
    s->rx_offset += (uint32_t)dl;
    if (++s->rx_since_ack >= MSP_WINDOW && s->rx_offset < s->rx_size) {
        s->rx_since_ack = 0;
        send_win_ack(s);
    }
}

static void on_file_done(blemesh_session_t *s, uint32_t xfer)
{
    if (!s->rx_active || xfer != s->rx_xfer) return;
    if (s->rx_offset < s->rx_size) { send_win_ack(s); return; }
    int ok = s->ops->bulk_verify(s->ops->ctx, s->rx_sha);
    s->rx_active = false;
    uint8_t f[9];
    int o = env(f, ok ? MSP_FILE_OK : MSP_FILE_FAIL);
    w32(f + o, xfer); o += 4;
    if (!ok) f[o++] = MSP_FAIL_HASH;
    ctl_send(s, f, o);
    s->ops->bulk_done(s->ops->ctx, s->peer, s->rx_sha, ok ? 1 : 0, 0);
}

/* ---- lifecycle ---------------------------------------------------------------- */
static void on_hello(blemesh_session_t *s, const uint8_t *d, int len,
                     uint32_t now)
{
    if (s->state != 0 || len < 2) return;
    int o = 0;
    s->peer_caps = r16(d); o += 2;
    int n = r_cs(d + o, len - o, s->peer, sizeof(s->peer));
    if (n < 0 || !s->peer[0]) return;
    o += n;
    if (len < o + 2 + 4 + 2 + 1) return;
    s->peer_max_frame = r16(d + o); o += 2;
    o += 4; /* spool_free_kb — advisory */
    s->peer_pending_msgs = r16(d + o); o += 2;
    s->peer_pending_bulk = d[o];

    s->state = 1;
    if (!s->dialer) send_hello(s);

    if ((s->peer_caps & MSP_CAP_GOSSIP) && s->ops->gossip_build) {
        uint8_t g[512];
        int gl = s->ops->gossip_build(s->ops->ctx, g, sizeof(g));
        if (gl > 0) ctl_send(s, g, gl);
    }
    drain_custody(s);
    maybe_start_bulk(s, now);
}

void blemesh_session_rx(blemesh_session_t *s, const uint8_t *d, int len,
                        uint32_t now)
{
    if (s->state == 2 || !blemesh_msp_is_frame(d, len)) return;
    s->last_rx = now;
    uint8_t type = d[2];
    const uint8_t *b = d + 3;
    int bl = len - 3;

    switch (type) {
    case MSP_HELLO:
        on_hello(s, b, bl, now);
        break;
    case MSP_GOSSIP:
        if (s->state == 1 && s->ops->gossip_rx)
            s->ops->gossip_rx(s->ops->ctx, s->peer, b, bl);
        break;
    case MSP_BYE:
        session_end(s, true);
        break;
    case MSP_MSG:
        if (s->state == 1) on_msg(s, b, bl);
        break;
    case MSP_MSG_ACK: {
        if (bl < 1) break;
        int n = b[0];
        for (int i = 0; i < n && 1 + i < bl; i++) ack_seq(s, b[1 + i], true);
        if (out_slots_used(s) == 0 && s->custody_drained) {
            drain_custody(s);
            maybe_start_bulk(s, now);
        }
        break;
    }
    case MSP_MSG_REJ:
        if (bl >= 2) ack_seq(s, b[0], b[1] == MSP_REJ_DUP);
        if (out_slots_used(s) == 0 && s->custody_drained)
            maybe_start_bulk(s, now);
        break;
    case MSP_FILE_OFFER:
        if (s->state == 1) on_offer(s, b, bl);
        break;
    case MSP_FILE_ACCEPT: {
        if (bl < 10 || !s->tx_active || r32(b) != s->tx_xfer) break;
        uint32_t off = r32(b + 4);
        uint16_t win = r16(b + 8);
        if ((uint64_t)off >= s->tx_size) {
            /* Peer already has it — handover without a byte moved. */
            s->tx_active = false;
            s->ops->bulk_done(s->ops->ctx, s->peer, s->tx_sha, 1, 1);
            maybe_start_bulk(s, now);
            break;
        }
        s->tx_offset = off;
        s->tx_window = win;
        pump_chunks(s, now);
        break;
    }
    case MSP_FILE_REJECT:
        if (bl >= 5 && s->tx_active && r32(b) == s->tx_xfer) {
            s->tx_active = false;
            s->ops->bulk_done(s->ops->ctx, s->peer, s->tx_sha, 0, 1);
        }
        break;
    case MSP_CHUNK:
        on_chunk(s, b, bl, now);
        break;
    case MSP_WIN_ACK:
        if (bl >= 10 && s->tx_active && r32(b) == s->tx_xfer) {
            s->tx_offset = r32(b + 4);      /* receiver-stated resync point */
            s->tx_window = r16(b + 8);
            s->tx_done_sent = false;        /* it may want a re-DONE after fill */
            pump_chunks(s, now);
        }
        break;
    case MSP_FILE_DONE:
        if (bl >= 4) on_file_done(s, r32(b));
        break;
    case MSP_FILE_OK:
        if (bl >= 4 && s->tx_active && r32(b) == s->tx_xfer) {
            s->tx_active = false;
            s->ops->bulk_done(s->ops->ctx, s->peer, s->tx_sha, 1, 1);
            maybe_start_bulk(s, now);
        }
        break;
    case MSP_FILE_FAIL:
        if (bl >= 4) {
            uint32_t x = r32(b);
            if (s->tx_active && x == s->tx_xfer) {
                s->tx_active = false;
                s->ops->bulk_done(s->ops->ctx, s->peer, s->tx_sha, 0, 1);
            } else if (s->rx_active && x == s->rx_xfer) {
                s->rx_active = false;
                s->ops->bulk_done(s->ops->ctx, s->peer, s->rx_sha, 0, 0);
            }
        }
        break;
    default:
        break;
    }
}

void blemesh_session_tx_ready(blemesh_session_t *s, uint32_t now)
{
    if (s->state == 1 && s->tx_active) pump_chunks(s, now);
}

void blemesh_session_poll_bulk(blemesh_session_t *s, uint32_t now)
{
    if (s->state == 1) maybe_start_bulk(s, now);
}

void blemesh_session_tick(blemesh_session_t *s, uint32_t now)
{
    if (s->state == 2) return;
    if (s->state == 0 && now - s->opened_at > MSP_HELLO_TIMEOUT) {
        session_end(s, false);
        return;
    }
    if (s->state == 1) {
        bool busy = s->tx_active || s->rx_active || out_slots_used(s) > 0;
        if (busy && now - s->last_rx > MSP_STALL_TIMEOUT) {
            session_end(s, false);
            return;
        }
        if (!busy && now - s->opened_at > MSP_SESSION_CAP) {
            send_bye(s, MSP_BYE_POLITENESS);
            session_end(s, true);
        }
    }
}

static void session_end(blemesh_session_t *s, bool clean)
{
    if (s->state == 2) return;
    s->state = 2;
    if (s->tx_active) {
        s->tx_active = false;
        s->ops->bulk_done(s->ops->ctx, s->peer, s->tx_sha, 0, 1);
    }
    if (s->rx_active) {
        /* Spool keeps the bytes — the next session resumes from the offset. */
        s->rx_active = false;
        s->ops->bulk_done(s->ops->ctx, s->peer, s->rx_sha, 0, 0);
    }
    if (s->ops->closed) s->ops->closed(s->ops->ctx, s->peer, clean ? 1 : 0);
}

void blemesh_session_close(blemesh_session_t *s, bool clean)
{
    session_end(s, clean);
}

void blemesh_session_set_pending(blemesh_session_t *s, uint16_t msgs,
                                 uint8_t bulk, uint32_t spool_free_kb)
{
    s->pending_msgs = msgs;
    s->pending_bulk = bulk;
    s->spool_free_kb = spool_free_kb;
}

void blemesh_session_init(blemesh_session_t *s, const blemesh_session_ops_t *ops,
                          const char *self_callsign, uint16_t caps,
                          uint16_t max_frame, bool dialer, uint32_t now)
{
    memset(s, 0, sizeof(*s));
    s->ops = ops;
    s->caps = caps;
    s->max_frame = max_frame;
    s->dialer = dialer;
    s->opened_at = now;
    s->last_rx = now;
    int n = 0;
    while (self_callsign[n] && n < BLEMESH_CALLSIGN_MAX) {
        s->self[n] = self_callsign[n];
        n++;
    }
    s->self[n] = 0;
}

void blemesh_session_start(blemesh_session_t *s)
{
    if (s->dialer) send_hello(s);
}
