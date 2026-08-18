/*
 * espnow_probe -- two ESP32s, ESP-NOW, and nothing else.
 *
 * WHY THIS EXISTS
 *
 * XPRS.md section 23.7 moves a pair of stations off the calling channel to a
 * working channel of their own. On the real firmware that meeting succeeded
 * about one attempt in five: both boards reported themselves on the working
 * channel, both drivers reported their frames sent, and the dongle received
 * nothing at all for the whole window.
 *
 * Six causes have been ruled out by measurement on the real firmware (see
 * docs/espnow.md): the acceptance being lost, slow disassociation, heap and
 * refused sends, WiFi power save, the broadcast peer's channel, and off-channel
 * scanning -- esp_wifi_scan_stop() found no scan to stop on any attempt, and a
 * guard that re-reads the channel every tick has never seen the radio drift.
 * Aiming at channel 11 instead of 6 gave the same rate, so it is not one
 * channel's interference either.
 *
 * What is left is the environment. The dongle runs a BLE controller, a NimBLE
 * host, an APRS-IS iGate, a Reticulum hub, an HTTP server, an SD-backed index
 * and three bearers, all sharing one radio through the coexistence scheduler.
 * The question this firmware answers is the one that cannot be answered there:
 *
 *   CAN TWO ESP32s HOLD A MANUALLY-SET CHANNEL AND HEAR EACH OTHER AT ALL,
 *   with nothing else running?
 *
 * and then, one variable at a time, which addition breaks it.
 *
 * IT ANSWERED. Steps 1 to 3 pass perfectly; step 4 fails absolutely. With the
 * BLE controller running, a station that is NOT ASSOCIATED receives nothing --
 * while transmitting perfectly, which is why this read for so long as the other
 * end going quiet. Cancelling the scan does not help; only taking the
 * controller down does. An associated station with the same controller up is
 * fine, because association is what keeps the WiFi side scheduled. The full
 * table and what it means for section 23.7 are in docs/espnow.md.
 *
 * WHAT IT DOES
 *
 * Broadcasts a numbered ESP-NOW packet at a fixed rate and counts what comes
 * back. Both boards run the same firmware and print the same line. Nothing else
 * is started: no SD card, no HTTP, no LVGL, no sockets. Bluetooth is compiled
 * in but stays OFF until `ble on`, because it is the variable under test.
 *
 * Driven from the serial console so a whole sweep costs no reflashes:
 *
 *   ch <n>      set the channel (the station must not be associated)
 *   join        connect to the access point in wifi_secrets.h
 *   leave       disconnect, and stop reconnecting -- the section 23.7 path
 *   rate <ms>   how often to transmit; 0 stops
 *   reset       zero the counters
 *   state       what the driver says right now
 *
 * THE SEQUENCE TO RUN, on both boards, in this order. Each step adds exactly
 * one thing to the step before it, so whichever step first shows rx=0 names
 * the cause:
 *
 *   1. never associated, both on channel 1     -- does ESP-NOW work at all
 *   2. never associated, both `ch 6`           -- can a manual channel be held
 *   3. `join`, then `leave`, then both `ch 6`  -- the real section 23.7 path
 *   4. as 3, then `ble on`                     -- coexistence
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_event.h"
#include "esp_timer.h"
#include "esp_mac.h"
#include "esp_system.h"
#include "nvs_flash.h"
#include "esp_wifi.h"
#include "esp_now.h"
#include "esp_netif.h"

#include "wifi_secrets.h"

#include "esp_coexist.h"

#if CONFIG_BT_ENABLED
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_gap.h"
#endif

static const char *TAG = "probe";

static const uint8_t k_broadcast[6] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

/* Every packet says who sent it and which one it is, so a receiver can report
 * losses rather than only a count. 32 bytes; the size is not what is being
 * tested here and a small frame removes it as a variable. */
typedef struct {
    char     tag[8];         /* "PROBE" */
    uint8_t  mac[6];
    uint32_t seq;
    uint8_t  channel;        /* what the sender believed at the moment of send */
} probe_pkt_t;

static volatile uint32_t s_tx_issued, s_tx_done, s_tx_failed, s_tx_refused;
static volatile uint32_t s_rx, s_rx_lost, s_rx_wrong_chan;
static volatile int32_t  s_rx_rssi;
static volatile uint32_t s_peer_last_seq;
static volatile bool     s_peer_seen;
static uint32_t          s_seq;
static uint32_t          s_rate_ms = 500;
static volatile bool     s_want_reconnect;   /* false after `leave` */
static uint8_t           s_self_mac[6];

/* ---- ESP-NOW ------------------------------------------------------------ */

static void on_sent(const uint8_t *mac, esp_now_send_status_t status)
{
    (void)mac;
    if (status != ESP_NOW_SEND_SUCCESS) s_tx_failed++;
    s_tx_done++;
}

/* WiFi task, core 0. Counters only -- no logging, no work. */
static void on_recv(const esp_now_recv_info_t *info, const uint8_t *data, int len)
{
    if (!info || !data || len != (int)sizeof(probe_pkt_t)) return;
    probe_pkt_t p;
    memcpy(&p, data, sizeof p);
    if (memcmp(p.tag, "PROBE", 5) != 0) return;
    if (memcmp(p.mac, s_self_mac, 6) == 0) return;      /* our own, reflected */

    s_rx++;
    if (info->rx_ctrl) s_rx_rssi = info->rx_ctrl->rssi;

    /* Gaps in the sender's sequence are packets that were transmitted and not
     * heard -- the difference between "the link is bad" and "the link is dead",
     * which a plain count cannot show. */
    if (s_peer_seen && p.seq > s_peer_last_seq + 1) {
        s_rx_lost += p.seq - s_peer_last_seq - 1;
    }
    s_peer_last_seq = p.seq;
    s_peer_seen = true;

    uint8_t here = 0;
    wifi_second_chan_t sec;
    if (esp_wifi_get_channel(&here, &sec) == ESP_OK && here != p.channel) {
        s_rx_wrong_chan++;      /* heard across a channel boundary: impossible,
                                 * so it means one of us is not where it thinks */
    }
}

static void probe_send(void)
{
    probe_pkt_t p;
    memset(&p, 0, sizeof p);
    snprintf(p.tag, sizeof p.tag, "PROBE");
    memcpy(p.mac, s_self_mac, 6);
    p.seq = ++s_seq;
    wifi_second_chan_t sec;
    uint8_t ch = 0;
    esp_wifi_get_channel(&ch, &sec);
    p.channel = ch;

    esp_err_t e = esp_now_send(k_broadcast, (const uint8_t *)&p, sizeof p);
    if (e == ESP_OK) s_tx_issued++;
    else {
        s_tx_refused++;
        ESP_LOGW(TAG, "esp_now_send: %s", esp_err_to_name(e));
    }
}

/* ---- WiFi --------------------------------------------------------------- */

static void on_wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg; (void)base; (void)data;
    if (id == WIFI_EVENT_STA_DISCONNECTED) {
        /* The whole point of `leave` is that nothing puts us back. On the real
         * firmware this is geogram_wifi_hold_reconnect(). */
        if (s_want_reconnect) esp_wifi_connect();
        else ESP_LOGW(TAG, "disconnected, and staying that way");
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
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_start());
    /* A station that sleeps misses ESP-NOW frames. Same as the real firmware. */
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));
    ESP_ERROR_CHECK(esp_wifi_get_mac(WIFI_IF_STA, s_self_mac));
}

static void espnow_up(void)
{
    ESP_ERROR_CHECK(esp_now_init());
    ESP_ERROR_CHECK(esp_now_register_recv_cb(on_recv));
    ESP_ERROR_CHECK(esp_now_register_send_cb(on_sent));

    esp_now_peer_info_t peer = {
        .channel = 0,                /* follow the station */
        .ifidx = WIFI_IF_STA,
        .encrypt = false,
    };
    memcpy(peer.peer_addr, k_broadcast, 6);
    ESP_ERROR_CHECK(esp_now_add_peer(&peer));
}

/* ---- Bluetooth, the last variable --------------------------------------- */
/*
 * Steps 1 to 3 all pass with nothing but ESP-NOW: two boards hold a manually
 * set channel and hear each other perfectly, including after associating to an
 * access point and leaving it again. So the radio path section 23.7 uses is
 * sound, and what is left is everything else the dongle runs beside it.
 *
 * A continuous BLE scan is the heaviest thing on that list. The observer role
 * asks the controller for the radio essentially all the time, and the software
 * coexistence scheduler then hands WiFi whatever is left -- which, for an
 * ASSOCIATED station, includes the beacon intervals it must not miss, and for
 * an unassociated one may include nothing at all. That asymmetry is exactly the
 * shape of the fault: the dongle hears its peer on the calling channel, where
 * it is associated, and goes deaf on the working channel, where it is not.
 *
 * `ble on` starts a scan and an advertisement; `ble off` stops both. No
 * reflash, so the same board can be measured either way in one sitting.
 */
#if CONFIG_BT_ENABLED
static volatile bool s_ble_running;
static volatile bool s_ble_synced;
static uint32_t      s_ble_reports;

static int on_gap(struct ble_gap_event *ev, void *arg)
{
    (void)arg;
    if (ev->type == BLE_GAP_EVENT_DISC) s_ble_reports++;
    return 0;
}

static void ble_scan_start(void)
{
    struct ble_gap_disc_params d = {0};
    d.itvl = 0x0010;          /* 10 ms interval, 10 ms window: as greedy as the */
    d.window = 0x0010;        /* observer role gets, which is the point */
    d.passive = 1;
    d.filter_duplicates = 0;
    int rc = ble_gap_disc(BLE_OWN_ADDR_PUBLIC, BLE_HS_FOREVER, &d, on_gap, NULL);
    ESP_LOGW(TAG, "ble scan start rc=%d", rc);
}

static void ble_on_sync(void) { s_ble_synced = true; }
static void ble_host_task(void *p) { (void)p; nimble_port_run(); nimble_port_freertos_deinit(); }

static void ble_set(bool on)
{
    if (on && !s_ble_running) {
        nimble_port_init();
        ble_hs_cfg.sync_cb = ble_on_sync;
        nimble_port_freertos_init(ble_host_task);
        for (int i = 0; i < 100 && !s_ble_synced; i++) vTaskDelay(pdMS_TO_TICKS(20));
        ble_scan_start();
        s_ble_running = true;
        ESP_LOGW(TAG, "BLE on (scanning), heap %u", (unsigned)esp_get_free_heap_size());
    } else if (!on && s_ble_running) {
        ble_gap_disc_cancel();
        s_ble_running = false;
        ESP_LOGW(TAG, "BLE scan cancelled, heap %u", (unsigned)esp_get_free_heap_size());
    }
}

/* Cancelling the scan is not enough -- measured: with the controller still up
 * and merely idle, an unassociated station still receives nothing. So the
 * question this answers is whether taking the controller ALL the way down gives
 * the radio back, which decides whether any workaround exists for a station
 * that has to leave its access point while carrying Bluetooth. */
static void ble_kill(void)
{
    if (s_ble_running) { ble_gap_disc_cancel(); s_ble_running = false; }
    int rc = nimble_port_stop();
    ESP_LOGW(TAG, "nimble_port_stop rc=%d", rc);
    nimble_port_deinit();
    s_ble_synced = false;
    ESP_LOGW(TAG, "BLE controller down, heap %u",
             (unsigned)esp_get_free_heap_size());
}
#else
static void ble_set(bool on)
{
    ESP_LOGW(TAG, "this build has no Bluetooth (CONFIG_BT_ENABLED=n) -- %d", on);
}
static void ble_kill(void) { ESP_LOGW(TAG, "no Bluetooth in this build"); }
#endif

/* ---- Console ------------------------------------------------------------ */

static void print_state(void)
{
    uint8_t ch = 0;
    wifi_second_chan_t sec = WIFI_SECOND_CHAN_NONE;
    esp_wifi_get_channel(&ch, &sec);
    wifi_ap_record_t ap;
    bool assoc = (esp_wifi_sta_get_ap_info(&ap) == ESP_OK);
    uint8_t proto = 0;
    esp_wifi_get_protocol(WIFI_IF_STA, &proto);
    wifi_ps_type_t ps = WIFI_PS_NONE;
    esp_wifi_get_ps(&ps);
    ESP_LOGW(TAG, "state ch=%u assoc=%d%s proto=0x%02x ps=%d rate=%ums heap=%u",
             ch, assoc, assoc ? ap.ssid[0] ? " (has ap)" : "" : "", proto,
             (int)ps, (unsigned)s_rate_ms, (unsigned)esp_get_free_heap_size());
}

static void handle(const char *line)
{
    if (strncmp(line, "ch ", 3) == 0) {
        int ch = atoi(line + 3);
        esp_err_t e = esp_wifi_set_channel((uint8_t)ch, WIFI_SECOND_CHAN_NONE);
        uint8_t now = 0; wifi_second_chan_t sec;
        esp_wifi_get_channel(&now, &sec);
        ESP_LOGW(TAG, "ch %d -> %s, radio says %u", ch, esp_err_to_name(e), now);
        return;
    }
    if (strcmp(line, "join") == 0) {
        wifi_config_t wc = {0};
        snprintf((char *)wc.sta.ssid, sizeof wc.sta.ssid, "%s", WIFI_SSID);
        snprintf((char *)wc.sta.password, sizeof wc.sta.password, "%s", WIFI_PASS);
        s_want_reconnect = true;
        esp_wifi_set_config(WIFI_IF_STA, &wc);
        ESP_LOGW(TAG, "join -> %s", esp_err_to_name(esp_wifi_connect()));
        return;
    }
    if (strcmp(line, "leave") == 0) {
        s_want_reconnect = false;
        ESP_LOGW(TAG, "leave -> %s", esp_err_to_name(esp_wifi_disconnect()));
        return;
    }
    if (strncmp(line, "rate ", 5) == 0) {
        s_rate_ms = (uint32_t)atoi(line + 5);
        ESP_LOGW(TAG, "rate %ums", (unsigned)s_rate_ms);
        return;
    }
    if (strcmp(line, "reset") == 0) {
        s_tx_issued = s_tx_done = s_tx_failed = s_tx_refused = 0;
        s_rx = s_rx_lost = s_rx_wrong_chan = 0;
        s_peer_seen = false; s_seq = 0;
        ESP_LOGW(TAG, "counters zeroed");
        return;
    }
    if (strcmp(line, "ble on") == 0)  { ble_set(true);  return; }
    if (strcmp(line, "ble off") == 0) { ble_set(false); return; }
    if (strcmp(line, "ble kill") == 0) { ble_kill(); return; }
    if (strncmp(line, "coex ", 5) == 0) {
        /* The coexistence scheduler decides which radio gets the air. Its
         * default is BALANCE, and BALANCE is measured here to mean "an
         * unassociated station receives nothing" -- an associated one has
         * beacons it must not miss, which is presumably why it keeps its slot
         * and an ESP-NOW-only station does not. */
        const char *w = line + 5;
        esp_coex_prefer_t p = ESP_COEX_PREFER_BALANCE;
        if (strcmp(w, "wifi") == 0) p = ESP_COEX_PREFER_WIFI;
        else if (strcmp(w, "bt") == 0) p = ESP_COEX_PREFER_BT;
        ESP_LOGW(TAG, "coex %s -> %s", w,
                 esp_err_to_name(esp_coex_preference_set(p)));
        return;
    }
    if (strcmp(line, "state") == 0) { print_state(); return; }
    ESP_LOGW(TAG, "ch <n> | join | leave | rate <ms> | reset | state | ble on|off|kill | coex wifi|bt|balance");
}

static void console_task(void *arg)
{
    (void)arg;
    static char line[64];
    int n = 0;
    for (;;) {
        int c = fgetc(stdin);
        if (c == EOF) { vTaskDelay(pdMS_TO_TICKS(20)); continue; }
        if (c == '\r' || c == '\n') {
            if (n > 0) { line[n] = 0; handle(line); n = 0; }
            continue;
        }
        if (n < (int)sizeof line - 1) line[n++] = (char)c;
    }
}

/* ---- The probe ---------------------------------------------------------- */

static void probe_task(void *arg)
{
    (void)arg;
    uint32_t last_report = 0;
    for (;;) {
        if (s_rate_ms) {
            probe_send();
            vTaskDelay(pdMS_TO_TICKS(s_rate_ms));
        } else {
            vTaskDelay(pdMS_TO_TICKS(100));
        }
        uint32_t now = (uint32_t)(esp_timer_get_time() / 1000);
        if (now - last_report < 2000) continue;
        last_report = now;

        uint8_t ch = 0;
        wifi_second_chan_t sec = WIFI_SECOND_CHAN_NONE;
        esp_wifi_get_channel(&ch, &sec);
#if CONFIG_BT_ENABLED
        ESP_LOGW(TAG, "ch=%u tx=%u sent=%u fail=%u refused=%u | rx=%u lost=%u "
                      "offchan=%u rssi=%d | ble=%d adv_seen=%u",
                 ch, (unsigned)s_tx_issued, (unsigned)s_tx_done,
                 (unsigned)s_tx_failed, (unsigned)s_tx_refused,
                 (unsigned)s_rx, (unsigned)s_rx_lost,
                 (unsigned)s_rx_wrong_chan, (int)s_rx_rssi,
                 (int)s_ble_running, (unsigned)s_ble_reports);
#else
        ESP_LOGW(TAG, "ch=%u tx=%u sent=%u fail=%u refused=%u | rx=%u lost=%u "
                      "offchan=%u rssi=%d",
                 ch, (unsigned)s_tx_issued, (unsigned)s_tx_done,
                 (unsigned)s_tx_failed, (unsigned)s_tx_refused,
                 (unsigned)s_rx, (unsigned)s_rx_lost,
                 (unsigned)s_rx_wrong_chan, (int)s_rx_rssi);
#endif
    }
}

void app_main(void)
{
    esp_err_t e = nvs_flash_init();
    if (e == ESP_ERR_NVS_NO_FREE_PAGES || e == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        nvs_flash_init();
    }

    wifi_up();
    espnow_up();

    ESP_LOGW(TAG, "espnow_probe up: %02x:%02x:%02x:%02x:%02x:%02x, heap %u",
             s_self_mac[0], s_self_mac[1], s_self_mac[2], s_self_mac[3],
             s_self_mac[4], s_self_mac[5], (unsigned)esp_get_free_heap_size());
    ESP_LOGW(TAG, "NOT associated. ch <n> | join | leave | rate <ms> | reset | "
                  "state | ble on|off");
    print_state();

    xTaskCreate(probe_task, "probe", 4096, NULL, 5, NULL);
    xTaskCreate(console_task, "console", 4096, NULL, 4, NULL);
}
