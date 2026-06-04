/**
 * @file cmd_wifi.c
 * @brief WiFi commands for serial console
 */

#include <stdio.h>
#include <string.h>
#include "console.h"
#include "esp_console.h"
#include "esp_log.h"
#include "argtable3/argtable3.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "wifi_bsp.h"

static const char *TAG = "cmd_wifi";

// ============================================================================
// wifi command (status)
// ============================================================================

static int cmd_wifi_status(int argc, char **argv)
{
    geogram_wifi_status_t status = geogram_wifi_get_status();
    char ip_str[16] = {0};

    if (console_get_output_mode() == CONSOLE_OUTPUT_JSON) {
        const char *status_str;
        switch (status) {
            case GEOGRAM_WIFI_STATUS_GOT_IP:
                geogram_wifi_get_ip(ip_str);
                status_str = "connected";
                break;
            case GEOGRAM_WIFI_STATUS_CONNECTING:
                status_str = "connecting";
                break;
            case GEOGRAM_WIFI_STATUS_CONNECTED:
                status_str = "connected_no_ip";
                break;
            case GEOGRAM_WIFI_STATUS_AP_STARTED:
                geogram_wifi_get_ap_ip(ip_str);
                status_str = "ap_mode";
                break;
            default:
                status_str = "disconnected";
                break;
        }
        if (strlen(ip_str) > 0) {
            printf("{\"status\":\"%s\",\"ip\":\"%s\"}\n", status_str, ip_str);
        } else {
            printf("{\"status\":\"%s\"}\n", status_str);
        }
    } else {
        switch (status) {
            case GEOGRAM_WIFI_STATUS_GOT_IP:
                geogram_wifi_get_ip(ip_str);
                printf("WiFi: Connected\n");
                printf("IP: %s\n", ip_str);
                break;
            case GEOGRAM_WIFI_STATUS_CONNECTING:
                printf("WiFi: Connecting...\n");
                break;
            case GEOGRAM_WIFI_STATUS_CONNECTED:
                printf("WiFi: Connected (waiting for IP)\n");
                break;
            case GEOGRAM_WIFI_STATUS_AP_STARTED:
                geogram_wifi_get_ap_ip(ip_str);
                printf("WiFi: AP Mode\n");
                printf("AP IP: %s\n", ip_str);
                break;
            default:
                printf("WiFi: Disconnected\n");
                break;
        }
    }

    return 0;
}

// ============================================================================
// wifi connect command
// ============================================================================

static struct {
    struct arg_str *ssid;
    struct arg_str *password;
    struct arg_end *end;
} wifi_connect_args;

static int cmd_wifi_connect(int argc, char **argv)
{
    int nerrors = arg_parse(argc, argv, (void **)&wifi_connect_args);
    if (nerrors != 0) {
        arg_print_errors(stderr, wifi_connect_args.end, argv[0]);
        return 1;
    }

    if (wifi_connect_args.ssid->count == 0) {
        printf("Error: SSID required\n");
        printf("Usage: wifi_connect <ssid> [password]\n");
        return 1;
    }

    const char *ssid = wifi_connect_args.ssid->sval[0];
    const char *password = wifi_connect_args.password->count > 0 ?
                           wifi_connect_args.password->sval[0] : "";

    printf("Connecting to %s...\n", ssid);

    // Save credentials to NVS
    nvs_handle_t nvs;
    esp_err_t err = nvs_open("wifi_config", NVS_READWRITE, &nvs);
    if (err == ESP_OK) {
        nvs_set_str(nvs, "ssid", ssid);
        nvs_set_str(nvs, "password", password);
        nvs_commit(nvs);
        nvs_close(nvs);
        ESP_LOGI(TAG, "WiFi credentials saved");
    }

    // Stop any existing connection
    geogram_wifi_disconnect();

    // Connect
    geogram_wifi_config_t config = {};
    strncpy(config.ssid, ssid, sizeof(config.ssid) - 1);
    strncpy(config.password, password, sizeof(config.password) - 1);
    config.callback = NULL;  // Console doesn't need callbacks

    err = geogram_wifi_connect(&config);
    if (err != ESP_OK) {
        printf("Error: Failed to start connection: %s\n", esp_err_to_name(err));
        return 1;
    }

    return 0;
}

// ============================================================================
// wifi disconnect command
// ============================================================================

static int cmd_wifi_disconnect(int argc, char **argv)
{
    printf("Disconnecting from WiFi...\n");

    esp_err_t err = geogram_wifi_disconnect();
    if (err != ESP_OK) {
        printf("Error: %s\n", esp_err_to_name(err));
        return 1;
    }

    printf("Disconnected\n");
    return 0;
}

// ============================================================================
// wifi clear command (clear saved credentials)
// ============================================================================

static int cmd_wifi_clear(int argc, char **argv)
{
    nvs_handle_t nvs;
    esp_err_t err = nvs_open("wifi_config", NVS_READWRITE, &nvs);
    if (err != ESP_OK) {
        printf("Error: Failed to open NVS: %s\n", esp_err_to_name(err));
        return 1;
    }

    nvs_erase_all(nvs);
    nvs_commit(nvs);
    nvs_close(nvs);

    printf("WiFi credentials cleared\n");
    return 0;
}

// ============================================================================
// wifi saved command (show saved credentials)
// ============================================================================

static int cmd_wifi_saved(int argc, char **argv)
{
    char ssid[33] = {0};
    char password[65] = {0};

    esp_err_t err = geogram_wifi_load_credentials(ssid, password);
    if (err != ESP_OK || strlen(ssid) == 0) {
        printf("No saved WiFi credentials\n");
        return 0;
    }

    if (console_get_output_mode() == CONSOLE_OUTPUT_JSON) {
        printf("{\"ssid\":\"%s\"}\n", ssid);
    } else {
        printf("Saved SSID: %s\n", ssid);
        printf("Password: %s\n", strlen(password) > 0 ? "********" : "(none)");
    }

    return 0;
}

// ============================================================================
// Register all WiFi commands
// ============================================================================

void register_wifi_commands(void)
{
    // wifi (status)
    const esp_console_cmd_t wifi_cmd = {
        .command = "wifi",
        .help = "Show WiFi connection status",
        .hint = NULL,
        .func = &cmd_wifi_status,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&wifi_cmd));

    // wifi_connect
    wifi_connect_args.ssid = arg_str1(NULL, NULL, "<ssid>", "Network SSID");
    wifi_connect_args.password = arg_str0(NULL, NULL, "[password]", "Network password");
    wifi_connect_args.end = arg_end(2);
    const esp_console_cmd_t wifi_connect_cmd = {
        .command = "wifi_connect",
        .help = "Connect to WiFi network",
        .hint = NULL,
        .func = &cmd_wifi_connect,
        .argtable = &wifi_connect_args,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&wifi_connect_cmd));

    // wifi_disconnect
    const esp_console_cmd_t wifi_disconnect_cmd = {
        .command = "wifi_disconnect",
        .help = "Disconnect from WiFi",
        .hint = NULL,
        .func = &cmd_wifi_disconnect,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&wifi_disconnect_cmd));

    // wifi_clear
    const esp_console_cmd_t wifi_clear_cmd = {
        .command = "wifi_clear",
        .help = "Clear saved WiFi credentials",
        .hint = NULL,
        .func = &cmd_wifi_clear,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&wifi_clear_cmd));

    // wifi_saved
    const esp_console_cmd_t wifi_saved_cmd = {
        .command = "wifi_saved",
        .help = "Show saved WiFi credentials",
        .hint = NULL,
        .func = &cmd_wifi_saved,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&wifi_saved_cmd));

    ESP_LOGI(TAG, "WiFi commands registered");
}
