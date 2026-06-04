/**
 * @file cmd_config.c
 * @brief Configuration commands for serial console
 */

#include <stdio.h>
#include <string.h>
#include "console.h"
#include "esp_console.h"
#include "esp_log.h"
#include "argtable3/argtable3.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "station.h"
#include "app_config.h"
#include "wifi_bsp.h"

#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54
#include "sdcard.h"
#include "lvgl_port.h"
#endif

static const char *TAG = "cmd_config";

// ============================================================================
// config show command
// ============================================================================

static int cmd_config_show(int argc, char **argv)
{
    char ssid[33] = {0};
    char password[65] = {0};

    if (console_get_output_mode() == CONSOLE_OUTPUT_JSON) {
        printf("{");
        printf("\"callsign\":\"%s\"", station_get_callsign());
        printf(",\"version\":\"%s\"", GEOGRAM_VERSION);
        printf(",\"board\":\"%s\"", BOARD_NAME);

#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54
        printf(",\"display_rotation\":%d", lvgl_port_get_rotation());
#endif

        if (geogram_wifi_load_credentials(ssid, password) == ESP_OK && strlen(ssid) > 0) {
            printf(",\"wifi_ssid\":\"%s\"", ssid);
        }

        printf("}\n");
    } else {
        printf("\n=== Configuration ===\n\n");

        printf("Callsign: %s\n", station_get_callsign());
        printf("Firmware: %s\n", GEOGRAM_VERSION);
        printf("Board: %s\n", BOARD_NAME);

#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54
        printf("Display rotation: %d degrees\n", lvgl_port_get_rotation());
#endif

        if (geogram_wifi_load_credentials(ssid, password) == ESP_OK && strlen(ssid) > 0) {
            printf("\nWiFi SSID: %s\n", ssid);
            printf("WiFi Password: %s\n", strlen(password) > 0 ? "********" : "(none)");
        } else {
            printf("\nWiFi: Not configured\n");
        }

        printf("\n");
    }

    return 0;
}

// ============================================================================
// config reset command
// ============================================================================

static int cmd_config_reset(int argc, char **argv)
{
    printf("Resetting all configuration...\n");

    // Clear WiFi credentials
    nvs_handle_t nvs;
    if (nvs_open("wifi_config", NVS_READWRITE, &nvs) == ESP_OK) {
        nvs_erase_all(nvs);
        nvs_commit(nvs);
        nvs_close(nvs);
    }

    // Clear display settings
    if (nvs_open("display", NVS_READWRITE, &nvs) == ESP_OK) {
        nvs_erase_all(nvs);
        nvs_commit(nvs);
        nvs_close(nvs);
    }

    // Clear other app settings
    if (nvs_open("geogram", NVS_READWRITE, &nvs) == ESP_OK) {
        nvs_erase_all(nvs);
        nvs_commit(nvs);
        nvs_close(nvs);
    }

    printf("Configuration reset. Reboot to apply changes.\n");
    return 0;
}

// ============================================================================
// nvs_list command (list NVS namespaces)
// ============================================================================

static int cmd_nvs_list(int argc, char **argv)
{
    printf("Known NVS namespaces:\n");
    printf("  wifi_config - WiFi credentials\n");
    printf("  display     - Display settings\n");
    printf("  geogram     - Application settings\n");
    return 0;
}

// ============================================================================
// nvs_get command
// ============================================================================

static struct {
    struct arg_str *namespace;
    struct arg_str *key;
    struct arg_end *end;
} nvs_get_args;

static int cmd_nvs_get(int argc, char **argv)
{
    int nerrors = arg_parse(argc, argv, (void **)&nvs_get_args);
    if (nerrors != 0) {
        arg_print_errors(stderr, nvs_get_args.end, argv[0]);
        return 1;
    }

    const char *ns = nvs_get_args.namespace->sval[0];
    const char *key = nvs_get_args.key->sval[0];

    nvs_handle_t nvs;
    esp_err_t err = nvs_open(ns, NVS_READONLY, &nvs);
    if (err != ESP_OK) {
        printf("Error: Cannot open namespace '%s': %s\n", ns, esp_err_to_name(err));
        return 1;
    }

    // Try to read as different types
    char str_value[256];
    size_t str_len = sizeof(str_value);
    int32_t i32_value;
    uint32_t u32_value;

    err = nvs_get_str(nvs, key, str_value, &str_len);
    if (err == ESP_OK) {
        printf("%s/%s = \"%s\" (string)\n", ns, key, str_value);
        nvs_close(nvs);
        return 0;
    }

    err = nvs_get_i32(nvs, key, &i32_value);
    if (err == ESP_OK) {
        printf("%s/%s = %ld (i32)\n", ns, key, (long)i32_value);
        nvs_close(nvs);
        return 0;
    }

    err = nvs_get_u32(nvs, key, &u32_value);
    if (err == ESP_OK) {
        printf("%s/%s = %lu (u32)\n", ns, key, (unsigned long)u32_value);
        nvs_close(nvs);
        return 0;
    }

    nvs_close(nvs);
    printf("Key '%s' not found in namespace '%s'\n", key, ns);
    return 1;
}

// ============================================================================
// nvs_set command
// ============================================================================

static struct {
    struct arg_str *namespace;
    struct arg_str *key;
    struct arg_str *value;
    struct arg_str *type;
    struct arg_end *end;
} nvs_set_args;

static int cmd_nvs_set(int argc, char **argv)
{
    int nerrors = arg_parse(argc, argv, (void **)&nvs_set_args);
    if (nerrors != 0) {
        arg_print_errors(stderr, nvs_set_args.end, argv[0]);
        return 1;
    }

    const char *ns = nvs_set_args.namespace->sval[0];
    const char *key = nvs_set_args.key->sval[0];
    const char *value = nvs_set_args.value->sval[0];
    const char *type = nvs_set_args.type->count > 0 ? nvs_set_args.type->sval[0] : "str";

    nvs_handle_t nvs;
    esp_err_t err = nvs_open(ns, NVS_READWRITE, &nvs);
    if (err != ESP_OK) {
        printf("Error: Cannot open namespace '%s': %s\n", ns, esp_err_to_name(err));
        return 1;
    }

    if (strcmp(type, "str") == 0 || strcmp(type, "string") == 0) {
        err = nvs_set_str(nvs, key, value);
    } else if (strcmp(type, "i32") == 0) {
        err = nvs_set_i32(nvs, key, atoi(value));
    } else if (strcmp(type, "u32") == 0) {
        err = nvs_set_u32(nvs, key, (uint32_t)atoi(value));
    } else {
        printf("Unknown type: %s (use str, i32, u32)\n", type);
        nvs_close(nvs);
        return 1;
    }

    if (err != ESP_OK) {
        printf("Error setting value: %s\n", esp_err_to_name(err));
        nvs_close(nvs);
        return 1;
    }

    nvs_commit(nvs);
    nvs_close(nvs);

    printf("Set %s/%s = %s\n", ns, key, value);
    return 0;
}

// ============================================================================
// nvs_erase command
// ============================================================================

static struct {
    struct arg_str *namespace;
    struct arg_str *key;
    struct arg_end *end;
} nvs_erase_args;

static int cmd_nvs_erase(int argc, char **argv)
{
    int nerrors = arg_parse(argc, argv, (void **)&nvs_erase_args);
    if (nerrors != 0) {
        arg_print_errors(stderr, nvs_erase_args.end, argv[0]);
        return 1;
    }

    const char *ns = nvs_erase_args.namespace->sval[0];

    nvs_handle_t nvs;
    esp_err_t err = nvs_open(ns, NVS_READWRITE, &nvs);
    if (err != ESP_OK) {
        printf("Error: Cannot open namespace '%s': %s\n", ns, esp_err_to_name(err));
        return 1;
    }

    if (nvs_erase_args.key->count > 0) {
        // Erase specific key
        const char *key = nvs_erase_args.key->sval[0];
        err = nvs_erase_key(nvs, key);
        if (err != ESP_OK) {
            printf("Error erasing key: %s\n", esp_err_to_name(err));
            nvs_close(nvs);
            return 1;
        }
        printf("Erased key '%s' from namespace '%s'\n", key, ns);
    } else {
        // Erase entire namespace
        err = nvs_erase_all(nvs);
        if (err != ESP_OK) {
            printf("Error erasing namespace: %s\n", esp_err_to_name(err));
            nvs_close(nvs);
            return 1;
        }
        printf("Erased all keys from namespace '%s'\n", ns);
    }

    nvs_commit(nvs);
    nvs_close(nvs);
    return 0;
}

// ============================================================================
// Register all config commands
// ============================================================================

void register_config_commands(void)
{
    // config (show)
    const esp_console_cmd_t config_cmd = {
        .command = "config",
        .help = "Show all configuration",
        .hint = NULL,
        .func = &cmd_config_show,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&config_cmd));

    // config_reset
    const esp_console_cmd_t config_reset_cmd = {
        .command = "config_reset",
        .help = "Reset all configuration to defaults",
        .hint = NULL,
        .func = &cmd_config_reset,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&config_reset_cmd));

    // nvs_list
    const esp_console_cmd_t nvs_list_cmd = {
        .command = "nvs_list",
        .help = "List known NVS namespaces",
        .hint = NULL,
        .func = &cmd_nvs_list,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&nvs_list_cmd));

    // nvs_get
    nvs_get_args.namespace = arg_str1(NULL, NULL, "<namespace>", "NVS namespace");
    nvs_get_args.key = arg_str1(NULL, NULL, "<key>", "Key name");
    nvs_get_args.end = arg_end(2);
    const esp_console_cmd_t nvs_get_cmd = {
        .command = "nvs_get",
        .help = "Get NVS value",
        .hint = NULL,
        .func = &cmd_nvs_get,
        .argtable = &nvs_get_args,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&nvs_get_cmd));

    // nvs_set
    nvs_set_args.namespace = arg_str1(NULL, NULL, "<namespace>", "NVS namespace");
    nvs_set_args.key = arg_str1(NULL, NULL, "<key>", "Key name");
    nvs_set_args.value = arg_str1(NULL, NULL, "<value>", "Value");
    nvs_set_args.type = arg_str0("t", "type", "<type>", "Type (str/i32/u32)");
    nvs_set_args.end = arg_end(4);
    const esp_console_cmd_t nvs_set_cmd = {
        .command = "nvs_set",
        .help = "Set NVS value",
        .hint = NULL,
        .func = &cmd_nvs_set,
        .argtable = &nvs_set_args,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&nvs_set_cmd));

    // nvs_erase
    nvs_erase_args.namespace = arg_str1(NULL, NULL, "<namespace>", "NVS namespace");
    nvs_erase_args.key = arg_str0(NULL, NULL, "[key]", "Key to erase (omit for all)");
    nvs_erase_args.end = arg_end(2);
    const esp_console_cmd_t nvs_erase_cmd = {
        .command = "nvs_erase",
        .help = "Erase NVS key or namespace",
        .hint = NULL,
        .func = &cmd_nvs_erase,
        .argtable = &nvs_erase_args,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&nvs_erase_cmd));

    ESP_LOGI(TAG, "Config commands registered");
}
