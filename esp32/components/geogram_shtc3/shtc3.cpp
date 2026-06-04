#include <stdio.h>
#include <string.h>
#include "shtc3.h"
#include "i2c_bsp.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"

static const char *TAG = "shtc3";

// SHTC3 commands
#define CMD_READ_ID           0xEFC8
#define CMD_SOFT_RESET        0x805D
#define CMD_SLEEP             0xB098
#define CMD_WAKEUP            0x3517
#define CMD_MEAS_T_RH_POLLING 0x7866

// CRC polynomial
#define CRC_POLYNOMIAL        0x31

// Temperature calibration offset (in Celsius) to compensate for ESP32 self-heating
// The sensor is inside the enclosure and reads higher than ambient
// Adjusted based on real-world testing
#define SHTC3_TEMP_OFFSET_C   6.0f

struct shtc3_dev {
    i2c_dev_handle_t i2c_handle;
    uint16_t id;
};

static uint8_t shtc3_calc_crc(const uint8_t *data, uint8_t len) {
    uint8_t crc = 0xFF;

    for (uint8_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (uint8_t bit = 0; bit < 8; bit++) {
            if (crc & 0x80) {
                crc = (crc << 1) ^ CRC_POLYNOMIAL;
            } else {
                crc = crc << 1;
            }
        }
    }
    return crc;
}

static esp_err_t shtc3_send_command(shtc3_handle_t handle, uint16_t cmd) {
    uint8_t buf[2] = {(uint8_t)(cmd >> 8), (uint8_t)(cmd & 0xFF)};
    return i2c_write_bytes(handle->i2c_handle, -1, buf, 2);
}

esp_err_t shtc3_create(i2c_dev_handle_t i2c_handle, shtc3_handle_t *handle) {
    if (i2c_handle == NULL || handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    shtc3_handle_t dev = (shtc3_handle_t)malloc(sizeof(struct shtc3_dev));
    if (dev == NULL) {
        return ESP_ERR_NO_MEM;
    }

    dev->i2c_handle = i2c_handle;
    dev->id = 0;

    // Initialize sensor
    esp_err_t ret = shtc3_wakeup(dev);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to wake up SHTC3");
        free(dev);
        return ret;
    }

    ret = shtc3_soft_reset(dev);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Soft reset failed");
    }
    vTaskDelay(pdMS_TO_TICKS(20));

    ret = shtc3_get_id(dev, &dev->id);
    if (ret == ESP_OK) {
        ESP_LOGI(TAG, "SHTC3 initialized, ID: 0x%04X", dev->id);
    } else {
        ESP_LOGW(TAG, "Failed to read SHTC3 ID");
    }

    *handle = dev;
    return ESP_OK;
}

esp_err_t shtc3_delete(shtc3_handle_t handle) {
    if (handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    shtc3_sleep(handle);
    free(handle);
    return ESP_OK;
}

esp_err_t shtc3_wakeup(shtc3_handle_t handle) {
    if (handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    esp_err_t ret = shtc3_send_command(handle, CMD_WAKEUP);
    if (ret == ESP_OK) {
        vTaskDelay(pdMS_TO_TICKS(50));  // Wait for sensor to wake up
    }
    return ret;
}

esp_err_t shtc3_sleep(shtc3_handle_t handle) {
    if (handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    return shtc3_send_command(handle, CMD_SLEEP);
}

esp_err_t shtc3_soft_reset(shtc3_handle_t handle) {
    if (handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    return shtc3_send_command(handle, CMD_SOFT_RESET);
}

esp_err_t shtc3_get_id(shtc3_handle_t handle, uint16_t *id) {
    if (handle == NULL || id == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    uint8_t cmd[2] = {(uint8_t)(CMD_READ_ID >> 8), (uint8_t)(CMD_READ_ID & 0xFF)};
    uint8_t data[3];

    esp_err_t ret = i2c_write_read(handle->i2c_handle, cmd, 2, data, 3);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to read ID");
        return ret;
    }

    // Verify CRC
    uint8_t crc = shtc3_calc_crc(data, 2);
    if (crc != data[2]) {
        ESP_LOGE(TAG, "ID CRC mismatch");
        return ESP_ERR_INVALID_CRC;
    }

    *id = (data[0] << 8) | data[1];
    return ESP_OK;
}

esp_err_t shtc3_read(shtc3_handle_t handle, shtc3_data_t *data) {
    if (handle == NULL || data == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    // Wake up sensor
    esp_err_t ret = shtc3_wakeup(handle);
    if (ret != ESP_OK) {
        return ret;
    }

    // Send measurement command
    ret = shtc3_send_command(handle, CMD_MEAS_T_RH_POLLING);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to start measurement");
        return ret;
    }

    // Wait for measurement to complete
    vTaskDelay(pdMS_TO_TICKS(20));

    // Read measurement data
    uint8_t raw[6];
    ret = i2c_read_bytes(handle->i2c_handle, -1, raw, 6);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to read measurement");
        shtc3_sleep(handle);
        return ret;
    }

    // Verify temperature CRC
    uint8_t crc = shtc3_calc_crc(raw, 2);
    if (crc != raw[2]) {
        ESP_LOGE(TAG, "Temperature CRC mismatch");
        shtc3_sleep(handle);
        return ESP_ERR_INVALID_CRC;
    }

    // Verify humidity CRC
    crc = shtc3_calc_crc(&raw[3], 2);
    if (crc != raw[5]) {
        ESP_LOGE(TAG, "Humidity CRC mismatch");
        shtc3_sleep(handle);
        return ESP_ERR_INVALID_CRC;
    }

    // Calculate temperature and humidity
    uint16_t raw_temp = (raw[0] << 8) | raw[1];
    uint16_t raw_humi = (raw[3] << 8) | raw[4];

    // Temperature formula: T = -45 + 175 * raw / 65536
    data->temperature = 175.0f * (float)raw_temp / 65536.0f - 45.0f - SHTC3_TEMP_OFFSET_C;

    // Humidity formula: RH = raw / 65536 * 100
    data->humidity = 100.0f * (float)raw_humi / 65536.0f;

    // Put sensor back to sleep
    shtc3_sleep(handle);

    return ESP_OK;
}
