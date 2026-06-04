#ifndef PCF85063_H
#define PCF85063_H

#include <stdint.h>
#include "esp_err.h"
#include "i2c_bsp.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief PCF85063 I2C address
 */
#define PCF85063_I2C_ADDR  0x51

/**
 * @brief RTC datetime structure
 */
typedef struct {
    uint16_t year;
    uint8_t  month;
    uint8_t  day;
    uint8_t  hour;
    uint8_t  minute;
    uint8_t  second;
    uint8_t  weekday;
} pcf85063_datetime_t;

/**
 * @brief PCF85063 handle (opaque type)
 */
typedef struct pcf85063_dev *pcf85063_handle_t;

/**
 * @brief Create PCF85063 RTC instance
 *
 * @param i2c_handle I2C device handle
 * @param handle Pointer to store RTC handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t pcf85063_create(i2c_dev_handle_t i2c_handle, pcf85063_handle_t *handle);

/**
 * @brief Delete PCF85063 RTC instance
 *
 * @param handle RTC handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t pcf85063_delete(pcf85063_handle_t handle);

/**
 * @brief Set RTC date and time
 *
 * @param handle RTC handle
 * @param datetime Datetime to set
 * @return esp_err_t ESP_OK on success
 */
esp_err_t pcf85063_set_datetime(pcf85063_handle_t handle, const pcf85063_datetime_t *datetime);

/**
 * @brief Get RTC date and time
 *
 * @param handle RTC handle
 * @param datetime Pointer to store datetime
 * @return esp_err_t ESP_OK on success
 */
esp_err_t pcf85063_get_datetime(pcf85063_handle_t handle, pcf85063_datetime_t *datetime);

/**
 * @brief Set alarm by seconds
 *
 * @param handle RTC handle
 * @param seconds Seconds for alarm (0-59)
 * @return esp_err_t ESP_OK on success
 */
esp_err_t pcf85063_set_alarm_seconds(pcf85063_handle_t handle, uint8_t seconds);

/**
 * @brief Set alarm by minutes
 *
 * @param handle RTC handle
 * @param minutes Minutes for alarm (0-59)
 * @return esp_err_t ESP_OK on success
 */
esp_err_t pcf85063_set_alarm_minutes(pcf85063_handle_t handle, uint8_t minutes);

/**
 * @brief Clear alarm flag
 *
 * @param handle RTC handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t pcf85063_clear_alarm(pcf85063_handle_t handle);

/**
 * @brief Enable alarm interrupt
 *
 * @param handle RTC handle
 * @param enable Enable or disable
 * @return esp_err_t ESP_OK on success
 */
esp_err_t pcf85063_enable_alarm_interrupt(pcf85063_handle_t handle, bool enable);

#ifdef __cplusplus
}
#endif

#endif // PCF85063_H
