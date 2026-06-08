/**
 * @file msgstore.c
 * @brief SD-backed, index-addressed APRS message log. See msgstore.h.
 *
 * On-disk: fixed 192-byte records in segment files <dir>/seg_<first>.bin, each
 * holding MS_RECS_PER_SEG records. The filename number is the index of the
 * segment's first record (a multiple of the segment size), so lexical filename
 * order == index order and evicting the oldest messages is just deleting the
 * lowest-numbered segment file(s). An in-RAM table maps segments to their first
 * index + valid count; it is rebuilt by scanning the directory on open. The next
 * monotonic index is (max index on disk) + 1.
 *
 * The store is INSTANCE-BASED: each msgstore_open(dir) is an independent log with
 * its own index, epoch and eviction, so e.g. messages and position beacons can be
 * kept in separate archives on the same card.
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
#define MS_MAGIC            0x47
#define MS_FLAG_OUTGOING    0x01
#define MS_RECS_PER_SEG     4096u
#define MS_MAX_SEGMENTS     272      /* >= ceil(1e6/4096)+margin */
#define MS_HARD_CAP         1000000u
#define MS_FSYNC_EVERY      16
#define MS_DEDUP_RING       64
#define MS_DEFAULT_LIMIT    50u
#define MS_MAX_LIMIT        500u
#define MS_DIR_LEN          40

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

/* One store instance. */
struct msgstore_s {
    char             dir[MS_DIR_LEN];
    SemaphoreHandle_t mtx;
    bool             ready;
    ms_seg_t         segs[MS_MAX_SEGMENTS];
    int              nseg;
    uint32_t         next_index;    /* index to assign to the next record */
    uint32_t         oldest_index;  /* index of the oldest stored record */
    uint32_t         count;         /* total live records */
    uint32_t         cap;           /* capacity in records */
    char             epoch;
    FILE            *active_fp;
    uint32_t         active_first;
    int              active_seg;
    int              since_sync;
    uint32_t         dedup[MS_DEDUP_RING];
    int              dedup_pos;
    char             diag[24];
};

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

static void seg_path(const msgstore_t *st, char *out, size_t cap, uint32_t first_index)
{
    snprintf(out, cap, "%s/seg_%010u.bin", st->dir, (unsigned)first_index);
}

static void epoch_path(const msgstore_t *st, char *out, size_t cap)
{
    snprintf(out, cap, "%s/epoch", st->dir);
}

static int find_seg(const msgstore_t *st, uint32_t first_index)
{
    for (int i = 0; i < st->nseg; i++)
        if (st->segs[i].first_index == first_index) return i;
    return -1;
}

/* Create @p path and any missing parent directories (best effort). */
static void mkdir_p(const char *path)
{
    char tmp[MS_DIR_LEN];
    size_t n = strlcpy(tmp, path, sizeof tmp);
    if (n >= sizeof tmp) return;
    for (char *p = tmp + 1; *p; p++) {
        if (*p != '/') continue;
        *p = 0;
        mkdir(tmp, 0755);
        *p = '/';
    }
    mkdir(tmp, 0755);
}

/* ---- capacity ---------------------------------------------------------- */

static void recompute_cap(msgstore_t *st)
{
    uint64_t total = 0, freeb = 0;
    if (esp_vfs_fat_info(MS_MOUNT, &total, &freeb) != ESP_OK) {
        st->cap = MS_HARD_CAP;
        return;
    }
    /* Usable = current free + what the store already occupies, at 90% margin. */
    uint64_t usable = freeb + (uint64_t)st->count * sizeof(ms_rec_t);
    uint64_t by_space = (usable * 9 / 10) / sizeof(ms_rec_t);
    uint64_t cap = by_space < MS_HARD_CAP ? by_space : MS_HARD_CAP;
    if (cap < MS_RECS_PER_SEG) cap = MS_RECS_PER_SEG;
    st->cap = (uint32_t)cap;
}

/* ---- boot scan --------------------------------------------------------- */

static void sort_segs(msgstore_t *st)
{
    for (int i = 1; i < st->nseg; i++) {         /* insertion sort, n is small */
        ms_seg_t key = st->segs[i];
        int j = i - 1;
        while (j >= 0 && st->segs[j].first_index > key.first_index) {
            st->segs[j + 1] = st->segs[j]; j--;
        }
        st->segs[j + 1] = key;
    }
}

/* Count leading valid records in a segment file (used only for the tail seg). */
static uint16_t scan_seg_count(const msgstore_t *st, uint32_t first_index)
{
    char path[64];
    seg_path(st, path, sizeof path, first_index);
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

static void load_epoch(msgstore_t *st, bool store_empty)
{
    char ep[64];
    epoch_path(st, ep, sizeof ep);
    char e = 0;
    if (!store_empty) {
        FILE *f = fopen(ep, "rb");
        if (f) { if (fread(&e, 1, 1, f) != 1) e = 0; fclose(f); }
    }
    if (e < 'A' || e > 'Z') {                 /* empty store, or missing/bad */
        e = (char)('A' + (esp_random() % 26));
        FILE *f = fopen(ep, "wb");
        if (f) { fwrite(&e, 1, 1, f); fclose(f); }
    }
    st->epoch = e;
}

msgstore_t *msgstore_open(const char *dir)
{
    if (!dir || !dir[0]) return NULL;
    if (!sdcard_is_mounted()) {
        ESP_LOGW(TAG, "no SD card mounted — persistence disabled (%s)", dir);
        return NULL;
    }
    msgstore_t *st = calloc(1, sizeof *st);
    if (!st) return NULL;
    if (strlcpy(st->dir, dir, sizeof st->dir) >= sizeof st->dir) {
        ESP_LOGE(TAG, "dir too long: %s", dir);
        free(st);
        return NULL;
    }
    st->mtx = xSemaphoreCreateMutex();
    if (!st->mtx) { free(st); return NULL; }
    st->active_first = UINT32_MAX;
    st->active_seg = -1;
    strcpy(st->diag, "none");

    mkdir_p(st->dir);

    /* Scan segment files. */
    DIR *d = opendir(st->dir);
    if (d) {
        struct dirent *de;
        while ((de = readdir(d)) != NULL && st->nseg < MS_MAX_SEGMENTS) {
            if (strncmp(de->d_name, "seg_", 4) != 0) continue;
            if (!strstr(de->d_name, ".bin")) continue;
            uint32_t first = (uint32_t)strtoul(de->d_name + 4, NULL, 10);
            if (first % MS_RECS_PER_SEG != 0) continue;
            st->segs[st->nseg].first_index = first;
            st->segs[st->nseg].count = MS_RECS_PER_SEG;  /* refined below */
            st->nseg++;
        }
        closedir(d);
    }
    sort_segs(st);

    st->count = 0;
    if (st->nseg == 0) {
        st->oldest_index = 0;
        st->next_index = 0;
    } else {
        for (int i = 0; i < st->nseg - 1; i++) st->count += st->segs[i].count;
        uint16_t tail = scan_seg_count(st, st->segs[st->nseg - 1].first_index);
        st->segs[st->nseg - 1].count = tail;
        st->count += tail;
        st->oldest_index = st->segs[0].first_index;
        st->next_index = st->segs[st->nseg - 1].first_index + tail;
    }

    recompute_cap(st);
    load_epoch(st, st->count == 0);
    st->ready = true;

    ESP_LOGI(TAG, "%s ready: epoch=%c count=%u next=%u oldest=%u cap=%u segs=%d",
             st->dir, st->epoch, (unsigned)st->count, (unsigned)st->next_index,
             (unsigned)st->oldest_index, (unsigned)st->cap, st->nseg);
    return st;
}

bool msgstore_ready(const msgstore_t *st) { return st && st->ready; }

/* ---- eviction ---------------------------------------------------------- */

/* Delete oldest whole segments until ~10% of cap is freed. Caller holds mutex
 * and must NOT have the to-be-created segment in st->segs yet. */
static void evict_oldest(msgstore_t *st)
{
    uint32_t target = st->cap / 10;
    if (target < MS_RECS_PER_SEG) target = MS_RECS_PER_SEG;
    uint32_t freed = 0;
    while (freed < target && st->nseg > 1) {
        char path[64];
        seg_path(st, path, sizeof path, st->segs[0].first_index);
        sdcard_delete_file(path);
        freed += st->segs[0].count;
        if (st->count >= st->segs[0].count) st->count -= st->segs[0].count; else st->count = 0;
        memmove(&st->segs[0], &st->segs[1], (size_t)(st->nseg - 1) * sizeof(ms_seg_t));
        st->nseg--;
        st->oldest_index = st->segs[0].first_index;
    }
    ESP_LOGI(TAG, "%s evicted ~%u old records (oldest now %u)",
             st->dir, (unsigned)freed, (unsigned)st->oldest_index);
}

/* ---- add --------------------------------------------------------------- */

const char *msgstore_diag(const msgstore_t *st) { return st ? st->diag : "null"; }

esp_err_t msgstore_add(msgstore_t *st, const char *from, const char *to,
                       const char *text, msgstore_kind_t kind, int rssi,
                       bool outgoing)
{
    if (!st || !st->ready) { return ESP_ERR_INVALID_STATE; }
    if (!from) from = "";
    if (!to) to = "";
    if (!text) text = "";

    /* Content hash (also stored for integrity) and recent-dup check. */
    char hbuf[MSGSTORE_CALL_LEN * 2 + MSGSTORE_TEXT_LEN + 4];
    snprintf(hbuf, sizeof hbuf, "%s\x1f%s\x1f%s", from, to, text);
    uint32_t hash = fnv1a(hbuf);

    xSemaphoreTake(st->mtx, portMAX_DELAY);

    for (int i = 0; i < MS_DEDUP_RING; i++) {
        if (st->dedup[i] == hash) { strcpy(st->diag, "dup"); xSemaphoreGive(st->mtx); return ESP_OK; }
    }

    uint32_t idx = st->next_index;
    uint32_t seg_first = (idx / MS_RECS_PER_SEG) * MS_RECS_PER_SEG;

    if (st->active_fp == NULL || st->active_first != seg_first) {
        if (st->active_fp) { fflush(st->active_fp); fclose(st->active_fp); st->active_fp = NULL; }
        char path[64];
        seg_path(st, path, sizeof path, seg_first);
        int si = find_seg(st, seg_first);
        if (si < 0) {
            /* Brand-new segment: enforce cap, refresh free-space estimate. */
            recompute_cap(st);
            if (st->count >= st->cap) evict_oldest(st);
            st->active_fp = fopen(path, "wb+");
            if (!st->active_fp) { strcpy(st->diag, "fopen_new"); xSemaphoreGive(st->mtx); ESP_LOGW(TAG, "open new seg failed"); return ESP_FAIL; }
            st->segs[st->nseg].first_index = seg_first;
            st->segs[st->nseg].count = 0;
            st->active_seg = st->nseg;
            st->nseg++;
            if (st->count == 0) st->oldest_index = seg_first;
        } else {
            st->active_fp = fopen(path, "rb+");
            if (!st->active_fp) { strcpy(st->diag, "fopen_re"); xSemaphoreGive(st->mtx); ESP_LOGW(TAG, "reopen seg failed"); return ESP_FAIL; }
            st->active_seg = si;
        }
        st->active_first = seg_first;
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
    if (fseek(st->active_fp, off, SEEK_SET) != 0 ||
        fwrite(&r, sizeof r, 1, st->active_fp) != 1) {
        strcpy(st->diag, "write");
        xSemaphoreGive(st->mtx);
        ESP_LOGW(TAG, "write failed at index %u", (unsigned)idx);
        return ESP_FAIL;
    }

    st->segs[st->active_seg].count = (uint16_t)((idx % MS_RECS_PER_SEG) + 1);
    st->next_index = idx + 1;
    st->count++;
    st->dedup[st->dedup_pos] = hash;
    st->dedup_pos = (st->dedup_pos + 1) % MS_DEDUP_RING;

    if (++st->since_sync >= MS_FSYNC_EVERY) {
        fflush(st->active_fp);
        fsync(fileno(st->active_fp));
        st->since_sync = 0;
    }

    strcpy(st->diag, "ok");
    xSemaphoreGive(st->mtx);
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

size_t msgstore_query(msgstore_t *st, const msgstore_query_t *q,
                      msgstore_emit_cb_t cb, void *ctx,
                      uint32_t *out_next, bool *out_more)
{
    uint32_t next = q ? q->since_index : 0;
    bool more = false;
    size_t matched = 0;
    if (!st || !st->ready || !q) { if (out_next) *out_next = next; if (out_more) *out_more = false; return 0; }

    uint32_t limit = q->limit ? q->limit : MS_DEFAULT_LIMIT;
    if (limit > MS_MAX_LIMIT) limit = MS_MAX_LIMIT;

    char nfilter[MSGSTORE_CALL_LEN] = {0};
    bool use_call = q->call_filter && q->call_filter[0];
    if (use_call) norm_call(nfilter, sizeof nfilter, q->call_filter);

    xSemaphoreTake(st->mtx, portMAX_DELAY);
    /* Make the latest writes visible to the separate read handles below. fflush
     * pushes the stdio buffer into FATFS; fsync commits the dirty sectors AND the
     * directory-entry size — without it a freshly fopen("rb") read sees the old
     * (often zero) file size and hits EOF before the newest records. */
    if (st->active_fp) { fflush(st->active_fp); fsync(fileno(st->active_fp)); }

    if (st->count == 0) { xSemaphoreGive(st->mtx); if (out_next) *out_next = next; if (out_more) *out_more = false; return 0; }

    /* `since_index` is INCLUSIVE: return records with index >= since_index. The
     * cursor handed back (out_next) is last_emitted+1, so a follow-up poll with
     * since=that returns strictly newer records. Inclusive semantics are required
     * so index 0 (the very first record) is reachable via since=0. */
    uint32_t start = q->since_index;
    if (start < st->oldest_index) start = st->oldest_index;

    for (int si = 0; si < st->nseg && !more; si++) {
        uint32_t sf = st->segs[si].first_index;
        uint32_t sc = st->segs[si].count;
        if (sc == 0) continue;
        if (sf + sc - 1 < start) continue;       /* whole segment below start */

        char path[64];
        seg_path(st, path, sizeof path, sf);
        FILE *f = fopen(path, "rb");
        if (!f) continue;

        uint32_t i0 = (start > sf) ? (start - sf) : 0;
        if (i0) fseek(f, (long)i0 * (long)sizeof(ms_rec_t), SEEK_SET);

        ms_rec_t r;
        for (uint32_t i = i0; i < sc; i++) {
            if (fread(&r, sizeof r, 1, f) != 1) break;
            if (r.magic != MS_MAGIC) continue;
            if (r.index < q->since_index) continue;
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
            next = r.index + 1;        /* cursor = one past last emitted */
        }
        fclose(f);
    }
done:
    xSemaphoreGive(st->mtx);
    if (out_next) *out_next = next;
    if (out_more) *out_more = more;
    return matched;
}

/* ---- accessors --------------------------------------------------------- */

uint32_t msgstore_get_latest_index(const msgstore_t *st)
{
    if (!st) return 0;
    return st->next_index ? st->next_index - 1 : 0;
}

char msgstore_get_epoch(const msgstore_t *st) { return (st && st->ready) ? st->epoch : '?'; }

uint32_t msgstore_get_count(const msgstore_t *st) { return st ? st->count : 0; }

void msgstore_get_stats(const msgstore_t *st, msgstore_stats_t *out)
{
    if (!out) return;
    memset(out, 0, sizeof *out);
    if (!st || !st->ready) { out->epoch = '?'; return; }
    xSemaphoreTake(st->mtx, portMAX_DELAY);
    out->count = st->count;
    out->cap = st->cap;
    out->latest_index = st->next_index ? st->next_index - 1 : 0;
    out->epoch = st->epoch;
    uint64_t total = 0, freeb = 0;
    if (esp_vfs_fat_info(MS_MOUNT, &total, &freeb) == ESP_OK) {
        out->total_bytes = total; out->free_bytes = freeb;
    }
    xSemaphoreGive(st->mtx);
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
    uint32_t last_fit;    /* cursor: one past last record that fit */
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
    c->last_fit = r->index + 1;     /* cursor = one past last record that fit */
    return true;
}

size_t msgstore_build_json(msgstore_t *st, char *buf, size_t size,
                           const msgstore_query_t *q)
{
    if (!buf || size < 128 || !q) return 0;
    char epoch = msgstore_get_epoch(st);
    uint32_t latest = msgstore_get_latest_index(st);

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
    size_t matched = msgstore_query(st, q, json_emit_cb, &c, &qnext, &qmore);

    uint32_t next = c.full ? c.last_fit : qnext;
    bool more = qmore || c.full;

    int n = snprintf(buf + c.len, size - c.len,
        "],\"next\":\"%c%u\",\"more\":%s,\"count\":%u}",
        epoch, (unsigned)next, more ? "true" : "false", (unsigned)matched);
    if (n > 0) c.len += (size_t)n;
    return c.len;
}
