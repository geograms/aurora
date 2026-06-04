#ifndef BOARD_POWER_H
#define BOARD_POWER_H

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize board power management
 *
 * @return esp_err_t ESP_OK on success
 */
esp_err_t board_power_init(void);

/**
 * @brief Turn on e-paper display power
 */
void board_power_epd_on(void);

/**
 * @brief Turn off e-paper display power
 */
void board_power_epd_off(void);

/**
 * @brief Turn on audio power
 */
void board_power_audio_on(void);

/**
 * @brief Turn off audio power
 */
void board_power_audio_off(void);

/**
 * @brief Turn on VBAT measurement power
 */
void board_power_vbat_on(void);

/**
 * @brief Turn off VBAT measurement power
 */
void board_power_vbat_off(void);

/**
 * @brief Turn on backlight
 */
void board_power_backlight_on(void);

/**
 * @brief Turn off backlight
 */
void board_power_backlight_off(void);

/**
 * @brief Turn on backlight for a specified duration (non-blocking)
 *
 * @param duration_ms Duration in milliseconds to keep the backlight on
 */
void board_power_backlight_timed(uint32_t duration_ms);

/**
 * @brief Enter deep sleep with RTC wake-up
 *
 * @param wakeup_time_sec Wake-up time in seconds (0 = use external wake-up only)
 */
void board_power_deep_sleep(uint32_t wakeup_time_sec);

/**
 * @brief Enter low power mode with configurable wake-up sources
 */
void board_power_enable_low_power_mode(void);

#ifdef __cplusplus
}
#endif

#endif // BOARD_POWER_H
