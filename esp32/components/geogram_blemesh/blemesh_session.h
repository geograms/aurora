/*
 * blemesh_session — Mesh Session Protocol v1 (MSP) over a GATT link.
 *
 * C mirror of aurora lib/services/mesh/mesh_session.dart — the two codecs
 * must stay byte-identical (aurora test/mesh_session_test.dart carries hex
 * fixtures both sides reproduce; test_msp_host.c compiles this file on the
 * host and checks the same vectors).
 *
 * Wire: every frame is [0x4D][0x01][type][body], little-endian, one frame
 * per ATT write/notify. Callsign-style strings are [len u8][ASCII].
 * See doc/mesh.md §3 Plane 2 for the frame table.
 *
 * Pure logic — no radio, storage or OS deps. The firmware supplies transport
 * and spool through blemesh_session_ops_t; time comes in as monotonic seconds
 * (same convention as the rest of blemesh).
 *
 * Transport contract: ops->send() queues ONE frame (notify or write). It may
 * return BLEMESH_SEND_BUSY when the transport queue is full — the session
 * pauses its chunk pump and resumes when the firmware calls
 * blemesh_session_tx_ready() (e.g. from NimBLE's BLE_GAP_EVENT_NOTIFY_TX).
 */
#ifndef GEOGRAM_BLEMESH_SESSION_H
#define GEOGRAM_BLEMESH_SESSION_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- wire constants (must match mesh_session.dart) ----------------------- */
#define BLEMESH_MSP_MAGIC   0x4D
#define BLEMESH_MSP_VER     0x01

enum {
    MSP_HELLO = 0x01, MSP_GOSSIP = 0x02, MSP_BYE = 0x03,
    MSP_MSG = 0x10, MSP_MSG_ACK = 0x11, MSP_MSG_REJ = 0x12,
    MSP_FILE_OFFER = 0x20, MSP_FILE_ACCEPT = 0x21, MSP_FILE_REJECT = 0x22,
    MSP_CHUNK = 0x23, MSP_WIN_ACK = 0x24, MSP_FILE_DONE = 0x25,
    MSP_FILE_OK = 0x26, MSP_FILE_FAIL = 0x27,
};

/* HELLO capability bits. */
#define MSP_CAP_MSG       (1 << 0)
#define MSP_CAP_BULK_RX   (1 << 1)
#define MSP_CAP_BULK_TX   (1 << 2)
#define MSP_CAP_GOSSIP    (1 << 3)
#define MSP_CAP_WRITE_NR  (1 << 4)   /* phase 2, reserved */

/* MSG_REJ reasons. */
#define MSP_REJ_DUP       1   /* peer already has it — sender archives too */
#define MSP_REJ_QUOTA     2
#define MSP_REJ_MALFORMED 3

/* FILE_REJECT reasons. */
#define MSP_FREJ_QUOTA    1
#define MSP_FREJ_NO_ROUTE 2
#define MSP_FREJ_BUSY     3
#define MSP_FREJ_EXPIRED  4

/* FILE_FAIL reasons. */
#define MSP_FAIL_HASH     1
#define MSP_FAIL_IO       2
#define MSP_FAIL_CANCEL   3

/* BYE reasons. */
#define MSP_BYE_DONE       0
#define MSP_BYE_POLITENESS 1
#define MSP_BYE_ERROR      2

#define MSP_CHUNK_HEADER   11   /* envelope 3 + xfer 4 + offset 4 */
#define MSP_WINDOW         16   /* default credit window (chunks) */
#define MSP_MSG_OUT_MAX    8    /* custody msgs awaiting ack */
#define MSP_HELLO_TIMEOUT  5
#define MSP_STALL_TIMEOUT  30
#define MSP_SESSION_CAP    300  /* politeness cycle (seconds) */

#define BLEMESH_SEND_OK    0
#define BLEMESH_SEND_BUSY  (-2)  /* transport queue full — retry on tx_ready */

/* True when [d] is an MSP frame (the GATT write demux test). */
static inline bool blemesh_msp_is_frame(const uint8_t *d, int len)
{
    return len >= 3 && d[0] == BLEMESH_MSP_MAGIC && d[1] == BLEMESH_MSP_VER;
}

/* ---- host-supplied operations -------------------------------------------- */
typedef struct {
    void *ctx;

    /* Queue one MSP frame on the link. BLEMESH_SEND_OK, BLEMESH_SEND_BUSY,
     * or any other negative = link dead (session closes). */
    int  (*send)(void *ctx, const uint8_t *frame, int len);

    /* Custody tx: next parked frame for/via [peer]. Fill am (6 chars + NUL,
     * "" if none), wire, ts; return wire length, or 0 when nothing pending. */
    int  (*msg_pop)(void *ctx, const char *peer, char am[7],
                    uint8_t *wire, int cap, uint32_t *ts);
    /* Peer took custody (MSG_ACK / duplicate MSG_REJ) — archive our copy. */
    void (*msg_transferred)(void *ctx, const char *peer, const char *am);
    /* Custody rx: park an inbound frame. 0 = accepted, else MSP_REJ_*. */
    int  (*msg_rx)(void *ctx, const char *peer, const char *am, uint32_t ts,
                   const uint8_t *wire, int len);

    /* Gossip: build our GOSSIP frame (WITH envelope) into [frame]; return
     * length or 0 to skip. Inbound body (after envelope) lands in gossip_rx. */
    int  (*gossip_build)(void *ctx, uint8_t *frame, int cap);
    void (*gossip_rx)(void *ctx, const char *peer, const uint8_t *body, int len);

    /* Bulk tx: next spooled file for [peer]. Return 1 when one exists. */
    int  (*bulk_next)(void *ctx, const char *peer, uint8_t sha[32],
                      uint64_t *size, uint32_t *ttl_s,
                      char origin[10], char target[10],
                      char ext[17], char name[65]);
    /* Bulk rx: inbound offer. Set *resume_offset (bytes already held; ==size
     * means "have it all"). Return 0 = accept, else MSP_FREJ_*. */
    int  (*bulk_offer_rx)(void *ctx, const char *peer, const uint8_t sha[32],
                          uint64_t size, const char *origin, const char *target,
                          const char *ext, const char *name,
                          uint32_t *resume_offset);
    /* Read payload for an outbound transfer. Return bytes read (0 = error). */
    int  (*bulk_read)(void *ctx, const uint8_t sha[32], uint32_t offset,
                      uint8_t *buf, int len);
    /* Persist an inbound chunk. 0 = ok. */
    int  (*bulk_write)(void *ctx, const uint8_t sha[32], uint32_t offset,
                       const uint8_t *d, int len);
    /* Full-file SHA-256 verify of the inbound spool. 1 = ok. */
    int  (*bulk_verify)(void *ctx, const uint8_t sha[32]);
    /* Transfer over (ok=1 custody moved). to_peer=1 when we were sending. */
    void (*bulk_done)(void *ctx, const char *peer, const uint8_t sha[32],
                      int ok, int to_peer);

    void (*closed)(void *ctx, const char *peer, int clean);
} blemesh_session_ops_t;

/* ---- session state -------------------------------------------------------- */
typedef struct {
    const blemesh_session_ops_t *ops;
    char     self[10];
    char     peer[10];
    uint16_t caps, peer_caps;
    uint16_t max_frame, peer_max_frame;
    uint16_t pending_msgs;
    uint8_t  pending_bulk;
    uint32_t spool_free_kb;
    uint16_t peer_pending_msgs;
    uint8_t  peer_pending_bulk;

    uint8_t  state;        /* 0 hello, 1 active, 2 closed */
    bool     dialer;
    bool     hello_sent;
    uint32_t opened_at, last_rx;

    /* custody tx in flight */
    struct { uint8_t seq; char am[7]; bool used; } out_msgs[MSP_MSG_OUT_MAX];
    uint8_t  next_seq;
    bool     custody_drained;

    /* bulk tx */
    bool     tx_active;
    uint8_t  tx_sha[32];
    uint64_t tx_size;
    uint32_t tx_xfer, tx_offset;
    int      tx_window;    /* chunks still granted */
    bool     tx_done_sent;

    /* bulk rx */
    bool     rx_active;
    uint8_t  rx_sha[32];
    uint64_t rx_size;
    uint32_t rx_xfer, rx_offset;
    int      rx_since_ack;
    bool     rx_resynced;
} blemesh_session_t;

/* ---- have-digest bloom (mesh_bloom.dart mirror) --------------------------- */
#define BLEMESH_BLOOM_BYTES 128
void blemesh_bloom_add(uint8_t bloom[BLEMESH_BLOOM_BYTES], const char *am);
bool blemesh_bloom_has(const uint8_t *bloom, int len, const char *am);

/* ---- API ------------------------------------------------------------------ */
void blemesh_session_init(blemesh_session_t *s, const blemesh_session_ops_t *ops,
                          const char *self_callsign, uint16_t caps,
                          uint16_t max_frame, bool dialer, uint32_t now);

/* Kick the session off once the link/subscription is up (the dialer's HELLO
 * goes out here; call set_pending first). */
void blemesh_session_start(blemesh_session_t *s);

/* Set the counters advertised in our HELLO (call before the first rx/tick). */
void blemesh_session_set_pending(blemesh_session_t *s, uint16_t msgs,
                                 uint8_t bulk, uint32_t spool_free_kb);

/* Feed one inbound MSP frame (already prefix-demuxed). */
void blemesh_session_rx(blemesh_session_t *s, const uint8_t *d, int len,
                        uint32_t now);

/* Transport drained a frame (NOTIFY_TX) — resume a paused chunk pump. */
void blemesh_session_tx_ready(blemesh_session_t *s, uint32_t now);

/* Re-check for bulk work mid-session (routes/spool can appear after the
 * HELLO-time check — without a poll an idle session never offers). */
void blemesh_session_poll_bulk(blemesh_session_t *s, uint32_t now);

/* Drive timeouts (hello/stall/politeness). Call every ~1 s. */
void blemesh_session_tick(blemesh_session_t *s, uint32_t now);

/* Tear down (link dropped). Fires ops->closed exactly once. */
void blemesh_session_close(blemesh_session_t *s, bool clean);

static inline bool blemesh_session_closed(const blemesh_session_t *s)
{
    return s->state == 2;
}

#ifdef __cplusplus
}
#endif
#endif /* GEOGRAM_BLEMESH_SESSION_H */
