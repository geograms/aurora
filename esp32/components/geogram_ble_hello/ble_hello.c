/**
 * @file ble_hello.c
 * @brief Standalone BLE HELLO protocol — advertising, scanning, GATT.
 */

#include "ble_hello.h"

#include <string.h>
#include <stdio.h>

#include "esp_log.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "nvs_flash.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
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
    uint8_t  mfg[31];                   /* full manufacturer data to rebroadcast */
    uint8_t  len;                       /* 0 = empty slot */
    uint32_t expire;                    /* seconds-since-boot when it lapses */
} relay_slot_t;
static relay_slot_t s_relay[RELAY_MAX];
static int          s_relay_rr;         /* round-robin advertise cursor */

typedef struct { uint32_t hash; uint32_t t; } rdedup_t;
static rdedup_t s_rdedup[RDEDUP_MAX];
static int      s_rdedup_cnt;

/* GATT */
static uint16_t s_notify_handle;
static uint16_t s_conn_handle;
static bool     s_conn_active;

/* Time-sharing state */
static esp_timer_handle_t s_cycle_timer;
static bool     s_scanning;             /* true = scan phase, false = adv phase */

/* ---- helpers ------------------------------------------------------------ */

/* Forward declaration */
static int ble_hello_gap_event(struct ble_gap_event *event, void *arg);

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

    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids16 = &svc_uuid;
    fields.num_uuids16 = 1;
    fields.uuids16_is_complete = 1;
    fields.mfg_data = mfg;
    fields.mfg_data_len = mfg_len;

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGW(TAG, "adv_set_fields failed: %d", rc);
        return;
    }

    /* --- Scan response data ---
     * Put the device name here to save primary adv space. */
    struct ble_hs_adv_fields rsp_fields = {0};
    rsp_fields.name = (uint8_t *)s_callsign;
    rsp_fields.name_len = strlen(s_callsign);
    rsp_fields.name_is_complete = 1;

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

/* ---- passive scanning --------------------------------------------------- */

static void start_scan(void)
{
    /* Stop advertising first — can't coexist with legacy scan */
    ble_gap_adv_stop();
    s_scanning = true;

    struct ble_gap_disc_params params = {0};
    params.passive = 1;
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

/* ---- GATT callbacks ----------------------------------------------------- */

static int gatt_write_cb(uint16_t conn_handle, uint16_t attr_handle,
                         struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)attr_handle;
    (void)arg;

    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return 0;

    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len == 0 || len > 512) return 0;

    char buf[513];
    uint16_t copied = 0;
    ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof(buf) - 1, &copied);
    buf[copied] = '\0';

    cJSON *root = cJSON_Parse(buf);
    if (!root) return 0;

    cJSON *type = cJSON_GetObjectItem(root, "type");
    if (type && cJSON_IsString(type) && strcmp(type->valuestring, "hello") == 0) {
        ESP_LOGI(TAG, "HELLO received on conn %d", conn_handle);
        send_hello_ack(conn_handle);
    }
    cJSON_Delete(root);
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

/* Decode a compact Aurora APRS payload `<from>\x1f<to>\x1f<text>` (the bytes
 * after the 2-byte company id) and deliver it via the registered callback.
 * Untrusted input — everything is bounds-checked and NUL-terminated. */
static void aprs_decode(const uint8_t *payload, int len, int rssi)
{
    if (!s_aprs_cb || len <= 0) return;

    /* Field buffers sized for a legacy advert (payload <= ~29 bytes). */
    char from[16] = {0}, to[16] = {0}, text[64] = {0};
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

    s_aprs_cb(from, to, text, rssi);
}

/* ---- GAP event handler -------------------------------------------------- */

static int ble_hello_gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;

    switch (event->type) {

    case BLE_GAP_EVENT_DISC: {
        /* Check manufacturer data for Geogram marker */
        struct ble_hs_adv_fields fields;
        if (ble_hs_adv_parse_fields(&fields, event->disc.data,
                                     event->disc.length_data) != 0) {
            break;
        }
        if (fields.mfg_data && fields.mfg_data_len >= 3 &&
            fields.mfg_data[0] == COMPANY_ID_LO &&
            fields.mfg_data[1] == COMPANY_ID_HI) {
            if (fields.mfg_data[2] == GEOGRAM_MARKER) {
                /* Geogram presence beacon */
                track_device(event->disc.addr.val);
            } else if (fields.mfg_data_len >= 4) {
                /* No 0x3E marker — treat as an Aurora APRS frame. */
                track_device(event->disc.addr.val);
                aprs_decode(&fields.mfg_data[2], fields.mfg_data_len - 2,
                            event->disc.rssi);
                /* Mesh repeater: rebroadcast new content once per 10 min. */
                uint32_t ch = fnv1a(&fields.mfg_data[2],
                                    fields.mfg_data_len - 2);
                if (!relay_seen(ch)) {
                    relay_remember(ch);
                    relay_enqueue(fields.mfg_data, fields.mfg_data_len);
                }
            }
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
        /* Scan window finished — resume advertising if not connected */
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
