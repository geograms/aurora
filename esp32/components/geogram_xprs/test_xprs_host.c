/*
 * Host-side test for xprs.c — the C twin of aurora's test/xprs_packet_test.dart.
 *
 * Replays test/xprs_corpus.json (every example in docs/XPRS.md, identifiers
 * cross-checked against an independent Python implementation): every wire must
 * parse, re-encode byte-exact, byte-count exact, and derive the corpus
 * identifier. Then the transport vocabulary: the section-13 via: ladder keeps
 * one identity across hops, loops and spent budgets refuse, urgency, scope and
 * station tests match the Dart.
 *
 * Run: ./test_xprs_host.sh   (converts the corpus and gcc-compiles this file;
 * never built into the firmware — see CMakeLists.txt).
 */
#include "xprs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- minimal SHA-256 (public-domain style, host only) -------------------- */
static const uint32_t K[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,
    0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,
    0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,
    0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,
    0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,
    0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,
    0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,
    0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,
    0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2 };
#define ROR(x,n) (((x) >> (n)) | ((x) << (32 - (n))))
void xprs_sha256(const uint8_t *in, size_t len, uint8_t out[32])
{
    uint32_t h[8] = { 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
                      0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19 };
    size_t total = len + 9;                 /* 0x80 + 8-byte length */
    size_t blocks = (total + 63) / 64;
    for (size_t b = 0; b < blocks; b++) {
        uint8_t chunk[64];
        for (int i = 0; i < 64; i++) {
            size_t pos = b * 64 + i;
            if (pos < len) chunk[i] = in[pos];
            else if (pos == len) chunk[i] = 0x80;
            else if (pos >= blocks * 64 - 8) {
                uint64_t bits = (uint64_t)len * 8;
                chunk[i] = (uint8_t)(bits >> (8 * (blocks * 64 - 1 - pos)));
            } else chunk[i] = 0;
        }
        uint32_t w[64];
        for (int i = 0; i < 16; i++)
            w[i] = (uint32_t)chunk[i*4] << 24 | (uint32_t)chunk[i*4+1] << 16 |
                   (uint32_t)chunk[i*4+2] << 8 | chunk[i*4+3];
        for (int i = 16; i < 64; i++) {
            uint32_t s0 = ROR(w[i-15],7) ^ ROR(w[i-15],18) ^ (w[i-15] >> 3);
            uint32_t s1 = ROR(w[i-2],17) ^ ROR(w[i-2],19) ^ (w[i-2] >> 10);
            w[i] = w[i-16] + s0 + w[i-7] + s1;
        }
        uint32_t a=h[0],bb=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
        for (int i = 0; i < 64; i++) {
            uint32_t S1 = ROR(e,6) ^ ROR(e,11) ^ ROR(e,25);
            uint32_t ch = (e & f) ^ (~e & g);
            uint32_t t1 = hh + S1 + ch + K[i] + w[i];
            uint32_t S0 = ROR(a,2) ^ ROR(a,13) ^ ROR(a,22);
            uint32_t mj = (a & bb) ^ (a & c) ^ (bb & c);
            uint32_t t2 = S0 + mj;
            hh=g; g=f; f=e; e=d+t1; d=c; c=bb; bb=a; a=t1+t2;
        }
        h[0]+=a; h[1]+=bb; h[2]+=c; h[3]+=d; h[4]+=e; h[5]+=f; h[6]+=g; h[7]+=hh;
    }
    for (int i = 0; i < 8; i++) {
        out[i*4]   = (uint8_t)(h[i] >> 24);
        out[i*4+1] = (uint8_t)(h[i] >> 16);
        out[i*4+2] = (uint8_t)(h[i] >> 8);
        out[i*4+3] = (uint8_t)h[i];
    }
}

/* Generated from aurora/test/xprs_corpus.json by test_xprs_host.sh. */
typedef struct { const char *wire; int bytes; const char *id; } corpus_t;
#include "xprs_corpus_inc.h"

static int g_fail;
#define CHECK(cond, ...) do { if (!(cond)) { g_fail++; \
    printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); \
    printf("\n"); } } while (0)

int main(void)
{
    /* 1. The corpus: parse, round-trip, byte count, identifier. */
    int n_corpus = (int)(sizeof(g_corpus) / sizeof(g_corpus[0]));
    for (int i = 0; i < n_corpus; i++) {
        const corpus_t *c = &g_corpus[i];
        int len = (int)strlen(c->wire);
        xprs_t p;
        CHECK(xprs_parse(c->wire, len, &p), "[%d] does not parse: %.60s", i, c->wire);
        if (p.n == 0) continue;
        char out[XPRS_MAX_WIRE + 1];
        int el = xprs_encode(&p, out, sizeof out);
        CHECK(el == len && memcmp(out, c->wire, len) == 0,
              "[%d] round-trip differs:\n  in  %s\n  out %s", i, c->wire, out);
        if (c->bytes > 0)
            CHECK(el == c->bytes, "[%d] bytes %d != corpus %d", i, el, c->bytes);
        char id[XPRS_ID_LEN];
        xprs_id(&p, id);
        CHECK(strcmp(id, c->id) == 0, "[%d] id %s != corpus %s: %.60s",
              i, id, c->id, c->wire);
    }
    printf("corpus: %d wires replayed\n", n_corpus);

    /* 2. The section-13 via: ladder — identity survives every hop. */
    const char *hop0 = "t:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 q:ack m:meet at the bridge at six";
    char hop1[XPRS_MAX_WIRE + 1], hop2[XPRS_MAX_WIRE + 1], hop3[XPRS_MAX_WIRE + 1];
    int l1 = xprs_append_via(hop0, (int)strlen(hop0), "X32DVA", hop1, sizeof hop1);
    CHECK(l1 > 0, "hop1 append failed");
    /* A new via: is inserted immediately BEFORE m: (XprsPacket.with_), so the
     * doc's ladder wires — which write via: before q: — differ in field order
     * but not in identity, which is the property the ladder loop asserts. */
    CHECK(strcmp(hop1, "t:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 q:ack via:X32DVA m:meet at the bridge at six") == 0,
          "hop1 wire: %s", hop1);
    int l2 = xprs_append_via(hop1, l1, "CT1ABC-9", hop2, sizeof hop2);
    CHECK(l2 > 0, "hop2 append failed");
    int l3 = xprs_append_via(hop2, l2, "X3RLY7", hop3, sizeof hop3);
    CHECK(l3 > 0, "hop3 append failed");
    char id[XPRS_ID_LEN];
    for (const char *w = hop0;;) {
        CHECK(xprs_id_of(w, (int)strlen(w), id) && strcmp(id, "de9780") == 0,
              "ladder id drifted to %s on: %.60s", id, w);
        if (w == hop0) w = hop1; else if (w == hop1) w = hop2;
        else if (w == hop2) w = hop3; else break;
    }

    /* 3. Refusals: loop, budget, and the sos/warning budget of 9. */
    char tmp[XPRS_MAX_WIRE + 1];
    CHECK(xprs_append_via(hop1, l1, "x32dva", tmp, sizeof tmp) == -1,
          "loop not refused (case-insensitive)");
    CHECK(xprs_append_via(hop3, l3, "X1AAAA", tmp, sizeof tmp) == -1,
          "3-hop message budget not refused");
    const char *sos = "t:sos f:X1QZ3N pos:38.7,-9.1 via:A1,B2,C3 m:need water";
    CHECK(xprs_append_via(sos, (int)strlen(sos), "D4", tmp, sizeof tmp) > 0,
          "sos budget must be 9, refused at 3");

    /* 4. Vocabulary. */
    xprs_t p;
    const char *w1 = "t:message f:X1QZ3N d:X1RD89 scope:local urg:urgent m:x";
    CHECK(xprs_parse(w1, (int)strlen(w1), &p), "w1 parse");
    CHECK(xprs_scope_local(&p), "scope:local not seen");
    CHECK(xprs_urg(&p) == XPRS_URG_URGENT, "urg:urgent");
    const char *w2 = "t:message f:A d:B urg:sideways m:x";
    CHECK(xprs_parse(w2, (int)strlen(w2), &p) && xprs_urg(&p) == XPRS_URG_NORMAL,
          "unknown urg word must read NORMAL");
    CHECK(xprs_is_station("X1RD89", 6), "X1RD89 is a station");
    CHECK(!xprs_is_station("LISBOA", 6), "LISBOA is a group");
    CHECK(!xprs_is_station("X5A3F2", 6), "X5 is a group");
    CHECK(xprs_is_station("CT1ABC-9", 8), "CT1ABC-9 is a station");

    /* 4b. uptime:/lifetime: are ordinary qty fields — parse, survive a
     * round-trip, and never disturb the identifier derivation. */
    const char *wu = "t:observation f:X3RLY7 link:ble peers:4 mail:3 uptime:26h lifetime:38day";
    CHECK(xprs_parse(wu, (int)strlen(wu), &p), "uptime beacon parse");
    char uv[16];
    CHECK(xprs_get_str(&p, "uptime", uv, sizeof uv) && strcmp(uv, "26h") == 0,
          "uptime value, got '%s'", uv);
    CHECK(xprs_get_str(&p, "lifetime", uv, sizeof uv) && strcmp(uv, "38day") == 0,
          "lifetime value, got '%s'", uv);

    /* 5. Parser tolerance (design rule 8): malformed tokens skip, m: swallows. */
    const char *w3 = "t:message :bad UPPER:no f:X1QZ3N m:a b:c https://x";
    CHECK(xprs_parse(w3, (int)strlen(w3), &p), "tolerant parse");
    char v[64];
    CHECK(xprs_get_str(&p, "m", v, sizeof v) && strcmp(v, "a b:c https://x") == 0,
          "m: must swallow the rest, got '%s'", v);
    CHECK(p.n == 3, "skips must leave t,f,m only (got %d)", p.n);
    CHECK(!xprs_parse("x:message f:A m:y", 17, &p), "no t: must not parse");

    if (g_fail) { printf("FAILED: %d check(s)\n", g_fail); return 1; }
    printf("OK: all checks passed\n");
    return 0;
}
