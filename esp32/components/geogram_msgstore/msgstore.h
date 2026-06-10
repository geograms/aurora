/**
 * @file msgstore.h
 * @brief Persistent, queryable APRS message log on microSD (index-based).
 *
 * The iGate persists every APRS message it observes to the SD card and lets
 * other devices (the Aurora app, other ESP32s) fetch "messages since index N",
 * optionally filtered by callsign or message kind. The ESP32 has no reliable
 * wall clock, so ordering/resume is by a MONOTONIC INDEX, not timestamps.
 *
 * A per-store EPOCH letter (A-Z) lets clients detect when the index resets
 * (card wiped/reformatted) and re-sync from 0 — same convention as the in-RAM
 * geogram_aprs store (aprs_store_parse_id "K5").
 *
 * On-disk layout: fixed 192-byte records in segment files under /sdcard/aprs/,
 * each segment holding MSGSTORE_RECS_PER_SEGMENT records. Filenames encode the
 * segment's first index, so eviction of the oldest messages is just deleting
 * the oldest segment file(s).
 */

#ifndef GEOGRAM_MSGSTORE_H
#define GEOGRAM_MSGSTORE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define MSGSTORE_CALL_LEN   10   /* callsign field (incl. NUL); matches APRS store */
#define MSGSTORE_TEXT_LEN   156  /* APRS text body cap (incl. NUL); longer truncated.
                                  * (Was 160; trimmed by 4 to fit the record `ts`
                                  * while keeping the on-disk record 192 bytes —
                                  * APRS messages are <=67 chars, so no real loss.
                                  * `ts` sits AFTER text, so records written by the
                                  * old build still read correctly with ts==0.) */

/** Message kind, derived from the APRS `to` field. */
typedef enum {
    MSGSTORE_KIND_OTHER    = 0,
    MSGSTORE_KIND_POSITION = 1,  /* to == "!", text == "lat,lon[,comment]" */
    MSGSTORE_KIND_MESSAGE  = 2,  /* to == a callsign (direct message)      */
    MSGSTORE_KIND_GROUP    = 3,  /* to starts with '#'                     */
    MSGSTORE_KIND_GEOCHAT  = 4,  /* to == "" (geo-chat / area broadcast)   */
} msgstore_kind_t;

/** One record returned by a query. */
typedef struct {
    uint32_t index;
    uint8_t  kind;
    int8_t   rssi;            /* dBm, 0 if unknown (e.g. from APRS-IS) */
    bool     outgoing;
    char     from[MSGSTORE_CALL_LEN];
    char     to[MSGSTORE_CALL_LEN];
    char     text[MSGSTORE_TEXT_LEN];
    uint32_t ts;              /* wall-clock epoch when stored, 0 if clock unsynced */
} msgstore_query_rec_t;

/** Query parameters. */
typedef struct {
    uint32_t    since_index;  /* return records with index > since_index */
    const char *call_filter;  /* NULL/"" = any; matches `from` OR `to` (case-insensitive, SSID-stripped) */
    int         kind_filter;  /* -1 = any; else a msgstore_kind_t value */
    uint32_t    limit;        /* max records to emit (0 = a sensible default) */
    uint32_t    since_ts;     /* 0 = any; else only records with ts >= since_ts
                               * (records with ts==0 — stored before the clock
                               * synced — are excluded when since_ts > 0) */
} msgstore_query_t;

/** Store statistics. */
typedef struct {
    uint32_t count;        /* records currently on disk */
    uint32_t cap;          /* current capacity (records) */
    uint32_t latest_index; /* highest stored index (0 if empty) */
    uint64_t total_bytes;  /* card total bytes */
    uint64_t free_bytes;   /* card free bytes */
    char     epoch;        /* current epoch letter */
} msgstore_stats_t;

/**
 * Per-record emit callback for streaming queries. Return false to stop early.
 */
typedef bool (*msgstore_emit_cb_t)(const msgstore_query_rec_t *rec, void *ctx);

/** Opaque store instance. Multiple independent stores can coexist on one card
 *  (e.g. one for messages, one for position beacons), each in its own directory
 *  with its own monotonic index, epoch and eviction. */
typedef struct msgstore_s msgstore_t;

/**
 * @brief Open (create + scan) a store rooted at @p dir on the mounted SD card.
 *        The SD card must already be mounted (sdcard_init()). Scans @p dir,
 *        recovers the next index and epoch, and computes capacity from free
 *        space. Each distinct @p dir is an independent store.
 * @return store handle, or NULL if no SD card / out of memory.
 */
msgstore_t *msgstore_open(const char *dir);

/** @brief True if @p st is a valid, ready store. */
bool msgstore_ready(const msgstore_t *st);

/**
 * @brief Append one observed message (deduped by content hash within a short
 *        window). Assigns the next monotonic index. No-op if @p st is NULL.
 * @param st       store handle
 * @param from     sender callsign
 * @param to       APRS `to` field ("", callsign, "#grp", or "!")
 * @param text     message body (or "lat,lon[,comment]" for positions)
 * @param kind     message kind (see msgstore_kind_t)
 * @param rssi     dBm or 0 if unknown
 * @param outgoing true if this device originated/relayed it
 */
esp_err_t msgstore_add(msgstore_t *st, const char *from, const char *to,
                       const char *text, msgstore_kind_t kind, int rssi,
                       bool outgoing);

/**
 * @brief Stream matching records to @p cb in ascending index order.
 * @param st       store handle
 * @param q        query parameters
 * @param cb       per-record callback (NULL just counts)
 * @param ctx      opaque pointer passed to cb
 * @param out_next [out] resume cursor: last emitted index + 1 (or since_index if
 *                 none). Pass to the next query as since_index.
 * @param out_more [out] true if more matches exist beyond @p limit
 * @return number of records emitted
 */
size_t msgstore_query(msgstore_t *st, const msgstore_query_t *q,
                      msgstore_emit_cb_t cb, void *ctx,
                      uint32_t *out_next, bool *out_more);

/** @brief Highest stored index (0 if empty). */
uint32_t msgstore_get_latest_index(const msgstore_t *st);

/** @brief Current epoch letter (A-Z), or '?' if not ready. */
char msgstore_get_epoch(const msgstore_t *st);

/** @brief Number of records currently stored. */
uint32_t msgstore_get_count(const msgstore_t *st);

/** @brief Last msgstore_add() outcome marker (diagnostic): "ok", "dup",
 *  "fopen_new", "fopen_re", "write", "notready", or "none". */
const char *msgstore_diag(const msgstore_t *st);

/** @brief Fill @p out with store/card statistics. */
void msgstore_get_stats(const msgstore_t *st, msgstore_stats_t *out);

/**
 * @brief Map an APRS `to` field to a message kind.
 */
msgstore_kind_t msgstore_kind_from_to(const char *to);

/**
 * @brief Build a JSON page for HTTP: runs the query and serialises the result as
 *        {"epoch","latest_index","count","next","more","messages":[...]}.
 * @return number of bytes written (excluding NUL), 0 on error.
 */
size_t msgstore_build_json(msgstore_t *st, char *buf, size_t size,
                           const msgstore_query_t *q);

#ifdef __cplusplus
}
#endif

#endif /* GEOGRAM_MSGSTORE_H */
