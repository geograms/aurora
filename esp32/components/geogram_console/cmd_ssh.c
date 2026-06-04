/**
 * @file cmd_ssh.c
 * @brief SSH management CLI commands
 */

#include <stdio.h>
#include <string.h>
#include "esp_console.h"
#include "argtable3/argtable3.h"
#include "geogram_ssh.h"

static struct {
    struct arg_str *action;
    struct arg_str *password;
    struct arg_end *end;
} ssh_args;

static int cmd_ssh(int argc, char **argv)
{
    int nerrors = arg_parse(argc, argv, (void **)&ssh_args);

    if (nerrors != 0) {
        arg_print_errors(stderr, ssh_args.end, argv[0]);
        return 1;
    }

    const char *action = ssh_args.action->sval[0];

    if (strcmp(action, "status") == 0) {
        // Show SSH status
        if (geogram_ssh_is_running()) {
            char fingerprint[64];
            printf("SSH Server: Running\n");
            printf("Port: %d\n", geogram_ssh_get_port());
            if (geogram_ssh_get_fingerprint(fingerprint) == ESP_OK) {
                printf("Fingerprint: %s\n", fingerprint);
            }
            printf("Password: %s\n", geogram_ssh_has_password() ? "Set" : "None (passwordless)");
        } else {
            printf("SSH Server: Not running\n");
        }
    }
    else if (strcmp(action, "password") == 0) {
        // Set or clear password
        if (ssh_args.password->count > 0) {
            const char *pw = ssh_args.password->sval[0];
            if (strcmp(pw, "clear") == 0 || strcmp(pw, "none") == 0) {
                if (geogram_ssh_clear_password() == ESP_OK) {
                    printf("Password cleared - passwordless login enabled\n");
                    printf("Note: Restart device to apply changes\n");
                } else {
                    printf("Failed to clear password\n");
                    return 1;
                }
            } else {
                if (geogram_ssh_set_password(pw) == ESP_OK) {
                    printf("Password set successfully\n");
                    printf("Note: Restart device to apply changes\n");
                } else {
                    printf("Failed to set password\n");
                    return 1;
                }
            }
        } else {
            printf("Usage: ssh password <new_password>\n");
            printf("       ssh password clear\n");
            printf("\nCurrent: %s\n", geogram_ssh_has_password() ? "Password set" : "Passwordless");
        }
    }
    else {
        printf("Unknown action: %s\n", action);
        printf("Usage:\n");
        printf("  ssh status              - Show SSH server status\n");
        printf("  ssh password <pass>     - Set SSH password\n");
        printf("  ssh password clear      - Enable passwordless login\n");
        return 1;
    }

    return 0;
}

void register_ssh_commands(void)
{
    ssh_args.action = arg_str1(NULL, NULL, "<action>", "status | password");
    ssh_args.password = arg_str0(NULL, NULL, "<password>", "new password or 'clear'");
    ssh_args.end = arg_end(2);

    const esp_console_cmd_t cmd = {
        .command = "ssh",
        .help = "SSH server management",
        .hint = NULL,
        .func = &cmd_ssh,
        .argtable = &ssh_args
    };

    esp_console_cmd_register(&cmd);
}
