/**
 * @file bech32.h
 * @brief Bech32 encoding for NOSTR npub/nsec
 *
 * Implementation based on BIP-173 specification.
 */

#ifndef GEOGRAM_BECH32_H
#define GEOGRAM_BECH32_H

#include <stdint.h>
#include <stddef.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Encode data as bech32
 *
 * @param hrp Human-readable part (e.g., "npub", "nsec")
 * @param data Raw data bytes
 * @param data_len Length of data
 * @param output Output buffer for bech32 string
 * @param output_len Size of output buffer
 * @return ESP_OK on success
 */
esp_err_t bech32_encode(const char *hrp, const uint8_t *data, size_t data_len,
                        char *output, size_t output_len);

/**
 * @brief Decode bech32 string
 *
 * @param input Bech32-encoded string
 * @param hrp Output buffer for human-readable part (at least 8 bytes)
 * @param data Output buffer for decoded data
 * @param data_len Input: size of data buffer, Output: actual data length
 * @return ESP_OK on success
 */
esp_err_t bech32_decode(const char *input, char *hrp, uint8_t *data, size_t *data_len);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_BECH32_H
