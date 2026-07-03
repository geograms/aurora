/* gatt_mesh — MSP-over-GATT server + SD bulk spool (see gatt_mesh.h).
 *
 * NimBLE specifics (EXT_ADV build):
 *  - The broadcast plane keeps ext-adv instance 0 (relay_task); the GATT
 *    plane adds instance 1 as a LEGACY connectable advert carrying the
 *    geogram presence format `FF FF 3E <devId> <callsign>` — exactly what
 *    the phones' discovery scan dials.
 *  - Chunk notifies are paced by BLE_GAP_EVENT_NOTIFY_TX with a small
 *    in-flight credit; blemesh_session's pump pauses on BLEMESH_SEND_BUSY
 *    and resumes from tx_ready.
 *  - One central at a time (the phones' model too).
 */
#include "gatt_mesh.h"

#include <ctype.h>
#include <dirent.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "mbedtls/sha256.h"

#include "host/ble_gap.h"
#include "host/ble_hs.h"
#include "os/os_mbuf.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "blemesh.h"
#include "blemesh_session.h"

static const char *TAG = "gatt_mesh";

#define SVC_UUID        0xFFE0
#define CHR_WRITE_UUID  0xFFF1
#define CHR_NOTIFY_UUID 0xFFF2
#define ADV_INSTANCE    1
#define NOTIFY_INFLIGHT_MAX 2
#define BULK_DIR        "/sdcard/mesh/bulk"
#define BULK_QUOTA_BYTES (200u * 1024u * 1024u)

static uint16_t s_notify_handle;
static uint16_t s_conn = BLE_HS_CONN_HANDLE_NONE;
static uint8_t  s_addr_type;
static char     s_call[10];
static bool     s_subscribed;
static volatile int s_notify_inflight;
static bool     s_session_up;
static blemesh_session_t s_sess;
static SemaphoreHandle_t s_lock;
static uint32_t s_conn_since;    /* connect time (for the idle reaper) */
static uint32_t s_last_msp;      /* last MSP frame from the central */

static uint32_t now_s(void) { return (uint32_t)(esp_timer_get_time() / 1000000ULL); }

/* ---- bulk spool (SD, stdio) ---------------------------------------------- */

static void sha_hex(const uint8_t sha[32], char out[65])
{
    static const char *h = "0123456789abcdef";
    for (int i = 0; i < 32; i++) {
        out[i * 2] = h[sha[i] >> 4];
        out[i * 2 + 1] = h[sha[i] & 0xF];
    }
    out[64] = 0;
}

typedef struct {
    char sha[65];
    char ext[17], name[65], origin[10], target[10], src[8], state[8];
    char path[128];           /* origin entries: the source file */
    uint64_t size;
} bulk_meta_t;

/* RAM spool index (defined below; declared here for the meta helpers). */
#define BULK_CACHE_MAX 8
static bulk_meta_t s_bulk[BULK_CACHE_MAX];
static int s_bulk_n;
static void bulk_cache_upsert(const bulk_meta_t *m);
static void bulk_cache_remove(const char *sha_hex);

static void meta_path_for(const uint8_t sha[32], char *out, int cap)
{
    char hx[65];
    sha_hex(sha, hx);
    hx[16] = 0;                       /* 8-byte prefix names the files */
    snprintf(out, cap, BULK_DIR "/%s.meta", hx);
}

static void part_path_for(const uint8_t sha[32], char *out, int cap)
{
    char hx[65];
    sha_hex(sha, hx);
    hx[16] = 0;
    snprintf(out, cap, BULK_DIR "/%s.part", hx);
}

static bool meta_read_file(const char *path, bulk_meta_t *m)
{
    memset(m, 0, sizeof(*m));
    FILE *f = fopen(path, "r");
    if (!f) return false;
    char line[192];
    while (fgets(line, sizeof(line), f)) {
        char *nl = strchr(line, '\n');
        if (nl) *nl = 0;
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        const char *v = eq + 1;
        if (!strcmp(line, "sha")) snprintf(m->sha, sizeof(m->sha), "%s", v);
        else if (!strcmp(line, "ext")) snprintf(m->ext, sizeof(m->ext), "%s", v);
        else if (!strcmp(line, "name")) snprintf(m->name, sizeof(m->name), "%s", v);
        else if (!strcmp(line, "origin")) snprintf(m->origin, sizeof(m->origin), "%s", v);
        else if (!strcmp(line, "target")) snprintf(m->target, sizeof(m->target), "%s", v);
        else if (!strcmp(line, "src")) snprintf(m->src, sizeof(m->src), "%s", v);
        else if (!strcmp(line, "state")) snprintf(m->state, sizeof(m->state), "%s", v);
        else if (!strcmp(line, "path")) snprintf(m->path, sizeof(m->path), "%s", v);
        else if (!strcmp(line, "size")) m->size = strtoull(v, NULL, 10);
    }
    fclose(f);
    return m->sha[0] != 0;
}

static bool meta_read(const uint8_t sha[32], bulk_meta_t *m)
{
    char hx[65];
    sha_hex(sha, hx);
    for (int i = 0; i < s_bulk_n; i++) {
        if (strcmp(s_bulk[i].sha, hx) == 0) { *m = s_bulk[i]; return true; }
    }
    char p[160];
    meta_path_for(sha, p, sizeof(p));
    return meta_read_file(p, m);
}

static void meta_write(const bulk_meta_t *m)
{
    uint8_t sha[32];
    for (int i = 0; i < 32; i++) {
        unsigned v;
        sscanf(m->sha + i * 2, "%2x", &v);
        sha[i] = (uint8_t)v;
    }
    /* RAM index FIRST — it is the authoritative queue; the file is only the
     * reboot-persistence layer. (An early return on fopen failure used to
     * skip the upsert: sendfile printed "queued" while the beacon kept
     * advertising zero bulk — the classic silent SD failure.) */
    bulk_cache_upsert(m);
    char p[160];
    meta_path_for(sha, p, sizeof(p));
    FILE *f = fopen(p, "w");
    if (!f) {
        ESP_LOGW(TAG, "meta write FAILED for %s (queued in RAM only)", m->name);
        return;
    }
    fprintf(f, "sha=%s\nsize=%llu\next=%s\nname=%s\norigin=%s\ntarget=%s\n"
               "src=%s\nstate=%s\npath=%s\n",
            m->sha, (unsigned long long)m->size, m->ext, m->name, m->origin,
            m->target, m->src, m->state, m->path);
    fclose(f);
}

static void hex_to_sha(const char *hx, uint8_t out[32])
{
    for (int i = 0; i < 32; i++) {
        unsigned v = 0;
        sscanf(hx + i * 2, "%2x", &v);
        out[i] = (uint8_t)v;
    }
}

/* Streamed SHA-256 of a file (never the whole file in RAM). */
static bool sha256_file(const char *path, uint8_t out[32], uint64_t *size)
{
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    mbedtls_sha256_context c;
    mbedtls_sha256_init(&c);
    mbedtls_sha256_starts(&c, 0);
    static uint8_t buf[2048];
    size_t n;
    uint64_t total = 0;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
        mbedtls_sha256_update(&c, buf, n);
        total += n;
    }
    fclose(f);
    mbedtls_sha256_finish(&c, out);
    mbedtls_sha256_free(&c);
    if (size) *size = total;
    return true;
}

/* RAM index of spool entries. The FAT VFS directory walk proved unsafe
 * against concurrent SD writers (console + iGate logs + SCF persist all hit
 * the card): opendir/readdir wedged the calling task mid-session. The dir is
 * walked ONCE at start (before the radio traffic ramps) and kept in sync by
 * every meta mutation; queries never touch readdir again. */
static void bulk_cache_upsert(const bulk_meta_t *m)
{
    for (int i = 0; i < s_bulk_n; i++) {
        if (strcmp(s_bulk[i].sha, m->sha) == 0) { s_bulk[i] = *m; return; }
    }
    if (s_bulk_n < BULK_CACHE_MAX) s_bulk[s_bulk_n++] = *m;
}

static void bulk_cache_remove(const char *sha_hex)
{
    for (int i = 0; i < s_bulk_n; i++) {
        if (strcmp(s_bulk[i].sha, sha_hex) == 0) {
            s_bulk[i] = s_bulk[s_bulk_n - 1];
            s_bulk_n--;
            return;
        }
    }
}

static void bulk_cache_load(void)
{
    s_bulk_n = 0;
    DIR *d = opendir(BULK_DIR);
    if (!d) return;
    struct dirent *e;
    bulk_meta_t m;
    while (s_bulk_n < BULK_CACHE_MAX && (e = readdir(d)) != NULL) {
        const char *dot = strrchr(e->d_name, '.');
        if (!dot || strcmp(dot, ".meta") != 0) continue;
        char p[320];
        snprintf(p, sizeof(p), BULK_DIR "/%s", e->d_name);
        if (meta_read_file(p, &m)) bulk_cache_upsert(&m);
    }
    closedir(d);
    ESP_LOGI(TAG, "bulk spool: %d entr%s cached", s_bulk_n,
             s_bulk_n == 1 ? "y" : "ies");
}

/* First cached entry matching [state] (and deliverable to [peer]). */
static bool bulk_scan(const char *state, const char *peer, bulk_meta_t *m)
{
    for (int i = 0; i < s_bulk_n; i++) {
        if (strcmp(s_bulk[i].state, state) != 0) continue;
        if (peer) {
            bool give = strcasecmp(s_bulk[i].target, peer) == 0;
            if (!give) {
                char via[BLEMESH_CALLSIGN_MAX + 1];
                if (blemesh_route_via(s_bulk[i].target, via)) {
                    give = strcasecmp(via, peer) == 0;
                } else {
                    /* No route at all: hand custody to whoever is here — the
                     * data-mule case. Custody, TTL and the e2e receipt purge
                     * cover a mule that never meets the target. */
                    give = true;
                }
            }
            if (!give || strcasecmp(s_bulk[i].origin, peer) == 0) continue;
        }
        *m = s_bulk[i];
        return true;
    }
    return false;
}

int gatt_mesh_bulk_pending(void)
{
    int n = 0;
    for (int i = 0; i < s_bulk_n; i++) {
        if (strcmp(s_bulk[i].state, "ready") == 0) n++;
    }
    return n;
}

int gatt_mesh_sendfile(const char *to, const char *path)
{
    struct stat st;
    if (stat(path, &st) != 0 || st.st_size <= 0) {
        printf("sendfile: cannot stat %s\n", path);
        return -1;
    }
    uint8_t sha[32];
    uint64_t size = 0;
    printf("sendfile: hashing %s (%ld B)...\n", path, (long)st.st_size);
    if (!sha256_file(path, sha, &size)) {
        printf("sendfile: read failed\n");
        return -1;
    }
    bulk_meta_t m;
    memset(&m, 0, sizeof(m));
    sha_hex(sha, m.sha);
    m.size = size;
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    const char *dot = strrchr(base, '.');
    snprintf(m.name, sizeof(m.name), "%s", base);
    if (dot && dot[1]) snprintf(m.ext, sizeof(m.ext), "%s", dot + 1);
    snprintf(m.origin, sizeof(m.origin), "%s", s_call);
    snprintf(m.target, sizeof(m.target), "%s", to);
    for (char *c = m.target; *c; c++) *c = (char)toupper((unsigned char)*c);
    snprintf(m.src, sizeof(m.src), "file");
    snprintf(m.state, sizeof(m.state), "ready");
    snprintf(m.path, sizeof(m.path), "%s", path);
    mkdir("/sdcard/mesh", 0775);
    mkdir(BULK_DIR, 0775);
    meta_write(&m);
    printf("sendfile: queued %s (%llu B, sha %.16s...) -> %s\n",
           m.name, (unsigned long long)size, m.sha, m.target);
    return 0;
}

/* ---- session ops ----------------------------------------------------------- */

/* Notify TX ring: a session burst (HELLO+GOSSIP+custody+FILE_OFFER right
 * after the peer's HELLO) far exceeds the in-flight credit — frames beyond
 * it must QUEUE, not drop (a dropped FILE_OFFER stalls the whole session:
 * the phone waits, idles out and disconnects — the exact failure seen in
 * the first live dongle session). */
#define TXQ_CAP 16
static uint8_t s_txq[TXQ_CAP][512];
static uint16_t s_txq_len[TXQ_CAP];
static int s_txq_head, s_txq_n;

static int notify_now(const uint8_t *frame, int len)
{
    struct os_mbuf *om = ble_hs_mbuf_from_flat(frame, len);
    if (!om) return BLE_HS_ENOMEM;
    return ble_gatts_notify_custom(s_conn, s_notify_handle, om);
}

static void txq_reset(void) { s_txq_head = 0; s_txq_n = 0; }

/* Drain queued frames into the in-flight window (host task context). */
static void txq_pump(void)
{
    while (s_txq_n > 0 && s_notify_inflight < NOTIFY_INFLIGHT_MAX) {
        int rc = notify_now(s_txq[s_txq_head], s_txq_len[s_txq_head]);
        if (rc != 0) break;              /* retry on the next NOTIFY_TX */
        s_txq_head = (s_txq_head + 1) % TXQ_CAP;
        s_txq_n--;
        s_notify_inflight++;
    }
}

static int op_send(void *ctx, const uint8_t *frame, int len)
{
    (void)ctx;
    /* NOT gated on s_subscribed: the SUBSCRIBE gap event can be lost on a
     * fringe link even though the central called setCharacteristicNotification
     * locally (Android delivers incoming notify PDUs regardless of the CCCD
     * round-trip). NimBLE transmits notify_custom without CCCD state. */
    if (s_conn == BLE_HS_CONN_HANDLE_NONE || len > 512) {
        return -1;
    }
    if (s_txq_n == 0 && s_notify_inflight < NOTIFY_INFLIGHT_MAX) {
        int rc = notify_now(frame, len);
        if (rc == 0) {
            s_notify_inflight++;
            return BLEMESH_SEND_OK;
        }
        ESP_LOGW(TAG, "notify rc=%d (type 0x%02x, %dB) - queueing", rc,
                 len >= 3 ? frame[2] : 0, len);
        /* controller busy: fall through to the queue */
    }
    if (s_txq_n >= TXQ_CAP) return BLEMESH_SEND_BUSY; /* pump pauses+resumes */
    int slot = (s_txq_head + s_txq_n) % TXQ_CAP;
    memcpy(s_txq[slot], frame, len);
    s_txq_len[slot] = (uint16_t)len;
    s_txq_n++;
    return BLEMESH_SEND_OK;
}

static int op_msg_pop(void *ctx, const char *peer, char am[7],
                      uint8_t *wire, int cap, uint32_t *ts)
{
    (void)ctx;
    char am8[8] = "";
    int n = blemesh_scf_pop_custody(peer, now_s(), am8, wire, cap, ts);
    memcpy(am, am8, 7);
    return n;
}

static void op_msg_transferred(void *ctx, const char *peer, const char *am)
{
    (void)ctx;
    ESP_LOGI(TAG, "custody of %s -> %s (purged)", am, peer);
    blemesh_scf_ack(am);   /* peer owns it now; our copy is done */
}

static int op_msg_rx(void *ctx, const char *peer, const char *am, uint32_t ts,
                     const uint8_t *wire, int len)
{
    (void)ctx; (void)ts;
    /* The dongle is a carrier: park whatever a session hands us. Target is
     * inside the compact frame (from \x1F to \x1F text). */
    char to[BLEMESH_CALLSIGN_MAX + 1] = "";
    int a = -1, b = -1;
    for (int i = 0; i < len; i++) {
        if (wire[i] == 0x1F) { if (a < 0) a = i; else { b = i; break; } }
    }
    if (a < 0 || b < 0 || b - a - 1 > BLEMESH_CALLSIGN_MAX) return 3; /* malformed */
    memcpy(to, wire + a + 1, b - a - 1);
    to[b - a - 1] = 0;
    if (!blemesh_scf_offer(to, am, wire, len, now_s())) return 1; /* duplicate */
    ESP_LOGI(TAG, "took custody of %s for %s (via %s)", am[0] ? am : "msg", to, peer);
    return 0;
}

static int op_gossip_build(void *ctx, uint8_t *frame, int cap)
{
    (void)ctx;
    if (cap < 8) return 0;
    /* GOSSIP: our DV digest; empty bloom (a carrier receives no 1:1s). */
    blemesh_dv_t dv[48];
    int k = blemesh_table_export(dv, 48);
    int max_k = (cap - 7) / 4;
    if (k > max_k) k = max_k;
    if (k > 255) k = 255;
    int n = 0;
    frame[n++] = BLEMESH_MSP_MAGIC;
    frame[n++] = BLEMESH_MSP_VER;
    frame[n++] = MSP_GOSSIP;
    frame[n++] = 0;               /* flags */
    frame[n++] = (uint8_t)k;
    for (int i = 0; i < k; i++) {
        memcpy(frame + n, dv[i].hash, 3); n += 3;
        frame[n++] = dv[i].cost;
    }
    frame[n++] = 0; frame[n++] = 0;   /* bloom_len = 0 */
    return n;
}

static void op_gossip_rx(void *ctx, const char *peer, const uint8_t *b, int n)
{
    (void)ctx; (void)peer; (void)b; (void)n;
    /* Beacons already feed the DV table; nothing extra needed here. */
}

static int op_bulk_next(void *ctx, const char *peer, uint8_t sha[32],
                        uint64_t *size, uint32_t *ttl, char origin[10],
                        char target[10], char ext[17], char name[65])
{
    (void)ctx;
    bulk_meta_t m;
    if (!bulk_scan("ready", peer, &m)) return 0;
    hex_to_sha(m.sha, sha);
    *size = m.size;
    *ttl = 7 * 24 * 3600;
    snprintf(origin, 10, "%s", m.origin);
    snprintf(target, 10, "%s", m.target);
    snprintf(ext, 17, "%s", m.ext);
    snprintf(name, 65, "%s", m.name);
    return 1;
}

static int op_bulk_offer_rx(void *ctx, const char *peer, const uint8_t sha[32],
                            uint64_t size, const char *origin,
                            const char *target, const char *ext,
                            const char *name, uint32_t *resume)
{
    (void)ctx; (void)peer;
    bulk_meta_t m;
    if (meta_read(sha, &m) && strcmp(m.state, "ready") == 0) {
        *resume = (uint32_t)size;       /* already hold it whole */
        return 0;
    }
    if (size > BULK_QUOTA_BYTES) return MSP_FREJ_QUOTA;
    char pp[160];
    part_path_for(sha, pp, sizeof(pp));
    struct stat st;
    uint32_t have = (stat(pp, &st) == 0) ? (uint32_t)st.st_size : 0;
    if (!m.sha[0]) {
        memset(&m, 0, sizeof(m));
        sha_hex(sha, m.sha);
        m.size = size;
        snprintf(m.ext, sizeof(m.ext), "%s", ext);
        snprintf(m.name, sizeof(m.name), "%s", name);
        snprintf(m.origin, sizeof(m.origin), "%s", origin);
        snprintf(m.target, sizeof(m.target), "%s", target);
        snprintf(m.src, sizeof(m.src), "rx");
        snprintf(m.state, sizeof(m.state), "rx");
        mkdir("/sdcard/mesh", 0775);
        mkdir(BULK_DIR, 0775);
        meta_write(&m);
    }
    *resume = have > size ? (uint32_t)size : have;
    ESP_LOGI(TAG, "bulk offer %s (%llu B) resume@%lu", name,
             (unsigned long long)size, (unsigned long)*resume);
    return 0;
}

static int op_bulk_read(void *ctx, const uint8_t sha[32], uint32_t off,
                        uint8_t *buf, int len)
{
    (void)ctx;
    bulk_meta_t m;
    if (!meta_read(sha, &m)) return 0;
    char pp[160];
    if (strcmp(m.src, "file") == 0) {
        snprintf(pp, sizeof(pp), "%s", m.path);
    } else {
        part_path_for(sha, pp, sizeof(pp));
    }
    FILE *f = fopen(pp, "rb");
    if (!f) return 0;
    int n = 0;
    if (fseek(f, (long)off, SEEK_SET) == 0) {
        n = (int)fread(buf, 1, (size_t)len, f);
    }
    fclose(f);
    return n;
}

static int op_bulk_write(void *ctx, const uint8_t sha[32], uint32_t off,
                         const uint8_t *d, int len)
{
    (void)ctx;
    char pp[160];
    part_path_for(sha, pp, sizeof(pp));
    FILE *f = fopen(pp, "r+b");
    if (!f) f = fopen(pp, "wb");
    if (!f) return -1;
    int rc = -1;
    if (fseek(f, (long)off, SEEK_SET) == 0 &&
        fwrite(d, 1, (size_t)len, f) == (size_t)len) {
        rc = 0;
    }
    fclose(f);
    return rc;
}

static int op_bulk_verify(void *ctx, const uint8_t sha[32])
{
    (void)ctx;
    char pp[160];
    part_path_for(sha, pp, sizeof(pp));
    uint8_t got[32];
    if (!sha256_file(pp, got, NULL)) return 0;
    if (memcmp(got, sha, 32) != 0) {
        remove(pp);                     /* poisoned partial: clean restart */
        return 0;
    }
    return 1;
}

static void op_bulk_done(void *ctx, const char *peer, const uint8_t sha[32],
                         int ok, int to_peer)
{
    (void)ctx;
    bulk_meta_t m;
    if (!meta_read(sha, &m)) return;
    if (!ok) return;                    /* spool keeps the offset for resume */
    if (to_peer) {
        /* Custody moved downstream. Origin entries keep their file (the
         * console owner's copy); relay copies are dropped. */
        if (strcmp(m.src, "file") == 0) {
            snprintf(m.state, sizeof(m.state), "done");
            meta_write(&m);
        } else {
            char pp[160], mp[160];
            part_path_for(sha, pp, sizeof(pp));
            meta_path_for(sha, mp, sizeof(mp));
            remove(pp);
            remove(mp);
            bulk_cache_remove(m.sha);
        }
        ESP_LOGI(TAG, "bulk %s handed to %s", m.name, peer);
    } else {
        /* Inbound complete + verified: we are a custodian (the dongle is
         * never a final target) — hold for forwarding. */
        snprintf(m.state, sizeof(m.state), "ready");
        meta_write(&m);
        ESP_LOGI(TAG, "bulk %s received, holding for %s", m.name, m.target);
    }
}

static void op_closed(void *ctx, const char *peer, int clean)
{
    (void)ctx;
    ESP_LOGI(TAG, "session with %s closed %s", peer[0] ? peer : "(pre-hello)",
             clean ? "cleanly" : "abruptly");
}

static const blemesh_session_ops_t OPS = {
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

/* ---- GATT service ---------------------------------------------------------- */

static int gatt_write_cb(uint16_t conn_handle, uint16_t attr_handle,
                         struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)attr_handle; (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return 0;
    static uint8_t buf[520];
    uint16_t len = 0;
    if (ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof(buf), &len) != 0) return 0;
    if (!blemesh_msp_is_frame(buf, len)) return 0;   /* not ours: ignore */
    s_conn = conn_handle;
    s_last_msp = now_s();
    if (xSemaphoreTake(s_lock, pdMS_TO_TICKS(2000)) == pdTRUE) {
        /* A HELLO always begins a fresh session: a stale active session from
         * a dead connection would swallow it (state!=0 ignores HELLO) and the
         * new peer would never get a reply (seen live). */
        if (len >= 3 && buf[2] == MSP_HELLO && s_session_up) {
            blemesh_session_close(&s_sess, false);
            s_session_up = false;
        }
        if (!s_session_up) {
            blemesh_session_init(&s_sess, &OPS, s_call,
                                 MSP_CAP_MSG | MSP_CAP_BULK_RX |
                                 MSP_CAP_BULK_TX | MSP_CAP_GOSSIP,
                                 509, false, now_s());
            blemesh_session_set_pending(
                &s_sess, (uint16_t)blemesh_scf_count(),
                (uint8_t)gatt_mesh_bulk_pending(), 0);
            s_session_up = true;
        }
        blemesh_session_rx(&s_sess, buf, len, now_s());
        ESP_LOGI(TAG, "msp rx type 0x%02x %dB (peer=%s state=%d)",
                 buf[2], len, s_sess.peer, s_sess.state);
        xSemaphoreGive(s_lock);
    }
    return 0;
}

static int gatt_notify_cb(uint16_t conn_handle, uint16_t attr_handle,
                          struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle; (void)attr_handle; (void)ctxt; (void)arg;
    return 0;
}

static const struct ble_gatt_svc_def s_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = BLE_UUID16_DECLARE(SVC_UUID),
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = BLE_UUID16_DECLARE(CHR_WRITE_UUID),
                .access_cb = gatt_write_cb,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
            },
            {
                .uuid = BLE_UUID16_DECLARE(CHR_NOTIFY_UUID),
                .access_cb = gatt_notify_cb,
                .val_handle = &s_notify_handle,
                .flags = BLE_GATT_CHR_F_NOTIFY,
            },
            { 0 },
        },
    },
    { 0 },
};

void gatt_mesh_svcs_init(void)
{
    s_lock = xSemaphoreCreateMutex();
    ble_svc_gap_init();
    ble_svc_gatt_init();
    int rc = ble_gatts_count_cfg(s_svcs);
    if (rc == 0) rc = ble_gatts_add_svcs(s_svcs);
    if (rc != 0) ESP_LOGE(TAG, "gatt svc registration rc=%d", rc);
    ble_att_set_preferred_mtu(512);
}

/* ---- connectable presence advert (instance 1, legacy PDU) ------------------ */

static int conn_gap_event(struct ble_gap_event *ev, void *arg);

static void start_conn_advert(void)
{
    struct ble_gap_ext_adv_params p = {0};
    p.legacy_pdu = 1;
    p.connectable = 1;
    p.scannable = 1;                 /* legacy connectable = ADV_IND */
    p.own_addr_type = s_addr_type;
    p.primary_phy = BLE_HCI_LE_PHY_1M;
    p.secondary_phy = BLE_HCI_LE_PHY_1M;
    p.itvl_min = 0xA0;               /* 100 ms — fringe centrals need every
                                        ADV_IND chance they can get */
    p.itvl_max = 0xC0;
    p.sid = 1;

    int rc = ble_gap_ext_adv_configure(ADV_INSTANCE, &p, NULL,
                                       conn_gap_event, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) {
        ESP_LOGE(TAG, "conn adv configure rc=%d", rc);
        return;
    }
    /* AD: flags + presence manufacturer data FF FF 3E <devId> <callsign>. */
    uint8_t ad[31];
    int n = 0;
    ad[n++] = 2; ad[n++] = 0x01; ad[n++] = 0x06;          /* flags */
    int cs = (int)strlen(s_call);
    if (cs > 9) cs = 9;
    ad[n++] = (uint8_t)(4 + cs);
    ad[n++] = 0xFF;                                       /* mfr data */
    ad[n++] = 0xFF; ad[n++] = 0xFF;                       /* company 0xFFFF */
    ad[n++] = 0x3E;                                       /* marker */
    ad[n++] = 5;                                          /* devId (1..15) */
    memcpy(ad + n, s_call, cs); n += cs;

    struct os_mbuf *om = ble_hs_mbuf_from_flat(ad, n);
    if (!om) return;
    rc = ble_gap_ext_adv_set_data(ADV_INSTANCE, om);
    if (rc != 0) { ESP_LOGE(TAG, "conn adv data rc=%d", rc); return; }
    rc = ble_gap_ext_adv_start(ADV_INSTANCE, 0, 0);
    if (rc != 0 && rc != BLE_HS_EALREADY) {
        ESP_LOGE(TAG, "conn adv start rc=%d", rc);
    } else {
        ESP_LOGI(TAG, "connectable presence advert up (instance %d)", ADV_INSTANCE);
    }
}

static int conn_gap_event(struct ble_gap_event *ev, void *arg)
{
    (void)arg;
    switch (ev->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (ev->connect.status == 0) {
            s_conn = ev->connect.conn_handle;
            s_conn_since = now_s();
            s_last_msp = 0;
            s_subscribed = false;
            s_notify_inflight = 0;
            ESP_LOGI(TAG, "central connected (handle %d)", s_conn);
        } else {
            start_conn_advert();
        }
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "central disconnected (reason %d)",
                 ev->disconnect.reason);
        if (xSemaphoreTake(s_lock, pdMS_TO_TICKS(2000)) == pdTRUE) {
            if (s_session_up) {
                blemesh_session_close(&s_sess, false);
                s_session_up = false;
            }
            xSemaphoreGive(s_lock);
        }
        s_conn = BLE_HS_CONN_HANDLE_NONE;
        s_subscribed = false;
        s_notify_inflight = 0;
        txq_reset();
        start_conn_advert();            /* back on the air for the next dial */
        break;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if (ev->subscribe.attr_handle == s_notify_handle) {
            s_subscribed = ev->subscribe.cur_notify;
            ESP_LOGI(TAG, "central %ssubscribed FFF2 (conn %d)",
                     s_subscribed ? "" : "un", ev->subscribe.conn_handle);
            s_conn = ev->subscribe.conn_handle;
        }
        break;
    case BLE_GAP_EVENT_NOTIFY_TX:
        if (s_notify_inflight > 0) s_notify_inflight--;
        txq_pump();                      /* queued control/chunk frames first */
        if (xSemaphoreTake(s_lock, pdMS_TO_TICKS(500)) == pdTRUE) {
            if (s_session_up) blemesh_session_tx_ready(&s_sess, now_s());
            xSemaphoreGive(s_lock);
        }
        break;
    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(TAG, "MTU %d", ev->mtu.value);
        break;
    default:
        break;
    }
    return 0;
}

void gatt_mesh_start(const char *callsign, uint8_t own_addr_type)
{
    snprintf(s_call, sizeof(s_call), "%s", callsign);
    s_addr_type = own_addr_type;
    bulk_cache_load();   /* one dir walk, before radio traffic ramps */
    start_conn_advert();
}

void gatt_mesh_conn_adv(bool on)
{
    if (on) {
        start_conn_advert();
    } else {
        ble_gap_ext_adv_stop(ADV_INSTANCE);
    }
}

void gatt_mesh_tick(void)
{
    if (!s_lock) return;
    /* Drain any queued notifies even when no NOTIFY_TX is pending — a
     * first-send failure would otherwise deadlock the queue (nothing in
     * flight -> no NOTIFY_TX -> pump never runs). */
    if (s_conn != BLE_HS_CONN_HANDLE_NONE) txq_pump();
    /* Idle-central reaper: a fringe central can hold a healthy LL link yet
     * never complete the ATT handshake (seen live: 23 min of silence). A
     * silent link pins instance 1 (no re-advertising, no fresh dials) —
     * terminate it so the next attempt starts clean. */
    if (s_conn != BLE_HS_CONN_HANDLE_NONE) {
        uint32_t ref = s_last_msp ? s_last_msp : s_conn_since;
        if (now_s() - ref > 45 && !s_session_up) {
            ESP_LOGW(TAG, "silent central for %lus - terminating",
                     (unsigned long)(now_s() - ref));
            ble_gap_terminate(s_conn, BLE_ERR_REM_USER_CONN_TERM);
        }
    }
    if (xSemaphoreTake(s_lock, pdMS_TO_TICKS(200)) == pdTRUE) {
        if (s_session_up) {
            blemesh_session_poll_bulk(&s_sess, now_s()); /* routes may be new */
            blemesh_session_tick(&s_sess, now_s());
            if (blemesh_session_closed(&s_sess)) {
                s_session_up = false;
                /* Session done (politeness/BYE): drop the link so the phone's
                 * radio returns to broadcast; we re-advertise on disconnect. */
                if (s_conn != BLE_HS_CONN_HANDLE_NONE) {
                    ble_gap_terminate(s_conn, BLE_ERR_REM_USER_CONN_TERM);
                }
            }
        }
        xSemaphoreGive(s_lock);
    }
}

void gatt_mesh_print_status(void)
{
    printf("gatt: conn=%d subscribed=%d session=%d inflight=%d\n",
           s_conn == BLE_HS_CONN_HANDLE_NONE ? 0 : 1, s_subscribed ? 1 : 0,
           s_session_up ? 1 : 0, s_notify_inflight);
    for (int i = 0; i < s_bulk_n; i++) {
        printf("spool: %s %s -> %s %llu B state=%s\n", s_bulk[i].name,
               s_bulk[i].origin, s_bulk[i].target,
               (unsigned long long)s_bulk[i].size, s_bulk[i].state);
    }
    if (!s_bulk_n) printf("spool: empty\n");
}
