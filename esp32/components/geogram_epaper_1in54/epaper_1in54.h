#ifndef EPAPER_1IN54_H
#define EPAPER_1IN54_H

#include <stdint.h>
#include "driver/spi_master.h"
#include "driver/gpio.h"
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief E-paper display color
 */
typedef enum {
    EPAPER_COLOR_WHITE = 0xFF,
    EPAPER_COLOR_BLACK = 0x00,
} epaper_color_t;

/**
 * @brief E-paper SPI pin configuration
 */
typedef struct {
    gpio_num_t cs;
    gpio_num_t dc;
    gpio_num_t rst;
    gpio_num_t busy;
    gpio_num_t mosi;
    gpio_num_t sclk;
    spi_host_device_t spi_host;
} epaper_spi_config_t;

/**
 * @brief E-paper display handle (opaque type)
 */
typedef struct epaper_1in54_dev *epaper_1in54_handle_t;

/**
 * @brief Create and initialize the 1.54" e-paper display
 *
 * @param config SPI pin configuration
 * @param handle Pointer to store the display handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t epaper_1in54_create(const epaper_spi_config_t *config, epaper_1in54_handle_t *handle);

/**
 * @brief Delete the e-paper display instance
 *
 * @param handle Display handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t epaper_1in54_delete(epaper_1in54_handle_t handle);

/**
 * @brief Initialize the display for full refresh
 *
 * @param handle Display handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t epaper_1in54_init(epaper_1in54_handle_t handle);

/**
 * @brief Initialize the display for partial refresh
 *
 * @param handle Display handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t epaper_1in54_init_partial(epaper_1in54_handle_t handle);

/**
 * @brief Clear the display buffer to white
 *
 * @param handle Display handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t epaper_1in54_clear(epaper_1in54_handle_t handle);

/**
 * @brief Refresh the display with buffer contents (full refresh)
 *
 * @param handle Display handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t epaper_1in54_refresh(epaper_1in54_handle_t handle);

/**
 * @brief Partial refresh the display
 *
 * @param handle Display handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t epaper_1in54_refresh_partial(epaper_1in54_handle_t handle);

/**
 * @brief Draw a pixel to the buffer
 *
 * @param handle Display handle
 * @param x X coordinate
 * @param y Y coordinate
 * @param color Pixel color
 * @return esp_err_t ESP_OK on success
 */
esp_err_t epaper_1in54_draw_pixel(epaper_1in54_handle_t handle, uint16_t x, uint16_t y, epaper_color_t color);

/**
 * @brief Get the display buffer
 *
 * @param handle Display handle
 * @param buffer Pointer to store buffer address
 * @param len Pointer to store buffer length
 * @return esp_err_t ESP_OK on success
 */
esp_err_t epaper_1in54_get_buffer(epaper_1in54_handle_t handle, uint8_t **buffer, size_t *len);

/**
 * @brief Get display width
 *
 * @param handle Display handle
 * @return Display width in pixels
 */
uint16_t epaper_1in54_get_width(epaper_1in54_handle_t handle);

/**
 * @brief Get display height
 *
 * @param handle Display handle
 * @return Display height in pixels
 */
uint16_t epaper_1in54_get_height(epaper_1in54_handle_t handle);

#ifdef __cplusplus
}
#endif

#endif // EPAPER_1IN54_H
