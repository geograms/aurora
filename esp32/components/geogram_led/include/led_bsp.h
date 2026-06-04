#ifndef LED_BSP_H
#define LED_BSP_H

#include "esp_err.h"
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief LED colors
 */
typedef enum {
    LED_COLOR_OFF = 0,
    LED_COLOR_RED,
    LED_COLOR_GREEN,
    LED_COLOR_BLUE,
    LED_COLOR_WHITE,
    LED_COLOR_YELLOW,
    LED_COLOR_CYAN,
    LED_COLOR_MAGENTA,
} led_color_t;

/**
 * @brief LED states for status indication
 */
typedef enum {
    LED_STATE_OFF = 0,
    LED_STATE_OK,           // Solid green - system OK
    LED_STATE_ERROR,        // Blinking red - error condition
    LED_STATE_CONNECTING,   // Blinking yellow - connecting
} led_state_t;

/**
 * @brief Initialize the LED driver
 *
 * @param gpio_num GPIO pin number for WS2812 LED
 * @return esp_err_t ESP_OK on success
 */
esp_err_t led_init(int gpio_num);

/**
 * @brief Deinitialize the LED driver
 */
void led_deinit(void);

/**
 * @brief Set LED to a specific color
 *
 * @param color LED color
 * @return esp_err_t ESP_OK on success
 */
esp_err_t led_set_color(led_color_t color);

/**
 * @brief Set LED to a custom RGB color
 *
 * @param r Red component (0-255)
 * @param g Green component (0-255)
 * @param b Blue component (0-255)
 * @return esp_err_t ESP_OK on success
 */
esp_err_t led_set_rgb(uint8_t r, uint8_t g, uint8_t b);

/**
 * @brief Turn LED off
 *
 * @return esp_err_t ESP_OK on success
 */
esp_err_t led_off(void);

/**
 * @brief Set LED state for status indication
 *
 * This starts/stops background blinking tasks as needed.
 *
 * @param state LED state
 * @return esp_err_t ESP_OK on success
 */
esp_err_t led_set_state(led_state_t state);

/**
 * @brief Get current LED state
 *
 * @return led_state_t Current state
 */
led_state_t led_get_state(void);

/**
 * @brief Blink LED a specific number of times
 *
 * This is a non-blocking operation that runs in the background.
 * After blinking, the LED returns to its previous state.
 *
 * @param color Color to blink
 * @param count Number of blinks
 * @param on_ms On duration in ms
 * @param off_ms Off duration in ms
 * @return esp_err_t ESP_OK on success
 */
esp_err_t led_blink(led_color_t color, int count, int on_ms, int off_ms);

/**
 * @brief Notify chat message received (blink blue 3 times)
 *
 * Convenience function that calls led_blink with blue color.
 *
 * @return esp_err_t ESP_OK on success
 */
esp_err_t led_notify_chat(void);

#ifdef __cplusplus
}
#endif

#endif // LED_BSP_H
