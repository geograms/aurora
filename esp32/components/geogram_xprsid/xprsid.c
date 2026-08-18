/*
 * Making and checking an XPRS signature — see xprsid.h.
 *
 * Lifted from the dongle's main.c when a second station needed to sign. The
 * body is unchanged; what changed is that the key is now an argument instead of
 * a global, which is the only reason it could be shared at all.
 */

#include "xprsid.h"
#include "xprssig.h"

#include <string.h>
#include <stdio.h>

#include "mbedtls/sha256.h"

static void xid_sha256(const uint8_t *in, size_t len, uint8_t out[32])
{
    mbedtls_sha256_context c;
    mbedtls_sha256_init(&c);
    mbedtls_sha256_starts(&c, 0);
    mbedtls_sha256_update(&c, in, len);
    mbedtls_sha256_finish(&c, out);
    mbedtls_sha256_free(&c);
}

int xprsid_sign(char *wire, int len, int cap, const uint8_t priv[32])
{
    if (!wire || !priv || len <= 0) return len;
    if (len + 5 + XPRSSIG_B85_LEN >= cap) return len;   /* §9.1.1: no room */

    uint8_t digest[32];
    xid_sha256((const uint8_t *)wire, (size_t)len, digest);

    uint8_t sig[XPRSSIG_LEN];
    if (!xprssig_sign(digest, priv, sig)) return len;

    char b85[XPRSSIG_B85_LEN + 1];
    if (xprssig_b85_encode(sig, sizeof sig, b85, sizeof b85) != XPRSSIG_B85_LEN) {
        return len;
    }

    char *m = strstr(wire, " m:");
    if (m) {
        /* Insert before the message, keeping m: last. */
        int head = (int)(m - wire);
        char tail[XPRS_MAX_WIRE + 1];
        int taillen = len - head;
        if (taillen < 0 || taillen > (int)sizeof tail - 1) return len;
        memcpy(tail, m, (size_t)taillen);
        tail[taillen] = 0;
        int n = snprintf(wire + head, (size_t)(cap - head), " sig:%s%s", b85, tail);
        return (n > 0) ? head + n : len;
    }
    int n = snprintf(wire + len, (size_t)(cap - len), " sig:%s", b85);
    return (n > 0) ? len + n : len;
}

bool xprsid_verify(const xprs_t *p, const uint8_t pub[32])
{
    if (!p || !pub) return false;

    char b85[XPRSSIG_B85_LEN + 1];
    if (!xprs_get_str(p, "sig", b85, sizeof b85)) return false;
    if (strlen(b85) != XPRSSIG_B85_LEN) return false;

    uint8_t sig[XPRSSIG_LEN];
    if (xprssig_b85_decode(b85, XPRSSIG_B85_LEN, sig, sizeof sig) != XPRSSIG_LEN)
        return false;

    /* The canonical text: the packet with sig: and via: removed. */
    char canon[XPRS_MAX_WIRE + 1];
    int n = xprs_signed_text(p, canon, sizeof canon);
    if (n <= 0) return false;

    uint8_t digest[32];
    xid_sha256((const uint8_t *)canon, (size_t)n, digest);
    return xprssig_verify(digest, sig, pub);
}
