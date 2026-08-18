/*
 * Host test for the §23.7 rendezvous.
 *
 * Everything this file checks was previously learned by flashing two boards and
 * reading serial, one branch per build: the invitation that was not followed,
 * the acceptance counted as its own proof, the repeat answered `s:no busy`. A
 * state machine is the wrong thing to debug over a radio link.
 *
 * The radio is not here. `air` is an ops callback the test owns, so every
 * packet the component would transmit lands in a list instead; the channel
 * moves become counters (the XPRSCHAN_HOST_TEST half of xprschan.c); and the
 * clock is a variable the test advances, so a twelve-second timeout costs
 * nothing to check.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>

#include "xprschan.h"

/* Handles into the module (see the XPRSCHAN_HOST_TEST section of xprschan.c). */
extern uint32_t xc_test_now_ms;
extern uint32_t xc_test_slept_ms;
extern uint8_t  xc_test_channel;
extern bool     xc_test_lr;
extern int      xc_test_moves;
extern int      xc_test_homes;

static int checks, failures;
#define CHECK(cond, fmt, ...) do {                                            \
    checks++;                                                                 \
    if (!(cond)) {                                                            \
        failures++;                                                           \
        printf("  FAIL %s:%d  " fmt "\n", __func__, __LINE__, ##__VA_ARGS__); \
    }                                                                         \
} while (0)

#define SELF  "X3WWAJ"
#define PEER  "X3LTSH"

/* ── The fake station ───────────────────────────────────────────────────── */

#define AIRED_MAX 64
static char aired[AIRED_MAX][XPRS_MAX_WIRE + 1];
static int  aired_n;
static bool air_works = true;      /* a bearer that refuses, when we want one */
static bool sig_valid = true;      /* whether `verified` believes what it sees */
static bool willing   = true;      /* whether this station leaves the commons */
static int  reconnect_held;
static int  identity_airings;
static int  working_calls, home_calls;
static bool last_worked;
static int  settle_calls, trace_on, trace_off;
/* A log of the order things happened in, because for the radio calls the order
 * IS the correctness: Bluetooth has to be off BEFORE the station stops being
 * associated, and back on only after it is on its way home. */
static char order[16][24];
static int  order_n;
static void note(const char *what)
{
    if (order_n < 16) snprintf(order[order_n++], 24, "%s", what);
}
static int order_index(const char *what)
{
    for (int i = 0; i < order_n; i++) if (strcmp(order[i], what) == 0) return i;
    return -1;
}
static int  bt_on_calls, bt_off_calls;
static bool bt_running = true;

/* A signature this test can make and check without a curve: sixty characters,
 * which is exactly what §9.1 puts on the wire, so lengths and the `sig:`-before-
 * `m:` placement are the real ones. What it cannot do is prove authorship —
 * `sig_valid` stands in for that, because who is believed is the question these
 * tests ask, not how the believing is done. */
#define FAKE_SIG "0123456789012345678901234567890123456789012345678901234567890"

static int fake_sign(char *wire, int len, int cap)
{
    if (len + 5 + 60 >= cap) return len;
    char *m = strstr(wire, " m:");
    if (m) {
        int head = (int)(m - wire);
        char tail[XPRS_MAX_WIRE + 1];
        int taillen = len - head;
        memcpy(tail, m, (size_t)taillen);
        tail[taillen] = 0;
        int n = snprintf(wire + head, (size_t)(cap - head), " sig:%.60s%s",
                         FAKE_SIG, tail);
        return head + n;
    }
    int n = snprintf(wire + len, (size_t)(cap - len), " sig:%.60s", FAKE_SIG);
    return len + n;
}

static bool fake_verified(const xprs_t *p)
{
    char sig[80];
    if (!xprs_get_str(p, "sig", sig, sizeof sig)) return false;  /* §23.7 */
    return sig_valid;
}

static bool fake_air(const char *wire, int len)
{
    if (!air_works) return false;
    if (aired_n < AIRED_MAX) {
        memcpy(aired[aired_n], wire, (size_t)len);
        aired[aired_n][len] = 0;
        aired_n++;
    }
    return true;
}

static uint32_t fake_now(void)   { return xc_test_now_ms; }
static uint32_t no_clock(void)   { return 0; }
static void fake_time(char *out, int cap) { snprintf(out, (size_t)cap, "epoch:12"); }
static void fake_hold(bool hold)
{
    reconnect_held += hold ? 1 : -1;
    note(hold ? "hold" : "release");
}
static void fake_bluetooth(bool on)
{
    bt_running = on;
    if (on) bt_on_calls++; else bt_off_calls++;
    note(on ? "bt_on" : "bt_off");
}
static void fake_identity(void)  { identity_airings++; }
static bool fake_may_move(void)  { return willing; }
static bool fake_settle(uint32_t ms) { (void)ms; settle_calls++; return true; }
static void fake_trace(bool on)  { if (on) trace_on++; else trace_off++; }
static void fake_working(const char *peer, uint8_t ch, bool lr)
{
    (void)peer; (void)ch; (void)lr; working_calls++;
}
static void fake_home(const char *peer, bool worked)
{
    (void)peer; home_calls++; last_worked = worked;
}

static const xc_ops_t k_ops = {
    .sign = fake_sign,
    .verified = fake_verified,
    .air = fake_air,
    .now_ms = fake_now,
    .time_field = fake_time,
    .epoch = no_clock,
    .hold_reconnect = fake_hold,
    .announce_identity = fake_identity,
    .may_move = fake_may_move,
    .settle = fake_settle,
    .bluetooth = fake_bluetooth,
    .trace = fake_trace,
    .on_working = fake_working,
    .on_home = fake_home,
};

static void reset(void)
{
    xprschan_abort("test reset");
    aired_n = 0;
    xc_test_now_ms = 100000;   /* not zero: the deadlines are unsigned deltas */
    xc_test_slept_ms = 0;
    xc_test_channel = 0;
    xc_test_lr = false;
    xc_test_moves = xc_test_homes = 0;
    air_works = true; sig_valid = true; willing = true;
    reconnect_held = identity_airings = 0;
    working_calls = home_calls = 0;
    settle_calls = trace_on = trace_off = 0;
    order_n = bt_on_calls = bt_off_calls = 0;
    bt_running = true;
    last_worked = false;
    xprschan_init(SELF, &k_ops);
}

/* Hand the component a packet as if the bearer had heard it. */
static bool hear(const char *wire)
{
    xprs_t p;
    int len = (int)strlen(wire);
    if (!xprs_parse(wire, len, &p)) { CHECK(false, "unparseable: %s", wire); return false; }
    return xprschan_on_packet(&p, wire, len);
}

static const char *last_aired(void)
{
    return aired_n ? aired[aired_n - 1] : "";
}

/* How many aired packets contain [needle]. */
static int aired_with(const char *needle)
{
    int n = 0;
    for (int i = 0; i < aired_n; i++) if (strstr(aired[i], needle)) n++;
    return n;
}

/* The §5 identifier of the invitation we last put on the air. */
static bool invite_id(char *out)
{
    for (int i = aired_n - 1; i >= 0; i--) {
        if (strstr(aired[i], "t:channel")) {
            return xprs_id_of(aired[i], (int)strlen(aired[i]), out);
        }
    }
    return false;
}

static void advance(uint32_t ms)
{
    /* One tick per 250 ms, which is finer than either board runs and so cannot
     * hide a timer that only fires on an exact match. */
    for (uint32_t t = 0; t < ms; t += 250) {
        xc_test_now_ms += 250;
        xprschan_tick();
    }
}

/* ── As the inviter ─────────────────────────────────────────────────────── */

static void test_invite_is_aired_and_signed(void)
{
    reset();
    CHECK(xprschan_invite(PEER, 6, 30, false), "the invitation was refused");
    CHECK(xprschan_state() == XC_IDLE, "invite() must not act before the tick");
    xprschan_tick();
    CHECK(xprschan_state() == XC_INVITED, "state is %d", (int)xprschan_state());
    CHECK(aired_with("t:channel") == 1, "aired %d invitations", aired_with("t:channel"));
    CHECK(strstr(last_aired(), "sig:") != NULL, "unsigned: %s", last_aired());
    CHECK(strstr(last_aired(), "link:espnow") != NULL, "no bearer named");
    CHECK(strstr(last_aired(), "ch:6") != NULL, "no channel named");
    CHECK(identity_airings == 1, "identity aired %d times", identity_airings);
    CHECK(trace_on == 1, "the trace was not switched on");
    CHECK(xc_test_moves == 0, "moved before anybody answered");
}

static void test_a_station_that_will_not_move_does_not_invite(void)
{
    reset();
    willing = false;
    CHECK(!xprschan_invite(PEER, 6, 30, false), "invited anyway");
    CHECK(xprschan_state() == XC_IDLE, "state changed");
}

static void test_silence_ends_it_with_nobody_moved(void)
{
    reset();
    xprschan_invite(PEER, 6, 30, false);
    xprschan_tick();
    advance(XC_INVITE_FRESH_MS + 1000);
    CHECK(xprschan_state() == XC_IDLE, "still waiting after the invitation went stale");
    CHECK(xc_test_moves == 0, "moved with nobody to meet");
    CHECK(xc_test_channel == 0, "left the commons: channel %u", xc_test_channel);
    CHECK(home_calls == 1 && !last_worked, "home %d worked %d", home_calls, last_worked);
    CHECK(trace_off >= 1, "the trace was left on");
}

static void test_the_invitation_is_repeated_while_waiting(void)
{
    reset();
    xprschan_invite(PEER, 6, 30, false);
    xprschan_tick();
    char first[XPRS_ID_LEN];
    CHECK(invite_id(first), "no identifier for the invitation");

    advance(XC_INVITE_RETRY_MS * 3);
    int tries = aired_with("t:channel");
    CHECK(tries >= 3, "only %d invitations in three retry periods", tries);

    /* And our key goes with every one of them. §23.7 is followed only when the
     * signature verifies, so an invitee that missed the identity ignores the
     * invitation AND every retry -- one lost packet costing the whole attempt,
     * measured as seven "not signed by a key we hold" on the far board while
     * this one recorded "no answer". */
    CHECK(identity_airings >= tries,
          "%d identity airings for %d invitations", identity_airings, tries);

    /* Same bytes, so the same §5 identifier — an answer naming the first still
     * names the last, which is the whole reason a retry is safe. */
    for (int i = 0; i < aired_n; i++) {
        if (!strstr(aired[i], "t:channel")) continue;
        char id[XPRS_ID_LEN];
        CHECK(xprs_id_of(aired[i], (int)strlen(aired[i]), id) &&
              strcmp(id, first) == 0, "airing %d has identifier %s, not %s",
              i, id, first);
    }
}

static void test_an_unverifiable_answer_is_ignored(void)
{
    reset();
    xprschan_invite(PEER, 6, 30, false);
    xprschan_tick();
    char id[XPRS_ID_LEN];
    invite_id(id);

    char ack[XPRS_MAX_WIRE + 1];
    snprintf(ack, sizeof ack, "t:receipt f:%s d:%s r:%s s:ack sig:%.60s",
             PEER, SELF, id, FAKE_SIG);
    sig_valid = false;
    hear(ack);
    CHECK(xprschan_state() == XC_INVITED, "followed an answer we cannot check");
    CHECK(xc_test_moves == 0, "moved on an unverifiable answer");
}

static void test_an_answer_naming_another_invitation_is_ignored(void)
{
    reset();
    xprschan_invite(PEER, 6, 30, false);
    xprschan_tick();
    char ack[XPRS_MAX_WIRE + 1];
    snprintf(ack, sizeof ack, "t:receipt f:%s d:%s r:deadbeef s:ack sig:%.60s",
             PEER, SELF, FAKE_SIG);
    hear(ack);
    CHECK(xprschan_state() == XC_INVITED, "acted on somebody else's receipt");
    CHECK(xc_test_moves == 0, "moved for an unrelated receipt");
}

static void test_no_hardware_ends_it_without_moving(void)
{
    reset();
    xprschan_invite(PEER, 6, 30, false);
    xprschan_tick();
    char id[XPRS_ID_LEN];
    invite_id(id);
    char no[XPRS_MAX_WIRE + 1];
    snprintf(no, sizeof no, "t:receipt f:%s d:%s r:%s s:no sig:%.60s m:no espnow here",
             PEER, SELF, id, FAKE_SIG);
    hear(no);
    CHECK(xprschan_state() == XC_IDLE, "still waiting after a refusal");
    CHECK(xc_test_moves == 0, "moved after being told no");
    CHECK(home_calls == 1 && !last_worked, "home %d worked %d", home_calls, last_worked);
}

/* The bug that cost the most: the acceptance repeated on the COMMONS was
 * counted as the step-4 proof, so the inviter declared the channel proved while
 * still tuned to channel 1 and never actually verified anybody was there. */
static void test_the_proof_only_counts_once_we_have_moved(void)
{
    reset();
    xprschan_invite(PEER, 6, 30, false);
    xprschan_tick();
    char id[XPRS_ID_LEN];
    invite_id(id);
    char ack[XPRS_MAX_WIRE + 1];
    snprintf(ack, sizeof ack, "t:receipt f:%s d:%s r:%s s:ack sig:%.60s",
             PEER, SELF, id, FAKE_SIG);

    hear(ack);                       /* step 2, heard on the commons */
    CHECK(xprschan_state() == XC_WORKING, "did not commit to the move");
    CHECK(xc_test_moves == 0, "moved from the receive path");

    hear(ack);                       /* the invitee repeating itself, still home */
    CHECK(working_calls == 0, "counted a commons repeat as the working-channel proof");

    xprschan_tick();                 /* the move actually happens here */
    CHECK(xc_test_moves == 1, "did not move on the tick");
    CHECK(xc_test_channel == 6, "on channel %u", xc_test_channel);
    CHECK(working_calls == 0, "proved by arriving, without hearing anybody");

    hear(ack);                       /* step 4, and now it means something */
    CHECK(working_calls == 1, "the proof on the working channel did not count");
}

static void test_the_inviter_comes_home_when_nobody_proves_it(void)
{
    reset();
    xprschan_invite(PEER, 6, 30, false);
    xprschan_tick();
    char id[XPRS_ID_LEN];
    invite_id(id);
    char ack[XPRS_MAX_WIRE + 1];
    snprintf(ack, sizeof ack, "t:receipt f:%s d:%s r:%s s:ack sig:%.60s",
             PEER, SELF, id, FAKE_SIG);
    hear(ack);
    xprschan_tick();
    int before = aired_n;

    advance(XC_PROOF_WAIT_MS + 1000);
    CHECK(xprschan_state() == XC_IDLE, "still on the working channel alone");
    CHECK(xc_test_homes == 1, "came home %d times", xc_test_homes);
    CHECK(xc_test_channel == 0, "channel %u", xc_test_channel);
    /* §23.7 step 6: no error packet. The station that failed to arrive is not
     * listening anywhere this could reach. */
    CHECK(aired_n == before, "aired %d packets while alone", aired_n - before);
    CHECK(reconnect_held == 0, "the reconnect hold was not released");
}

/* ── As the invitee ─────────────────────────────────────────────────────── */

static void invite_us(char *out, int cap, const char *extra)
{
    snprintf(out, (size_t)cap,
             "t:channel f:%s d:%s link:espnow ch:6%s q:ack epoch:12 sig:%.60s",
             PEER, SELF, extra ? extra : "", FAKE_SIG);
}

static void test_an_unsigned_invitation_is_not_followed(void)
{
    reset();
    char inv[XPRS_MAX_WIRE + 1];
    snprintf(inv, sizeof inv,
             "t:channel f:%s d:%s link:espnow ch:6 q:ack epoch:12", PEER, SELF);
    hear(inv);
    CHECK(xprschan_state() == XC_IDLE, "followed an unsigned invitation");
    CHECK(aired_n == 0, "answered an unsigned invitation");
    CHECK(xc_test_moves == 0, "moved on an unsigned invitation");
}

static void test_an_invitation_from_a_stranger_is_not_followed(void)
{
    reset();
    sig_valid = false;
    char inv[XPRS_MAX_WIRE + 1];
    invite_us(inv, sizeof inv, NULL);
    hear(inv);
    CHECK(xprschan_state() == XC_IDLE, "followed a stranger");
    CHECK(aired_n == 0, "answered a stranger");
}

static void test_accepting_commits_and_moves_on_the_tick(void)
{
    reset();
    char inv[XPRS_MAX_WIRE + 1];
    invite_us(inv, sizeof inv, NULL);
    hear(inv);
    CHECK(xprschan_state() == XC_WORKING, "did not accept");
    CHECK(aired_with("s:ack") == 1, "aired %d acceptances", aired_with("s:ack"));
    CHECK(xc_test_moves == 0, "moved from the receive path");

    xprschan_tick();
    CHECK(xc_test_moves == 1, "did not move on the tick");
    CHECK(xc_test_channel == 6, "on channel %u", xc_test_channel);
    /* Spread across more than a second, not burst into one moment. */
    CHECK(xc_test_slept_ms >= 700, "left after only %ums", xc_test_slept_ms);
    CHECK(aired_with("s:ack") >= 4, "only %d acceptances", aired_with("s:ack"));
    CHECK(working_calls == 1, "never reported the working channel");

    /* Every one of them is the SAME packet — that is what makes it a proof. */
    const char *first = NULL;
    for (int i = 0; i < aired_n; i++) {
        if (!strstr(aired[i], "s:ack")) continue;
        if (!first) first = aired[i];
        else CHECK(strcmp(first, aired[i]) == 0, "airing %d differs: %s", i, aired[i]);
    }
}

/* The other half of the retry: an inviter that heard nothing asks again, and
 * this station must say yes again rather than answer `s:no busy` — which the
 * inviter reads as a refusal and gives up on an exchange that was only slow. */
static void test_a_repeated_invitation_gets_the_same_yes(void)
{
    reset();
    char inv[XPRS_MAX_WIRE + 1];
    invite_us(inv, sizeof inv, NULL);
    hear(inv);
    int acks = aired_with("s:ack");
    int moves = xc_test_moves;

    hear(inv);                       /* the same invitation, once more */
    CHECK(aired_with("s:no") == 0, "answered a repeat with a refusal");
    CHECK(aired_with("s:ack") == acks + 1, "did not repeat the acceptance");
    CHECK(xc_test_moves == moves, "moved twice for one invitation");
    CHECK(strcmp(aired[aired_n - 1], aired[aired_n - 2]) == 0,
          "the repeat is not the same packet");
}

static void test_a_different_invitation_while_busy_is_refused(void)
{
    reset();
    char inv[XPRS_MAX_WIRE + 1];
    invite_us(inv, sizeof inv, NULL);
    hear(inv);
    xprschan_tick();

    char other[XPRS_MAX_WIRE + 1];
    snprintf(other, sizeof other,
             "t:channel f:X3ZZZZ d:%s link:espnow ch:9 q:ack epoch:99 sig:%.60s",
             SELF, FAKE_SIG);
    hear(other);
    CHECK(aired_with("s:no") == 1, "did not refuse a second invitation");
    CHECK(xc_test_channel == 6, "wandered to channel %u", xc_test_channel);
}

static void test_a_bearer_that_refuses_leaves_nothing_behind(void)
{
    reset();
    air_works = false;
    char inv[XPRS_MAX_WIRE + 1];
    invite_us(inv, sizeof inv, NULL);
    hear(inv);
    CHECK(xprschan_state() == XC_IDLE, "committed to a move it never announced");
    CHECK(xc_test_moves == 0, "moved without an acceptance on the air");

    /* And the next attempt is treated as new, not as a repeat of something we
     * never actually said. */
    air_works = true;
    hear(inv);
    CHECK(xprschan_state() == XC_WORKING, "the retry was not accepted");
    CHECK(aired_with("s:ack") == 1, "aired %d", aired_with("s:ack"));
}

static void test_the_stay_is_bounded_whatever_until_says(void)
{
    reset();
    char inv[XPRS_MAX_WIRE + 1];
    /* An hour away, says the packet. The deadline is local and is not
     * negotiable; a station with no clock cannot even read this. */
    invite_us(inv, sizeof inv, " until:2099-01-01_00:00:00");
    hear(inv);
    xprschan_tick();
    CHECK(xc_test_channel == 6, "did not move");

    advance(XC_MAX_AWAY_MS + 2000);
    CHECK(xprschan_state() == XC_IDLE, "still away past the ceiling");
    CHECK(xc_test_channel == 0, "on channel %u", xc_test_channel);
    CHECK(xc_test_homes == 1, "came home %d times", xc_test_homes);
    CHECK(reconnect_held == 0, "the reconnect hold was not released");
}

static void test_abort_comes_home_from_the_working_channel(void)
{
    reset();
    char inv[XPRS_MAX_WIRE + 1];
    invite_us(inv, sizeof inv, NULL);
    hear(inv);
    xprschan_tick();
    CHECK(xc_test_channel == 6, "did not move");
    xprschan_abort("asked to");
    CHECK(xprschan_state() == XC_IDLE, "still busy");
    CHECK(xc_test_channel == 0, "on channel %u", xc_test_channel);
    CHECK(reconnect_held == 0, "the reconnect hold was not released");
}

/* The fault this whole component tripped over for a week, pinned.
 *
 * On ESP32 a running BLE controller costs an UNASSOCIATED station every
 * incoming frame -- measured one variable at a time in esp32/espnow_probe. So
 * Bluetooth must go off before the station lets go of the access point, and
 * come back only on the way home. An implementation that merely calls both at
 * some point in the move would pass a naive test and still be deaf. */
static void test_bluetooth_goes_off_before_we_leave_and_on_after(void)
{
    reset();
    char inv[XPRS_MAX_WIRE + 1];
    invite_us(inv, sizeof inv, NULL);
    hear(inv);
    xprschan_tick();
    CHECK(xc_test_channel == 6, "did not move");
    CHECK(bt_off_calls == 1, "Bluetooth switched off %d times", bt_off_calls);
    CHECK(!bt_running, "still on the air while away");
    CHECK(order_index("bt_off") >= 0 && order_index("hold") >= 0 &&
          order_index("bt_off") < order_index("hold"),
          "Bluetooth went off after the station let go of the access point");

    advance(XC_MAX_AWAY_MS + 2000);
    CHECK(xprschan_state() == XC_IDLE, "never came home");
    CHECK(bt_on_calls == 1, "Bluetooth switched on %d times", bt_on_calls);
    CHECK(bt_running, "came home without Bluetooth");
    CHECK(order_index("release") < order_index("bt_on"),
          "Bluetooth came back before the reconnect was released");
}

/* And the exchange that never happens must not cost the station its Bluetooth:
 * an invitation nobody answers moves nothing, so nothing may be switched off. */
static void test_bluetooth_is_untouched_when_nobody_moves(void)
{
    reset();
    xprschan_invite(PEER, 6, 30, false);
    xprschan_tick();
    advance(XC_INVITE_FRESH_MS + 1000);
    CHECK(xprschan_state() == XC_IDLE, "still waiting");
    CHECK(bt_off_calls == 0, "took Bluetooth down for an exchange that never was");
    CHECK(bt_running, "Bluetooth left off");
}

/* Section 23.7 step 5: "when it ends -- or until: passes, whichever is first --
 * EVERYONE returns to the calling channel." Everyone means the invitee too, and
 * the invitee here has no clock: `no_clock` returns 0, exactly like the M5Stack.
 *
 * It can still work the window out, because the invitation carries its own `ts:`
 * next to the `until:`, and the difference between them is a duration rather
 * than a time. Before this, a clockless station could read neither and fell back
 * to XC_DEFAULT_AWAY_MS -- staying on the working channel long after the inviter
 * had gone home, deaf to the commons and to the next invitation. Two of ten
 * attempts died that way. */
static void test_a_clockless_invitee_keeps_the_inviters_window(void)
{
    reset();
    /* Sent at 16:00:00, good until 16:00:20 -- twenty seconds, stated by a
     * packet, readable by a station that does not know what year it is. */
    char inv[XPRS_MAX_WIRE + 1];
    snprintf(inv, sizeof inv,
             "t:channel f:%s d:%s link:espnow ch:6 until:2026-08-17_16:00:20 "
             "q:ack ts:2026-08-17_16:00:00 sig:%.60s", PEER, SELF, FAKE_SIG);
    hear(inv);
    xprschan_tick();
    CHECK(xc_test_channel == 6, "did not move");

    /* Still there just before the twenty seconds are up... */
    advance(18000);
    CHECK(xc_test_channel == 6, "left after 18s of a 20s window");
    /* ...and home not long after, rather than at the 30-second default. */
    advance(4000);
    CHECK(xprschan_state() == XC_IDLE, "still away past the inviter's window");
    CHECK(xc_test_channel == 0, "on channel %u", xc_test_channel);
}

static void test_an_invitation_with_no_until_falls_back(void)
{
    reset();
    char inv[XPRS_MAX_WIRE + 1];
    invite_us(inv, sizeof inv, NULL);      /* no until: at all */
    hear(inv);
    xprschan_tick();
    advance(XC_DEFAULT_AWAY_MS - 3000);
    CHECK(xc_test_channel == 6, "left early with nothing to go on");
    advance(5000);
    CHECK(xprschan_state() == XC_IDLE, "never came home");
}

/* And the ceiling still is not negotiable, however generous the arithmetic. */
static void test_a_long_window_is_still_capped(void)
{
    reset();
    char inv[XPRS_MAX_WIRE + 1];
    snprintf(inv, sizeof inv,
             "t:channel f:%s d:%s link:espnow ch:6 until:2026-08-17_16:05:00 "
             "q:ack ts:2026-08-17_16:00:00 sig:%.60s", PEER, SELF, FAKE_SIG);
    hear(inv);                              /* five minutes, says the packet */
    xprschan_tick();
    advance(XC_MAX_AWAY_MS + 2000);
    CHECK(xprschan_state() == XC_IDLE, "a packet talked us into staying away");
    CHECK(xc_test_channel == 0, "on channel %u", xc_test_channel);
}

int main(void)
{
    printf("xprschan host tests (XPRS.md section 23.7)\n");
    test_invite_is_aired_and_signed();
    test_a_station_that_will_not_move_does_not_invite();
    test_silence_ends_it_with_nobody_moved();
    test_the_invitation_is_repeated_while_waiting();
    test_an_unverifiable_answer_is_ignored();
    test_an_answer_naming_another_invitation_is_ignored();
    test_no_hardware_ends_it_without_moving();
    test_the_proof_only_counts_once_we_have_moved();
    test_the_inviter_comes_home_when_nobody_proves_it();

    test_an_unsigned_invitation_is_not_followed();
    test_an_invitation_from_a_stranger_is_not_followed();
    test_accepting_commits_and_moves_on_the_tick();
    test_a_repeated_invitation_gets_the_same_yes();
    test_a_different_invitation_while_busy_is_refused();
    test_a_bearer_that_refuses_leaves_nothing_behind();
    test_the_stay_is_bounded_whatever_until_says();
    test_abort_comes_home_from_the_working_channel();
    test_bluetooth_goes_off_before_we_leave_and_on_after();
    test_bluetooth_is_untouched_when_nobody_moves();
    test_a_clockless_invitee_keeps_the_inviters_window();
    test_an_invitation_with_no_until_falls_back();
    test_a_long_window_is_still_capped();

    printf("%d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
