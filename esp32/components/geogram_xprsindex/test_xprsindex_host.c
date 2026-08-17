/*
 * Host test for the XPRS index. Runs on a temp directory instead of a card, so
 * the record layout, the two derived indexes, the eviction of what must not be
 * served and the recovery path are all testable without hardware.
 *
 * Build + run:  ./test_xprsindex_host.sh
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "xprsindex.h"

static int g_fail = 0;
/* The store converts ts: to epoch internally; the test needs the same number. */
static uint32_t xi_expect_ts(const char *str)
{
    int Y,M,D,h,m,sec;
    if (sscanf(str, "%4d-%2d-%2d_%2d:%2d:%2d", &Y,&M,&D,&h,&m,&sec) != 6) return 0;
    static const int cum[12] = {0,31,59,90,120,151,181,212,243,273,304,334};
    long days = (long)(Y - 1970) * 365 + ((Y - 1969) / 4) + cum[M - 1] + (D - 1);
    if (M > 2 && ((Y % 4 == 0 && Y % 100 != 0) || Y % 400 == 0)) days++;
    return (uint32_t)(days * 86400L + h * 3600 + m * 60 + sec);
}

static int g_checks = 0;

#define CHECK(cond, ...) do {                                              \
    g_checks++;                                                            \
    if (!(cond)) {                                                         \
        g_fail++;                                                          \
        printf("  FAIL %s:%d  ", __func__, __LINE__);                      \
        printf(__VA_ARGS__);                                               \
        printf("\n");                                                      \
    }                                                                      \
} while (0)

/* 2026-08-13_09:00:00 and a year earlier, as the epochs the codec derives. */
#define TS_2026 "2026-08-13_09:00:00"
#define TS_2025 "2025-08-13_09:00:00"

typedef struct { int n; xprsidx_rec_t last; xprsidx_rec_t first; } collect_t;

static bool collect(const xprsidx_rec_t *r, void *ctx)
{
    collect_t *c = ctx;
    if (c->n == 0) c->first = *r;
    c->last = *r;
    c->n++;
    return true;
}

static void rm_rf(const char *dir)
{
    char cmd[256];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", dir);
    if (system(cmd) != 0) { /* first run: nothing to remove */ }
}

/* ── the two questions the user asked for ───────────────────────────────── */

static void test_recent_of_a_type(const char *dir)
{
    rm_rf(dir);
    xprsidx_t *st = xprsindex_open(dir);
    CHECK(xprsindex_ready(st), "store did not open");

    /* Noise, then warnings, then more noise: the warnings are NOT at the end,
     * so a naive "read the last N records" would get this wrong. */
    char w[280];
    for (int i = 0; i < 40; i++) {
        snprintf(w, sizeof w, "t:observation f:X3WX%02d link:ble peers:2 ts:%s", i, TS_2026);
        xprsindex_add(st, w, (int)strlen(w), -60, false, 0);
    }
    for (int i = 0; i < 5; i++) {
        snprintf(w, sizeof w, "t:warning f:X3RLY%d pos:39.40,-8.20 kind:fire sev:danger ts:%s", i, TS_2026);
        xprsindex_add(st, w, (int)strlen(w), -60, false, 0);
    }
    for (int i = 0; i < 40; i++) {
        snprintf(w, sizeof w, "t:status f:X1A6%02d ts:%s m:here", i, TS_2026);
        xprsindex_add(st, w, (int)strlen(w), -60, false, 0);
    }

    collect_t c = {0};
    xprsidx_query_t q = { .type = XI_T_WARNING, .newest_first = true, .limit = 3 };
    size_t n = xprsindex_query(st, &q, collect, &c);

    CHECK(n == 3, "wanted 3 recent warnings, got %zu", n);
    CHECK(c.n == 3, "callback saw %d", c.n);
    CHECK(c.first.type == XI_T_WARNING, "first is type %d", c.first.type);
    /* Newest first: X3RLY4 was the last warning written. */
    CHECK(strcmp(c.first.from, "X3RLY4") == 0, "newest warning is %s", c.first.from);
    CHECK(strstr(c.first.wire, "kind:fire") != NULL, "wire not kept verbatim");
    xprsindex_close(st);
}

static void test_a_year_ago(const char *dir)
{
    rm_rf(dir);
    xprsidx_t *st = xprsindex_open(dir);
    char w[280];

    for (int i = 0; i < 10; i++) {
        snprintf(w, sizeof w, "t:blog f:X1OLD%d ts:%s m:last year %d", i, TS_2025, i);
        xprsindex_add(st, w, (int)strlen(w), 0, false, 0);
    }
    for (int i = 0; i < 10; i++) {
        snprintf(w, sizeof w, "t:blog f:X1NEW%d ts:%s m:this year %d", i, TS_2026, i);
        xprsindex_add(st, w, (int)strlen(w), 0, false, 0);
    }

    /* Everything in 2025. */
    collect_t c = {0};
    xprsidx_query_t q = {
        .since_ts = 1735689600u,   /* 2025-01-01 */
        .until_ts = 1767225599u,   /* 2025-12-31 */
        .type = -1, .limit = 100,
    };
    size_t n = xprsindex_query(st, &q, collect, &c);
    CHECK(n == 10, "wanted the 10 from last year, got %zu", n);
    CHECK(strncmp(c.first.from, "X1OLD", 5) == 0, "first is %s", c.first.from);

    /* And the same range narrowed to a type that is not there. */
    collect_t c2 = {0};
    xprsidx_query_t q2 = q;
    q2.type = XI_T_WARNING;
    CHECK(xprsindex_query(st, &q2, collect, &c2) == 0, "warnings appeared from nowhere");
    xprsindex_close(st);
}

/* ── section 36: what may be served ─────────────────────────────────────── */

static void test_mail_is_not_public(const char *dir)
{
    rm_rf(dir);
    xprsidx_t *st = xprsindex_open(dir);

    const char *mail = "t:message f:X1QZ3N d:X1RD89 ts:" TS_2026 " x:pQ4m9xT2vB8kR";
    const char *pub  = "t:warning f:X3RLY7 pos:39.40,-8.20 kind:fire sev:danger ts:" TS_2026;
    CHECK(xprsindex_add(st, mail, (int)strlen(mail), -50, false, 0), "mail not stored");
    CHECK(xprsindex_add(st, pub, (int)strlen(pub), -50, false, 0), "publication not stored");

    /* A stranger sees the publication and never the mail. */
    collect_t c = {0};
    xprsidx_query_t q = { .type = -1, .limit = 50 };
    size_t n = xprsindex_query(st, &q, collect, &c);
    CHECK(n == 1, "a stranger saw %zu records", n);
    CHECK(c.first.type == XI_T_WARNING, "the wrong one survived");

    /* The addressee sees theirs. */
    collect_t c2 = {0};
    xprsidx_query_t q2 = { .type = -1, .limit = 50, .asker = "X1RD89" };
    CHECK(xprsindex_query(st, &q2, collect, &c2) == 2, "addressee cannot read own mail");

    /* So does the sender, and nobody else. */
    collect_t c3 = {0};
    xprsidx_query_t q3 = { .type = -1, .limit = 50, .asker = "X1QZ3N" };
    CHECK(xprsindex_query(st, &q3, collect, &c3) == 2, "sender cannot see what they sent");

    collect_t c4 = {0};
    xprsidx_query_t q4 = { .type = -1, .limit = 50, .asker = "X9NOSY" };
    CHECK(xprsindex_query(st, &q4, collect, &c4) == 1, "a third party read somebody's mail");
    xprsindex_close(st);
}

static void test_refuses_what_it_should(const char *dir)
{
    rm_rf(dir);
    xprsidx_t *st = xprsindex_open(dir);

    const char *ping = "t:ping f:X1A67X ts:" TS_2026;
    const char *pong = "t:pong f:X1A67X ts:" TS_2026;
    CHECK(!xprsindex_add(st, ping, (int)strlen(ping), 0, false, 0), "stored a ping");
    CHECK(!xprsindex_add(st, pong, (int)strlen(pong), 0, false, 0), "stored a pong");

    const char *notxprs = "X1A67X\x1FX1RD89\x1Fhello";
    CHECK(!xprsindex_add(st, notxprs, (int)strlen(notxprs), 0, false, 0),
          "stored a compact frame as XPRS");

    /* The same packet heard twice on two bearers is one record. */
    const char *w = "t:warning f:X3RLY7 kind:fire sev:danger ts:" TS_2026;
    CHECK(xprsindex_add(st, w, (int)strlen(w), -50, false, 0), "first copy refused");
    CHECK(!xprsindex_add(st, w, (int)strlen(w), -80, false, 0), "duplicate stored twice");

    collect_t c = {0};
    xprsidx_query_t q = { .type = -1, .limit = 50 };
    CHECK(xprsindex_query(st, &q, collect, &c) == 1, "store holds the wrong count");
    xprsindex_close(st);
}

/* ── survives a restart, and a truncated index ──────────────────────────── */

static void test_reopen(const char *dir)
{
    rm_rf(dir);
    xprsidx_t *st = xprsindex_open(dir);
    char w[280];
    for (int i = 0; i < 12; i++) {
        snprintf(w, sizeof w, "t:place f:X1PL%02d ts:%s m:spot %d", i, TS_2026, i);
        xprsindex_add(st, w, (int)strlen(w), 0, false, 0);
    }
    uint32_t latest = xprsindex_latest_index(st);
    xprsindex_close(st);

    xprsidx_t *re = xprsindex_open(dir);
    CHECK(xprsindex_ready(re), "did not reopen");
    CHECK(xprsindex_latest_index(re) == latest, "index moved across a restart: %u vs %u",
          (unsigned)xprsindex_latest_index(re), (unsigned)latest);

    /* And it keeps counting from where it left off rather than overwriting. */
    const char *more = "t:place f:X1PLNEW ts:" TS_2026 " m:after reboot";
    CHECK(xprsindex_add(re, more, (int)strlen(more), 0, false, 0), "append after reopen failed");
    CHECK(xprsindex_latest_index(re) == latest + 1, "did not continue the sequence");
    xprsindex_close(re);
}

static void test_survives_a_lost_index(const char *dir)
{
    rm_rf(dir);
    xprsidx_t *st = xprsindex_open(dir);
    char w[280];
    for (int i = 0; i < 6; i++) {
        snprintf(w, sizeof w, "t:warning f:X3W%02d kind:fire sev:danger ts:%s", i, TS_2026);
        xprsindex_add(st, w, (int)strlen(w), 0, false, 0);
    }
    xprsindex_close(st);

    /* A power cut between the record and its indexes: the derived files go. */
    char cmd[256];
    snprintf(cmd, sizeof cmd, "rm -f '%s'/zone.idx '%s'/t/*.idx", dir, dir);
    if (system(cmd) != 0) { /* nothing to remove is fine */ }

    xprsidx_t *re = xprsindex_open(dir);
    collect_t c = {0};
    /* A range query walks segments, so it answers from the records alone. */
    xprsidx_query_t q = { .type = XI_T_WARNING, .limit = 50 };
    size_t n = xprsindex_query(re, &q, collect, &c);
    CHECK(n == 6, "records unreadable without the indexes: got %zu", n);
    xprsindex_close(re);
}

/* ── the shape of the thing on disk ─────────────────────────────────────── */

static void test_wire_is_kept_verbatim(const char *dir)
{
    rm_rf(dir);
    xprsidx_t *st = xprsindex_open(dir);

    /* A packet at the format's limit must survive whole — this is what the
     * 192-byte APRS record could not do, and the reason for a second store. */
    char w[XPRSIDX_WIRE_MAX + 1];
    int n = snprintf(w, sizeof w, "t:blog f:X1LONG ts:%s m:", TS_2026);
    while (n < XPRSIDX_WIRE_MAX) w[n++] = 'x';
    w[XPRSIDX_WIRE_MAX] = '\0';
    CHECK((int)strlen(w) == XPRSIDX_WIRE_MAX, "test packet is %d bytes", (int)strlen(w));
    CHECK(xprsindex_add(st, w, XPRSIDX_WIRE_MAX, 0, false, 0), "250-byte packet refused");

    collect_t c = {0};
    xprsidx_query_t q = { .type = -1, .limit = 5 };
    xprsindex_query(st, &q, collect, &c);
    CHECK(c.n == 1, "got %d records", c.n);
    CHECK(c.first.len == XPRSIDX_WIRE_MAX, "length changed: %u", (unsigned)c.first.len);
    CHECK(strcmp(c.first.wire, w) == 0, "the packet came back different");
    CHECK(c.first.id[0] != '\0', "no identifier derived");
    xprsindex_close(st);
}

/* ── a torn tail must not hide the answers behind it ─────────────────────── */

/*
 * The dongle produced exactly this: the newest entries of t/08.idx were zeroes
 * (FatFs had the file's size but not its bytes), so "the most recent warning"
 * answered nothing while the record sat readable in its segment — and asking
 * for three answered three, because a bigger window reached past the damage.
 */
static void test_torn_tail_still_answers(const char *dir)
{
    rm_rf(dir);
    xprsidx_t *st = xprsindex_open(dir);
    char w[280];

    /* Record 0 is deliberately NOT a warning, as it was on the dongle: that is
     * what let four zero entries quietly answer "no recent warnings". */
    const char *first = "t:observation f:X3WX01 link:ble peers:2 "
                        "ts:2026-08-09_09:00:00";
    xprsindex_add(st, first, (int)strlen(first), -60, false, 0);
    for (int i = 0; i < 6; i++) {
        snprintf(w, sizeof w, "t:warning f:X3RLY%d pos:39.40,-8.20 kind:fire "
                              "sev:danger ts:2026-08-1%d_09:00:00", i, i);
        xprsindex_add(st, w, (int)strlen(w), -60, false, 0);
    }
    /* Real newest warning, the one a reader must get back. */
    const char *newest = "t:warning f:X1LAST pos:38.72,-9.14 kind:flood "
                         "sev:danger ts:2026-08-17_09:00:00";
    CHECK(xprsindex_add(st, newest, (int)strlen(newest), -60, false, 0),
          "newest warning not stored");
    xprsindex_close(st);

    /* Tear the tail: four zero entries appended, as a half-synced file reads. */
    char path[256];
    snprintf(path, sizeof path, "%s/t/%02d.idx", dir, XI_T_WARNING);
    FILE *f = fopen(path, "ab");
    CHECK(f != NULL, "no warning tail to tear");
    if (f) {
        uint32_t zero = 0;
        for (int i = 0; i < 4; i++) fwrite(&zero, sizeof zero, 1, f);
        fclose(f);
    }

    st = xprsindex_open(dir);
    collect_t c = {0};
    xprsidx_query_t q = { .type = XI_T_WARNING, .newest_first = true, .limit = 1 };
    size_t n = xprsindex_query(st, &q, collect, &c);
    CHECK(n == 1, "asked for 1 recent warning past a torn tail, got %zu", n);
    CHECK(strcmp(c.first.from, "X1LAST") == 0,
          "wrong warning came back: %s", c.first.from);

    /* And the same store answers a larger request consistently. */
    collect_t c3 = {0};
    xprsidx_query_t q3 = { .type = XI_T_WARNING, .newest_first = true, .limit = 3 };
    CHECK(xprsindex_query(st, &q3, collect, &c3) == 3, "limit 3 did not fill");
    CHECK(strcmp(c3.first.from, "X1LAST") == 0, "newest-first order broken");
    xprsindex_close(st);
}

/* ── authorship (XPRS.md §9.1) ───────────────────────────────────────────── */

/* A verifier the test drives: X1GOOD signs for itself, X1EVIL does not, and
 * nobody has ever heard of X1WHO. */
static int fake_verify(const char *wire, int len, const char *from)
{
    (void)wire; (void)len;
    if (strcmp(from, "X1GOOD") == 0) return 1;
    if (strcmp(from, "X1EVIL") == 0) return -1;
    return 0;
}

static bool collect_flags(const xprsidx_rec_t *rec, void *ctx)
{
    uint8_t *out = (uint8_t *)ctx;
    if (strcmp(rec->from, "X1GOOD") == 0) out[0] = rec->flags;
    if (strcmp(rec->from, "X1EVIL") == 0) out[1] = rec->flags;
    if (strcmp(rec->from, "X1WHO")  == 0) out[2] = rec->flags;
    if (strcmp(rec->from, "X1BARE") == 0) out[3] = rec->flags;
    return true;
}

static void test_verifies_what_it_stores(const char *dir)
{
    rm_rf(dir);
    xprsidx_t *st = xprsindex_open(dir);
    CHECK(st != NULL, "open failed");
    xprsindex_set_verifier(st, fake_verify);

    CHECK(xprsindex_add(st, "t:status f:X1GOOD ts:2026-08-17_10:00:00 sig:aaa m:hello",
                        56, -40, false, 1786000000), "signed+valid refused");
    CHECK(xprsindex_add(st, "t:status f:X1WHO ts:2026-08-17_10:00:01 sig:bbb m:hello",
                        55, -40, false, 1786000001), "signed+unknown refused");
    CHECK(xprsindex_add(st, "t:status f:X1BARE ts:2026-08-17_10:00:02 m:hello",
                        47, -40, false, 1786000002), "unsigned refused");
    /* Accepted by add() — it is only a lie once the signature has been checked,
     * and that happens a thread later. */
    xprsindex_add(st, "t:status f:X1EVIL ts:2026-08-17_10:00:03 sig:ccc m:hello",
                  56, -40, false, 1786000003);

    uint8_t f[4] = {0xFF, 0xFF, 0xFF, 0xFF};
    xprsidx_query_t q = { .type = -1, .limit = 50, .newest_first = false };
    xprsindex_query(st, &q, collect_flags, f);

    CHECK(f[0] != 0xFF, "the verified record was not stored");
    CHECK(xprsidx_sig_of(f[0]) == XI_SIG_VERIFIED,
          "a checked signature did not read as verified (flags %02x)", f[0]);
    CHECK(f[1] == 0xFF, "a FORGED record was stored — it must be refused");
    CHECK(xprsidx_sig_of(f[2]) == XI_SIG_UNVERIFIED,
          "an author we hold no key for should be unverified, not a verdict");
    CHECK(xprsidx_sig_of(f[3]) == XI_SIG_UNSIGNED,
          "an unsigned packet is not the same as an unverified one");

    xprsidx_stats_t stats;
    xprsindex_stats(st, &stats);
    CHECK(stats.verified == 1 && stats.unverified == 1 && stats.forged == 1,
          "counters wrong: %u/%u/%u", (unsigned)stats.verified,
          (unsigned)stats.unverified, (unsigned)stats.forged);
    CHECK(stats.count == 3, "the forged record still counts (%u)",
          (unsigned)stats.count);

    /* With no verifier a station says the honest thing: it cannot tell. */
    xprsindex_close(st);
    rm_rf(dir);
    st = xprsindex_open(dir);
    xprsindex_add(st, "t:status f:X1GOOD ts:2026-08-17_10:00:00 sig:aaa m:hello",
                  56, -40, false, 1786000000);
    uint8_t g[4] = {0xFF, 0xFF, 0xFF, 0xFF};
    xprsindex_query(st, &q, collect_flags, g);
    CHECK(xprsidx_sig_of(g[0]) == XI_SIG_UNVERIFIED,
          "without a verifier, a signature must not read as verified");
    xprsindex_close(st);
}

/* ── the directory an indexer publishes (XPRS.md §36.9) ──────────────────── */

static void test_directory(const char *dir)
{
    rm_rf(dir);
    xprsidx_t *st = xprsindex_open(dir);

    /* Two stations, one heard twice, plus a piece of mail — whose ADDRESSEE
     * must not appear. A directory says who this indexer archives; naming the
     * recipient would publish the envelope §36.7 keeps. */
    const char *feed[] = {
        "t:warning f:X3RLY7 kind:fire sev:danger ts:2026-08-10_09:00:00",
        "t:info f:X3RLY7 ts:2026-08-14_09:00:00 m:later",
        "t:blog f:X1BOA3 ts:2026-08-12_09:00:00 m:hello",
        "t:message f:X1QZ3N d:X1SECRET ts:2026-08-13_09:00:00 x:pQ4m9",
    };
    for (size_t i = 0; i < sizeof feed / sizeof feed[0]; i++) {
        xprsindex_add(st, feed[i], (int)strlen(feed[i]), -60, false, 0);
    }

    xprsidx_dir_entry_t e[8];
    int n = xprsindex_directory(st, e, 8);
    CHECK(n == 3, "listed %d stations, wanted 3", n);
    if (n == 3) {
        CHECK(strcmp(e[0].call, "X1BOA3") == 0, "not sorted: first is %s", e[0].call);
        CHECK(strcmp(e[1].call, "X1QZ3N") == 0, "second is %s", e[1].call);
        CHECK(strcmp(e[2].call, "X3RLY7") == 0, "third is %s", e[2].call);
        CHECK(e[2].last_ts == xi_expect_ts("2026-08-14_09:00:00"),
              "kept the older timestamp for a station heard twice");
    }
    for (int i = 0; i < n; i++) {
        CHECK(strcmp(e[i].call, "X1SECRET") != 0,
              "a mail addressee was published in the directory");
    }

    char text[512];
    int len = xprsindex_dir_render(e, n, text, sizeof text);
    CHECK(len > 0, "render refused");
    CHECK(strncmp(text, "XDIR1\n", 6) == 0, "no XDIR1 header");
    CHECK(strstr(text, "X3RLY7 2026-08-14_09:00:00") != NULL,
          "line missing or misformatted:\n%s", text);

    /* A directory that does not fit is truncated, never overrun. */
    char tiny[16];
    CHECK(xprsindex_dir_render(e, n, tiny, sizeof tiny) == -1,
          "rendered into a buffer too small for it");
    xprsindex_close(st);
}

int main(void)
{
    const char *dir = "/tmp/xprsidx_test";
    printf("xprsindex host tests\n");
    test_recent_of_a_type(dir);
    test_a_year_ago(dir);
    test_mail_is_not_public(dir);
    test_refuses_what_it_should(dir);
    test_reopen(dir);
    test_survives_a_lost_index(dir);
    test_wire_is_kept_verbatim(dir);
    test_torn_tail_still_answers(dir);
    test_directory(dir);
    test_verifies_what_it_stores(dir);
    rm_rf(dir);
    printf("%d checks, %d failed\n", g_checks, g_fail);
    return g_fail ? 1 : 0;
}
