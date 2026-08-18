/*
 * An XPRS station on an M5Stack Core, whose whole job is to be somebody else.
 *
 * Testing a bearer with one device proves nothing: a station that hears its own
 * broadcast has learned that the loopback works. This is the second voice — it
 * beacons on ESP-NOW, repeats what it hears, and prints every packet with the
 * signal it arrived at, so the two ends can be compared.
 *
 * WHAT THIS BOARD CANNOT DO. It is an original ESP32 (D0WDQ6): no BLE5 extended
 * advertising, so it can never join the mesh plane the T-Dongle runs on
 * (docs/esp32.md, "Radio capability per chip"). It has ESP-NOW and WiFi, which
 * is the entire point of it being here.
 *
 * THE CHANNEL IS THE WHOLE TRICK. ESP-NOW rides whatever channel the WiFi
 * station is on, and two devices on different channels hear nothing from each
 * other with no error anywhere. So this node associates to the SAME access
 * point as the dongle, which lands it on the same channel without anybody
 * having to guess one. With no credentials it stays unassociated and pins the
 * channel from the build config instead — fine between two idle boards, useless
 * against a dongle that is associated somewhere else.
 */

#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "nvs_flash.h"

#include "xprs.h"
#include "xprsnow.h"
#include "xprslan.h"
#include "xprsid.h"
#include "xprschan.h"
#include "nostr_keys.h"
#include "bech32.h"

#include "wifi_secrets.h"   /* gitignored; see wifi_secrets.h.example */

static const char *TAG = "m5xprs";

/* This station. Derived from the MAC so two boards never collide, unless NVS
 * carries one an operator chose. X5 marks it as an experimental station rather
 * than claiming an X1/X3 form that means something. */
static char s_call[10];

static void derive_callsign(void)
{
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    static const char *b32 = "ACDEFGHJKLMNPQRSTUVWXYZ23456789";  /* no B/I/O/1 */
    uint32_t v = ((uint32_t)mac[3] << 16) | ((uint32_t)mac[4] << 8) | mac[5];
    s_call[0] = 'X'; s_call[1] = '5';
    for (int i = 0; i < 4; i++) { s_call[2 + i] = b32[v % 30]; v /= 30; }
    s_call[6] = 0;
}

/* ── Signing, and whose word we take ────────────────────────────────────── */

/* One key per station we have heard a t:identity from (§9.3), first speaker
 * wins. Small: this exists so §23.7 has somebody it can believe, not to be a
 * directory. */
#define PEERKEYS_MAX 4
static struct { char call[10]; uint8_t pub[32]; } s_peers[PEERKEYS_MAX];
static int s_peers_n;

static const uint8_t *peer_key(const char *call)
{
    for (int i = 0; i < s_peers_n; i++) {
        if (strcasecmp(s_peers[i].call, call) == 0) return s_peers[i].pub;
    }
    return NULL;
}

/* Verified against the very key it publishes: a station claiming a key must
 * show it holds it, and the packet is signed with it. */
static void identity_heard(const xprs_t *p)
{
    char call[10], npub[80];
    if (!xprs_get_str(p, "f", call, sizeof call)) return;
    if (!xprs_get_str(p, "k", npub, sizeof npub)) return;
    if (strncmp(npub, "npub1", 5) != 0 || peer_key(call)) return;
    if (s_peers_n >= PEERKEYS_MAX) return;

    char hrp[8];
    uint8_t data[64];
    size_t dlen = sizeof data;
    if (bech32_decode(npub, hrp, data, &dlen) != ESP_OK) return;
    if (dlen != 32 || strcmp(hrp, "npub") != 0) return;
    if (!xprsid_verify(p, data)) {
        ESP_LOGW(TAG, "%s does not sign for the key it published", call);
        return;
    }
    snprintf(s_peers[s_peers_n].call, sizeof s_peers[0].call, "%s", call);
    memcpy(s_peers[s_peers_n].pub, data, 32);
    s_peers_n++;
    ESP_LOGI(TAG, "learned %s signs with %02x%02x%02x%02x...", call,
             data[0], data[1], data[2], data[3]);
}

static int sign_wire(char *wire, int len, int cap)
{
    const nostr_keys_t *k = nostr_keys_get();
    return k ? xprsid_sign(wire, len, cap, k->private_key) : len;
}

/* ── What we hear ───────────────────────────────────────────────────────── */

static uint32_t s_heard_count;

static void on_espnow(const char *wire, int len, const uint8_t mac[6], int rssi)
{
    s_heard_count++;
    xprs_t p;
    if (xprs_parse(wire, len, &p)) {
        char type[16];
        xprs_type(&p, type, sizeof type);
        if (strcmp(type, "identity") == 0) identity_heard(&p);
        /* §23.7 is handled in heard_espnow(), not here — see the note there. */
        if (strcmp(type, "channel") == 0 || strcmp(type, "receipt") == 0) return;
    }
    ESP_LOGI(TAG, "espnow %02x:%02x:%02x:%02x:%02x:%02x %4d dBm %3dB  %s",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], rssi, len, wire);
    /* A station with two bearers is a bridge: what arrived here goes out there,
     * under the ordinary relay rules (the bearer refuses when we are already in
     * via: or the hop budget is spent). */
    xprslan_offer(wire, len);
}

/* Every hearing on ESP-NOW, duplicates included.
 *
 * §23.7's step 4 is the same signed acceptance aired a second time on the
 * working channel, and the ordinary receive path drops a packet whose
 * identifier it has already heard. This callback is the one that does not. */
static void heard_espnow(const char *id, const char *wire, int len)
{
    (void)id;
    xprs_t p;
    if (!xprs_parse(wire, len, &p)) return;
    char type[16];
    xprs_type(&p, type, sizeof type);
    if (strcmp(type, "channel") == 0 || strcmp(type, "receipt") == 0) {
        xprschan_on_packet(&p, wire, len);
    }
}

static void on_lan(const char *wire, int len, uint32_t ip)
{
    ESP_LOGI(TAG, "lan    %u.%u.%u.%u %3dB  %s",
             (unsigned)(ip & 0xFF), (unsigned)((ip >> 8) & 0xFF),
             (unsigned)((ip >> 16) & 0xFF), (unsigned)((ip >> 24) & 0xFF),
             len, wire);
    xprsnow_offer(wire, len);
}

/* ── What we say ────────────────────────────────────────────────────────── */

/* t:observation f:<call> link:espnow peers:<n> — §10.6, and §10.6.1's rule that
 * a reading belongs to the bearer it names, which is why this says espnow and
 * the LAN beacon below says lan. */
static int espnow_beacon(char *out, int cap)
{
    if (!s_call[0]) return 0;
    return snprintf(out, (size_t)cap, "t:observation f:%s link:espnow peers:%d",
                    s_call, xprsnow_peer_count(600));
}

static int lan_beacon(char *out, int cap)
{
    if (!s_call[0]) return 0;
    return snprintf(out, (size_t)cap, "t:observation f:%s link:lan peers:%d",
                    s_call, xprslan_peer_count(600));
}

/* ── Meeting on a working channel (§23.7) ───────────────────────────────── */

/* No SNTP on this board, so most of the time there is no wall clock and
 * `epoch:<boot>.<uptime>` is the honest thing to send (§4.3). The deadline that
 * brings us home is local milliseconds either way. */
static void time_field(char *out, int cap)
{
    snprintf(out, cap, "epoch:0.%u",
             (unsigned)(esp_timer_get_time() / 1000000ULL));
}

static uint32_t now_ms(void) { return (uint32_t)(esp_timer_get_time() / 1000); }
static uint32_t no_clock(void) { return 0; }

static bool verified(const xprs_t *p)
{
    char from[10];
    if (!xprs_get_str(p, "f", from, sizeof from)) return false;
    const uint8_t *k = peer_key(from);
    return k && xprsid_verify(p, k);
}

static bool may_move(void) { return true; }   /* this board gateways nothing */
static void air_identity(void);               /* defined below, used by the ops */

static void on_working(const char *peer, uint8_t channel, bool lr)
{
    ESP_LOGW(TAG, "on channel %u with %s%s", channel, peer,
             lr ? " (long range)" : "");
}

static void on_home(const char *peer, bool worked)
{
    ESP_LOGW(TAG, "home again after %s (%s)", peer[0] ? peer : "nobody",
             worked ? "the pair met" : "nothing happened");
}

static const xc_ops_t k_chan_ops = {
    .sign = sign_wire,
    .verified = verified,
    .air = xprsnow_send,
    .now_ms = now_ms,
    .time_field = time_field,
    .epoch = no_clock,
    .hold_reconnect = NULL,      /* handled in the event handler above */
    .announce_identity = air_identity,
    .may_move = may_move,
    .settle = xprsnow_settle,
    .trace = xprsnow_set_trace,
    .on_working = on_working,
    .on_home = on_home,
};

/* §9.3: publish the key, or nobody can check a thing we say — including the
 * acceptance §23.7 leans on. */
static void air_identity(void)
{
    const char *npub = nostr_keys_get_npub();
    if (!npub || !npub[0]) return;
    char wire[XPRS_MAX_WIRE + 1], ts[24];
    time_field(ts, sizeof ts);
    int n = snprintf(wire, sizeof wire, "t:identity f:%s %s k:%s",
                     s_call, ts, npub);
    if (n <= 0 || n > XPRS_MAX_WIRE) return;
    n = sign_wire(wire, n, (int)sizeof wire);
    xprsnow_send(wire, n);
}

/* ── Status, every 15 s, the same shape the dongle prints ───────────────── */

static void status_task(void *arg)
{
    (void)arg;
    int n = 0;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(500));
        /* §23.7's deadline: the one thing that guarantees a station that moved
         * comes back. Cheap, so it runs on the fast tick, not the log's. */
        xprschan_tick();
        if (++n % 120 == 0) air_identity();       /* every 60 s */
        if (n % 30) continue;                     /* the rest every 15 s */

        uint32_t rx = 0, tx = 0, cancelled = 0, dropped = 0;
        uint32_t issued = 0, done = 0, failed = 0;
        xprsnow_stats(&rx, &tx, &cancelled, &dropped);
        /* `tx` counts what this station decided to say; `done`/`fail` count what
         * the radio actually did with it. They were the same number until the
         * send callback existed, and the difference is where a rendezvous that
         * "sent" its acceptance and was not heard shows up. */
        xprsnow_tx_stats(&issued, &done, &failed);
        ESP_LOGW(TAG, "alive %us heap=%u call=%s ch=%u espnow rx=%u tx=%u "
                      "cancel=%u drop=%u sent=%u/%u fail=%u peers=%d heard=%u",
                 (unsigned)(esp_timer_get_time() / 1000000ULL),
                 (unsigned)esp_get_free_heap_size(), s_call,
                 xprsnow_channel(), (unsigned)rx, (unsigned)tx,
                 (unsigned)cancelled, (unsigned)dropped,
                 (unsigned)done, (unsigned)issued, (unsigned)failed,
                 xprsnow_peer_count(600), (unsigned)s_heard_count);
    }
}

/* ── WiFi ───────────────────────────────────────────────────────────────── */

static void on_wifi_event(void *arg, esp_event_base_t base, int32_t id,
                          void *data)
{
    (void)arg; (void)data;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        /* Leaving the access point's channel on purpose (§23.7) looks exactly
         * like losing the link. Reconnecting here would drag us home before the
         * far side arrives, which is what it did the first time. */
        if (xprschan_busy()) return;
        ESP_LOGW(TAG, "wifi disconnected — retrying");
        vTaskDelay(pdMS_TO_TICKS(2000));
        esp_wifi_connect();
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ESP_LOGI(TAG, "wifi up on channel %u", xprsnow_channel());
    }
}

static void wifi_up(void)
{
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        WIFI_EVENT, ESP_EVENT_ANY_ID, on_wifi_event, NULL, NULL));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        IP_EVENT, IP_EVENT_STA_GOT_IP, on_wifi_event, NULL, NULL));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));

    if (WIFI_SSID[0]) {
        wifi_config_t wc = {0};
        snprintf((char *)wc.sta.ssid, sizeof wc.sta.ssid, "%s", WIFI_SSID);
        snprintf((char *)wc.sta.password, sizeof wc.sta.password, "%s", WIFI_PASS);
        ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wc));
        ESP_LOGI(TAG, "associating to \"%s\" — this is what puts us on the "
                      "dongle's channel", WIFI_SSID);
    } else {
        ESP_LOGW(TAG, "no WiFi credentials: staying unassociated on channel %d. "
                      "That only meets another unassociated board — an "
                      "associated dongle is on its access point's channel.",
                 ESPNOW_FALLBACK_CHANNEL);
    }
    ESP_ERROR_CHECK(esp_wifi_start());
    if (!WIFI_SSID[0]) {
        ESP_ERROR_CHECK(esp_wifi_set_channel(ESPNOW_FALLBACK_CHANNEL,
                                             WIFI_SECOND_CHAN_NONE));
    }
}

void app_main(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    if (nostr_keys_init() != ESP_OK || !nostr_keys_available()) {
        ESP_LOGE(TAG, "no signing key — this station cannot take part in §23.7, "
                      "which follows only invitations it can check");
    }
    derive_callsign();
    /* §3: an X3 callsign derives from the signing key, so a receiver can
     * re-derive it. This board keeps its MAC-derived X5 name only when there is
     * no key to derive from. */
    if (nostr_keys_get_callsign() && nostr_keys_get_callsign()[0]) {
        snprintf(s_call, sizeof s_call, "%s", nostr_keys_get_callsign());
    }
    ESP_LOGI(TAG, "M5Stack XPRS station %s (ESP-NOW + LAN, no BLE5 on this chip)",
             s_call);

    wifi_up();

    /* The LAN bearer first, deliberately: its task is what pumps every bearer's
     * re-air queue and beacon, ESP-NOW included. Starting ESP-NOW without it
     * would leave nothing driving either — which xprsnow_start() says out loud
     * rather than letting it be discovered in the field. */
    if (xprslan_start(s_call) == ESP_OK) {
        xprslan_set_rx_cb(on_lan);
        xprslan_set_beacon(lan_beacon, 60, 10);
    } else {
        ESP_LOGE(TAG, "LAN bearer failed — nothing will pump ESP-NOW either");
    }

    if (xprsnow_start(s_call) == ESP_OK) {
        xprsnow_set_rx_cb(on_espnow);
        xprsnow_set_heard_cb(heard_espnow);
        /* Faster than the dongle's 300 s: this board exists to be measured, and
         * a minute between beacons is a long time to watch a serial console. */
        xprsnow_set_beacon(espnow_beacon, 60, 5);
        xprschan_init(s_call, &k_chan_ops);
        air_identity();
    }

    xTaskCreate(status_task, "status", 3072, NULL, 1, NULL);
}
