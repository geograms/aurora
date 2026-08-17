/*
 * The XPRS index — see xprsindex.h for what it is and why it is not SQLite.
 *
 * On disk, under <dir>:
 *   seg_%010u.bin   fixed 320-byte records, XI_RECS_PER_SEG per file
 *   zone.idx        one 16-byte entry per segment, in segment order
 *   t/%02d.idx      per type: 4-byte record numbers, newest last
 *
 * Only the active segment keeps a file handle open. Everything else is opened,
 * used and closed — a FAT mount has a small open-file budget and this component
 * shares it with the rest of the firmware.
 */

#include "xprsindex.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>

#include "xprs.h"

#ifdef XPRSIDX_HOST_TEST
#define XI_LOGI(fmt, ...) ((void)0)
#define XI_LOGW(fmt, ...) ((void)0)
static uint64_t xi_card_total(const char *d) { (void)d; return 0; }
static uint64_t xi_card_free(const char *d) { (void)d; return 0; }
#else
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_vfs_fat.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
static const char *TAG = "xprsidx";
#define XI_LOGI(fmt, ...) ESP_LOGI(TAG, fmt, ##__VA_ARGS__)
#define XI_LOGW(fmt, ...) ESP_LOGW(TAG, fmt, ##__VA_ARGS__)
static uint64_t xi_card_total(const char *d);
static uint64_t xi_card_free(const char *d);
#endif

/* One store, several tasks. The BLE task and the LAN bearer both add records,
 * and the HTTP server and the GATT server both read — all through the same
 * FILE* for the active segment, which FatFs does not make thread-safe. Without
 * this, a query issued while a packet is being written reads a record that is
 * half somebody else's seek. */
#ifdef XPRSIDX_HOST_TEST
#define XI_LOCK(st)    ((void)(st))
#define XI_UNLOCK(st)  ((void)(st))
#else
#define XI_LOCK(st)    do { if ((st)->lock) xSemaphoreTake((st)->lock, portMAX_DELAY); } while (0)
#define XI_UNLOCK(st)  do { if ((st)->lock) xSemaphoreGive((st)->lock); } while (0)
#endif

#define XI_RECS_PER_SEG   4096u
#define XI_DEDUP_RING     32
#define XI_DEFAULT_LIMIT  64
/* Recent segments cached in RAM. The zone file is the real map — an index that
 * kept every segment in memory would cost 384 KB on a full card, which is the
 * whole SRAM budget. */
#define XI_SEG_CACHE      8

/* ── Getting off the radio's back ───────────────────────────────────────── */

/*
 * The card is not allowed on the receive path.
 *
 * A record is 320 bytes and an fsync, and this firmware's own notes say why
 * that matters: "the SDMMC bus desensitises the 2.4 GHz radio". Writing one per
 * heard packet, from the NimBLE host task, cost the WiFi station its ability to
 * transmit — associated, but `wifi:m f null`, DNS timing out, 0 of 90 pings
 * answered. With the writes removed the same firmware never dropped one.
 *
 * So xprsindex_add() still does all the DECIDING on the caller's thread — parse,
 * type, identifier, duplicate — and then hands the finished 320-byte record to a
 * ring that a low-priority task drains. The radio path touches no card, and the
 * writer syncs once per batch instead of once per packet.
 */
#define XI_QUEUE_LEN  8         /* records buffered before the writer runs.
                                 * 8 x 320 B: this board has no PSRAM and the
                                 * HTTP handlers need their allocation more. */

/*
 * How often the card is allowed to be busy at all.
 *
 * Measured on the T-Dongle: with the SD store active the WiFi station stays
 * associated and cannot transmit — `wifi:m f null`, DNS timing out, 1 of 95
 * pings answered. The same firmware with FEATURE_SDCARD=0 and BLE still running
 * answered 159 of 162. The SDMMC bus desensitises the 2.4 GHz radio, which this
 * firmware already knew (see the mount in main.cpp) and which the index made
 * continuous by writing a record per heard packet.
 *
 * A burst every few seconds is fine; a trickle is not. Records wait in RAM and
 * go down together, leaving the bus quiet in between.
 */
/*
 * How often the writer is allowed to touch the card.
 *
 * Two separate things go wrong when it is too eager. It used to write a record
 * per heard packet from the receive path, on core 0 where the radios live, and
 * the WiFi station could not transmit at all (1 of 96 pings). Moving the writes
 * to a task pinned to core 1 fixed that (178 of 182) — but a writer that then
 * wakes ten times a second keeps the FATFS layer busy, and every other reader of
 * the card, including the unrelated APRS archive endpoints, waits behind it.
 *
 * So: records wait in RAM and go down in one burst every couple of seconds,
 * leaving the card free the rest of the time.
 */
#define XI_DRAIN_EVERY_MS  2000

/* ── On-disk shapes ─────────────────────────────────────────────────────── */

typedef struct __attribute__((packed)) {
    uint32_t index;
    uint32_t ts;
    int8_t   rssi;
    uint8_t  flags;
    uint8_t  type;
    uint8_t  _pad;
    uint16_t len;
    char     id[8];
    char     from[XPRSIDX_CALL_LEN];
    char     to[XPRSIDX_CALL_LEN];
    char     wire[XPRSIDX_WIRE_MAX + 1];
    uint8_t  _pad2[15];
} xi_rec_t;
_Static_assert(sizeof(xi_rec_t) == 320, "record must be 320 bytes");

typedef struct __attribute__((packed)) {
    uint32_t first_index;
    uint32_t min_ts;
    uint32_t max_ts;
    uint32_t type_mask;
} xi_zone_t;
_Static_assert(sizeof(xi_zone_t) == 16, "zone entry must be 16 bytes");

struct xprsidx_s {
    char     dir[64];
    bool     ready;
    char     epoch;
    uint32_t next_index;      /* index the next record will take */
    uint32_t count;
    uint32_t nseg;
    FILE    *active_fp;
    uint32_t active_first;
    FILE    *read_fp;         /* scan cursor: one closed segment, held open */
    uint32_t read_first;
    FILE    *tail_fp;         /* the one open type tail (see xi_type_append) */
    int      tail_type;       /* which type it is, -1 = none */
    uint32_t tail_warned;     /* bit per type already complained about */
    xi_zone_t active_zone;    /* the active segment's entry, in RAM */
    uint32_t active_zone_no;
    bool     zone_dirty;
    uint32_t since_flush;     /* adds since the zone entry last hit the card */
    uint32_t dedup[XI_DEDUP_RING];
    int      dedup_pos;
    xprsidx_gate_fn gate;           /* "the radio is idle" — may be NULL */
    xprsidx_verify_cb_t verify;     /* section 9.1, run on the writer task */
    uint32_t verified, unverified, forged;
    volatile bool paused;           /* a reader owns the card right now */
    xi_rec_t queue[XI_QUEUE_LEN];   /* decided, not yet on the card */
    int      q_head, q_count;
    uint32_t q_dropped;
#ifndef XPRSIDX_HOST_TEST
    SemaphoreHandle_t lock;
#endif
};

/* ── Type vocabulary ────────────────────────────────────────────────────── */

static const char *const XI_TYPE_NAME[XI_T__COUNT] = {
    "message", "observation", "receipt", "reaction",
    "request", "identity", "track", "sos",
    "warning", "info", "challenge", "response",
    "blog", "passage", "event", "offer",
    "need", "channel", "mailbox", "service",
    "command", "result", "moderate", "status",
    "place", "poll", "file", "report",
    "ping", "pong",
    "other",
};

const char *xprsidx_type_name(int code)
{
    if (code < 0 || code >= XI_T__COUNT) return "other";
    return XI_TYPE_NAME[code];
}

int xprsidx_type_code(const char *name)
{
    if (!name || !*name) return XI_T_OTHER;
    for (int i = 0; i < XI_T__COUNT; i++) {
        if (strcmp(name, XI_TYPE_NAME[i]) == 0) return i;
    }
    return XI_T_OTHER;
}

/* ── Small helpers ──────────────────────────────────────────────────────── */

static void xi_copy(char *dst, size_t cap, const char *src, int len)
{
    size_t n = 0;
    for (; src && n + 1 < cap && (len < 0 || n < (size_t)len) && src[n]; n++) {
        dst[n] = src[n];
    }
    dst[n] = '\0';
}

static bool xi_ieq(const char *a, const char *b)
{
    if (!a || !b) return false;
    for (; *a && *b; a++, b++) {
        char ca = *a, cb = *b;
        if (ca >= 'a' && ca <= 'z') ca = (char)(ca - 32);
        if (cb >= 'a' && cb <= 'z') cb = (char)(cb - 32);
        if (ca != cb) return false;
    }
    return *a == *b;
}

static void xi_seg_path(const xprsidx_t *st, char *out, size_t cap, uint32_t first)
{
    snprintf(out, cap, "%s/seg_%010u.bin", st->dir, (unsigned)first);
}
static void xi_zone_path(const xprsidx_t *st, char *out, size_t cap)
{
    snprintf(out, cap, "%s/zone.idx", st->dir);
}
static void xi_type_path(const xprsidx_t *st, char *out, size_t cap, int type)
{
    snprintf(out, cap, "%s/t/%02d.idx", st->dir, type);
}

/* `ts:` is `YYYY-MM-DD_hh:mm:ss` (section 4.3). Converted to epoch seconds so a
 * range is an integer comparison rather than string work on every record. */
static uint32_t xi_ts_to_epoch(const char *v, int vlen)
{
    if (!v || vlen < 19) return 0;
    int Y = 0, M = 0, D = 0, h = 0, m = 0, s = 0;
    if (sscanf(v, "%4d-%2d-%2d_%2d:%2d:%2d", &Y, &M, &D, &h, &m, &s) != 6) return 0;
    if (Y < 1970 || M < 1 || M > 12 || D < 1 || D > 31) return 0;
    static const int cum[12] = {0,31,59,90,120,151,181,212,243,273,304,334};
    long days = (long)(Y - 1970) * 365 + ((Y - 1969) / 4) + cum[M - 1] + (D - 1);
    if (M > 2 && ((Y % 4 == 0 && Y % 100 != 0) || Y % 400 == 0)) days++;
    return (uint32_t)(days * 86400L + h * 3600 + m * 60 + s);
}

uint32_t xprsindex_ts_to_epoch(const char *ts, int len)
{
    return xi_ts_to_epoch(ts, len);
}

static uint32_t xi_id_hash(const char id[XPRSIDX_ID_LEN])
{
    uint32_t h = 2166136261u;
    for (int i = 0; i < XPRSIDX_ID_LEN && id[i]; i++) {
        h ^= (uint8_t)id[i];
        h *= 16777619u;
    }
    return h ? h : 1u;
}

/* ── Zone map ───────────────────────────────────────────────────────────── */

static bool xi_zone_read(const xprsidx_t *st, uint32_t n, xi_zone_t *out)
{
    char path[96];
    xi_zone_path(st, path, sizeof path);
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    bool ok = fseek(f, (long)n * (long)sizeof(xi_zone_t), SEEK_SET) == 0 &&
              fread(out, sizeof *out, 1, f) == 1;
    fclose(f);
    return ok;
}

static void xi_zone_write(const xprsidx_t *st, uint32_t n, const xi_zone_t *z)
{
    char path[96];
    xi_zone_path(st, path, sizeof path);
    FILE *f = fopen(path, "r+b");
    if (!f) f = fopen(path, "w+b");
    if (!f) return;
    if (fseek(f, (long)n * (long)sizeof(xi_zone_t), SEEK_SET) == 0) {
        fwrite(z, sizeof *z, 1, f);
    }
    fclose(f);
}

/* The segment a record index belongs to. */
static uint32_t xi_seg_of(uint32_t index) { return (index / XI_RECS_PER_SEG) * XI_RECS_PER_SEG; }
static uint32_t xi_seg_no(uint32_t index) { return index / XI_RECS_PER_SEG; }

/* How many records may go by before the active segment's zone entry is put on
 * the card. Losing it to a power cut costs nothing — it is rebuilt from the
 * segment on the next open — so this is a write-amplification knob, not a
 * durability one. */
#define XI_ZONE_FLUSH_EVERY  64

/* Put the in-RAM entry on the card if it has moved on. */
static void xi_zone_flush(xprsidx_t *st)
{
    if (!st->zone_dirty) return;
    xi_zone_write(st, st->active_zone_no, &st->active_zone);
    st->zone_dirty = false;
    st->since_flush = 0;
}

/* Fold one record into its segment's zone entry, in RAM. Reading and writing
 * zone.idx for every packet was two file opens per record, on a mount where an
 * open is about 10 ms; the entry only has to be correct when somebody reads it,
 * and every reader goes through xi_zone_flush() first. */
static void xi_zone_touch(xprsidx_t *st, const xi_rec_t *r)
{
    uint32_t n = xi_seg_no(r->index);
    if (!st->zone_dirty && st->active_zone.first_index != xi_seg_of(r->index)) {
        /* First touch of this segment in this session: take whatever the card
         * already holds so a reopened segment keeps its earlier window. */
        if (!xi_zone_read(st, n, &st->active_zone) ||
            st->active_zone.first_index != xi_seg_of(r->index)) {
            st->active_zone.first_index = xi_seg_of(r->index);
            st->active_zone.min_ts   = r->ts;
            st->active_zone.max_ts   = r->ts;
            st->active_zone.type_mask = 0;
        }
        st->active_zone_no = n;
    } else if (n != st->active_zone_no) {
        xi_zone_flush(st);                       /* the segment rolled */
        if (!xi_zone_read(st, n, &st->active_zone) ||
            st->active_zone.first_index != xi_seg_of(r->index)) {
            st->active_zone.first_index = xi_seg_of(r->index);
            st->active_zone.min_ts   = r->ts;
            st->active_zone.max_ts   = r->ts;
            st->active_zone.type_mask = 0;
        }
        st->active_zone_no = n;
    }

    if (r->ts) {
        if (!st->active_zone.min_ts || r->ts < st->active_zone.min_ts)
            st->active_zone.min_ts = r->ts;
        if (r->ts > st->active_zone.max_ts) st->active_zone.max_ts = r->ts;
    }
    if (r->type < 32) st->active_zone.type_mask |= (1u << r->type);
    st->zone_dirty = true;
    if (++st->since_flush >= XI_ZONE_FLUSH_EVERY) xi_zone_flush(st);
}

/* ── Type tails ─────────────────────────────────────────────────────────── */

/* One tail file stays open. Traffic arrives in runs of the same type, so this
 * turns the common case into a write with no open at all — and an open on this
 * FAT mount costs about 10 ms, which is most of what an append used to be. */
static void xi_tail_close(xprsidx_t *st)
{
    if (st->tail_fp) { fclose(st->tail_fp); st->tail_fp = NULL; }
    st->tail_type = -1;
}

static void xi_type_append(xprsidx_t *st, int type, uint32_t index)
{
    /* See the reader: 0 cannot be told from a hole, so it is never stored. */
    if (index == 0) return;
    if (st->tail_type != type) {
        xi_tail_close(st);
        char path[96];
        xi_type_path(st, path, sizeof path, type);
        st->tail_fp = fopen(path, "ab");
        if (!st->tail_fp) {
            /* Loud, and only once per type: a tail that never opens means
             * "the most recent N of this type" silently answers nothing, and
             * the store looks healthy while it does. */
            if (!(st->tail_warned & (1u << (type & 31)))) {
                st->tail_warned |= (1u << (type & 31));
                XI_LOGW("cannot open %s (errno %d) — recent-%s queries will be "
                        "empty until the index is rebuilt", path, errno,
                        xprsidx_type_name(type));
            }
            return;
        }
        st->tail_type = type;
    }
    fwrite(&index, sizeof index, 1, st->tail_fp);
}

/* Newest-last, so the most recent N are the last N entries. */
/* Read a window of the tail, [skip_end] entries back from the end. Newest last,
 * as stored. Returns how many were read. */
static uint32_t xi_type_tail(const xprsidx_t *st, int type, uint32_t skip_end,
                             uint32_t want, uint32_t *out, uint32_t cap)
{
    char path[96];
    xi_type_path(st, path, sizeof path, type);
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return 0; }
    long end = ftell(f);
    uint32_t have = (uint32_t)(end / (long)sizeof(uint32_t));
    if (skip_end >= have) { fclose(f); return 0; }
    uint32_t avail = have - skip_end;
    uint32_t take = want < avail ? want : avail;
    if (take > cap) take = cap;
    if (take == 0) { fclose(f); return 0; }
    if (fseek(f, (long)(avail - take) * (long)sizeof(uint32_t), SEEK_SET) != 0) {
        fclose(f);
        return 0;
    }
    uint32_t got = (uint32_t)fread(out, sizeof(uint32_t), take, f);
    fclose(f);
    return got;
}

static bool xi_write_rec(xprsidx_t *st, const xi_rec_t *rec);
static void xi_sync_card(xprsidx_t *st);
#ifndef XPRSIDX_HOST_TEST
static void xi_writer_task(void *arg);
#endif
#ifdef XPRSIDX_HOST_TEST
/* No writer task on the host, so the record goes down immediately and the
 * behaviour a test sees matches the device's once its queue has drained. */
static bool xi_write_rec_fwd(xprsidx_t *st, const xi_rec_t *r)
{
    bool ok = xi_write_rec(st, r);
    xi_sync_card(st);
    return ok;
}
#endif

/* ── Records ────────────────────────────────────────────────────────────── */

static bool xi_read_rec(xprsidx_t *st, uint32_t index, xi_rec_t *out)
{
    long off = (long)(index % XI_RECS_PER_SEG) * (long)sizeof(xi_rec_t);

    /* The active segment is read through the handle that is writing it, never
     * by name. FatFs only updates a file's directory entry on sync or close, so
     * a second fopen() of the segment currently being appended sees the size it
     * had at the last sync — usually zero — and every record just written reads
     * back as nothing. POSIX has no such rule, so a host test cannot catch it;
     * the dongle failed exactly this way. The next write fseek()s to its own
     * offset, so moving the position here is safe. */
    if (st->active_fp && xi_seg_of(index) == st->active_first) {
        fflush(st->active_fp);
        bool ok = fseek(st->active_fp, off, SEEK_SET) == 0 &&
                  fread(out, sizeof *out, 1, st->active_fp) == 1;
        return ok && out->len > 0;
    }

    /* Anything older is read through a cursor that stays open on the segment
     * being scanned. Opening a segment by name costs ~25 ms on this mount — a
     * directory scan — and a range query reads many records from the same file,
     * so re-opening per record made the open the whole cost of the query. */
    uint32_t first = xi_seg_of(index);
    if (!st->read_fp || st->read_first != first) {
        if (st->read_fp) fclose(st->read_fp);
        char path[96];
        xi_seg_path(st, path, sizeof path, first);
        st->read_fp = fopen(path, "rb");
        st->read_first = first;
        if (!st->read_fp) return false;
    }
    bool ok = fseek(st->read_fp, off, SEEK_SET) == 0 &&
              fread(out, sizeof *out, 1, st->read_fp) == 1;
    return ok && out->len > 0;
}

/* Drop the scan cursor — before a segment it might hold becomes the one being
 * written, and on close. */
static void xi_read_close(xprsidx_t *st)
{
    if (st->read_fp) { fclose(st->read_fp); st->read_fp = NULL; }
    st->read_first = 0;
}

static void xi_to_public(const xi_rec_t *in, xprsidx_rec_t *out)
{
    out->index = in->index;
    out->ts    = in->ts;
    out->rssi  = in->rssi;
    out->flags = in->flags;
    out->type  = in->type;
    out->len   = in->len;
    xi_copy(out->id, sizeof out->id, in->id, -1);
    xi_copy(out->from, sizeof out->from, in->from, -1);
    xi_copy(out->to, sizeof out->to, in->to, -1);
    uint16_t n = in->len <= XPRSIDX_WIRE_MAX ? in->len : XPRSIDX_WIRE_MAX;
    memcpy(out->wire, in->wire, n);
    out->wire[n] = '\0';
}

/*
 * The section 36 rule, in one place: mail belongs to two stations and nobody
 * else, however the query was phrased.
 */
static bool xi_may_serve(const xi_rec_t *r, const xprsidx_query_t *q)
{
    if (!(r->flags & XI_F_MAIL)) return true;
    if (!q->asker || !*q->asker) return false;
    return xi_ieq(q->asker, r->to) || xi_ieq(q->asker, r->from);
}

static bool xi_matches(const xi_rec_t *r, const xprsidx_query_t *q)
{
    if (q->type >= 0 && r->type != (uint8_t)q->type) return false;
    if (q->since_ts && (r->ts == 0 || r->ts < q->since_ts)) return false;
    if (q->until_ts && (r->ts == 0 || r->ts > q->until_ts)) return false;
    if (q->from && *q->from && !xi_ieq(q->from, r->from)) return false;
    return xi_may_serve(r, q);
}

/* ── Open / scan ────────────────────────────────────────────────────────── */

static void xi_mkdirs(const xprsidx_t *st)
{
    char path[96];
    mkdir(st->dir, 0777);
    snprintf(path, sizeof path, "%s/t", st->dir);
    mkdir(path, 0777);
}

/* How many records the last segment actually holds (a power cut can leave a
 * short one). Reads back to front and stops at the first written record. */
static uint32_t xi_scan_tail(xprsidx_t *st, uint32_t first)
{
    char path[96];
    xi_seg_path(st, path, sizeof path, first);
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    fseek(f, 0, SEEK_END);
    long end = ftell(f);
    uint32_t slots = (uint32_t)(end / (long)sizeof(xi_rec_t));
    if (slots > XI_RECS_PER_SEG) slots = XI_RECS_PER_SEG;
    uint32_t n = 0;
    xi_rec_t r;
    for (uint32_t i = 0; i < slots; i++) {
        if (fseek(f, (long)i * (long)sizeof(xi_rec_t), SEEK_SET) != 0) break;
        if (fread(&r, sizeof r, 1, f) != 1) break;
        if (r.len == 0) break;
        n = i + 1;
    }
    fclose(f);
    return n;
}

xprsidx_t *xprsindex_open(const char *dir)
{
    if (!dir || !*dir) return NULL;
    xprsidx_t *st = calloc(1, sizeof *st);
    if (!st) return NULL;
    xi_copy(st->dir, sizeof st->dir, dir, -1);
    st->epoch = 'A';
    st->tail_type = -1;
#ifndef XPRSIDX_HOST_TEST
    st->lock = xSemaphoreCreateMutex();
#endif
    xi_mkdirs(st);

    /* Find the highest segment on the card. */
    uint32_t last_first = 0;
    bool any = false;
    DIR *d = opendir(st->dir);
    if (d) {
        struct dirent *de;
        while ((de = readdir(d)) != NULL) {
            if (strncmp(de->d_name, "seg_", 4) != 0) continue;
            uint32_t first = (uint32_t)strtoul(de->d_name + 4, NULL, 10);
            st->nseg++;
            if (!any || first > last_first) { last_first = first; any = true; }
        }
        closedir(d);
    }
    if (any) {
        uint32_t tail = xi_scan_tail(st, last_first);
        st->next_index = last_first + tail;
        st->count = st->next_index;   /* eviction rewrites this below */
    }
    st->ready = true;
#ifndef XPRSIDX_HOST_TEST
    /* Core 1, deliberately. The BLE controller and host are pinned to core 0
     * (CONFIG_BT_NIMBLE_PINNED_TO_CORE 0), WiFi runs there and so does the main
     * task, while core 1 sits nearly idle. SD transactions are long and this is
     * the one job in the firmware with no reason to compete with a radio for
     * the same processor. */
    /* 8 KB. FATFS and the SDMMC driver are not frugal with stack and 3 KB
     * overflowed under a burst of traffic — the dongle rebooted rather than
     * dropped a record — which is where the old 4 KB came from. It now also
     * verifies a signature before each write, and mbedtls_ecp_muladd on
     * secp256k1 wants several kilobytes of its own; a stack overflow here
     * presents as a reboot loop, so this is sized generously on purpose. */
    if (xTaskCreatePinnedToCore(xi_writer_task, "xprsidx_wr", 8192, st, 2, NULL,
                                1) != pdPASS) {
        XI_LOGW("writer task failed to start — nothing will reach the card");
        st->ready = false;
        free(st);
        return NULL;
    }
#endif
    XI_LOGI("open %s: %u records, %u segments", st->dir,
            (unsigned)st->count, (unsigned)st->nseg);
    return st;
}

void xprsindex_close(xprsidx_t *st)
{
    if (!st) return;
    xi_zone_flush(st);
    xi_tail_close(st);
    xi_read_close(st);
    if (st->active_fp) fclose(st->active_fp);
    free(st);
}

bool xprsindex_ready(const xprsidx_t *st) { return st && st->ready; }

uint32_t xprsindex_latest_index(const xprsidx_t *st)
{
    return (st && st->next_index) ? st->next_index - 1 : 0;
}

char xprsindex_epoch(const xprsidx_t *st) { return st ? st->epoch : '?'; }

/* ── Add ────────────────────────────────────────────────────────────────── */

/*
 * Decide what a record's signature says, one packet before it becomes
 * permanent (XPRS.md section 9.1). Returns false when it must not be stored.
 *
 * Called with the lock held, and NEVER from the thread that heard the packet:
 * a verify is a secp256k1 point multiplication, and on the device this runs on
 * the writer task, pinned to core 1, for the same reason the writes do.
 *
 * A FORGED record is dropped. It is the one thing on an open bearer that is
 * evidence of a lie, and an indexer that kept it would hand it to somebody
 * later under the name of the station it impersonates.
 */
static bool xi_judge_rec(xprsidx_t *st, xi_rec_t *r)
{
    if (!(r->flags & XI_F_SIGNED) || !st->verify) return true;
    int v = st->verify(r->wire, r->len, r->from);
    if (v > 0) {
        r->flags |= XI_F_VERIFIED;
        st->verified++;
        return true;
    }
    if (v < 0) {
        st->forged++;
        st->count--;                 /* it was counted when it was accepted */
        XI_LOGW("refused a forged packet in the name of %s", r->from);
        return false;
    }
    st->unverified++;
    return true;
}

/* Hand a finished record to the writer. Called with the lock held. */
static bool xi_queue_rec(xprsidx_t *st, const xi_rec_t *r)
{
#ifdef XPRSIDX_HOST_TEST
    /* The host has no writer task, so the judgement happens here instead — the
     * same call, one thread earlier. */
    xi_rec_t judged = *r;
    if (!xi_judge_rec(st, &judged)) return false;
    return xi_write_rec_fwd(st, &judged);
#else
    if (st->q_count >= XI_QUEUE_LEN) {
        /* The card is slower than the air. Losing the newest is better than
         * blocking the receive path, which is the whole point of the ring. */
        st->q_dropped++;
        if (st->q_dropped == 1 || (st->q_dropped % 100) == 0) {
            XI_LOGW("write queue full — %u records dropped (card too slow)",
                    (unsigned)st->q_dropped);
        }
        return false;
    }
    st->queue[(st->q_head + st->q_count) % XI_QUEUE_LEN] = *r;
    st->q_count++;
    return true;
#endif
}

static bool xi_add_locked(xprsidx_t *st, const char *wire, int len,
                          int rssi, bool outgoing, uint32_t ts_now)
{
    if (!st || !st->ready || !wire || len <= 0) return false;
    if (len > XPRSIDX_WIRE_MAX) return false;
    if (!xprs_looks_like((const uint8_t *)wire, len)) return false;

    xprs_t p;
    if (!xprs_parse(wire, len, &p)) return false;

    char type[16];
    xprs_type(&p, type, sizeof type);
    int code = xprsidx_type_code(type);
    /* A liveness probe is meaningless once it is old (see the header). */
    if (code == XI_T_PING || code == XI_T_PONG) return false;

    xi_rec_t r;
    memset(&r, 0, sizeof r);
    xprs_id_of(wire, len, r.id);

    uint32_t h = xi_id_hash(r.id);
    for (int i = 0; i < XI_DEDUP_RING; i++) {
        if (st->dedup[i] == h) return false;      /* heard again, already kept */
    }

    char buf[XPRSIDX_CALL_LEN];
    if (xprs_get_str(&p, "f", buf, sizeof buf)) xi_copy(r.from, sizeof r.from, buf, -1);
    if (xprs_get_str(&p, "d", buf, sizeof buf)) xi_copy(r.to, sizeof r.to, buf, -1);

    int vlen = 0;
    const char *ts = xprs_get(&p, "ts", &vlen);
    r.ts = ts ? xi_ts_to_epoch(ts, vlen) : 0;
    if (!r.ts) r.ts = ts_now;

    r.index = st->next_index;
    r.rssi  = (int8_t)rssi;
    r.type  = (uint8_t)code;
    r.len   = (uint16_t)len;
    r.flags = 0;
    if (r.to[0]) r.flags |= XI_F_MAIL;
    if (outgoing) r.flags |= XI_F_OUTGOING;
    if (xprs_get(&p, "sig", &vlen)) r.flags |= XI_F_SIGNED;
    memcpy(r.wire, wire, (size_t)len);

    /* Decided. The card work is somebody else's problem now. */
    st->dedup[st->dedup_pos] = h;
    st->dedup_pos = (st->dedup_pos + 1) % XI_DEDUP_RING;
    st->next_index++;
    st->count++;
    return xi_queue_rec(st, &r);
}

/* The half that touches the card. Runs on the writer task (or, on the host,
 * straight from xi_add_locked). The lock is already held. */
static bool xi_write_rec(xprsidx_t *st, const xi_rec_t *rec)
{
    const xi_rec_t r = *rec;
    int code = r.type;

    uint32_t seg_first = xi_seg_of(r.index);
    if (!st->active_fp || st->active_first != seg_first) {
        if (st->active_fp) fclose(st->active_fp);
        if (st->read_fp && st->read_first == seg_first) xi_read_close(st);
        char path[96];
        xi_seg_path(st, path, sizeof path, seg_first);
        st->active_fp = fopen(path, "r+b");
        if (!st->active_fp) {
            st->active_fp = fopen(path, "w+b");
            if (st->active_fp) st->nseg++;
        }
        st->active_first = seg_first;
    }
    if (!st->active_fp) return false;

    long off = (long)(r.index % XI_RECS_PER_SEG) * (long)sizeof(xi_rec_t);
    if (fseek(st->active_fp, off, SEEK_SET) != 0) return false;
    if (fwrite(&r, sizeof r, 1, st->active_fp) != 1) return false;
    fflush(st->active_fp);

    /* Indexes AFTER the record: they are derived, so a power cut between the
     * two leaves them short and rebuildable rather than pointing at nothing. */
    xi_zone_touch(st, &r);
    xi_type_append(st, code, r.index);
    return true;
}

/* fflush only pushes stdio's buffer into FatFs. FatFs writes the file's
 * DIRECTORY ENTRY on sync or close, and nothing closes this handle when the
 * power goes — so without this the whole active segment is invisible after a
 * reboot: the records are on the card, the entry still says the file is empty,
 * and the next open counts none of them. Measured by losing 2000 records to a
 * reset.
 *
 * Once per drained batch rather than once per record: a batch is a fraction of
 * a second of traffic, and per-record it was the SD bus running constantly
 * underneath the radio. */
static void xi_sync_card(xprsidx_t *st)
{
    if (st->active_fp) fsync(fileno(st->active_fp));
    /* The tail needs it for the same reason the segment does: FatFs writes a
     * file's size on sync or close, and appended bytes that never reach the
     * card leave the file LONGER than its contents — the reader then finds
     * zeroes where the newest entries should be, and "the most recent N of this
     * type" answers nothing while the records sit safely in their segment. */
    if (st->tail_fp) { fflush(st->tail_fp); fsync(fileno(st->tail_fp)); }
    xi_zone_flush(st);
}

/* ── Query ──────────────────────────────────────────────────────────────── */

/* "The most recent N of this type" — straight off the type tail. */
/* Entries read per pass, and the most we will look at before giving up. */
#define XI_TAIL_WINDOW   32
#define XI_TAIL_MAX_SCAN 4096

static size_t xi_query_recent_typed(xprsidx_t *st, const xprsidx_query_t *q,
                                    xprsidx_emit_cb_t cb, void *ctx,
                                    uint32_t limit)
{
    uint32_t idx[XI_TAIL_WINDOW];
    size_t emitted = 0;
    uint32_t skip = 0;
    bool stopped = false;
    xi_rec_t r;
    xprsidx_rec_t pub;

    /* Walk the tail backwards a window at a time rather than taking one fixed
     * bite of it. Entries get skipped for ordinary reasons — the record is mail
     * this asker may not see, it falls outside the time range — and for
     * disagreeable ones: a torn tail can end in zeroes that point at record 0.
     * A single fixed window meant a handful of those hid every real answer
     * behind them, and asking for ONE recent warning returned none while asking
     * for three returned three. */
    while (emitted < limit && !stopped && skip < XI_TAIL_MAX_SCAN) {
        uint32_t got = xi_type_tail(st, q->type, skip, XI_TAIL_WINDOW,
                                    idx, XI_TAIL_WINDOW);
        if (got == 0) break;                       /* reached the start */
        for (uint32_t i = got; i > 0 && emitted < limit; i--) {
            uint32_t n = idx[i - 1];
            /* A zero is ambiguous: it is either a pointer to record 0 or the
             * hole a half-synced file leaves behind, and nothing on disk tells
             * the two apart. Treated as a hole — the cost is that the very
             * first record a store ever takes is not in the fast path for its
             * type, and a range query still finds it. */
            if (n == 0) continue;
            if (n >= st->next_index) continue;     /* never written: torn tail */
            if (!xi_read_rec(st, n, &r)) continue;
            if (!xi_matches(&r, q)) continue;
            xi_to_public(&r, &pub);
            emitted++;
            if (cb && !cb(&pub, ctx)) { stopped = true; break; }
        }
        skip += got;
        if (got < XI_TAIL_WINDOW) break;           /* that was the whole file */
    }
    return emitted;
}

/*
 * A time range. Segments are written in time order, so the zone map answers
 * "which segments can possibly contain this range" without opening any of them
 * — and type_mask drops the segments that hold none of the wanted type.
 */
static size_t xi_query_range(xprsidx_t *st, const xprsidx_query_t *q,
                             xprsidx_emit_cb_t cb, void *ctx, uint32_t limit)
{
    uint32_t nseg = st->next_index ? xi_seg_no(st->next_index - 1) + 1 : 0;
    size_t emitted = 0;
    xi_rec_t r;
    xprsidx_rec_t pub;

    for (uint32_t s = 0; s < nseg && emitted < limit; s++) {
        uint32_t sn = q->newest_first ? (nseg - 1 - s) : s;
        xi_zone_t z;
        if (xi_zone_read(st, sn, &z) && z.first_index == sn * XI_RECS_PER_SEG) {
            /* Skip whole segments the range or the type cannot be in. */
            if (q->until_ts && z.min_ts && z.min_ts > q->until_ts) continue;
            if (q->since_ts && z.max_ts && z.max_ts < q->since_ts) continue;
            if (q->type >= 0 && q->type < 32 && z.type_mask &&
                !(z.type_mask & (1u << q->type))) {
                continue;
            }
        }
        uint32_t first = sn * XI_RECS_PER_SEG;
        uint32_t last  = first + XI_RECS_PER_SEG - 1;
        if (last >= st->next_index) last = st->next_index ? st->next_index - 1 : 0;
        for (uint32_t k = 0; k <= last - first && emitted < limit; k++) {
            uint32_t i = q->newest_first ? (last - k) : (first + k);
            if (!xi_read_rec(st, i, &r)) continue;
            if (!xi_matches(&r, q)) continue;
            xi_to_public(&r, &pub);
            emitted++;
            if (cb && !cb(&pub, ctx)) return emitted;
        }
    }
    return emitted;
}

/* Everything a reader looks at, on the card. The write path keeps the zone
 * entry in RAM and the tail in a stdio buffer; a query is rare and this is what
 * makes that safe. */
static void xi_sync(xprsidx_t *st)
{
    xi_zone_flush(st);
    /* Closed, not flushed: the tail is read back by name, and by the same FatFs
     * rule as xi_read_rec() a name lookup sees the size from the last close. It
     * reopens on the next packet of that type. */
    xi_tail_close(st);
    if (st->active_fp) fflush(st->active_fp);
}

static size_t xi_query_locked(xprsidx_t *st, const xprsidx_query_t *q,
                              xprsidx_emit_cb_t cb, void *ctx)
{
    if (!st || !st->ready || !q) return 0;
    xi_sync(st);
    uint32_t limit = q->limit ? q->limit : XI_DEFAULT_LIMIT;

    /* The "most recent warnings" shape: a typed newest-first query never walks
     * segments, however big the card is. */
    if (q->newest_first && q->type >= 0 && q->type < XI_T__COUNT) {
        return xi_query_recent_typed(st, q, cb, ctx, limit);
    }
    return xi_query_range(st, q, cb, ctx, limit);
}

#ifdef XPRSIDX_BENCH
/* Fill the store with synthetic traffic spread over two years and time the two
 * questions this design exists to answer. Compiled ONLY under -DXPRSIDX_BENCH,
 * so it costs the shipped firmware nothing; it is here rather than in a test
 * because the number that matters is SD I/O on the device, which no host can
 * stand in for. See the header for why these two queries and not others. */
static bool xi_bench_sink(const xprsidx_rec_t *r, void *ctx)
{
    (void)r;
    (*(uint32_t *)ctx)++;
    return true;
}

void xprsindex_bench(xprsidx_t *st, uint32_t n)
{
    if (!st || !st->ready) { XI_LOGW("bench: no store"); return; }

    /* 2024-08-13 09:00:00 UTC, walking forward ~2 years across n records. */
    const uint32_t t0 = 1723539600u;
    const uint32_t step = (63072000u / (n ? n : 1));
    char w[XPRSIDX_WIRE_MAX + 1];
    char ts[24];

    int64_t a0 = esp_timer_get_time();
    uint32_t wrote = 0;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t t = t0 + i * step;
        /* Cheap epoch -> the ts: shape, good enough to be parsed back. */
        uint32_t days = t / 86400u, rem = t % 86400u;
        uint32_t y = 1970, d = days;
        for (;;) {
            uint32_t len = ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) ? 366 : 365;
            if (d < len) break;
            d -= len; y++;
        }
        snprintf(ts, sizeof ts, "%04u-%02u-%02u_%02u:%02u:%02u",
                 (unsigned)y, (unsigned)(d / 31 + 1), (unsigned)(d % 31 + 1),
                 (unsigned)(rem / 3600), (unsigned)((rem / 60) % 60),
                 (unsigned)(rem % 60));
        /* One warning in every fifty; the rest is the ordinary mix. */
        int len = (i % 50 == 0)
            ? snprintf(w, sizeof w, "t:warning f:X3B%04u pos:39.40,-8.20 "
                                    "kind:fire sev:danger ts:%s", (unsigned)i, ts)
            : snprintf(w, sizeof w, "t:observation f:X1B%04u link:ble peers:%u "
                                    "ts:%s", (unsigned)i, (unsigned)(i % 30), ts);
        if (xprsindex_add(st, w, len, -60, false, 0)) wrote++;
    }
    int64_t a1 = esp_timer_get_time();
    XI_LOGW("bench: wrote %u/%u records in %lld ms (%lld us each)",
            (unsigned)wrote, (unsigned)n, (a1 - a0) / 1000,
            wrote ? (a1 - a0) / wrote : 0);

    /* What the warning tail actually holds, and what those records actually
     * are — the two halves of "the tail answered nothing". */
    {
        uint32_t idx[8];
        xi_sync(st);
        uint32_t got = xi_type_tail(st, XI_T_WARNING, 0, 8, idx, 8);
        XI_LOGW("bench: warning tail holds %u of the last 8", (unsigned)got);
        for (uint32_t i = 0; i < got; i++) {
            xi_rec_t r;
            bool ok = xi_read_rec(st, idx[i], &r);
            XI_LOGW("bench:   tail[%u]=%u read=%d type=%s len=%u from=%s",
                    (unsigned)i, (unsigned)idx[i], (int)ok,
                    ok ? xprsidx_type_name(r.type) : "?",
                    ok ? (unsigned)r.len : 0u, ok ? r.from : "?");
        }
    }

    uint32_t seen = 0;
    xprsidx_query_t q1 = { .type = XI_T_WARNING, .newest_first = true, .limit = 20 };
    int64_t b0 = esp_timer_get_time();
    size_t n1 = xprsindex_query(st, &q1, xi_bench_sink, &seen);
    int64_t b1 = esp_timer_get_time();
    XI_LOGW("bench: 20 most recent warnings -> %u in %lld us",
            (unsigned)n1, b1 - b0);

    /* "What was sent last year": the 365 days ending a year ago. */
    seen = 0;
    xprsidx_query_t q2 = { .since_ts = t0, .until_ts = t0 + 31536000u,
                           .type = -1, .limit = 50 };
    int64_t c0 = esp_timer_get_time();
    size_t n2 = xprsindex_query(st, &q2, xi_bench_sink, &seen);
    int64_t c1 = esp_timer_get_time();
    XI_LOGW("bench: 50 from the year to %u -> %u in %lld us",
            (unsigned)(t0 + 31536000u), (unsigned)n2, c1 - c0);

    xprsidx_stats_t s;
    xprsindex_stats(st, &s);
    XI_LOGW("bench: store now %u records, %u segments, %llu bytes free",
            (unsigned)s.count, (unsigned)s.segments,
            (unsigned long long)s.free_bytes);
}
#endif /* XPRSIDX_BENCH */

#ifndef XPRSIDX_HOST_TEST
/*
 * The only task that touches the card for writing. Low priority on purpose:
 * everything else — the radios, the BLE host, the web server — matters more
 * than how soon a record is durable, and a full ring is a bounded loss whereas
 * a busy SD bus is a station nobody can reach.
 */
static void xi_writer_task(void *arg)
{
    xprsidx_t *st = (xprsidx_t *)arg;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(XI_DRAIN_EVERY_MS));
        if (st->paused) continue;         /* a reader has the card */

        int n = 0;
        for (;;) {
            /* ONE record per lock, never a whole drain.
             *
             * The HTTP server has a single worker task, so a handler that
             * blocks on this mutex takes down every endpoint on the device, not
             * just its own — which is exactly what holding it across a batch of
             * SD writes did. A reader now waits for one record at most, and for
             * nothing at all once it has asked for the pause below. */
            XI_LOCK(st);
            if (st->paused || st->q_count == 0) { XI_UNLOCK(st); break; }
            if (st->gate && !st->gate()) { XI_UNLOCK(st); break; }
            xi_rec_t rec = st->queue[st->q_head];
            st->q_head = (st->q_head + 1) % XI_QUEUE_LEN;
            st->q_count--;

            /* The queue exists to move work off the thread that heard the
             * packet; judging authorship is more of the same work, and the
             * record is about to be written by this task anyway. */
            if (xi_judge_rec(st, &rec)) {
                xi_write_rec(st, &rec);
                n++;
            }
            XI_UNLOCK(st);
        }
        if (n) {
            XI_LOCK(st);
            xi_sync_card(st);
            XI_UNLOCK(st);
        }
    }
}
#endif

/* The public entry points hold the lock; everything below them assumes it. */
bool xprsindex_add(xprsidx_t *st, const char *wire, int len,
                   int rssi, bool outgoing, uint32_t ts_now)
{
    if (!st) return false;
    XI_LOCK(st);
    bool ok = xi_add_locked(st, wire, len, rssi, outgoing, ts_now);
    XI_UNLOCK(st);
    return ok;
}

size_t xprsindex_query(xprsidx_t *st, const xprsidx_query_t *q,
                       xprsidx_emit_cb_t cb, void *ctx)
{
    if (!st) return 0;
    XI_LOCK(st);
    size_t n = xi_query_locked(st, q, cb, ctx);
    XI_UNLOCK(st);
    return n;
}

/* ── The directory (XPRS.md §36.9) ──────────────────────────────────────── */

/* Insertion sort by callsign, keeping the newest ts per station. The list is
 * small — an indexer with more archived callsigns than this has outgrown a
 * dongle — and staying sorted as we go is what lets a peer diff two
 * directories by reading them straight through. */
static void xi_dir_put(xprsidx_dir_entry_t *out, int *n, int max,
                       const char *call, uint32_t ts)
{
    if (!call || !call[0]) return;
    int i = 0;
    for (; i < *n; i++) {
        int cmp = strcmp(out[i].call, call);
        if (cmp == 0) {
            if (ts > out[i].last_ts) out[i].last_ts = ts;   /* keep the newest */
            return;
        }
        if (cmp > 0) break;                                  /* insert here */
    }
    if (*n >= max) return;               /* full: the tail is simply not listed */
    for (int k = *n; k > i; k--) out[k] = out[k - 1];
    snprintf(out[i].call, sizeof out[i].call, "%s", call);
    out[i].last_ts = ts;
    (*n)++;
}

int xprsindex_directory(xprsidx_t *st, xprsidx_dir_entry_t *out, int max)
{
    if (!st || !st->ready || !out || max <= 0) return 0;
    XI_LOCK(st);
    xi_sync(st);

    int n = 0;
    xi_rec_t r;
    for (uint32_t i = 0; i < st->next_index; i++) {
        if (!xi_read_rec(st, i, &r)) continue;
        /* Mail is listed by its SENDER only. Naming the addressee would tell a
         * peer who receives mail here, which is the envelope §36.7 keeps. */
        xi_dir_put(out, &n, max, r.from, r.ts);
    }
    XI_UNLOCK(st);
    return n;
}

int xprsindex_dir_render(const xprsidx_dir_entry_t *entries, int n,
                         char *out, size_t cap)
{
    if (!out || cap < 8) return -1;
    size_t len = 0;
    int w = snprintf(out, cap, "XDIR1\n");
    if (w < 0 || (size_t)w >= cap) return -1;
    len = (size_t)w;
    for (int i = 0; i < n && entries; i++) {
        /* `call ts` — the two value types the format already has (§4.3), so a
         * reader needs no new parser for a directory. */
        char ts[24] = "-";
        if (entries[i].last_ts) {
            uint32_t t = entries[i].last_ts;
            uint32_t days = t / 86400u, rem = t % 86400u, y = 1970, d = days;
            for (;;) {
                uint32_t l = ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) ? 366 : 365;
                if (d < l) break;
                d -= l; y++;
            }
            static const int cum[12] = {0,31,59,90,120,151,181,212,243,273,304,334};
            bool leap = ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0);
            int mon = 11;
            for (int m = 0; m < 12; m++) {
                int start = cum[m] + ((leap && m >= 2) ? 1 : 0);
                if ((int)d < start) { mon = m - 1; break; }
            }
            int mstart = cum[mon] + ((leap && mon >= 2) ? 1 : 0);
            snprintf(ts, sizeof ts, "%04u-%02u-%02u_%02u:%02u:%02u",
                     (unsigned)y, (unsigned)(mon + 1), (unsigned)(d - mstart + 1),
                     (unsigned)(rem / 3600), (unsigned)((rem / 60) % 60),
                     (unsigned)(rem % 60));
        }
        w = snprintf(out + len, cap - len, "%s %s\n", entries[i].call, ts);
        if (w < 0 || (size_t)w >= cap - len) return -1;
        len += (size_t)w;
    }
    return (int)len;
}

void xprsindex_set_gate(xprsidx_t *st, xprsidx_gate_fn gate)
{
    if (st) st->gate = gate;
}

void xprsindex_pause_writes(xprsidx_t *st, bool paused)
{
    if (!st) return;
    st->paused = paused;
    if (!paused) return;
    /* Take and release the lock once: when this returns, the writer is not
     * inside a record, so the caller has the card to itself. */
    XI_LOCK(st);
    XI_UNLOCK(st);
}

void xprsindex_queue_stats(xprsidx_t *st, uint32_t *out_waiting,
                           uint32_t *out_dropped)
{
    if (out_waiting) *out_waiting = st ? (uint32_t)st->q_count : 0;
    if (out_dropped) *out_dropped = st ? st->q_dropped : 0;
}

bool xprsindex_get(xprsidx_t *st, uint32_t index, xprsidx_rec_t *out)
{
    if (!st || !out) return false;
    /* Under the lock like every other reader. `xi_read_rec` reaches through
     * `active_fp` — the handle the writer task is appending with — and FatFs
     * makes no promise about two tasks seeking one FILE*: without this, a read
     * issued while a packet is being written returns a record that is half
     * somebody else's seek, and moves the writer's file position under it. */
    XI_LOCK(st);
    bool ok = false;
    if (index < st->next_index) {
        xi_rec_t r;
        if (xi_read_rec(st, index, &r)) {
            xi_to_public(&r, out);
            ok = true;
        }
    }
    XI_UNLOCK(st);
    return ok;
}

void xprsindex_set_verifier(xprsidx_t *st, xprsidx_verify_cb_t cb)
{
    if (!st) return;
    XI_LOCK(st);
    st->verify = cb;
    XI_UNLOCK(st);
}

void xprsindex_stats(xprsidx_t *st, xprsidx_stats_t *out)
{
    if (!out) return;
    memset(out, 0, sizeof *out);
    if (!st) { out->epoch = '?'; return; }
    out->count        = st->count;
    out->latest_index = xprsindex_latest_index(st);
    out->segments     = st->nseg;
    out->epoch        = st->epoch;
    out->total_bytes  = xi_card_total(st->dir);
    out->free_bytes   = xi_card_free(st->dir);
    out->verified     = st->verified;
    out->unverified   = st->unverified;
    out->forged       = st->forged;
}

#ifndef XPRSIDX_HOST_TEST
/* esp_vfs_fat_info() wants the MOUNT POINT ("/sdcard"), not the store's own
 * directory below it, and returns ESP_ERR_INVALID_STATE for anything deeper. */
static void xi_mount_of(const char *d, char *out, size_t cap)
{
    size_t n = 0;
    if (d && *d == '/') {
        for (n = 1; n + 1 < cap && d[n] && d[n] != '/'; n++) out[n] = d[n];
        out[0] = '/';
    }
    out[n] = '\0';
}

static uint64_t xi_card_total(const char *d)
{
    char mnt[32]; xi_mount_of(d, mnt, sizeof mnt);
    uint64_t tot = 0, fre = 0;
    if (esp_vfs_fat_info(mnt, &tot, &fre) != ESP_OK) return 0;
    return tot;
}
static uint64_t xi_card_free(const char *d)
{
    char mnt[32]; xi_mount_of(d, mnt, sizeof mnt);
    uint64_t tot = 0, fre = 0;
    if (esp_vfs_fat_info(mnt, &tot, &fre) != ESP_OK) return 0;
    return fre;
}
#endif
