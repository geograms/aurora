#ifndef SSD1306_H
#define SSD1306_H

#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief SSD1306 display dimensions
 */
#define SSD1306_WIDTH   128
#define SSD1306_HEIGHT  64
#define SSD1306_BUFFER_SIZE (SSD1306_WIDTH * SSD1306_HEIGHT / 8)

/**
 * @brief SSD1306 I2C configuration
 */
typedef struct {
    int sda_pin;
    int scl_pin;
    int rst_pin;        // Reset pin (-1 if not used)
    uint8_t i2c_addr;   // I2C address (typically 0x3C)
} ssd1306_config_t;

/**
 * @brief SSD1306 display handle (opaque type)
 */
typedef struct ssd1306_dev *ssd1306_handle_t;

/**
 * @brief Create an SSD1306 display instance
 *
 * @param config Display configuration
 * @param handle Pointer to store the display handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t ssd1306_create(const ssd1306_config_t *config, ssd1306_handle_t *handle);

/**
 * @brief Initialize the SSD1306 display hardware
 *
 * @param handle Display handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t ssd1306_init(ssd1306_handle_t handle);

/**
 * @brief Delete the SSD1306 display instance
 *
 * @param handle Display handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t ssd1306_delete(ssd1306_handle_t handle);

/**
 * @brief Clear the display buffer to all black (off)
 *
 * @param handle Display handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t ssd1306_clear(ssd1306_handle_t handle);

/**
 * @brief Fill the display buffer to all white (on)
 *
 * @param handle Display handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t ssd1306_fill(ssd1306_handle_t handle);

/**
 * @brief Flush the framebuffer to the display
 *
 * @param handle Display handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t ssd1306_display(ssd1306_handle_t handle);

/**
 * @brief Draw a pixel in the framebuffer
 *
 * @param handle Display handle
 * @param x X coordinate (0-127)
 * @param y Y coordinate (0-63)
 * @param on true = pixel on (white), false = pixel off (black)
 * @return esp_err_t ESP_OK on success
 */
esp_err_t ssd1306_draw_pixel(ssd1306_handle_t handle, uint16_t x, uint16_t y, bool on);

/**
 * @brief Draw a string using the built-in 6x8 font
 *
 * @param handle Display handle
 * @param x X coordinate
 * @param y Y coordinate
 * @param str Null-terminated string
 * @param on true = white text on black, false = black text on white
 * @return esp_err_t ESP_OK on success
 */
esp_err_t ssd1306_draw_string(ssd1306_handle_t handle, uint16_t x, uint16_t y,
                               const char *str, bool on);

/**
 * @brief Set display contrast
 *
 * @param handle Display handle
 * @param contrast Contrast value (0-255)
 * @return esp_err_t ESP_OK on success
 */
esp_err_t ssd1306_set_contrast(ssd1306_handle_t handle, uint8_t contrast);

/**
 * @brief Turn display on or off
 *
 * @param handle Display handle
 * @param on true = display on, false = display off
 * @return esp_err_t ESP_OK on success
 */
esp_err_t ssd1306_set_on(ssd1306_handle_t handle, bool on);

/**
 * @brief Get display width
 *
 * @param handle Display handle
 * @return Display width in pixels
 */
uint16_t ssd1306_get_width(ssd1306_handle_t handle);

/**
 * @brief Get display height
 *
 * @param handle Display handle
 * @return Display height in pixels
 */
uint16_t ssd1306_get_height(ssd1306_handle_t handle);

#ifdef __cplusplus
}
#endif

#endif // SSD1306_H
