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

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_wifi.h"
#include "esp_now.h"

static const char *TAG = "xprschan";

static const uint8_t k_broadcast[6] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

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

/* Home, so we can go back to it. */
static uint8_t  s_home_channel;
static bool     s_was_associated;

/* The acceptance we sent, kept verbatim: step 4 re-airs THE SAME packet, same
 * signature, same identifier. A fresh one would prove nothing — anybody can
 * compose a packet; only the party that committed can repeat that one. */
static char     s_accept_wire[XPRS_MAX_WIRE + 1];
static int      s_accept_len;

/* ── The radio ──────────────────────────────────────────────────────────── */

static void xc_set_lr(bool on)
{
    uint8_t bitmap = WIFI_PROTOCOL_11B | WIFI_PROTOCOL_11G | WIFI_PROTOCOL_11N;
    if (on) bitmap |= WIFI_PROTOCOL_LR;
    esp_err_t e = esp_wifi_set_protocol(WIFI_IF_STA, bitmap);
    if (e != ESP_OK) {
        ESP_LOGW(TAG, "set_protocol(%s) failed: %s", on ? "with LR" : "plain",
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
        ESP_LOGW(TAG, "rate config refused: %s", esp_err_to_name(e));
    }
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
    /* Say so BEFORE disconnecting, or the reconnect fires on the way out. */
    if (s_ops.hold_reconnect) s_ops.hold_reconnect(true);
    if (s_was_associated) {
        esp_wifi_disconnect();
        /* AND WAIT FOR IT. esp_wifi_disconnect() is asynchronous: setting the
         * channel while the station is still associated does not move it — the
         * driver restores the access point's home channel underneath us, and
         * the move silently never happens. Measured: "moved to channel 6"
         * followed 70 ms later by "connected ... channel 1". */
        for (int i = 0; i < 30; i++) {          /* up to ~600 ms */
            wifi_ap_record_t ap;
            if (esp_wifi_sta_get_ap_info(&ap) != ESP_OK) break;
            vTaskDelay(pdMS_TO_TICKS(20));
        }
    }
    if (lr) xc_set_lr(true);
    esp_err_t e = esp_wifi_set_channel(channel, WIFI_SECOND_CHAN_NONE);
    if (e != ESP_OK) ESP_LOGW(TAG, "set_channel(%u): %s", channel,
                              esp_err_to_name(e));
    ESP_LOGW(TAG, "moved to channel %u%s — deaf to the commons until we return",
             channel, lr ? " on the long-range PHY" : "");
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
    ESP_LOGW(TAG, "back on the calling channel");
}

/* ── Composing ──────────────────────────────────────────────────────────── */

static bool xc_air_signed(char *wire, int len)
{
    if (len <= 0 || len > XPRS_MAX_WIRE) return false;
    if (s_ops.sign) len = s_ops.sign(wire, len, XPRS_MAX_WIRE + 1);
    return s_ops.air && s_ops.air(wire, len);
}

/* ── Going home, one place ──────────────────────────────────────────────── */

static void xc_finish(const char *why, bool worked)
{
    if (s_state == XC_WORKING) xc_come_home();
    ESP_LOGI(TAG, "exchange with %s ended: %s", s_peer[0] ? s_peer : "nobody",
             why);
    char peer[10];
    snprintf(peer, sizeof peer, "%s", s_peer);
    s_state = XC_IDLE;
    s_peer[0] = 0;
    s_invite_id[0] = 0;
    s_accept_len = 0;
    s_proved = false;
    s_lr = false;
    if (s_ops.on_home) s_ops.on_home(peer, worked);
}

void xprschan_abort(const char *why) { if (s_state != XC_IDLE) xc_finish(why, false); }

/* ── Step 1: invite ─────────────────────────────────────────────────────── */

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
        ESP_LOGW(TAG, "not inviting: this station does not leave the commons");
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
        vTaskDelay(pdMS_TO_TICKS(150));
    }

    char wire[XPRS_MAX_WIRE + 1];
    int n = snprintf(wire, sizeof wire,
                     "t:channel f:%s d:%s link:espnow ch:%u%s q:ack %s",
                     s_call, peer, channel, until, ts);
    if (n <= 0 || n > XPRS_MAX_WIRE) return false;
    if (s_ops.sign) n = s_ops.sign(wire, n, (int)sizeof wire);

    /* The identifier of what we actually aired is what an answer must name. */
    if (!xprs_id_of(wire, n, s_invite_id)) return false;
    if (!s_ops.air(wire, n)) return false;

    snprintf(s_peer, sizeof s_peer, "%s", peer);
    s_channel = channel;
    s_lr = lr;
    s_inviter = true;
    s_state = XC_INVITED;
    s_away_ms = away;                       /* applied at the moment of the move */
    s_invite_stale_ms = s_ops.now_ms() + XC_INVITE_FRESH_MS;
    s_proof_by_ms = 0;
    s_proved = false;
    ESP_LOGI(TAG, "invited %s to channel %u%s (%s) — waiting on the commons",
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
        ESP_LOGW(TAG, "ignoring an invitation from %s: not signed by a key we "
                      "hold", from);
        return true;
    }

    char reply[XPRS_MAX_WIRE + 1];
    char id[XPRS_ID_LEN];
    xprs_id(p, id);

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
    if (!s_ops.air(s_accept_wire, n)) return true;

    /* How long we are willing to be away. `until:` may shorten this; nothing
     * can lengthen it past XC_MAX_AWAY_MS. */
    uint32_t away = XC_DEFAULT_AWAY_MS;
    char until[32];
    uint32_t now_epoch = s_ops.epoch ? s_ops.epoch() : 0;
    if (now_epoch && xprs_get_str(p, "until", until, sizeof until)) {
        uint32_t u = xc_ts_epoch(until);
        if (u > now_epoch) {
            uint32_t want = (u - now_epoch) * 1000u;
            if (want < away) away = want;
        }
    }
    if (away > XC_MAX_AWAY_MS) away = XC_MAX_AWAY_MS;

    snprintf(s_peer, sizeof s_peer, "%s", from);
    s_channel = (uint8_t)ch;
    s_lr = false;                 /* the inviter's PHY choice is not on the wire
                                   * yet; both ends use the plain rate until
                                   * §23.7 grows a word for it */
    s_inviter = false;
    s_state = XC_WORKING;
    s_deadline_ms = s_ops.now_ms() + away;

    /* Step 3: on SENDING the acceptance, the invitee tunes and follows.
     *
     * SENDING means the frame has left, not that the call returned.
     * esp_now_send() is asynchronous, so tuning immediately carries the
     * acceptance to the NEW channel, where nobody is listening yet — the
     * inviter waits out its whole invitation and reports "no answer", which is
     * exactly what it did. Give the radio a moment to actually put it on the
     * commons before leaving. */
    vTaskDelay(pdMS_TO_TICKS(120));
    xc_go(s_channel, s_lr);

    /* Step 4: the same packet again, here. The first airing committed; this one
     * locates. The far side sends nothing until it hears it. */
    s_ops.air(s_accept_wire, s_accept_len);
    s_proved = true;
    ESP_LOGI(TAG, "accepted %s: on channel %u for %ums", from, s_channel,
             (unsigned)away);
    if (s_ops.on_working) s_ops.on_working(s_peer, s_channel, s_lr);
    return true;
}

/* A receipt that answers our invitation. */
static bool xc_on_receipt(const xprs_t *p, const char *wire, int len)
{
    char r[XPRS_ID_LEN], from[10], st[8];
    if (!xprs_get_str(p, "r", r, sizeof r)) return false;
    if (!s_invite_id[0] || strcmp(r, s_invite_id) != 0) return false;
    if (!xprs_get_str(p, "f", from, sizeof from)) return false;
    if (!xprs_get_str(p, "s", st, sizeof st)) return false;

    /* The acceptance is the commitment (§23.7 step 2) and step 4 leans on it
     * being unforgeable. An answer we cannot check is an answer from nobody in
     * particular, and acting on it is how a station ends up alone on a channel
     * somebody else named. */
    if (!s_ops.verified || !s_ops.verified(p)) {
        ESP_LOGW(TAG, "ignoring an answer from %s: not signed by a key we hold",
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
        xc_go(s_channel, s_lr);
        uint32_t t = s_ops.now_ms();
        s_deadline_ms = t + s_away_ms;      /* the clock starts on the move */
        s_proof_by_ms = t + XC_PROOF_WAIT_MS;
        ESP_LOGI(TAG, "%s accepted — moved, now waiting for them to prove they "
                      "are here", from);
        return true;
    }

    if (s_state == XC_WORKING && !s_proved && !strcmp(from, s_peer)) {
        /* Step 4, heard on the working channel: the same signed packet, which
         * only the station that committed could repeat. Now the work may run. */
        (void)wire; (void)len;
        s_proved = true;
        ESP_LOGI(TAG, "%s is here — the channel is ours", from);
        if (s_ops.on_working) s_ops.on_working(s_peer, s_channel, s_lr);
        return true;
    }
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
            ESP_LOGW(TAG, "could not air the invitation to %s", s_want_peer);
        }
    }
    if (s_state == XC_IDLE) return;
    uint32_t now = s_ops.now_ms();

    if (s_state == XC_INVITED) {
        /* Nobody answered on the commons. Nothing moved, so nothing to undo —
         * §23.7 step 2: silence ends the matter with everyone still here. */
        if ((int32_t)(now - s_invite_stale_ms) > 0) xc_finish("no answer", false);
        return;
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
