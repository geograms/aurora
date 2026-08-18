/**
 * @file xprsid.h
 * @brief Signing and checking an XPRS packet (`docs/XPRS.md` §9.1).
 *
 * Two pure functions. Everything about WHICH key belongs to whom stays with the
 * station — this file only knows how a signature is made and checked, which is
 * the part every station does identically and none should write twice.
 *
 * `sig:` covers the packet with `sig:` and `via:` removed — the same canonical
 * text the §5 identifier is derived from, so a relay appending itself cannot
 * invalidate a signature.
 */

#ifndef GEOGRAM_XPRSID_H
#define GEOGRAM_XPRSID_H

#include <stdint.h>
#include <stdbool.h>

#include "xprs.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Append `sig:` to @p wire in place, signed with @p priv.
 *
 * Inserted BEFORE `m:` when the packet has one, because `m:` is greedy and must
 * stay last (§4). Returns the new length, or the old one when there is no room
 * (§9.1.1) or no key — an unsigned packet is legitimate and better than a
 * truncated one.
 */
int xprsid_sign(char *wire, int len, int cap, const uint8_t priv[32]);

/**
 * @brief Check `sig:` against @p pub, a 32-byte x-only key.
 * @return false for unsigned, malformed, or wrong. A caller deciding whether to
 *         act wants one answer, and "not proven" is the same as "no".
 */
bool xprsid_verify(const xprs_t *p, const uint8_t pub[32]);

#ifdef __cplusplus
}
#endif
#endif /* GEOGRAM_XPRSID_H */
