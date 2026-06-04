#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "i2c_bsp.h"
#include "freertos/FreeRTOS.h"
#include "esp_log.h"

static const char *TAG = "i2c_bsp";

static i2c_port_t s_i2c_port = I2C_NUM_0;
static bool s_i2c_initialized = false;
static uint32_t s_i2c_timeout_ticks = 1000 / portTICK_PERIOD_MS;

esp_err_t i2c_bus_init(const i2c_bus_config_t *config)
{
    if (config == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    if (s_i2c_initialized) {
        ESP_LOGW(TAG, "I2C bus already initialized");
        return ESP_OK;
    }

    s_i2c_port = config->port;

    i2c_config_t i2c_conf = {
        .mode = I2C_MODE_MASTER,
        .sda_io_num = config->sda_pin,
        .scl_io_num = config->scl_pin,
        .sda_pullup_en = GPIO_PULLUP_ENABLE,
        .scl_pullup_en = GPIO_PULLUP_ENABLE,
        .master.clk_speed = config->freq_hz ? config->freq_hz : 300000,
    };

    esp_err_t ret = i2c_param_config(s_i2c_port, &i2c_conf);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to configure I2C: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = i2c_driver_install(s_i2c_port, I2C_MODE_MASTER, 0, 0, 0);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to install I2C driver: %s", esp_err_to_name(ret));
        return ret;
    }

    s_i2c_initialized = true;
    ESP_LOGI(TAG, "I2C bus initialized on SDA=%d, SCL=%d", config->sda_pin, config->scl_pin);
    return ESP_OK;
}

esp_err_t i2c_bus_deinit(void)
{
    if (!s_i2c_initialized) {
        return ESP_OK;
    }

    esp_err_t ret = i2c_driver_delete(s_i2c_port);
    if (ret == ESP_OK) {
        s_i2c_initialized = false;
    }
    return ret;
}

esp_err_t i2c_bus_add_device(uint8_t dev_addr, i2c_dev_handle_t *dev_handle)
{
    if (!s_i2c_initialized) {
        ESP_LOGE(TAG, "I2C bus not initialized");
        return ESP_ERR_INVALID_STATE;
    }

    if (dev_handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    i2c_dev_t *dev = malloc(sizeof(i2c_dev_t));
    if (dev == NULL) {
        return ESP_ERR_NO_MEM;
    }

    dev->port = s_i2c_port;
    dev->addr = dev_addr;

    ESP_LOGI(TAG, "Added I2C device at address 0x%02X", dev_addr);
    *dev_handle = dev;
    return ESP_OK;
}

esp_err_t i2c_bus_remove_device(i2c_dev_handle_t dev_handle)
{
    if (dev_handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    free(dev_handle);
    return ESP_OK;
}

esp_err_t i2c_write_bytes(i2c_dev_handle_t dev_handle, int reg, const uint8_t *buf, uint8_t len)
{
    if (dev_handle == NULL || (buf == NULL && len > 0)) {
        return ESP_ERR_INVALID_ARG;
    }

    i2c_cmd_handle_t cmd = i2c_cmd_link_create();

    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (dev_handle->addr << 1) | I2C_MASTER_WRITE, true);

    if (reg >= 0) {
        i2c_master_write_byte(cmd, (uint8_t)reg, true);
    }

    if (len > 0 && buf != NULL) {
        i2c_master_write(cmd, buf, len, true);
    }

    i2c_master_stop(cmd);

    esp_err_t ret = i2c_master_cmd_begin(dev_handle->port, cmd, s_i2c_timeout_ticks);
    i2c_cmd_link_delete(cmd);

    return ret;
}

esp_err_t i2c_read_bytes(i2c_dev_handle_t dev_handle, int reg, uint8_t *buf, uint8_t len)
{
    if (dev_handle == NULL || buf == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    esp_err_t ret;

    if (reg >= 0) {
        // Write register address first
        i2c_cmd_handle_t cmd = i2c_cmd_link_create();
        i2c_master_start(cmd);
        i2c_master_write_byte(cmd, (dev_handle->addr << 1) | I2C_MASTER_WRITE, true);
        i2c_master_write_byte(cmd, (uint8_t)reg, true);
        i2c_master_stop(cmd);
        ret = i2c_master_cmd_begin(dev_handle->port, cmd, s_i2c_timeout_ticks);
        i2c_cmd_link_delete(cmd);

        if (ret != ESP_OK) {
            return ret;
        }
    }

    // Read data
    i2c_cmd_handle_t cmd = i2c_cmd_link_create();
    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (dev_handle->addr << 1) | I2C_MASTER_READ, true);

    if (len > 1) {
        i2c_master_read(cmd, buf, len - 1, I2C_MASTER_ACK);
    }
    i2c_master_read_byte(cmd, &buf[len - 1], I2C_MASTER_NACK);

    i2c_master_stop(cmd);

    ret = i2c_master_cmd_begin(dev_handle->port, cmd, s_i2c_timeout_ticks);
    i2c_cmd_link_delete(cmd);

    return ret;
}

esp_err_t i2c_write_read(i2c_dev_handle_t dev_handle,
                         const uint8_t *write_buf, uint8_t write_len,
                         uint8_t *read_buf, uint8_t read_len)
{
    if (dev_handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    i2c_cmd_handle_t cmd = i2c_cmd_link_create();

    // Write phase
    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (dev_handle->addr << 1) | I2C_MASTER_WRITE, true);

    if (write_len > 0 && write_buf != NULL) {
        i2c_master_write(cmd, write_buf, write_len, true);
    }

    // Repeated start and read phase
    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (dev_handle->addr << 1) | I2C_MASTER_READ, true);

    if (read_len > 1) {
        i2c_master_read(cmd, read_buf, read_len - 1, I2C_MASTER_ACK);
    }
    i2c_master_read_byte(cmd, &read_buf[read_len - 1], I2C_MASTER_NACK);

    i2c_master_stop(cmd);

    esp_err_t ret = i2c_master_cmd_begin(dev_handle->port, cmd, s_i2c_timeout_ticks);
    i2c_cmd_link_delete(cmd);

    return ret;
}
