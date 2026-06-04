#ifndef SHTC3_H
#define SHTC3_H

#include <stdint.h>
#include "esp_err.h"
#include "i2c_bsp.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief SHTC3 I2C address
 */
#define SHTC3_I2C_ADDR  0x70

/**
 * @brief SHTC3 sensor data
 */
typedef struct {
    float temperature;  // Celsius
    float humidity;     // Percentage (0-100)
} shtc3_data_t;

/**
 * @brief SHTC3 handle (opaque type)
 */
typedef struct shtc3_dev *shtc3_handle_t;

/**
 * @brief Create SHTC3 sensor instance
 *
 * @param i2c_handle I2C device handle
 * @param handle Pointer to store sensor handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t shtc3_create(i2c_dev_handle_t i2c_handle, shtc3_handle_t *handle);

/**
 * @brief Delete SHTC3 sensor instance
 *
 * @param handle Sensor handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t shtc3_delete(shtc3_handle_t handle);

/**
 * @brief Read temperature and humidity
 *
 * @param handle Sensor handle
 * @param data Pointer to store sensor data
 * @return esp_err_t ESP_OK on success
 */
esp_err_t shtc3_read(shtc3_handle_t handle, shtc3_data_t *data);

/**
 * @brief Wake up the sensor from sleep mode
 *
 * @param handle Sensor handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t shtc3_wakeup(shtc3_handle_t handle);

/**
 * @brief Put the sensor into sleep mode
 *
 * @param handle Sensor handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t shtc3_sleep(shtc3_handle_t handle);

/**
 * @brief Perform soft reset
 *
 * @param handle Sensor handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t shtc3_soft_reset(shtc3_handle_t handle);

/**
 * @brief Get sensor ID
 *
 * @param handle Sensor handle
 * @param id Pointer to store ID
 * @return esp_err_t ESP_OK on success
 */
esp_err_t shtc3_get_id(shtc3_handle_t handle, uint16_t *id);

#ifdef __cplusplus
}
#endif

#endif // SHTC3_H
