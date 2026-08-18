/*
 * Meeting on a working channel — XPRS.md §23.7. Read xprschan.h first.
 *
 * The whole file is one small state machine and one large piece of caution: a
 * station that changes channel has left the network, and the only thing that
 * brings it back is this code running correctly. Every path that leaves home
 * sets the same deadline, and xprschan_tick() enforces it whatever else has
 * gone wrong.
 */

#include "xprschan.h"

#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#ifdef XPRSCHAN_HOST_TEST

/* Everything except the radio compiles on the host, on the same terms as
 * geogram_xprslan: the test owns the clock, supplies `air` through the ops, and
 * the three functions that retune hardware become counters. Every bug this file
 * has had so far was found by flashing two boards and watching, which is a slow
 * way to learn that a state machine took a branch. */
#define XC_LOGI(...) ((void)0)
#define XC_LOGW(...) ((void)0)

/* Not a sleep: the harness is single-threaded, so a delay is time passing. */
uint32_t xc_test_now_ms;
uint32_t xc_test_slept_ms;
static void xc_delay_ms(uint32_t ms) { xc_test_now_ms += ms; xc_test_slept_ms += ms; }

/* What the radio was asked to do. */
uint8_t  xc_test_channel;      /* where we are, 0 until something moves us */
bool     xc_test_lr;
int      xc_test_moves;
int      xc_test_homes;
int      xc_test_reconnect_held;

#else /* on the device */

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_wifi.h"
#include "esp_now.h"

#define XC_LOGI(...) ESP_LOGI(TAG, __VA_ARGS__)
#define XC_LOGW(...) ESP_LOGW(TAG, __VA_ARGS__)

static void xc_delay_ms(uint32_t ms) { vTaskDelay(pdMS_TO_TICKS(ms)); }

static const uint8_t k_broadcast[6] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

#endif

static const char *TAG __attribute__((unused)) = "xprschan";

/* `YYYY-MM-DD_hh:mm:ss` (§4.3) as epoch seconds, or 0. Small enough to keep
 * here rather than depend on the index for one field. */
static uint32_t xc_ts_epoch(const char *v)
{
    int Y = 0, M = 0, D = 0, h = 0, m = 0, s = 0;
    if (!v || sscanf(v, "%4d-%2d-%2d_%2d:%2d:%2d", &Y, &M, &D, &h, &m, &s) != 6)
        return 0;
    if (Y < 1970 || M < 1 || M > 12 || D < 1 || D > 31) return 0;
    static const int cum[12] = {0,31,59,90,120,151,181,212,243,273,304,334};
    long days = (long)(Y - 1970) * 365 + ((Y - 1969) / 4) + cum[M - 1] + (D - 1);
    if (M > 2 && ((Y % 4 == 0 && Y % 100 != 0) || Y % 400 == 0)) days++;
    return (uint32_t)(days * 86400L + h * 3600 + m * 60 + s);
}

static xc_ops_t  s_ops;
static char      s_call[10];
static xc_state_t s_state;

/* The exchange in hand. */
static char     s_peer[10];
static char     s_invite_id[XPRS_ID_LEN];   /* what an answer must name in r: */
static uint8_t  s_channel;
static bool     s_lr;
static bool     s_inviter;
static uint32_t s_deadline_ms;              /* local, and not negotiable */
static uint32_t s_invite_stale_ms;          /* step 2: how long we wait */
static uint32_t s_away_ms;                  /* how long we will stay once moved */
static uint32_t s_proof_by_ms;              /* inviter: nobody came (step 6) */
static bool     s_proved;                   /* step 4 has been heard */
/* The radio is ACTUALLY on the working channel — not merely decided to be.
 *
 * The decision is taken where the acceptance is heard and performed a tick
 * later, and the invitee keeps repeating that acceptance on the commons in the
 * meantime. Without this the inviter counted one of those commons repeats as
 * step 4 and declared the channel proved while still sitting on channel 1 —
 * measured, and the proof is worthless there: the whole point of step 4 is that
 * hearing it HERE is what cannot be faked from anywhere else. */
static bool     s_moved;

/* Home, so we can go back to it. */
static uint8_t  s_home_channel __attribute__((unused));
static bool     s_was_associated __attribute__((unused));

/* The acceptance we sent, kept verbatim: step 4 re-airs THE SAME packet, same
 * signature, same identifier. A fresh one would prove nothing — anybody can
 * compose a packet; only the party that committed can repeat that one. */
static char     s_accept_wire[XPRS_MAX_WIRE + 1];
static int      s_accept_len;
/* Which invitation that acceptance answers. An inviter that heard nothing re-airs
 * the same invitation, and the invitee must recognise it as the one it already
 * said yes to — otherwise it answers `s:no busy`, which the inviter reads as a
 * refusal and abandons an exchange that was going fine. */
static char     s_accept_r[XPRS_ID_LEN];
static uint32_t s_accept_aired;    /* airings the bearer took */
static uint32_t s_accept_lost;     /* airings it refused */

/* The invitation we sent, kept verbatim for the same reason: identical bytes
 * mean an identical §5 identifier, so an answer's `r:` still names it. */
static char     s_invite_wire[XPRS_MAX_WIRE + 1];
static int      s_invite_len;
static uint32_t s_invite_last_ms;
static uint32_t s_invite_tries;

/* ── The radio ──────────────────────────────────────────────────────────── */

#ifdef XPRSCHAN_HOST_TEST

static void xc_set_lr(bool on) { xc_test_lr = on; }
static void xc_keep_channel(uint8_t channel) { (void)channel; }

/* The fake radio mirrors the real one's ORDER, not just its effects. Bluetooth
 * before the station lets go of the access point on the way out, and after the
 * reconnect is released on the way back -- that ordering is the fix for the
 * fault measured in esp32/espnow_probe, so it is the thing worth testing. */
static void xc_go(uint8_t channel, bool lr)
{
    if (s_ops.bluetooth) s_ops.bluetooth(false);
    if (s_ops.hold_reconnect) s_ops.hold_reconnect(true);
    if (lr) xc_set_lr(true);
    xc_test_channel = channel;
    xc_test_moves++;
}
static void xc_come_home(void)
{
    if (s_lr) xc_set_lr(false);
    if (s_ops.hold_reconnect) s_ops.hold_reconnect(false);
    xc_test_channel = 0;
    xc_test_homes++;
    if (s_ops.bluetooth) s_ops.bluetooth(true);
}

#else

static void xc_set_lr(bool on)
{
    uint8_t bitmap = WIFI_PROTOCOL_11B | WIFI_PROTOCOL_11G | WIFI_PROTOCOL_11N;
    if (on) bitmap |= WIFI_PROTOCOL_LR;
    esp_err_t e = esp_wifi_set_protocol(WIFI_IF_STA, bitmap);
    if (e != ESP_OK) {
        XC_LOGW("set_protocol(%s) failed: %s", on ? "with LR" : "plain",
                 esp_err_to_name(e));
        return;
    }
    /* The rate has to be told separately, and the driver refuses the pairing
     * unless the phy mode and the rate agree — it says so in as many words:
     * "invalid LR rate, need change rate to WIFI_PHY_RATE_LORA_250K or
     * WIFI_PHY_RATE_LORA_500K". Back to the default on the way home. */
    /* On the way back, 11B with the 1 Mbps long-preamble rate — a pairing the
     * driver accepts. 11G with a 1 Mbps rate is not one (1 Mbps is an 11b
     * rate), and a refused rate config leaves the broadcast peer in whatever
     * state the failed call left it: the bearer went deaf after one round trip
     * and stayed that way until a reboot. */
    esp_now_rate_config_t rc = {
        .phymode = on ? WIFI_PHY_MODE_LR : WIFI_PHY_MODE_11B,
        .rate    = on ? WIFI_PHY_RATE_LORA_250K : WIFI_PHY_RATE_1M_L,
        .ersu    = false,
        .dcm     = false,
    };
    e = esp_now_set_peer_rate_config(k_broadcast, &rc);
    if (e != ESP_OK) {
        XC_LOGW("rate config refused: %s", esp_err_to_name(e));
    }
}

/* Two things the driver is entitled to change under us when the station stops
 * being associated, and both of them make this bearer silently deaf.
 *
 * Power save: a station that sleeps misses ESP-NOW frames — Espressif's own
 * example says so — and WIFI_PS_NONE was set once, at boot, while associated.
 * Leaving the access point is exactly the event that may restore the default.
 *
 * The peer channel: the broadcast peer is registered with channel 0, meaning
 * "wherever the station is". That is the right answer while associated and an
 * ambiguous one immediately after a manual retune, so name the channel.
 *
 * Measured before this existed: both boards reported themselves on channel 6,
 * the invitee's driver reported 21 frames sent, and neither board received a
 * single byte from the other for fourteen seconds — deaf in both directions at
 * once, which is not something one board's timing can cause.
 */
static void xc_hold_the_radio_awake(uint8_t channel)
{
    esp_wifi_set_ps(WIFI_PS_NONE);
    esp_now_peer_info_t peer;
    if (esp_now_get_peer(k_broadcast, &peer) == ESP_OK) {
        peer.channel = channel;          /* 0 on the way home: follow the station */
        esp_err_t e = esp_now_mod_peer(&peer);
        if (e != ESP_OK) XC_LOGW("peer channel %u refused: %s", channel,
                                 esp_err_to_name(e));
    }
}

/* Are we still where we think we are?
 *
 * Stopping the scan once, at the moment of the move, only helps if the driver
 * never starts another -- and a disconnected station keeps looking for its
 * network. This runs while we are away and puts the radio back when it has
 * drifted, which is also the only way anybody finds out that it did.
 */
static void xc_keep_channel(uint8_t channel)
{
    uint8_t now_ch = 0;
    wifi_second_chan_t sec = WIFI_SECOND_CHAN_NONE;
    if (esp_wifi_get_channel(&now_ch, &sec) != ESP_OK) return;
    if (now_ch == channel) return;
    XC_LOGW("drifted to channel %u -- going back to %u", now_ch, channel);
    esp_wifi_scan_stop();
    esp_wifi_set_channel(channel, WIFI_SECOND_CHAN_NONE);
}

static void xc_go(uint8_t channel, bool lr)
{
    wifi_second_chan_t second = WIFI_SECOND_CHAN_NONE;
    esp_wifi_get_channel(&s_home_channel, &second);

    wifi_ap_record_t ap;
    s_was_associated = (esp_wifi_sta_get_ap_info(&ap) == ESP_OK);

    /* Leaving the access point is the point, not an accident: on this channel
     * we are deaf to it and to everything it carries. §23.7 calls that ordinary
     * absence, and it is only ordinary because we come back. */
    /* Bluetooth goes first, and it goes before the disassociation rather than
     * after: the moment this station stops being associated is the moment a
     * running BLE controller costs it every incoming frame. */
    if (s_ops.bluetooth) s_ops.bluetooth(false);

    /* Say so BEFORE disconnecting, or the reconnect fires on the way out. */
    if (s_ops.hold_reconnect) s_ops.hold_reconnect(true);
    if (s_was_associated) {
        esp_wifi_disconnect();
        /* AND WAIT FOR IT. esp_wifi_disconnect() is asynchronous: setting the
         * channel while the station is still associated does not move it — the
         * driver restores the access point's home channel underneath us, and
         * the move silently never happens. Measured: "moved to channel 6"
         * followed 70 ms later by "connected ... channel 1". */
        /* Up to two seconds, not six hundred milliseconds. Six hundred was a
         * guess, and the cost of guessing short is being deaf on a channel we
         * believe we are on: measured, the far side's proof took between one
         * and five seconds to be heard after the move, and one attempt in four
         * never heard it inside the eight-second window at all. That is what a
         * station looks like when it arrives late to its own rendezvous. */
        int waited = 0;
        for (; waited < 100; waited++) {        /* up to ~2 s */
            wifi_ap_record_t ap2;
            if (esp_wifi_sta_get_ap_info(&ap2) != ESP_OK) break;
            xc_delay_ms(20);
        }
        if (waited >= 100) XC_LOGW("still associated after 2s — the move may not take");
        else               XC_LOGI("let go of the access point in %dms", waited * 20);
    }
    if (lr) xc_set_lr(true);
    esp_err_t e = esp_wifi_set_channel(channel, WIFI_SECOND_CHAN_NONE);
    if (e != ESP_OK) XC_LOGW("set_channel(%u): %s", channel,
                              esp_err_to_name(e));
    /* And STOP LOOKING FOR THE ACCESS POINT.
     *
     * A station that has just been disconnected hunts for its network, and a
     * scan hops every channel in turn -- so the radio spends most of its time
     * somewhere other than where esp_wifi_get_channel() says it is, which is
     * exactly the shape of the fault: both boards reporting channel 6, both
     * drivers reporting frames sent, neither hearing a byte from the other.
     * ESP_ERR_WIFI_STATE here simply means there was no scan to stop.
     *
     * OUTBOUND ONLY. On the way home a scan is not the problem, it is the
     * mechanism: esp_wifi_connect() starts one, and stopping it leaves the
     * station on the working channel for good. Measured doing exactly that --
     * "back on the calling channel" while the heartbeat still said ch=6. */
    esp_err_t st = esp_wifi_scan_stop();
    if (st == ESP_OK) XC_LOGW("a scan was running -- stopped it");
    else if (st != ESP_ERR_WIFI_STATE && st != ESP_ERR_WIFI_NOT_STARTED)
        XC_LOGW("scan_stop: %s", esp_err_to_name(st));
    esp_wifi_set_channel(channel, WIFI_SECOND_CHAN_NONE);   /* a scan moved it */

    xc_hold_the_radio_awake(channel);

    /* Read it back rather than trust the calls, and read it LAST -- the driver
     * quietly restoring the access point's channel is the exact failure this
     * path exists to avoid, and it does not announce itself. */
    uint8_t actual = 0;
    wifi_second_chan_t back = WIFI_SECOND_CHAN_NONE;
    esp_wifi_get_channel(&actual, &back);
    if (actual != channel)
        XC_LOGW("asked for channel %u but the radio says %u", channel, actual);
    XC_LOGW("moved to channel %u (radio says %u)%s — deaf to the commons until "
            "we return", channel, actual, lr ? " on the long-range PHY" : "");
}

static void xc_come_home(void)
{
    if (s_lr) xc_set_lr(false);
    if (s_ops.hold_reconnect) s_ops.hold_reconnect(false);
    if (s_was_associated) {
        /* Reconnecting restores the access point's channel by itself, which is
         * a safer way home than remembering a number. */
        esp_wifi_connect();
    } else if (s_home_channel) {
        esp_wifi_set_channel(s_home_channel, WIFI_SECOND_CHAN_NONE);
    }
    xc_hold_the_radio_awake(0);   /* 0: follow the station again */
    /* And Bluetooth last, after the station is on its way back to the access
     * point -- the order that took it off the air, reversed. */
    if (s_ops.bluetooth) s_ops.bluetooth(true);
    XC_LOGW("back on the calling channel");
}

#endif /* XPRSCHAN_HOST_TEST */

/* ── Composing ──────────────────────────────────────────────────────────── */

static bool xc_air_signed(char *wire, int len)
{
    if (len <= 0 || len > XPRS_MAX_WIRE) return false;
    if (s_ops.sign) len = s_ops.sign(wire, len, XPRS_MAX_WIRE + 1);
    return s_ops.air && s_ops.air(wire, len);
}

/* ── Going home, one place ──────────────────────────────────────────────── */

static void xc_finish(const char *why __attribute__((unused)), bool worked)
{
    if (s_state == XC_WORKING) xc_come_home();
    XC_LOGI("exchange with %s ended: %s", s_peer[0] ? s_peer : "nobody",
             why);
    /* What the attempt cost, whichever side we were. The invitation count is
     * the honest measure of how hard the commons was to reach — an exchange
     * that took six tries and one that took one both end with the same line
     * otherwise. */
    if (s_inviter) {
        XC_LOGI("  invitation aired %u time(s)", (unsigned)s_invite_tries);
    } else if (s_accept_aired || s_accept_lost) {
        XC_LOGI("  acceptance aired %u time(s), %u refused by the bearer",
                 (unsigned)s_accept_aired, (unsigned)s_accept_lost);
    }
    if (s_ops.trace) s_ops.trace(false);
    char peer[10];
    snprintf(peer, sizeof peer, "%s", s_peer);
    s_state = XC_IDLE;
    s_peer[0] = 0;
    s_invite_id[0] = 0;
    s_accept_len = 0;
    s_accept_r[0] = 0;
    s_accept_aired = 0;
    s_accept_lost = 0;
    s_invite_len = 0;
    s_invite_tries = 0;
    s_proved = false;
    s_moved = false;
    s_lr = false;
    if (s_ops.on_home) s_ops.on_home(peer, worked);
}

/* One airing of the acceptance, counted either way.
 *
 * The bearer's answer was thrown away everywhere this used to be written, so a
 * refused send — a full driver queue is the ordinary cause — was indistinguish-
 * able from a send that went out and was not heard. Those need opposite fixes. */
static void xc_air_accept(const char *when __attribute__((unused)))
{
    if (s_accept_len <= 0 || !s_ops.air) return;
    if (s_ops.air(s_accept_wire, s_accept_len)) {
        s_accept_aired++;
    } else {
        s_accept_lost++;
        XC_LOGW("the bearer refused the acceptance (%s) — %u refused now",
                 when, (unsigned)s_accept_lost);
    }
}

void xprschan_abort(const char *why) { if (s_state != XC_IDLE) xc_finish(why, false); }

/* ── Step 1: invite ─────────────────────────────────────────────────────── */

/* A move that has been decided but not yet performed.
 *
 * xc_go() disconnects and waits up to 600 ms for the driver to let go of the
 * access point, and it used to do that on the task that drains the receive
 * queue — so nothing was emptying that queue during the exact window the far
 * side's step-4 proof arrives in. The decision is made where the packet is
 * heard; the blocking is done on the ticking task. */
static uint32_t s_arrived_ms;     /* invitee: when we reached the channel */

/* How long to wait before saying it again.
 *
 * The two stations do not arrive together — the inviter has an access point to
 * let go of first — so the seconds right after arriving are the ones where a
 * repeat is most likely to be the first thing the other end hears, and the
 * ones where a second of silence is most expensive. Quick at first, then the
 * ordinary cadence for the rest of the stay. */
static uint32_t xc_announce_gap(uint32_t now)
{
    return ((uint32_t)(now - s_arrived_ms) < XC_ARRIVAL_HURRY_MS)
               ? XC_ANNOUNCE_FAST_MS : XC_ANNOUNCE_EVERY_MS;
}

static bool    s_want_move;
static uint32_t s_announce_ms;    /* invitee: when step 4 last went out */
static uint8_t s_move_channel;
static bool    s_move_lr;

/* What was asked for, waiting for a task with the stack to sign it. */
static bool     s_want_invite;
static char     s_want_peer[10];
static uint8_t  s_want_channel;
static uint32_t s_want_seconds;
static bool     s_want_lr;

bool xprschan_invite(const char *peer, uint8_t channel, uint32_t seconds,
                     bool lr)
{
    if (s_state != XC_IDLE || s_want_invite || !peer || !peer[0] || !channel)
        return false;
    if (s_ops.may_move && !s_ops.may_move()) {
        XC_LOGW("not inviting: this station does not leave the commons");
        return false;
    }
    snprintf(s_want_peer, sizeof s_want_peer, "%s", peer);
    s_want_channel = channel;
    s_want_seconds = seconds;
    s_want_lr = lr;
    s_want_invite = true;      /* xprschan_tick() does the signing */
    return true;
}

static bool xc_do_invite(const char *peer, uint8_t channel, uint32_t seconds,
                         bool lr)
{
    if (s_state != XC_IDLE) return false;

    uint32_t away = seconds * 1000u;
    if (away == 0 || away > XC_MAX_AWAY_MS) away = XC_MAX_AWAY_MS;

    char ts[24], until[40];
    s_ops.time_field(ts, sizeof ts);
    uint32_t now_epoch = s_ops.epoch ? s_ops.epoch() : 0;
    if (now_epoch) {
        uint32_t u = now_epoch + away / 1000u;
        time_t tt = (time_t)u;
        struct tm g;
        gmtime_r(&tt, &g);
        /* Clamped fields: gmtime_r cannot return out-of-range values, but the
         * compiler cannot know that and refuses the format otherwise. */
        snprintf(until, sizeof until, " until:%04d-%02d-%02d_%02d:%02d:%02d",
                 (g.tm_year + 1900) % 10000, (g.tm_mon + 1) % 100,
                 g.tm_mday % 100, g.tm_hour % 100, g.tm_min % 100,
                 g.tm_sec % 100);
    } else {
        until[0] = 0;   /* no clock: the deadline is local anyway */
    }

    /* "Here is who I am", then "meet me". The far side cannot act on the
     * second without the first, and a station that rebooted five minutes ago
     * has not heard it yet. */
    if (s_ops.announce_identity) {
        s_ops.announce_identity();
        xc_delay_ms(150);
    }

    char wire[XPRS_MAX_WIRE + 1];
    int n = snprintf(wire, sizeof wire,
                     "t:channel f:%s d:%s link:espnow ch:%u%s q:ack %s",
                     s_call, peer, channel, until, ts);
    if (n <= 0 || n > XPRS_MAX_WIRE) {
        XC_LOGW("the invitation does not fit in a packet (%d bytes)", n);
        return false;
    }
    if (s_ops.sign) n = s_ops.sign(wire, n, (int)sizeof wire);

    /* The identifier of what we actually aired is what an answer must name. */
    if (!xprs_id_of(wire, n, s_invite_id)) {
        XC_LOGW("cannot derive an identifier for the invitation");
        return false;
    }

    /* From here until the exchange ends, every packet the bearer hears is
     * logged. This is the window where a missing answer has to be told apart
     * from an answer that arrived and was refused, and no counter can do it. */
    if (s_ops.trace) s_ops.trace(true);

    /* Let the identity clear the radio before the invitation follows it. The
     * two used to go out 150 ms apart and the answer landed on top of the
     * second one; a station cannot hear while it talks. */
    if (s_ops.settle) s_ops.settle(300);

    if (!s_ops.air(wire, n)) {
        XC_LOGW("the bearer refused the invitation (%d bytes)", n);
        if (s_ops.trace) s_ops.trace(false);
        return false;
    }
    memcpy(s_invite_wire, wire, (size_t)n);
    s_invite_len = n;
    s_invite_tries = 1;
    s_invite_last_ms = s_ops.now_ms();

    snprintf(s_peer, sizeof s_peer, "%s", peer);
    s_channel = channel;
    s_lr = lr;
    s_inviter = true;
    s_state = XC_INVITED;
    s_away_ms = away;                       /* applied at the moment of the move */
    s_invite_stale_ms = s_ops.now_ms() + XC_INVITE_FRESH_MS;
    s_proof_by_ms = 0;
    s_proved = false;
    s_moved = false;
    XC_LOGI("invited %s to channel %u%s (%s) — waiting on the commons",
             peer, channel, lr ? " LR" : "", s_invite_id);
    return true;
}

/* ── Steps 2-4: the answers ─────────────────────────────────────────────── */

/* An invitation addressed to us. */
static bool xc_on_invite(const xprs_t *p, const char *wire, int len)
{
    (void)wire; (void)len;
    char to[10], from[10], link[12], chs[8];
    if (!xprs_get_str(p, "d", to, sizeof to) ||
        strcasecmp(to, s_call) != 0) return false;
    if (!xprs_get_str(p, "f", from, sizeof from) || !from[0]) return false;

    /* §23.7: an unsigned invitation is not followed. Nor an unverifiable one —
     * a station we hold no key for is a stranger asking us to leave the shared
     * channel, and there is nothing to weigh that against. */
    if (!s_ops.verified || !s_ops.verified(p)) {
        XC_LOGW("ignoring an invitation from %s: not signed by a key we "
                      "hold", from);
        return true;
    }

    char reply[XPRS_MAX_WIRE + 1];
    char id[XPRS_ID_LEN];
    xprs_id(p, id);

    /* The same invitation again, from the station we already said yes to.
     *
     * The inviter re-airs it when it has heard no answer, so a repeat means our
     * acceptance did not arrive — the one thing worth doing about it is sending
     * that acceptance again, verbatim. It must NOT be answered `s:no busy`,
     * which is what the willing test below would produce now that we are no
     * longer XC_IDLE: the inviter reads `s:no` as a refusal and ends an exchange
     * that was only slow. And it must not move us a second time. */
    if (s_accept_len > 0 && s_accept_r[0] && strcmp(id, s_accept_r) == 0) {
        XC_LOGI("%s is still asking — saying yes again", from);
        xc_air_accept("answering a repeated invitation");
        return true;
    }

    bool ours = xprs_get_str(p, "link", link, sizeof link) &&
                strcmp(link, "espnow") == 0 &&
                xprs_get_str(p, "ch", chs, sizeof chs);
    bool willing = ours && s_state == XC_IDLE &&
                   (!s_ops.may_move || s_ops.may_move());

    if (!willing) {
        /* §23.7: an invitee without the hardware answers s:no, and the pair
         * uses what they already share. Saying so is cheaper for both than
         * silence, which the inviter must wait out. */
        int n = snprintf(reply, sizeof reply,
                         "t:receipt f:%s d:%s r:%s s:no m:%s",
                         s_call, from, id,
                         ours ? "busy" : "no espnow channel here");
        if (n > 0) xc_air_signed(reply, n);
        return true;
    }

    int ch = atoi(chs);
    if (ch <= 0 || ch > 14) return true;

    /* Step 2: accept ON THE COMMONS. The acceptance is the commitment, so it
     * is composed once and kept — step 4 re-airs this exact packet. */
    int n = snprintf(s_accept_wire, sizeof s_accept_wire,
                     "t:receipt f:%s d:%s r:%s s:ack", s_call, from, id);
    if (n <= 0) return true;
    if (s_ops.sign) n = s_ops.sign(s_accept_wire, n, (int)sizeof s_accept_wire);
    s_accept_len = n;
    snprintf(s_accept_r, sizeof s_accept_r, "%s", id);
    s_accept_aired = 0;
    s_accept_lost = 0;
    if (s_ops.trace) s_ops.trace(true);
    /* Aired here, on whatever task heard the invitation — and NOT settled here,
     * because that task is the one draining the receive queue and blocking it
     * loses the packets arriving meanwhile. The airings that wait for the radio
     * are the ones the tick performs. */
    xc_air_accept("the commitment");
    if (s_accept_aired == 0) {
        /* Nothing was committed, so forget it entirely — leaving the identifier
         * behind would make the inviter's next attempt look like a repeat of an
         * acceptance we never sent, and we would answer it while staying home
         * as the inviter moved. */
        s_accept_len = 0;
        s_accept_r[0] = 0;
        if (s_ops.trace) s_ops.trace(false);
        return true;
    }

    /* How long we are willing to be away -- and §23.7 step 5 says EVERYONE
     * returns when the exchange ends or `until:` passes, so the two stations
     * have to arrive at the same answer or the pair does not come home together.
     *
     * `until:` is an absolute time, which a station with no clock cannot read.
     * That is how this ended up defaulting to XC_DEFAULT_AWAY_MS and staying on
     * the working channel long after the inviter had gone home, deaf to the
     * commons and to the next invitation -- measured, and it cost two of ten
     * attempts.
     *
     * But the invitation states its own `ts:` as well, and `until: - ts:` is a
     * DURATION: two fields of the same packet, subtracted. No clock is involved,
     * so a station without one gets exactly the window the inviter asked for.
     * The invitee's clock starts when it SENDS the acceptance and the inviter's
     * when it HEARS it, so equal durations bring the invitee home a moment
     * first, which is the right way round.
     *
     * Only the ceiling is non-negotiable: nothing on the wire can keep this
     * station away longer than XC_MAX_AWAY_MS. */
    uint32_t away = XC_DEFAULT_AWAY_MS;         /* nothing said: our own guess */
    char until[32], sent[32];
    if (xprs_get_str(p, "until", until, sizeof until)) {
        uint32_t u = xc_ts_epoch(until);
        /* The invitation's own timestamp first -- it needs no clock. Fall back
         * to ours only when the inviter dated the deadline but not the packet. */
        uint32_t base = 0;
        if (xprs_get_str(p, "ts", sent, sizeof sent)) base = xc_ts_epoch(sent);
        if (!base && s_ops.epoch) base = s_ops.epoch();
        if (base && u > base) away = (u - base) * 1000u;
    }
    if (away > XC_MAX_AWAY_MS) away = XC_MAX_AWAY_MS;

    snprintf(s_peer, sizeof s_peer, "%s", from);
    s_channel = (uint8_t)ch;
    s_lr = false;                 /* the inviter's PHY choice is not on the wire
                                   * yet; both ends use the plain rate until
                                   * §23.7 grows a word for it */
    s_inviter = false;
    s_state = XC_WORKING;
    s_proved = false;
    s_deadline_ms = s_ops.now_ms() + away;

    /* Step 3: on SENDING the acceptance, the invitee tunes and follows — but
     * not from here. Both the settle the send needs and the disconnect wait the
     * move needs are hundreds of milliseconds, and this runs on the task that
     * empties the receive queue. Hand it to the tick. */
    s_move_channel = s_channel;
    s_move_lr = s_lr;
    s_want_move = true;
    XC_LOGI("accepted %s: moving to channel %u for %ums", from,
             s_channel, (unsigned)away);
    return true;
}

/* A receipt that answers our invitation. */
static bool xc_on_receipt(const xprs_t *p, const char *wire, int len)
{
    char r[XPRS_ID_LEN], from[10], st[8];
    if (!xprs_get_str(p, "r", r, sizeof r)) {
        XC_LOGW("a receipt with no r: — nothing to match it to");
        return false;
    }
    if (!s_invite_id[0]) return false;         /* not ours to answer */
    if (strcmp(r, s_invite_id) != 0) {
        /* Loud, not debug. A mismatch here is the difference between "nobody
         * answered" and "somebody answered and we did not recognise our own
         * invitation", and those need completely different fixes. */
        XC_LOGW("a receipt names %s, but our invitation was %s", r,
                 s_invite_id);
        return false;
    }
    if (!xprs_get_str(p, "f", from, sizeof from)) return false;
    if (!xprs_get_str(p, "s", st, sizeof st)) return false;

    /* The acceptance is the commitment (§23.7 step 2) and step 4 leans on it
     * being unforgeable. An answer we cannot check is an answer from nobody in
     * particular, and acting on it is how a station ends up alone on a channel
     * somebody else named. */
    if (!s_ops.verified || !s_ops.verified(p)) {
        XC_LOGW("ignoring an answer from %s: not signed by a key we hold",
                 from);
        return true;
    }

    if (strcmp(st, "no") == 0) {
        if (s_state == XC_INVITED) xc_finish("they cannot", false);
        return true;
    }
    if (strcmp(st, "ack") != 0) return false;

    if (s_state == XC_INVITED) {
        /* Step 3: on HEARING the acceptance the inviter tunes and listens. It
         * does NOT start sending — that waits for step 4. */
        s_state = XC_WORKING;
        s_proved = false;
        s_move_channel = s_channel;
        s_move_lr = s_lr;
        s_want_move = true;                 /* performed on the ticking task */
        uint32_t t = s_ops.now_ms();
        s_deadline_ms = t + s_away_ms;      /* the clock starts on the decision */
        s_proof_by_ms = t + XC_PROOF_WAIT_MS;
        XC_LOGI("%s accepted — moved, now waiting for them to prove they "
                      "are here", from);
        return true;
    }

    if (s_state == XC_WORKING && !s_proved && s_moved &&
        !strcasecmp(from, s_peer)) {
        /* Step 4, heard on the working channel: the same signed packet, which
         * only the station that committed could repeat. Now the work may run. */
        (void)wire; (void)len;
        s_proved = true;
        XC_LOGI("%s is here — the channel is ours", from);
        if (s_ops.on_working) s_ops.on_working(s_peer, s_channel, s_lr);
        return true;
    }
    XC_LOGW("an ack from %s arrived in state %d — nothing to do with it",
             from, (int)s_state);
    return false;
}

bool xprschan_on_packet(const xprs_t *p, const char *wire, int len)
{
    if (!p) return false;
    char type[16];
    xprs_type(p, type, sizeof type);
    if (strcmp(type, "channel") == 0)  return xc_on_invite(p, wire, len);
    if (strcmp(type, "receipt") == 0)  return xc_on_receipt(p, wire, len);
    return false;
}

/* ── Steps 5 and 6: the clock ───────────────────────────────────────────── */

void xprschan_tick(void)
{
    /* The signing half of an invitation, on the task that can afford it. */
    if (s_want_invite && s_state == XC_IDLE) {
        s_want_invite = false;
        if (!xc_do_invite(s_want_peer, s_want_channel, s_want_seconds,
                          s_want_lr)) {
            XC_LOGW("could not air the invitation to %s", s_want_peer);
        }
    }
    /* The blocking half of a move, on the task that can afford to block. */
    if (s_want_move) {
        s_want_move = false;
        /* Say it more than once before leaving.
         *
         * The acceptance is the commitment (§23.7 step 2) and it was aired
         * exactly once, into a channel the inviter shares with its own
         * transmissions — a station cannot hear while it talks, and a single
         * unacknowledged packet is a thin thing to build a rendezvous on.
         * Measured: the exchange completed some attempts and died at step 2 on
         * others, with nothing wrong but timing. Three airings on the commons,
         * then the move; step 3 says the invitee moves on SENDING, and sending
         * it three times is still sending it.
         *
         * Also lets the frame actually leave before the radio moves under it —
         * esp_now_send() is asynchronous, and tuning too early carried the
         * acceptance to the new channel where nobody was listening yet. */
        if (!s_inviter && s_accept_len > 0) {
            for (int i = 0; i < 2; i++) {
                /* Spread, not burst. Three airings inside a third of a second
                 * are three attempts at THE SAME MOMENT, and the moment is the
                 * problem: the answer is due while the inviter is still busy
                 * with the two frames it just sent. Roughly half a second
                 * apart, varied by the tick's own phase so two stations doing
                 * this at once do not stay in step, samples genuinely different
                 * conditions. The inviter waits XC_PROOF_WAIT_MS for the proof,
                 * so arriving later costs nothing. */
                uint32_t gap = 350u + (s_ops.now_ms() % 300u);
                xc_delay_ms(gap);
                xc_air_accept("before the move");
            }
        }
        /* And do not retune until the radio is actually finished. This was a
         * 120 ms guess, and when it was wrong the acceptance travelled to the
         * new channel where nobody was listening yet. */
        if (s_ops.settle) s_ops.settle(500);
        else xc_delay_ms(120);
        xc_go(s_move_channel, s_move_lr);
        s_moved = true;
        if (!s_inviter) {
            /* Step 4: the same packet again, here. The first airing committed;
             * this one locates. Repeated below until the exchange ends. */
            xc_air_accept("step 4, on the working channel");
            s_announce_ms = s_arrived_ms = s_ops.now_ms();
            s_proved = true;
            if (s_ops.on_working) s_ops.on_working(s_peer, s_channel, s_lr);
        }
    }

    if (s_state == XC_IDLE) return;
    uint32_t now = s_ops.now_ms();
    if (s_moved) xc_keep_channel(s_channel);

    if (s_state == XC_INVITED) {
        /* Nobody answered on the commons. Nothing moved, so nothing to undo —
         * §23.7 step 2: silence ends the matter with everyone still here. */
        if ((int32_t)(now - s_invite_stale_ms) > 0) {
            xc_finish("no answer", false);
            return;
        }
        /* Ask again, with the same bytes.
         *
         * "Nobody answered" and "the one packet that carried the question was
         * not heard" are the same silence from here, and on this bearer they
         * were mostly the second. The identifier does not change, so an answer
         * to any of these airings still names an invitation we recognise, and
         * the invitee re-airs the acceptance it already sent rather than
         * treating a repeat as a fresh invitation it is too busy for. */
        if (s_invite_len > 0 &&
            (int32_t)(now - (s_invite_last_ms + XC_INVITE_RETRY_MS)) > 0) {
            s_invite_last_ms = now;
            s_invite_tries++;
            /* The identity goes with EVERY attempt, not just the first.
             *
             * §23.7 is followed only when the signature verifies, so an invitee
             * that never received our key ignores the invitation -- and it will
             * ignore all the retries too, for the same reason, silently. The
             * identity was aired once and the invitation seven times, so one
             * lost identity packet cost the whole attempt: measured as seven
             * consecutive "not signed by a key we hold" on the far board while
             * this one recorded "no answer". They are one packet each and they
             * travel together. */
            if (s_ops.announce_identity) s_ops.announce_identity();
            if (s_ops.settle) s_ops.settle(300);
            if (!s_ops.air(s_invite_wire, s_invite_len)) {
                XC_LOGW("the bearer refused invitation attempt %u",
                         (unsigned)s_invite_tries);
            }
        }
        return;
    }

    /* Step 4, repeated.
     *
     * Both stations reach the working channel by their own route, and each
     * route takes hundreds of milliseconds it does not control — a disconnect
     * the driver completes when it feels like it, then a channel switch. Airing
     * the proof once means airing it into whatever moment the other station
     * happens to be in, and if that moment is mid-switch the exchange is over
     * before it began. §23.7 says the invitee re-airs its acceptance and does
     * not say once; the station with the bulk "sends nothing until it hears
     * this", so saying it until somebody does is the reading that works.
     *
     * The same signed bytes every time, so it stays the proof it was. */
    if (!s_inviter && s_proved && s_accept_len > 0 &&
        (int32_t)(now - (s_announce_ms + xc_announce_gap(now))) > 0) {
        s_announce_ms = now;
        xc_air_accept("step 4, repeated");
    }

    /* Step 6: alone on the working channel. No error packet — the party that
     * failed to arrive is not listening anywhere useful to send one. */
    if (!s_proved && s_proof_by_ms && (int32_t)(now - s_proof_by_ms) > 0) {
        xc_finish("nobody came", false);
        return;
    }

    /* Step 5, and the rule that matters most: the channel is borrowed. */
    if ((int32_t)(now - s_deadline_ms) > 0) {
        xc_finish("time is up", s_proved);
    }
}

xc_state_t xprschan_state(void) { return s_state; }
bool xprschan_busy(void) { return s_state != XC_IDLE; }

void xprschan_init(const char *callsign, const xc_ops_t *ops)
{
    if (!ops) return;
    s_ops = *ops;
    snprintf(s_call, sizeof s_call, "%s", callsign ? callsign : "");
    s_state = XC_IDLE;
}
