/*
 * Host test for the RNS codec, against vectors the DART implementation
 * produced (reticulum-dart, tool/gen_rns_vectors.dart).
 *
 * This is the whole point of the file: two implementations agreeing on their
 * own output proves nothing, so every crypto assertion below is a byte string
 * that came out of the other one. If the ESP32 and Aurora ever stop
 * understanding each other, it should fail here rather than on a rooftop.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>

#include "rns.h"

/* TweetNaCl asks the application for entropy. The device has esp_fill_random;
 * here the values only need to be different from each other. */
void randombytes(unsigned char *p, unsigned long long n)
{
    for (unsigned long long i = 0; i < n; i++) p[i] = (unsigned char)(rand() & 0xFF);
}

static int g_checks, g_fail;
#define CHECK(cond, fmt, ...) do {                                            \
    g_checks++;                                                               \
    if (!(cond)) {                                                            \
        g_fail++;                                                             \
        printf("  FAIL %s:%d  " fmt "\n", __func__, __LINE__, ##__VA_ARGS__); \
    }                                                                         \
} while (0)

/* ── the vectors ────────────────────────────────────────────────────────── */

/* private key = x25519_prv(32) || ed25519_prv(32) */
static const char *V_PRV =
    "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
    "404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f";
/* the X25519 public half Dart derived from it */
static const char *V_XPUB =
    "07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c";
/* SHA-256(public)[:16] — used below as the HKDF salt, exactly as RNS does */
static const char *V_HASH = "57df59090787a31a08a224049f9a9113";
/* hkdf(64, ikm="shared-secret", salt=hash) */
static const char *V_HKDF =
    "f01af99a2da1d4e46ec868a1f39713f99231eb875428bc16ea95ef68550e8d4c"
    "964a198d341cc90dfb1f132a742930beb5c3b2005853b6ec0dd9f6f6f11e63fc";
static const char *V_PLAIN =
    "743a7761726e696e6720663a5833524c5937206b696e643a66697265207365763a64616e676572";
/* eph_pub(32) || iv(16) || AES-256-CBC(PKCS7(plain)) || HMAC(32) */
static const char *V_CIPHER =
    "605a725d2a4adfeeb1a29e17edd621c1b7593ee8cdbc44ac6c4ab6e2f805d23c"
    "101112131415161718191a1b1c1d1e1f"
    "4e7959df62edbf70ddb827a83b6ce27bf5d4b0a910420b4ac57a50f40172a43e"
    "c637e5073dd40bb44be597f390afcf17"
    "0538f66540d015ec0aa235766a7c06f163fd5ecea6c9b0a0b6e37b8407de6b85";

static size_t unhex(const char *h, uint8_t *out, size_t cap)
{
    size_t n = 0;
    for (const char *p = h; p[0] && p[1] && n < cap; p += 2) {
        unsigned v;
        sscanf(p, "%2x", &v);
        out[n++] = (uint8_t)v;
    }
    return n;
}

static void hexdump(const char *label, const uint8_t *b, size_t n)
{
    printf("    %s ", label);
    for (size_t i = 0; i < n; i++) printf("%02x", b[i]);
    printf("\n");
}

/* ── what Dart says the primitives must produce ─────────────────────────── */

static void test_x25519_matches_dart(void)
{
    uint8_t prv[64], want[32], got[32];
    unhex(V_PRV, prv, sizeof prv);
    unhex(V_XPUB, want, sizeof want);
    rns_x25519_base(prv, got);
    CHECK(memcmp(got, want, 32) == 0, "X25519 public half differs from Dart's");
    if (memcmp(got, want, 32) != 0) { hexdump("got ", got, 32); hexdump("want", want, 32); }
}

static void test_hkdf_matches_dart(void)
{
    uint8_t salt[16], want[64], got[64];
    unhex(V_HASH, salt, sizeof salt);
    unhex(V_HKDF, want, sizeof want);
    const char *ikm = "shared-secret";
    CHECK(rns_hkdf(got, sizeof got, (const uint8_t *)ikm, strlen(ikm),
                   salt, sizeof salt), "hkdf refused");
    CHECK(memcmp(got, want, 64) == 0, "HKDF output differs from Dart's");
    if (memcmp(got, want, 64) != 0) { hexdump("got ", got, 64); hexdump("want", want, 64); }
}

/* ── the real interop test: read what Dart wrote ────────────────────────── */

static void test_decrypt_dart_ciphertext(void)
{
    uint8_t prv[64], salt[16], cipher[256], want[128], got[256];
    unhex(V_PRV, prv, sizeof prv);
    unhex(V_HASH, salt, sizeof salt);
    size_t clen = unhex(V_CIPHER, cipher, sizeof cipher);
    size_t wlen = unhex(V_PLAIN, want, sizeof want);

    CHECK(clen == 128, "vector length %zu", clen);
    int n = rns_decrypt_from(prv, salt, cipher, clen, got, sizeof got);
    CHECK(n == (int)wlen, "decrypted %d bytes, wanted %zu", n, wlen);
    if (n == (int)wlen) {
        CHECK(memcmp(got, want, wlen) == 0, "plaintext differs");
        printf("    decrypted: %.*s\n", n, (const char *)got);
    }
}

/* ── and write what Dart would read ─────────────────────────────────────── */

static void test_encrypt_reproduces_dart(void)
{
    uint8_t prv[64], xpub[32], salt[16], plain[128], want[256], got[256];
    unhex(V_PRV, prv, sizeof prv);
    unhex(V_XPUB, xpub, sizeof xpub);
    unhex(V_HASH, salt, sizeof salt);
    size_t plen = unhex(V_PLAIN, plain, sizeof plain);
    size_t wlen = unhex(V_CIPHER, want, sizeof want);

    /* The same ephemeral key and IV Dart was given, so the bytes are
     * comparable — production passes NULL for both. */
    uint8_t eph[32], iv[16];
    for (int i = 0; i < 32; i++) eph[i] = (uint8_t)(0xA0 + i);
    for (int i = 0; i < 16; i++) iv[i] = (uint8_t)(0x10 + i);

    int n = rns_encrypt_to(xpub, salt, plain, plen, eph, iv, got, sizeof got);
    CHECK(n == (int)wlen, "produced %d bytes, Dart produced %zu", n, wlen);
    if (n == (int)wlen) {
        CHECK(memcmp(got, want, wlen) == 0, "ciphertext differs from Dart's");
        if (memcmp(got, want, wlen) != 0) {
            hexdump("got ", got, wlen);
            hexdump("want", want, wlen);
        }
    }
}

static void test_round_trip_random(void)
{
    uint8_t prv[64], xpub[32], salt[16];
    unhex(V_PRV, prv, sizeof prv);
    unhex(V_XPUB, xpub, sizeof xpub);
    unhex(V_HASH, salt, sizeof salt);

    /* Lengths around the block boundary, where PKCS7 is easiest to get wrong. */
    const size_t lens[] = { 1, 15, 16, 17, 31, 32, 33, 250 };
    for (size_t i = 0; i < sizeof lens / sizeof lens[0]; i++) {
        uint8_t plain[300], cipher[512], back[512];
        for (size_t k = 0; k < lens[i]; k++) plain[k] = (uint8_t)(k * 7 + i);
        int n = rns_encrypt_to(xpub, salt, plain, lens[i], NULL, NULL,
                               cipher, sizeof cipher);
        CHECK(n > 0, "encrypt refused %zu bytes", lens[i]);
        int m = rns_decrypt_from(prv, salt, cipher, (size_t)n, back, sizeof back);
        CHECK(m == (int)lens[i], "round trip of %zu came back %d", lens[i], m);
        if (m == (int)lens[i]) {
            CHECK(memcmp(plain, back, lens[i]) == 0, "round trip corrupted %zu", lens[i]);
        }
    }
}

static void test_forgery_is_refused(void)
{
    uint8_t prv[64], xpub[32], salt[16], cipher[256], back[256];
    unhex(V_PRV, prv, sizeof prv);
    unhex(V_XPUB, xpub, sizeof xpub);
    unhex(V_HASH, salt, sizeof salt);
    const char *msg = "t:message f:X1QZ3N d:X1RD89 m:meet at six";
    int n = rns_encrypt_to(xpub, salt, (const uint8_t *)msg, strlen(msg),
                           NULL, NULL, cipher, sizeof cipher);
    CHECK(n > 0, "encrypt refused");

    cipher[n - 40] ^= 0x01;            /* one bit, inside the ciphertext */
    CHECK(rns_decrypt_from(prv, salt, cipher, (size_t)n, back, sizeof back) < 0,
          "a tampered token decrypted");

    cipher[n - 40] ^= 0x01;            /* undo, then break the MAC itself */
    cipher[n - 1] ^= 0x01;
    CHECK(rns_decrypt_from(prv, salt, cipher, (size_t)n, back, sizeof back) < 0,
          "a tampered MAC was accepted");
}

/* ── addressing ─────────────────────────────────────────────────────────── */

static void test_addressing(void)
{
    uint8_t nh[RNS_NAME_HASH_LEN], nh2[RNS_NAME_HASH_LEN];
    const char *aspects[] = { "xprs", "index" };
    rns_name_hash("geogram", aspects, 2, nh);
    rns_name_hash("geogram", aspects, 2, nh2);
    CHECK(memcmp(nh, nh2, sizeof nh) == 0, "name hash is not stable");

    const char *other[] = { "xprs", "indez" };
    rns_name_hash("geogram", other, 2, nh2);
    CHECK(memcmp(nh, nh2, sizeof nh) != 0, "one letter did not change the name hash");

    uint8_t idh[RNS_HASH_LEN], dest[RNS_HASH_LEN], dest2[RNS_HASH_LEN];
    unhex(V_HASH, idh, sizeof idh);
    rns_destination_hash(nh, idh, dest);
    rns_destination_hash(nh, idh, dest2);
    CHECK(memcmp(dest, dest2, sizeof dest) == 0, "destination hash is not stable");
}

/* ── HDLC ───────────────────────────────────────────────────────────────── */

static int g_frames;
static uint8_t g_last[RNS_MTU + 64];
static size_t g_last_len;
static void on_frame(const uint8_t *f, size_t n, void *ctx)
{
    (void)ctx;
    g_frames++;
    g_last_len = n > sizeof g_last ? sizeof g_last : n;
    memcpy(g_last, f, g_last_len);
}

static void test_hdlc(void)
{
    /* A payload carrying both bytes that must be escaped. */
    const uint8_t payload[] = { 0x01, RNS_HDLC_FLAG, 0x02, RNS_HDLC_ESC, 0x03 };
    uint8_t framed[64];
    int n = rns_hdlc_frame(payload, sizeof payload, framed, sizeof framed);
    CHECK(n == (int)sizeof payload + 2 + 2, "framed length %d", n);
    CHECK(framed[0] == RNS_HDLC_FLAG && framed[n - 1] == RNS_HDLC_FLAG,
          "frame is not delimited");
    for (int i = 1; i < n - 1; i++) {
        CHECK(framed[i] != RNS_HDLC_FLAG, "an unescaped flag survived at %d", i);
    }

    rns_hdlc_rx_t rx;
    rns_hdlc_rx_init(&rx);
    g_frames = 0;
    rns_hdlc_rx_feed(&rx, framed, (size_t)n, on_frame, NULL);
    CHECK(g_frames == 1, "reassembled %d frames", g_frames);
    CHECK(g_last_len == sizeof payload &&
          memcmp(g_last, payload, sizeof payload) == 0, "payload came back wrong");

    /* The same frame delivered one byte at a time — TCP gives no boundaries. */
    rns_hdlc_rx_init(&rx);
    g_frames = 0;
    for (int i = 0; i < n; i++) rns_hdlc_rx_feed(&rx, &framed[i], 1, on_frame, NULL);
    CHECK(g_frames == 1, "byte-at-a-time gave %d frames", g_frames);
    CHECK(memcmp(g_last, payload, sizeof payload) == 0, "byte-at-a-time corrupted it");

    /* Two frames back to back, sharing a flag. */
    uint8_t two[128];
    memcpy(two, framed, (size_t)n);
    memcpy(two + n, framed, (size_t)n);
    rns_hdlc_rx_init(&rx);
    g_frames = 0;
    rns_hdlc_rx_feed(&rx, two, (size_t)n * 2, on_frame, NULL);
    CHECK(g_frames == 2, "back-to-back gave %d frames", g_frames);
}

/* ── packet header ──────────────────────────────────────────────────────── */

static void test_packet_header(void)
{
    uint8_t dest[RNS_HASH_LEN];
    unhex(V_HASH, dest, sizeof dest);
    const uint8_t body[] = "payload";

    rns_packet_t p = {
        .header_type = RNS_HEADER_1,
        .transport_type = RNS_TRANSPORT_BROADCAST,
        .dest_type = RNS_DEST_SINGLE,
        .packet_type = RNS_PACKET_DATA,
        .hops = 0,
        .context = 0,
        .data = body,
        .data_len = sizeof body - 1,
    };
    memcpy(p.dest, dest, sizeof dest);

    uint8_t wire[64];
    int n = rns_packet_build(&p, wire, sizeof wire);
    CHECK(n == 3 + RNS_HASH_LEN + (int)(sizeof body - 1), "built %d bytes", n);
    CHECK(wire[0] == 0x00, "flags for a broadcast DATA/SINGLE packet: %02x", wire[0]);

    rns_packet_t q;
    CHECK(rns_packet_parse(wire, (size_t)n, &q), "did not parse back");
    CHECK(q.packet_type == RNS_PACKET_DATA && q.dest_type == RNS_DEST_SINGLE,
          "types came back wrong");
    CHECK(memcmp(q.dest, dest, sizeof dest) == 0, "destination came back wrong");
    CHECK(q.data_len == sizeof body - 1 &&
          memcmp(q.data, body, q.data_len) == 0, "payload came back wrong");

    /* An announce sets the packet type in the low bits. */
    p.packet_type = RNS_PACKET_ANNOUNCE;
    n = rns_packet_build(&p, wire, sizeof wire);
    CHECK(n > 0 && (wire[0] & 0x03) == RNS_PACKET_ANNOUNCE, "announce flags wrong");

    /* HEADER_2, as every announce a hub relays arrives: a transport id sits
     * before the destination, and reading it as HEADER_1 attributes the packet
     * to the wrong address entirely. */
    uint8_t tid[RNS_HASH_LEN];
    for (int i = 0; i < RNS_HASH_LEN; i++) tid[i] = (uint8_t)(0xC0 + i);
    uint8_t h2[96];
    h2[0] = (uint8_t)((RNS_HEADER_2 << 6) | RNS_PACKET_ANNOUNCE);
    h2[1] = 3;                                   /* hops, as a relay sets */
    memcpy(h2 + 2, tid, RNS_HASH_LEN);
    memcpy(h2 + 2 + RNS_HASH_LEN, dest, RNS_HASH_LEN);
    h2[2 + 2 * RNS_HASH_LEN] = 0;
    memcpy(h2 + 3 + 2 * RNS_HASH_LEN, body, sizeof body - 1);
    size_t h2len = 3 + 2 * RNS_HASH_LEN + sizeof body - 1;

    CHECK(rns_packet_parse(h2, h2len, &q), "HEADER_2 was refused");
    CHECK(q.header_type == RNS_HEADER_2, "header type wrong");
    CHECK(q.have_transport_id && memcmp(q.transport_id, tid, sizeof tid) == 0,
          "transport id came back wrong");
    CHECK(memcmp(q.dest, dest, RNS_HASH_LEN) == 0,
          "destination read from the transport id's position");
    CHECK(q.hops == 3, "hops came back %u", q.hops);
    CHECK(q.data_len == sizeof body - 1 &&
          memcmp(q.data, body, q.data_len) == 0, "HEADER_2 payload wrong");

    /* A truncated HEADER_2 must be refused, not read into the next field. */
    CHECK(!rns_packet_parse(h2, 3 + RNS_HASH_LEN, &q), "short HEADER_2 accepted");
}

int main(void)
{
    printf("rns host tests (vectors from reticulum-dart)\n");
    test_x25519_matches_dart();
    test_hkdf_matches_dart();
    test_decrypt_dart_ciphertext();
    test_encrypt_reproduces_dart();
    test_round_trip_random();
    test_forgery_is_refused();
    test_addressing();
    test_hdlc();
    test_packet_header();
    printf("%d checks, %d failed\n", g_checks, g_fail);
    return g_fail ? 1 : 0;
}
