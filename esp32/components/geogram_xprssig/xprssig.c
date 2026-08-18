/*
 * XPRS signatures — see xprssig.h for the scheme and why it is not BIP-340.
 *
 * The maths is one file; only the bignum and curve primitives differ by side
 * (mbedtls on the ESP32, OpenSSL in the host harness). The harness verifies
 * signatures produced by reticulum-dart, which is the only check that means
 * anything here: a signer nobody else can verify is worse than no signer,
 * because it looks like it works.
 */

#include "xprssig.h"

#include <string.h>

/* ── Backend: everything below needs only these ─────────────────────────── */

/* All operate on 32-byte big-endian values.
 *   xs_mul_g_add_p : R = a·G + b·P, with P given x-only (even y). b/P optional.
 *   xs_sc_muladd   : (k + e·d) mod n
 *   xs_sc_negate   : n - d
 *   xs_sc_valid    : 0 < d < n
 */
static bool xs_mul_g_add_p(const uint8_t a[32], const uint8_t *b,
                           const uint8_t p_x[32],
                           uint8_t out_x[32], bool *out_y_odd);
static bool xs_sc_muladd(const uint8_t k[32], const uint8_t e[32],
                         const uint8_t d[32], uint8_t out[32]);
static bool xs_sc_negate(const uint8_t d[32], uint8_t out[32]);
static bool xs_sc_valid(const uint8_t d[32]);
static void xs_sha256(const uint8_t *in, size_t len, uint8_t out[32]);
static void xs_random(uint8_t *out, size_t len);

/*
 * The tagged-hash domain strings, XPRS.md section 9.1.2.
 *
 * The tag is hashed into the challenge, so these two strings are as much a part
 * of the wire format as the curve is. A verifier using different ones agrees
 * with nobody.
 *
 * There were briefly two more, from before the protocol was renamed, and this
 * verifier tried the old challenge string after the current one so that
 * already-signed data kept validating. That transition is over. What it cost is
 * worth stating, because it is not the usual "shows as unverified": the archive
 * drops forged packets at flush and the courier drops forged carried mail, so
 * every signature made under the old strings was DISCARDED rather than doubted.
 */
#define XS_TAG_NONCE          "XPRS/nonce"
#define XS_TAG_CHALLENGE      "XPRS/challenge"

#ifdef XPRSSIG_HOST_TEST
/* Set by the test to reproduce section 9.1.2's worked example. */
bool xprssig_test_zero_aux;
#endif

#ifdef XPRSSIG_HOST_TEST

#include <openssl/sha.h>
#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/obj_mac.h>
#include <stdlib.h>

static void xs_sha256(const uint8_t *in, size_t len, uint8_t out[32])
{
    SHA256(in, len, out);
}
static void xs_random(uint8_t *out, size_t len)
{
    for (size_t i = 0; i < len; i++) out[i] = (uint8_t)(rand() & 0xFF);
}

static EC_GROUP *xs_group(void)
{
    static EC_GROUP *g;
    if (!g) g = EC_GROUP_new_by_curve_name(NID_secp256k1);
    return g;
}

static bool xs_mul_g_add_p(const uint8_t a[32], const uint8_t *b,
                           const uint8_t p_x[32],
                           uint8_t out_x[32], bool *out_y_odd)
{
    EC_GROUP *grp = xs_group();
    BN_CTX *ctx = BN_CTX_new();
    EC_POINT *r = EC_POINT_new(grp), *p = NULL;
    BIGNUM *ba = BN_bin2bn(a, 32, NULL), *bb = NULL, *x = BN_new(), *y = BN_new();
    bool ok = false;

    if (b && p_x) {
        /* lift_x with even y — the convention the whole scheme uses. */
        BIGNUM *px = BN_bin2bn(p_x, 32, NULL);
        p = EC_POINT_new(grp);
        if (EC_POINT_set_compressed_coordinates(grp, p, px, 0, ctx) != 1) {
            BN_free(px); goto done;
        }
        BN_free(px);
        bb = BN_bin2bn(b, 32, NULL);
    }
    if (EC_POINT_mul(grp, r, ba, p, bb, ctx) != 1) goto done;
    if (EC_POINT_is_at_infinity(grp, r)) goto done;
    if (EC_POINT_get_affine_coordinates(grp, r, x, y, ctx) != 1) goto done;
    BN_bn2binpad(x, out_x, 32);
    if (out_y_odd) *out_y_odd = BN_is_odd(y);
    ok = true;
done:
    BN_free(ba); BN_free(x); BN_free(y);
    if (bb) BN_free(bb);
    if (p) EC_POINT_free(p);
    EC_POINT_free(r); BN_CTX_free(ctx);
    return ok;
}

static bool xs_sc_muladd(const uint8_t k[32], const uint8_t e[32],
                         const uint8_t d[32], uint8_t out[32])
{
    EC_GROUP *grp = xs_group();
    BN_CTX *ctx = BN_CTX_new();
    BIGNUM *n = BN_new(), *bk = BN_bin2bn(k, 32, NULL);
    BIGNUM *be = BN_bin2bn(e, 32, NULL), *bd = BN_bin2bn(d, 32, NULL);
    BIGNUM *t = BN_new();
    EC_GROUP_get_order(grp, n, ctx);
    BN_mod_mul(t, be, bd, n, ctx);
    BN_mod_add(t, t, bk, n, ctx);
    BN_bn2binpad(t, out, 32);
    BN_free(n); BN_free(bk); BN_free(be); BN_free(bd); BN_free(t);
    BN_CTX_free(ctx);
    return true;
}

static bool xs_sc_negate(const uint8_t d[32], uint8_t out[32])
{
    EC_GROUP *grp = xs_group();
    BN_CTX *ctx = BN_CTX_new();
    BIGNUM *n = BN_new(), *bd = BN_bin2bn(d, 32, NULL);
    EC_GROUP_get_order(grp, n, ctx);
    BN_sub(bd, n, bd);
    BN_bn2binpad(bd, out, 32);
    BN_free(n); BN_free(bd); BN_CTX_free(ctx);
    return true;
}

static bool xs_sc_valid(const uint8_t d[32])
{
    EC_GROUP *grp = xs_group();
    BN_CTX *ctx = BN_CTX_new();
    BIGNUM *n = BN_new(), *bd = BN_bin2bn(d, 32, NULL);
    EC_GROUP_get_order(grp, n, ctx);
    bool ok = !BN_is_zero(bd) && BN_cmp(bd, n) < 0;
    BN_free(n); BN_free(bd); BN_CTX_free(ctx);
    return ok;
}

#else  /* on the device */

#include "mbedtls/ecp.h"
#include "mbedtls/bignum.h"
#include "mbedtls/sha256.h"
#include "esp_random.h"

static void xs_sha256(const uint8_t *in, size_t len, uint8_t out[32])
{
    mbedtls_sha256(in, len, out, 0);
}
static void xs_random(uint8_t *out, size_t len)
{
    esp_fill_random(out, len);
}

/* mbedtls blinds scalar multiplication and REFUSES to run without an RNG —
 * passing NULL costs a MBEDTLS_ERR_ECP_BAD_INPUT_DATA and, further up, a
 * station that quietly decides it cannot sign. */
static int xs_rng(void *ctx, unsigned char *out, size_t len)
{
    (void)ctx;
    esp_fill_random(out, len);
    return 0;
}

/* One group, loaded once: mbedtls_ecp_group_load walks a table and this is a
 * board where a few hundred microseconds per signature matters less than the
 * heap a second copy would take. */
static mbedtls_ecp_group *xs_group(void)
{
    static mbedtls_ecp_group grp;
    static bool loaded;
    if (!loaded) {
        mbedtls_ecp_group_init(&grp);
        if (mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256K1) != 0) return NULL;
        loaded = true;
    }
    return &grp;
}

/* mbedtls has no lift_x, so the even-y point is rebuilt from a compressed
 * encoding: 0x02 || x is exactly "this x, even y". */
static int xs_lift_x(mbedtls_ecp_group *grp, mbedtls_ecp_point *p,
                     const uint8_t x[32])
{
    uint8_t buf[33];
    buf[0] = 0x02;
    memcpy(buf + 1, x, 32);
    return mbedtls_ecp_point_read_binary(grp, p, buf, sizeof buf);
}

static bool xs_mul_g_add_p(const uint8_t a[32], const uint8_t *b,
                           const uint8_t p_x[32],
                           uint8_t out_x[32], bool *out_y_odd)
{
    mbedtls_ecp_group *grp = xs_group();
    if (!grp) return false;

    mbedtls_ecp_point R, P;
    mbedtls_mpi ba, bb, x, y;
    mbedtls_ecp_point_init(&R); mbedtls_ecp_point_init(&P);
    mbedtls_mpi_init(&ba); mbedtls_mpi_init(&bb);
    mbedtls_mpi_init(&x);  mbedtls_mpi_init(&y);
    bool ok = false;

    if (mbedtls_mpi_read_binary(&ba, a, 32) != 0) goto done;
    if (b && p_x) {
        if (mbedtls_mpi_read_binary(&bb, b, 32) != 0) goto done;
        if (xs_lift_x(grp, &P, p_x) != 0) goto done;
        /* R = a·G + b·P */
        if (mbedtls_ecp_muladd(grp, &R, &ba, &grp->G, &bb, &P) != 0) goto done;
    } else {
        if (mbedtls_ecp_mul(grp, &R, &ba, &grp->G, xs_rng, NULL) != 0) goto done;
    }
    if (mbedtls_ecp_is_zero(&R)) goto done;
    if (mbedtls_mpi_write_binary(&R.MBEDTLS_PRIVATE(X), out_x, 32) != 0) goto done;
    if (out_y_odd) {
        *out_y_odd = (mbedtls_mpi_get_bit(&R.MBEDTLS_PRIVATE(Y), 0) != 0);
    }
    ok = true;
done:
    mbedtls_ecp_point_free(&R); mbedtls_ecp_point_free(&P);
    mbedtls_mpi_free(&ba); mbedtls_mpi_free(&bb);
    mbedtls_mpi_free(&x);  mbedtls_mpi_free(&y);
    return ok;
}

static bool xs_sc_muladd(const uint8_t k[32], const uint8_t e[32],
                         const uint8_t d[32], uint8_t out[32])
{
    mbedtls_ecp_group *grp = xs_group();
    if (!grp) return false;
    mbedtls_mpi bk, be, bd, t;
    mbedtls_mpi_init(&bk); mbedtls_mpi_init(&be);
    mbedtls_mpi_init(&bd); mbedtls_mpi_init(&t);
    bool ok = mbedtls_mpi_read_binary(&bk, k, 32) == 0 &&
              mbedtls_mpi_read_binary(&be, e, 32) == 0 &&
              mbedtls_mpi_read_binary(&bd, d, 32) == 0 &&
              mbedtls_mpi_mul_mpi(&t, &be, &bd) == 0 &&
              mbedtls_mpi_mod_mpi(&t, &t, &grp->N) == 0 &&
              mbedtls_mpi_add_mpi(&t, &t, &bk) == 0 &&
              mbedtls_mpi_mod_mpi(&t, &t, &grp->N) == 0 &&
              mbedtls_mpi_write_binary(&t, out, 32) == 0;
    mbedtls_mpi_free(&bk); mbedtls_mpi_free(&be);
    mbedtls_mpi_free(&bd); mbedtls_mpi_free(&t);
    return ok;
}

static bool xs_sc_negate(const uint8_t d[32], uint8_t out[32])
{
    mbedtls_ecp_group *grp = xs_group();
    if (!grp) return false;
    mbedtls_mpi bd, t;
    mbedtls_mpi_init(&bd); mbedtls_mpi_init(&t);
    bool ok = mbedtls_mpi_read_binary(&bd, d, 32) == 0 &&
              mbedtls_mpi_sub_mpi(&t, &grp->N, &bd) == 0 &&
              mbedtls_mpi_write_binary(&t, out, 32) == 0;
    mbedtls_mpi_free(&bd); mbedtls_mpi_free(&t);
    return ok;
}

static bool xs_sc_valid(const uint8_t d[32])
{
    mbedtls_ecp_group *grp = xs_group();
    if (!grp) return false;
    mbedtls_mpi bd;
    mbedtls_mpi_init(&bd);
    bool ok = mbedtls_mpi_read_binary(&bd, d, 32) == 0 &&
              mbedtls_mpi_cmp_int(&bd, 0) > 0 &&
              mbedtls_mpi_cmp_mpi(&bd, &grp->N) < 0;
    mbedtls_mpi_free(&bd);
    return ok;
}
#endif

/* ── Tagged hash: sha256(sha256(tag) || sha256(tag) || msg) ─────────────── */

static void xs_tagged(const char *tag, const uint8_t *m1, size_t n1,
                      const uint8_t *m2, size_t n2,
                      const uint8_t *m3, size_t n3, uint8_t out[32])
{
    uint8_t th[32];
    xs_sha256((const uint8_t *)tag, strlen(tag), th);

    /* One buffer rather than a streaming hash: every message here is a few
     * dozen bytes and the largest possible is 64 + 32 + 32. */
    uint8_t buf[64 + 160];
    size_t n = 0;
    memcpy(buf + n, th, 32); n += 32;
    memcpy(buf + n, th, 32); n += 32;
    if (m1 && n1 && n + n1 <= sizeof buf) { memcpy(buf + n, m1, n1); n += n1; }
    if (m2 && n2 && n + n2 <= sizeof buf) { memcpy(buf + n, m2, n2); n += n2; }
    if (m3 && n3 && n + n3 <= sizeof buf) { memcpy(buf + n, m3, n3); n += n3; }
    xs_sha256(buf, n, out);
}

/* ── Public API ─────────────────────────────────────────────────────────── */

bool xprssig_public_key(const uint8_t priv[XPRSSIG_KEY_LEN],
                        uint8_t pub_x[XPRSSIG_KEY_LEN])
{
    if (!priv || !pub_x || !xs_sc_valid(priv)) return false;
    bool y_odd = false;
    /* The x of d·G is the same whichever of d or n-d is used, so the parity
     * only matters to the signer. */
    return xs_mul_g_add_p(priv, NULL, NULL, pub_x, &y_odd);
}

bool xprssig_sign(const uint8_t digest[32], const uint8_t priv[XPRSSIG_KEY_LEN],
                  uint8_t out[XPRSSIG_LEN])
{
    if (!digest || !priv || !out || !xs_sc_valid(priv)) return false;

    /* d' is whichever of d, n-d gives an even-y public point. */
    uint8_t dp[32], px[32];
    bool y_odd = false;
    memcpy(dp, priv, 32);
    if (!xs_mul_g_add_p(dp, NULL, NULL, px, &y_odd)) return false;
    if (y_odd) {
        uint8_t neg[32];
        if (!xs_sc_negate(dp, neg)) return false;
        memcpy(dp, neg, 32);
        if (!xs_mul_g_add_p(dp, NULL, NULL, px, &y_odd)) return false;
    }

    uint8_t aux[32];
    xs_random(aux, sizeof aux);
#ifdef XPRSSIG_HOST_TEST
    /* The specification's worked example (section 9.1.2) fixes aux to 32 zero
     * bytes so every intermediate value is reproducible. Nothing but the test
     * can reach this, and a signature is no weaker for it: aux only has to be
     * unpredictable, and on the device it comes from esp_fill_random. */
    if (xprssig_test_zero_aux) memset(aux, 0, sizeof aux);
#endif

    uint8_t k[32];
    xs_tagged(XS_TAG_NONCE, dp, 32, digest, 32, aux, 32, k);
    /* k is used mod n by the multiply; a zero k would be fatal and is
     * astronomically unlikely, but costs one comparison to exclude. */
    if (!xs_sc_valid(k)) {
        memset(k, 0, 32);
        k[31] = 1;
    }

    uint8_t rx[32];
    if (!xs_mul_g_add_p(k, NULL, NULL, rx, NULL)) return false;

    uint8_t e32[32];
    xs_tagged(XS_TAG_CHALLENGE, rx, 32, px, 32, digest, 32, e32);
    /* The challenge is TRUNCATED to 16 bytes — that is where the signature's
     * size comes from — so the scalar arithmetic uses it zero-extended. */
    uint8_t e[32] = {0};
    memcpy(e + 16, e32, 16);

    uint8_t s[32];
    if (!xs_sc_muladd(k, e, dp, s)) return false;

    memcpy(out, e32, 16);
    memcpy(out + 16, s, 32);
    return true;
}

bool xprssig_verify(const uint8_t digest[32], const uint8_t sig[XPRSSIG_LEN],
                    const uint8_t pub_x[XPRSSIG_KEY_LEN])
{
    if (!digest || !sig || !pub_x) return false;

    uint8_t e[32] = {0};
    memcpy(e + 16, sig, 16);
    const uint8_t *s = sig + 16;
    if (!xs_sc_valid(s)) return false;

    /* R' = s·G - e·P, computed as s·G + (n-e)·P. */
    uint8_t neg_e[32];
    if (!xs_sc_negate(e, neg_e)) return false;

    uint8_t rx[32];
    if (!xs_mul_g_add_p(s, neg_e, pub_x, rx, NULL)) return false;

    uint8_t e2[32];
    xs_tagged(XS_TAG_CHALLENGE, rx, 32, pub_x, 32, digest, 32, e2);

    uint8_t diff = 0;
    for (int i = 0; i < 16; i++) diff |= (uint8_t)(sig[i] ^ e2[i]);
    return diff == 0;
}

bool xprssig_generate(uint8_t priv[XPRSSIG_KEY_LEN])
{
    if (!priv) return false;
    for (int attempt = 0; attempt < 8; attempt++) {
        xs_random(priv, XPRSSIG_KEY_LEN);
        if (xs_sc_valid(priv)) return true;
    }
    return false;
}

/* ── base85 (§4.3) ──────────────────────────────────────────────────────── */

static const char XS_B85[] =
    "0123456789abcdefghijklmnopqrstuvwxyz"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ.-+=^!/*?&<>()[]%$#@,;_";

int xprssig_b85_encode(const uint8_t *in, size_t len, char *out, size_t cap)
{
    if (!in || !out || (len % 4) != 0) return -1;
    size_t need = (len / 4) * 5;
    if (cap < need + 1) return -1;
    size_t o = 0;
    for (size_t i = 0; i < len; i += 4) {
        uint32_t v = ((uint32_t)in[i] << 24) | ((uint32_t)in[i + 1] << 16) |
                     ((uint32_t)in[i + 2] << 8) | in[i + 3];
        char d[5];
        for (int j = 4; j >= 0; j--) { d[j] = XS_B85[v % 85]; v /= 85; }
        for (int j = 0; j < 5; j++) out[o++] = d[j];
    }
    out[o] = 0;
    return (int)o;
}

int xprssig_b85_decode(const char *in, size_t len, uint8_t *out, size_t cap)
{
    if (!in || !out || (len % 5) != 0) return -1;
    size_t need = (len / 5) * 4;
    if (cap < need) return -1;
    size_t o = 0;
    for (size_t i = 0; i < len; i += 5) {
        uint32_t v = 0;
        for (int j = 0; j < 5; j++) {
            const char *p = strchr(XS_B85, in[i + j]);
            if (!p || !in[i + j]) return -1;
            v = v * 85 + (uint32_t)(p - XS_B85);
        }
        out[o++] = (uint8_t)(v >> 24);
        out[o++] = (uint8_t)(v >> 16);
        out[o++] = (uint8_t)(v >> 8);
        out[o++] = (uint8_t)v;
    }
    return (int)o;
}
