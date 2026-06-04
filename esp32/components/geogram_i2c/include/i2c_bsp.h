#ifndef I2C_BSP_H
#define I2C_BSP_H

#include <stdint.h>
#include "driver/i2c.h"
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief I2C device handle structure
 *
 * This is our own handle type for the legacy I2C API.
 */
typedef struct {
    i2c_port_t port;
    uint8_t addr;
} i2c_dev_t;

/**
 * @brief I2C device handle pointer
 */
typedef i2c_dev_t *i2c_dev_handle_t;

/**
 * @brief I2C bus configuration structure
 */
typedef struct {
    int sda_pin;
    int scl_pin;
    i2c_port_t port;
    uint32_t freq_hz;
} i2c_bus_config_t;

/**
 * @brief Initialize the I2C master bus
 *
 * @param config I2C bus configuration
 * @return esp_err_t ESP_OK on success
 */
esp_err_t i2c_bus_init(const i2c_bus_config_t *config);

/**
 * @brief Deinitialize the I2C master bus
 *
 * @return esp_err_t ESP_OK on success
 */
esp_err_t i2c_bus_deinit(void);

/**
 * @brief Add a device to the I2C bus
 *
 * @param dev_addr 7-bit device address
 * @param dev_handle Pointer to store the device handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t i2c_bus_add_device(uint8_t dev_addr, i2c_dev_handle_t *dev_handle);

/**
 * @brief Remove a device from the I2C bus
 *
 * @param dev_handle Device handle to remove
 * @return esp_err_t ESP_OK on success
 */
esp_err_t i2c_bus_remove_device(i2c_dev_handle_t dev_handle);

/**
 * @brief Write data to an I2C device
 *
 * @param dev_handle Device handle
 * @param reg Register address (-1 for no register)
 * @param buf Data buffer
 * @param len Data length
 * @return esp_err_t ESP_OK on success
 */
esp_err_t i2c_write_bytes(i2c_dev_handle_t dev_handle, int reg, const uint8_t *buf, uint8_t len);

/**
 * @brief Read data from an I2C device
 *
 * @param dev_handle Device handle
 * @param reg Register address (-1 for no register)
 * @param buf Data buffer
 * @param len Data length
 * @return esp_err_t ESP_OK on success
 */
esp_err_t i2c_read_bytes(i2c_dev_handle_t dev_handle, int reg, uint8_t *buf, uint8_t len);

/**
 * @brief Write then read from an I2C device
 *
 * @param dev_handle Device handle
 * @param write_buf Write buffer
 * @param write_len Write length
 * @param read_buf Read buffer
 * @param read_len Read length
 * @return esp_err_t ESP_OK on success
 */
esp_err_t i2c_write_read(i2c_dev_handle_t dev_handle,
                         const uint8_t *write_buf, uint8_t write_len,
                         uint8_t *read_buf, uint8_t read_len);

#ifdef __cplusplus
}
#endif

#endif // I2C_BSP_H
