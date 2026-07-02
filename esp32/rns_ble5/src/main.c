/*
 * Full Reticulum BLE5 node for the LilyGO T-Dongle-S3.
 *
 * RECEIVE: NimBLE extended scan; decode RNS announces (manufacturer 0xFFFF,
 *   marker 0x3E, subtype 0x55) and print the chat text.
 * TRANSMIT: a real RNS Identity (X25519 + Ed25519, persisted in NVS) with its
 *   own "aurora.chat" destination. It builds and Ed25519-SIGNS valid announces
 *   and airs them as BLE5 extended advertisements, so the phones accept and
 *   display them exactly like another phone.
 *
 * Crypto: TweetNaCl (Ed25519 sign + X25519 base-point + SHA-512) for the
 * identity/signature, mbedTLS SHA-256 for the RNS hashes. No app-layer secrets
 * leave the device; the BLE transport itself is unauthenticated (RNS provides
 * its own crypto), so no pairing is needed.
 */
#include <stdio.h>
#include <string.h>
#include <strings.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "freertos/queue.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "mbedtls/sha256.h"

#include "driver/gpio.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "os/os_mbuf.h"
#include "nimble/ble.h"
#include "nimble/hci_common.h"
#include "host/ble_hs.h"
#include "host/ble_gap.h"
#include "host/util/util.h"

#include "model_init.h"
#include "tdongle_ui.h"
#include "tweetnacl.h"

/* APRS-IS iGate: WiFi STA + APRS-IS client (reused generic components). */
#include "wifi_bsp.h"
#include "aprsis.h"

/* LAN presence: passive listener on the Aurora UDP discovery broadcast. */
#include "lanwatch.h"

/* BLE street mesh (aurora doc/mesh.md): route beacon + DV table + SCF. */
#include <sys/stat.h>
#include "blemesh.h"
#include "sdcard.h"

/* Provisioning defaults (WiFi creds + callsign). The real file is gitignored;
 * values are written to NVS on first boot and NVS is the source of truth after.
 * Builds fine without the file (creds then come only from NVS). */
#if __has_include("igate_secrets.h")
#include "igate_secrets.h"
#endif
#ifndef IGATE_WIFI_SSID
#define IGATE_WIFI_SSID ""
#endif
#ifndef IGATE_WIFI_PASSWORD
#define IGATE_WIFI_PASSWORD ""
#endif
#ifndef IGATE_CALLSIGN
#define IGATE_CALLSIGN ""
#endif

static const char *TAG = "rns_ble5";
static uint8_t s_own_addr_type;

#define COMPANY_LO 0xFF
#define COMPANY_HI 0xFF
#define MARKER     0x3E
#define SUBTYPE      0x55   /* Reticulum packet */
#define SUBTYPE_APRS 0x41   /* APRS broadcast parcel ('A') — plaintext */
#define SUBTYPE_MESH BLEMESH_SUBTYPE /* 0x4D street-mesh route beacon ('M') */

#define RNS_PKT_ANNOUNCE 0x01
#define DST_HASH_LEN     16
#define CALLSIGN_MAX     12   /* max callsign chars shown on the dashboard */
#define KEYSIZE          64
#define NAME_HASH_LEN    10
#define RANDOM_HASH_LEN  10
#define RATCHET_LEN      32
#define SIG_LEN          64

#define APP_NAME "aurora"
#define ASPECT   "chat"
#define FULL_NAME "aurora.chat"      /* expand_name(None, app, aspect) */

/* ---- our identity (RNS) ------------------------------------------------- */
static uint8_t s_ed_sk[64];   /* Ed25519 secret: seed(32) || pub(32) */
static uint8_t s_ed_pk[32];
static uint8_t s_x_sk[32];     /* X25519 scalar */
static uint8_t s_x_pk[32];
static uint8_t s_pubkey[KEYSIZE];     /* x25519_pub(32) || ed25519_pub(32) */
static uint8_t s_id_hash[16];
static uint8_t s_name_hash[NAME_HASH_LEN];
static uint8_t s_dest_hash[DST_HASH_LEN];

/* Repeater: re-air a received RNS packet so out-of-range nodes still get it. */
static void maybe_relay(const uint8_t *pkt, int len, int rssi);
/* UI hook (metadata only; defined in the UI section, no-op until UI is wired). */
static void ui_log_packet(const uint8_t *dest_hash, int hops, int rssi,
                          const char *name);
static uint32_t now_sec(void);
/* APRS (subtype 0x41) is plaintext broadcast chat — relay it (not shown; the
 * display is a reach dashboard now, never message content). */
static void handle_aprs(const uint8_t *payload, int len, int rssi);
/* iGate: remember a callsign heard over BLE5 (for the APRS-IS filter). */
static void igate_heard_add(const char *call);
/* Street mesh: beacon TX + ingest + store-and-forward delivery. */
static void handle_mesh(const uint8_t *payload, int len, int rssi);
static void mesh_beacon_air(void);
static void mesh_deliver_pending(const char *target);
static volatile bool s_mesh_dirty;      /* topology changed -> beacon early */
static bool s_mesh_up;
static char s_aprs_call[10];            /* tentative; defined with iGate below */

/* TweetNaCl entropy hook. */
void randombytes(unsigned char *p, unsigned long long n)
{
    esp_fill_random(p, (size_t)n);
}

static void sha256(const uint8_t *in, size_t n, uint8_t *out32)
{
    mbedtls_sha256(in, n, out32, 0);
}

static void hexn(const uint8_t *b, int n, char *out)
{
    static const char *h = "0123456789abcdef";
    for (int i = 0; i < n; i++) {
        out[i * 2] = h[b[i] >> 4];
        out[i * 2 + 1] = h[b[i] & 0xf];
    }
    out[n * 2] = 0;
}

/* ---- receive path ------------------------------------------------------- */
static char s_last[160];

static void handle_rns_packet(const uint8_t *pkt, int len, int rssi)
{
    if (len < 2 + DST_HASH_LEN + 1) return;
    uint8_t flags = pkt[0];
    if ((flags & 0x03) != RNS_PKT_ANNOUNCE) return;
    uint8_t htype = (flags >> 6) & 0x01;
    uint8_t ctxflag = (flags >> 5) & 0x01;

    int dataoff = htype ? (2 + DST_HASH_LEN + DST_HASH_LEN + 1)
                        : (2 + DST_HASH_LEN + 1);
    const uint8_t *dhash = htype ? pkt + 2 + DST_HASH_LEN : pkt + 2;
    if (len <= dataoff) return;

    const uint8_t *ad = pkt + dataoff;
    int adlen = len - dataoff;
    int appoff = KEYSIZE + NAME_HASH_LEN + RANDOM_HASH_LEN +
                 (ctxflag ? RATCHET_LEN : 0) + SIG_LEN;
    if (adlen <= appoff) return;

    const uint8_t *app = ad + appoff;
    int applen = adlen - appoff;
    if (applen > 120) applen = 120;

    char text[121];
    memcpy(text, app, applen);
    text[applen] = 0;
    for (int i = 0; i < applen; i++)
        if (text[i] < 32 || text[i] > 126) text[i] = '.';

    /* Ignore our own announces (we hear our own broadcasts). */
    if (memcmp(dhash, s_dest_hash, DST_HASH_LEN) == 0) return;

    /* An announce's dest IS the announcing node, and its plaintext app_data is
     * the device callsign — the right signal for the "in range" dashboard. Feed
     * it every time so the peer stays fresh (the serial line below is deduped). */
    ui_log_packet(dhash, pkt[1], rssi, text);

    char dh[2 * 4 + 1];
    hexn(dhash, 4, dh);
    char line[160];
    snprintf(line, sizeof(line), "%s|%s", dh, text);
    if (strcmp(line, s_last) == 0) return;
    strncpy(s_last, line, sizeof(s_last) - 1);
    ESP_LOGI(TAG, "RX announce  dest=%s..  rssi=%d  app=\"%s\"", dh, rssi, text);
}

static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    if (event->type != BLE_GAP_EVENT_EXT_DISC) return 0;
    struct ble_gap_ext_disc_desc *d = &event->ext_disc;
    const uint8_t *p = d->data;
    int n = d->length_data;
    for (int i = 0; i + 2 <= n;) {
        int adlen = p[i];
        if (adlen == 0 || i + 1 + adlen > n) break;
        if (p[i + 1] == 0xFF && adlen >= 1 + 2) {
            const uint8_t *m = &p[i + 2];
            int mlen = adlen - 1;
            if (mlen >= 4 && m[0] == COMPANY_LO && m[1] == COMPANY_HI &&
                m[2] == MARKER) {
                if (m[3] == SUBTYPE) {            /* Reticulum (encrypted) */
                    handle_rns_packet(&m[4], mlen - 4, d->rssi); /* serial decode */
                    maybe_relay(&m[4], mlen - 4, d->rssi);       /* repeater + UI */
                } else if (m[3] == SUBTYPE_APRS) { /* APRS (plaintext) */
                    handle_aprs(&m[4], mlen - 4, d->rssi);       /* show + relay */
                } else if (m[3] == SUBTYPE_MESH) { /* street-mesh route beacon */
                    handle_mesh(&m[4], mlen - 4, d->rssi);
                }
            }
        }
        i += 1 + adlen;
    }
    return 0;
}

/* ---- identity ----------------------------------------------------------- */
static void identity_init(void)
{
    nvs_handle_t h;
    bool have = false;
    if (nvs_open("rns", NVS_READWRITE, &h) == ESP_OK) {
        size_t a = sizeof(s_ed_sk), b = sizeof(s_x_sk);
        if (nvs_get_blob(h, "ed_sk", s_ed_sk, &a) == ESP_OK && a == sizeof(s_ed_sk) &&
            nvs_get_blob(h, "x_sk", s_x_sk, &b) == ESP_OK && b == sizeof(s_x_sk)) {
            have = true;
        }
        if (!have) {
            crypto_sign_keypair(s_ed_pk, s_ed_sk);   /* random Ed25519 */
            randombytes(s_x_sk, sizeof(s_x_sk));     /* X25519 scalar */
            nvs_set_blob(h, "ed_sk", s_ed_sk, sizeof(s_ed_sk));
            nvs_set_blob(h, "x_sk", s_x_sk, sizeof(s_x_sk));
            nvs_commit(h);
            ESP_LOGI(TAG, "generated new identity");
        }
        nvs_close(h);
    } else {
        crypto_sign_keypair(s_ed_pk, s_ed_sk);
        randombytes(s_x_sk, sizeof(s_x_sk));
    }
    memcpy(s_ed_pk, s_ed_sk + 32, 32);               /* pub = sk[32:64] */
    crypto_scalarmult_base(s_x_pk, s_x_sk);          /* X25519 pubkey */

    memcpy(s_pubkey, s_x_pk, 32);
    memcpy(s_pubkey + 32, s_ed_pk, 32);
    uint8_t h32[32];
    sha256(s_pubkey, KEYSIZE, h32);
    memcpy(s_id_hash, h32, DST_HASH_LEN);
    sha256((const uint8_t *)FULL_NAME, strlen(FULL_NAME), h32);
    memcpy(s_name_hash, h32, NAME_HASH_LEN);
    uint8_t hm[NAME_HASH_LEN + DST_HASH_LEN];
    memcpy(hm, s_name_hash, NAME_HASH_LEN);
    memcpy(hm + NAME_HASH_LEN, s_id_hash, DST_HASH_LEN);
    sha256(hm, sizeof(hm), h32);
    memcpy(s_dest_hash, h32, DST_HASH_LEN);

    char dh[2 * DST_HASH_LEN + 1], ih[2 * DST_HASH_LEN + 1];
    hexn(s_dest_hash, DST_HASH_LEN, dh);
    hexn(s_id_hash, DST_HASH_LEN, ih);
    ESP_LOGI(TAG, "identity=%s dest(%s)=%s", ih, FULL_NAME, dh);
}

/* ---- transmit (signed announce as a BLE5 extended advertisement) -------- */
static bool s_adv_configured = false;

/* Big buffers kept static (off-stack); announce() is only ever called from the
 * single announce task, so this is safe. */
static uint8_t s_signed[DST_HASH_LEN + KEYSIZE + NAME_HASH_LEN + RANDOM_HASH_LEN + 128];
static uint8_t s_sm[64 + sizeof(s_signed)];
static uint8_t s_ad[256];

/* Air a complete BLE AD buffer on ext-adv instance 0 (configure on first use,
 * then stop+set_data+start). Used by both our own announce and the repeater. */
static void air_raw_ad(const uint8_t *ad, int n)
{
    struct os_mbuf *om = ble_hs_mbuf_from_flat(ad, n);
    if (!om) { ESP_LOGW(TAG, "mbuf alloc failed"); return; }
    if (!s_adv_configured) {
        struct ble_gap_ext_adv_params p = {0};
        p.connectable = 0;
        p.scannable = 0;
        p.legacy_pdu = 0;
        p.own_addr_type = s_own_addr_type;
        p.primary_phy = BLE_HCI_LE_PHY_1M;
        p.secondary_phy = BLE_HCI_LE_PHY_1M;
        p.sid = 0;
        p.tx_power = 127;
        p.itvl_min = 0x100;   /* 160 ms */
        p.itvl_max = 0x100;
        int rc = ble_gap_ext_adv_configure(0, &p, NULL, gap_event, NULL);
        if (rc != 0) { ESP_LOGE(TAG, "ext_adv_configure rc=%d", rc); os_mbuf_free_chain(om); return; }
        s_adv_configured = true;
    } else {
        ble_gap_ext_adv_stop(0);
    }
    int rc = ble_gap_ext_adv_set_data(0, om);
    if (rc != 0) { ESP_LOGE(TAG, "ext_adv_set_data rc=%d", rc); return; }
    rc = ble_gap_ext_adv_start(0, 0, 0);
    if (rc != 0 && rc != BLE_HS_EALREADY) ESP_LOGE(TAG, "ext_adv_start rc=%d", rc);
}

static void announce(const char *app, int applen)
{
    uint8_t random_hash[RANDOM_HASH_LEN];
    randombytes(random_hash, RANDOM_HASH_LEN);

    /* signed_data = dest + pubkey + name_hash + random_hash + app  (no ratchet) */
    uint8_t *signed_data = s_signed;
    int sp = 0;
    memcpy(signed_data + sp, s_dest_hash, DST_HASH_LEN); sp += DST_HASH_LEN;
    memcpy(signed_data + sp, s_pubkey, KEYSIZE); sp += KEYSIZE;
    memcpy(signed_data + sp, s_name_hash, NAME_HASH_LEN); sp += NAME_HASH_LEN;
    memcpy(signed_data + sp, random_hash, RANDOM_HASH_LEN); sp += RANDOM_HASH_LEN;
    memcpy(signed_data + sp, app, applen); sp += applen;

    /* Ed25519 detached signature = crypto_sign output[0:64]. */
    unsigned long long smlen = 0;
    crypto_sign(s_sm, &smlen, signed_data, sp, s_ed_sk);
    const uint8_t *sig = s_sm;  /* first 64 bytes */

    /* announce_data = pubkey + name_hash + random_hash + signature + app */
    /* rns_packet   = flags(0x01) hops(0x00) dest_hash(16) context(0x00) data */
    /* ad           = len 0xFF FF FF 3E 55 <rns_packet> */
    uint8_t *ad = s_ad;
    int n = 0;
    ad[n++] = 0;            /* AD length placeholder */
    ad[n++] = 0xFF;         /* manufacturer specific data */
    ad[n++] = COMPANY_LO;
    ad[n++] = COMPANY_HI;
    ad[n++] = MARKER;
    ad[n++] = SUBTYPE;
    ad[n++] = 0x01;         /* flags: HEADER_1, broadcast, SINGLE, ANNOUNCE */
    ad[n++] = 0x00;         /* hops */
    memcpy(ad + n, s_dest_hash, DST_HASH_LEN); n += DST_HASH_LEN;
    ad[n++] = 0x00;         /* context NONE */
    memcpy(ad + n, s_pubkey, KEYSIZE); n += KEYSIZE;
    memcpy(ad + n, s_name_hash, NAME_HASH_LEN); n += NAME_HASH_LEN;
    memcpy(ad + n, random_hash, RANDOM_HASH_LEN); n += RANDOM_HASH_LEN;
    memcpy(ad + n, sig, SIG_LEN); n += SIG_LEN;
    memcpy(ad + n, app, applen); n += applen;
    ad[0] = n - 1;          /* AD length = everything after the length byte */

    air_raw_ad(ad, n);
    ESP_LOGI(TAG, "TX announce app=\"%.*s\" (%dB adv)", applen, app, n);
}

/* ---- repeater (BLE5 RNS transport node) --------------------------------- */
static uint32_t now_sec(void) { return (uint32_t)(esp_timer_get_time() / 1000000ULL); }

static uint32_t fnv1a(const uint8_t *d, int n)
{
    uint32_t h = 2166136261u;
    for (int i = 0; i < n; i++) { h ^= d[i]; h *= 16777619u; }
    return h;
}

/* content dedup: don't re-air the same packet within 10 minutes */
#define RDEDUP_MAX      32
#define RELAY_DEDUP_SEC 600
typedef struct { uint32_t hash; uint32_t t; } dedup_t;
static dedup_t s_rdedup[RDEDUP_MAX];
static int     s_rdedup_cnt;

static bool relay_seen(uint32_t hash)
{
    uint32_t t = now_sec();
    for (int i = 0; i < RDEDUP_MAX; i++)
        if (s_rdedup[i].hash == hash && (t - s_rdedup[i].t) < RELAY_DEDUP_SEC)
            return true;
    return false;
}
static void relay_remember(uint32_t hash)
{
    s_rdedup[s_rdedup_cnt % RDEDUP_MAX].hash = hash;
    s_rdedup[s_rdedup_cnt % RDEDUP_MAX].t = now_sec();
    s_rdedup_cnt++;
}

/* re-air queue: full BLE AD buffers with a TTL, round-robin aired by relay_task */
#define RELAY_MAX     8
#define RELAY_TTL_SEC 30
typedef struct { uint8_t ad[256]; uint8_t len; uint32_t expire; } relay_slot_t;
static relay_slot_t      s_relay[RELAY_MAX];
static int               s_relay_rr;
static SemaphoreHandle_t s_relay_mtx;
static volatile uint32_t s_relayed_count;

static void relay_enqueue(const uint8_t *ad, int len)
{
    if (len <= 0 || len > 256) return;
    xSemaphoreTake(s_relay_mtx, portMAX_DELAY);
    uint32_t t = now_sec();
    int slot = -1; uint32_t soonest = 0xffffffff;
    for (int i = 0; i < RELAY_MAX; i++) {
        if (s_relay[i].len == 0 || s_relay[i].expire <= t) { slot = i; break; }
        if (s_relay[i].expire < soonest) { soonest = s_relay[i].expire; slot = i; }
    }
    memcpy(s_relay[slot].ad, ad, len);
    s_relay[slot].len = len;
    s_relay[slot].expire = t + RELAY_TTL_SEC;
    xSemaphoreGive(s_relay_mtx);
}

/* Copy the next live queued AD into [out] (round-robin). Returns its length or 0. */
static int relay_pick(uint8_t *out)
{
    int got = 0;
    xSemaphoreTake(s_relay_mtx, portMAX_DELAY);
    uint32_t t = now_sec();
    for (int k = 0; k < RELAY_MAX; k++) {
        int i = (s_relay_rr + k) % RELAY_MAX;
        if (s_relay[i].len > 0 && s_relay[i].expire <= t) { s_relay[i].len = 0; continue; }
        if (s_relay[i].len > 0) {
            memcpy(out, s_relay[i].ad, s_relay[i].len);
            got = s_relay[i].len;
            s_relay_rr = (i + 1) % RELAY_MAX;
            break;
        }
    }
    xSemaphoreGive(s_relay_mtx);
    return got;
}

/* Rewrite a received RNS packet into transport form (HEADER_2, hops+1,
 * transport_id = our identity hash) and frame it as a BLE AD into [out].
 * Returns AD length, or 0 if not relayable. The origin's signature is NOT
 * affected (it covers dest+pubkey+name_hash+random_hash+app, not hops/tid). */
static int build_relay_ad(const uint8_t *in, int in_len, uint8_t *out)
{
    if (in_len < 2 + DST_HASH_LEN + 1) return 0;
    uint8_t flags = in[0];
    uint8_t hops = in[1];
    if (hops >= 128) return 0;
    bool h2 = (flags >> 6) & 0x01;
    int tail_start = h2 ? (2 + DST_HASH_LEN) : 2;   /* dest_hash + context + data */
    int tail_len = in_len - tail_start;
    if (tail_len <= 0) return 0;
    uint8_t nflags = flags | (1 << 6) | (1 << 4);   /* HEADER_2 + TRANSPORT */
    int n = 0;
    out[n++] = 0;            /* AD length placeholder */
    out[n++] = 0xFF;
    out[n++] = COMPANY_LO;
    out[n++] = COMPANY_HI;
    out[n++] = MARKER;
    out[n++] = SUBTYPE;
    out[n++] = nflags;
    out[n++] = hops + 1;
    memcpy(out + n, s_id_hash, DST_HASH_LEN); n += DST_HASH_LEN;
    if (n + tail_len > 254) return 0;               /* one AD max 254 bytes */
    memcpy(out + n, in + tail_start, tail_len); n += tail_len;
    out[0] = n - 1;
    return n;
}

static void maybe_relay(const uint8_t *pkt, int len, int rssi)
{
    if (len < 2 + DST_HASH_LEN + 1) return;
    uint8_t flags = pkt[0];
    bool h2 = (flags >> 6) & 0x01;
    const uint8_t *dhash = h2 ? pkt + 2 + DST_HASH_LEN : pkt + 2;
    if (memcmp(dhash, s_dest_hash, DST_HASH_LEN) == 0) return;  /* our own */

    uint32_t ch = fnv1a(pkt, len);
    if (relay_seen(ch)) return;                                  /* already handled */
    relay_remember(ch);

    uint8_t ad[256];
    int n = build_relay_ad(pkt, len, ad);
    if (n <= 0) return;
    relay_enqueue(ad, n);
    s_relayed_count++;
    ESP_LOGI(TAG, "relayed dest=%02x%02x%02x%02x hops=%d->%d rssi=%d (#%u)",
             dhash[0], dhash[1], dhash[2], dhash[3], pkt[1], pkt[1] + 1, rssi,
             (unsigned)s_relayed_count);
}

/* Split an Aurora APRS parcel — from <0x1F> to <0x1F> text — into NUL-terminated
 * fields (the caller zeroes them). Returns false if there is no 0x1F separator
 * (a non-Aurora frame we still show/relay but do not gate). */
static bool split_aprs_fields(const uint8_t *p, int len,
                              char *from, int fcap, char *to, int tcap,
                              char *text, int xcap)
{
    char *f[3] = { from, to, text };
    int cap[3] = { fcap - 1, tcap - 1, xcap - 1 };
    int fi = 0, fp = 0;
    bool sep = false;
    for (int i = 0; i < len; i++) {
        uint8_t b = p[i];
        if (b == 0x1F) { sep = true; if (fi < 2) { fi++; fp = 0; } continue; }
        if (fp < cap[fi]) f[fi][fp++] = (char)b;
    }
    return sep;
}

/* Frame a raw APRS payload as a BLE AD: [len][FF FF][3E][41][payload]. */
static int build_aprs_ad(const uint8_t *payload, int len, uint8_t *out)
{
    int n = 0;
    out[n++] = 0;            /* AD length placeholder */
    out[n++] = 0xFF;
    out[n++] = COMPANY_LO;
    out[n++] = COMPANY_HI;
    out[n++] = MARKER;
    out[n++] = SUBTYPE_APRS;
    if (n + len > 254) return 0;             /* one AD max 254 bytes */
    memcpy(out + n, payload, len); n += len;
    out[0] = n - 1;
    return n;
}

/* An APRS group message heard over BLE5. Unlike Reticulum, APRS is PLAINTEXT
 * (a public, radio-compatible bulletin), so the dongle may show it. It is also
 * relayed (re-aired once) to extend reach — one-to-many, deduped by content. */
static void handle_aprs(const uint8_t *payload, int len, int rssi)
{
    if (len <= 0) return;
    uint32_t ch = fnv1a(payload, len);
    if (relay_seen(ch)) return;              /* already handled (dedup) */
    relay_remember(ch);

    /* Split the Aurora parcel: from <0x1F> to <0x1F> text. */
    char from[CALLSIGN_MAX] = {0}, to[12] = {0}, text[160] = {0};
    bool aurora = split_aprs_fields(payload, len, from, sizeof from,
                                    to, sizeof to, text, sizeof text);
    if (!aurora) {
        /* Non-Aurora frame: printable dump for the dashboard, not gated. */
        int t = 0;
        for (int i = 0; i < len && t < (int)sizeof(text) - 1; i++) {
            uint8_t c = payload[i];
            text[t++] = (c >= 32 && c <= 126) ? (char)c : '.';
        }
        text[t] = 0;
        snprintf(from, sizeof from, "APRS");
    }
    ESP_LOGI(TAG, "RX APRS  rssi=%d  %s>%s: \"%s\"", rssi, from, to, text);

    /* Receipt id: 1:1 messages carry a PREPENDED "am:<6hex> " token; receipts
     * come back as "?ACK <6hex> d|r" control frames (aurora receipts design). */
    char am[8] = "";
    const char *body = text;
    if (strncmp(text, "am:", 3) == 0 && strlen(text) >= 9) {
        memcpy(am, text + 3, 6); am[6] = 0;
        body = text + 9;
        while (*body == ' ') body++;
    }
    if (aurora && strncmp(text, "?ACK ", 5) == 0 && strlen(text) >= 11) {
        char ack_am[8]; memcpy(ack_am, text + 5, 6); ack_am[6] = 0;
        int purged = blemesh_scf_ack(ack_am);
        if (purged) ESP_LOGI(TAG, "SCF: ack %s purged %d", ack_am, purged);
    }

    /* iGate uplink (RF -> Internet): remember the sender and gate it to APRS-IS.
     * No-op if WiFi/APRS-IS is down. Skip control frames (text starting '?',
     * e.g. ?ACK/?PING/?MAIL) and ENCRYPTED payloads — the phones deliberately
     * keep ENC1 ciphertext OFF APRS-IS (7-bit air mangles it into
     * "cannot decrypt" garbage on every receiver). */
    if (aurora) {
        igate_heard_add(from);
        if (to[0] && to[0] != '?' && text[0] != '?' &&
            strncmp(body, "ENC1:", 5) != 0)
            aprsis_uplink(from, to, text);
    }

    /* Store-and-forward custody (doc/mesh.md §6): park heard 1:1 messages so a
     * receiver that is out of range / asleep gets them when it reappears. The
     * sender was just heard transmitting — deliver anything parked for IT too. */
    if (aurora && s_mesh_up) {
        bool one2one = to[0] && to[0] != '#' && to[0] != '?' && to[0] != '!' &&
                       text[0] != '?' && strcmp(to, s_aprs_call) != 0;
        if (one2one && blemesh_scf_offer(to, am, payload, len, now_sec()))
            ESP_LOGI(TAG, "SCF: parked %dB for %s (am=%s, %d held)",
                     len, to, am[0] ? am : "-", blemesh_scf_count());
        mesh_deliver_pending(from);
    }

    /* Relay (extend reach). Re-air the same plaintext frame, deduped above. */
    uint8_t ad[256];
    int n = build_aprs_ad(payload, len, ad);
    if (n > 0) {
        relay_enqueue(ad, n);
        s_relayed_count++;
        ESP_LOGI(TAG, "relayed APRS %dB rssi=%d (#%u)", len, rssi,
                 (unsigned)s_relayed_count);
    }
}

/* ---- street mesh (aurora doc/mesh.md): beacon + DV + SCF ----------------- */

/* Re-air every parked frame for [target] (it was just seen). Each goes back on
 * the normal relay rotation as a plain 0x41 broadcast; the receiver dedups. */
static void mesh_deliver_pending(const char *target)
{
    static uint8_t frames[4][BLEMESH_SCF_FRAME_MAX];
    static int lens[4];
    int n = blemesh_scf_pop_for(target, now_sec(), frames, lens, 4);
    for (int i = 0; i < n; i++) {
        uint8_t ad[256];
        int an = build_aprs_ad(frames[i], lens[i], ad);
        if (an > 0) { relay_enqueue(ad, an); s_relayed_count++; }
    }
    if (n > 0)
        ESP_LOGI(TAG, "SCF: %s back in range -> re-airing %d parked frame(s)", target, n);
}

/* A phone's (or another dongle's) route beacon: learn it, and treat the sender
 * as "in range" for parked mail. */
static void handle_mesh(const uint8_t *payload, int len, int rssi)
{
    if (!s_mesh_up) return;
    blemesh_beacon_t b;
    if (!blemesh_beacon_decode(payload, len, &b)) return;
    bool changed = blemesh_table_ingest(&b, rssi, now_sec());
    if (changed) {
        s_mesh_dirty = true;
        ESP_LOGI(TAG, "mesh: %s (%s%s, %ddBm, reaches %d) — %d neighbor(s)",
                 b.callsign,
                 b.dev_class == BLEMESH_CLASS_PHONE ? "phone" :
                 b.dev_class == BLEMESH_CLASS_ESP32 ? "esp32" : "node",
                 b.powered ? ", powered" : "", rssi, b.dv_count,
                 blemesh_neighbor_count());
    }
    mesh_deliver_pending(b.callsign);
}

/* Build + air our route beacon: class esp32, always powered + stationary (a
 * plugged dongle is the street's natural base station), storage headroom from
 * the SD card, DV digest from the table. */
static void mesh_beacon_air(void)
{
    if (!s_mesh_up) return;
    blemesh_beacon_t b = {0};
    snprintf(b.callsign, sizeof(b.callsign), "%s",
             s_aprs_call[0] ? s_aprs_call : "TDONGLE");
    b.dev_class = BLEMESH_CLASS_ESP32;
    b.powered = true;
    b.uptime_bucket = blemesh_uptime_bucket(now_sec());
    b.mobility = 1;                       /* stationary */
    b.storage_bucket = sdcard_is_mounted() ? 3 : 0;
    b.dv_count = (uint8_t)blemesh_table_export(b.dv, 48);

    uint8_t payload[200];
    int pn = blemesh_beacon_encode(&b, payload, sizeof(payload));
    if (pn <= 0) return;
    uint8_t ad[256];
    int n = 0;
    ad[n++] = 0;
    ad[n++] = 0xFF;
    ad[n++] = COMPANY_LO;
    ad[n++] = COMPANY_HI;
    ad[n++] = MARKER;
    ad[n++] = SUBTYPE_MESH;
    memcpy(ad + n, payload, pn); n += pn;
    ad[0] = n - 1;
    air_raw_ad(ad, n);
}

/* Owns ext-adv instance 0: rotates between queued relays and our own announce. */
static void relay_task(void *arg)
{
    (void)arg;
    static uint8_t pick[256];
    announce("tdongle-s3 online", 17);   /* configures instance 0 + first announce */
    uint32_t last_own = now_sec();
    uint32_t last_sweep = now_sec();
    uint32_t last_beacon = 0;
    int tick = 0;
    bool flip = false;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(1500));
        uint32_t t = now_sec();

        /* Housekeeping: age out dead neighbors/routes + expired parked mail. */
        if (t - last_sweep >= 60) {
            last_sweep = t;
            blemesh_table_sweep(t);
            blemesh_scf_sweep(t);
        }
        /* Triggered update: topology changed -> beacon early (light debounce
         * via the 1.5 s loop period), same as the phones. */
        if (s_mesh_dirty && t - last_beacon >= 4) {
            s_mesh_dirty = false;
            last_beacon = t;
            mesh_beacon_air();
            continue;
        }

        /* Our own frames get a GUARANTEED slot every 8 s — a busy street keeps
         * the relay queue non-empty for minutes at a time, and a beacon that
         * only airs when idle is never heard (the phones then never learn we
         * exist, so no routes ever point through us). Alternate the mesh route
         * beacon and the signed RNS announce; relays fill every other slot. */
        if (t - last_own >= 8) {
            flip = !flip;
            if (flip && s_mesh_up) {
                mesh_beacon_air();
                last_beacon = t;
            } else {
                char msg[48];
                int l = snprintf(msg, sizeof(msg), "tdongle-s3 #%d", ++tick);
                announce(msg, l);         /* keep our own announce fresh (re-signs) */
            }
            last_own = t;
            continue;
        }
        int n = relay_pick(pick);
        if (n > 0) {
            air_raw_ad(pick, n);          /* re-air a relayed packet */
        }
    }
}

static void start_scan(void)
{
    struct ble_gap_ext_disc_params uncoded = {
        .itvl = 0x0060, .window = 0x0050, .passive = 1,
    };
    int rc = ble_gap_ext_disc(s_own_addr_type, 0, 0, 0, 0, 0, &uncoded, NULL,
                              gap_event, NULL);
    if (rc != 0) ESP_LOGE(TAG, "ext_disc rc=%d", rc);
    else ESP_LOGI(TAG, "extended scanning…");
}

/* ---- status / reach dashboard UI (metadata only; reuses tdongle_ui) ------ */
/* The display body is a BLE/LAN coverage dashboard (NEVER message content).
 * The BOOT button cycles it: counts -> BLE callsigns -> LAN callsigns.
 * name = the callsign the node broadcasts in its (plaintext) announce app_data;
 * every announce heard over BLE5 feeds the in-reach peer registry. */
typedef struct {
    char name[CALLSIGN_MAX];
    uint8_t prefix[4];
} ui_msg_t;
static QueueHandle_t s_ui_q;

/* T-Dongle-S3 pushbutton = the BOOT strap pin (GPIO0, active low; no BTN_* in
 * geogram_model_tdongle_s3 — the board has no other button). */
#define UI_BTN_GPIO    GPIO_NUM_0
#define UI_VIEW_COUNT  3            /* counts, BLE list, LAN list */
#define UI_INRANGE_SEC 300          /* "in reach" = heard in the last 5 min */

/* BLE reach registry: Reticulum announce peers, dest-hash keyed (the mesh
 * route-beacon neighbors live in blemesh_table; the render merges both).
 * Written only by ui_task (via s_ui_q), read only by ui_task. */
#define UI_PEER_MAX 16
static struct { uint8_t p[4]; uint32_t t; char name[CALLSIGN_MAX]; } s_ui_peers[UI_PEER_MAX];

/* Called from the NimBLE host task — only enqueues (LVGL is single-task). [name]
 * is the announce's plaintext app_data (the device callsign); falls back to the
 * dest-hash prefix in hex when no name was advertised. */
static void ui_log_packet(const uint8_t *dest_hash, int hops, int rssi,
                          const char *name)
{
    (void)hops; (void)rssi;
    if (!s_ui_q) return;
    ui_msg_t m;
    if (name && name[0]) {
        snprintf(m.name, sizeof(m.name), "%s", name);
    } else {
        hexn(dest_hash, 4, m.name);
    }
    memcpy(m.prefix, dest_hash, 4);
    xQueueSend(s_ui_q, &m, 0);   /* drop if full; the next announce refreshes */
}

/* Case-insensitive "is [name] already in the list" (dedup helper). */
static bool ui_name_listed(char names[][CALLSIGN_MAX], int n, const char *name)
{
    for (int k = 0; k < n; k++)
        if (strcasecmp(names[k], name) == 0) return true;
    return false;
}

/* Collect the DISTINCT callsigns currently in BLE reach: RNS announce peers
 * merged with the street-mesh beacon neighbors (a phone shows up on both, and
 * announces SEVERAL destinations under one callsign — dedup by name,
 * case-insensitive). Returns the count (<= max). */
static int ble_reach_gather(char names[][CALLSIGN_MAX], int max)
{
    uint32_t now = now_sec();
    int n = 0;
    for (int i = 0; i < UI_PEER_MAX && n < max; i++) {
        if (!s_ui_peers[i].t || now - s_ui_peers[i].t >= UI_INRANGE_SEC) continue;
        if (ui_name_listed(names, n, s_ui_peers[i].name)) continue;
        snprintf(names[n], CALLSIGN_MAX, "%s", s_ui_peers[i].name);
        n++;
    }
    for (int i = 0; i < blemesh_neighbor_count() && n < max; i++) {
        const blemesh_neighbor_t *nb = blemesh_neighbor_at(i);
        if (!nb || now - nb->last_heard >= UI_INRANGE_SEC) continue;
        if (ui_name_listed(names, n, nb->callsign)) continue;
        snprintf(names[n], CALLSIGN_MAX, "%s", nb->callsign);
        n++;
    }
    return n;
}

/* Append " name" entries to [body] until it is full (label wraps the rest). */
static void append_names(char *body, int cap, char names[][CALLSIGN_MAX], int n)
{
    int used = strlen(body);
    for (int i = 0; i < n; i++) {
        int w = snprintf(body + used, cap - used, "%s%s",
                         i ? "  " : "", names[i]);
        if (w <= 0 || used + w >= cap - 1) break;
        used += w;
    }
}

/* Rebuild the dashboard body for [view] + the rotating bottom-left line.
 * Runs in ui_task only (all tdongle_ui calls are deferred-safe anyway). */
static void ui_render(int view, int *rot)
{
    static char names[UI_PEER_MAX + BLEMESH_NEIGH_MAX][CALLSIGN_MAX];
    static lanwatch_peer_t lan[LANWATCH_PEERS_MAX];
    int nble = ble_reach_gather(names, UI_PEER_MAX + BLEMESH_NEIGH_MAX);
    int nlan = lanwatch_peers(lan, LANWATCH_PEERS_MAX, UI_INRANGE_SEC);

    char body[224];
    if (view == 1) {                       /* BLE callsigns in reach */
        snprintf(body, sizeof(body), "BLE in reach (%d):\n%s",
                 nble, nble ? "" : "--");
        append_names(body, sizeof(body), names, nble);
    } else if (view == 2) {                /* WiFi/LAN callsigns in reach */
        snprintf(body, sizeof(body), "LAN in reach (%d):\n%s",
                 nlan, nlan ? "" : "--");
        for (int i = 0; i < nlan; i++) {   /* nameless peer -> its IP tail */
            if (!lan[i].callsign[0]) {
                const uint8_t *q = (const uint8_t *)&lan[i].ip; /* net order */
                snprintf(lan[i].callsign, sizeof(lan[i].callsign),
                         ".%u.%u", (unsigned)q[2], (unsigned)q[3]);
            }
        }
        int used = strlen(body);
        for (int i = 0; i < nlan; i++) {
            int w = snprintf(body + used, sizeof(body) - used, "%s%s",
                             i ? "  " : "", lan[i].callsign);
            if (w <= 0 || used + w >= (int)sizeof(body) - 1) break;
            used += w;
        }
    } else {                               /* default: reach counts */
        snprintf(body, sizeof(body),
                 "In reach\nBLE devices: %d\nLAN devices: %d", nble, nlan);
    }
    tdongle_ui_set_body(body);
    tdongle_ui_set_device_count(nble);

    /* Bottom-left rotates through the in-reach BLE callsigns, then a relay
     * tally — readable at a glance even from the counts view. */
    char line[24];
    int sel = (*rot)++ % (nble + 1);
    if (sel < nble)
        snprintf(line, sizeof(line), "%s", names[sel]);
    else
        snprintf(line, sizeof(line), "relayed %u", (unsigned)s_relayed_count);
    tdongle_ui_set_info(line);
}

/* Owns ALL LVGL/tdongle_ui calls. Drains the queue into the peer registry,
 * polls the button, and refreshes the three zones (top=uptime by tdongle_ui,
 * body=reach dashboard, bottom=rotating callsign/relayed + BLE count). */
static void ui_task(void *arg)
{
    (void)arg;
    /* BOOT button: input + pull-up, plain debounced polling (no ISR needed). */
    gpio_config_t btn = {
        .pin_bit_mask = 1ULL << UI_BTN_GPIO,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&btn);

    int last_ui = 0, rot = 0, view = 0;
    int btn_low = 0;
    bool btn_fired = false, dirty = true;
    for (;;) {
        ui_msg_t m;
        while (xQueueReceive(s_ui_q, &m, 0) == pdTRUE) {
            uint32_t t = now_sec();
            int slot = -1, oldest = 0;
            for (int i = 0; i < UI_PEER_MAX; i++) {
                if (memcmp(s_ui_peers[i].p, m.prefix, 4) == 0 && s_ui_peers[i].t) { slot = i; break; }
                if (s_ui_peers[i].t == 0) { slot = i; break; }
                if (s_ui_peers[i].t < s_ui_peers[oldest].t) oldest = i;
            }
            if (slot < 0) slot = oldest;
            memcpy(s_ui_peers[slot].p, m.prefix, 4);
            s_ui_peers[slot].t = t ? t : 1;
            snprintf(s_ui_peers[slot].name, sizeof(s_ui_peers[slot].name), "%s", m.name);
        }

        /* Button poll (~10 ms period): 3 consecutive lows = pressed, fire once
         * per press, re-arm on release. Cycles the dashboard view. */
        if (gpio_get_level(UI_BTN_GPIO) == 0) {
            if (++btn_low >= 3 && !btn_fired) {
                btn_fired = true;
                view = (view + 1) % UI_VIEW_COUNT;
                dirty = true;
            }
        } else {
            btn_low = 0;
            btn_fired = false;
        }

        int now = (int)now_sec();
        if (dirty || now - last_ui >= 2) {   /* refresh ~every 2s + on press */
            dirty = false;
            last_ui = now;
            ui_render(view, &rot);
        }
        tdongle_ui_update();
        /* At the default 100 Hz tick pdMS_TO_TICKS(5) rounds to 0 ticks, so
         * vTaskDelay would never block and this task would starve IDLE0 (task
         * watchdog). Always delay at least one tick so the idle task can run. */
        TickType_t d = pdMS_TO_TICKS(10);
        vTaskDelay(d ? d : 1);
    }
}

static void on_sync(void)
{
    ble_hs_id_infer_auto(0, &s_own_addr_type);
    start_scan();
    /* relay_task owns ext-adv instance 0 (own announce + relayed packets). It has
     * a generous stack because Ed25519 signing for our own announce is heavy. */
    xTaskCreate(relay_task, "rns_relay", 8192, NULL, 5, NULL);
}

static void on_reset(int reason) { ESP_LOGW(TAG, "nimble reset, reason=%d", reason); }

static void host_task(void *param)
{
    (void)param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

/* ---- APRS-IS iGate (WiFi STA -> APRS-IS, gating BLE5 APRS both ways) ----- */

static char s_aprs_call[10];     /* station callsign (X3xxxx) used with APRS-IS */

/* Callsigns heard over BLE5 APRS — the iGate filters APRS-IS for traffic to
 * these (and relays such traffic back down). Touched by the NimBLE host task
 * (igate_heard_add) and the aprsis task (igate_get_heard) → mutex-guarded. */
#define IG_HEARD_MAX 24
static struct { char call[8]; uint32_t t; } s_ig_heard[IG_HEARD_MAX];
static SemaphoreHandle_t s_ig_heard_mtx;

static void igate_heard_add(const char *call)
{
    if (!s_ig_heard_mtx || !call) return;
    char c[8]; int n = 0;                     /* normalise: upper, strip -SSID */
    for (const char *p = call; *p && *p != '-' && n < 7; p++) {
        char u = (*p >= 'a' && *p <= 'z') ? (char)(*p - 32) : *p;
        if ((u >= 'A' && u <= 'Z') || (u >= '0' && u <= '9')) c[n++] = u;
        else break;
    }
    c[n] = 0;
    if (n < 3) return;                         /* too short to be a callsign */
    xSemaphoreTake(s_ig_heard_mtx, portMAX_DELAY);
    uint32_t t = now_sec();
    int slot = -1, oldest = 0;
    for (int i = 0; i < IG_HEARD_MAX; i++) {
        if (strcmp(s_ig_heard[i].call, c) == 0) { slot = i; break; }
        if (s_ig_heard[i].t == 0) { slot = i; break; }
        if (s_ig_heard[i].t < s_ig_heard[oldest].t) oldest = i;
    }
    if (slot < 0) slot = oldest;
    strncpy(s_ig_heard[slot].call, c, sizeof s_ig_heard[slot].call - 1);
    s_ig_heard[slot].call[sizeof s_ig_heard[slot].call - 1] = 0;
    s_ig_heard[slot].t = t ? t : 1;
    xSemaphoreGive(s_ig_heard_mtx);
}

/* aprsis hook: fill calls[][8] with up to [max] callsigns heard within [age]. */
static int igate_get_heard(char calls[][8], int max, uint32_t max_age_sec)
{
    if (!s_ig_heard_mtx) return 0;
    int out = 0;
    uint32_t t = now_sec();
    xSemaphoreTake(s_ig_heard_mtx, portMAX_DELAY);
    for (int i = 0; i < IG_HEARD_MAX && out < max; i++) {
        if (s_ig_heard[i].t && (t - s_ig_heard[i].t) < max_age_sec) {
            strncpy(calls[out], s_ig_heard[i].call, 7);
            calls[out][7] = 0;
            out++;
        }
    }
    xSemaphoreGive(s_ig_heard_mtx);
    return out;
}

/* aprsis hook (downlink): re-air an APRS frame from the Internet over BLE5 so
 * local phones receive it. Built as the same from<0x1F>to<0x1F>text parcel and
 * content-remembered so we don't re-gate our own downlink back up (loop guard). */
static bool igate_relay(const char *from, const char *to, const char *text)
{
    uint8_t pl[300];
    int n = 0;
    for (const char *p = from; *p && n < 280; p++) pl[n++] = (uint8_t)*p;
    pl[n++] = 0x1F;
    for (const char *p = to; *p && n < 290; p++) pl[n++] = (uint8_t)*p;
    pl[n++] = 0x1F;
    for (const char *p = text; *p && n < 299; p++) pl[n++] = (uint8_t)*p;

    uint8_t ad[256];
    int adn = build_aprs_ad(pl, n, ad);
    if (adn <= 0) return false;
    relay_remember(fnv1a(pl, n));       /* loop guard: ignore our own downlink on RX */
    relay_enqueue(ad, adn);
    s_relayed_count++;
    return true;
}

/* Derive a stable X3-prefixed station callsign from the RNS identity hash. */
static void derive_x3_callsign(char *out, int cap)
{
    static const char B36[] = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) v = (v << 8) | s_id_hash[i];
    if (cap < 7) { out[0] = 0; return; }
    out[0] = 'X'; out[1] = '3';
    for (int i = 0; i < 4; i++) { out[2 + i] = B36[v % 36]; v /= 36; }
    out[6] = 0;
}

/* First-boot provisioning: write WiFi creds + callsign into NVS if absent, then
 * load the callsign into s_aprs_call. NVS is the source of truth thereafter. */
static void igate_provision(void)
{
    nvs_handle_t h;
    /* WiFi creds in the namespace geogram_wifi reads ("wifi_config"). */
    if (nvs_open("wifi_config", NVS_READWRITE, &h) == ESP_OK) {
        size_t len = 0;
        bool have = (nvs_get_str(h, "ssid", NULL, &len) == ESP_OK && len > 1);
        if (!have && IGATE_WIFI_SSID[0]) {
            nvs_set_str(h, "ssid", IGATE_WIFI_SSID);
            nvs_set_str(h, "password", IGATE_WIFI_PASSWORD);
            nvs_commit(h);
            ESP_LOGI(TAG, "provisioned WiFi credentials into NVS");
        }
        nvs_close(h);
    }
    /* Callsign in the RNS namespace ("rns"/"aprs_call"). */
    s_aprs_call[0] = 0;
    if (nvs_open("rns", NVS_READWRITE, &h) == ESP_OK) {
        size_t len = sizeof s_aprs_call;
        if (!(nvs_get_str(h, "aprs_call", s_aprs_call, &len) == ESP_OK && s_aprs_call[0])) {
            if (IGATE_CALLSIGN[0])
                snprintf(s_aprs_call, sizeof s_aprs_call, "%s", IGATE_CALLSIGN);
            else
                derive_x3_callsign(s_aprs_call, sizeof s_aprs_call);
            nvs_set_str(h, "aprs_call", s_aprs_call);
            nvs_commit(h);
        }
        nvs_close(h);
    }
    if (!s_aprs_call[0]) derive_x3_callsign(s_aprs_call, sizeof s_aprs_call);
}

/* Bring up the APRS-IS iGate, then WiFi STA. aprsis_init() starts its own task
 * that waits for WiFi internally — starting it first means its uplink queue
 * exists before the first BLE frame arrives, so traffic heard during the WiFi
 * connect window is buffered and gated once connected (not lost). No-op (warns)
 * if there are no WiFi credentials. */
static void igate_start(void)
{
    s_ig_heard_mtx = xSemaphoreCreateMutex();
    igate_provision();

    char ssid[33] = {0}, pass[65] = {0};
    bool have_creds = false;
    if (geogram_wifi_init() == ESP_OK &&
        geogram_wifi_load_credentials(ssid, pass) == ESP_OK && ssid[0]) {
        have_creds = true;
    }
    if (!have_creds) {
        ESP_LOGW(TAG, "iGate: no WiFi credentials in NVS — iGate disabled");
        return;
    }

    /* Start APRS-IS first (queue ready for early frames); it waits for WiFi. */
    aprsis_set_stores(NULL, NULL);             /* no SD archive on this firmware */
    aprsis_set_ble_hooks(igate_get_heard, igate_relay);
    aprsis_init(s_aprs_call);
    ESP_LOGI(TAG, "iGate: APRS-IS started as %s; connecting WiFi STA to %s",
             s_aprs_call, ssid);

    geogram_wifi_config_t cfg = {0};
    strncpy(cfg.ssid, ssid, sizeof cfg.ssid - 1);
    strncpy(cfg.password, pass, sizeof cfg.password - 1);
    cfg.callback = NULL;
    geogram_wifi_connect(&cfg);

    /* LAN reach: listen for the Aurora UDP discovery broadcast (announces) so
     * the dashboard can count geogram devices on the same network. Passive
     * (receive-only); datagrams start flowing once the STA has an IP. */
    lanwatch_start(LANWATCH_DEFAULT_PORT);
}

/* ---- serial console (USB-Serial-JTAG stdin) ------------------------------ *
 * Debug/control without the app: type into `pio device monitor` / serial.sh.
 *   status                   dump identity, neighbors, routes, parked mail
 *   msg <to> <text...>       air a compact APRS 1:1/group frame from our call
 *   beacon                   air the mesh route beacon now
 *   ack <6hex>               simulate an overheard ?ACK (purges parked mail)
 */
static void console_handle(char *line)
{
    if (strcmp(line, "status") == 0) {
        printf("callsign=%s mesh=%d neigh=%d routes=%d scf=%d sd=%d\n",
               s_aprs_call[0] ? s_aprs_call : "TDONGLE", (int)s_mesh_up,
               blemesh_neighbor_count(), blemesh_route_count(),
               blemesh_scf_count(), (int)sdcard_is_mounted());
        for (int i = 0; i < blemesh_neighbor_count(); i++) {
            const blemesh_neighbor_t *n = blemesh_neighbor_at(i);
            printf("  neigh %-9s class=%d rssi=%d bidi=%d reach=%d age=%us\n",
                   n->callsign, n->dev_class, n->rssi, (int)n->bidirectional,
                   n->reach, (unsigned)(now_sec() - n->last_heard));
        }
        return;
    }
    if (strncmp(line, "msg ", 4) == 0) {
        char *to = line + 4;
        char *sp = strchr(to, ' ');
        if (!sp) { printf("usage: msg <to> <text>\n"); return; }
        *sp = 0;
        const char *text = sp + 1;
        uint8_t payload[BLEMESH_SCF_FRAME_MAX];
        int n = snprintf((char *)payload, sizeof(payload), "%s\x1f%s\x1f%s",
                         s_aprs_call[0] ? s_aprs_call : "TDONGLE", to, text);
        if (n <= 0 || n >= (int)sizeof(payload)) { printf("too long\n"); return; }
        uint8_t ad[256];
        int an = build_aprs_ad(payload, n, ad);
        if (an > 0) {
            /* Remember our own content hash BEFORE airing: when a phone
             * re-airs (bridges) this frame back to us, handle_aprs must treat
             * it as already-handled — otherwise the echo gets uplinked to
             * APRS-IS and the "BLE-only" message leaks onto the internet. */
            relay_remember(fnv1a(payload, n));
            relay_enqueue(ad, an);
            printf("queued %dB to %s\n", n, to);
        }
        return;
    }
    if (strcmp(line, "beacon") == 0) { mesh_beacon_air(); printf("beacon aired\n"); return; }
    if (strncmp(line, "ack ", 4) == 0) {
        printf("purged %d\n", blemesh_scf_ack(line + 4));
        return;
    }
    printf("commands: status | msg <to> <text> | beacon | ack <am>\n");
}

static void console_task(void *arg)
{
    (void)arg;
    static char line[220];
    int n = 0;
    for (;;) {
        int c = fgetc(stdin);
        if (c == EOF) { vTaskDelay(pdMS_TO_TICKS(50)); continue; }
        if (c == '\r' || c == '\n') {
            if (n > 0) { line[n] = 0; console_handle(line); n = 0; }
            continue;
        }
        if (n < (int)sizeof(line) - 1) line[n++] = (char)c;
    }
}

void app_main(void)
{
    /* model_init() initialises NVS + the ST7735 LCD. */
    if (model_init() != ESP_OK) {
        ESP_LOGW(TAG, "model_init failed (no display?)");
    } else {
        tdongle_ui_init(model_get_lcd());
    }

    s_relay_mtx = xSemaphoreCreateMutex();
    if (nimble_port_init() != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init failed");
        return;
    }
    identity_init();

    /* Start the dashboard UI task (owns all LVGL calls). */
    s_ui_q = xQueueCreate(12, sizeof(ui_msg_t));
    xTaskCreate(ui_task, "ui", 4096, NULL, 4, NULL);

    /* WiFi STA + APRS-IS iGate, started BEFORE the BLE host runs so the uplink
     * queue exists for the first frames heard during the WiFi connect window. */
    igate_start();

    /* Street mesh: identity from the iGate callsign (NVS). SD card (if present)
     * persists parked store-and-forward mail across reboots; RAM-only without. */
    blemesh_table_init(s_aprs_call[0] ? s_aprs_call : "TDONGLE");
    const char *scf_path = NULL;
    if (sdcard_init() == ESP_OK && sdcard_is_mounted()) {
        mkdir("/sdcard/mesh", 0775);
        scf_path = "/sdcard/mesh/pending.bin";
        ESP_LOGI(TAG, "mesh: SD store-and-forward at %s", scf_path);
    } else {
        ESP_LOGW(TAG, "mesh: no SD card — store-and-forward is RAM-only");
    }
    blemesh_scf_init(scf_path);
    s_mesh_up = true;

    xTaskCreate(console_task, "console", 4096, NULL, 3, NULL);

    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;
    nimble_port_freertos_init(host_task);

    ESP_LOGI(TAG, "RNS-BLE5 full node + repeater + UI + APRS-IS iGate up");
}
