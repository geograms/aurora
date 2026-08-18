/*
 * Host test for XPRS signatures, against a signature reticulum-dart produced.
 *
 * The scheme is randomised, so the C side cannot reproduce Dart's bytes — it
 * must VERIFY them, which is the stronger property anyway: a verifier that
 * agrees has the curve, both tagged hashes, the even-y convention and the
 * 16-byte challenge truncation all correct.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <openssl/sha.h>

#include "xprssig.h"

static int g_checks, g_fail;
#define CHECK(cond, fmt, ...) do {                                            \
    g_checks++;                                                               \
    if (!(cond)) { g_fail++;                                                  \
        printf("  FAIL %s:%d  " fmt "\n", __func__, __LINE__, ##__VA_ARGS__); } \
} while (0)

/* ── vectors from reticulum-dart (tool/gen_sig_vectors.dart) ────────────── */
static const char *V_TEXT   = "t:service f:X3JS7Y serve:index,history,mailbox count:32";
static const char *V_SCALAR = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
static const char *V_DIGEST = "8c012bc0f0f3919ab65e7867c5b394194d1eed28c593b1ccd456ec8532650a07";
static const char *V_PUBX   = "4646ae5047316b4230d0086c8acec687f00b1cd9d1dc634f6cb358ac0a9a8fff";
static const char *V_SIG    = "3b09196bc9df9dce35f837dfc90d2ea42432274aedd128b21733174728bc5b01"
                              "b56af1ac8b424a7873cc2902b10b1b76";
static const char *V_SIGB85 = "i,^!u+(@Vmhtxb*+QG(_bR?-t[A[t*7C^>;d7<+=WqblkI+y3XBiD6mU[RH%";
static const char *V_B85IN  = "00010203fafbfcfd";
static const char *V_B85OUT = "009c6#UQi&";

/* ── the specification's own worked example (XPRS.md section 9.1.2) ─────── */
/*
 * The vectors above came from the other implementation, which is a good check
 * that two codebases agree and no check at all that either matches the
 * document. This one is the document: aux fixed to 32 zero bytes so every
 * intermediate is reproducible, and the toy key d = 7 (never sign with a toy
 * key). It is what caught both implementations still using the pre-rename
 * tagged-hash domain strings: they agreed with each other and with nothing
 * else, which is exactly what a cross-implementation vector cannot detect.
 */
static const char *W_CANON = "t:message f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 "
                             "m:net starts in ten minutes";
static const char *W_M     = "39922745225b987201d0a253ed152b99712088ba6c578a41bdfc670594a3c553";
static const char *W_PX    = "5cbdf0646e5db4eaa398f365f2ea7a0e3d419b7e0330e39ce92bddedcac4f9bc";
static const char *W_SIG   = "b40348c6defc8e1ae6dfca7635513e3b"
                             "e052dd3b72c2aab12db5d39d047de1816f15f396a402ea9d2d3407bde0dd5df8";
static const char *W_B85   = "V<-(s&U-xL(hjs8hbML0<8nw[A)a<YeW+5_1BYlWzX.)fQYP&LeI[ZC<n4Yl";

extern bool xprssig_test_zero_aux;

static size_t unhex(const char *h, uint8_t *out, size_t cap)
{
    size_t n = 0;
    for (const char *p = h; p[0] && p[1] && n < cap; p += 2) {
        unsigned v; sscanf(p, "%2x", &v); out[n++] = (uint8_t)v;
    }
    return n;
}

static void test_digest_is_what_dart_signed(void)
{
    uint8_t want[32], got[32];
    unhex(V_DIGEST, want, sizeof want);
    SHA256((const uint8_t *)V_TEXT, strlen(V_TEXT), got);
    CHECK(memcmp(got, want, 32) == 0,
          "sha256 of the signed text differs from Dart's digest");
}

static void test_public_key_matches_dart(void)
{
    uint8_t d[32], want[32], got[32];
    unhex(V_SCALAR, d, sizeof d);
    unhex(V_PUBX, want, sizeof want);
    CHECK(xprssig_public_key(d, got), "public key refused");
    CHECK(memcmp(got, want, 32) == 0, "x-only public key differs from Dart's");
}

/* Cross-implementation agreement: a signature the Dart signer produced, checked
 * here. Regenerate with `dart run tool/gen_sig_vectors.dart` in reticulum-dart
 * if either side's scheme changes -- the vectors are not hand-written and the
 * generator prints them in this order. */
static void test_verifies_dart_signature(void)
{
    uint8_t digest[32], sig[48], pub[32];
    unhex(V_DIGEST, digest, sizeof digest);
    unhex(V_SIG, sig, sizeof sig);
    unhex(V_PUBX, pub, sizeof pub);
    CHECK(xprssig_verify(digest, sig, pub),
          "a signature reticulum-dart produced did not verify");
}

static void test_our_signature_verifies(void)
{
    uint8_t d[32], digest[32], pub[32], sig[48];
    unhex(V_SCALAR, d, sizeof d);
    unhex(V_DIGEST, digest, sizeof digest);
    CHECK(xprssig_public_key(d, pub), "public key refused");
    CHECK(xprssig_sign(digest, d, sig), "signing refused");
    CHECK(xprssig_verify(digest, sig, pub), "our own signature did not verify");

    /* Randomised: two signatures over the same digest must differ, or the
     * nonce is not doing its job and the key is recoverable. */
    uint8_t sig2[48];
    CHECK(xprssig_sign(digest, d, sig2), "second signing refused");
    CHECK(memcmp(sig, sig2, 48) != 0, "two signatures were identical");
    CHECK(xprssig_verify(digest, sig2, pub), "the second did not verify");
}

static void test_rejects_what_it_should(void)
{
    uint8_t d[32], digest[32], pub[32], sig[48];
    unhex(V_SCALAR, d, sizeof d);
    unhex(V_DIGEST, digest, sizeof digest);
    xprssig_public_key(d, pub);
    xprssig_sign(digest, d, sig);

    uint8_t bad[48];
    memcpy(bad, sig, 48); bad[0] ^= 0x01;
    CHECK(!xprssig_verify(digest, bad, pub), "a tampered challenge verified");
    memcpy(bad, sig, 48); bad[47] ^= 0x01;
    CHECK(!xprssig_verify(digest, bad, pub), "a tampered scalar verified");

    uint8_t other[32];
    memcpy(other, digest, 32); other[5] ^= 0x01;
    CHECK(!xprssig_verify(other, sig, pub), "a signature verified over the wrong digest");

    uint8_t wrongpub[32];
    memcpy(wrongpub, pub, 32); wrongpub[9] ^= 0x01;
    CHECK(!xprssig_verify(digest, sig, wrongpub), "verified against the wrong key");

    uint8_t zero[32] = {0};
    CHECK(!xprssig_public_key(zero, pub), "zero accepted as a private key");
    CHECK(!xprssig_sign(digest, zero, sig), "signed with a zero key");
}

static void test_base85(void)
{
    uint8_t in[8], back[8];
    char out[16];
    size_t n = unhex(V_B85IN, in, sizeof in);
    CHECK(xprssig_b85_encode(in, n, out, sizeof out) == 10, "encode length wrong");
    CHECK(strcmp(out, V_B85OUT) == 0, "base85 differs from Dart's: %s", out);
    CHECK(xprssig_b85_decode(out, strlen(out), back, sizeof back) == (int)n,
          "decode length wrong");
    CHECK(memcmp(in, back, n) == 0, "base85 round trip corrupted the bytes");

    /* The signature's own encoding is what `sig:` carries — 48 bytes, 60
     * characters, and it must equal what Dart wrote for the same bytes. */
    uint8_t sig[48];
    char enc[80];
    unhex(V_SIG, sig, sizeof sig);
    CHECK(xprssig_b85_encode(sig, 48, enc, sizeof enc) == 60,
          "a signature did not encode to 60 characters");
    CHECK(strcmp(enc, V_SIGB85) == 0, "signature base85 differs:\n    %s\n    %s",
          enc, V_SIGB85);

    /* A character outside the alphabet is a refusal, not a wrong answer. */
    char bad[11];
    strcpy(bad, V_B85OUT);
    bad[3] = '~';
    CHECK(xprssig_b85_decode(bad, 10, back, sizeof back) == -1,
          "a character outside the alphabet decoded");
    CHECK(xprssig_b85_encode(in, 7, out, sizeof out) == -1,
          "encoded a length that is not a multiple of four");
}

static void test_the_specifications_worked_example(void)
{
    /* d = 7, big-endian in 32 bytes. */
    uint8_t d[32] = {0};
    d[31] = 7;

    uint8_t m[32];
    SHA256((const uint8_t *)W_CANON, strlen(W_CANON), m);
    uint8_t want_m[32];
    unhex(W_M, want_m, sizeof want_m);
    CHECK(memcmp(m, want_m, 32) == 0, "the canonical text does not hash to m");

    uint8_t px[32], want_px[32];
    CHECK(xprssig_public_key(d, px), "no public key for d=7");
    unhex(W_PX, want_px, sizeof want_px);
    CHECK(memcmp(px, want_px, 32) == 0, "px does not match the document");

    xprssig_test_zero_aux = true;
    uint8_t sig[XPRSSIG_LEN], want_sig[XPRSSIG_LEN];
    CHECK(xprssig_sign(m, d, sig), "signing failed");
    xprssig_test_zero_aux = false;
    unhex(W_SIG, want_sig, sizeof want_sig);
    CHECK(memcmp(sig, want_sig, XPRSSIG_LEN) == 0,
          "the signature does not reproduce the document's -- check the tagged"
          " hash domain strings (XPRS/nonce, XPRS/challenge)");

    char b85[XPRSSIG_B85_LEN + 1];
    CHECK(xprssig_b85_encode(want_sig, sizeof want_sig, b85, sizeof b85)
              == XPRSSIG_B85_LEN, "encode length");
    CHECK(strcmp(b85, W_B85) == 0, "base85 differs:\n  got  %s\n  want %s",
          b85, W_B85);

    CHECK(xprssig_verify(m, want_sig, want_px), "cannot verify the document");
}

/* The tags are hashed into the challenge, so they are as much a part of the
 * wire format as the curve is. This verifier briefly tried the pre-rename
 * challenge string after the current one, so that already-signed data kept
 * validating; that fallback has been removed and this stands in its place.
 *
 * The vector is a real signature made under the old strings. Nothing produced
 * that way verifies any more -- and here that means DISCARDED, not merely
 * unbadged: the archive drops forged packets at flush and the courier drops
 * forged carried mail. */
static void test_a_pre_rename_signature_no_longer_verifies(void)
{
    static const char *OLD_DIGEST =
        "8c012bc0f0f3919ab65e7867c5b394194d1eed28c593b1ccd456ec8532650a07";
    static const char *OLD_PUBX =
        "4646ae5047316b4230d0086c8acec687f00b1cd9d1dc634f6cb358ac0a9a8fff";
    static const char *OLD_SIG =
        "fad545192d362ec74b79a6c621ea8169afce898c6f45ddf3080bd258d29108a7"
        "fca82021d4ecc12aa033e53715176bf3";

    uint8_t digest[32], sig[XPRSSIG_LEN], pub[32];
    unhex(OLD_DIGEST, digest, sizeof digest);
    unhex(OLD_SIG, sig, sizeof sig);
    unhex(OLD_PUBX, pub, sizeof pub);
    CHECK(!xprssig_verify(digest, sig, pub),
          "a fallback to a second challenge string has come back");
}

int main(void)
{
    printf("xprssig host tests (signature from reticulum-dart)\n");
    test_digest_is_what_dart_signed();
    test_public_key_matches_dart();
    test_verifies_dart_signature();
    test_our_signature_verifies();
    test_rejects_what_it_should();
    test_base85();
    test_the_specifications_worked_example();
    test_a_pre_rename_signature_no_longer_verifies();
    printf("%d checks, %d failed\n", g_checks, g_fail);
    return g_fail ? 1 : 0;
}
