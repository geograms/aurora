#ifndef MODEL_INIT_H
#define MODEL_INIT_H

#include <stdbool.h>
#include "esp_err.h"
#include "epaper_1in54.h"
#include "pcf85063.h"
#include "shtc3.h"
#include "button_bsp.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize all board hardware
 *
 * @return esp_err_t ESP_OK on success
 */
esp_err_t model_init(void);

/**
 * @brief Deinitialize board hardware
 *
 * @return esp_err_t ESP_OK on success
 */
esp_err_t model_deinit(void);

/**
 * @brief Get e-paper display handle
 *
 * @return epaper_1in54_handle_t Display handle or NULL
 */
epaper_1in54_handle_t model_get_display(void);

/**
 * @brief Get RTC handle
 *
 * @return pcf85063_handle_t RTC handle or NULL
 */
pcf85063_handle_t model_get_rtc(void);

/**
 * @brief Get humidity/temperature sensor handle
 *
 * @return shtc3_handle_t Sensor handle or NULL
 */
shtc3_handle_t model_get_env_sensor(void);

/**
 * @brief Check if SD card is available and mounted
 *
 * @return true if SD card is mounted
 */
bool model_has_sdcard(void);

#ifdef __cplusplus
}
#endif

#endif // MODEL_INIT_H
