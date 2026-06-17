/**
 * @file aprsis.c
 * @brief APRS-IS iGate — bridges APRS-IS <-> BLE on the T-Dongle.
 *
 * Protocol logic (passcode, TNC2 parse/build) mirrors the Aurora desktop/
 * Android client (wapps/aprs/aprs.c); transport is lwip BSD sockets.
 */

#include "aprsis.h"

#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"

#include "esp_log.h"
#include "esp_timer.h"

#include "lwip/sockets.h"
#include "lwip/netdb.h"

#include "wifi_bsp.h"
#include "msgstore.h"

static const char *TAG = "aprsis";

/* BLE integration hooks (see aprsis.h) — set by the firmware that owns the BLE
 * link. Both optional: NULL get_heard => no heard calls; NULL relay => no
 * downlink (uplink-only iGate). */
static aprsis_get_heard_fn s_get_heard = NULL;
static aprsis_relay_fn     s_relay     = NULL;

void aprsis_set_ble_hooks(aprsis_get_heard_fn get_heard, aprsis_relay_fn relay)
{
    s_get_heard = get_heard;
    s_relay = relay;
}

static int hook_get_heard(char calls[][8], int max, uint32_t max_age_sec)
{
    return s_get_heard ? s_get_heard(calls, max, max_age_sec) : 0;
}

/* ---- configuration ------------------------------------------------------ */

#define APRSIS_HOST         "rotate.aprs2.net"
#define APRSIS_PORT         14580
#define APRSIS_RADIUS_KM    50          /* "nearby" radius when coords defined */
#define HEARD_AGE_SEC       31536000    /* keep heard stations ~1 year (store-fwd) */
#define FILTER_CALLS_MAX    24          /* heard calls put in the g/ filter     */
#define FILTER_CHECK_SEC    30          /* re-evaluate filter this often        */
#define RECONNECT_DELAY_MS  8000
#define UPLINK_Q_LEN        8
#define UPLINK_DEDUP_MAX    16
#define UPLINK_DEDUP_SEC    300         /* don't re-gate same content for 5 min */

/* Operator coordinates — undefined (0,0) by default; the T-Dongle has no GPS,
 * so "nearby" position traffic is only gated once these are set (compile-time
 * here or at runtime via aprsis_set_position). */
#ifndef APRSIS_DEFAULT_LAT
#define APRSIS_DEFAULT_LAT  0.0
#endif
#ifndef APRSIS_DEFAULT_LON
#define APRSIS_DEFAULT_LON  0.0
#endif

/* ---- APRS packet model (subset we act on) ------------------------------- */

enum { APRS_OTHER = 0, APRS_POSITION = 1, APRS_MESSAGE = 2 };

typedef struct {
    char   from[16];
    int    type;
    int    has_pos;
    double lat, lon;
    char   addressee[16];
    char   text[160];
    char   comment[80];
} aprs_packet_t;

typedef struct {
    char from[16];
    char to[16];
    char text[160];
} uplink_job_t;

/* ---- state -------------------------------------------------------------- */

static char            s_call[10];
static int             s_pass;
static volatile double s_lat = APRSIS_DEFAULT_LAT;
static volatile double s_lon = APRSIS_DEFAULT_LON;
static volatile int    s_radius_km = APRSIS_RADIUS_KM;
static volatile bool   s_have_pos;
static volatile bool   s_connected;
static volatile bool   s_running;
/* Separate archives: text messages vs automated position beacons. Set by the
 * owner via aprsis_set_stores(); NULL until then (add is a safe no-op). */
static msgstore_t     *s_msg_store;
static msgstore_t     *s_beacon_store;
/* RX diagnostics (exposed via aprsis_get_rx_stats). */
static volatile uint32_t s_rx_lines;   /* info lines received from APRS-IS      */
static volatile uint32_t s_rx_msgs;    /* of those, parsed as APRS messages     */
static volatile uint32_t s_rx_gated;   /* messages whose addressee is local     */
static QueueHandle_t   s_uplink_q;
static int             s_seq = 1;

typedef struct { uint32_t hash; uint32_t t; } dedup_t;
static dedup_t s_up_dedup[UPLINK_DEDUP_MAX];
static int     s_up_dedup_cnt;

/* ---- small helpers ------------------------------------------------------ */

static uint32_t now_sec(void) { return (uint32_t)(esp_timer_get_time() / 1000000ULL); }

static char a_up(char c) { return (c >= 'a' && c <= 'z') ? (char)(c - 'a' + 'A') : c; }
static int  a_digit(char c) { return c >= '0' && c <= '9'; }

static uint32_t fnv1a(const char *d, int n)
{
    uint32_t h = 2166136261u;
    for (int i = 0; i < n; i++) { h ^= (uint8_t)d[i]; h *= 16777619u; }
    return h;
}

/* Normalise a callsign: uppercase, drop any "-SSID". */
static void norm_call(const char *in, char *out, int max)
{
    int n = 0;
    for (int i = 0; in[i] && in[i] != '-' && n < max - 1; i++) out[n++] = a_up(in[i]);
    out[n] = 0;
}
static bool call_eq(const char *a, const char *b)
{
    char x[12], y[12];
    norm_call(a, x, sizeof x);
    norm_call(b, y, sizeof y);
    return strcmp(x, y) == 0;
}

/* substring [a,b) as int / double (digits only, no sign) */
static int a_sub_int(const char *s, int a, int b)
{
    int v = 0, seen = 0;
    for (int i = a; i < b; i++) { if (a_digit(s[i])) { v = v * 10 + (s[i] - '0'); seen = 1; } }
    return seen ? v : -1;
}
static double a_sub_dbl(const char *s, int a, int b)
{
    double v = 0, f = 0.1; int dot = 0;
    for (int i = a; i < b; i++) {
        char c = s[i];
        if (c == '.') { dot = 1; continue; }
        if (!a_digit(c)) continue;
        if (!dot) v = v * 10 + (c - '0');
        else { v += (c - '0') * f; f *= 0.1; }
    }
    return v;
}

/* ---- APRS-IS passcode (port of aprs_passcode) --------------------------- */

static int aprs_passcode(const char *callsign)
{
    char base[16]; int n = 0;
    for (int i = 0; callsign[i] && callsign[i] != '-' && n < 15; i++)
        base[n++] = a_up(callsign[i]);
    base[n] = 0;
    int hash = 0x73e2;
    for (int i = 0; i < n;) {
        hash ^= (int)base[i] << 8; i++;
        if (i < n) { hash ^= (int)base[i]; i++; }
    }
    return hash & 0x7FFF;
}

/* ---- parsing (port of aprs.c) ------------------------------------------- */

static int classify(const char *info)
{
    if (!info[0]) return APRS_OTHER;
    char c = info[0];
    if (c == '!' || c == '/' || c == '=' || c == '@') return APRS_POSITION;
    if (c == ':') return APRS_MESSAGE;
    if (c == ';' || c == ')') return APRS_POSITION;
    return APRS_OTHER;
}

static int parse_uncompressed(const char *d, double *lat, double *lon)
{
    if ((int)strlen(d) < 19) return 0;
    int latDeg = a_sub_int(d, 0, 2);
    double latMin = a_sub_dbl(d, 2, 7);
    char latH = d[7];
    int lonDeg = a_sub_int(d, 9, 12);
    double lonMin = a_sub_dbl(d, 12, 17);
    char lonH = d[17];
    if (latDeg < 0 || lonDeg < 0) return 0;
    if (latH != 'N' && latH != 'S') return 0;
    if (lonH != 'E' && lonH != 'W') return 0;
    double la = latDeg + latMin / 60.0;
    double lo = lonDeg + lonMin / 60.0;
    if (latH == 'S') la = -la;
    if (lonH == 'W') lo = -lo;
    if (la < -90 || la > 90 || lo < -180 || lo > 180) return 0;
    *lat = la; *lon = lo; return 1;
}

static int parse_position(const char *info, double *lat, double *lon)
{
    char c = info[0];
    if (c == '`' || c == '\'' || c == ';' || c == ')') return 0;  /* skip complex */
    const char *pos;
    if (c == '/' || c == '@') { if ((int)strlen(info) < 9) return 0; pos = info + 8; }
    else                       pos = info + 1;
    if (!pos[0] || !a_digit(pos[0])) return 0;   /* only uncompressed for igate */
    return parse_uncompressed(pos, lat, lon);
}

static int aprs_parse(const char *line, aprs_packet_t *out)
{
    memset(out, 0, sizeof *out);
    int colon = -1;
    for (int i = 0; line[i]; i++) if (line[i] == ':') { colon = i; break; }
    if (colon < 0 || !line[colon + 1]) return 0;
    int gt = -1;
    for (int i = 0; i < colon; i++) if (line[i] == '>') { gt = i; break; }
    if (gt < 0) return 0;
    int fn = gt < 15 ? gt : 15;
    memcpy(out->from, line, fn); out->from[fn] = 0;

    const char *info = line + colon + 1;
    out->type = classify(info);

    if (out->type == APRS_MESSAGE) {
        int sc = -1;
        for (int i = 1; info[i]; i++) if (info[i] == ':') { sc = i; break; }
        if (sc > 1) {
            int an = sc - 1; if (an > 15) an = 15;
            int w = 0;
            for (int i = 1; i <= an; i++) if (info[i] != ' ') out->addressee[w++] = info[i];
            out->addressee[w] = 0;
            const char *body = info + sc + 1;
            int brace = -1;
            for (int i = 0; body[i]; i++) if (body[i] == '{') { brace = i; break; }
            int tn = brace >= 0 ? brace : (int)strlen(body);
            if (tn > 159) tn = 159;
            memcpy(out->text, body, tn); out->text[tn] = 0;
        }
    } else if (out->type == APRS_POSITION) {
        double la, lo;
        if (parse_position(info, &la, &lo)) { out->has_pos = 1; out->lat = la; out->lon = lo; }
    }
    return 1;
}

/* ---- transmit builders (port of aprs.c) --------------------------------- */

static void fmt_lat(double dd, char *b)
{
    char h = 'N'; if (dd < 0) { h = 'S'; dd = -dd; }
    int deg = (int)dd; double m = (dd - deg) * 60.0;
    int mi = (int)m; int mh = (int)((m - mi) * 100.0 + 0.5);
    sprintf(b, "%02d%02d.%02d%c", deg % 100, mi, mh, h);
}
static void fmt_lon(double dd, char *b)
{
    char h = 'E'; if (dd < 0) { h = 'W'; dd = -dd; }
    int deg = (int)dd; double m = (dd - deg) * 60.0;
    int mi = (int)m; int mh = (int)((m - mi) * 100.0 + 0.5);
    sprintf(b, "%03d%02d.%02d%c", deg % 1000, mi, mh, h);
}

/* Uppercase a callsign into a 9-char space-padded APRS addressee field. */
static void pad_addressee(const char *to, char dest[10])
{
    int i = 0;
    for (; to[i] && i < 9; i++) dest[i] = a_up(to[i]);
    for (; i < 9; i++) dest[i] = ' ';
    dest[9] = 0;
}

/* ---- heard / locality --------------------------------------------------- */

static bool is_local_call(const char *c)
{
    if (call_eq(c, s_call)) return true;
    char heard[FILTER_CALLS_MAX][8];
    int hn = hook_get_heard(heard, FILTER_CALLS_MAX, HEARD_AGE_SEC);
    for (int i = 0; i < hn; i++) if (call_eq(c, heard[i])) return true;
    return false;
}

/* Build the APRS-IS server-side filter from heard calls (+ position). */
static void build_filter(char *out, size_t max)
{
    char heard[FILTER_CALLS_MAX][8];
    int hn = hook_get_heard(heard, FILTER_CALLS_MAX, HEARD_AGE_SEC);
    int o = snprintf(out, max, "g/%s", s_call);
    for (int i = 0; i < hn && o < (int)max - 12; i++)
        o += snprintf(out + o, max - o, "/%s", heard[i]);
    if (s_have_pos && o < (int)max - 32)
        snprintf(out + o, max - o, " r/%.4f/%.4f/%d", s_lat, s_lon, s_radius_km);
}

/* ---- uplink dedup ------------------------------------------------------- */

static bool uplink_seen(uint32_t h)
{
    uint32_t t = now_sec();
    int n = s_up_dedup_cnt < UPLINK_DEDUP_MAX ? s_up_dedup_cnt : UPLINK_DEDUP_MAX;
    for (int i = 0; i < n; i++)
        if (s_up_dedup[i].hash == h && (t - s_up_dedup[i].t) < UPLINK_DEDUP_SEC) return true;
    return false;
}
static void uplink_remember(uint32_t h)
{
    int idx = s_up_dedup_cnt % UPLINK_DEDUP_MAX;
    s_up_dedup[idx].hash = h; s_up_dedup[idx].t = now_sec(); s_up_dedup_cnt++;
}

/* ---- socket ------------------------------------------------------------- */

static int aprsis_connect(void)
{
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    char ports[8]; snprintf(ports, sizeof ports, "%d", APRSIS_PORT);
    if (getaddrinfo(APRSIS_HOST, ports, &hints, &res) != 0 || !res) {
        ESP_LOGW(TAG, "DNS lookup failed for %s", APRSIS_HOST);
        return -1;
    }
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) { freeaddrinfo(res); return -1; }
    if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) {
        ESP_LOGW(TAG, "connect to %s:%d failed (errno %d)", APRSIS_HOST, APRSIS_PORT, errno);
        close(fd); freeaddrinfo(res); return -1;
    }
    freeaddrinfo(res);
    struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    return fd;
}

static bool send_line(int fd, const char *s)
{
    int len = (int)strlen(s);
    return send(fd, s, len, 0) == len;
}

/* ---- RX: gate one APRS-IS info line to BLE ------------------------------ */

static void handle_info_line(const char *line)
{
    s_rx_lines++;
    aprs_packet_t p;
    if (!aprs_parse(line, &p)) return;
    if (call_eq(p.from, s_call)) return;          /* never relay our own */

    if (p.type == APRS_MESSAGE) {
        if (!p.addressee[0] || !p.text[0]) return;
        s_rx_msgs++;
        bool local = is_local_call(p.addressee);
        /* MESSAGES archive: every text message we receive. The server-side filter
         * already scoped these to our callsigns (g/) plus, when a position is set,
         * everything within radius (r/) — so an arriving message is either for us
         * or live area chatter; both belong in the messages archive. Persist FIRST
         * (queries must not depend on the BLE relay), then relay. */
        if (local) s_rx_gated++;
        msgstore_add(s_msg_store, p.from, p.addressee, p.text,
                     MSGSTORE_KIND_MESSAGE, 0, false);
        /* Relay over BLE only what is addressed to a locally-heard callsign (the
         * phone user) — third-party area chatter is archived but not pushed. */
        if (local && s_relay) s_relay(p.from, p.addressee, p.text);
    } else if (p.type == APRS_POSITION && p.has_pos) {
        /* BEACONS archive: automated position reports. Only arrive when a position
         * is set (the r/ filter is added then), so they are already within radius.
         * Compact "lat,lon" (3 decimals ~110 m) also fits the tiny BLE advert. */
        char pos[40];
        snprintf(pos, sizeof pos, "%.3f,%.3f", p.lat, p.lon);
        msgstore_add(s_beacon_store, p.from, "!", pos, MSGSTORE_KIND_POSITION, 0, false);
        if (s_have_pos && s_relay) s_relay(p.from, "!", pos);
    }
}

/* ---- TX: gate one BLE-heard frame up to APRS-IS ------------------------- */

static void do_uplink(int fd, const uplink_job_t *j)
{
    if (call_eq(j->from, s_call)) return;         /* don't gate our own beacons */

    uint32_t h = fnv1a(j->from, (int)strlen(j->from))
               ^ fnv1a(j->to, (int)strlen(j->to))
               ^ fnv1a(j->text, (int)strlen(j->text));
    if (uplink_seen(h)) return;
    uplink_remember(h);

    /* RF -> IS gating uses the q-construct: the original station stays the
     * source and the iGate adds ",qAR,<igatecall>" to the path. (Third-party
     * "}" with a TCPIP* inner path is rejected by APRS-IS as a loop.) */
    char line[320];
    if (strcmp(j->to, "!") == 0) {                /* position beacon */
        const char *comma = strchr(j->text, ',');
        if (!comma) return;
        double lat = atof(j->text), lon = atof(comma + 1);
        if (lat == 0 && lon == 0) return;
        char la[16], lo[16];
        fmt_lat(lat, la); fmt_lon(lon, lo);
        snprintf(line, sizeof line, "%s>APRS,qAR,%s:!%s/%s>\r\n",
                 j->from, s_call, la, lo);
    } else if (j->to[0] && j->to[0] != '#') {     /* direct message */
        char dest[10]; pad_addressee(j->to, dest);
        snprintf(line, sizeof line, "%s>APRS,qAR,%s::%s:%s{%d\r\n",
                 j->from, s_call, dest, j->text, s_seq++);
    } else {
        return;                                   /* geo-chat / groups: not gated */
    }

    if (send_line(fd, line)) {
        size_t n = strlen(line);
        ESP_LOGI(TAG, "iGate uplink -> APRS-IS: %.*s", (int)(n >= 2 ? n - 2 : n), line);
    }
}

/* ---- task --------------------------------------------------------------- */

static void aprsis_task(void *arg)
{
    (void)arg;
    static char acc[2048];
    static char rd[1024];
    char cur_filter[256] = {0};

    while (s_running) {
        /* Wait for WiFi + IP. */
        if (geogram_wifi_get_status() != GEOGRAM_WIFI_STATUS_GOT_IP) {
            vTaskDelay(pdMS_TO_TICKS(2000));
            continue;
        }

        int fd = aprsis_connect();
        if (fd < 0) { vTaskDelay(pdMS_TO_TICKS(RECONNECT_DELAY_MS)); continue; }

        build_filter(cur_filter, sizeof cur_filter);
        char login[420];
        snprintf(login, sizeof login,
                 "user %s pass %d vers GeogramIgate 0.1 filter %s\r\n",
                 s_call, s_pass, cur_filter);
        if (!send_line(fd, login)) { close(fd); vTaskDelay(pdMS_TO_TICKS(RECONNECT_DELAY_MS)); continue; }
        ESP_LOGI(TAG, "connected; login as %s, filter: %s", s_call, cur_filter);

        s_connected = true;
        int acclen = 0;
        uint32_t last_check = now_sec();

        while (s_running) {
            /* TX: drain anything heard over BLE awaiting uplink. */
            uplink_job_t job;
            while (xQueueReceive(s_uplink_q, &job, 0) == pdTRUE) do_uplink(fd, &job);

            /* RX: read whatever is available (1 s timeout). */
            int n = recv(fd, rd, sizeof rd, 0);
            if (n == 0) { ESP_LOGW(TAG, "APRS-IS closed connection"); break; }
            if (n < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINPROGRESS) {
                    /* idle timeout — fall through to periodic work */
                } else { ESP_LOGW(TAG, "recv error %d", errno); break; }
            } else {
                if (acclen + n > (int)sizeof(acc) - 1) acclen = 0;   /* overflow guard */
                memcpy(acc + acclen, rd, n); acclen += n;
                int start = 0;
                for (int i = 0; i < acclen; i++) {
                    if (acc[i] != '\n') continue;
                    acc[i] = 0;
                    if (i > start && acc[i - 1] == '\r') acc[i - 1] = 0;
                    const char *l = acc + start;
                    if (l[0] && l[0] != '#') handle_info_line(l);
                    start = i + 1;
                }
                if (start > 0) { memmove(acc, acc + start, acclen - start); acclen -= start; }
            }

            /* Periodic: keepalive + re-evaluate the filter (reconnect if the
             * heard set / position changed). */
            uint32_t t = now_sec();
            if (t - last_check >= FILTER_CHECK_SEC) {
                last_check = t;
                if (!send_line(fd, "# keepalive\r\n")) { ESP_LOGW(TAG, "keepalive send failed"); break; }
                char nf[256];
                build_filter(nf, sizeof nf);
                if (strcmp(nf, cur_filter) != 0) {
                    ESP_LOGI(TAG, "filter changed -> reconnecting");
                    break;
                }
            }
        }

        s_connected = false;
        close(fd);
        vTaskDelay(pdMS_TO_TICKS(RECONNECT_DELAY_MS));
    }
    vTaskDelete(NULL);
}

/* ---- public API --------------------------------------------------------- */

esp_err_t aprsis_init(const char *callsign)
{
    if (s_running) return ESP_ERR_INVALID_STATE;
    if (!callsign || !callsign[0]) return ESP_ERR_INVALID_ARG;

    strncpy(s_call, callsign, sizeof s_call - 1);
    s_call[sizeof s_call - 1] = 0;
    s_pass = aprs_passcode(s_call);
    s_have_pos = (s_lat != 0.0 || s_lon != 0.0);

    s_uplink_q = xQueueCreate(UPLINK_Q_LEN, sizeof(uplink_job_t));
    if (!s_uplink_q) return ESP_ERR_NO_MEM;

    s_running = true;
    if (xTaskCreate(aprsis_task, "aprsis", 6144, NULL, 5, NULL) != pdPASS) {
        s_running = false;
        vQueueDelete(s_uplink_q);
        s_uplink_q = NULL;
        return ESP_FAIL;
    }
    ESP_LOGI(TAG, "iGate started — call %s, passcode %d%s",
             s_call, s_pass, s_have_pos ? " (position set)" : " (no position)");
    return ESP_OK;
}

void aprsis_set_position(double lat, double lon, int radius_km)
{
    s_lat = lat;
    s_lon = lon;
    if (radius_km > 0) s_radius_km = radius_km;
    s_have_pos = (lat != 0.0 || lon != 0.0);
    ESP_LOGI(TAG, "position %s: %.4f, %.4f r=%dkm",
             s_have_pos ? "set" : "cleared", lat, lon, s_radius_km);
    /* The APRS-IS filter is rebuilt on the next FILTER_CHECK_SEC tick; force a
     * reconnect-on-change by clearing nothing here — the task notices via
     * build_filter compare. */
}

void aprsis_get_position(double *lat, double *lon, int *radius_km, bool *have_pos)
{
    if (lat) *lat = s_lat;
    if (lon) *lon = s_lon;
    if (radius_km) *radius_km = s_radius_km;
    if (have_pos) *have_pos = s_have_pos;
}

void aprsis_set_stores(msgstore_t *messages, msgstore_t *beacons)
{
    s_msg_store = messages;
    s_beacon_store = beacons;
}

void aprsis_uplink(const char *from, const char *to, const char *text)
{
    if (!s_uplink_q || !from || !to || !text) return;
    uplink_job_t j;
    strncpy(j.from, from, sizeof j.from - 1); j.from[sizeof j.from - 1] = 0;
    strncpy(j.to, to, sizeof j.to - 1);       j.to[sizeof j.to - 1] = 0;
    strncpy(j.text, text, sizeof j.text - 1); j.text[sizeof j.text - 1] = 0;
    xQueueSend(s_uplink_q, &j, 0);            /* drop if full — best effort */
}

bool aprsis_is_connected(void) { return s_connected; }

void aprsis_get_rx_stats(uint32_t *lines, uint32_t *msgs, uint32_t *gated)
{
    if (lines) *lines = s_rx_lines;
    if (msgs)  *msgs  = s_rx_msgs;
    if (gated) *gated = s_rx_gated;
}
