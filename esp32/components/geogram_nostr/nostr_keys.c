/**
 * @file nostr_keys.c
 * @brief NOSTR key generation and management
 *
 * Uses mbedTLS secp256k1 for key generation and bech32 for encoding.
 */

#include "nostr_keys.h"
#include "bech32.h"

#include <string.h>
#include <ctype.h>
#include "esp_log.h"
#include "esp_random.h"
#include "nvs_flash.h"
#include "nvs.h"

#include "mbedtls/ecp.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/entropy.h"

static const char *TAG = "nostr_keys";

// NVS namespace and keys
#define NVS_NAMESPACE       "nostr"
#define NVS_KEY_PRIVKEY     "privkey"
#define NVS_KEY_PUBKEY      "pubkey"

// Singleton keys instance
static nostr_keys_t s_keys = {0};
static bool s_initialized = false;

/**
 * @brief Custom random number generator using ESP32 hardware RNG
 */
static int esp_rng_func(void *ctx, unsigned char *buf, size_t len) {
    (void)ctx;
    esp_fill_random(buf, len);
    return 0;
}

/**
 * @brief Generate secp256k1 key pair
 */
static esp_err_t generate_keypair(uint8_t *private_key, uint8_t *public_key) {
    mbedtls_ecp_group grp;
    mbedtls_mpi d;           // Private key
    mbedtls_ecp_point Q;     // Public key point

    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_ecp_point_init(&Q);

    esp_err_t ret = ESP_FAIL;
    int mbedtls_ret;

    // Load secp256k1 curve
    mbedtls_ret = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256K1);
    if (mbedtls_ret != 0) {
        ESP_LOGE(TAG, "Failed to load secp256k1: -0x%04x", -mbedtls_ret);
        goto cleanup;
    }

    // Generate private key (random scalar)
    mbedtls_ret = mbedtls_ecp_gen_privkey(&grp, &d, esp_rng_func, NULL);
    if (mbedtls_ret != 0) {
        ESP_LOGE(TAG, "Failed to generate private key: -0x%04x", -mbedtls_ret);
        goto cleanup;
    }

    // Calculate public key Q = d * G
    mbedtls_ret = mbedtls_ecp_mul(&grp, &Q, &d, &grp.G, esp_rng_func, NULL);
    if (mbedtls_ret != 0) {
        ESP_LOGE(TAG, "Failed to calculate public key: -0x%04x", -mbedtls_ret);
        goto cleanup;
    }

    // Export private key (32 bytes)
    mbedtls_ret = mbedtls_mpi_write_binary(&d, private_key, NOSTR_PRIVATE_KEY_LEN);
    if (mbedtls_ret != 0) {
        ESP_LOGE(TAG, "Failed to export private key: -0x%04x", -mbedtls_ret);
        goto cleanup;
    }

    // Export public key as uncompressed format first, then extract x-coordinate
    // For BIP-340 Schnorr, we need just the x-coordinate (32 bytes)
    uint8_t pub_uncompressed[65];  // 0x04 + 32-byte X + 32-byte Y
    size_t pub_len = 0;
    mbedtls_ret = mbedtls_ecp_point_write_binary(&grp, &Q, MBEDTLS_ECP_PF_UNCOMPRESSED,
                                                  &pub_len, pub_uncompressed, sizeof(pub_uncompressed));
    if (mbedtls_ret != 0 || pub_len != 65) {
        ESP_LOGE(TAG, "Failed to export public key: -0x%04x", -mbedtls_ret);
        goto cleanup;
    }

    // Copy just the x-coordinate (skip the 0x04 prefix byte)
    memcpy(public_key, pub_uncompressed + 1, NOSTR_PUBLIC_KEY_LEN);

    ret = ESP_OK;
    ESP_LOGI(TAG, "Generated secp256k1 key pair");

cleanup:
    mbedtls_ecp_group_free(&grp);
    mbedtls_mpi_free(&d);
    mbedtls_ecp_point_free(&Q);

    return ret;
}

/**
 * @brief Encode keys as bech32 npub/nsec
 */
static esp_err_t encode_keys(nostr_keys_t *keys) {
    esp_err_t ret;

    // Encode public key as npub
    ret = bech32_encode("npub", keys->public_key, NOSTR_PUBLIC_KEY_LEN,
                        keys->npub, sizeof(keys->npub));
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to encode npub: %s", esp_err_to_name(ret));
        return ret;
    }

    // Encode private key as nsec
    ret = bech32_encode("nsec", keys->private_key, NOSTR_PRIVATE_KEY_LEN,
                        keys->nsec, sizeof(keys->nsec));
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to encode nsec: %s", esp_err_to_name(ret));
        return ret;
    }

    ESP_LOGI(TAG, "npub: %.20s...", keys->npub);

    return ESP_OK;
}

esp_err_t nostr_keys_derive_callsign(const char *npub, char *callsign) {
    if (!npub || !callsign) {
        return ESP_ERR_INVALID_ARG;
    }

    // Verify npub format (must start with "npub1")
    if (strlen(npub) < 9 || strncmp(npub, "npub1", 5) != 0) {
        return ESP_ERR_INVALID_ARG;
    }

    // Extract first 4 characters after "npub1" and uppercase them
    callsign[0] = 'X';
    callsign[1] = '3';
    for (int i = 0; i < 4; i++) {
        callsign[2 + i] = toupper((unsigned char)npub[5 + i]);
    }
    callsign[6] = '\0';

    return ESP_OK;
}

/**
 * @brief Save keys to NVS
 */
static esp_err_t save_keys_to_nvs(const nostr_keys_t *keys) {
    nvs_handle_t nvs;
    esp_err_t ret = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &nvs);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to open NVS: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = nvs_set_blob(nvs, NVS_KEY_PRIVKEY, keys->private_key, NOSTR_PRIVATE_KEY_LEN);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to save private key: %s", esp_err_to_name(ret));
        nvs_close(nvs);
        return ret;
    }

    ret = nvs_set_blob(nvs, NVS_KEY_PUBKEY, keys->public_key, NOSTR_PUBLIC_KEY_LEN);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to save public key: %s", esp_err_to_name(ret));
        nvs_close(nvs);
        return ret;
    }

    ret = nvs_commit(nvs);
    nvs_close(nvs);

    if (ret == ESP_OK) {
        ESP_LOGI(TAG, "Keys saved to NVS");
    }

    return ret;
}

/**
 * @brief Load keys from NVS
 */
static esp_err_t load_keys_from_nvs(nostr_keys_t *keys) {
    nvs_handle_t nvs;
    esp_err_t ret = nvs_open(NVS_NAMESPACE, NVS_READONLY, &nvs);
    if (ret != ESP_OK) {
        return ret;  // No keys stored yet
    }

    size_t len = NOSTR_PRIVATE_KEY_LEN;
    ret = nvs_get_blob(nvs, NVS_KEY_PRIVKEY, keys->private_key, &len);
    if (ret != ESP_OK || len != NOSTR_PRIVATE_KEY_LEN) {
        nvs_close(nvs);
        return ESP_ERR_NOT_FOUND;
    }

    len = NOSTR_PUBLIC_KEY_LEN;
    ret = nvs_get_blob(nvs, NVS_KEY_PUBKEY, keys->public_key, &len);
    if (ret != ESP_OK || len != NOSTR_PUBLIC_KEY_LEN) {
        nvs_close(nvs);
        return ESP_ERR_NOT_FOUND;
    }

    nvs_close(nvs);
    ESP_LOGI(TAG, "Keys loaded from NVS");

    return ESP_OK;
}

esp_err_t nostr_keys_init(void) {
    if (s_initialized) {
        return ESP_OK;
    }

    memset(&s_keys, 0, sizeof(s_keys));

    // Try to load existing keys from NVS
    esp_err_t ret = load_keys_from_nvs(&s_keys);
    if (ret != ESP_OK) {
        ESP_LOGI(TAG, "No existing keys found, generating new ones");
        ret = nostr_keys_generate();
        if (ret != ESP_OK) {
            return ret;
        }
    } else {
        // Encode loaded keys
        ret = encode_keys(&s_keys);
        if (ret != ESP_OK) {
            return ret;
        }

        // Derive callsign
        ret = nostr_keys_derive_callsign(s_keys.npub, s_keys.callsign);
        if (ret != ESP_OK) {
            return ret;
        }
    }

    s_initialized = true;
    ESP_LOGI(TAG, "NOSTR keys initialized - callsign: %s", s_keys.callsign);

    return ESP_OK;
}

esp_err_t nostr_keys_generate(void) {
    esp_err_t ret;

    // Generate new key pair
    ret = generate_keypair(s_keys.private_key, s_keys.public_key);
    if (ret != ESP_OK) {
        return ret;
    }

    // Encode as bech32
    ret = encode_keys(&s_keys);
    if (ret != ESP_OK) {
        return ret;
    }

    // Derive callsign
    ret = nostr_keys_derive_callsign(s_keys.npub, s_keys.callsign);
    if (ret != ESP_OK) {
        return ret;
    }

    // Save to NVS
    ret = save_keys_to_nvs(&s_keys);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Failed to save keys to NVS (keys still usable in RAM)");
    }

    ESP_LOGI(TAG, "Generated new keys - callsign: %s", s_keys.callsign);

    return ESP_OK;
}

const nostr_keys_t *nostr_keys_get(void) {
    return s_initialized ? &s_keys : NULL;
}

const char *nostr_keys_get_callsign(void) {
    return s_initialized ? s_keys.callsign : NULL;
}

const char *nostr_keys_get_npub(void) {
    return s_initialized ? s_keys.npub : NULL;
}

bool nostr_keys_available(void) {
    return s_initialized;
}
