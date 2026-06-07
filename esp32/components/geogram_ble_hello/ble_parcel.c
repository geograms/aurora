/**
 * @file ble_parcel.c
 * @brief BLE parcel protocol (C port of geogram's ble_parcel.dart).
 */

#include "ble_parcel.h"

#include <string.h>

uint32_t ble_parcel_crc32(const uint8_t *data, int len)
{
    uint32_t crc = 0xFFFFFFFFu;
    for (int i = 0; i < len; i++) {
        crc ^= data[i];
        for (int b = 0; b < 8; b++) {
            if (crc & 1u) crc = (crc >> 1) ^ 0xEDB88320u;
            else crc >>= 1;
        }
    }
    return crc ^ 0xFFFFFFFFu;
}

bool ble_parcel_parse_header(const uint8_t *bytes, int len, ble_parcel_hdr_t *out)
{
    if (!bytes || !out || len < BLE_PARCEL_HDR_OVH) return false;
    int total = (bytes[2] << 8) | bytes[3];
    if (total < 1 || total >= 1000) return false;   /* same heuristic as Dart */
    out->msg_id[0] = (char)bytes[0];
    out->msg_id[1] = (char)bytes[1];
    out->msg_id[2] = 0;
    out->total = total;
    out->crc = ((uint32_t)bytes[4] << 24) | ((uint32_t)bytes[5] << 16) |
               ((uint32_t)bytes[6] << 8) | (uint32_t)bytes[7];
    out->flags = bytes[8];
    out->data = bytes + BLE_PARCEL_HDR_OVH;
    out->data_len = len - BLE_PARCEL_HDR_OVH;
    return true;
}

int ble_parcel_build_header(const char *msg_id, const uint8_t *payload,
                            int payload_len, uint8_t *out, int out_cap)
{
    if (!msg_id || !out) return -1;
    if (payload_len < 0 || payload_len > BLE_PARCEL_HDR_CAP) return -1;
    if (out_cap < BLE_PARCEL_HDR_OVH + payload_len) return -1;

    uint32_t crc = ble_parcel_crc32(payload, payload_len);
    out[0] = (uint8_t)msg_id[0];
    out[1] = (uint8_t)msg_id[1];
    out[2] = 0; out[3] = 1;                 /* TOTAL = 1 (single parcel) */
    out[4] = (uint8_t)(crc >> 24);
    out[5] = (uint8_t)(crc >> 16);
    out[6] = (uint8_t)(crc >> 8);
    out[7] = (uint8_t)(crc);
    out[8] = 0;                             /* FLAGS = 0 (no compression) */
    if (payload_len > 0) memcpy(out + BLE_PARCEL_HDR_OVH, payload, payload_len);
    return BLE_PARCEL_HDR_OVH + payload_len;
}

int ble_parcel_build_receipt(const char *msg_id, uint8_t *out, int out_cap)
{
    /* {"msg_id":"XX","status":"complete"} */
    char id0 = msg_id[0], id1 = msg_id[0] ? msg_id[1] : 0;
    int n = 0;
    const char *a = "{\"msg_id\":\"";
    const char *b = "\",\"status\":\"complete\"}";
    int la = (int)strlen(a), lb = (int)strlen(b);
    if (out_cap < la + 2 + lb) return -1;
    memcpy(out + n, a, la); n += la;
    out[n++] = (uint8_t)id0;
    out[n++] = (uint8_t)id1;
    memcpy(out + n, b, lb); n += lb;
    return n;
}

bool ble_parcel_is_receipt(const uint8_t *bytes, int len)
{
    if (!bytes || len < 2 || bytes[0] != '{') return false;
    /* crude: a JSON object that mentions "msg_id" */
    for (int i = 0; i + 6 <= len; i++) {
        if (memcmp(bytes + i, "msg_id", 6) == 0) return true;
    }
    return false;
}

void ble_parcel_gen_id(char *out3, uint32_t seed)
{
    /* two A-Z letters from a simple PRNG seeded by the caller */
    uint32_t s = seed * 1664525u + 1013904223u;
    out3[0] = (char)('A' + (s >> 16) % 26);
    s = s * 1664525u + 1013904223u;
    out3[1] = (char)('A' + (s >> 16) % 26);
    out3[2] = 0;
}
