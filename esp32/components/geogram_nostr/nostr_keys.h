/**
 * @file nostr_keys.h
 * @brief NOSTR key generation and management for Geogram
 *
 * Generates secp256k1 key pairs and derives callsigns from npub.
 * Keys are stored in NVS for persistence across reboots.
 */

#ifndef GEOGRAM_NOSTR_KEYS_H
#define GEOGRAM_NOSTR_KEYS_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define NOSTR_PRIVATE_KEY_LEN   32      // secp256k1 private key (32 bytes)
#define NOSTR_PUBLIC_KEY_LEN    32      // x-only public key for Schnorr/BIP-340 (32 bytes)
#define NOSTR_NPUB_LEN          64      // bech32-encoded npub (npub1 + ~58 chars)
#define NOSTR_NSEC_LEN          64      // bech32-encoded nsec
#define NOSTR_CALLSIGN_LEN      7       // X3XXXX + null terminator

/**
 * @brief NOSTR key pair structure
 */
typedef struct {
    uint8_t private_key[NOSTR_PRIVATE_KEY_LEN];     // Raw private key bytes
    uint8_t public_key[NOSTR_PUBLIC_KEY_LEN];       // Raw x-only public key bytes
    char npub[NOSTR_NPUB_LEN];                      // Bech32 encoded public key
    char nsec[NOSTR_NSEC_LEN];                      // Bech32 encoded private key
    char callsign[NOSTR_CALLSIGN_LEN];              // Derived callsign (X3XXXX)
} nostr_keys_t;

/**
 * @brief Initialize the NOSTR keys module
 *
 * Loads existing keys from NVS or generates new ones if not found.
 *
 * @return ESP_OK on success
 */
esp_err_t nostr_keys_init(void);

/**
 * @brief Get the current NOSTR keys
 *
 * @return Pointer to the keys structure (owned by module, do not free)
 */
const nostr_keys_t *nostr_keys_get(void);

/**
 * @brief Get the station callsign (X3XXXX format)
 *
 * @return Null-terminated callsign string
 */
const char *nostr_keys_get_callsign(void);

/**
 * @brief Get the npub (bech32-encoded public key)
 *
 * @return Null-terminated npub string
 */
const char *nostr_keys_get_npub(void);

/**
 * @brief Generate new NOSTR keys
 *
 * Generates a new key pair, saves to NVS, and updates the cached keys.
 * Warning: This will replace any existing keys!
 *
 * @return ESP_OK on success
 */
esp_err_t nostr_keys_generate(void);

/**
 * @brief Check if keys have been initialized
 *
 * @return true if keys are available
 */
bool nostr_keys_available(void);

/**
 * @brief Derive callsign from an npub string
 *
 * Extracts the first 4 characters after "npub1" and creates X3XXXX format.
 *
 * @param npub The bech32-encoded npub string
 * @param callsign Output buffer for callsign (at least NOSTR_CALLSIGN_LEN bytes)
 * @return ESP_OK on success, ESP_ERR_INVALID_ARG if npub is invalid
 */
esp_err_t nostr_keys_derive_callsign(const char *npub, char *callsign);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_NOSTR_KEYS_H
