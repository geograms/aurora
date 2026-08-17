/*
 * xprs — the XPRS wire format (aurora docs/XPRS.md), C mirror of
 * lib/services/xprs/{xprs_packet,xprs_id,xprs_vocab}.dart.
 *
 * One line of text under 250 bytes, `key:value` fields separated by single
 * spaces, `t:` first, `m:` last (its value swallows the rest of the packet):
 *
 *   t:message f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 m:net starts in ten minutes
 *
 * Everything here is pure logic over caller-owned buffers — no radio, no
 * storage, no ESP-IDF except the sha256 hook (xprs_sha256_idf.c on target,
 * supplied by the harness on host). test_xprs_host.c replays the same corpus
 * as test/xprs_packet_test.dart (test/xprs_corpus.json), so the two parsers
 * and both identifier derivations cannot drift apart unnoticed.
 *
 * Parsing is ZERO-COPY: fields point into the caller's buffer, values are not
 * NUL-terminated (they carry lengths). Field order is preserved because the
 * identifier is a hash of the packet as written — nothing here sorts,
 * normalises or rewrites.
 */
#ifndef GEOGRAM_XPRS_H
#define GEOGRAM_XPRS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The largest a packet may be on any bearer (docs/XPRS.md section 4). */
#define XPRS_MAX_WIRE   250
/* Fields in one packet. The spec has no cap; the densest packet in the 205
 * corpus examples holds 14 fields, so 32 leaves real headroom on a device
 * where a parse lives on the stack. A packet with MORE fields fails to parse
 * outright rather than being read partially — storing a subset would derive a
 * WRONG identifier, and a 250-byte packet needs pathological 3-byte fields to
 * get anywhere near this. */
#define XPRS_MAX_FIELDS 32
/* An identifier: 6 lowercase hex characters + NUL. */
#define XPRS_ID_LEN     7

typedef struct {
    const char *key;   /* into the caller's buffer */
    uint16_t    klen;
    const char *val;   /* into the caller's buffer; NOT NUL-terminated */
    uint16_t    vlen;
} xprs_field_t;

typedef struct {
    xprs_field_t f[XPRS_MAX_FIELDS];
    int          n;
} xprs_t;

/* Provided by xprs_sha256_idf.c on the target (mbedtls); the host test
 * harness links its own implementation instead. */
void xprs_sha256(const uint8_t *in, size_t len, uint8_t out[32]);

/* Is [wire] an XPRS packet at all? The seam mirrored from mesh_frame.dart:
 * starts "t:" and contains no 0x1F byte (a compact Aurora parcel has two). */
bool xprs_looks_like(const uint8_t *wire, int len);

/* Parse one wire packet. Returns false only when it is not XPRS at all (no
 * leading `t:`, or no field survived). Malformed tokens are skipped without
 * error — design rule 8 — exactly as XprsPacket.parse does. [wire] must stay
 * alive as long as [out] is used. */
bool xprs_parse(const char *wire, int len, xprs_t *out);

/* First value for [key], or NULL. Sets *vlen when non-NULL is returned. */
const char *xprs_get(const xprs_t *p, const char *key, int *vlen);

/* First value for [key] copied out NUL-terminated (truncates to cap-1).
 * Returns false when the key is absent (out[0] is then 0). */
bool xprs_get_str(const xprs_t *p, const char *key, char *out, int cap);

/* The packet type — the value of the first field, which parse guarantees is
 * `t`. Copied NUL-terminated into [out]. */
void xprs_type(const xprs_t *p, char *out, int cap);

/* Rebuild the wire text: fields joined "k:v" with single spaces. Returns the
 * length written, or -1 when it does not fit [cap] (needs len+1 for the NUL). */
int xprs_encode(const xprs_t *p, char *out, int cap);

/* The six-character identifier (docs/XPRS.md section 5): first 6 hex chars of
 * sha256(packet with sig: and via: removed). Never transmitted. */
void xprs_id(const xprs_t *p, char id[XPRS_ID_LEN]);

/* Identifier straight from wire form. Returns false when it does not parse. */
bool xprs_id_of(const char *wire, int len, char id[XPRS_ID_LEN]);

/* The exact text a signature covers (section 9.1): the packet with `sig:` and
 * `via:` removed. The SAME text the section 5 identifier is derived from, which
 * is not a coincidence — both have to survive relaying, and relaying only ever
 * touches `via:`.
 *
 * A verifier has to rebuild this byte for byte, and two implementations
 * disagreeing about it is the kind of bug that only shows up once both are
 * deployed. Returns the length written, or -1 when it would not fit. */
int xprs_signed_text(const xprs_t *p, char *out, int cap);

/* ---- transport vocabulary (xprs_vocab.dart) ------------------------------ */

/* Urgency levels, ordered lowest-first (section 13.5): the custody store
 * evicts lowest-urgency-first, oldest-first within a level. */
enum {
    XPRS_URG_LOW    = 0,
    XPRS_URG_NORMAL = 1,
    XPRS_URG_HIGH   = 2,
    XPRS_URG_URGENT = 3,
};

/* Parse urg: — anything unrecognised (or absent) is NORMAL, as fromWire does.
 * Use xprs_get to distinguish "absent" from "stated" when admission needs to
 * (a stranger's unstated mail is parked at LOW, docs/store-and-forward.md). */
int xprs_urg(const xprs_t *p);

/* Relay budget by type (section 13.1): sos|warning 9, everything else 3. */
int xprs_relay_limit(const xprs_t *p);

/* Callsigns in via:, i.e. hops taken (section 13). 0 when absent. */
int xprs_via_count(const xprs_t *p);

/* Is [self] already in via:? (section 13.2 — a station in the path never
 * relays, whatever the count says.) Case-insensitive. */
bool xprs_via_contains(const xprs_t *p, const char *self);

/* scope:local — for the bearers in range now; never carried, never gatewayed
 * (section 13.11). */
bool xprs_scope_local(const xprs_t *p);

/* Does [addr] name a station rather than a group (section 6.3)? A group name
 * is 1-16 uppercase letters; anything with a digit is a callsign — except an
 * X5 prefix, which is a (closed) group. Mirrors MeshCustodyDelegate._isStation. */
bool xprs_is_station(const char *addr, int len);

/* Rebuild [wire] with [self] appended to via: (created before m: when absent),
 * which is what a relay transmits (section 13). Neither the identifier nor a
 * signature changes — both are computed with via: removed. Returns the new
 * length, or -1 when relaying is forbidden (self already in the path, the
 * type's relay budget is spent) or the result would not fit [cap]. */
int xprs_append_via(const char *wire, int len, const char *self,
                    char *out, int cap);

#ifdef __cplusplus
}
#endif
#endif /* GEOGRAM_XPRS_H */
