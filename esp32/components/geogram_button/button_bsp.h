#ifndef BUTTON_BSP_H
#define BUTTON_BSP_H

#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"
#include "driver/gpio.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Button event types
 */
typedef enum {
    BUTTON_EVENT_NONE = 0,
    BUTTON_EVENT_PRESSED,
    BUTTON_EVENT_RELEASED,
    BUTTON_EVENT_CLICK,
    BUTTON_EVENT_DOUBLE_CLICK,
    BUTTON_EVENT_LONG_PRESS,
} button_event_t;

/**
 * @brief Button configuration
 */
typedef struct {
    gpio_num_t gpio;
    bool active_low;          // true if button is active low
    uint32_t debounce_ms;     // Debounce time in ms
    uint32_t long_press_ms;   // Long press threshold in ms
} button_config_t;

/**
 * @brief Button event callback
 */
typedef void (*button_callback_t)(gpio_num_t gpio, button_event_t event, void *user_data);

/**
 * @brief Button handle (opaque type)
 */
typedef struct button_dev *button_handle_t;

/**
 * @brief Create and register a button
 *
 * @param config Button configuration
 * @param callback Event callback function
 * @param user_data User data passed to callback
 * @param handle Pointer to store button handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t button_create(const button_config_t *config, button_callback_t callback,
                        void *user_data, button_handle_t *handle);

/**
 * @brief Delete a button
 *
 * @param handle Button handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t button_delete(button_handle_t handle);

/**
 * @brief Get current button state
 *
 * @param handle Button handle
 * @return true if button is pressed
 */
bool button_is_pressed(button_handle_t handle);

/**
 * @brief Initialize button subsystem
 *
 * @return esp_err_t ESP_OK on success
 */
esp_err_t button_init(void);

/**
 * @brief Deinitialize button subsystem
 *
 * @return esp_err_t ESP_OK on success
 */
esp_err_t button_deinit(void);

#ifdef __cplusplus
}
#endif

#endif // BUTTON_BSP_H
