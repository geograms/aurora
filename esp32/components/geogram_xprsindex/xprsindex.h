/**
 * @file xprsindex.h
 * @brief Every XPRS packet this station hears, kept on microSD and answerable.
 *
 * docs/XPRS.md section 36: an indexer is handed the packet itself, verbatim and
 * signed, and answers questions about it. This is that store for the T-Dongle.
 *
 * ── Why not msgstore, and why not SQLite ────────────────────────────────────
 *
 * `geogram_msgstore` has the segment discipline this borrows — append-only
 * records in seg_<first>.bin, a monotonic index, an epoch letter so a client
 * detects a wiped card and re-syncs, eviction by deleting the oldest segment.
 * That part is proven and is copied deliberately. What does not fit is its
 * RECORD: an APRS shape (from/to/text, kind derived from the APRS `to`) whose
 * 156-byte text field cannot hold a 250-byte XPRS packet at all, and whose
 * clients depend on the layout. So the iGate keeps its store and this is a
 * second one, in its own directory, with its own index and epoch.
 *
 * SQLite was the first choice and does not fit the hardware: the app binary is
 * 1,848,576 B in a 1,966,080 B partition (6% headroom) and this build has no
 * PSRAM, so a page cache would come out of the SRAM already shared with BLE,
 * WiFi and LVGL. Instead there are two small indexes, below, that answer the
 * questions actually asked in time proportional to the ANSWER rather than to
 * the store.
 *
 * ── What makes the two hard questions fast ──────────────────────────────────
 *
 * "The most recent warnings" — a tail index per type, `t/<code>.idx`, holding
 * 4-byte record numbers with the newest last. Twenty warnings is a seek to the
 * end, an 80-byte read and twenty direct record reads. It never grows with the
 * size of the store.
 *
 * "What was sent last year" — a zone map, `zone.idx`, one 16-byte entry per
 * segment: {first_index, min_ts, max_ts, type_mask}. Segments are written in
 * time order, so a range binary-searches the file by seeking rather than
 * loading it, and then opens only the segments whose window overlaps. The
 * type_mask lets a typed range skip a segment holding none of that type.
 *
 * Both are DERIVED. If either is missing or was truncated by a power cut it is
 * rebuilt by walking the segments; the segments are the source of truth and the
 * store is readable without either index.
 *
 * ── What may be served ──────────────────────────────────────────────────────
 *
 * The station hears everyone, so section 36 draws a line this file enforces:
 *
 *   - no `d:`, and a publication type -> queryable by anybody
 *   - carries `d:` -> MAIL. Stored, held for that station, and never emitted to
 *     a third party. Storing a stranger's sealed message is fine (section 9.2
 *     seals the body); handing it to whoever asks is not.
 *   - ping/pong -> not stored at all; a stale liveness probe answers a question
 *     nobody is still asking.
 */

#ifndef GEOGRAM_XPRSINDEX_H
#define GEOGRAM_XPRSINDEX_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Longest XPRS packet (docs/XPRS.md section 4). */
#define XPRSIDX_WIRE_MAX  250
/** Identifier: 6 lowercase hex + NUL (section 5). */
#define XPRSIDX_ID_LEN    7
/** Callsign field, long enough for a suffixed one (section 3.1). */
#define XPRSIDX_CALL_LEN  16

/**
 * Packet type codes. The order is the assigned list in section 4, so a code is
 * stable on disk; the mask in a zone entry is a bit per code, which is why the
 * count must stay under 32.
 */
typedef enum {
    XI_T_MESSAGE = 0, XI_T_OBSERVATION, XI_T_RECEIPT, XI_T_REACTION,
    XI_T_REQUEST, XI_T_IDENTITY, XI_T_TRACK, XI_T_SOS,
    XI_T_WARNING, XI_T_INFO, XI_T_CHALLENGE, XI_T_RESPONSE,
    XI_T_BLOG, XI_T_PASSAGE, XI_T_EVENT, XI_T_OFFER,
    XI_T_NEED, XI_T_CHANNEL, XI_T_MAILBOX, XI_T_SERVICE,
    XI_T_COMMAND, XI_T_RESULT, XI_T_MODERATE, XI_T_STATUS,
    XI_T_PLACE, XI_T_POLL, XI_T_FILE, XI_T_REPORT,
    XI_T_PING, XI_T_PONG,
    XI_T_OTHER,            /* a type this build does not know: still stored */
    XI_T__COUNT
} xprsidx_type_t;

/** Name for a code ("warning"), or "other". Never NULL. */
const char *xprsidx_type_name(int code);
/** Code for a name; XI_T_OTHER when unknown. */
int xprsidx_type_code(const char *name);

/** Record flags. */
#define XI_F_MAIL      0x01   /* carries d: — held, never served to others */
#define XI_F_OUTGOING  0x02   /* this station originated or relayed it */
#define XI_F_SIGNED    0x04   /* carried sig: */
#define XI_F_VERIFIED  0x08   /* the signature checked out against a known key */

/**
 * How a record's authorship should be presented (XPRS.md section 9.1). Derived
 * from the flags rather than stored twice.
 *
 * There is no FORGED value because a forged record is never written: a
 * signature that fails against a key we hold is the one thing on this bearer
 * that is evidence of a lie, and keeping it would mean serving it to somebody
 * later under the author's name.
 */
typedef enum {
    XI_SIG_UNSIGNED = 0,   /* no sig: — common and legitimate */
    XI_SIG_UNVERIFIED,     /* signed, but we hold no key for the author */
    XI_SIG_VERIFIED,       /* signed, and it checks out */
} xprsidx_sig_t;

static inline xprsidx_sig_t xprsidx_sig_of(uint8_t flags)
{
    if (!(flags & XI_F_SIGNED)) return XI_SIG_UNSIGNED;
    return (flags & XI_F_VERIFIED) ? XI_SIG_VERIFIED : XI_SIG_UNVERIFIED;
}

/**
 * Check one packet's `sig:` (XPRS.md section 9.1).
 *
 * @return >0 verified, 0 cannot tell (no key for this author), <0 forged.
 *
 * The store calls this on its OWN writer task, never on the thread that heard
 * the packet: a verify is a secp256k1 point multiplication, and this board has
 * a long history of what happens when work like that lands on the processor the
 * radios are using. Anything the callback needs must therefore be safe to touch
 * from that task.
 */
typedef int (*xprsidx_verify_cb_t)(const char *wire, int len, const char *from);


/** One record as a query hands it back. */
typedef struct {
    uint32_t index;
    uint32_t ts;                        /* sender's ts: as epoch, 0 if unstated */
    int8_t   rssi;                      /* dBm, 0 if unknown */
    uint8_t  flags;
    uint8_t  type;                      /* xprsidx_type_t */
    uint16_t len;                       /* bytes of wire */
    char     id[XPRSIDX_ID_LEN];        /* section 5 identifier */
    char     from[XPRSIDX_CALL_LEN];    /* f: */
    char     to[XPRSIDX_CALL_LEN];      /* d:, empty when a publication */
    char     wire[XPRSIDX_WIRE_MAX + 1];/* the packet, verbatim */
} xprsidx_rec_t;

/** Query parameters. All filters are AND-ed; a zero field means "any". */
typedef struct {
    uint32_t since_ts;      /* 0 = any; else ts >= since_ts */
    uint32_t until_ts;      /* 0 = any; else ts <= until_ts */
    int      type;          /* -1 = any; else an xprsidx_type_t */
    const char *from;       /* NULL/"" = any author */
    /**
     * Who is asking. Mail (a record with d:) is emitted ONLY when this matches
     * its `to` or its `from` — the section 36 rule, enforced here rather than
     * left to the caller, because the caller is a radio protocol and forgetting
     * it would publish other people's mail.
     */
    const char *asker;
    uint32_t limit;         /* 0 = a sensible default */
    bool     newest_first;  /* the "most recent N" shape */
} xprsidx_query_t;

typedef struct {
    uint32_t count;         /* records on disk */
    uint32_t latest_index;
    uint32_t segments;
    uint64_t total_bytes;   /* card */
    uint64_t free_bytes;
    char     epoch;
    /* Authorship, since boot. `forged` counts records refused, not stored. */
    uint32_t verified, unverified, forged;
} xprsidx_stats_t;

/** Return false to stop the query early. */
typedef bool (*xprsidx_emit_cb_t)(const xprsidx_rec_t *rec, void *ctx);

typedef struct xprsidx_s xprsidx_t;

/**
 * Open (create + scan) the index rooted at @p dir on the mounted card. Recovers
 * the next index and epoch, and rebuilds either derived index if it is missing
 * or short. NULL when there is no card or no memory.
 */
xprsidx_t *xprsindex_open(const char *dir);

/**
 * Install the verifier. NULL (the default) means every signed record is stored
 * unverified, which is what a station with no keys can honestly say.
 */
void xprsindex_set_verifier(xprsidx_t *st, xprsidx_verify_cb_t cb);
void       xprsindex_close(xprsidx_t *st);
bool       xprsindex_ready(const xprsidx_t *st);

/**
 * Offer one heard packet. Parses it, refuses what must not be stored (not XPRS,
 * ping/pong, a duplicate within the recent window), and otherwise appends it
 * verbatim and updates both indexes.
 *
 * @param ts_now  wall clock if this station has one, else 0 — used only when
 *                the packet states no ts: of its own.
 * @return true when a record was written.
 */
bool xprsindex_add(xprsidx_t *st, const char *wire, int len,
                   int rssi, bool outgoing, uint32_t ts_now);

/**
 * Stream matching records. Ascending index unless @p q asks for newest_first.
 * @return how many were emitted.
 */
size_t xprsindex_query(xprsidx_t *st, const xprsidx_query_t *q,
                       xprsidx_emit_cb_t cb, void *ctx);

void xprsindex_stats(xprsidx_t *st, xprsidx_stats_t *out);

/**
 * `ts:` (`YYYY-MM-DD_hh:mm:ss`, section 4.3) as epoch seconds, or 0 when it is
 * not one. Public because a `cmd:history` carries `since:`/`until:` in exactly
 * that form and has to turn them into the same numbers this index stores —
 * a second parser would be a second set of off-by-one bugs.
 */
uint32_t xprsindex_ts_to_epoch(const char *ts, int len);

/**
 * Read one record by its index.
 *
 * For a caller that has already chosen what it wants and only needs the bytes
 * back later — a paced `cmd:history` replay holds a page of INDEXES (four bytes
 * each) rather than a page of wires (a quarter of a kilobyte each), which on a
 * board with about thirteen kilobytes of free heap is the difference between
 * working and quietly failing to create a task.
 *
 * @return false when the index was never written or the record is unreadable.
 */
bool xprsindex_get(xprsidx_t *st, uint32_t index, xprsidx_rec_t *out);

/**
 * @brief Ask the owner whether the card may be touched right now.
 * @return true when the radio is idle and a burst of SD traffic is harmless.
 */
typedef bool (*xprsidx_gate_fn)(void);

/**
 * @brief Hold SD writes while the radio is busy.
 *
 * The SDMMC bus desensitises the 2.4 GHz radio — measured on the T-Dongle as a
 * WiFi station that stays associated and cannot get a frame out (1 of 96 pings
 * answered with the card in use, 159 of 162 without). Records are decided
 * immediately and wait in RAM; this decides when they are allowed to go down.
 * Without a gate the writer drains on its own timer.
 */
void xprsindex_set_gate(xprsidx_t *st, xprsidx_gate_fn gate);

/**
 * @brief Stop the writer touching the card, and wait until it is out.
 *
 * For a reader that is about to do its own SD work — an HTTP request, a GATT
 * query — and does not want to queue behind a batch of writes. Returns once the
 * writer is out of the card, so the caller owns it. Always pair it:
 *
 *     xprsindex_pause_writes(st, true);
 *     ... read, build the answer ...
 *     xprsindex_pause_writes(st, false);
 *
 * Records keep being accepted into RAM while paused; only the card is idle.
 */
void xprsindex_pause_writes(xprsidx_t *st, bool paused);

/* ── The directory an indexer publishes (XPRS.md §36.9) ─────────────────── */

/** One archived station: its callsign and when this indexer last heard it. */
typedef struct {
    char     call[XPRSIDX_CALL_LEN];
    uint32_t last_ts;                 /* the packet's own ts:, epoch seconds */
} xprsidx_dir_entry_t;

/**
 * @brief Who this indexer archives, for the XDIR1 listing of §36.9.
 *
 * Sorted by callsign, one entry per station, with the most recent time it was
 * heard — which is exactly what a peer indexer needs to decide whether to ask
 * us about a callsign, and nothing more. **Content never travels between
 * indexers; only this does.**
 *
 * Walks the store, so it is not free: an indexer publishes a directory on a
 * cadence, it does not rebuild one per question.
 *
 * @return entries written (<= @p max).
 */
int xprsindex_directory(xprsidx_t *st, xprsidx_dir_entry_t *out, int max);

/**
 * @brief Render entries as the XDIR1 text of §36.9 — a header line, then
 *        `call ts` per station, sorted.
 * @return bytes written, excluding the NUL, or -1 if it would not fit.
 */
int xprsindex_dir_render(const xprsidx_dir_entry_t *entries, int n,
                         char *out, size_t cap);

/** Records waiting in RAM, and how many were dropped because it filled. */
void xprsindex_queue_stats(xprsidx_t *st, uint32_t *out_waiting,
                           uint32_t *out_dropped);

#ifdef XPRSIDX_BENCH
/**
 * Fill the store with @p n synthetic packets spread over two years and log how
 * long the write and the two headline queries take ON THE DEVICE.
 *
 * Compiled only under -DXPRSIDX_BENCH — the shipped firmware does not contain
 * it. Build it with:
 *     PLATFORMIO_BUILD_FLAGS=-DXPRSIDX_BENCH pio run -e tdongle_s3 -t upload
 * and note that it WRITES to the card: run it on a store you can discard.
 */
void xprsindex_bench(xprsidx_t *st, uint32_t n);
#endif
uint32_t xprsindex_latest_index(const xprsidx_t *st);
char xprsindex_epoch(const xprsidx_t *st);

#ifdef __cplusplus
}
#endif
#endif /* GEOGRAM_XPRSINDEX_H */
