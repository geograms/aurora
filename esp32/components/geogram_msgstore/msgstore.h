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
#define MSGSTORE_TEXT_LEN   160  /* APRS text body cap (incl. NUL); longer truncated */

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
} msgstore_query_rec_t;

/** Query parameters. */
typedef struct {
    uint32_t    since_index;  /* return records with index > since_index */
    const char *call_filter;  /* NULL/"" = any; matches `from` OR `to` (case-insensitive, SSID-stripped) */
    int         kind_filter;  /* -1 = any; else a msgstore_kind_t value */
    uint32_t    limit;        /* max records to emit (0 = a sensible default) */
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

/**
 * @brief Initialise the store. The SD card must already be mounted
 *        (sdcard_init()); this scans /sdcard/aprs, recovers the next index and
 *        epoch, and computes the capacity from free space. Safe to call once.
 * @return ESP_OK if ready; ESP_ERR_INVALID_STATE if no SD card.
 */
esp_err_t msgstore_init(void);

/** @brief True if the store is initialised and backed by a mounted card. */
bool msgstore_ready(void);

/**
 * @brief Append one observed message (deduped by content hash within a short
 *        window). Assigns the next monotonic index. No-op if not ready.
 * @param from     sender callsign
 * @param to       APRS `to` field ("", callsign, "#grp", or "!")
 * @param text     message body (or "lat,lon[,comment]" for positions)
 * @param kind     message kind (see msgstore_kind_t)
 * @param rssi     dBm or 0 if unknown
 * @param outgoing true if this device originated/relayed it
 */
esp_err_t msgstore_add(const char *from, const char *to, const char *text,
                       msgstore_kind_t kind, int rssi, bool outgoing);

/**
 * @brief Stream matching records to @p cb in ascending index order.
 * @param q        query parameters
 * @param cb       per-record callback (NULL just counts)
 * @param ctx      opaque pointer passed to cb
 * @param out_next [out] resume cursor: index of the last emitted record (or
 *                 since_index if none). Pass to the next query as since_index.
 * @param out_more [out] true if more matches exist beyond @p limit
 * @return number of records emitted
 */
size_t msgstore_query(const msgstore_query_t *q, msgstore_emit_cb_t cb, void *ctx,
                      uint32_t *out_next, bool *out_more);

/** @brief Highest stored index (0 if empty). */
uint32_t msgstore_get_latest_index(void);

/** @brief Current epoch letter (A-Z), or '?' if not ready. */
char msgstore_get_epoch(void);

/** @brief Number of records currently stored. */
uint32_t msgstore_get_count(void);

/** @brief Fill @p out with store/card statistics. */
void msgstore_get_stats(msgstore_stats_t *out);

/**
 * @brief Map an APRS `to` field to a message kind.
 */
msgstore_kind_t msgstore_kind_from_to(const char *to);

/**
 * @brief Build a JSON page for HTTP: runs the query and serialises the result as
 *        {"epoch","latest_index","count","next","more","messages":[...]}.
 * @return number of bytes written (excluding NUL), 0 on error.
 */
size_t msgstore_build_json(char *buf, size_t size, const msgstore_query_t *q);

#ifdef __cplusplus
}
#endif

#endif /* GEOGRAM_MSGSTORE_H */
