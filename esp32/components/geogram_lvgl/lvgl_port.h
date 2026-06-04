/**
 * @file lvgl_port.h
 * @brief LVGL port for Geogram e-paper display
 */

#ifndef LVGL_PORT_H
#define LVGL_PORT_H

#include "esp_err.h"
#include "epaper_1in54.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize LVGL and display driver
 *
 * @param epaper_handle E-paper display handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t lvgl_port_init(epaper_1in54_handle_t epaper_handle);

/**
 * @brief Deinitialize LVGL
 *
 * @return esp_err_t ESP_OK on success
 */
esp_err_t lvgl_port_deinit(void);

/**
 * @brief Trigger a display refresh
 *
 * Call this after updating LVGL objects to refresh the e-paper display.
 * Uses partial refresh by default for faster updates.
 *
 * @param full_refresh Set to true for full refresh (clears ghosting)
 */
void lvgl_port_refresh(bool full_refresh);

/**
 * @brief Get LVGL mutex for thread-safe operations
 *
 * Lock this mutex before accessing LVGL objects from non-LVGL tasks.
 *
 * @param timeout_ms Timeout in milliseconds
 * @return true if lock acquired, false on timeout
 */
bool lvgl_port_lock(uint32_t timeout_ms);

/**
 * @brief Release LVGL mutex
 */
void lvgl_port_unlock(void);

/**
 * @brief Rotate the display 90 degrees clockwise
 *
 * Cycles through: 0° -> 90° -> 180° -> 270° -> 0°
 */
void lvgl_port_rotate_cw(void);

/**
 * @brief Get current rotation angle
 *
 * @return Current rotation (0, 90, 180, or 270 degrees)
 */
int lvgl_port_get_rotation(void);

#ifdef __cplusplus
}
#endif

#endif // LVGL_PORT_H
