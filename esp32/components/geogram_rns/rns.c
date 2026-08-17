/*
 * Reticulum, the part of it a station needs — see rns.h.
 *
 * The protocol logic here is shared by the device and the host harness; only
 * the primitives differ (mbedtls on the ESP32, OpenSSL in the harness), and the
 * vectors in test_rns_host.c come from the Dart implementation, so a wrong
 * wrapper on either side is caught rather than shipped.
 */

#include "rns.h"

#include <string.h>
#include <stdlib.h>

/* X25519 comes from TweetNaCl either way: it is the fiddliest primitive to get
 * two libraries agreeing on, so both sides run the same code.
 *
 * Declared under the names the object file actually exports. TweetNaCl's header
 * renames the API through macros (crypto_scalarmult ->
 * crypto_scalarmult_curve25519_tweet), and that header lives in the rns_ble5
 * sources rather than in a component, which a component has no business
 * reaching into. */
extern int crypto_scalarmult_curve25519_tweet(unsigned char *q,
                                              const unsigned char *n,
                                              const unsigned char *p);
extern int crypto_scalarmult_curve25519_tweet_base(unsigned char *q,
                                                   const unsigned char *n);
#define rns_nacl_scalarmult      crypto_scalarmult_curve25519_tweet
#define rns_nacl_scalarmult_base crypto_scalarmult_curve25519_tweet_base

#ifdef RNS_HOST_TEST
#include <openssl/sha.h>
#include <openssl/hmac.h>
#include <openssl/evp.h>

void rns_sha256(const uint8_t *in, size_t len, uint8_t out[32])
{
    SHA256(in, len, out);
}

void rns_hmac_sha256(const uint8_t *key, size_t keylen,
                     const uint8_t *in, size_t len, uint8_t out[32])
{
    unsigned int n = 32;
    HMAC(EVP_sha256(), key, (int)keylen, in, len, out, &n);
}

/* Raw AES-256-CBC, no padding — the padding is PKCS7 and is done below so both
 * backends pad identically. */
static bool aes_cbc(const uint8_t key[32], const uint8_t iv[16], bool encrypt,
                    const uint8_t *in, size_t len, uint8_t *out)
{
    EVP_CIPHER_CTX *c = EVP_CIPHER_CTX_new();
    if (!c) return false;
    int outl = 0, ok;
    ok = encrypt ? EVP_EncryptInit_ex(c, EVP_aes_256_cbc(), NULL, key, iv)
                 : EVP_DecryptInit_ex(c, EVP_aes_256_cbc(), NULL, key, iv);
    if (ok == 1) EVP_CIPHER_CTX_set_padding(c, 0);
    if (ok == 1) {
        ok = encrypt ? EVP_EncryptUpdate(c, out, &outl, in, (int)len)
                     : EVP_DecryptUpdate(c, out, &outl, in, (int)len);
    }
    EVP_CIPHER_CTX_free(c);
    return ok == 1 && (size_t)outl == len;
}

static void rns_random(uint8_t *out, size_t len)
{
    for (size_t i = 0; i < len; i++) out[i] = (uint8_t)(rand() & 0xFF);
}

#else /* on the device */

#include "mbedtls/sha256.h"
#include "mbedtls/md.h"
#include "mbedtls/aes.h"
#include "esp_random.h"

void rns_sha256(const uint8_t *in, size_t len, uint8_t out[32])
{
    mbedtls_sha256(in, len, out, 0);
}

void rns_hmac_sha256(const uint8_t *key, size_t keylen,
                     const uint8_t *in, size_t len, uint8_t out[32])
{
    const mbedtls_md_info_t *md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    mbedtls_md_hmac(md, key, keylen, in, len, out);
}

static bool aes_cbc(const uint8_t key[32], const uint8_t iv[16], bool encrypt,
                    const uint8_t *in, size_t len, uint8_t *out)
{
    mbedtls_aes_context ctx;
    uint8_t iv_copy[16];
    memcpy(iv_copy, iv, 16);
    mbedtls_aes_init(&ctx);
    int rc = encrypt ? mbedtls_aes_setkey_enc(&ctx, key, 256)
                     : mbedtls_aes_setkey_dec(&ctx, key, 256);
    if (rc == 0) {
        rc = mbedtls_aes_crypt_cbc(&ctx,
                                   encrypt ? MBEDTLS_AES_ENCRYPT : MBEDTLS_AES_DECRYPT,
                                   len, iv_copy, in, out);
    }
    mbedtls_aes_free(&ctx);
    return rc == 0;
}

static void rns_random(uint8_t *out, size_t len)
{
    esp_fill_random(out, len);
}
#endif

/* ── HKDF (RNS's variant — see rns.h) ───────────────────────────────────── */

bool rns_hkdf(uint8_t *out, size_t out_len,
              const uint8_t *ikm, size_t ikm_len,
              const uint8_t *salt, size_t salt_len)
{
    if (!out || out_len < 1 || !ikm || ikm_len == 0) return false;

    uint8_t zero_salt[32] = {0};
    if (!salt || salt_len == 0) { salt = zero_salt; salt_len = sizeof zero_salt; }

    uint8_t prk[32];
    rns_hmac_sha256(salt, salt_len, ikm, ikm_len, prk);

    uint8_t block[32];
    size_t have = 0;
    int blocks = (int)((out_len + 31) / 32);
    for (int i = 0; i < blocks; i++) {
        /* input = previous block (empty on the first round) || counter */
        uint8_t in[33];
        size_t in_len = 0;
        if (i > 0) { memcpy(in, block, 32); in_len = 32; }
        in[in_len++] = (uint8_t)((i + 1) % 256);
        rns_hmac_sha256(prk, sizeof prk, in, in_len, block);
        size_t take = (out_len - have) < 32 ? (out_len - have) : 32;
        memcpy(out + have, block, take);
        have += take;
    }
    return true;
}

void rns_x25519_base(const uint8_t priv[32], uint8_t pub_out[32])
{
    rns_nacl_scalarmult_base(pub_out, priv);
}

void rns_x25519_shared(const uint8_t priv[32], const uint8_t peer_pub[32],
                       uint8_t shared_out[32])
{
    rns_nacl_scalarmult(shared_out, priv, peer_pub);
}

/* ── Identity and addressing ────────────────────────────────────────────── */

void rns_identity_init(const uint8_t *prv, const uint8_t pub[RNS_PUB_LEN],
                       rns_identity_t *out)
{
    if (!pub || !out) return;
    memset(out, 0, sizeof *out);
    memcpy(out->pub, pub, RNS_PUB_LEN);
    if (prv) {
        memcpy(out->prv, prv, RNS_PRV_LEN);
        out->have_private = true;
        /* The X25519 half must agree with the private key, or everything
         * addressed to us decrypts to nothing. Cheap to check, and a silent
         * mismatch here is unfindable later. */
        uint8_t derived[32];
        rns_x25519_base(prv, derived);
        if (memcmp(derived, pub, 32) != 0) memcpy(out->pub, derived, 32);
    }
    uint8_t full[32];
    rns_sha256(out->pub, RNS_PUB_LEN, full);
    memcpy(out->hash, full, RNS_HASH_LEN);
}

void rns_identity_from_public(const uint8_t pub[RNS_PUB_LEN],
                              rns_identity_t *out)
{
    if (!pub || !out) return;
    memset(out, 0, sizeof *out);
    memcpy(out->pub, pub, RNS_PUB_LEN);
    uint8_t full[32];
    rns_sha256(out->pub, RNS_PUB_LEN, full);
    memcpy(out->hash, full, RNS_HASH_LEN);
}

void rns_name_hash(const char *app, const char *const *aspects, int naspects,
                   uint8_t out[RNS_NAME_HASH_LEN])
{
    char name[160];
    size_t n = 0;
    for (const char *a = app; a && *a && n + 1 < sizeof name; a++) name[n++] = *a;
    for (int i = 0; i < naspects && aspects; i++) {
        if (n + 1 < sizeof name) name[n++] = '.';
        for (const char *a = aspects[i]; a && *a && n + 1 < sizeof name; a++) {
            name[n++] = *a;
        }
    }
    name[n] = 0;
    uint8_t full[32];
    rns_sha256((const uint8_t *)name, n, full);
    memcpy(out, full, RNS_NAME_HASH_LEN);
}

void rns_destination_hash(const uint8_t name_hash[RNS_NAME_HASH_LEN],
                          const uint8_t identity_hash[RNS_HASH_LEN],
                          uint8_t out[RNS_HASH_LEN])
{
    uint8_t buf[RNS_NAME_HASH_LEN + RNS_HASH_LEN];
    memcpy(buf, name_hash, RNS_NAME_HASH_LEN);
    memcpy(buf + RNS_NAME_HASH_LEN, identity_hash, RNS_HASH_LEN);
    uint8_t full[32];
    rns_sha256(buf, sizeof buf, full);
    memcpy(out, full, RNS_HASH_LEN);
}

/* ── Encrypted single packets ───────────────────────────────────────────── */

int rns_encrypt_to(const uint8_t peer_x25519_pub[32],
                   const uint8_t salt[RNS_HASH_LEN],
                   const uint8_t *plain, size_t plain_len,
                   const uint8_t *eph_priv, const uint8_t *iv,
                   uint8_t *out, size_t out_cap)
{
    if (!peer_x25519_pub || !plain || !out) return -1;
    size_t padded = ((plain_len / 16) + 1) * 16;          /* PKCS7 always pads */
    if (out_cap < RNS_ENC_OVERHEAD + padded) return -1;

    uint8_t eph[32], the_iv[16];
    if (eph_priv) memcpy(eph, eph_priv, 32); else rns_random(eph, 32);
    if (iv) memcpy(the_iv, iv, 16); else rns_random(the_iv, 16);

    uint8_t *p = out;
    rns_x25519_base(eph, p);                              /* eph pub */
    uint8_t shared[32];
    rns_x25519_shared(eph, peer_x25519_pub, shared);
    uint8_t derived[64];
    if (!rns_hkdf(derived, sizeof derived, shared, sizeof shared,
                  salt, RNS_HASH_LEN)) {
        return -1;
    }
    p += 32;
    memcpy(p, the_iv, 16);

    /* PKCS7: the pad byte is the pad length, and a whole block is added when
     * the plaintext already fits exactly. */
    uint8_t padbuf[RNS_MTU + 32];
    if (padded > sizeof padbuf) return -1;
    memcpy(padbuf, plain, plain_len);
    uint8_t padval = (uint8_t)(padded - plain_len);
    memset(padbuf + plain_len, padval, padded - plain_len);

    if (!aes_cbc(derived + 32, the_iv, true, padbuf, padded, p + 16)) return -1;

    /* HMAC covers iv || ciphertext, with the FIRST half of the derived key. */
    rns_hmac_sha256(derived, 32, p, 16 + padded, p + 16 + padded);
    return (int)(32 + 16 + padded + RNS_MAC_LEN);
}

int rns_decrypt_from(const uint8_t our_x25519_priv[32],
                     const uint8_t salt[RNS_HASH_LEN],
                     const uint8_t *in, size_t in_len,
                     uint8_t *out, size_t out_cap)
{
    if (!our_x25519_priv || !in || !out) return -1;
    if (in_len < RNS_ENC_OVERHEAD + 16) return -1;

    const uint8_t *eph_pub = in;
    const uint8_t *token = in + 32;
    size_t token_len = in_len - 32;
    size_t ct_len = token_len - 16 - RNS_MAC_LEN;
    if (ct_len == 0 || (ct_len % 16) != 0) return -1;

    uint8_t shared[32], derived[64];
    rns_x25519_shared(our_x25519_priv, eph_pub, shared);
    if (!rns_hkdf(derived, sizeof derived, shared, sizeof shared,
                  salt, RNS_HASH_LEN)) {
        return -1;
    }

    /* Verify before decrypting: a forged token should cost nothing but a
     * comparison, and must never reach the cipher. */
    uint8_t mac[32];
    rns_hmac_sha256(derived, 32, token, 16 + ct_len, mac);
    uint8_t diff = 0;
    for (int i = 0; i < 32; i++) diff |= mac[i] ^ token[16 + ct_len + i];
    if (diff) return -1;

    uint8_t plain[RNS_MTU + 32];
    if (ct_len > sizeof plain) return -1;
    if (!aes_cbc(derived + 32, token, false, token + 16, ct_len, plain)) return -1;

    uint8_t pad = plain[ct_len - 1];
    if (pad == 0 || pad > 16 || pad > ct_len) return -1;
    for (uint8_t i = 0; i < pad; i++) {
        if (plain[ct_len - 1 - i] != pad) return -1;
    }
    size_t plain_len = ct_len - pad;
    if (plain_len > out_cap) return -1;
    memcpy(out, plain, plain_len);
    return (int)plain_len;
}

/* ── HDLC ───────────────────────────────────────────────────────────────── */

int rns_hdlc_frame(const uint8_t *in, size_t len, uint8_t *out, size_t out_cap)
{
    if (!in || !out) return -1;
    size_t n = 0;
    if (n >= out_cap) return -1;
    out[n++] = RNS_HDLC_FLAG;
    for (size_t i = 0; i < len; i++) {
        uint8_t b = in[i];
        if (b == RNS_HDLC_FLAG || b == RNS_HDLC_ESC) {
            if (n + 2 > out_cap) return -1;
            out[n++] = RNS_HDLC_ESC;
            out[n++] = b ^ RNS_HDLC_MASK;
        } else {
            if (n + 1 > out_cap) return -1;
            out[n++] = b;
        }
    }
    if (n + 1 > out_cap) return -1;
    out[n++] = RNS_HDLC_FLAG;
    return (int)n;
}

void rns_hdlc_rx_init(rns_hdlc_rx_t *rx)
{
    if (rx) memset(rx, 0, sizeof *rx);
}

void rns_hdlc_rx_feed(rns_hdlc_rx_t *rx, const uint8_t *in, size_t len,
                      void (*cb)(const uint8_t *frame, size_t len, void *ctx),
                      void *ctx)
{
    if (!rx || !in) return;
    for (size_t i = 0; i < len; i++) {
        uint8_t b = in[i];
        if (b == RNS_HDLC_FLAG) {
            /* A flag both ends the frame in progress and starts the next, so a
             * stream of back-to-back frames needs no separator handling. */
            if (rx->in_frame && rx->len > 0 && cb) cb(rx->buf, rx->len, ctx);
            rx->in_frame = true;
            rx->escaped = false;
            rx->len = 0;
            continue;
        }
        if (!rx->in_frame) continue;              /* junk before the first flag */
        if (b == RNS_HDLC_ESC) { rx->escaped = true; continue; }
        if (rx->escaped) { b ^= RNS_HDLC_MASK; rx->escaped = false; }
        if (rx->len >= sizeof rx->buf) {
            /* Dropped whole rather than truncated: half a packet can parse as
             * a valid shorter one, which is worse than losing it. */
            rx->in_frame = false;
            rx->len = 0;
            rx->dropped++;
            continue;
        }
        rx->buf[rx->len++] = b;
    }
}

/* ── Packet header ──────────────────────────────────────────────────────── */

int rns_packet_build(const rns_packet_t *p, uint8_t *out, size_t out_cap)
{
    if (!p || !out) return -1;
    size_t need = 1 + 1 + RNS_HASH_LEN + 1 + p->data_len;
    if (out_cap < need) return -1;
    out[0] = (uint8_t)((p->header_type << 6) | (p->context_flag << 5) |
                       (p->transport_type << 4) | (p->dest_type << 2) |
                       p->packet_type);
    out[1] = p->hops;
    memcpy(out + 2, p->dest, RNS_HASH_LEN);
    out[2 + RNS_HASH_LEN] = p->context;
    if (p->data_len && p->data) {
        memcpy(out + 3 + RNS_HASH_LEN, p->data, p->data_len);
    }
    return (int)need;
}

bool rns_packet_parse(const uint8_t *in, size_t len, rns_packet_t *out)
{
    if (!in || !out || len < 3 + RNS_HASH_LEN) return false;
    memset(out, 0, sizeof *out);
    out->header_type    = (in[0] >> 6) & 0x03;
    out->context_flag   = (in[0] >> 5) & 0x01;
    out->transport_type = (in[0] >> 4) & 0x01;
    out->dest_type      = (in[0] >> 2) & 0x03;
    out->packet_type    = in[0] & 0x03;
    out->hops = in[1];

    /* HEADER_2 puts the relaying transport node's id before the destination.
     * Everything a hub relays looks like this, so reading only HEADER_1 means
     * hearing nothing from beyond the local link. */
    size_t off = 2;
    if (out->header_type == RNS_HEADER_2) {
        if (len < 3 + 2 * RNS_HASH_LEN) return false;
        memcpy(out->transport_id, in + off, RNS_HASH_LEN);
        out->have_transport_id = true;
        off += RNS_HASH_LEN;
    }
    memcpy(out->dest, in + off, RNS_HASH_LEN);
    off += RNS_HASH_LEN;
    out->context = in[off++];
    out->data = in + off;
    out->data_len = len - off;
    return true;
}
