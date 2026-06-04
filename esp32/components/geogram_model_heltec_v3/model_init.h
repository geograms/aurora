#ifndef MODEL_INIT_H
#define MODEL_INIT_H

#include <stdint.h>
#include "esp_err.h"
#include "ssd1306.h"
#include "sx1262.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize board hardware
 */
esp_err_t model_init(void);

/**
 * @brief Deinitialize board hardware
 */
esp_err_t model_deinit(void);

/**
 * @brief Get OLED display handle
 */
ssd1306_handle_t model_get_display(void);

/**
 * @brief Get LoRa radio handle
 */
sx1262_handle_t model_get_lora(void);

/**
 * @brief Vext power control (powers OLED + LoRa)
 */
void model_vext_on(void);
void model_vext_off(void);

/**
 * @brief LED control (white PWM LED)
 */
void model_led_on(void);
void model_led_off(void);
void model_led_set_brightness(uint8_t brightness);

/**
 * @brief Get battery voltage in volts
 */
float model_get_battery_voltage(void);

#ifdef __cplusplus
}
#endif

#endif // MODEL_INIT_H
