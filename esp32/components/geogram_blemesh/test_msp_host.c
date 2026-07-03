/*
 * test_msp_host — host-side (gcc) parity test for blemesh_session.c.
 *
 * Checks the C MSP codec byte-for-byte against the shared fixtures in
 * aurora/test/mesh_session_test.dart, plus a full two-session loopback
 * (custody, bulk, resume, dup-suppression, interrupt+resume).
 *
 * Build & run (no ESP-IDF needed — pure C):
 *   gcc -Wall -Wextra -O1 -o /tmp/test_msp \
 *       blemesh_session.c test_msp_host.c && /tmp/test_msp
 *
 * NOT part of the firmware build (excluded from CMakeLists SRCS).
 */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "blemesh_session.h"

/* ---- fixtures shared with mesh_session_test.dart -------------------------- */
static const char *FX_HELLO =
    "4d01010f0006583141363758fd0100040000030001";
static const char *FX_MSG =
    "4d0110070161316232633304030201080058311f58321f6869";
static const char *FX_BLOOM =
    "0000000000000000000000000001000000000000000000000000000000000000"
    "0000000000000000000000400000000000000000000000000000000000000000"
    "0000000000000000000000000080000000000000000000000000000000000000"
    "0000000000000000000000000000000000002000000000000000000000000000";

static void hexstr(const uint8_t *d, int n, char *out)
{
    for (int i = 0; i < n; i++) sprintf(out + 2 * i, "%02x", d[i]);
    out[2 * n] = 0;
}

/* ---- loopback harness ------------------------------------------------------ */
#define QCAP 4096
#define FCAP 520

typedef struct {
    uint8_t frames[QCAP][FCAP];
    int lens[QCAP];
    int head, tail;
} queue_t;

static void q_push(queue_t *q, const uint8_t *d, int n)
{
    assert(q->tail < QCAP && n <= FCAP);
    memcpy(q->frames[q->tail], d, n);
    q->lens[q->tail++] = n;
}

typedef struct {
    const char *name;
    queue_t *out;                     /* frames we send land here */

    /* custody */
    struct { char am[7]; uint8_t wire[64]; int len; } outbox[8];
    int outbox_n, popped;
    char rx_ams[8][7];
    int rx_n;
    char transferred[8][7];
    int transferred_n;
    int msg_result;
    int gossips;

    /* bulk tx */
    uint8_t *tx_data;
    uint64_t tx_size;
    uint8_t tx_sha[32];
    int tx_served, tx_offered;

    /* bulk rx */
    uint8_t spool[131072];
    uint32_t spool_len;
    uint32_t resume_offset;
    int verify_result;
    int chunks, done_ok_tx, done_fail_tx, done_ok_rx, done_fail_rx;
    uint32_t min_chunk_off;
    int interrupt_after;              /* chunks; 0 = never */
    blemesh_session_t *sess_a, *sess_b; /* for interrupt */
} node_t;

static int op_send(void *ctx, const uint8_t *f, int n)
{
    node_t *nd = ctx;
    q_push(nd->out, f, n);
    return BLEMESH_SEND_OK;
}

static int op_msg_pop(void *ctx, const char *peer, char am[7],
                      uint8_t *wire, int cap, uint32_t *ts)
{
    (void)peer; (void)cap;
    node_t *nd = ctx;
    if (nd->popped >= nd->outbox_n) return 0;
    int i = nd->popped++;
    memcpy(am, nd->outbox[i].am, 7);
    memcpy(wire, nd->outbox[i].wire, nd->outbox[i].len);
    *ts = 0x01020304;
    return nd->outbox[i].len;
}

static void op_msg_transferred(void *ctx, const char *peer, const char *am)
{
    (void)peer;
    node_t *nd = ctx;
    snprintf(nd->transferred[nd->transferred_n++], 7, "%s", am);
}

static int op_msg_rx(void *ctx, const char *peer, const char *am, uint32_t ts,
                     const uint8_t *wire, int len)
{
    (void)peer; (void)ts; (void)wire; (void)len;
    node_t *nd = ctx;
    snprintf(nd->rx_ams[nd->rx_n++], 7, "%s", am);
    return nd->msg_result;
}

static int op_gossip_build(void *ctx, uint8_t *frame, int cap)
{
    (void)ctx; (void)cap;
    /* Minimal valid GOSSIP: no entries, empty bloom. */
    frame[0] = 0x4D; frame[1] = 0x01; frame[2] = MSP_GOSSIP;
    frame[3] = 0; frame[4] = 0; frame[5] = 0; frame[6] = 0;
    return 7;
}

static void op_gossip_rx(void *ctx, const char *peer, const uint8_t *b, int n)
{
    (void)peer; (void)b; (void)n;
    ((node_t *)ctx)->gossips++;
}

static int op_bulk_next(void *ctx, const char *peer, uint8_t sha[32],
                        uint64_t *size, uint32_t *ttl, char origin[10],
                        char target[10], char ext[17], char name[65])
{
    (void)peer;
    node_t *nd = ctx;
    if (!nd->tx_data || nd->tx_served || nd->tx_offered) return 0;
    nd->tx_offered = 1;
    memcpy(sha, nd->tx_sha, 32);
    *size = nd->tx_size;
    *ttl = 3600;
    strcpy(origin, "AAA");
    strcpy(target, "BBB");
    strcpy(ext, "bin");
    strcpy(name, "blob.bin");
    return 1;
}

static int op_bulk_offer_rx(void *ctx, const char *peer, const uint8_t sha[32],
                            uint64_t size, const char *origin,
                            const char *target, const char *ext,
                            const char *name, uint32_t *resume)
{
    (void)peer; (void)sha; (void)size; (void)origin; (void)target;
    (void)ext; (void)name;
    *resume = ((node_t *)ctx)->resume_offset;
    return 0;
}

static int op_bulk_read(void *ctx, const uint8_t sha[32], uint32_t off,
                        uint8_t *buf, int len)
{
    (void)sha;
    node_t *nd = ctx;
    if (off >= nd->tx_size) return 0;
    if ((uint64_t)off + len > nd->tx_size) len = (int)(nd->tx_size - off);
    memcpy(buf, nd->tx_data + off, len);
    return len;
}

static int op_bulk_write(void *ctx, const uint8_t sha[32], uint32_t off,
                         const uint8_t *d, int len)
{
    (void)sha;
    node_t *nd = ctx;
    if (off != nd->spool_len) return -1; /* harness writes are contiguous */
    memcpy(nd->spool + off, d, len);
    nd->spool_len += len;
    nd->chunks++;
    if (off < nd->min_chunk_off) nd->min_chunk_off = off;
    if (nd->interrupt_after && nd->chunks == nd->interrupt_after) {
        blemesh_session_close(nd->sess_a, false);
        blemesh_session_close(nd->sess_b, false);
    }
    return 0;
}

static int op_bulk_verify(void *ctx, const uint8_t sha[32])
{
    (void)sha;
    return ((node_t *)ctx)->verify_result;
}

static void op_bulk_done(void *ctx, const char *peer, const uint8_t sha[32],
                         int ok, int to_peer)
{
    (void)peer; (void)sha;
    node_t *nd = ctx;
    if (to_peer) { if (ok) { nd->done_ok_tx++; nd->tx_served = 1; }
                   else { nd->done_fail_tx++; nd->tx_offered = 0; } }
    else { if (ok) nd->done_ok_rx++; else nd->done_fail_rx++; }
}

static void op_closed(void *ctx, const char *peer, int clean)
{
    (void)ctx; (void)peer; (void)clean;
}

static const blemesh_session_ops_t OPS_TMPL = {
    .send = op_send,
    .msg_pop = op_msg_pop,
    .msg_transferred = op_msg_transferred,
    .msg_rx = op_msg_rx,
    .gossip_build = op_gossip_build,
    .gossip_rx = op_gossip_rx,
    .bulk_next = op_bulk_next,
    .bulk_offer_rx = op_bulk_offer_rx,
    .bulk_read = op_bulk_read,
    .bulk_write = op_bulk_write,
    .bulk_verify = op_bulk_verify,
    .bulk_done = op_bulk_done,
    .closed = op_closed,
};

/* Deliver queued frames until quiet. */
static void pump(blemesh_session_t *a, blemesh_session_t *b,
                 queue_t *to_b, queue_t *to_a)
{
    uint32_t now = 100;
    while (to_b->head < to_b->tail || to_a->head < to_a->tail) {
        if (to_b->head < to_b->tail) {
            int i = to_b->head++;
            blemesh_session_rx(b, to_b->frames[i], to_b->lens[i], now);
        }
        if (to_a->head < to_a->tail) {
            int i = to_a->head++;
            blemesh_session_rx(a, to_a->frames[i], to_a->lens[i], now);
        }
    }
}

static int tests = 0, fails = 0;
#define CHECK(cond, msg) do { tests++; if (!(cond)) { fails++; \
    printf("FAIL %s:%d %s\n", __FILE__, __LINE__, msg); } } while (0)

/* Fresh linked pair. Queues/ops/nodes are caller-owned so state survives
 * "reconnects" (new sessions, same nodes). */
static void link_up(node_t *na, node_t *nb, queue_t *to_b, queue_t *to_a,
                    blemesh_session_t *a, blemesh_session_t *b,
                    blemesh_session_ops_t *oa, blemesh_session_ops_t *ob)
{
    memset(to_b, 0, sizeof(*to_b));
    memset(to_a, 0, sizeof(*to_a));
    na->out = to_b;
    nb->out = to_a;
    *oa = OPS_TMPL; oa->ctx = na;
    *ob = OPS_TMPL; ob->ctx = nb;
    blemesh_session_init(a, oa, "AAA", 0x0F, 509, true, 100);
    blemesh_session_init(b, ob, "BBB", 0x0F, 509, false, 100);
    na->sess_a = a; na->sess_b = b;
    nb->sess_a = a; nb->sess_b = b;
    blemesh_session_start(a);
    blemesh_session_start(b);
}

static void node_init(node_t *n, const char *name)
{
    memset(n, 0, sizeof(*n));
    n->name = name;
    n->verify_result = 1;
    n->min_chunk_off = 0xFFFFFFFF;
}

int main(void)
{
    char hx[2 * FCAP + 1];

    /* --- fixture: HELLO ---------------------------------------------------- */
    {
        node_t na; node_init(&na, "A");
        queue_t q; memset(&q, 0, sizeof(q));
        na.out = &q;
        blemesh_session_ops_t ops = OPS_TMPL; ops.ctx = &na;
        blemesh_session_t s;
        blemesh_session_init(&s, &ops, "X1A67X", 0x000F, 509, true, 100);
        blemesh_session_set_pending(&s, 3, 1, 1024);
        blemesh_session_start(&s);
        CHECK(q.tail == 1, "hello sent");
        hexstr(q.frames[0], q.lens[0], hx);
        CHECK(strcmp(hx, FX_HELLO) == 0, "HELLO fixture");
        if (strcmp(hx, FX_HELLO)) printf("  got %s\n  exp %s\n", hx, FX_HELLO);
    }

    /* --- fixture: bloom ----------------------------------------------------- */
    {
        uint8_t bloom[BLEMESH_BLOOM_BYTES] = {0};
        blemesh_bloom_add(bloom, "a1b2c3");
        hexstr(bloom, sizeof(bloom), hx);
        CHECK(strcmp(hx, FX_BLOOM) == 0, "bloom fixture");
        if (strcmp(hx, FX_BLOOM)) printf("  got %s\n  exp %s\n", hx, FX_BLOOM);
        CHECK(blemesh_bloom_has(bloom, sizeof(bloom), "a1b2c3"), "bloom has");
        CHECK(!blemesh_bloom_has(bloom, sizeof(bloom), "ffffff"), "bloom not");
    }

    /* --- fixture: MSG + custody loopback ------------------------------------ */
    {
        node_t na, nb;
        node_init(&na, "A"); node_init(&nb, "B");
        strcpy(na.outbox[0].am, "a1b2c3");
        memcpy(na.outbox[0].wire, "X1\x1FX2\x1Fhi", 8);
        na.outbox[0].len = 8;
        na.outbox_n = 1;

        queue_t to_b, to_a;
        blemesh_session_t a, b;
        blemesh_session_ops_t oa, ob;
        link_up(&na, &nb, &to_b, &to_a, &a, &b, &oa, &ob);
        a.next_seq = 6; /* fixture uses seq 7 */
        pump(&a, &b, &to_b, &to_a);

        /* find the MSG frame A sent */
        int found = 0;
        for (int i = 0; i < to_b.tail; i++) {
            if (to_b.frames[i][2] == MSP_MSG) {
                hexstr(to_b.frames[i], to_b.lens[i], hx);
                CHECK(strcmp(hx, FX_MSG) == 0, "MSG fixture");
                if (strcmp(hx, FX_MSG))
                    printf("  got %s\n  exp %s\n", hx, FX_MSG);
                found = 1;
            }
        }
        CHECK(found, "MSG frame aired");
        CHECK(nb.rx_n == 1 && strcmp(nb.rx_ams[0], "a1b2c3") == 0, "custody rx");
        CHECK(na.transferred_n == 1 && strcmp(na.transferred[0], "a1b2c3") == 0,
              "custody transferred");
        CHECK(na.gossips == 1 && nb.gossips == 1, "gossip swap");
    }

    /* --- custody duplicate still archives ----------------------------------- */
    {
        node_t na, nb;
        node_init(&na, "A"); node_init(&nb, "B");
        nb.msg_result = MSP_REJ_DUP;
        strcpy(na.outbox[0].am, "cccccc");
        memcpy(na.outbox[0].wire, "X\x1FY\x1Fm", 5);
        na.outbox[0].len = 5;
        na.outbox_n = 1;
        queue_t to_b, to_a;
        blemesh_session_t a, b;
        blemesh_session_ops_t oa, ob;
        link_up(&na, &nb, &to_b, &to_a, &a, &b, &oa, &ob);
        pump(&a, &b, &to_b, &to_a);
        CHECK(na.transferred_n == 1, "dup archives at sender");
    }

    /* --- bulk end-to-end + integrity ---------------------------------------- */
    uint8_t *data = malloc(100 * 1024);
    for (int i = 0; i < 100 * 1024; i++) data[i] = (uint8_t)((i * 31 + 7) & 0xFF);
    {
        node_t na, nb;
        node_init(&na, "A"); node_init(&nb, "B");
        na.tx_data = data;
        na.tx_size = 100 * 1024;
        queue_t to_b, to_a;
        blemesh_session_t a, b;
        blemesh_session_ops_t oa, ob;
        link_up(&na, &nb, &to_b, &to_a, &a, &b, &oa, &ob);
        pump(&a, &b, &to_b, &to_a);
        CHECK(na.done_ok_tx == 1, "bulk tx done");
        CHECK(nb.done_ok_rx == 1, "bulk rx done");
        CHECK(nb.spool_len == 100 * 1024, "bulk length");
        CHECK(memcmp(nb.spool, data, 100 * 1024) == 0, "bulk integrity");
    }

    /* --- resume from receiver-stated offset --------------------------------- */
    {
        node_t na, nb;
        node_init(&na, "A"); node_init(&nb, "B");
        na.tx_data = data;
        na.tx_size = 50 * 1024;
        nb.resume_offset = 20000;
        memcpy(nb.spool, data, 20000);
        nb.spool_len = 20000;
        queue_t to_b, to_a;
        blemesh_session_t a, b;
        blemesh_session_ops_t oa, ob;
        link_up(&na, &nb, &to_b, &to_a, &a, &b, &oa, &ob);
        pump(&a, &b, &to_b, &to_a);
        CHECK(nb.done_ok_rx == 1, "resume rx done");
        CHECK(nb.min_chunk_off == 20000, "nothing before resume point re-sent");
        CHECK(memcmp(nb.spool, data, 50 * 1024) == 0, "resume integrity");
    }

    /* --- dup suppression: accept-at-size ------------------------------------ */
    {
        node_t na, nb;
        node_init(&na, "A"); node_init(&nb, "B");
        na.tx_data = data;
        na.tx_size = 1024;
        nb.resume_offset = 1024;
        queue_t to_b, to_a;
        blemesh_session_t a, b;
        blemesh_session_ops_t oa, ob;
        link_up(&na, &nb, &to_b, &to_a, &a, &b, &oa, &ob);
        pump(&a, &b, &to_b, &to_a);
        CHECK(na.done_ok_tx == 1, "dup handover ok");
        CHECK(nb.chunks == 0, "no bytes moved");
    }

    /* --- interrupt mid-transfer, resume in a new session --------------------- */
    {
        node_t na, nb;
        node_init(&na, "A"); node_init(&nb, "B");
        na.tx_data = data;
        na.tx_size = 64 * 1024;
        nb.interrupt_after = 20;
        queue_t to_b, to_a;
        blemesh_session_t a, b;
        blemesh_session_ops_t oa, ob;
        link_up(&na, &nb, &to_b, &to_a, &a, &b, &oa, &ob);
        pump(&a, &b, &to_b, &to_a);
        CHECK(nb.done_ok_rx == 0, "interrupted");
        CHECK(nb.spool_len > 0 && nb.spool_len < 64 * 1024, "partial spool");

        /* reconnect: same nodes, fresh sessions — resumes at spool_len */
        uint32_t had = nb.spool_len;
        nb.interrupt_after = 0;
        nb.resume_offset = had;
        nb.min_chunk_off = 0xFFFFFFFF;
        na.tx_offered = 0; /* scheduler re-offers after a failed attempt */
        link_up(&na, &nb, &to_b, &to_a, &a, &b, &oa, &ob);
        pump(&a, &b, &to_b, &to_a);
        CHECK(nb.done_ok_rx == 1, "resumed to completion");
        CHECK(nb.min_chunk_off == had, "resumed at prior offset");
        CHECK(memcmp(nb.spool, data, 64 * 1024) == 0, "post-resume integrity");
    }

    /* --- hash mismatch fails cleanly ----------------------------------------- */
    {
        node_t na, nb;
        node_init(&na, "A"); node_init(&nb, "B");
        na.tx_data = data;
        na.tx_size = 2048;
        nb.verify_result = 0;
        queue_t to_b, to_a;
        blemesh_session_t a, b;
        blemesh_session_ops_t oa, ob;
        link_up(&na, &nb, &to_b, &to_a, &a, &b, &oa, &ob);
        pump(&a, &b, &to_b, &to_a);
        CHECK(na.done_fail_tx == 1, "tx sees hash fail");
        CHECK(nb.done_fail_rx == 1, "rx reports hash fail");
    }

    free(data);
    printf("%d tests, %d failures\n", tests, fails);
    return fails ? 1 : 0;
}
