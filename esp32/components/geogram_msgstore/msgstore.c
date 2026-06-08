/**
 * @file msgstore.c
 * @brief SD-backed, index-addressed APRS message log. See msgstore.h.
 *
 * On-disk: fixed 192-byte records in segment files /sdcard/aprs/seg_<first>.bin,
 * each holding MSGSTORE_RECS_PER_SEGMENT records. The filename number is the
 * index of the segment's first record (a multiple of the segment size), so
 * lexical filename order == index order and evicting the oldest messages is just
 * deleting the lowest-numbered segment file(s). An in-RAM table maps segments to
 * their first index + valid count; it is rebuilt by scanning the directory on
 * boot. The next monotonic index is (max index on disk) + 1.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include <dirent.h>
#include <unistd.h>
#include <sys/stat.h>

#include "msgstore.h"
#include "sdcard.h"
#include "esp_vfs_fat.h"
#include "esp_random.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

static const char *TAG = "msgstore";

#define MS_MOUNT            "/sdcard"
#define MS_DIR              "/sdcard/aprs"
#define MS_EPOCH_PATH       "/sdcard/aprs/epoch"
#define MS_MAGIC            0x47
#define MS_FLAG_OUTGOING    0x01
#define MS_RECS_PER_SEG     4096u
#define MS_MAX_SEGMENTS     272      /* >= ceil(1e6/4096)+margin */
#define MS_HARD_CAP         1000000u
#define MS_FSYNC_EVERY      16
#define MS_DEDUP_RING       64
#define MS_DEFAULT_LIMIT    50u
#define MS_MAX_LIMIT        500u

/* Packed 192-byte on-disk record. */
typedef struct __attribute__((packed)) {
    uint8_t  magic;        /* MS_MAGIC when valid; 0 = empty/torn */
    uint8_t  kind;         /* msgstore_kind_t */
    int8_t   rssi;
    uint8_t  flags;        /* bit0 outgoing */
    uint32_t index;        /* little-endian (native LE on xtensa) */
    uint32_t hash;
    char     from[MSGSTORE_CALL_LEN];
    char     to[MSGSTORE_CALL_LEN];
    char     text[MSGSTORE_TEXT_LEN];
} ms_rec_t;

_Static_assert(sizeof(ms_rec_t) == 192, "record must be 192 bytes");

typedef struct {
    uint32_t first_index;  /* == filename number (multiple of MS_RECS_PER_SEG) */
    uint16_t count;        /* valid records in this segment */
} ms_seg_t;

static SemaphoreHandle_t s_mtx;
static bool      s_ready;
static ms_seg_t  s_segs[MS_MAX_SEGMENTS];
static int       s_nseg;
static uint32_t  s_next_index;     /* index to assign to the next record */
static uint32_t  s_oldest_index;   /* index of the oldest stored record */
static uint32_t  s_count;          /* total live records */
static uint32_t  s_cap;            /* capacity in records */
static char      s_epoch = '?';
static FILE     *s_active_fp;
static uint32_t  s_active_first = UINT32_MAX;
static int       s_active_seg = -1;
static int       s_since_sync;
static uint32_t  s_dedup[MS_DEDUP_RING];
static int       s_dedup_pos;

/* ---- small helpers ----------------------------------------------------- */

static uint32_t fnv1a(const char *s)
{
    uint32_t h = 2166136261u;
    for (; s && *s; s++) { h ^= (uint8_t)*s; h *= 16777619u; }
    return h;
}

/* Normalise a callsign: uppercase, stop at '-' or first non-alnum. */
static void norm_call(char *dst, size_t cap, const char *src)
{
    size_t n = 0;
    for (size_t i = 0; src && src[i] && n + 1 < cap; i++) {
        char c = src[i];
        if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
        if (c == '-') break;
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) dst[n++] = c;
        else break;
    }
    dst[n] = 0;
}

static void seg_path(char *out, size_t cap, uint32_t first_index)
{
    snprintf(out, cap, "%s/seg_%010u.bin", MS_DIR, (unsigned)first_index);
}

static int find_seg(uint32_t first_index)
{
    for (int i = 0; i < s_nseg; i++)
        if (s_segs[i].first_index == first_index) return i;
    return -1;
}

/* ---- capacity ---------------------------------------------------------- */

static void recompute_cap(void)
{
    uint64_t total = 0, freeb = 0;
    if (esp_vfs_fat_info(MS_MOUNT, &total, &freeb) != ESP_OK) {
        s_cap = MS_HARD_CAP;
        return;
    }
    /* Usable = current free + what the store already occupies, at 90% margin. */
    uint64_t usable = freeb + (uint64_t)s_count * sizeof(ms_rec_t);
    uint64_t by_space = (usable * 9 / 10) / sizeof(ms_rec_t);
    uint64_t cap = by_space < MS_HARD_CAP ? by_space : MS_HARD_CAP;
    if (cap < MS_RECS_PER_SEG) cap = MS_RECS_PER_SEG;
    s_cap = (uint32_t)cap;
}

/* ---- boot scan --------------------------------------------------------- */

static void sort_segs(void)
{
    for (int i = 1; i < s_nseg; i++) {           /* insertion sort, n is small */
        ms_seg_t key = s_segs[i];
        int j = i - 1;
        while (j >= 0 && s_segs[j].first_index > key.first_index) {
            s_segs[j + 1] = s_segs[j]; j--;
        }
        s_segs[j + 1] = key;
    }
}

/* Count leading valid records in a segment file (used only for the tail seg). */
static uint16_t scan_seg_count(uint32_t first_index)
{
    char path[64];
    seg_path(path, sizeof path, first_index);
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    uint16_t count = 0;
    ms_rec_t r;
    for (uint32_t i = 0; i < MS_RECS_PER_SEG; i++) {
        if (fread(&r, sizeof r, 1, f) != 1) break;
        if (r.magic != MS_MAGIC || r.index != first_index + i) break;
        count++;
    }
    fclose(f);
    return count;
}

static void load_epoch(bool store_empty)
{
    char e = 0;
    if (!store_empty) {
        FILE *f = fopen(MS_EPOCH_PATH, "rb");
        if (f) { if (fread(&e, 1, 1, f) != 1) e = 0; fclose(f); }
    }
    if (e < 'A' || e > 'Z') {                 /* empty store, or missing/bad */
        e = (char)('A' + (esp_random() % 26));
        FILE *f = fopen(MS_EPOCH_PATH, "wb");
        if (f) { fwrite(&e, 1, 1, f); fclose(f); }
    }
    s_epoch = e;
}

esp_err_t msgstore_init(void)
{
    if (s_ready) return ESP_OK;
    if (!sdcard_is_mounted()) {
        ESP_LOGW(TAG, "no SD card mounted — persistence disabled");
        return ESP_ERR_INVALID_STATE;
    }
    if (!s_mtx) s_mtx = xSemaphoreCreateMutex();
    if (!s_mtx) return ESP_ERR_NO_MEM;

    sdcard_mkdir(MS_DIR);

    /* Scan segment files. */
    s_nseg = 0;
    DIR *d = opendir(MS_DIR);
    if (d) {
        struct dirent *de;
        while ((de = readdir(d)) != NULL && s_nseg < MS_MAX_SEGMENTS) {
            if (strncmp(de->d_name, "seg_", 4) != 0) continue;
            const char *dot = strstr(de->d_name, ".bin");
            if (!dot) continue;
            uint32_t first = (uint32_t)strtoul(de->d_name + 4, NULL, 10);
            if (first % MS_RECS_PER_SEG != 0) continue;
            s_segs[s_nseg].first_index = first;
            s_segs[s_nseg].count = MS_RECS_PER_SEG;  /* refined below */
            s_nseg++;
        }
        closedir(d);
    }
    sort_segs();

    s_count = 0;
    if (s_nseg == 0) {
        s_oldest_index = 0;
        s_next_index = 0;
    } else {
        /* Middle segments are full by construction; only the tail is partial. */
        for (int i = 0; i < s_nseg - 1; i++) s_count += s_segs[i].count;
        uint16_t tail = scan_seg_count(s_segs[s_nseg - 1].first_index);
        s_segs[s_nseg - 1].count = tail;
        s_count += tail;
        s_oldest_index = s_segs[0].first_index;
        s_next_index = s_segs[s_nseg - 1].first_index + tail;
        /* A fully-empty tail file (tail==0) is harmless: we resume writing into it. */
    }

    recompute_cap();
    load_epoch(s_count == 0);

    s_active_fp = NULL;
    s_active_first = UINT32_MAX;
    s_active_seg = -1;
    s_since_sync = 0;
    memset(s_dedup, 0, sizeof s_dedup);
    s_dedup_pos = 0;
    s_ready = true;

    ESP_LOGI(TAG, "ready: epoch=%c count=%u next=%u oldest=%u cap=%u segs=%d",
             s_epoch, (unsigned)s_count, (unsigned)s_next_index,
             (unsigned)s_oldest_index, (unsigned)s_cap, s_nseg);
    return ESP_OK;
}

bool msgstore_ready(void) { return s_ready; }

/* ---- eviction ---------------------------------------------------------- */

/* Delete oldest whole segments until ~10% of cap is freed. Caller holds mutex
 * and must NOT have the to-be-created segment in s_segs yet. */
static void evict_oldest(void)
{
    uint32_t target = s_cap / 10;
    if (target < MS_RECS_PER_SEG) target = MS_RECS_PER_SEG;
    uint32_t freed = 0;
    while (freed < target && s_nseg > 1) {
        char path[64];
        seg_path(path, sizeof path, s_segs[0].first_index);
        sdcard_delete_file(path);
        freed += s_segs[0].count;
        if (s_count >= s_segs[0].count) s_count -= s_segs[0].count; else s_count = 0;
        memmove(&s_segs[0], &s_segs[1], (size_t)(s_nseg - 1) * sizeof(ms_seg_t));
        s_nseg--;
        s_oldest_index = s_segs[0].first_index;
    }
    ESP_LOGI(TAG, "evicted ~%u old records (oldest now %u)",
             (unsigned)freed, (unsigned)s_oldest_index);
}

/* ---- add --------------------------------------------------------------- */

esp_err_t msgstore_add(const char *from, const char *to, const char *text,
                       msgstore_kind_t kind, int rssi, bool outgoing)
{
    if (!s_ready) return ESP_ERR_INVALID_STATE;
    if (!from) from = "";
    if (!to) to = "";
    if (!text) text = "";

    /* Content hash (also stored for integrity) and recent-dup check. */
    char hbuf[MSGSTORE_CALL_LEN * 2 + MSGSTORE_TEXT_LEN + 4];
    snprintf(hbuf, sizeof hbuf, "%s\x1f%s\x1f%s", from, to, text);
    uint32_t hash = fnv1a(hbuf);

    xSemaphoreTake(s_mtx, portMAX_DELAY);

    for (int i = 0; i < MS_DEDUP_RING; i++) {
        if (s_dedup[i] == hash) { xSemaphoreGive(s_mtx); return ESP_OK; }
    }

    uint32_t idx = s_next_index;
    uint32_t seg_first = (idx / MS_RECS_PER_SEG) * MS_RECS_PER_SEG;

    if (s_active_fp == NULL || s_active_first != seg_first) {
        if (s_active_fp) { fflush(s_active_fp); fclose(s_active_fp); s_active_fp = NULL; }
        char path[64];
        seg_path(path, sizeof path, seg_first);
        int si = find_seg(seg_first);
        if (si < 0) {
            /* Brand-new segment: enforce cap, refresh free-space estimate. */
            recompute_cap();
            if (s_count >= s_cap) evict_oldest();
            s_active_fp = fopen(path, "wb+");
            if (!s_active_fp) { xSemaphoreGive(s_mtx); ESP_LOGW(TAG, "open new seg failed"); return ESP_FAIL; }
            s_segs[s_nseg].first_index = seg_first;
            s_segs[s_nseg].count = 0;
            s_active_seg = s_nseg;
            s_nseg++;
            if (s_count == 0) s_oldest_index = seg_first;
        } else {
            s_active_fp = fopen(path, "rb+");
            if (!s_active_fp) { xSemaphoreGive(s_mtx); ESP_LOGW(TAG, "reopen seg failed"); return ESP_FAIL; }
            s_active_seg = si;
        }
        s_active_first = seg_first;
    }

    ms_rec_t r;
    memset(&r, 0, sizeof r);
    r.magic = MS_MAGIC;
    r.kind = (uint8_t)kind;
    r.rssi = (int8_t)rssi;
    r.flags = outgoing ? MS_FLAG_OUTGOING : 0;
    r.index = idx;
    r.hash = hash;
    strlcpy(r.from, from, sizeof r.from);
    strlcpy(r.to, to, sizeof r.to);
    strlcpy(r.text, text, sizeof r.text);

    long off = (long)(idx % MS_RECS_PER_SEG) * (long)sizeof(ms_rec_t);
    if (fseek(s_active_fp, off, SEEK_SET) != 0 ||
        fwrite(&r, sizeof r, 1, s_active_fp) != 1) {
        xSemaphoreGive(s_mtx);
        ESP_LOGW(TAG, "write failed at index %u", (unsigned)idx);
        return ESP_FAIL;
    }

    s_segs[s_active_seg].count = (uint16_t)((idx % MS_RECS_PER_SEG) + 1);
    s_next_index = idx + 1;
    s_count++;
    s_dedup[s_dedup_pos] = hash;
    s_dedup_pos = (s_dedup_pos + 1) % MS_DEDUP_RING;

    if (++s_since_sync >= MS_FSYNC_EVERY) {
        fflush(s_active_fp);
        fsync(fileno(s_active_fp));
        s_since_sync = 0;
    }

    xSemaphoreGive(s_mtx);
    return ESP_OK;
}

/* ---- query ------------------------------------------------------------- */

static bool call_matches(const ms_rec_t *r, const char *norm_filter)
{
    char tmp[MSGSTORE_CALL_LEN];
    norm_call(tmp, sizeof tmp, r->from);
    if (strcmp(tmp, norm_filter) == 0) return true;
    norm_call(tmp, sizeof tmp, r->to);
    return strcmp(tmp, norm_filter) == 0;
}

size_t msgstore_query(const msgstore_query_t *q, msgstore_emit_cb_t cb, void *ctx,
                      uint32_t *out_next, bool *out_more)
{
    uint32_t next = q ? q->since_index : 0;
    bool more = false;
    size_t matched = 0;
    if (!s_ready || !q) { if (out_next) *out_next = next; if (out_more) *out_more = false; return 0; }

    uint32_t limit = q->limit ? q->limit : MS_DEFAULT_LIMIT;
    if (limit > MS_MAX_LIMIT) limit = MS_MAX_LIMIT;

    char nfilter[MSGSTORE_CALL_LEN] = {0};
    bool use_call = q->call_filter && q->call_filter[0];
    if (use_call) norm_call(nfilter, sizeof nfilter, q->call_filter);

    xSemaphoreTake(s_mtx, portMAX_DELAY);
    if (s_active_fp) fflush(s_active_fp);   /* make latest records visible to reads */

    if (s_count == 0) { xSemaphoreGive(s_mtx); if (out_next) *out_next = next; if (out_more) *out_more = false; return 0; }

    uint32_t start = q->since_index + 1;
    if (start < s_oldest_index) start = s_oldest_index;

    for (int si = 0; si < s_nseg && !more; si++) {
        uint32_t sf = s_segs[si].first_index;
        uint32_t sc = s_segs[si].count;
        if (sc == 0) continue;
        if (sf + sc - 1 < start) continue;       /* whole segment below start */

        char path[64];
        seg_path(path, sizeof path, sf);
        FILE *f = fopen(path, "rb");
        if (!f) continue;

        uint32_t i0 = (start > sf) ? (start - sf) : 0;
        if (i0) fseek(f, (long)i0 * (long)sizeof(ms_rec_t), SEEK_SET);

        ms_rec_t r;
        for (uint32_t i = i0; i < sc; i++) {
            if (fread(&r, sizeof r, 1, f) != 1) break;
            if (r.magic != MS_MAGIC) continue;
            if (r.index <= q->since_index) continue;
            if (q->kind_filter >= 0 && r.kind != (uint8_t)q->kind_filter) continue;
            if (use_call && !call_matches(&r, nfilter)) continue;

            if (matched >= limit) { more = true; break; }   /* one more match exists */

            if (cb) {
                msgstore_query_rec_t out;
                out.index = r.index;
                out.kind = r.kind;
                out.rssi = r.rssi;
                out.outgoing = (r.flags & MS_FLAG_OUTGOING) != 0;
                memcpy(out.from, r.from, sizeof out.from);
                memcpy(out.to, r.to, sizeof out.to);
                memcpy(out.text, r.text, sizeof out.text);
                out.from[MSGSTORE_CALL_LEN - 1] = 0;
                out.to[MSGSTORE_CALL_LEN - 1] = 0;
                out.text[MSGSTORE_TEXT_LEN - 1] = 0;
                if (!cb(&out, ctx)) { more = true; fclose(f); goto done; }
            }
            matched++;
            next = r.index;
        }
        fclose(f);
    }
done:
    xSemaphoreGive(s_mtx);
    if (out_next) *out_next = next;
    if (out_more) *out_more = more;
    return matched;
}

/* ---- accessors --------------------------------------------------------- */

uint32_t msgstore_get_latest_index(void)
{
    return s_next_index ? s_next_index - 1 : 0;
}

char msgstore_get_epoch(void) { return s_ready ? s_epoch : '?'; }

uint32_t msgstore_get_count(void) { return s_count; }

void msgstore_get_stats(msgstore_stats_t *out)
{
    if (!out) return;
    memset(out, 0, sizeof *out);
    if (!s_ready) { out->epoch = '?'; return; }
    xSemaphoreTake(s_mtx, portMAX_DELAY);
    out->count = s_count;
    out->cap = s_cap;
    out->latest_index = s_next_index ? s_next_index - 1 : 0;
    out->epoch = s_epoch;
    uint64_t total = 0, freeb = 0;
    if (esp_vfs_fat_info(MS_MOUNT, &total, &freeb) == ESP_OK) {
        out->total_bytes = total; out->free_bytes = freeb;
    }
    xSemaphoreGive(s_mtx);
}

msgstore_kind_t msgstore_kind_from_to(const char *to)
{
    if (!to || to[0] == 0) return MSGSTORE_KIND_GEOCHAT;
    if (to[0] == '!') return MSGSTORE_KIND_POSITION;
    if (to[0] == '#') return MSGSTORE_KIND_GROUP;
    return MSGSTORE_KIND_MESSAGE;
}

/* ---- JSON page builder ------------------------------------------------- */

static const char *kind_name(uint8_t k)
{
    switch (k) {
    case MSGSTORE_KIND_POSITION: return "position";
    case MSGSTORE_KIND_MESSAGE:  return "message";
    case MSGSTORE_KIND_GROUP:    return "group";
    case MSGSTORE_KIND_GEOCHAT:  return "geochat";
    default:                     return "other";
    }
}

/* Append a JSON-escaped string. Returns false if it would overflow. */
static bool json_append_escaped(char *buf, size_t size, size_t *len, const char *s)
{
    size_t n = *len;
    for (; s && *s; s++) {
        char esc[8];
        int el;
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { esc[0] = '\\'; esc[1] = (char)c; el = 2; }
        else if (c == '\n') { memcpy(esc, "\\n", 2); el = 2; }
        else if (c == '\r') { memcpy(esc, "\\r", 2); el = 2; }
        else if (c == '\t') { memcpy(esc, "\\t", 2); el = 2; }
        else if (c < 0x20) { el = snprintf(esc, sizeof esc, "\\u%04x", c); }
        else { esc[0] = (char)c; el = 1; }
        if (n + (size_t)el + 1 >= size) return false;
        memcpy(buf + n, esc, el); n += el;
    }
    buf[n] = 0; *len = n;
    return true;
}

typedef struct {
    char    *buf;
    size_t   size;
    size_t   len;
    char     epoch;
    bool     first;
    bool     full;        /* a record didn't fit */
    uint32_t last_fit;    /* index of last record that fit */
    size_t   tail_reserve;
} json_ctx_t;

static bool json_emit_cb(const msgstore_query_rec_t *r, void *vctx)
{
    json_ctx_t *c = (json_ctx_t *)vctx;
    /* Build into a scratch then commit only if it fits (with tail reserve). */
    char obj[320];
    size_t ol = 0;
    obj[0] = 0;
    int n = snprintf(obj, sizeof obj, "%s{\"index\":\"%c%u\",\"from\":\"",
                     c->first ? "" : ",", c->epoch, (unsigned)r->index);
    if (n < 0 || n >= (int)sizeof obj) return false;
    ol = (size_t)n;
    if (!json_append_escaped(obj, sizeof obj, &ol, r->from)) return false;

    n = snprintf(obj + ol, sizeof obj - ol, "\",\"to\":\"");
    if (n < 0) return false;
    ol += (size_t)n;
    if (!json_append_escaped(obj, sizeof obj, &ol, r->to)) return false;

    n = snprintf(obj + ol, sizeof obj - ol, "\",\"text\":\"");
    if (n < 0) return false;
    ol += (size_t)n;
    if (!json_append_escaped(obj, sizeof obj, &ol, r->text)) return false;

    n = snprintf(obj + ol, sizeof obj - ol, "\",\"type\":\"%s\"", kind_name(r->kind));
    if (n < 0 || ol + (size_t)n >= sizeof obj) return false;
    ol += (size_t)n;

    if (r->kind == MSGSTORE_KIND_POSITION) {
        double lat = 0, lon = 0;
        if (sscanf(r->text, "%lf,%lf", &lat, &lon) == 2) {
            n = snprintf(obj + ol, sizeof obj - ol, ",\"lat\":%.5f,\"lon\":%.5f", lat, lon);
            if (n < 0 || ol + (size_t)n >= sizeof obj) return false;
            ol += (size_t)n;
        }
    }
    if (ol + 1 >= sizeof obj) return false;
    obj[ol++] = '}';
    obj[ol] = 0;

    if (c->len + ol + c->tail_reserve >= c->size) { c->full = true; return false; }
    memcpy(c->buf + c->len, obj, ol);
    c->len += ol; c->buf[c->len] = 0;
    c->first = false;
    c->last_fit = r->index;
    return true;
}

size_t msgstore_build_json(char *buf, size_t size, const msgstore_query_t *q)
{
    if (!buf || size < 128 || !q) return 0;
    char epoch = msgstore_get_epoch();
    uint32_t latest = msgstore_get_latest_index();

    json_ctx_t c = {
        .buf = buf, .size = size, .len = 0, .epoch = epoch,
        .first = true, .full = false, .last_fit = q->since_index,
        .tail_reserve = 96,
    };
    c.len = (size_t)snprintf(buf, size,
        "{\"epoch\":\"%c\",\"latest_index\":\"%c%u\",\"messages\":[",
        epoch, epoch, (unsigned)latest);

    uint32_t qnext = q->since_index;
    bool qmore = false;
    size_t matched = msgstore_query(q, json_emit_cb, &c, &qnext, &qmore);

    uint32_t next = c.full ? c.last_fit : qnext;
    bool more = qmore || c.full;

    int n = snprintf(buf + c.len, size - c.len,
        "],\"next\":\"%c%u\",\"more\":%s,\"count\":%u}",
        epoch, (unsigned)next, more ? "true" : "false", (unsigned)matched);
    if (n > 0) c.len += (size_t)n;
    return c.len;
}
