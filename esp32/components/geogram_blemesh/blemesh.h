/*
 * blemesh — BLE street-mesh core (aurora doc/mesh.md), phone-wire-compatible.
 *
 * Three pieces, all pure logic (no radio/storage/UI — the firmware wires those):
 *
 *  1. Route-beacon codec (BLE5 manufacturer subtype 0x4D under marker 0x3E):
 *       [ver=1][class][cond][cs_len][callsign][K][(hash3+cost1)*K][bloom_len][bloom]
 *     Cond byte: bit0 powered, bits1-3 uptime bucket (log ladder), bits4-5
 *     mobility (0 unknown, 1 stationary, 2 moving), bits6-7 storage headroom.
 *     Class byte: 0 other, 1 phone, 2 tablet, 3 computer, 4 router, 5 esp32,
 *     6 base station. Routing hash = first 3 bytes of SHA-256(UPPER(callsign)).
 *
 *  2. Neighbor + distance-vector table: ingest received beacons, learn
 *     dest -> (via, cost) with cost cap 6, bidirectional confirmation (a
 *     neighbor is a usable next-hop only when its own digest lists US at
 *     cost 1), aging, and DV export for our own beacon.
 *
 *  3. Store-and-forward (SCF): park heard 1:1 frames keyed by their am: token,
 *     purge on an overheard "?ACK <am>" receipt, and hand frames back for
 *     re-air when the target reappears. Optional file persistence (stdio path,
 *     e.g. on the SD card) so parked mail survives a reboot.
 */
#ifndef GEOGRAM_BLEMESH_H
#define GEOGRAM_BLEMESH_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- shared constants (must match aurora lib/services/mesh/) ------------ */
#define BLEMESH_SUBTYPE       0x4D  /* 'M' — under company 0xFFFF, marker 0x3E */
#define BLEMESH_VER           1
#define BLEMESH_MAX_COST      6
#define BLEMESH_CALLSIGN_MAX  9     /* wire cap (chars) */

/* Device class byte. */
enum {
    BLEMESH_CLASS_OTHER = 0, BLEMESH_CLASS_PHONE, BLEMESH_CLASS_TABLET,
    BLEMESH_CLASS_COMPUTER, BLEMESH_CLASS_ROUTER, BLEMESH_CLASS_ESP32,
    BLEMESH_CLASS_BASE,
};

/* ---- beacon codec -------------------------------------------------------- */
typedef struct { uint8_t hash[3]; uint8_t cost; } blemesh_dv_t;

typedef struct {
    char     callsign[BLEMESH_CALLSIGN_MAX + 1];
    uint8_t  dev_class;
    bool     powered;
    uint8_t  uptime_bucket;   /* 0..7: <10m,30m,1h,3h,12h,1d,3d,>3d */
    uint8_t  mobility;        /* 0 unknown, 1 stationary, 2 moving */
    uint8_t  storage_bucket;  /* 0..3 */
    uint8_t  dv_count;
    blemesh_dv_t dv[48];
} blemesh_beacon_t;

/* Uptime bucket for a duration in seconds (same ladder as the phone). */
uint8_t blemesh_uptime_bucket(uint32_t uptime_sec);

/* 3-byte routing hash of a callsign (SHA-256 prefix of the UPPERCASED name). */
void blemesh_hash(const char *callsign, uint8_t out[3]);

/* Encode [b] into [out]; trims dv entries to fit [cap]. Returns bytes or 0. */
int blemesh_beacon_encode(const blemesh_beacon_t *b, uint8_t *out, int cap);

/* Decode a subtype-0x4D payload. Returns true on success (never crashes on
 * malformed air data; unknown trailing fields are ignored). */
bool blemesh_beacon_decode(const uint8_t *d, int len, blemesh_beacon_t *out);

/* ---- neighbor + DV table ------------------------------------------------- */
#define BLEMESH_NEIGH_MAX   24
#define BLEMESH_ROUTE_MAX   64
#define BLEMESH_NEIGH_TTL   300   /* seconds without a beacon -> dead */

typedef struct {
    char     callsign[BLEMESH_CALLSIGN_MAX + 1];
    uint8_t  hash[3];
    uint8_t  dev_class;
    uint8_t  cond;            /* raw cond byte (decoded on demand) */
    bool     bidirectional;   /* its digest lists US at cost 1 */
    int8_t   rssi;
    uint32_t last_heard;      /* seconds (monotonic, caller-supplied) */
    uint16_t beacons;
    uint8_t  reach;           /* size of its advertised digest */
} blemesh_neighbor_t;

typedef struct {
    uint8_t  hash[3];         /* destination */
    char     via[BLEMESH_CALLSIGN_MAX + 1];
    uint8_t  cost;
    uint32_t updated;
} blemesh_route_t;

/* Initialize with OUR callsign (identity of this node). */
void blemesh_table_init(const char *self_callsign);

/* Ingest a decoded beacon heard at [now] (monotonic seconds) with [rssi].
 * Returns true when topology changed (new neighbor / better route / bidi flip)
 * — the caller should beacon early (triggered update). */
bool blemesh_table_ingest(const blemesh_beacon_t *b, int rssi, uint32_t now);

/* Drop neighbors/routes not refreshed within BLEMESH_NEIGH_TTL. */
void blemesh_table_sweep(uint32_t now);

/* Export our DV digest (direct neighbors at cost 1 first, then learned routes
 * under the cap). Returns the number of entries written (<= max). */
int blemesh_table_export(blemesh_dv_t *out, int max);

/* Lookups for the firmware/UI. */
int  blemesh_neighbor_count(void);
const blemesh_neighbor_t *blemesh_neighbor_at(int i);
int  blemesh_route_count(void);
/* Is [callsign] currently reachable (a live neighbor, or routed)? */
bool blemesh_reachable(const char *callsign);

/* ---- store-and-forward --------------------------------------------------- */
#define BLEMESH_SCF_MAX        24
#define BLEMESH_SCF_FRAME_MAX  252   /* one extended-advert AD payload */
#define BLEMESH_SCF_TTL_SEC    (7 * 24 * 3600)  /* 7 days (doc/mesh.md §6) */

/* Initialize; [persist_path] (e.g. "/sdcard/mesh/pending.bin") may be NULL for
 * RAM-only. Loads any persisted entries. */
void blemesh_scf_init(const char *persist_path);

/* Offer a heard 1:1 frame for custody. [target] the addressee callsign, [am]
 * the 6-hex receipt id ("" = none, keyed by content hash instead), [frame] the
 * RAW subtype-0x41 payload (from\x1Fto\x1Ftext) to re-air verbatim.
 * Dedups by am/content. Returns true if newly parked. */
bool blemesh_scf_offer(const char *target, const char *am,
                       const uint8_t *frame, int len, uint32_t now);

/* An "?ACK <am> ..." receipt was overheard — the target has the message;
 * drop every parked copy carrying that am. Returns entries purged. */
int blemesh_scf_ack(const char *am);

/* The target was just seen (beacon/frame). Pops up to [max] parked frames for
 * it into [out] (arrays of BLEMESH_SCF_FRAME_MAX buffers + lengths) for
 * re-air. Popped entries stay parked (purged only by ack or TTL) but are
 * rate-limited to one re-air per sighting per BLEMESH_SCF_REAIR_MIN_SEC. */
#define BLEMESH_SCF_REAIR_MIN_SEC 60
int blemesh_scf_pop_for(const char *target, uint32_t now,
                        uint8_t out[][BLEMESH_SCF_FRAME_MAX], int *out_len,
                        int max);

/* Drop entries older than BLEMESH_SCF_TTL_SEC. */
void blemesh_scf_sweep(uint32_t now);

int blemesh_scf_count(void);

#ifdef __cplusplus
}
#endif
#endif /* GEOGRAM_BLEMESH_H */
