/**
 * @file geogram_ssh.c
 * @brief SSH server wrapper implementation
 */

#include "geogram_ssh.h"
#include "ssh_server.h"  // From ssh_cli_server component

#include <stdio.h>
#include <string.h>
#include "esp_log.h"
#include "esp_console.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "mbedtls/pk.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/sha256.h"

// Provide stub for if_nametoindex (not available in ESP-IDF lwip)
// This function is used for IPv6 link-local addresses with interface names
// On ESP32, we typically don't need this functionality
unsigned int if_nametoindex(const char *ifname) {
    (void)ifname;
    // Return 1 (first interface) as a reasonable default
    // or 0 to indicate "not found" which libssh handles gracefully
    return 1;
}

static const char *TAG = "geogram_ssh";

// NVS namespace and keys
#define NVS_NAMESPACE       "ssh"
#define NVS_KEY_HOST_KEY    "host_key"
#define NVS_KEY_PASSWORD    "password"

// Host key size (PEM format)
#define HOST_KEY_PEM_SIZE   2048
#define PASSWORD_MAX_LEN    64

static bool s_running = false;
static uint16_t s_port = 0;
static char s_host_key[HOST_KEY_PEM_SIZE] = {0};
static char s_password[PASSWORD_MAX_LEN] = {0};
static char s_fingerprint[64] = {0};

/**
 * @brief Generate an RSA host key
 */
static esp_err_t generate_host_key(char *pem_buf, size_t buf_size) {
    mbedtls_pk_context pk;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context ctr_drbg;
    const char *pers = "ssh_host_key";
    int ret;

    mbedtls_pk_init(&pk);
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&ctr_drbg);

    ESP_LOGI(TAG, "Generating RSA host key (this may take a moment)...");

    // Seed the random number generator
    ret = mbedtls_ctr_drbg_seed(&ctr_drbg, mbedtls_entropy_func, &entropy,
                                 (const unsigned char *)pers, strlen(pers));
    if (ret != 0) {
        ESP_LOGE(TAG, "Failed to seed RNG: -0x%04x", -ret);
        goto cleanup;
    }

    // Setup RSA key
    ret = mbedtls_pk_setup(&pk, mbedtls_pk_info_from_type(MBEDTLS_PK_RSA));
    if (ret != 0) {
        ESP_LOGE(TAG, "Failed to setup PK: -0x%04x", -ret);
        goto cleanup;
    }

    // Generate 2048-bit RSA key
    ret = mbedtls_rsa_gen_key(mbedtls_pk_rsa(pk), mbedtls_ctr_drbg_random,
                               &ctr_drbg, 2048, 65537);
    if (ret != 0) {
        ESP_LOGE(TAG, "Failed to generate RSA key: -0x%04x", -ret);
        goto cleanup;
    }

    // Write key to PEM format
    ret = mbedtls_pk_write_key_pem(&pk, (unsigned char *)pem_buf, buf_size);
    if (ret != 0) {
        ESP_LOGE(TAG, "Failed to write PEM: -0x%04x", -ret);
        goto cleanup;
    }

    ESP_LOGI(TAG, "Host key generated successfully");

cleanup:
    mbedtls_pk_free(&pk);
    mbedtls_entropy_free(&entropy);
    mbedtls_ctr_drbg_free(&ctr_drbg);

    return ret == 0 ? ESP_OK : ESP_FAIL;
}

/**
 * @brief Calculate SHA256 fingerprint of host key
 */
static esp_err_t calculate_fingerprint(const char *pem_key, char *fingerprint) {
    mbedtls_pk_context pk;
    unsigned char der_buf[2048];
    unsigned char hash[32];
    int der_len;

    mbedtls_pk_init(&pk);

    // Parse PEM key
    int ret = mbedtls_pk_parse_key(&pk, (const unsigned char *)pem_key,
                                    strlen(pem_key) + 1, NULL, 0,
                                    NULL, NULL);
    if (ret != 0) {
        mbedtls_pk_free(&pk);
        return ESP_FAIL;
    }

    // Write public key to DER format
    der_len = mbedtls_pk_write_pubkey_der(&pk, der_buf, sizeof(der_buf));
    if (der_len < 0) {
        mbedtls_pk_free(&pk);
        return ESP_FAIL;
    }

    // Hash the DER-encoded public key
    mbedtls_sha256(der_buf + sizeof(der_buf) - der_len, der_len, hash, 0);

    // Format as hex fingerprint
    char *p = fingerprint;
    p += sprintf(p, "SHA256:");
    for (int i = 0; i < 8; i++) {  // First 8 bytes is enough for display
        if (i > 0) *p++ = ':';
        p += sprintf(p, "%02x", hash[i]);
    }

    mbedtls_pk_free(&pk);
    return ESP_OK;
}

/**
 * @brief Load host key from NVS
 */
static esp_err_t load_host_key(void) {
    nvs_handle_t nvs;
    esp_err_t ret = nvs_open(NVS_NAMESPACE, NVS_READONLY, &nvs);
    if (ret != ESP_OK) {
        return ret;
    }

    size_t len = sizeof(s_host_key);
    ret = nvs_get_str(nvs, NVS_KEY_HOST_KEY, s_host_key, &len);
    nvs_close(nvs);

    if (ret == ESP_OK) {
        ESP_LOGI(TAG, "Host key loaded from NVS");
        calculate_fingerprint(s_host_key, s_fingerprint);
    }

    return ret;
}

/**
 * @brief Save host key to NVS
 */
static esp_err_t save_host_key(void) {
    nvs_handle_t nvs;
    esp_err_t ret = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &nvs);
    if (ret != ESP_OK) {
        return ret;
    }

    ret = nvs_set_str(nvs, NVS_KEY_HOST_KEY, s_host_key);
    if (ret == ESP_OK) {
        ret = nvs_commit(nvs);
    }
    nvs_close(nvs);

    if (ret == ESP_OK) {
        ESP_LOGI(TAG, "Host key saved to NVS");
    }

    return ret;
}

/**
 * @brief Load password from NVS
 */
static esp_err_t load_password(void) {
    nvs_handle_t nvs;
    esp_err_t ret = nvs_open(NVS_NAMESPACE, NVS_READONLY, &nvs);
    if (ret != ESP_OK) {
        s_password[0] = '\0';  // No password set
        return ESP_OK;
    }

    size_t len = sizeof(s_password);
    ret = nvs_get_str(nvs, NVS_KEY_PASSWORD, s_password, &len);
    nvs_close(nvs);

    if (ret != ESP_OK) {
        s_password[0] = '\0';  // No password set
    }

    return ESP_OK;
}

/**
 * @brief Shell callback for SSH sessions
 */
static void ssh_shell_callback(ssh_server_session_t *session, void *ctx) {
    (void)ctx;  // Unused

    char line[256];

    printf("\r\n");
    printf("Geogram SSH Console\r\n");
    if (session && session->username) {
        printf("Connected as: %s\r\n", session->username);
    }
    printf("Type 'help' for commands, 'exit' to disconnect\r\n");
    printf("\r\n");

    while (1) {
        printf("geogram> ");
        fflush(stdout);

        if (fgets(line, sizeof(line), stdin) == NULL) {
            break;
        }

        // Remove newline
        size_t len = strlen(line);
        if (len > 0 && line[len - 1] == '\n') {
            line[len - 1] = '\0';
            len--;
        }
        if (len > 0 && line[len - 1] == '\r') {
            line[len - 1] = '\0';
            len--;
        }

        if (len == 0) {
            continue;
        }

        // Check for exit
        if (strcmp(line, "exit") == 0 || strcmp(line, "quit") == 0) {
            printf("Goodbye!\r\n");
            break;
        }

        // Execute command
        int ret;
        esp_err_t err = esp_console_run(line, &ret);

        if (err == ESP_ERR_NOT_FOUND) {
            printf("Unknown command: %s\r\n", line);
            printf("Type 'help' for available commands\r\n");
        } else if (err == ESP_ERR_INVALID_ARG) {
            // Empty command
        } else if (err != ESP_OK) {
            printf("Error: %s\r\n", esp_err_to_name(err));
        }
    }
}

esp_err_t geogram_ssh_start(uint16_t port) {
    if (s_running) {
        ESP_LOGW(TAG, "SSH server already running");
        return ESP_OK;
    }

    // Load or generate host key
    if (load_host_key() != ESP_OK) {
        ESP_LOGI(TAG, "No host key found, generating new one");
        esp_err_t ret = generate_host_key(s_host_key, sizeof(s_host_key));
        if (ret != ESP_OK) {
            ESP_LOGE(TAG, "Failed to generate host key");
            return ret;
        }
        save_host_key();
        calculate_fingerprint(s_host_key, s_fingerprint);
    }

    // Load password (if any)
    load_password();

    // Configure SSH server
    static char port_str[8];  // Static to persist after function returns
    snprintf(port_str, sizeof(port_str), "%d", port);

    ssh_server_config_t config = {
        .bindaddr = "0.0.0.0",
        .port = port_str,
        .debug_level = "0",
        .username = "root",
        .host_key = s_host_key,
#if CONFIG_EXAMPLE_ALLOW_PASSWORD_AUTH
        .password = s_password[0] ? s_password : "",  // Empty = any password accepted
#endif
#if CONFIG_EXAMPLE_ALLOW_PUBLICKEY_AUTH
        .allowed_pubkeys = NULL,
#endif
        .shell_func = ssh_shell_callback,
        .shell_func_ctx = NULL,
        .shell_task_size = 8192,
        .shell_task_kill_on_disconnect = true,
    };

    esp_err_t ret = ssh_server_start(&config);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to start SSH server: %s", esp_err_to_name(ret));
        return ret;
    }

    s_port = port;
    s_running = true;

    ESP_LOGI(TAG, "SSH server started on port %d", port);
    ESP_LOGI(TAG, "Fingerprint: %s", s_fingerprint);
    if (s_password[0] == '\0') {
        ESP_LOGI(TAG, "Passwordless login enabled (use 'ssh password' to set)");
    }

    return ESP_OK;
}

esp_err_t geogram_ssh_stop(void) {
    if (!s_running) {
        return ESP_OK;
    }

    // Note: ssh_cli_server doesn't provide a stop function
    // We just mark it as not running
    s_running = false;
    s_port = 0;

    ESP_LOGI(TAG, "SSH server stopped");
    return ESP_OK;
}

bool geogram_ssh_is_running(void) {
    return s_running;
}

esp_err_t geogram_ssh_set_password(const char *password) {
    nvs_handle_t nvs;

    if (password == NULL || password[0] == '\0') {
        return geogram_ssh_clear_password();
    }

    strncpy(s_password, password, sizeof(s_password) - 1);
    s_password[sizeof(s_password) - 1] = '\0';

    esp_err_t ret = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &nvs);
    if (ret != ESP_OK) {
        return ret;
    }

    ret = nvs_set_str(nvs, NVS_KEY_PASSWORD, s_password);
    if (ret == ESP_OK) {
        ret = nvs_commit(nvs);
    }
    nvs_close(nvs);

    if (ret == ESP_OK) {
        ESP_LOGI(TAG, "SSH password set (restart SSH to apply)");
    }

    return ret;
}

esp_err_t geogram_ssh_clear_password(void) {
    nvs_handle_t nvs;

    s_password[0] = '\0';

    esp_err_t ret = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &nvs);
    if (ret != ESP_OK) {
        return ret;
    }

    ret = nvs_erase_key(nvs, NVS_KEY_PASSWORD);
    if (ret == ESP_ERR_NVS_NOT_FOUND) {
        ret = ESP_OK;  // Already cleared
    }
    if (ret == ESP_OK) {
        ret = nvs_commit(nvs);
    }
    nvs_close(nvs);

    if (ret == ESP_OK) {
        ESP_LOGI(TAG, "SSH password cleared (passwordless login enabled)");
    }

    return ret;
}

bool geogram_ssh_has_password(void) {
    return s_password[0] != '\0';
}

uint16_t geogram_ssh_get_port(void) {
    return s_running ? s_port : 0;
}

esp_err_t geogram_ssh_get_fingerprint(char *fingerprint) {
    if (!s_running || s_fingerprint[0] == '\0') {
        return ESP_ERR_INVALID_STATE;
    }

    strcpy(fingerprint, s_fingerprint);
    return ESP_OK;
}
