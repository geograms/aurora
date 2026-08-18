/**
 * @file xprssig.h
 * @brief XPRS signatures (docs/XPRS.md §9.1) — 48 bytes over secp256k1.
 *
 * `sig:` is what stops a callsign being a label anyone can write. A station
 * signs by default; a receiver must still accept unsigned packets, but it must
 * never present an unsigned `f:` as established.
 *
 * ── The scheme, and why it is not BIP-340 ───────────────────────────────────
 *
 * Classic Schnorr in (e, s) form with the challenge truncated to 16 bytes and
 * the scalar full at 32 — 48 bytes, which is the smallest a secp256k1
 * signature can be, and 60 characters in the base85 below. BIP-340's (R, s) is
 * 64 bytes and would not leave room for a message. Same key as the npub and the
 * callsign, so nothing about identity changes.
 *
 * Not interoperable with BIP-340 verifiers, by construction. The reference is
 * `reticulum-dart/lib/src/util/xprs_crypto.dart`, and the host harness verifies
 * signatures that implementation produced.
 *
 * ── What is signed ──────────────────────────────────────────────────────────
 *
 * The packet with `sig:` and `via:` removed (§9.1) — the same canonical text
 * the §5 identifier is derived from, so a relay appending itself to `via:`
 * cannot invalidate a signature. Callers pass the sha256 of that text.
 */

#ifndef GEOGRAM_XPRSSIG_H
#define GEOGRAM_XPRSSIG_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define XPRSSIG_LEN      48     /* 16-byte challenge || 32-byte scalar */
#define XPRSSIG_B85_LEN  60     /* what `sig:` carries */
#define XPRSSIG_KEY_LEN  32     /* private scalar, and the x-only public key */

/**
 * @brief The x-only public key for a private scalar, BIP-340 even-y convention.
 * @return false if the scalar is not a valid secp256k1 key.
 */
bool xprssig_public_key(const uint8_t priv[XPRSSIG_KEY_LEN],
                        uint8_t pub_x[XPRSSIG_KEY_LEN]);

/**
 * @brief Sign a 32-byte digest. Randomised: a fresh nonce every call, so two
 *        signatures over the same digest differ and neither leaks the key.
 * @return false when the scalar is unusable.
 */
bool xprssig_sign(const uint8_t digest[32], const uint8_t priv[XPRSSIG_KEY_LEN],
                  uint8_t out[XPRSSIG_LEN]);

/** @brief Verify a 48-byte signature against an x-only public key. */
bool xprssig_verify(const uint8_t digest[32], const uint8_t sig[XPRSSIG_LEN],
                    const uint8_t pub_x[XPRSSIG_KEY_LEN]);

/**
 * @brief The APRS-safe base85 of §4.3 — 4 bytes to 5 characters.
 *
 * Its own alphabet, not RFC 1924 and not Ascii85: the characters chosen are
 * the ones that survive an APRS path. @p len must be a multiple of 4.
 * @return characters written (excluding the NUL), or -1.
 */
int xprssig_b85_encode(const uint8_t *in, size_t len, char *out, size_t cap);
/** @return bytes written, or -1 on a character outside the alphabet. */
int xprssig_b85_decode(const char *in, size_t len, uint8_t *out, size_t cap);

/**
 * @brief Generate a private scalar from the platform's entropy.
 * @return false if a usable key could not be produced.
 */
bool xprssig_generate(uint8_t priv[XPRSSIG_KEY_LEN]);

#ifdef __cplusplus
}
#endif
#endif /* GEOGRAM_XPRSSIG_H */
