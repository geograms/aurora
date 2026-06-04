/**
 * @file sdcard.c
 * @brief SD card driver for Geogram ESP32-S3 ePaper board
 *
 * Uses 1-bit SDMMC mode. Automatically formats unformatted cards.
 */

#include <stdio.h>
#include <string.h>
#include <sys/unistd.h>
#include <sys/stat.h>
#include "sdcard.h"
#include "esp_vfs_fat.h"
#include "sdmmc_cmd.h"
#include "driver/sdmmc_host.h"
#include "esp_log.h"

// Default configuration (can be overridden by model_config.h)
#ifndef SDCARD_D0_PIN
#define SDCARD_D0_PIN       GPIO_NUM_40
#endif
#ifndef SDCARD_CLK_PIN
#define SDCARD_CLK_PIN      GPIO_NUM_39
#endif
#ifndef SDCARD_CMD_PIN
#define SDCARD_CMD_PIN      GPIO_NUM_41
#endif
#ifndef SDCARD_MOUNT_POINT
#define SDCARD_MOUNT_POINT  "/sdcard"
#endif

static const char *TAG = "sdcard";

// SD card handle
static sdmmc_card_t *s_card = NULL;
static bool s_mounted = false;

esp_err_t sdcard_init(void)
{
    if (s_mounted) {
        ESP_LOGW(TAG, "SD card already mounted");
        return ESP_OK;
    }

    ESP_LOGI(TAG, "Initializing SD card (1-bit SDMMC mode)");

    // Mount configuration
    esp_vfs_fat_sdmmc_mount_config_t mount_config = {
        .format_if_mount_failed = true,     // Auto-format if unformatted
        .max_files = 5,
        .allocation_unit_size = 16 * 1024   // 16KB allocation unit
    };

    // SDMMC host configuration
    sdmmc_host_t host = SDMMC_HOST_DEFAULT();
    host.max_freq_khz = SDMMC_FREQ_HIGHSPEED;

    // Slot configuration for 1-bit mode
    sdmmc_slot_config_t slot_config = SDMMC_SLOT_CONFIG_DEFAULT();
    slot_config.width = 1;  // 1-bit mode
    slot_config.clk = SDCARD_CLK_PIN;
    slot_config.cmd = SDCARD_CMD_PIN;
    slot_config.d0 = SDCARD_D0_PIN;
    slot_config.flags |= SDMMC_SLOT_FLAG_INTERNAL_PULLUP;

    ESP_LOGI(TAG, "Mounting SD card at %s", SDCARD_MOUNT_POINT);

    esp_err_t ret = esp_vfs_fat_sdmmc_mount(SDCARD_MOUNT_POINT, &host, &slot_config, &mount_config, &s_card);

    if (ret != ESP_OK) {
        if (ret == ESP_FAIL) {
            ESP_LOGE(TAG, "Failed to mount filesystem. Card may be corrupted.");
        } else if (ret == ESP_ERR_NO_MEM) {
            ESP_LOGE(TAG, "Failed to allocate memory for SD card");
        } else {
            ESP_LOGE(TAG, "Failed to initialize SD card: %s", esp_err_to_name(ret));
            ESP_LOGI(TAG, "No SD card inserted or card not supported");
        }
        s_card = NULL;
        return ret;
    }

    s_mounted = true;

    // Print card info
    sdmmc_card_print_info(stdout, s_card);
    ESP_LOGI(TAG, "SD card mounted successfully");
    ESP_LOGI(TAG, "Capacity: %.2f GB", sdcard_get_capacity_gb());

    return ESP_OK;
}

esp_err_t sdcard_deinit(void)
{
    if (!s_mounted) {
        return ESP_OK;
    }

    esp_err_t ret = esp_vfs_fat_sdcard_unmount(SDCARD_MOUNT_POINT, s_card);
    if (ret == ESP_OK) {
        ESP_LOGI(TAG, "SD card unmounted");
        s_card = NULL;
        s_mounted = false;
    } else {
        ESP_LOGE(TAG, "Failed to unmount SD card: %s", esp_err_to_name(ret));
    }

    return ret;
}

bool sdcard_is_mounted(void)
{
    if (!s_mounted || s_card == NULL) {
        return false;
    }

    // Verify card is still accessible
    esp_err_t ret = sdmmc_get_status(s_card);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "SD card not responding");
        return false;
    }

    return true;
}

esp_err_t sdcard_get_info(sdcard_info_t *info)
{
    if (info == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    memset(info, 0, sizeof(sdcard_info_t));
    strncpy(info->mount_point, SDCARD_MOUNT_POINT, sizeof(info->mount_point) - 1);

    if (!sdcard_is_mounted()) {
        info->mounted = false;
        return ESP_OK;
    }

    info->mounted = true;
    info->capacity_gb = sdcard_get_capacity_gb();

    return ESP_OK;
}

float sdcard_get_capacity_gb(void)
{
    if (s_card == NULL) {
        return 0.0f;
    }

    // CSD capacity is in 512-byte sectors
    // Convert to GB: sectors * 512 / (1024^3)
    return (float)(s_card->csd.capacity) / 2048.0f / 1024.0f;
}

esp_err_t sdcard_write_file(const char *path, const void *data, size_t len)
{
    if (path == NULL || data == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    if (!sdcard_is_mounted()) {
        ESP_LOGE(TAG, "SD card not mounted");
        return ESP_ERR_INVALID_STATE;
    }

    FILE *f = fopen(path, "wb");
    if (f == NULL) {
        ESP_LOGE(TAG, "Failed to open file for writing: %s", path);
        return ESP_ERR_NOT_FOUND;
    }

    // If len is 0, treat as null-terminated string
    if (len == 0) {
        len = strlen((const char *)data);
    }

    size_t written = fwrite(data, 1, len, f);
    fclose(f);

    if (written != len) {
        ESP_LOGE(TAG, "Write incomplete: %zu/%zu bytes", written, len);
        return ESP_FAIL;
    }

    ESP_LOGD(TAG, "Wrote %zu bytes to %s", len, path);
    return ESP_OK;
}

esp_err_t sdcard_read_file(const char *path, void *buffer, size_t buffer_size, size_t *bytes_read)
{
    if (path == NULL || buffer == NULL || buffer_size == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    if (!sdcard_is_mounted()) {
        ESP_LOGE(TAG, "SD card not mounted");
        return ESP_ERR_INVALID_STATE;
    }

    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        ESP_LOGW(TAG, "File not found: %s", path);
        return ESP_ERR_NOT_FOUND;
    }

    // Get file size
    fseek(f, 0, SEEK_END);
    long file_size = ftell(f);
    fseek(f, 0, SEEK_SET);

    // Read up to buffer_size bytes
    size_t to_read = (file_size < (long)buffer_size) ? (size_t)file_size : buffer_size;
    size_t read_bytes = fread(buffer, 1, to_read, f);
    fclose(f);

    if (bytes_read != NULL) {
        *bytes_read = read_bytes;
    }

    ESP_LOGD(TAG, "Read %zu bytes from %s", read_bytes, path);
    return ESP_OK;
}

esp_err_t sdcard_append_file(const char *path, const void *data, size_t len)
{
    if (path == NULL || data == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    if (!sdcard_is_mounted()) {
        ESP_LOGE(TAG, "SD card not mounted");
        return ESP_ERR_INVALID_STATE;
    }

    FILE *f = fopen(path, "ab");
    if (f == NULL) {
        ESP_LOGE(TAG, "Failed to open file for appending: %s", path);
        return ESP_ERR_NOT_FOUND;
    }

    // If len is 0, treat as null-terminated string
    if (len == 0) {
        len = strlen((const char *)data);
    }

    size_t written = fwrite(data, 1, len, f);
    fclose(f);

    if (written != len) {
        ESP_LOGE(TAG, "Append incomplete: %zu/%zu bytes", written, len);
        return ESP_FAIL;
    }

    ESP_LOGD(TAG, "Appended %zu bytes to %s", len, path);
    return ESP_OK;
}

bool sdcard_file_exists(const char *path)
{
    if (path == NULL || !sdcard_is_mounted()) {
        return false;
    }

    struct stat st;
    return (stat(path, &st) == 0);
}

esp_err_t sdcard_delete_file(const char *path)
{
    if (path == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    if (!sdcard_is_mounted()) {
        ESP_LOGE(TAG, "SD card not mounted");
        return ESP_ERR_INVALID_STATE;
    }

    if (unlink(path) != 0) {
        ESP_LOGE(TAG, "Failed to delete file: %s", path);
        return ESP_FAIL;
    }

    ESP_LOGD(TAG, "Deleted file: %s", path);
    return ESP_OK;
}

esp_err_t sdcard_mkdir(const char *path)
{
    if (path == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    if (!sdcard_is_mounted()) {
        ESP_LOGE(TAG, "SD card not mounted");
        return ESP_ERR_INVALID_STATE;
    }

    struct stat st;
    if (stat(path, &st) == 0) {
        // Already exists
        return ESP_OK;
    }

    if (mkdir(path, 0755) != 0) {
        ESP_LOGE(TAG, "Failed to create directory: %s", path);
        return ESP_FAIL;
    }

    ESP_LOGD(TAG, "Created directory: %s", path);
    return ESP_OK;
}
