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
    rm_rf(dir);
    printf("%d checks, %d failed\n", g_checks, g_fail);
    return g_fail ? 1 : 0;
}
