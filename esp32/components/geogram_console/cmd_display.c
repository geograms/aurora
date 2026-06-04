/**
 * @file cmd_display.c
 * @brief Display commands for serial console
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "console.h"
#include "esp_console.h"
#include "esp_log.h"
#include "argtable3/argtable3.h"
#include "app_config.h"

#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54
#include "lvgl_port.h"
#endif

static const char *TAG = "cmd_display";

// ============================================================================
// display command (show current state)
// ============================================================================

static int cmd_display_status(int argc, char **argv)
{
#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54
    int rotation = lvgl_port_get_rotation();

    if (console_get_output_mode() == CONSOLE_OUTPUT_JSON) {
        printf("{\"rotation\":%d}\n", rotation);
    } else {
        printf("Display rotation: %d degrees\n", rotation);
    }
#else
    printf("No display available on this board\n");
#endif
    return 0;
}

// ============================================================================
// display_rotate command
// ============================================================================

static struct {
    struct arg_int *angle;
    struct arg_end *end;
} display_rotate_args;

static int cmd_display_rotate(int argc, char **argv)
{
#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54
    int nerrors = arg_parse(argc, argv, (void **)&display_rotate_args);
    if (nerrors != 0) {
        arg_print_errors(stderr, display_rotate_args.end, argv[0]);
        return 1;
    }

    if (display_rotate_args.angle->count > 0) {
        int angle = display_rotate_args.angle->ival[0];

        // Validate angle
        if (angle != 0 && angle != 90 && angle != 180 && angle != 270) {
            printf("Error: Invalid angle. Use 0, 90, 180, or 270\n");
            return 1;
        }

        // Rotate to desired angle
        int current = lvgl_port_get_rotation();
        while (current != angle) {
            lvgl_port_rotate_cw();
            current = lvgl_port_get_rotation();
        }

        printf("Display rotated to %d degrees\n", angle);
    } else {
        // No angle specified - rotate 90 degrees clockwise
        lvgl_port_rotate_cw();
        printf("Display rotated to %d degrees\n", lvgl_port_get_rotation());
    }

    // Refresh display to show changes
    lvgl_port_refresh(false);
#else
    printf("No display available on this board\n");
#endif
    return 0;
}

// ============================================================================
// display_refresh command
// ============================================================================

static struct {
    struct arg_lit *full;
    struct arg_end *end;
} display_refresh_args;

static int cmd_display_refresh(int argc, char **argv)
{
#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54
    int nerrors = arg_parse(argc, argv, (void **)&display_refresh_args);
    if (nerrors != 0) {
        arg_print_errors(stderr, display_refresh_args.end, argv[0]);
        return 1;
    }

    bool full_refresh = display_refresh_args.full->count > 0;

    if (full_refresh) {
        printf("Performing full display refresh...\n");
    } else {
        printf("Performing partial display refresh...\n");
    }

    lvgl_port_refresh(full_refresh);
    printf("Display refreshed\n");
#else
    printf("No display available on this board\n");
#endif
    return 0;
}

// ============================================================================
// Register all display commands
// ============================================================================

void register_display_commands(void)
{
    // display (status)
    const esp_console_cmd_t display_cmd = {
        .command = "display",
        .help = "Show display status",
        .hint = NULL,
        .func = &cmd_display_status,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&display_cmd));

    // display_rotate
    display_rotate_args.angle = arg_int0(NULL, NULL, "[angle]", "Rotation angle (0/90/180/270)");
    display_rotate_args.end = arg_end(1);
    const esp_console_cmd_t display_rotate_cmd = {
        .command = "display_rotate",
        .help = "Rotate display (0/90/180/270 or omit to cycle)",
        .hint = NULL,
        .func = &cmd_display_rotate,
        .argtable = &display_rotate_args,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&display_rotate_cmd));

    // display_refresh
    display_refresh_args.full = arg_lit0("f", "full", "Full refresh (clears ghosting)");
    display_refresh_args.end = arg_end(1);
    const esp_console_cmd_t display_refresh_cmd = {
        .command = "display_refresh",
        .help = "Refresh display (-f for full refresh)",
        .hint = NULL,
        .func = &cmd_display_refresh,
        .argtable = &display_refresh_args,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&display_refresh_cmd));

    ESP_LOGI(TAG, "Display commands registered");
}
