#ifndef GEOGRAM_SDCARD_H
#define GEOGRAM_SDCARD_H

#include <stddef.h>
#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief SD card state
 */
typedef enum {
    SDCARD_STATE_NOT_PRESENT,   // No card inserted
    SDCARD_STATE_MOUNTED,       // Card mounted and ready
    SDCARD_STATE_ERROR          // Card present but error occurred
} sdcard_state_t;

/**
 * @brief SD card information
 */
typedef struct {
    bool mounted;               // True if card is mounted
    float capacity_gb;          // Card capacity in GB
    char mount_point[32];       // Mount point path
} sdcard_info_t;

/**
 * @brief Initialize SD card subsystem
 *
 * Attempts to mount the SD card. If mount fails due to unformatted card,
 * automatically formats it as FAT32.
 *
 * @return ESP_OK on success, error code otherwise
 */
esp_err_t sdcard_init(void);

/**
 * @brief Deinitialize SD card subsystem
 *
 * Unmounts the SD card and releases resources.
 *
 * @return ESP_OK on success
 */
esp_err_t sdcard_deinit(void);

/**
 * @brief Check if SD card is mounted
 *
 * @return true if card is mounted and accessible
 */
bool sdcard_is_mounted(void);

/**
 * @brief Get SD card information
 *
 * @param info Pointer to structure to fill with card info
 * @return ESP_OK on success
 */
esp_err_t sdcard_get_info(sdcard_info_t *info);

/**
 * @brief Get SD card capacity in GB
 *
 * @return Capacity in GB, or 0 if not mounted
 */
float sdcard_get_capacity_gb(void);

/**
 * @brief Write data to a file on the SD card
 *
 * @param path Full path (e.g., "/sdcard/test.txt")
 * @param data Data to write
 * @param len Data length (0 for null-terminated string)
 * @return ESP_OK on success
 */
esp_err_t sdcard_write_file(const char *path, const void *data, size_t len);

/**
 * @brief Read data from a file on the SD card
 *
 * @param path Full path to read
 * @param buffer Buffer to store data
 * @param buffer_size Size of buffer
 * @param bytes_read Actual bytes read (can be NULL)
 * @return ESP_OK on success
 */
esp_err_t sdcard_read_file(const char *path, void *buffer, size_t buffer_size, size_t *bytes_read);

/**
 * @brief Append data to a file on the SD card
 *
 * @param path Full path
 * @param data Data to append
 * @param len Data length (0 for null-terminated string)
 * @return ESP_OK on success
 */
esp_err_t sdcard_append_file(const char *path, const void *data, size_t len);

/**
 * @brief Check if a file exists on the SD card
 *
 * @param path Full path to check
 * @return true if file exists
 */
bool sdcard_file_exists(const char *path);

/**
 * @brief Delete a file from the SD card
 *
 * @param path Full path to delete
 * @return ESP_OK on success
 */
esp_err_t sdcard_delete_file(const char *path);

/**
 * @brief Create a directory on the SD card
 *
 * @param path Full path for new directory
 * @return ESP_OK on success
 */
esp_err_t sdcard_mkdir(const char *path);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_SDCARD_H
