#include <stdio.h>
#include <string.h>
#include "pcf85063.h"
#include "i2c_bsp.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"

static const char *TAG = "pcf85063";

// PCF85063 register addresses
#define REG_CONTROL_1       0x00
#define REG_CONTROL_2       0x01
#define REG_OFFSET          0x02
#define REG_RAM_BYTE        0x03
#define REG_SECONDS         0x04
#define REG_MINUTES         0x05
#define REG_HOURS           0x06
#define REG_DAYS            0x07
#define REG_WEEKDAYS        0x08
#define REG_MONTHS          0x09
#define REG_YEARS           0x0A
#define REG_SECOND_ALARM    0x0B
#define REG_MINUTE_ALARM    0x0C
#define REG_HOUR_ALARM      0x0D
#define REG_DAY_ALARM       0x0E
#define REG_WEEKDAY_ALARM   0x0F
#define REG_TIMER_VALUE     0x10
#define REG_TIMER_MODE      0x11

struct pcf85063_dev {
    i2c_dev_handle_t i2c_handle;
};

static uint8_t bcd_to_dec(uint8_t bcd) {
    return ((bcd >> 4) * 10) + (bcd & 0x0F);
}

static uint8_t dec_to_bcd(uint8_t dec) {
    return ((dec / 10) << 4) | (dec % 10);
}

esp_err_t pcf85063_create(i2c_dev_handle_t i2c_handle, pcf85063_handle_t *handle) {
    if (i2c_handle == NULL || handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    pcf85063_handle_t dev = (pcf85063_handle_t)malloc(sizeof(struct pcf85063_dev));
    if (dev == NULL) {
        return ESP_ERR_NO_MEM;
    }

    dev->i2c_handle = i2c_handle;

    // Reset the RTC to known state
    uint8_t ctrl1 = 0x00;  // Normal mode, no software reset
    esp_err_t ret = i2c_write_bytes(i2c_handle, REG_CONTROL_1, &ctrl1, 1);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize PCF85063");
        free(dev);
        return ret;
    }

    ESP_LOGI(TAG, "PCF85063 RTC initialized");
    *handle = dev;
    return ESP_OK;
}

esp_err_t pcf85063_delete(pcf85063_handle_t handle) {
    if (handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    free(handle);
    return ESP_OK;
}

esp_err_t pcf85063_set_datetime(pcf85063_handle_t handle, const pcf85063_datetime_t *datetime) {
    if (handle == NULL || datetime == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    uint8_t data[7];
    data[0] = dec_to_bcd(datetime->second) & 0x7F;  // Seconds (bit 7 = OS flag)
    data[1] = dec_to_bcd(datetime->minute);
    data[2] = dec_to_bcd(datetime->hour);
    data[3] = dec_to_bcd(datetime->day);
    data[4] = datetime->weekday & 0x07;
    data[5] = dec_to_bcd(datetime->month);
    data[6] = dec_to_bcd(datetime->year - 2000);  // Years since 2000

    esp_err_t ret = i2c_write_bytes(handle->i2c_handle, REG_SECONDS, data, 7);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to set datetime");
    }
    return ret;
}

esp_err_t pcf85063_get_datetime(pcf85063_handle_t handle, pcf85063_datetime_t *datetime) {
    if (handle == NULL || datetime == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    uint8_t data[7];
    esp_err_t ret = i2c_read_bytes(handle->i2c_handle, REG_SECONDS, data, 7);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to get datetime");
        return ret;
    }

    datetime->second = bcd_to_dec(data[0] & 0x7F);
    datetime->minute = bcd_to_dec(data[1] & 0x7F);
    datetime->hour = bcd_to_dec(data[2] & 0x3F);
    datetime->day = bcd_to_dec(data[3] & 0x3F);
    datetime->weekday = data[4] & 0x07;
    datetime->month = bcd_to_dec(data[5] & 0x1F);
    datetime->year = 2000 + bcd_to_dec(data[6]);

    return ESP_OK;
}

esp_err_t pcf85063_set_alarm_seconds(pcf85063_handle_t handle, uint8_t seconds) {
    if (handle == NULL || seconds > 59) {
        return ESP_ERR_INVALID_ARG;
    }

    uint8_t data = dec_to_bcd(seconds) & 0x7F;  // Enable alarm (bit 7 = 0)
    return i2c_write_bytes(handle->i2c_handle, REG_SECOND_ALARM, &data, 1);
}

esp_err_t pcf85063_set_alarm_minutes(pcf85063_handle_t handle, uint8_t minutes) {
    if (handle == NULL || minutes > 59) {
        return ESP_ERR_INVALID_ARG;
    }

    uint8_t data = dec_to_bcd(minutes) & 0x7F;  // Enable alarm (bit 7 = 0)
    return i2c_write_bytes(handle->i2c_handle, REG_MINUTE_ALARM, &data, 1);
}

esp_err_t pcf85063_clear_alarm(pcf85063_handle_t handle) {
    if (handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    uint8_t ctrl2;
    esp_err_t ret = i2c_read_bytes(handle->i2c_handle, REG_CONTROL_2, &ctrl2, 1);
    if (ret != ESP_OK) {
        return ret;
    }

    ctrl2 &= ~(1 << 3);  // Clear AF (alarm flag)
    return i2c_write_bytes(handle->i2c_handle, REG_CONTROL_2, &ctrl2, 1);
}

esp_err_t pcf85063_enable_alarm_interrupt(pcf85063_handle_t handle, bool enable) {
    if (handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    uint8_t ctrl2;
    esp_err_t ret = i2c_read_bytes(handle->i2c_handle, REG_CONTROL_2, &ctrl2, 1);
    if (ret != ESP_OK) {
        return ret;
    }

    if (enable) {
        ctrl2 |= (1 << 7);  // Enable AIE (alarm interrupt enable)
    } else {
        ctrl2 &= ~(1 << 7);  // Disable AIE
    }

    return i2c_write_bytes(handle->i2c_handle, REG_CONTROL_2, &ctrl2, 1);
}
