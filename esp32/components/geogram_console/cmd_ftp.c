/**
 * @file cmd_ftp.c
 * @brief FTP server management CLI commands
 */

#include <stdio.h>
#include <string.h>
#include "esp_console.h"
#include "argtable3/argtable3.h"
#include "app_config.h"

#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54
#include "ftp_server.h"

static struct {
    struct arg_str *action;
    struct arg_end *end;
} ftp_args;

static int cmd_ftp(int argc, char **argv)
{
    int nerrors = arg_parse(argc, argv, (void **)&ftp_args);

    if (nerrors != 0) {
        arg_print_errors(stderr, ftp_args.end, argv[0]);
        return 1;
    }

    const char *action = ftp_args.action->sval[0];

    if (strcmp(action, "status") == 0) {
        if (ftp_server_is_running()) {
            printf("FTP Server: Running\n");
            printf("Port: %d\n", ftp_server_get_port());

            if (ftp_server_is_client_connected()) {
                char ip[16];
                if (ftp_server_get_client_ip(ip) == ESP_OK) {
                    printf("Client: %s\n", ip);
                }
            } else {
                printf("Client: None\n");
            }
        } else {
            printf("FTP Server: Not running\n");
        }
    }
    else if (strcmp(action, "start") == 0) {
        if (ftp_server_is_running()) {
            printf("FTP server is already running\n");
        } else {
            if (ftp_server_start(FTP_DEFAULT_PORT) == ESP_OK) {
                printf("FTP server started on port %d\n", FTP_DEFAULT_PORT);
            } else {
                printf("Failed to start FTP server\n");
                return 1;
            }
        }
    }
    else if (strcmp(action, "stop") == 0) {
        if (!ftp_server_is_running()) {
            printf("FTP server is not running\n");
        } else {
            ftp_server_stop();
            printf("FTP server stopped\n");
        }
    }
    else {
        printf("Unknown action: %s\n", action);
        printf("Usage:\n");
        printf("  ftp status  - Show FTP server status\n");
        printf("  ftp start   - Start FTP server\n");
        printf("  ftp stop    - Stop FTP server\n");
        return 1;
    }

    return 0;
}

void register_ftp_commands(void)
{
    ftp_args.action = arg_str1(NULL, NULL, "<action>", "status | start | stop");
    ftp_args.end = arg_end(2);

    const esp_console_cmd_t cmd = {
        .command = "ftp",
        .help = "FTP server management",
        .hint = NULL,
        .func = &cmd_ftp,
        .argtable = &ftp_args
    };

    esp_console_cmd_register(&cmd);
}

#else
// No FTP support for boards without SD card
void register_ftp_commands(void)
{
    // FTP commands not available on this board
}
#endif
