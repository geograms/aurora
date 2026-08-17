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

/* ── What we hear ───────────────────────────────────────────────────────── */

static uint32_t s_heard_count;

static void on_espnow(const char *wire, int len, const uint8_t mac[6], int rssi)
{
    s_heard_count++;
    ESP_LOGI(TAG, "espnow %02x:%02x:%02x:%02x:%02x:%02x %4d dBm %3dB  %s",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], rssi, len, wire);
    /* A station with two bearers is a bridge: what arrived here goes out there,
     * under the ordinary relay rules (the bearer refuses when we are already in
     * via: or the hop budget is spent). */
    xprslan_offer(wire, len);
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

/* ── Status, every 15 s, the same shape the dongle prints ───────────────── */

static void status_task(void *arg)
{
    (void)arg;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(15000));
        uint32_t rx = 0, tx = 0, cancelled = 0, dropped = 0;
        xprsnow_stats(&rx, &tx, &cancelled, &dropped);
        ESP_LOGW(TAG, "alive %us heap=%u call=%s ch=%u espnow rx=%u tx=%u "
                      "cancel=%u drop=%u peers=%d heard=%u",
                 (unsigned)(esp_timer_get_time() / 1000000ULL),
                 (unsigned)esp_get_free_heap_size(), s_call,
                 xprsnow_channel(), (unsigned)rx, (unsigned)tx,
                 (unsigned)cancelled, (unsigned)dropped,
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

    derive_callsign();
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
        /* Faster than the dongle's 300 s: this board exists to be measured, and
         * a minute between beacons is a long time to watch a serial console. */
        xprsnow_set_beacon(espnow_beacon, 60, 5);
    }

    xTaskCreate(status_task, "status", 3072, NULL, 1, NULL);
}
