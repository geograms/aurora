/**
 * @file ble_hello.c
 * @brief Standalone BLE HELLO protocol — advertising, scanning, GATT.
 */

#include "ble_hello.h"
#include "ble_parcel.h"

#include <string.h>
#include <stdio.h>

#include "esp_log.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "nvs_flash.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "nimble/hci_common.h"
#include "host/ble_hs.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/ble_att.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "cJSON.h"

static const char *TAG = "ble_hello";

/* ---- Geogram BLE constants ---------------------------------------------- */

#define GEOGRAM_MARKER      0x3E        /* '>' */
#define COMPANY_ID_LO       0xFF        /* test company ID 0xFFFF */
#define COMPANY_ID_HI       0xFF
#define MAX_SEEN            16
#define EXPIRE_SEC          60

/* APRS-over-BLE mesh repeater: rebroadcast each received Aurora frame once,
 * suppressing any frame whose content was already relayed in the last 10 min
 * (loop/storm control). Relayed frames are advertised for RELAY_TTL_SEC so
 * neighbours catch them within a scan window. */
#define RELAY_MAX           8           /* concurrent frames queued for relay */
#define RELAY_TTL_SEC       30          /* how long to keep rebroadcasting one */
#define RDEDUP_MAX          32          /* recently-relayed content cache */
#define RELAY_DEDUP_SEC     600         /* 10-minute suppression window */

/* Display dedup: a received message is delivered to the chat only once per
 * SHOWN_DEDUP_SEC. A single broadcast is received dozens of times across an
 * advert window, and the mesh relays it too, so without this the same line
 * repeats on the rolling chat. */
#define SHOWN_MAX           48          /* recently-shown message cache */
#define SHOWN_DEDUP_SEC     3600        /* 60-minute display suppression */

/* Heard-callsign registry: every station whose callsign we saw over BLE
 * (presence beacon or APRS frame `from`). The APRS-IS iGate reads this to
 * build its message filter (only pull traffic addressed to local stations). */
#define HEARD_MAX           24          /* distinct callsigns remembered */

/* Longer APRS messages over BLE — same technique as geogram_ble_aprs
 * (BlueAPRS): a compact frame that overflows the primary legacy advert carries
 * the remainder in the active-scan SCAN_RSP, so any active scanner reassembles
 * it (works on all devices). The primary advert stays the bare compact form
 * (company id + payload) so the Aurora app still reads the first part; the
 * SCAN_RSP continuation is marked so it isn't mis-parsed:
 *   ADV mfg:      [0xFF,0xFF, <payload[0 .. ADV_PAYLOAD_CAP)>]
 *   SCAN_RSP mfg: [0xFF,0xFF, 0x3E, 'B', <payload[ADV_PAYLOAD_CAP ..])>] */
#define APRS_CONT_SUBTYPE   0x42        /* 'B' — SCAN_RSP continuation marker */
#define ADV_MFG_CAP         20          /* company(2)+payload(18) — safe in a legacy advert beside flags+FFE0 */
#define ADV_PAYLOAD_CAP     (ADV_MFG_CAP - 2)
#define CONT_HDR_LEN        4           /* company(2)+marker(1)+subtype(1) */
#define CONT_PAYLOAD_CAP    24          /* overflow bytes carried in SCAN_RSP */
#define APRS_MFG_MAX        (2 + ADV_PAYLOAD_CAP + CONT_PAYLOAD_CAP)  /* 44 */

/* GATT UUIDs */
#define SVC_UUID            0xFFE0
#define CHR_WRITE_UUID      0xFFF1
#define CHR_NOTIFY_UUID     0xFFF2

/* Time-sharing: NimBLE legacy can't advertise + scan simultaneously.
 * Scan-heavy duty cycle so we reliably catch APRS frames from phones/desktops
 * (whose adverts rotate/refresh and are only briefly on air), with short
 * advertise windows in between for presence. */
#define ADV_DURATION_SEC    6           /* advertise window between scans */
#define SCAN_DURATION_MS    5000        /* scan for 5s (~80% of the cycle) */

/* ---- state -------------------------------------------------------------- */

static bool     s_active;
static char     s_callsign[8];          /* "X3XXXX\0" */
static uint8_t  s_device_id;            /* (MAC hash % 15) + 1 */

/* Manufacturer data: [company_lo, company_hi, marker, device_id, callsign...] */
static uint8_t  s_mfg_data[4 + 6];     /* max 10 bytes */
static uint8_t  s_mfg_len;

/* Seen devices (passive scan) */
typedef struct {
    uint8_t addr[6];
    uint32_t last_seen;                 /* seconds since boot */
} seen_entry_t;

static seen_entry_t s_seen[MAX_SEEN];
static int          s_seen_count;

/* Aurora APRS-over-BLE receive callback (optional, set by app) */
static ble_hello_aprs_cb_t s_aprs_cb;

/* APRS relay state */
typedef struct {
    uint8_t  mfg[APRS_MFG_MAX];         /* full manufacturer data to rebroadcast
                                           (split across ADV + SCAN_RSP if long) */
    uint8_t  len;                       /* 0 = empty slot */
    uint32_t expire;                    /* seconds-since-boot when it lapses */
} relay_slot_t;
static relay_slot_t s_relay[RELAY_MAX];
static int          s_relay_rr;         /* round-robin advertise cursor */

/* Reassembly: a compact APRS primary advert (no marker) is held until the next
 * scan event tells us whether a SCAN_RSP continuation follows. Pairing is by
 * advertiser address; everything runs in the NimBLE host task (no locking). */
static struct {
    bool     active;
    uint8_t  addr[6];
    uint8_t  mfg[APRS_MFG_MAX];
    int      len;
    int      rssi;
} s_pending;

typedef struct { uint32_t hash; uint32_t t; } rdedup_t;
static rdedup_t s_rdedup[RDEDUP_MAX];
static int      s_rdedup_cnt;

/* Display dedup state (same shape as relay dedup, longer window) */
static rdedup_t s_shown[SHOWN_MAX];
static int      s_shown_cnt;

/* Heard-callsign registry (uppercased, NUL-terminated, SSID stripped). */
typedef struct { char call[8]; uint32_t t; } heard_t;
static heard_t s_heard[HEARD_MAX];
static int     s_heard_cnt;

/* GATT */
static uint16_t s_notify_handle;
static uint16_t s_conn_handle;
static bool     s_conn_active;

/* Time-sharing state */
static esp_timer_handle_t s_cycle_timer;
static bool     s_scanning;             /* true = scan phase, false = adv phase */

/* ---- helpers ------------------------------------------------------------ */

/* Forward declarations */
static int ble_hello_gap_event(struct ble_gap_event *event, void *arg);
static void aprs_decode(const uint8_t *payload, int len, int rssi);

static uint32_t now_sec(void)
{
    return (uint32_t)(esp_timer_get_time() / 1000000ULL);
}

static uint8_t compute_device_id(void)
{
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_BT);
    uint32_t h = 2166136261u;
    for (int i = 0; i < 6; i++) {
        h ^= mac[i];
        h *= 16777619u;
    }
    return (uint8_t)((h % 15) + 1);
}

static void build_mfg_data(void)
{
    s_mfg_data[0] = COMPANY_ID_LO;
    s_mfg_data[1] = COMPANY_ID_HI;
    s_mfg_data[2] = GEOGRAM_MARKER;
    s_mfg_data[3] = s_device_id;
    size_t cslen = strlen(s_callsign);
    if (cslen > 6) cslen = 6;
    memcpy(&s_mfg_data[4], s_callsign, cslen);
    s_mfg_len = (uint8_t)(4 + cslen);
}

/* ---- scan tracking ------------------------------------------------------ */

static void track_device(const uint8_t *addr)
{
    uint32_t t = now_sec();

    /* Update existing */
    for (int i = 0; i < s_seen_count; i++) {
        if (memcmp(s_seen[i].addr, addr, 6) == 0) {
            s_seen[i].last_seen = t;
            return;
        }
    }

    /* Add new — evict oldest if full */
    if (s_seen_count < MAX_SEEN) {
        memcpy(s_seen[s_seen_count].addr, addr, 6);
        s_seen[s_seen_count].last_seen = t;
        s_seen_count++;
    } else {
        int oldest = 0;
        for (int i = 1; i < MAX_SEEN; i++) {
            if (s_seen[i].last_seen < s_seen[oldest].last_seen) {
                oldest = i;
            }
        }
        memcpy(s_seen[oldest].addr, addr, 6);
        s_seen[oldest].last_seen = t;
    }
}

/* ---- APRS relay --------------------------------------------------------- */

static uint32_t fnv1a(const uint8_t *d, int n)
{
    uint32_t h = 2166136261u;
    for (int i = 0; i < n; i++) { h ^= d[i]; h *= 16777619u; }
    return h;
}

/* True if this content was relayed within the last RELAY_DEDUP_SEC. */
static bool relay_seen(uint32_t hash)
{
    uint32_t t = now_sec();
    int n = s_rdedup_cnt < RDEDUP_MAX ? s_rdedup_cnt : RDEDUP_MAX;
    for (int i = 0; i < n; i++) {
        if (s_rdedup[i].hash == hash && (t - s_rdedup[i].t) < RELAY_DEDUP_SEC) {
            return true;
        }
    }
    return false;
}

static void relay_remember(uint32_t hash)
{
    int idx = s_rdedup_cnt % RDEDUP_MAX;
    s_rdedup[idx].hash = hash;
    s_rdedup[idx].t = now_sec();
    s_rdedup_cnt++;
}

/* True if this message content was shown on the chat within SHOWN_DEDUP_SEC. */
static bool shown_recent(uint32_t hash)
{
    uint32_t t = now_sec();
    int n = s_shown_cnt < SHOWN_MAX ? s_shown_cnt : SHOWN_MAX;
    for (int i = 0; i < n; i++) {
        if (s_shown[i].hash == hash && (t - s_shown[i].t) < SHOWN_DEDUP_SEC) {
            return true;
        }
    }
    return false;
}

static void shown_mark(uint32_t hash)
{
    int idx = s_shown_cnt % SHOWN_MAX;
    s_shown[idx].hash = hash;
    s_shown[idx].t = now_sec();
    s_shown_cnt++;
}

/* Remember a callsign heard over BLE (uppercase, strip any "-SSID"). Updates
 * the timestamp if already known; evicts the oldest entry when full. */
static void heard_add(const char *raw, int rawlen)
{
    char call[8];
    int n = 0;
    for (int i = 0; i < rawlen && raw[i] && raw[i] != '-' && n < 7; i++) {
        char c = raw[i];
        if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
        /* APRS callsign charset only — guards against junk in manufacturer data */
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) call[n++] = c;
        else break;
    }
    call[n] = 0;
    if (n < 3) return;                 /* too short to be a real callsign */

    uint32_t t = now_sec();
    for (int i = 0; i < s_heard_cnt; i++) {
        if (strcmp(s_heard[i].call, call) == 0) { s_heard[i].t = t; return; }
    }
    int slot;
    if (s_heard_cnt < HEARD_MAX) {
        slot = s_heard_cnt++;
    } else {                           /* full — evict the oldest */
        slot = 0;
        for (int i = 1; i < HEARD_MAX; i++)
            if (s_heard[i].t < s_heard[slot].t) slot = i;
    }
    strcpy(s_heard[slot].call, call);
    s_heard[slot].t = t;
    ESP_LOGI(TAG, "heard callsign over BLE: %s (%d known)", call, s_heard_cnt);
}

/* Queue a full manufacturer-data frame for rebroadcast. */
static void relay_enqueue(const uint8_t *mfg, int len)
{
    if (len <= 0) return;
    if (len > (int)sizeof(s_relay[0].mfg)) len = sizeof(s_relay[0].mfg);
    uint32_t t = now_sec();
    int slot = -1;
    for (int i = 0; i < RELAY_MAX; i++) {
        if (s_relay[i].len == 0 || s_relay[i].expire <= t) { slot = i; break; }
    }
    if (slot < 0) {                     /* all busy — evict the soonest-to-lapse */
        slot = 0;
        for (int i = 1; i < RELAY_MAX; i++)
            if (s_relay[i].expire < s_relay[slot].expire) slot = i;
    }
    memcpy(s_relay[slot].mfg, mfg, len);
    s_relay[slot].len = (uint8_t)len;
    s_relay[slot].expire = t + RELAY_TTL_SEC;
}

/* Pick the next live frame to rebroadcast (round-robin), reaping expired
 * slots; returns its index, or -1 if nothing pending. */
static int relay_pick(void)
{
    uint32_t t = now_sec();
    for (int n = 0; n < RELAY_MAX; n++) {
        s_relay_rr = (s_relay_rr + 1) % RELAY_MAX;
        relay_slot_t *r = &s_relay[s_relay_rr];
        if (r->len == 0) continue;
        if (r->expire <= t) { r->len = 0; continue; }
        return s_relay_rr;
    }
    return -1;
}

/* ---- advertising -------------------------------------------------------- */

static void advertise_with(const uint8_t *mfg, uint8_t mfg_len)
{
    /* Stop scanning first — can't coexist with legacy adv */
    ble_gap_disc_cancel();
    s_scanning = false;

    struct ble_gap_adv_params adv_params = {0};
    adv_params.conn_mode = BLE_GAP_CONN_MODE_UND;  /* connectable for GATT */
    adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;

    /* --- Primary advertising data ---
     * Must include the FFE0 service UUID — Flutter app scans with
     * withServices:[FFE0] filter and won't see us without it. */
    ble_uuid16_t svc_uuid = BLE_UUID16_INIT(SVC_UUID);

    /* Long frame? Carry the first ADV_MFG_CAP bytes here and the overflow in
     * the SCAN_RSP continuation (active scanners reassemble it). */
    bool split = mfg_len > ADV_MFG_CAP;
    uint8_t adv_cont[CONT_HDR_LEN + CONT_PAYLOAD_CAP];
    int adv_cont_len = 0;

    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids16 = &svc_uuid;
    fields.num_uuids16 = 1;
    fields.uuids16_is_complete = 1;
    fields.mfg_data = mfg;
    fields.mfg_data_len = split ? ADV_MFG_CAP : mfg_len;

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGW(TAG, "adv_set_fields failed: %d", rc);
        return;
    }

    /* --- Scan response data ---
     * For a split frame: the marked continuation. Otherwise: the device name. */
    struct ble_hs_adv_fields rsp_fields = {0};
    if (split) {
        int overflow = mfg_len - ADV_MFG_CAP;
        if (overflow > CONT_PAYLOAD_CAP) overflow = CONT_PAYLOAD_CAP;
        adv_cont[0] = COMPANY_ID_LO;
        adv_cont[1] = COMPANY_ID_HI;
        adv_cont[2] = GEOGRAM_MARKER;
        adv_cont[3] = APRS_CONT_SUBTYPE;
        memcpy(&adv_cont[CONT_HDR_LEN], &mfg[ADV_MFG_CAP], overflow);
        adv_cont_len = CONT_HDR_LEN + overflow;
        rsp_fields.mfg_data = adv_cont;
        rsp_fields.mfg_data_len = adv_cont_len;
    } else {
        rsp_fields.name = (uint8_t *)s_callsign;
        rsp_fields.name_len = strlen(s_callsign);
        rsp_fields.name_is_complete = 1;
    }

    rc = ble_gap_adv_rsp_set_fields(&rsp_fields);
    if (rc != 0) {
        ESP_LOGW(TAG, "adv_rsp_set_fields failed: %d", rc);
    }

    rc = ble_gap_adv_start(BLE_OWN_ADDR_PUBLIC, NULL, BLE_HS_FOREVER,
                           &adv_params, ble_hello_gap_event, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) {
        ESP_LOGW(TAG, "adv_start failed: %d", rc);
    }
}

/* Advertise a pending relay frame when one is queued (so APRS messages are
 * rebroadcast promptly), otherwise our own presence beacon. */
static void start_advertise(void)
{
    int ri = relay_pick();
    if (ri >= 0) {
        ESP_LOGI(TAG, "relaying APRS frame (%u bytes)", s_relay[ri].len);
        advertise_with(s_relay[ri].mfg, s_relay[ri].len);
    } else {
        advertise_with(s_mfg_data, s_mfg_len);
    }
}

/* ---- active scanning ---------------------------------------------------- */

static void start_scan(void)
{
    /* Stop advertising first — can't coexist with legacy scan */
    ble_gap_adv_stop();
    s_scanning = true;

    struct ble_gap_disc_params params = {0};
    params.passive = 0;            /* active — request SCAN_RSP continuations */
    params.itvl = 0x0050;          /* 50 ms */
    params.window = 0x0030;        /* 30 ms */
    params.filter_duplicates = 0;  /* we do our own dedup */

    /* Scan for a limited duration, then cycle timer switches back to adv */
    int rc = ble_gap_disc(BLE_OWN_ADDR_PUBLIC, SCAN_DURATION_MS,
                          &params, ble_hello_gap_event, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) {
        ESP_LOGW(TAG, "scan start failed: %d", rc);
        /* Fall back to advertising */
        start_advertise();
    }
}

/* ---- adv/scan cycle timer ----------------------------------------------- */

static void cycle_timer_cb(void *arg)
{
    (void)arg;
    if (!s_active) return;

    /* NimBLE can scan while a connection is active (just not while
     * advertising).  Always cycle so device count stays fresh. */
    if (!s_scanning) {
        /* Was advertising (or connected) → brief scan window */
        start_scan();
    } else {
        /* Was scanning → resume advertising (unless connected) */
        if (!s_conn_active) {
            start_advertise();
        } else {
            s_scanning = false;  /* just stop scanning, stay connected */
            ble_gap_disc_cancel();
        }
    }
}

/* ---- GATT: hello_ack builder -------------------------------------------- */

static void send_hello_ack(uint16_t conn)
{
    cJSON *root = cJSON_CreateObject();
    cJSON_AddNumberToObject(root, "v", 1);
    cJSON_AddStringToObject(root, "type", "hello_ack");

    cJSON *payload = cJSON_AddObjectToObject(root, "payload");
    cJSON_AddBoolToObject(payload, "success", 1);
    cJSON_AddStringToObject(payload, "callsign", s_callsign);
    cJSON *caps = cJSON_AddArrayToObject(payload, "capabilities");
    cJSON_AddItemToArray(caps, cJSON_CreateString("hello"));
    cJSON_AddStringToObject(payload, "platform", "esp32");

    char *json = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);

    if (!json) return;

    struct os_mbuf *om = ble_hs_mbuf_from_flat(json, strlen(json));
    if (om) {
        int rc = ble_gatts_notify_custom(conn, s_notify_handle, om);
        if (rc != 0) {
            ESP_LOGW(TAG, "notify failed: %d", rc);
        } else {
            ESP_LOGI(TAG, "HELLO_ACK sent to conn %d", conn);
        }
    }
    free(json);
}

/* ---- BLE parcel transport over GATT (FFF1 write in, FFF2 notify out) ----- */

/* Notify a "complete" receipt for [msg_id] to the connected client. */
static void gatt_send_receipt(uint16_t conn, const char *msg_id)
{
    uint8_t r[48];
    int n = ble_parcel_build_receipt(msg_id, r, sizeof r);
    if (n <= 0) return;
    struct os_mbuf *om = ble_hs_mbuf_from_flat(r, n);
    if (om) ble_gatts_notify_custom(conn, s_notify_handle, om);
}

/* Send [payload] (a compact `<from>\x1f<to>\x1f<text>` frame) as a single
 * parcel to the connected GATT client (the desktop). */
static void gatt_send_parcel(uint16_t conn, const uint8_t *payload, int len)
{
    if (len <= 0 || len > BLE_PARCEL_HDR_CAP) return;
    uint8_t buf[BLE_PARCEL_HDR_OVH + BLE_PARCEL_HDR_CAP];
    char id[3];
    ble_parcel_gen_id(id, (uint32_t)esp_timer_get_time());
    int n = ble_parcel_build_header(id, payload, len, buf, sizeof buf);
    if (n <= 0) return;
    struct os_mbuf *om = ble_hs_mbuf_from_flat(buf, n);
    if (om) ble_gatts_notify_custom(conn, s_notify_handle, om);
}

/* True when a central (the desktop) is connected to our GATT server. */
static bool gatt_client_connected(void) { return s_conn_active; }

/* ---- GATT callbacks ----------------------------------------------------- */

static int gatt_write_cb(uint16_t conn_handle, uint16_t attr_handle,
                         struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)attr_handle;
    (void)arg;

    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return 0;

    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len == 0 || len > 512) return 0;

    uint8_t buf[513];
    uint16_t copied = 0;
    ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof(buf) - 1, &copied);
    buf[copied] = '\0';

    /* JSON ('{') is either a HELLO handshake or a parcel receipt; anything else
     * is a BLE parcel carrying a text frame. */
    if (buf[0] == '{') {
        if (ble_parcel_is_receipt(buf, copied)) {
            return 0;   /* ack of one of our notifies — nothing to do */
        }
        cJSON *root = cJSON_Parse((char *)buf);
        if (root) {
            cJSON *type = cJSON_GetObjectItem(root, "type");
            if (type && cJSON_IsString(type) &&
                strcmp(type->valuestring, "hello") == 0) {
                ESP_LOGI(TAG, "HELLO received on conn %d", conn_handle);
                send_hello_ack(conn_handle);
            }
            cJSON_Delete(root);
        }
        return 0;
    }

    /* BLE parcel (geogram parcel protocol). Chat frames are a single parcel. */
    ble_parcel_hdr_t p;
    if (ble_parcel_parse_header(buf, copied, &p)) {
        if (p.total == 1) {
            if (ble_parcel_crc32(p.data, p.data_len) == p.crc) {
                ESP_LOGI(TAG, "GATT parcel rx: msg %s (%d B)", p.msg_id, p.data_len);
                aprs_decode(p.data, p.data_len, 0);     /* deliver as a received frame */
                gatt_send_receipt(conn_handle, p.msg_id);
            } else {
                ESP_LOGW(TAG, "GATT parcel CRC mismatch (msg %s)", p.msg_id);
            }
        } else {
            ESP_LOGW(TAG, "GATT multi-parcel not supported yet (total=%d)", p.total);
        }
    }
    return 0;
}

static int gatt_notify_cb(uint16_t conn_handle, uint16_t attr_handle,
                          struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)ctxt;
    (void)arg;
    return 0;
}

/* GATT service definition */
static const struct ble_gatt_svc_def s_gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = BLE_UUID16_DECLARE(SVC_UUID),
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                /* Write characteristic — client sends HELLO */
                .uuid = BLE_UUID16_DECLARE(CHR_WRITE_UUID),
                .access_cb = gatt_write_cb,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
            },
            {
                /* Notify characteristic — server sends HELLO_ACK */
                .uuid = BLE_UUID16_DECLARE(CHR_NOTIFY_UUID),
                .access_cb = gatt_notify_cb,
                .val_handle = &s_notify_handle,
                .flags = BLE_GATT_CHR_F_NOTIFY,
            },
            { 0 }, /* sentinel */
        },
    },
    { 0 }, /* sentinel */
};

/* ---- Aurora APRS-over-BLE decode ---------------------------------------- */

void ble_hello_set_aprs_cb(ble_hello_aprs_cb_t cb)
{
    s_aprs_cb = cb;
}

int ble_hello_get_heard(char calls[][8], int max, uint32_t max_age_sec)
{
    uint32_t t = now_sec();
    int n = 0;
    for (int i = 0; i < s_heard_cnt && n < max; i++) {
        if (max_age_sec == 0 || (t - s_heard[i].t) <= max_age_sec) {
            strncpy(calls[n], s_heard[i].call, 7);
            calls[n][7] = 0;
            n++;
        }
    }
    return n;
}

bool ble_hello_relay_aprs(const char *from, const char *to, const char *text)
{
    if (!s_active || !from || !to || !text) return false;

    /* Connected desktop? Send the FULL frame reliably over GATT as a parcel
     * (no advert size limit). The advertising path below still serves
     * ESP32<->ESP32 peers (and is truncated to fit a legacy advert). */
    if (gatt_client_connected()) {
        uint8_t full[BLE_PARCEL_HDR_CAP];
        int fn = 0;
        for (const char *p = from; *p && fn < (int)sizeof(full); p++) full[fn++] = (uint8_t)*p;
        if (fn < (int)sizeof(full)) full[fn++] = 0x1F;
        for (const char *p = to; *p && fn < (int)sizeof(full); p++) full[fn++] = (uint8_t)*p;
        if (fn < (int)sizeof(full)) full[fn++] = 0x1F;
        for (const char *p = text; *p && fn < (int)sizeof(full); p++) full[fn++] = (uint8_t)*p;
        gatt_send_parcel(s_conn_handle, full, fn);
    }

    /* Build compact manufacturer data: [0xFF,0xFF,<from>\x1f<to>\x1f<text>].
     * Up to APRS_MFG_MAX bytes: the primary legacy advert holds the first
     * ADV_MFG_CAP and the rest rides the SCAN_RSP continuation (see
     * advertise_with). Longer-than-that text is truncated to fit. */
    uint8_t mfg[APRS_MFG_MAX];
    int n = 0;
    mfg[n++] = COMPANY_ID_LO;
    mfg[n++] = COMPANY_ID_HI;
    for (const char *p = from; *p && n < (int)sizeof(mfg); p++) mfg[n++] = (uint8_t)*p;
    if (n < (int)sizeof(mfg)) mfg[n++] = 0x1F;
    for (const char *p = to; *p && n < (int)sizeof(mfg); p++) mfg[n++] = (uint8_t)*p;
    if (n < (int)sizeof(mfg)) mfg[n++] = 0x1F;
    bool truncated = false;
    for (const char *p = text; *p; p++) {
        if (n >= (int)sizeof(mfg)) { truncated = true; break; }
        mfg[n++] = (uint8_t)*p;
    }
    if (n <= 4) return false;          /* nothing but headers fit */

    /* Content dedup against the shared mesh/display caches so a message gated
     * repeatedly by APRS-IS is only put on air once, and our own re-scan of it
     * neither re-relays nor re-displays it. */
    uint32_t ch = fnv1a(&mfg[2], n - 2);
    if (relay_seen(ch)) return false;
    relay_remember(ch);
    shown_mark(ch);

    relay_enqueue(mfg, n);
    ESP_LOGI(TAG, "iGate relay -> BLE: %s -> %s (%d B%s)",
             from, to[0] ? to : "(geo)", n, truncated ? ", truncated" : "");
    return true;
}

/* Decode a compact Aurora APRS payload `<from>\x1f<to>\x1f<text>` (the bytes
 * after the 2-byte company id) and deliver it via the registered callback.
 * Untrusted input — everything is bounds-checked and NUL-terminated. */
static void aprs_decode(const uint8_t *payload, int len, int rssi)
{
    if (!s_aprs_cb || len <= 0) return;

    /* Field buffers: text is large enough for a full GATT parcel frame, not
     * just a legacy advert. */
    char from[16] = {0}, to[16] = {0}, text[240] = {0};
    char *fields[3] = { from, to, text };
    size_t caps[3]  = { sizeof from - 1, sizeof to - 1, sizeof text - 1 };

    int fi = 0;     /* current field */
    size_t fp = 0;  /* write pos in current field */
    bool saw_sep = false;
    for (int i = 0; i < len; i++) {
        uint8_t b = payload[i];
        if (b == 0x1F) {            /* field separator */
            saw_sep = true;
            if (fi < 2) { fi++; fp = 0; }
            continue;               /* extra separators fold into text once fi==2 */
        }
        if (fp < caps[fi]) fields[fi][fp++] = (char)b;
    }
    if (!saw_sep) return;           /* not an Aurora APRS frame */

    /* Remember the sender so the iGate can filter APRS-IS for traffic to it. */
    heard_add(from, (int)strlen(from));

    /* Display dedup: deliver the same message content to the chat only once per
     * SHOWN_DEDUP_SEC (60 min). One broadcast is received dozens of times and
     * is also relayed by the mesh, so without this the line repeats. */
    uint32_t ch = fnv1a(payload, len);
    if (shown_recent(ch)) return;
    shown_mark(ch);

    s_aprs_cb(from, to, text, rssi);
}

/* Deliver one fully-assembled compact APRS frame: show it (deduped) and
 * rebroadcast it once for the mesh repeater. [mfg] = [0xFF,0xFF,payload…]. */
static void process_aprs_frame(const uint8_t *mfg, int len, int rssi)
{
    if (len < 4) return;
    aprs_decode(&mfg[2], len - 2, rssi);
    uint32_t ch = fnv1a(&mfg[2], len - 2);
    if (!relay_seen(ch)) {
        relay_remember(ch);
        relay_enqueue(mfg, len);
    }
}

/* A held primary advert turned out to have no SCAN_RSP continuation — deliver
 * it as a (short) frame. */
static void flush_pending(void)
{
    if (!s_pending.active) return;
    s_pending.active = false;
    process_aprs_frame(s_pending.mfg, s_pending.len, s_pending.rssi);
}

/* ---- GAP event handler -------------------------------------------------- */

static int ble_hello_gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;

    switch (event->type) {

    case BLE_GAP_EVENT_DISC: {
        struct ble_hs_adv_fields fields;
        if (ble_hs_adv_parse_fields(&fields, event->disc.data,
                                     event->disc.length_data) != 0) {
            break;
        }
        const uint8_t *mfg = fields.mfg_data;
        int mlen = fields.mfg_data_len;
        if (!mfg || mlen < 3 || mfg[0] != COMPANY_ID_LO || mfg[1] != COMPANY_ID_HI) {
            break;
        }
        const uint8_t *addr = event->disc.addr.val;
        bool is_rsp = (event->disc.event_type == BLE_HCI_ADV_RPT_EVTYPE_SCAN_RSP);

        /* SCAN_RSP continuation of a long compact frame: reassemble it onto the
         * pending primary from the same advertiser. */
        if (mlen >= CONT_HDR_LEN && mfg[2] == GEOGRAM_MARKER &&
            mfg[3] == APRS_CONT_SUBTYPE && is_rsp) {
            if (s_pending.active && memcmp(s_pending.addr, addr, 6) == 0) {
                int overflow = mlen - CONT_HDR_LEN;
                if (overflow > APRS_MFG_MAX - s_pending.len)
                    overflow = APRS_MFG_MAX - s_pending.len;
                if (overflow > 0) {
                    memcpy(&s_pending.mfg[s_pending.len], &mfg[CONT_HDR_LEN], overflow);
                    s_pending.len += overflow;
                }
                s_pending.active = false;
                process_aprs_frame(s_pending.mfg, s_pending.len, event->disc.rssi);
            }
            break;
        }

        /* Any other event means the held primary (if any) had no continuation. */
        flush_pending();

        if (mfg[2] == GEOGRAM_MARKER) {
            /* Geogram presence beacon: [company,marker,device_id,callsign…] */
            track_device(addr);
            if (mlen > 4) heard_add((const char *)&mfg[4], mlen - 4);
        } else if (mlen >= 4) {
            /* Compact Aurora APRS frame (no marker). Hold it until the next
             * scan event reveals whether a SCAN_RSP continuation follows. */
            track_device(addr);
            int n = mlen > APRS_MFG_MAX ? APRS_MFG_MAX : mlen;
            memcpy(s_pending.addr, addr, 6);
            memcpy(s_pending.mfg, mfg, n);
            s_pending.len = n;
            s_pending.rssi = event->disc.rssi;
            s_pending.active = true;
        }
        break;
    }

    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            s_conn_handle = event->connect.conn_handle;
            s_conn_active = true;
            ESP_LOGI(TAG, "connected — conn_handle=%d", s_conn_handle);
        } else {
            /* Connection failed — restart advertising */
            start_advertise();
        }
        break;

    case BLE_GAP_EVENT_DISCONNECT:
        s_conn_active = false;
        ESP_LOGI(TAG, "disconnected — reason=%d", event->disconnect.reason);
        start_advertise();
        break;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        /* Advertising ended (e.g. duration expired) — restart if active */
        if (s_active && !s_scanning) {
            start_advertise();
        }
        break;

    case BLE_GAP_EVENT_DISC_COMPLETE:
        /* Scan window finished — deliver any held primary (no continuation
         * arrived) and resume advertising if not connected. */
        flush_pending();
        s_scanning = false;
        if (s_active && !s_conn_active) {
            start_advertise();
        }
        break;

    default:
        break;
    }

    return 0;
}

/* ---- NimBLE host task + sync -------------------------------------------- */

static void on_sync(void)
{
    /* Use default public address */
    int rc = ble_hs_util_ensure_addr(0);
    if (rc != 0) {
        ESP_LOGE(TAG, "ensure_addr failed: %d", rc);
        return;
    }

    /* Prefer a large ATT MTU so a whole parcel rides one write/notify. */
    ble_att_set_preferred_mtu(512);

    ESP_LOGI(TAG, "BLE host synced — starting advertising");
    start_advertise();

    /* Start the adv/scan cycle timer — fires every ADV_DURATION_SEC to
     * briefly scan, then DISC_COMPLETE switches back to advertising. */
    if (s_cycle_timer) {
        esp_timer_start_periodic(s_cycle_timer, ADV_DURATION_SEC * 1000000ULL);
    }
}

static void on_reset(int reason)
{
    ESP_LOGW(TAG, "BLE host reset — reason=%d", reason);
}

static void nimble_host_task(void *param)
{
    (void)param;
    nimble_port_run();          /* blocks until nimble_port_stop() */
    nimble_port_freertos_deinit();
}

/* ---- public API --------------------------------------------------------- */

esp_err_t ble_hello_init(const char *callsign)
{
    if (s_active) return ESP_ERR_INVALID_STATE;
    if (!callsign || strlen(callsign) == 0) return ESP_ERR_INVALID_ARG;

    strncpy(s_callsign, callsign, sizeof(s_callsign) - 1);
    s_callsign[sizeof(s_callsign) - 1] = '\0';
    s_device_id = compute_device_id();
    build_mfg_data();

    memset(s_seen, 0, sizeof(s_seen));
    s_seen_count = 0;
    s_conn_active = false;
    s_scanning = false;

    /* Create adv/scan cycle timer */
    esp_timer_create_args_t timer_args = {
        .callback = cycle_timer_cb,
        .name = "ble_hello_cycle",
    };
    esp_err_t err = esp_timer_create(&timer_args, &s_cycle_timer);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "cycle timer create failed: %s", esp_err_to_name(err));
        s_cycle_timer = NULL;
    }

    /* NimBLE init */
    int rc = nimble_port_init();
    if (rc != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init failed: %d", rc);
        return ESP_FAIL;
    }

    /* Host callbacks */
    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.sync_cb = on_sync;

    /* GAP device name */
    ble_svc_gap_device_name_set(s_callsign);

    /* GATT init */
    ble_svc_gap_init();
    ble_svc_gatt_init();

    rc = ble_gatts_count_cfg(s_gatt_svcs);
    if (rc != 0) {
        ESP_LOGE(TAG, "gatts_count_cfg failed: %d", rc);
        return ESP_FAIL;
    }
    rc = ble_gatts_add_svcs(s_gatt_svcs);
    if (rc != 0) {
        ESP_LOGE(TAG, "gatts_add_svcs failed: %d", rc);
        return ESP_FAIL;
    }

    /* Start host task */
    nimble_port_freertos_init(nimble_host_task);

    s_active = true;
    ESP_LOGI(TAG, "BLE HELLO active — callsign: %s, device_id: %d", s_callsign, s_device_id);
    return ESP_OK;
}

void ble_hello_stop(void)
{
    if (!s_active) return;
    s_active = false;
    if (s_cycle_timer) {
        esp_timer_stop(s_cycle_timer);
        esp_timer_delete(s_cycle_timer);
        s_cycle_timer = NULL;
    }
    ble_gap_adv_stop();
    ble_gap_disc_cancel();
    nimble_port_stop();
    ESP_LOGI(TAG, "BLE HELLO stopped");
}

int ble_hello_device_count(void)
{
    uint32_t t = now_sec();
    int count = 0;
    for (int i = 0; i < s_seen_count; i++) {
        if ((t - s_seen[i].last_seen) <= EXPIRE_SEC) {
            count++;
        }
    }
    return count;
}

bool ble_hello_is_active(void)
{
    return s_active;
}
