/*
 * A Reticulum TCP interface: one socket to one hub, HDLC in both directions.
 *
 * This is what makes the dongle reachable beyond the room it is in. Reticulum
 * hubs speak HDLC-framed packets over TCP on port 4242, and a leaf that opens
 * one socket to one hub gets the whole network's routing for free — it does not
 * have to be a transport node itself, which is the entire reason a device with
 * fifteen kilobytes of heap can take part at all.
 *
 * Deliberately one socket. Several would want a table, a policy for which to
 * send on, and reconnection state per entry; a station that wants redundancy is
 * better served by a hub that has it.
 */

#include "rns.h"
#include "rns_tcp.h"

#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_log.h"
#include "esp_timer.h"

static const char *TAG = "rns_tcp";

/* Reconnect backoff: quick at first because the usual cause is that WiFi came
 * up a moment after we did, then slow, because the usual cause after that is a
 * hub that is down and hammering it helps nobody. */
#define RECONNECT_FAST_MS   2000
#define RECONNECT_SLOW_MS   30000
#define FAST_ATTEMPTS       5

static char     s_host[64];
static uint16_t s_port;
static volatile int s_sock = -1;
static volatile bool s_running;
static SemaphoreHandle_t s_tx_mtx;
static rns_tcp_rx_cb_t s_rx_cb;
static void *s_rx_ctx;

static rns_hdlc_rx_t s_rx;          /* static: 600-odd bytes, not stack */
static uint32_t s_rx_packets, s_tx_packets, s_connects;

bool rns_tcp_is_up(void) { return s_sock >= 0; }

void rns_tcp_stats(uint32_t *rx, uint32_t *tx, uint32_t *connects, uint32_t *dropped)
{
    if (rx) *rx = s_rx_packets;
    if (tx) *tx = s_tx_packets;
    if (connects) *connects = s_connects;
    if (dropped) *dropped = s_rx.dropped;
}

void rns_tcp_set_rx_cb(rns_tcp_rx_cb_t cb, void *ctx)
{
    s_rx_cb = cb;
    s_rx_ctx = ctx;
}

bool rns_tcp_send(const uint8_t *packet, size_t len)
{
    if (s_sock < 0 || !packet || len == 0) return false;

    /* Framed on the stack: an RNS packet is bounded and this keeps the buffer
     * out of the heap, which is the scarce thing on this board. */
    uint8_t framed[2 * (RNS_MTU + 64) + 2];
    int n = rns_hdlc_frame(packet, len, framed, sizeof framed);
    if (n <= 0) return false;

    xSemaphoreTake(s_tx_mtx, portMAX_DELAY);
    int sock = s_sock;
    bool ok = false;
    if (sock >= 0) {
        int sent = 0;
        while (sent < n) {
            int w = send(sock, framed + sent, (size_t)(n - sent), 0);
            if (w <= 0) break;
            sent += w;
        }
        ok = (sent == n);
        if (ok) s_tx_packets++;
    }
    xSemaphoreGive(s_tx_mtx);
    if (!ok) ESP_LOGW(TAG, "send failed (errno %d) — the socket will reconnect", errno);
    return ok;
}

static void on_frame(const uint8_t *frame, size_t len, void *ctx)
{
    (void)ctx;
    s_rx_packets++;
    if (s_rx_cb) s_rx_cb(frame, len, s_rx_ctx);
}

static int dial(void)
{
    struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM };
    struct addrinfo *res = NULL;
    char port[8];
    snprintf(port, sizeof port, "%u", (unsigned)s_port);
    if (getaddrinfo(s_host, port, &hints, &res) != 0 || !res) {
        ESP_LOGW(TAG, "cannot resolve %s", s_host);
        return -1;
    }
    int sock = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (sock < 0) { freeaddrinfo(res); return -1; }

    struct timeval tv = { .tv_sec = 10, .tv_usec = 0 };
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    if (connect(sock, res->ai_addr, res->ai_addrlen) != 0) {
        ESP_LOGW(TAG, "connect to %s:%u failed (errno %d)", s_host,
                 (unsigned)s_port, errno);
        close(sock);
        freeaddrinfo(res);
        return -1;
    }
    freeaddrinfo(res);

    /* A Reticulum packet is small and latency matters more than packing, so
     * Nagle would only delay announces behind nothing. */
    int one = 1;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    /* Read with a timeout so the task can notice s_running going false and
     * can be told to re-announce on a fresh connection. */
    tv.tv_sec = 1;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);

    ESP_LOGI(TAG, "connected to %s:%u", s_host, (unsigned)s_port);
    return sock;
}

static void rns_tcp_task(void *arg)
{
    (void)arg;
    int attempts = 0;
    static uint8_t buf[512];

    while (s_running) {
        int sock = dial();
        if (sock < 0) {
            attempts++;
            vTaskDelay(pdMS_TO_TICKS(attempts <= FAST_ATTEMPTS ? RECONNECT_FAST_MS
                                                               : RECONNECT_SLOW_MS));
            continue;
        }
        attempts = 0;
        rns_hdlc_rx_init(&s_rx);
        s_sock = sock;
        s_connects++;
        if (s_rx_cb) s_rx_cb(NULL, 0, s_rx_ctx);   /* "we are up" — announce now */

        while (s_running) {
            int n = recv(sock, buf, sizeof buf, 0);
            if (n > 0) {
                rns_hdlc_rx_feed(&s_rx, buf, (size_t)n, on_frame, NULL);
                continue;
            }
            if (n == 0) { ESP_LOGW(TAG, "hub closed the connection"); break; }
            if (errno == EAGAIN || errno == EWOULDBLOCK) continue;  /* just idle */
            ESP_LOGW(TAG, "recv failed (errno %d)", errno);
            break;
        }

        xSemaphoreTake(s_tx_mtx, portMAX_DELAY);
        s_sock = -1;
        xSemaphoreGive(s_tx_mtx);
        close(sock);
        if (s_running) vTaskDelay(pdMS_TO_TICKS(RECONNECT_FAST_MS));
    }
    vTaskDelete(NULL);
}

esp_err_t rns_tcp_start(const char *host, uint16_t port)
{
    if (s_running) return ESP_OK;
    if (!host || !*host) return ESP_ERR_INVALID_ARG;
    snprintf(s_host, sizeof s_host, "%s", host);
    s_port = port ? port : RNS_TCP_DEFAULT_PORT;
    if (!s_tx_mtx) s_tx_mtx = xSemaphoreCreateMutex();
    if (!s_tx_mtx) return ESP_ERR_NO_MEM;
    s_running = true;
    /* Core 1: core 0 carries the BLE controller, the NimBLE host, WiFi and
     * app_main, and this task blocks in recv() with a socket buffer behind it. */
    if (xTaskCreatePinnedToCore(rns_tcp_task, "rns_tcp", 4096, NULL, 4, NULL, 1)
        != pdPASS) {
        s_running = false;
        return ESP_FAIL;
    }
    ESP_LOGI(TAG, "interface to %s:%u starting", s_host, (unsigned)s_port);
    return ESP_OK;
}

void rns_tcp_stop(void)
{
    s_running = false;
    int sock = s_sock;
    if (sock >= 0) shutdown(sock, SHUT_RDWR);
}
