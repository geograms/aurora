/*
 * Host test for the XPRS LAN bearer.
 *
 * The socket is not the interesting part and is not tested here. What is tested
 * is everything that decides WHETHER and WHEN a packet goes on the wire: the
 * relay rules, the random delay, and the rule that hearing somebody else say it
 * first throws our copy away. Those are what turn three dongles on one LAN into
 * one transmission instead of three.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>

#include "xprslan.h"

/* Handles into the module (see the XPRSLAN_HOST_TEST section of xprslan.c). */
extern uint32_t xl_test_now_ms;
extern char     xl_test_aired[];
extern int      xl_test_aired_len;
extern int      xl_test_air_count;
extern uint32_t xl_test_random;
void     xl_test_datagram(const char *wire, int len, uint32_t ip);
int      xl_test_pump(uint32_t now);
void     xl_test_reset(void);
int      xl_test_queue_len(void);
uint32_t xl_test_queue_due(int i);

static int checks, failures;
#define CHECK(cond, fmt, ...) do {                                            \
    checks++;                                                                 \
    if (!(cond)) {                                                            \
        failures++;                                                           \
        printf("  FAIL %s:%d  " fmt "\n", __func__, __LINE__, ##__VA_ARGS__); \
    }                                                                         \
} while (0)

#define SELF "X3WWAJ"
#define TS   "2026-08-13_09:00:00"

/* Move the clock and let anything due go out. */
static void advance(uint32_t ms)
{
    xl_test_now_ms += ms;
    xl_test_pump(xl_test_now_ms);
}

static void setup(void)
{
    xl_test_now_ms = 100000;
    xl_test_random = 0;              /* jitter = the minimum, unless a test says */
    xl_test_reset();
    xprslan_start(SELF);
}

/* ── A packet from another bearer waits, then goes ───────────────────────── */

static void test_offer_waits_then_airs(void)
{
    setup();
    const char *w = "t:message f:X1QZ3N d:LISBOA ts:" TS " m:anyone got a 10 mm spanner?";
    xprslan_offer(w, (int)strlen(w));

    CHECK(xl_test_queue_len() == 1, "not queued (%d)", xl_test_queue_len());
    CHECK(xl_test_air_count == 0, "aired immediately — the whole point is that it waits");

    advance(XPRSLAN_JITTER_MIN_MS - 1);
    CHECK(xl_test_air_count == 0, "aired before its moment");

    advance(2);
    CHECK(xl_test_air_count == 1, "never aired (%d)", xl_test_air_count);
    CHECK(strstr(xl_test_aired, "via:" SELF) != NULL,
          "relayed without saying so: %s", xl_test_aired);
    CHECK(strstr(xl_test_aired, "m:anyone got a 10 mm spanner?") != NULL,
          "payload changed: %s", xl_test_aired);
}

/* ── Somebody else says it first ─────────────────────────────────────────── */

static void test_heard_elsewhere_cancels(void)
{
    setup();
    const char *w = "t:warning f:X3RLY7 pos:39.40,-8.20 kind:fire sev:danger ts:" TS;
    xprslan_offer(w, (int)strlen(w));
    CHECK(xl_test_queue_len() == 1, "not queued");

    /* Another station relays the same packet — same §5 identifier, because the
     * identifier is computed with via: and sig: removed. */
    char theirs[300];
    snprintf(theirs, sizeof theirs,
             "t:warning f:X3RLY7 pos:39.40,-8.20 kind:fire sev:danger ts:" TS
             " via:X1OTHER");
    xl_test_datagram(theirs, (int)strlen(theirs), 0x0100A8C0);

    CHECK(xl_test_queue_len() == 0, "still queued after hearing it from somebody else");
    advance(XPRSLAN_JITTER_MAX_MS + 10);
    CHECK(xl_test_air_count == 0, "aired a packet that was already on the LAN");

    uint32_t rx = 0, tx = 0, cancelled = 0;
    xprslan_stats(&rx, &tx, &cancelled);
    CHECK(rx == 1, "rx count %u", (unsigned)rx);
    CHECK(tx == 0, "tx count %u", (unsigned)tx);
    CHECK(cancelled == 1, "cancelled count %u", (unsigned)cancelled);
}

/* ── The relay rules belong to geogram_xprs ──────────────────────────────── */

static void test_own_hop_is_not_relayed(void)
{
    setup();
    char w[300];
    snprintf(w, sizeof w, "t:message f:X1QZ3N d:X1RD89 ts:" TS " via:%s m:hello", SELF);
    xprslan_offer(w, (int)strlen(w));
    CHECK(xl_test_queue_len() == 0, "queued a packet we had already relayed");

    /* And a spent budget: a message may take 3 hops (§13.1). */
    setup();
    snprintf(w, sizeof w,
             "t:message f:X1QZ3N d:X1RD89 ts:" TS " via:X1AAAAA,X1BBBBB,X1CCCCC m:hello");
    xprslan_offer(w, (int)strlen(w));
    CHECK(xl_test_queue_len() == 0, "queued a packet whose relay budget was spent");
}

/* ── The same thing twice ────────────────────────────────────────────────── */

static void test_no_double_air(void)
{
    setup();
    const char *w = "t:status f:X1A67X ts:" TS " m:here";
    xprslan_offer(w, (int)strlen(w));
    advance(XPRSLAN_JITTER_MAX_MS + 10);
    CHECK(xl_test_air_count == 1, "first air missing (%d)", xl_test_air_count);

    xprslan_offer(w, (int)strlen(w));           /* heard again on the other bearer */
    advance(XPRSLAN_JITTER_MAX_MS + 10);
    CHECK(xl_test_air_count == 1, "aired the same packet twice (%d)", xl_test_air_count);
}

/* ── Delivery upward, once ───────────────────────────────────────────────── */

static int   rx_calls;
static char  rx_last[300];
static void rx_cb(const char *wire, int len, uint32_t ip)
{
    (void)ip;
    rx_calls++;
    memcpy(rx_last, wire, (size_t)len);
    rx_last[len] = 0;
}

static void test_rx_delivers_once(void)
{
    setup();
    rx_calls = 0;
    xprslan_set_rx_cb(rx_cb);

    const char *w = "t:observation f:X1B0001 link:lan peers:3 ts:" TS;
    xl_test_datagram(w, (int)strlen(w), 0x0200A8C0);
    xl_test_datagram(w, (int)strlen(w), 0x0300A8C0);   /* the LAN repeats itself */

    CHECK(rx_calls == 1, "delivered %d times", rx_calls);
    CHECK(strcmp(rx_last, w) == 0, "packet altered on the way up: %s", rx_last);
    CHECK(xprslan_peer_count(60) == 2, "peers %d", xprslan_peer_count(60));
    xprslan_set_rx_cb(NULL);
}

/* ── Anything that is not XPRS is not ours ───────────────────────────────── */

static void test_ignores_foreign_datagrams(void)
{
    setup();
    rx_calls = 0;
    xprslan_set_rx_cb(rx_cb);

    const char *junk = "\x7f\x45\x4c\x46 not a packet";
    xl_test_datagram(junk, (int)strlen(junk), 0x0400A8C0);
    const char *json = "{\"type\":\"hello\"}";
    xl_test_datagram(json, (int)strlen(json), 0x0400A8C0);

    CHECK(rx_calls == 0, "delivered %d non-XPRS datagrams", rx_calls);
    xprslan_offer(json, (int)strlen(json));
    CHECK(xl_test_queue_len() == 0, "queued a non-XPRS payload");
    xprslan_set_rx_cb(NULL);
}

/* ── The delay is inside its window, and it varies ───────────────────────── */

static void test_jitter_window(void)
{
    for (uint32_t r = 0; r < 5; r++) {
        setup();
        xl_test_random = r * 977;                /* a different draw each time */
        const char *w = "t:info f:X1QZ3N ts:" TS " m:window";
        xprslan_offer(w, (int)strlen(w));
        CHECK(xl_test_queue_len() == 1, "not queued for draw %u", (unsigned)r);
        uint32_t due = xl_test_queue_due(0) - xl_test_now_ms;
        CHECK(due >= XPRSLAN_JITTER_MIN_MS && due <= XPRSLAN_JITTER_MAX_MS,
              "delay %u ms outside [%u,%u]", (unsigned)due,
              XPRSLAN_JITTER_MIN_MS, XPRSLAN_JITTER_MAX_MS);
    }
}

/* ── Our own packets go now, with no via: ────────────────────────────────── */

static void test_own_send_is_immediate(void)
{
    setup();
    const char *beacon = "t:observation f:" SELF " link:lan peers:2";
    CHECK(xprslan_send(beacon, (int)strlen(beacon)), "own send refused");
    CHECK(xl_test_air_count == 1, "own packet did not go out");
    CHECK(strstr(xl_test_aired, "via:") == NULL,
          "our own packet claims hops: %s", xl_test_aired);

    /* And it is not then relayed back onto the LAN when it returns to us. */
    xprslan_offer(beacon, (int)strlen(beacon));
    advance(XPRSLAN_JITTER_MAX_MS + 10);
    CHECK(xl_test_air_count == 1, "re-aired our own packet (%d)", xl_test_air_count);
}

/* ── The beacon runs on the bearer's task ────────────────────────────────── */

static int beacon_calls;
static int beacon_build(char *out, int cap)
{
    beacon_calls++;
    return snprintf(out, (size_t)cap, "t:observation f:" SELF " link:lan peers:%d",
                    xprslan_peer_count(600));
}

static void test_beacon_cadence(void)
{
    setup();
    beacon_calls = 0;
    xprslan_set_beacon(beacon_build, 300, 20);      /* every 5 min, first at 20 s */

    advance(19000);
    CHECK(beacon_calls == 0, "beacon spoke before its first delay (%d)", beacon_calls);

    advance(2000);
    CHECK(beacon_calls == 1, "no first beacon (%d)", beacon_calls);
    CHECK(strstr(xl_test_aired, "t:observation f:" SELF " link:lan") != NULL,
          "beacon shape wrong: %s", xl_test_aired);
    CHECK(strstr(xl_test_aired, "via:") == NULL, "our own beacon claims hops");

    advance(299000);
    CHECK(beacon_calls == 1, "beacon repeated early (%d)", beacon_calls);
    advance(2000);
    CHECK(beacon_calls == 2, "beacon did not repeat (%d)", beacon_calls);
    xprslan_set_beacon(NULL, 0, 0);
}

/* ── the origin repeating itself must NOT cancel our copy ────────────────── */

static void test_origin_repeat_does_not_cancel(void)
{
    setup();
    const char *w = "t:warning f:X3RLY7 pos:39.40,-8.20 kind:fire sev:danger ts:" TS;
    xprslan_offer(w, (int)strlen(w));
    CHECK(xl_test_queue_len() == 1, "not queued");

    /* The SAME packet again, still with no via: — the sender repeating because
     * nobody carried it. That is a reason to relay, not to stand down. */
    xl_test_datagram(w, (int)strlen(w), 0x0100A8C0);
    CHECK(xl_test_queue_len() == 1, "an origin repeat cancelled our digipeat");

    advance(XPRSLAN_JITTER_MAX_MS + 10);
    CHECK(xl_test_air_count == 1, "never aired (%d)", xl_test_air_count);
}

/* ── the heard callback sees what the rx callback is spared ──────────────── */

static int heard_calls;
static void heard_cb(const char *id, const char *wire, int len)
{
    (void)id; (void)wire; (void)len;
    heard_calls++;
}

static void test_heard_cb_sees_duplicates(void)
{
    setup();
    rx_calls = 0; heard_calls = 0;
    xprslan_set_rx_cb(rx_cb);
    xprslan_set_heard_cb(heard_cb);

    const char *w = "t:warning f:X3RLY7 pos:39.40,-8.20 kind:fire sev:danger ts:" TS;
    xl_test_datagram(w, (int)strlen(w), 0x0100A8C0);
    xl_test_datagram(w, (int)strlen(w), 0x0200A8C0);   /* another station relays it */

    CHECK(rx_calls == 1, "rx saw the duplicate (%d)", rx_calls);
    CHECK(heard_calls == 2, "heard missed the duplicate (%d)", heard_calls);
    xprslan_set_rx_cb(NULL);
    xprslan_set_heard_cb(NULL);
}

int main(void)
{
    printf("xprslan host tests\n");
    test_offer_waits_then_airs();
    test_heard_elsewhere_cancels();
    test_own_hop_is_not_relayed();
    test_no_double_air();
    test_rx_delivers_once();
    test_ignores_foreign_datagrams();
    test_jitter_window();
    test_own_send_is_immediate();
    test_beacon_cadence();
    test_heard_cb_sees_duplicates();
    test_origin_repeat_does_not_cancel();
    printf("%d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
