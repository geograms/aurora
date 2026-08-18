/*
 * XPRS over ESP-NOW — see xprsnow.h for the bearer and docs/espnow.md for the
 * wire. The queue, the identifier rings and the §13.2.1 cancel are not here:
 * they are `geogram_xprsbearer`, shared with the LAN.
 *
 * What is here is the radio, and one rule that shapes all of it: the receive
 * callback runs in the WiFi task on core 0, so it copies and returns.
 */

#include "xprsnow.h"
#include "xprsbearer.h"
#include "xprs.h"

#include <string.h>
#include <stdio.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_random.h"
#include "esp_now.h"
#include "esp_wifi.h"

static const char *TAG = "xprsnow";

static const uint8_t k_broadcast[6] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

/* One frame, as the callback hands it over. 264 bytes; four of them is the
 * whole cost of getting off the WiFi task. */
typedef struct {
    char    wire[XPRSNOW_WIRE_MAX + 1];
    int     len;
    int     rssi;
    uint8_t mac[6];
} nw_frame_t;

static xb_t              s_now;
static QueueHandle_t     s_rxq;
static SemaphoreHandle_t s_tx_mtx;
static xprsnow_rx_cb_t   s_rx_cb;
static uint32_t          s_dropped;
static bool              s_started;
static bool              s_trace;

/* The driver's own accounting, which is the only place "it went out" lives.
 * `issued` rises where we hand a frame over; `done` and `failed` rise in the
 * send callback, which runs on the WiFi task — so both sides are one writer
 * each and a plain volatile is enough to compare them. */
static volatile uint32_t s_tx_issued;
static volatile uint32_t s_tx_done;
static volatile uint32_t s_tx_failed;

/* Every frame the radio delivered, and how many of those were not XPRS. */
static volatile uint32_t s_frames;
static volatile uint32_t s_notxprs;

/* ── The radio ──────────────────────────────────────────────────────────── */

static uint32_t nw_now_ms(void) { return (uint32_t)(esp_timer_get_time() / 1000); }
static uint32_t nw_random(void) { return esp_random(); }
static void nw_lock(void *ctx)   { (void)ctx; if (s_tx_mtx) xSemaphoreTake(s_tx_mtx, portMAX_DELAY); }
static void nw_unlock(void *ctx) { (void)ctx; if (s_tx_mtx) xSemaphoreGive(s_tx_mtx); }

static bool nw_air(void *ctx, const char *wire, int len)
{
    (void)ctx;
    if (!s_started || len <= 0 || len > XPRSNOW_WIRE_MAX) return false;
    esp_err_t err = esp_now_send(k_broadcast, (const uint8_t *)wire, (size_t)len);
    if (err == ESP_OK) { s_tx_issued++; return true; }
    /* Loud, including the full queue. This was ESP_LOGD and therefore invisible,
     * and an invitation that never left the board looked from every log on the
     * device exactly like an invitation nobody answered. */
    ESP_LOGW(TAG, "esp_now_send(%d bytes) failed: %s", len,
             esp_err_to_name(err));
    return false;
}

/* Also the WiFi task. Two counters and nothing else. */
static void nw_send_cb(const uint8_t *mac, esp_now_send_status_t status)
{
    (void)mac;
    if (status != ESP_NOW_SEND_SUCCESS) s_tx_failed++;
    s_tx_done++;
}

bool xprsnow_settle(uint32_t timeout_ms)
{
    if (!s_started) return false;
    uint32_t start = nw_now_ms();
    while (s_tx_done != s_tx_issued) {
        if (nw_now_ms() - start >= timeout_ms) {
            ESP_LOGW(TAG, "%u frame(s) still in the driver after %ums",
                     (unsigned)(s_tx_issued - s_tx_done), (unsigned)timeout_ms);
            return false;
        }
        vTaskDelay(pdMS_TO_TICKS(5));
    }
    return true;
}

void xprsnow_set_trace(bool on) { s_trace = on; }

/*
 * IN THE WIFI TASK, ON CORE 0. Copy and get out.
 *
 * Everything this packet needs — the §5 identifier (a SHA-256), the archive,
 * the relay decision — happens on the bearer task in nw_drain(). Doing any of
 * it here is the mistake docs/esp32.md measured at 1 of 96 pings.
 */
static void nw_recv_cb(const esp_now_recv_info_t *info, const uint8_t *data,
                       int len)
{
    if (!info || !data || len <= 0 || len > XPRSNOW_WIRE_MAX) return;
    /* Counted BEFORE the byte test, because "the radio heard nothing" and "the
     * radio heard something that was not ours" are different faults and every
     * counter downstream of here conflates them. */
    s_frames++;
    if (!xprs_looks_like(data, len)) { s_notxprs++; return; }

    nw_frame_t f;
    memcpy(f.wire, data, (size_t)len);
    f.wire[len] = 0;
    f.len = len;
    f.rssi = info->rx_ctrl ? info->rx_ctrl->rssi : 0;
    if (info->src_addr) memcpy(f.mac, info->src_addr, 6);
    else                memset(f.mac, 0, 6);

    /* Never block the WiFi task. A full queue means the bearer task is behind,
     * and losing the frame is cheaper than stalling the radio for everybody. */
    if (s_rxq && xQueueSend(s_rxq, &f, 0) != pdTRUE) s_dropped++;
}

/* On the bearer task, once per tick. */
static void nw_drain(void *ctx)
{
    (void)ctx;
    if (!s_rxq) return;
    nw_frame_t f;
    while (xQueueReceive(s_rxq, &f, 0) == pdTRUE) {
        if (s_trace) {
            /* On the bearer task, not the WiFi task, and only while something
             * is asking. 56 bytes reaches past t:/f:/d:/r: on every packet the
             * choreography uses, which is all this needs to identify. */
            ESP_LOGW(TAG, "heard %d bytes at %d dBm: %.56s", f.len, f.rssi,
                     f.wire);
        }
        uint64_t peer = 0;
        for (int i = 0; i < 6; i++) peer = (peer << 8) | f.mac[i];
        xb_on_wire(&s_now, f.wire, f.len, peer, f.rssi);
    }
    if (s_trace) {
        /* The frames that never reached the queue at all. Reported as a change,
         * because a total tells you nothing about the window you are watching. */
        static uint32_t seen_frames, seen_notxprs, seen_dropped;
        if (s_frames != seen_frames || s_notxprs != seen_notxprs ||
            s_dropped != seen_dropped) {
            ESP_LOGW(TAG, "radio delivered %u frame(s) (+%u), %u not XPRS (+%u), "
                          "%u dropped by a full queue (+%u)",
                     (unsigned)s_frames, (unsigned)(s_frames - seen_frames),
                     (unsigned)s_notxprs, (unsigned)(s_notxprs - seen_notxprs),
                     (unsigned)s_dropped, (unsigned)(s_dropped - seen_dropped));
            seen_frames = s_frames;
            seen_notxprs = s_notxprs;
            seen_dropped = s_dropped;
        }
    }
}

static void nw_rx_shim(const char *wire, int len, uint64_t peer, int rssi)
{
    if (!s_rx_cb) return;
    uint8_t mac[6];
    for (int i = 5; i >= 0; i--) { mac[i] = (uint8_t)(peer & 0xFF); peer >>= 8; }
    s_rx_cb(wire, len, mac, rssi);
}

static const xb_ops_t k_now_ops = {
    .air = nw_air,
    .now_ms = nw_now_ms,
    .random = nw_random,
    .lock = nw_lock,
    .unlock = nw_unlock,
    .drain = nw_drain,
    .ctx = NULL,
    .name = "espnow",
};

/* ── The public bearer ──────────────────────────────────────────────────── */

void xprsnow_offer(const char *wire, int len) { xb_offer(&s_now, wire, len); }
bool xprsnow_send(const char *wire, int len)  { return xb_send(&s_now, wire, len); }
bool xprsnow_is_active(void)                  { return xb_is_active(&s_now); }

void xprsnow_set_rx_cb(xprsnow_rx_cb_t cb)
{
    s_rx_cb = cb;
    xb_set_rx_cb(&s_now, cb ? nw_rx_shim : NULL);
}
void xprsnow_set_heard_cb(xprsnow_heard_cb_t cb) { xb_set_heard_cb(&s_now, cb); }

void xprsnow_set_beacon(xprsnow_beacon_cb_t cb, uint32_t interval_sec,
                        uint32_t first_delay_sec)
{
    xb_set_beacon(&s_now, cb, interval_sec, first_delay_sec);
}

int xprsnow_peer_count(uint32_t max_age_sec)
{
    return xb_peer_count(&s_now, max_age_sec);
}

uint8_t xprsnow_channel(void)
{
    uint8_t primary = 0;
    wifi_second_chan_t second;
    if (esp_wifi_get_channel(&primary, &second) != ESP_OK) return 0;
    return primary;
}

void xprsnow_stats(uint32_t *rx, uint32_t *tx, uint32_t *cancelled,
                   uint32_t *dropped)
{
    xb_stats(&s_now, rx, tx, cancelled);
    if (dropped) *dropped = s_dropped;
}

void xprsnow_tx_stats(uint32_t *issued, uint32_t *done, uint32_t *failed)
{
    if (issued) *issued = s_tx_issued;
    if (done)   *done   = s_tx_done;
    if (failed) *failed = s_tx_failed;
}

esp_err_t xprsnow_start(const char *callsign)
{
    if (s_started) return ESP_OK;

    s_rxq = xQueueCreate(XPRSNOW_RX_QUEUE, sizeof(nw_frame_t));
    if (!s_rxq) return ESP_ERR_NO_MEM;
    if (!s_tx_mtx) s_tx_mtx = xSemaphoreCreateMutex();
    if (!s_tx_mtx) { vQueueDelete(s_rxq); s_rxq = NULL; return ESP_ERR_NO_MEM; }

    esp_err_t err = esp_now_init();
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "esp_now_init failed: %s — is WiFi started?",
                 esp_err_to_name(err));
        vQueueDelete(s_rxq); s_rxq = NULL;
        return err;
    }

    /* One peer, ever: the broadcast address. channel 0 means "whatever channel
     * the station is on", which is the only channel we are allowed to use while
     * associated — see the header. Broadcast is never encrypted. */
    esp_now_peer_info_t peer = {
        .channel = 0,
        .ifidx = WIFI_IF_STA,
        .encrypt = false,
    };
    memcpy(peer.peer_addr, k_broadcast, 6);
    err = esp_now_add_peer(&peer);
    if (err != ESP_OK && err != ESP_ERR_ESPNOW_EXIST) {
        ESP_LOGW(TAG, "broadcast peer refused: %s", esp_err_to_name(err));
        esp_now_deinit();
        vQueueDelete(s_rxq); s_rxq = NULL;
        return err;
    }

    esp_now_register_recv_cb(nw_recv_cb);
    esp_now_register_send_cb(nw_send_cb);

    /* A station that modem-sleeps misses ESP-NOW frames while it is asleep.
     * This costs power and takes a share of the airtime back from Bluetooth,
     * which is a trade this board has to be measured against, not assumed. */
    esp_wifi_set_ps(WIFI_PS_NONE);

    s_started = true;
    xb_init(&s_now, &k_now_ops, callsign);
    xb_register_ticked(&s_now);

    /* This bearer does not own a task — it is pumped by whoever does. If nobody
     * has claimed that job, nothing here will ever re-air or beacon, and the
     * failure would be silent: frames arrive, the queue drains never, the peer
     * count sits at zero. Say it now, loudly, instead. */
    if (!xb_has_driver()) {
        ESP_LOGE(TAG, "no bearer task is running — ESP-NOW will receive nothing "
                      "and beacon never (start the LAN bearer, or give this one "
                      "a task)");
    }

    ESP_LOGI(TAG, "XPRS over ESP-NOW up on channel %u, callsign %s",
             xprsnow_channel(), callsign ? callsign : "");
    return ESP_OK;
}

void xprsnow_stop(void)
{
    if (!s_started) return;
    xb_stop(&s_now);
    esp_now_unregister_recv_cb();
    esp_now_unregister_send_cb();
    esp_now_deinit();
    s_started = false;
}
