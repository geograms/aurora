/**
 * @file ble_hello.c
 * @brief Standalone BLE HELLO protocol — advertising, scanning, GATT.
 */

#include "ble_hello.h"
#include "ble_parcel.h"
#include "msgstore.h"

#include <string.h>
#include <stdio.h>
#include <stdlib.h>

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

/* Broadcast-parcel chunking (the <=300B connectionless transport). A message is
 * split into chunks; each chunk = a primary advert (subtype 0x50) + an optional
 * scan-response continuation (subtype 0x51), grouped by a 1-byte msg id with a
 * chunk index/total so every scanner in range reassembles it. See
 * lib/connections/bluetooth/ble_reassembler.dart (BleBroadcastReassembler) for
 * the matching receiver. */
#define BCAST_PRIMARY       0x50        /* 'P' — chunk primary (ADV) */
#define BCAST_CONT          0x51        /* 'Q' — chunk continuation (SCAN_RSP) */
#define BCH_PRI_HDR         6           /* marker,subtype,msgid,idx,total,flags (after company id) */
#define BCH_ADV_PAYLOAD     (ADV_MFG_CAP - 2 - BCH_PRI_HDR)  /* 12 */
#define BCH_CONT_HDR        4           /* marker,subtype,msgid,idx (after company id) */
#define BCH_CONT_PAYLOAD    22          /* continuation payload bytes per chunk */
#define BCH_CHUNK_PAYLOAD   (BCH_ADV_PAYLOAD + BCH_CONT_PAYLOAD)  /* 34 */
#define BCAST_MAX           300         /* size router threshold: <= here = broadcast */
#define BCH_RING            16          /* chunks queued for broadcast at once */
#define BRX_SLOTS           4           /* concurrent (addr,msgid) reassemblies */
#define BRX_MAX_CHUNKS      16          /* max chunks per reassembled message */
#define BRX_WINDOW_SEC      4           /* drop a partial with no new chunk this long */

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

/* ---- broadcast-parcel chunk ring ---------------------------------------- */

typedef struct {
    uint8_t  adv[2 + BCH_PRI_HDR + BCH_ADV_PAYLOAD];   /* primary mfg (0x50) */
    uint8_t  adv_len;
    uint8_t  rsp[2 + BCH_CONT_HDR + BCH_CONT_PAYLOAD]; /* continuation mfg (0x51), 0 = none */
    uint8_t  rsp_len;
    uint32_t expire;                                   /* 0 = empty slot */
} bch_slot_t;
static bch_slot_t s_bch[BCH_RING];
static int        s_bch_rr;
static uint8_t    s_tx_msgid;

/* Split [payload] (<=BCAST_MAX) into broadcast-parcel chunks and queue them for
 * rebroadcast. One msg id groups the chunks; each chunk carries idx/total so
 * any scanner reassembles. Chunks air via the rotation for BCH TTL. */
static void relay_enqueue_broadcast(const uint8_t *payload, int len)
{
    if (len <= 0) return;
    if (len > BCAST_MAX) len = BCAST_MAX;
    uint8_t msgid = ++s_tx_msgid;
    int total = (len + BCH_CHUNK_PAYLOAD - 1) / BCH_CHUNK_PAYLOAD;
    if (total < 1) total = 1;
    if (total > 255) total = 255;
    uint32_t t = now_sec();
    int off = 0;
    for (int idx = 0; idx < total; idx++) {
        int chunk = len - off; if (chunk > BCH_CHUNK_PAYLOAD) chunk = BCH_CHUNK_PAYLOAD;
        int padv = chunk > BCH_ADV_PAYLOAD ? BCH_ADV_PAYLOAD : chunk;
        int pcont = chunk - padv;   /* >0 → this chunk has a continuation */

        /* find a free/expired slot (evict soonest-to-lapse if all busy) */
        int slot = -1;
        for (int i = 0; i < BCH_RING; i++)
            if (s_bch[i].expire == 0 || s_bch[i].expire <= t) { slot = i; break; }
        if (slot < 0) {
            slot = 0;
            for (int i = 1; i < BCH_RING; i++)
                if (s_bch[i].expire < s_bch[slot].expire) slot = i;
        }
        bch_slot_t *s = &s_bch[slot];

        int a = 0;
        s->adv[a++] = COMPANY_ID_LO; s->adv[a++] = COMPANY_ID_HI;
        s->adv[a++] = GEOGRAM_MARKER; s->adv[a++] = BCAST_PRIMARY;
        s->adv[a++] = msgid; s->adv[a++] = (uint8_t)idx; s->adv[a++] = (uint8_t)total;
        s->adv[a++] = pcont > 0 ? 0x01 : 0x00;   /* flags: bit0 = has continuation */
        memcpy(&s->adv[a], &payload[off], padv); a += padv;
        s->adv_len = (uint8_t)a;

        if (pcont > 0) {
            int c = 0;
            s->rsp[c++] = COMPANY_ID_LO; s->rsp[c++] = COMPANY_ID_HI;
            s->rsp[c++] = GEOGRAM_MARKER; s->rsp[c++] = BCAST_CONT;
            s->rsp[c++] = msgid; s->rsp[c++] = (uint8_t)idx;
            memcpy(&s->rsp[c], &payload[off + padv], pcont); c += pcont;
            s->rsp_len = (uint8_t)c;
        } else {
            s->rsp_len = 0;
        }
        s->expire = t + RELAY_TTL_SEC;
        off += chunk;
    }
    ESP_LOGI(TAG, "broadcast msg %u: %d bytes in %d chunk(s)", msgid, len, total);
}

/* Pick the next live broadcast chunk (round-robin), reaping expired slots;
 * returns its index, or -1 if none pending. */
static int bch_pick(void)
{
    uint32_t t = now_sec();
    for (int n = 0; n < BCH_RING; n++) {
        s_bch_rr = (s_bch_rr + 1) % BCH_RING;
        bch_slot_t *s = &s_bch[s_bch_rr];
        if (s->expire == 0) continue;
        if (s->expire <= t) { s->expire = 0; continue; }
        return s_bch_rr;
    }
    return -1;
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

/* Core: advertise [adv_mfg] as the primary manufacturer data and either a
 * scan-response manufacturer data [rsp_mfg] (when rsp_len>0) or the device name.
 * Always includes the FFE0 service UUID so the Flutter app's filtered scan
 * (withServices:[FFE0]) sees us. */
static void do_advertise(const uint8_t *adv_mfg, int adv_len,
                         const uint8_t *rsp_mfg, int rsp_len)
{
    ble_gap_disc_cancel();   /* can't scan + advertise on legacy */
    s_scanning = false;

    struct ble_gap_adv_params adv_params = {0};
    adv_params.conn_mode = BLE_GAP_CONN_MODE_UND;  /* connectable for GATT */
    adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;

    ble_uuid16_t svc_uuid = BLE_UUID16_INIT(SVC_UUID);
    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids16 = &svc_uuid;
    fields.num_uuids16 = 1;
    fields.uuids16_is_complete = 1;
    fields.mfg_data = adv_mfg;
    fields.mfg_data_len = adv_len;

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGW(TAG, "adv_set_fields failed: %d", rc);
        return;
    }

    struct ble_hs_adv_fields rsp_fields = {0};
    if (rsp_mfg && rsp_len > 0) {
        rsp_fields.mfg_data = rsp_mfg;
        rsp_fields.mfg_data_len = rsp_len;
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

/* Legacy single-frame advertise (compact frame, optional 0x42 SCAN_RSP split). */
static void advertise_with(const uint8_t *mfg, uint8_t mfg_len)
{
    bool split = mfg_len > ADV_MFG_CAP;
    if (!split) { do_advertise(mfg, mfg_len, NULL, 0); return; }
    uint8_t cont[CONT_HDR_LEN + CONT_PAYLOAD_CAP];
    int overflow = mfg_len - ADV_MFG_CAP;
    if (overflow > CONT_PAYLOAD_CAP) overflow = CONT_PAYLOAD_CAP;
    cont[0] = COMPANY_ID_LO; cont[1] = COMPANY_ID_HI;
    cont[2] = GEOGRAM_MARKER; cont[3] = APRS_CONT_SUBTYPE;
    memcpy(&cont[CONT_HDR_LEN], &mfg[ADV_MFG_CAP], overflow);
    do_advertise(mfg, ADV_MFG_CAP, cont, CONT_HDR_LEN + overflow);
}

/* Advertise one broadcast-parcel chunk: primary (0x50) in ADV + optional
 * continuation (0x51) in SCAN_RSP. */
static void advertise_chunk(const uint8_t *adv, int adv_len,
                            const uint8_t *rsp, int rsp_len)
{
    do_advertise(adv, adv_len, rsp_len > 0 ? rsp : NULL, rsp_len);
}

/* Advertise a pending relay frame when one is queued (so APRS messages are
 * rebroadcast promptly), otherwise our own presence beacon. */
static void start_advertise(void)
{
    int bi = bch_pick();
    if (bi >= 0) {
        advertise_chunk(s_bch[bi].adv, s_bch[bi].adv_len,
                        s_bch[bi].rsp, s_bch[bi].rsp_len);
        return;
    }
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
    params.window = 0x0030;        /* 30 ms (60% duty): leave radio gaps so the
                                    * WiFi STA can complete its WPA2 handshake and
                                    * DHCP. A continuous (window==itvl) scan choked
                                    * WiFi (reason 15/202 handshake/DHCP timeouts). */
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

/* ---- APRS message-store query over GATT (cursor-paged) ----------------- */

static const char *ms_kind_name(uint8_t k)
{
    switch (k) {
    case MSGSTORE_KIND_POSITION: return "position";
    case MSGSTORE_KIND_MESSAGE:  return "message";
    case MSGSTORE_KIND_GROUP:    return "group";
    case MSGSTORE_KIND_GEOCHAT:  return "geochat";
    default:                     return "other";
    }
}

/* Append a JSON-escaped string; false if it would overflow [buf]. */
static bool ms_json_esc(char *buf, size_t size, size_t *len, const char *s)
{
    size_t n = *len;
    for (; s && *s; s++) {
        char e[8]; int el;
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { e[0] = '\\'; e[1] = (char)c; el = 2; }
        else if (c == '\n') { e[0] = '\\'; e[1] = 'n'; el = 2; }
        else if (c == '\r') { e[0] = '\\'; e[1] = 'r'; el = 2; }
        else if (c == '\t') { e[0] = '\\'; e[1] = 't'; el = 2; }
        else if (c < 0x20) { el = snprintf(e, sizeof e, "\\u%04x", c); }
        else { e[0] = (char)c; el = 1; }
        if (n + (size_t)el + 1 >= size) return false;
        memcpy(buf + n, e, el); n += el;
    }
    buf[n] = 0; *len = n;
    return true;
}

typedef struct {
    char *buf; size_t size; size_t len;
    bool first; bool full; uint32_t last; char epoch;
} ms_page_ctx_t;

/* Emit one record as a compact object {"i","f","t","x","k"}; stop if it would
 * overflow the page (leaving room for the trailer). */
static bool ms_page_emit(const msgstore_query_rec_t *r, void *vctx)
{
    ms_page_ctx_t *c = (ms_page_ctx_t *)vctx;
    char obj[256];
    size_t ol = 0;
    int n;

    n = snprintf(obj, sizeof obj, "%s{\"i\":\"%c%u\",\"f\":\"",
                 c->first ? "" : ",", c->epoch, (unsigned)r->index);
    if (n < 0 || n >= (int)sizeof obj) return false;
    ol = (size_t)n;
    if (!ms_json_esc(obj, sizeof obj, &ol, r->from)) return false;

    n = snprintf(obj + ol, sizeof obj - ol, "\",\"t\":\"");
    if (n < 0) return false;
    ol += (size_t)n;
    if (!ms_json_esc(obj, sizeof obj, &ol, r->to)) return false;

    n = snprintf(obj + ol, sizeof obj - ol, "\",\"x\":\"");
    if (n < 0) return false;
    ol += (size_t)n;
    if (!ms_json_esc(obj, sizeof obj, &ol, r->text)) return false;

    n = snprintf(obj + ol, sizeof obj - ol, "\",\"k\":\"%s\"}", ms_kind_name(r->kind));
    if (n < 0 || ol + (size_t)n >= sizeof obj) return false;
    ol += (size_t)n;

    if (c->len + ol + 48 >= c->size) { c->full = true; return false; }  /* keep trailer room */
    memcpy(c->buf + c->len, obj, ol);
    c->len += ol;
    c->buf[c->len] = 0;
    c->first = false;
    c->last = r->index;
    return true;
}

/* Parse an "epoch+index" id like "K1042" (or plain "1042"). */
static uint32_t ms_parse_since(const char *s, char *out_epoch)
{
    *out_epoch = 0;
    if (!s || !s[0]) return 0;
    if ((s[0] >= 'A' && s[0] <= 'Z') || (s[0] >= 'a' && s[0] <= 'z')) {
        char e = s[0]; if (e >= 'a') e = (char)(e - 32);
        *out_epoch = e; s++;
    }
    return (uint32_t)strtoul(s, NULL, 10);
}

static int ms_kind_from_str(const char *s)
{
    if (!s) return -1;
    if (!strcmp(s, "message"))  return MSGSTORE_KIND_MESSAGE;
    if (!strcmp(s, "position")) return MSGSTORE_KIND_POSITION;
    if (!strcmp(s, "group"))    return MSGSTORE_KIND_GROUP;
    if (!strcmp(s, "geochat"))  return MSGSTORE_KIND_GEOCHAT;
    if (!strcmp(s, "other"))    return MSGSTORE_KIND_OTHER;
    return -1;
}

/* Handle {"type":"aprs_query","since":..,"call":..,"kind":..,"limit":..} by
 * notifying one cursor-paged {"type":"aprs_page",...} on FFF2. The client
 * re-queries with since=next until more==false. */
static void handle_aprs_query(uint16_t conn, cJSON *root)
{
    uint32_t since = 0; char want_epoch = 0;
    char call[16] = {0}; int kind = -1; uint32_t limit = 0;
    cJSON *j;
    if ((j = cJSON_GetObjectItem(root, "since"))) {
        if (cJSON_IsString(j)) since = ms_parse_since(j->valuestring, &want_epoch);
        else if (cJSON_IsNumber(j)) since = (uint32_t)j->valuedouble;
    }
    if ((j = cJSON_GetObjectItem(root, "call")) && cJSON_IsString(j))
        strlcpy(call, j->valuestring, sizeof call);
    if ((j = cJSON_GetObjectItem(root, "kind")) && cJSON_IsString(j))
        kind = ms_kind_from_str(j->valuestring);
    if ((j = cJSON_GetObjectItem(root, "limit")) && cJSON_IsNumber(j))
        limit = (uint32_t)j->valuedouble;

    char epoch = msgstore_get_epoch();
    if (want_epoch && want_epoch != epoch) since = 0;   /* index reset → from start */
    uint32_t latest = msgstore_get_latest_index();

    /* Size the page to the negotiated ATT MTU so it fits one notification. */
    uint16_t mtu = ble_att_mtu(conn);
    size_t cap = (mtu > 23) ? (size_t)(mtu - 3) : 20;
    static char page[512];                 /* NimBLE host task is single-threaded */
    if (cap > sizeof page) cap = sizeof page;

    ms_page_ctx_t ctx = { .buf = page, .size = cap, .len = 0,
                          .first = true, .full = false, .last = since, .epoch = epoch };
    ctx.len = (size_t)snprintf(page, cap,
        "{\"type\":\"aprs_page\",\"epoch\":\"%c\",\"latest\":\"%c%u\",\"msgs\":[",
        epoch, epoch, (unsigned)latest);

    msgstore_query_t q = { .since_index = since,
                           .call_filter = call[0] ? call : NULL,
                           .kind_filter = kind, .limit = limit };
    uint32_t qnext = since;
    bool qmore = false;
    msgstore_query(&q, ms_page_emit, &ctx, &qnext, &qmore);
    uint32_t next = ctx.full ? ctx.last : qnext;
    bool more = qmore || ctx.full;

    int n = snprintf(page + ctx.len, cap - ctx.len,
        "],\"next\":\"%c%u\",\"more\":%s}", epoch, (unsigned)next, more ? "true" : "false");
    if (n > 0) ctx.len += (size_t)n;

    struct os_mbuf *om = ble_hs_mbuf_from_flat(page, ctx.len);
    if (om) {
        int rc = ble_gatts_notify_custom(conn, s_notify_handle, om);
        if (rc != 0) ESP_LOGW(TAG, "aprs_page notify failed: %d", rc);
    }
}

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
            } else if (type && cJSON_IsString(type) &&
                       strcmp(type->valuestring, "aprs_query") == 0) {
                handle_aprs_query(conn_handle, root);
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

    /* Build the bare compact payload `<from>\x1f<to>\x1f<text>` (no company id;
     * this is exactly what receivers' wapps parse). */
    uint8_t buf[BCAST_MAX];
    int n = 0;
    for (const char *p = from; *p && n < (int)sizeof(buf); p++) buf[n++] = (uint8_t)*p;
    if (n < (int)sizeof(buf)) buf[n++] = 0x1F;
    for (const char *p = to; *p && n < (int)sizeof(buf); p++) buf[n++] = (uint8_t)*p;
    if (n < (int)sizeof(buf)) buf[n++] = 0x1F;
    for (const char *p = text; *p && n < (int)sizeof(buf); p++) buf[n++] = (uint8_t)*p;
    if (n <= 2) return false;

    /* Content dedup so a message gated repeatedly by APRS-IS is only put on air
     * once, and our own re-scan of it neither re-broadcasts nor re-displays. */
    uint32_t ch = fnv1a(buf, n);
    if (relay_seen(ch)) return false;
    relay_remember(ch);
    shown_mark(ch);

    /* Size router: small text broadcasts to everyone in range (chunked adverts);
     * large payloads use GATT point-to-point (only if a peer is connected). */
    if (n <= BCAST_MAX) {
        relay_enqueue_broadcast(buf, n);
        ESP_LOGI(TAG, "iGate broadcast -> BLE: %s -> %s (%d B)",
                 from, to[0] ? to : "(geo)", n);
    } else if (gatt_client_connected()) {
        gatt_send_parcel(s_conn_handle, buf, n);
        ESP_LOGI(TAG, "iGate p2p (GATT) -> BLE: %s -> %s (%d B)",
                 from, to[0] ? to : "(geo)", n);
    } else {
        return false;
    }
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

/* ---- broadcast-parcel reassembly (receiver) ---------------------------- */
/* Groups incoming 0x50/0x51 chunks by (advertiser addr, msgid); when every
 * chunk (and its expected continuation) has arrived the full payload is
 * reassembled, displayed (deduped), and re-broadcast once for the mesh.
 * Mirrors BleBroadcastReassembler in ble_reassembler.dart. */
typedef struct {
    bool     used;
    uint8_t  addr[6];
    uint8_t  msgid;
    uint8_t  total;
    uint32_t updated;
    bool     have_pri[BRX_MAX_CHUNKS];
    bool     expects_cont[BRX_MAX_CHUNKS];
    bool     have_cont[BRX_MAX_CHUNKS];
    uint8_t  pri_len[BRX_MAX_CHUNKS];
    uint8_t  cont_len[BRX_MAX_CHUNKS];
    uint8_t  pri[BRX_MAX_CHUNKS][BCH_ADV_PAYLOAD];
    uint8_t  cont[BRX_MAX_CHUNKS][BCH_CONT_PAYLOAD];
} brx_slot_t;
static brx_slot_t s_brx[BRX_SLOTS];

static brx_slot_t *brx_find(const uint8_t *addr, uint8_t msgid)
{
    uint32_t t = now_sec();
    for (int i = 0; i < BRX_SLOTS; i++) {
        if (!s_brx[i].used) continue;
        if (t - s_brx[i].updated > BRX_WINDOW_SEC) { s_brx[i].used = false; continue; }
        if (s_brx[i].msgid == msgid && memcmp(s_brx[i].addr, addr, 6) == 0)
            return &s_brx[i];
    }
    return NULL;
}

static brx_slot_t *brx_alloc(const uint8_t *addr, uint8_t msgid, uint8_t total)
{
    uint32_t t = now_sec();
    int slot = -1;
    for (int i = 0; i < BRX_SLOTS; i++) {
        if (!s_brx[i].used || t - s_brx[i].updated > BRX_WINDOW_SEC) { slot = i; break; }
    }
    if (slot < 0) {                     /* all busy — evict the oldest */
        slot = 0;
        for (int i = 1; i < BRX_SLOTS; i++)
            if (s_brx[i].updated < s_brx[slot].updated) slot = i;
    }
    brx_slot_t *s = &s_brx[slot];
    memset(s, 0, sizeof(*s));
    s->used = true;
    memcpy(s->addr, addr, 6);
    s->msgid = msgid;
    s->total = total;
    s->updated = t;
    return s;
}

/* Deliver a fully-reassembled broadcast payload `<from>\x1f<to>\x1f<text>`
 * (no company id): re-broadcast once for the mesh (content-deduped) and show
 * it on the chat (aprs_decode dedups display + records the heard callsign). */
static void deliver_broadcast(const uint8_t *payload, int len, int rssi)
{
    if (len <= 0) return;
    uint32_t ch = fnv1a(payload, len);
    if (!relay_seen(ch)) {              /* flood: rebroadcast the whole message once */
        relay_remember(ch);
        relay_enqueue_broadcast(payload, len);
    }
    aprs_decode(payload, len, rssi);
}

/* Ingest one broadcast chunk [d] = [marker,subtype,msgid,idx,…] (company id
 * already stripped). On the last missing piece, reassemble and deliver. */
static void brx_ingest(const uint8_t *addr, const uint8_t *d, int dlen, int rssi)
{
    if (dlen < 4) return;
    uint8_t sub = d[1], msgid = d[2], idx = d[3];

    brx_slot_t *s = brx_find(addr, msgid);
    if (sub == BCAST_PRIMARY) {
        if (dlen < BCH_PRI_HDR) return;
        uint8_t total = d[4], flags = d[5];
        if (total == 0 || total > BRX_MAX_CHUNKS || idx >= total) return;
        if (!s) s = brx_alloc(addr, msgid, total);
        if (!s || s->total != total) return;
        int plen = dlen - BCH_PRI_HDR;
        if (plen > BCH_ADV_PAYLOAD) plen = BCH_ADV_PAYLOAD;
        if (plen < 0) plen = 0;
        memcpy(s->pri[idx], &d[BCH_PRI_HDR], plen);
        s->pri_len[idx] = (uint8_t)plen;
        s->have_pri[idx] = true;
        s->expects_cont[idx] = (flags & 0x01) != 0;
        s->updated = now_sec();
    } else {                            /* BCAST_CONT */
        if (!s || idx >= s->total) return;   /* continuation before primary — drop */
        int clen = dlen - BCH_CONT_HDR;
        if (clen > BCH_CONT_PAYLOAD) clen = BCH_CONT_PAYLOAD;
        if (clen < 0) clen = 0;
        memcpy(s->cont[idx], &d[BCH_CONT_HDR], clen);
        s->cont_len[idx] = (uint8_t)clen;
        s->have_cont[idx] = true;
        s->updated = now_sec();
    }

    if (!s) return;
    for (int i = 0; i < s->total; i++) {     /* complete? */
        if (!s->have_pri[i]) return;
        if (s->expects_cont[i] && !s->have_cont[i]) return;
    }

    uint8_t buf[BCAST_MAX];
    int n = 0;
    for (int i = 0; i < s->total; i++) {
        if (n + s->pri_len[i] <= (int)sizeof(buf)) {
            memcpy(&buf[n], s->pri[i], s->pri_len[i]); n += s->pri_len[i];
        }
        if (s->have_cont[i] && n + s->cont_len[i] <= (int)sizeof(buf)) {
            memcpy(&buf[n], s->cont[i], s->cont_len[i]); n += s->cont_len[i];
        }
    }
    s->used = false;
    deliver_broadcast(buf, n, rssi);
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

        /* Broadcast-parcel chunk (0x50 primary in ADV / 0x51 continuation in
         * SCAN_RSP): route to the reassembler, not the presence/compact paths
         * (its header bytes are not a callsign). */
        if (mlen >= 4 && mfg[2] == GEOGRAM_MARKER &&
            (mfg[3] == BCAST_PRIMARY || mfg[3] == BCAST_CONT)) {
            track_device(addr);
            brx_ingest(addr, &mfg[2], mlen - 2, event->disc.rssi);
            break;
        }

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
