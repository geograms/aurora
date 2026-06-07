/**
 * @file ble_parcel.h
 * @brief BLE parcel protocol (C port of geogram's ble_parcel.dart).
 *
 * Wire-compatible with the Flutter side so desktop <-> ESP32 exchange text over
 * GATT (service 0xFFE0, write 0xFFF1, notify 0xFFF2). A message is split into
 * parcels; APRS frames are tiny so they are a single header parcel.
 *
 *   Header parcel:  [MSG_ID:2][TOTAL:2 BE][CRC32:4 BE][FLAGS:1][DATA...]
 *   Data parcel:    [MSG_ID:2][PARCEL_NUM:2 BE][DATA...]
 *
 * Receipts are JSON ({"msg_id":"XX","status":"complete"|"missing"|...}).
 * This module implements the single-parcel path (TOTAL==1) used by chat-sized
 * messages, plus CRC32 and receipt building.
 */
#ifndef GEOGRAM_BLE_PARCEL_H
#define GEOGRAM_BLE_PARCEL_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BLE_PARCEL_MAX        280
#define BLE_PARCEL_HDR_OVH    9      /* MSG_ID(2)+TOTAL(2)+CRC32(4)+FLAGS(1) */
#define BLE_PARCEL_HDR_CAP    (BLE_PARCEL_MAX - BLE_PARCEL_HDR_OVH) /* 271 */

/** CRC32 (poly 0xEDB88320, init/xor 0xFFFFFFFF) — matches the Dart side. */
uint32_t ble_parcel_crc32(const uint8_t *data, int len);

/** A parsed single-message-complete parcel (header with TOTAL==1). */
typedef struct {
    char     msg_id[3];      /* 2 chars + NUL */
    int      total;          /* total parcels (1 for chat-sized) */
    uint32_t crc;            /* CRC32 of the message payload */
    uint8_t  flags;          /* lower 4 bits = compression (0 = none) */
    const uint8_t *data;     /* payload bytes (points into the input buffer) */
    int      data_len;
} ble_parcel_hdr_t;

/**
 * @brief Parse [bytes,len] as a header parcel. Returns true and fills [out] if
 * it is a well-formed header (TOTAL in 1..999); the data pointer aliases the
 * input. Does not verify CRC (caller does, since for single parcels the
 * payload == data).
 */
bool ble_parcel_parse_header(const uint8_t *bytes, int len, ble_parcel_hdr_t *out);

/**
 * @brief Build a single-parcel header carrying the whole [payload] into [out]
 * (capacity [out_cap]). Returns the byte count, or -1 if it doesn't fit.
 * [msg_id] must be 2 chars; flags 0 (no compression).
 */
int ble_parcel_build_header(const char *msg_id, const uint8_t *payload,
                            int payload_len, uint8_t *out, int out_cap);

/** Build a "complete" receipt JSON for [msg_id] into [out]; returns length. */
int ble_parcel_build_receipt(const char *msg_id, uint8_t *out, int out_cap);

/** True if [bytes,len] looks like a JSON receipt (starts with '{', has msg_id). */
bool ble_parcel_is_receipt(const uint8_t *bytes, int len);

/** Generate a 2-letter (A-Z) message id into [out3] (3 bytes: 2 + NUL). */
void ble_parcel_gen_id(char *out3, uint32_t seed);

#ifdef __cplusplus
}
#endif

#endif /* GEOGRAM_BLE_PARCEL_H */
