/*
 * lanwatch — passive listener on the Aurora LAN discovery UDP broadcast.
 *
 * Wire format (aurora rns_lan_interface.dart): one raw RNS packet per UDP
 * datagram, announces only. We parse just enough of an ANNOUNCE to (a) verify
 * it really is one and (b) pull the plaintext app_data out of the tail — for
 * the chat/LXMF destinations that app_data is the device callsign. Devices
 * are deduped by source IP: a phone announces several destinations (chat,
 * files, LXMF, relay — some with empty or binary app_data), but it is still
 * ONE device on the LAN.
 */
#include "lanwatch.h"

#include <string.h>
#include <stdio.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "lwip/sockets.h"

static const char *TAG = "lanwatch";

/* RNS announce layout constants (match aurora/reticulum-dart, RNS 1.3.5). */
#define RNS_PKT_ANNOUNCE 0x01
#define DST_HASH_LEN     16
#define KEYSIZE          64
#define NAME_HASH_LEN    10
#define RANDOM_HASH_LEN  10
#define RATCHET_LEN      32
#define SIG_LEN          64

/* ---- registry ------------------------------------------------------------ */
typedef struct {
    uint32_t ip;                                  /* 0 = free slot */
    char     callsign[LANWATCH_CALLSIGN_MAX + 1];
    uint32_t last_seen;                           /* monotonic seconds */
} entry_t;

static entry_t           s_peers[LANWATCH_PEERS_MAX];
static SemaphoreHandle_t s_mtx;

static uint32_t now_sec(void)
{
    return (uint32_t)(esp_timer_get_time() / 1000000ULL);
}

/* app_data is "a callsign" when it is short and looks like one (letters,
 * digits, '-', '_'). Filters out the service announces that carry empty or
 * binary app_data without needing to know their destination name hashes. */
static bool is_callsign(const uint8_t *d, int len)
{
    if (len < 2 || len > LANWATCH_CALLSIGN_MAX) return false;
    for (int i = 0; i < len; i++) {
        uint8_t c = d[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || c == '-' || c == '_'))
            return false;
    }
    return true;
}

/* Parse a raw RNS packet; returns true if it is an announce, with the
 * app_data tail in [app]/[applen] (may be empty). Never reads past [len]. */
static bool parse_announce(const uint8_t *pkt, int len,
                           const uint8_t **app, int *applen)
{
    if (len < 2 + DST_HASH_LEN + 1) return false;
    uint8_t flags = pkt[0];
    if ((flags & 0x03) != RNS_PKT_ANNOUNCE) return false;
    uint8_t htype = (flags >> 6) & 0x01;      /* HEADER_2 carries 2 addresses */
    uint8_t ctxflag = (flags >> 5) & 0x01;    /* ratchet present */

    int dataoff = htype ? (2 + DST_HASH_LEN + DST_HASH_LEN + 1)
                        : (2 + DST_HASH_LEN + 1);
    if (len <= dataoff) return false;
    int adlen = len - dataoff;
    int appoff = KEYSIZE + NAME_HASH_LEN + RANDOM_HASH_LEN +
                 (ctxflag ? RATCHET_LEN : 0) + SIG_LEN;
    if (adlen < appoff) return false;         /* truncated/garbage */
    *app = pkt + dataoff + appoff;
    *applen = adlen - appoff;
    return true;
}

static void registry_touch(uint32_t ip, const uint8_t *name, int name_len)
{
    xSemaphoreTake(s_mtx, portMAX_DELAY);
    uint32_t t = now_sec();
    int slot = -1, oldest = 0;
    for (int i = 0; i < LANWATCH_PEERS_MAX; i++) {
        if (s_peers[i].ip == ip) { slot = i; break; }
        if (s_peers[i].ip == 0) { slot = i; break; }
        if (s_peers[i].last_seen < s_peers[oldest].last_seen) oldest = i;
    }
    if (slot < 0) slot = oldest;
    if (s_peers[slot].ip != ip) {              /* new/evicted slot: reset name */
        s_peers[slot].ip = ip;
        s_peers[slot].callsign[0] = 0;
    }
    s_peers[slot].last_seen = t ? t : 1;
    if (name_len > 0) {                        /* remember the latest name */
        memcpy(s_peers[slot].callsign, name, name_len);
        s_peers[slot].callsign[name_len] = 0;
    }
    xSemaphoreGive(s_mtx);
}

/* ---- listener task -------------------------------------------------------- */
static void lanwatch_task(void *arg)
{
    int fd = (int)(intptr_t)arg;
    static uint8_t buf[600];                   /* > RNS MTU (500) */
    for (;;) {
        struct sockaddr_in src;
        socklen_t slen = sizeof(src);
        int n = recvfrom(fd, buf, sizeof(buf), 0,
                         (struct sockaddr *)&src, &slen);
        if (n <= 0) { vTaskDelay(pdMS_TO_TICKS(100)); continue; }

        const uint8_t *app = NULL;
        int applen = 0;
        if (!parse_announce(buf, n, &app, &applen)) continue;
        bool named = is_callsign(app, applen);
        registry_touch(src.sin_addr.s_addr, named ? app : NULL,
                       named ? applen : 0);
    }
}

/* ---- public API ------------------------------------------------------------ */
esp_err_t lanwatch_start(uint16_t port)
{
    if (s_mtx) return ESP_OK;                  /* already running */
    if (port == 0) port = LANWATCH_DEFAULT_PORT;

    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
    if (fd < 0) {
        ESP_LOGE(TAG, "socket() failed: errno %d", errno);
        return ESP_FAIL;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        ESP_LOGE(TAG, "bind(%u) failed: errno %d", port, errno);
        close(fd);
        return ESP_FAIL;
    }

    s_mtx = xSemaphoreCreateMutex();
    if (xTaskCreate(lanwatch_task, "lanwatch", 3072,
                    (void *)(intptr_t)fd, 3, NULL) != pdPASS) {
        ESP_LOGE(TAG, "task create failed");
        close(fd);
        return ESP_FAIL;
    }
    ESP_LOGI(TAG, "listening for Aurora LAN announces on UDP %u", port);
    return ESP_OK;
}

int lanwatch_count(uint32_t max_age_sec)
{
    return lanwatch_peers(NULL, LANWATCH_PEERS_MAX, max_age_sec);
}

int lanwatch_peers(lanwatch_peer_t *out, int max, uint32_t max_age_sec)
{
    if (!s_mtx) return 0;
    int n = 0;
    uint32_t t = now_sec();
    xSemaphoreTake(s_mtx, portMAX_DELAY);
    for (int i = 0; i < LANWATCH_PEERS_MAX && n < max; i++) {
        if (!s_peers[i].ip || (t - s_peers[i].last_seen) >= max_age_sec)
            continue;
        if (out) {
            out[n].ip = s_peers[i].ip;
            snprintf(out[n].callsign, sizeof(out[n].callsign), "%s",
                     s_peers[i].callsign);
            out[n].age_sec = t - s_peers[i].last_seen;
        }
        n++;
    }
    xSemaphoreGive(s_mtx);
    return n;
}
