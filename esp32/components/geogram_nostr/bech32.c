/**
 * @file bech32.c
 * @brief Bech32 encoding implementation for NOSTR
 *
 * Based on the reference implementation from BIP-173.
 */

#include "bech32.h"
#include <string.h>
#include <ctype.h>
#include <stdbool.h>

// Bech32 character set
static const char CHARSET[] = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

// Character to value lookup
static const int8_t CHARSET_REV[128] = {
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    15, -1, 10, 17, 21, 20, 26, 30,  7,  5, -1, -1, -1, -1, -1, -1,
    -1, 29, -1, 24, 13, 25,  9,  8, 23, -1, 18, 22, 31, 27, 19, -1,
     1,  0,  3, 16, 11, 28, 12, 14,  6,  4,  2, -1, -1, -1, -1, -1,
    -1, 29, -1, 24, 13, 25,  9,  8, 23, -1, 18, 22, 31, 27, 19, -1,
     1,  0,  3, 16, 11, 28, 12, 14,  6,  4,  2, -1, -1, -1, -1, -1
};

/**
 * @brief Compute bech32 polymod
 */
static uint32_t bech32_polymod(const uint8_t *values, size_t len) {
    uint32_t chk = 1;
    for (size_t i = 0; i < len; i++) {
        uint8_t top = chk >> 25;
        chk = (chk & 0x1ffffff) << 5 ^ values[i];
        if (top & 1) chk ^= 0x3b6a57b2;
        if (top & 2) chk ^= 0x26508e6d;
        if (top & 4) chk ^= 0x1ea119fa;
        if (top & 8) chk ^= 0x3d4233dd;
        if (top & 16) chk ^= 0x2a1462b3;
    }
    return chk;
}

/**
 * @brief Expand HRP for checksum computation
 */
static size_t bech32_hrp_expand(const char *hrp, uint8_t *out) {
    size_t hrp_len = strlen(hrp);
    size_t i;

    for (i = 0; i < hrp_len; i++) {
        out[i] = hrp[i] >> 5;
    }
    out[hrp_len] = 0;
    for (i = 0; i < hrp_len; i++) {
        out[hrp_len + 1 + i] = hrp[i] & 31;
    }

    return hrp_len * 2 + 1;
}

/**
 * @brief Create bech32 checksum
 */
static void bech32_create_checksum(const char *hrp, const uint8_t *data,
                                   size_t data_len, uint8_t *checksum) {
    uint8_t values[128];
    size_t hrp_len = bech32_hrp_expand(hrp, values);

    memcpy(values + hrp_len, data, data_len);
    memset(values + hrp_len + data_len, 0, 6);

    uint32_t polymod = bech32_polymod(values, hrp_len + data_len + 6) ^ 1;

    for (int i = 0; i < 6; i++) {
        checksum[i] = (polymod >> (5 * (5 - i))) & 31;
    }
}

/**
 * @brief Convert 8-bit data to 5-bit groups
 */
static esp_err_t convert_bits(const uint8_t *in, size_t in_len,
                              uint8_t *out, size_t *out_len,
                              int frombits, int tobits, bool pad) {
    uint32_t acc = 0;
    int bits = 0;
    size_t out_idx = 0;
    size_t max_out = *out_len;

    for (size_t i = 0; i < in_len; i++) {
        acc = (acc << frombits) | in[i];
        bits += frombits;
        while (bits >= tobits) {
            bits -= tobits;
            if (out_idx >= max_out) return ESP_ERR_NO_MEM;
            out[out_idx++] = (acc >> bits) & ((1 << tobits) - 1);
        }
    }

    if (pad) {
        if (bits > 0) {
            if (out_idx >= max_out) return ESP_ERR_NO_MEM;
            out[out_idx++] = (acc << (tobits - bits)) & ((1 << tobits) - 1);
        }
    } else if (bits >= frombits || ((acc << (tobits - bits)) & ((1 << tobits) - 1))) {
        return ESP_ERR_INVALID_ARG;
    }

    *out_len = out_idx;
    return ESP_OK;
}

esp_err_t bech32_encode(const char *hrp, const uint8_t *data, size_t data_len,
                        char *output, size_t output_len) {
    if (!hrp || !data || !output) {
        return ESP_ERR_INVALID_ARG;
    }

    size_t hrp_len = strlen(hrp);

    // Convert 8-bit data to 5-bit groups
    uint8_t data5[64];
    size_t data5_len = sizeof(data5);
    esp_err_t ret = convert_bits(data, data_len, data5, &data5_len, 8, 5, true);
    if (ret != ESP_OK) {
        return ret;
    }

    // Check output buffer size
    size_t total_len = hrp_len + 1 + data5_len + 6 + 1; // hrp + "1" + data + checksum + null
    if (output_len < total_len) {
        return ESP_ERR_NO_MEM;
    }

    // Create checksum
    uint8_t checksum[6];
    bech32_create_checksum(hrp, data5, data5_len, checksum);

    // Build output string
    size_t pos = 0;

    // Copy HRP (lowercase)
    for (size_t i = 0; i < hrp_len; i++) {
        output[pos++] = tolower((unsigned char)hrp[i]);
    }

    // Add separator
    output[pos++] = '1';

    // Add data
    for (size_t i = 0; i < data5_len; i++) {
        output[pos++] = CHARSET[data5[i]];
    }

    // Add checksum
    for (int i = 0; i < 6; i++) {
        output[pos++] = CHARSET[checksum[i]];
    }

    output[pos] = '\0';
    return ESP_OK;
}

esp_err_t bech32_decode(const char *input, char *hrp, uint8_t *data, size_t *data_len) {
    if (!input || !hrp || !data || !data_len) {
        return ESP_ERR_INVALID_ARG;
    }

    size_t input_len = strlen(input);
    if (input_len < 8) {  // Minimum: hrp(1) + "1" + data(1) + checksum(6)
        return ESP_ERR_INVALID_ARG;
    }

    // Find separator
    size_t sep_pos = 0;
    for (size_t i = input_len - 1; i > 0; i--) {
        if (input[i] == '1') {
            sep_pos = i;
            break;
        }
    }

    if (sep_pos == 0 || sep_pos + 7 > input_len) {
        return ESP_ERR_INVALID_ARG;
    }

    // Extract HRP
    for (size_t i = 0; i < sep_pos; i++) {
        hrp[i] = tolower((unsigned char)input[i]);
    }
    hrp[sep_pos] = '\0';

    // Decode data portion
    size_t data5_len = input_len - sep_pos - 1;
    uint8_t data5[64];

    for (size_t i = 0; i < data5_len; i++) {
        char c = input[sep_pos + 1 + i];
        if (c < 0 || CHARSET_REV[(unsigned char)c] == -1) {
            return ESP_ERR_INVALID_ARG;
        }
        data5[i] = CHARSET_REV[(unsigned char)c];
    }

    // Verify checksum
    uint8_t values[128];
    size_t hrp_exp_len = bech32_hrp_expand(hrp, values);
    memcpy(values + hrp_exp_len, data5, data5_len);

    if (bech32_polymod(values, hrp_exp_len + data5_len) != 1) {
        return ESP_ERR_INVALID_CRC;
    }

    // Remove checksum from data
    data5_len -= 6;

    // Convert 5-bit to 8-bit
    return convert_bits(data5, data5_len, data, data_len, 5, 8, false);
}
