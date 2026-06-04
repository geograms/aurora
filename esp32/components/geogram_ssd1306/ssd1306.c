#include <string.h>
#include <stdlib.h>
#include "ssd1306.h"
#include "ssd1306_font.h"
#include "i2c_bsp.h"
#include "driver/gpio.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "ssd1306";

// SSD1306 commands
#define SSD1306_CMD_DISPLAY_OFF         0xAE
#define SSD1306_CMD_DISPLAY_ON          0xAF
#define SSD1306_CMD_SET_MUX_RATIO       0xA8
#define SSD1306_CMD_SET_DISPLAY_OFFSET  0xD3
#define SSD1306_CMD_SET_START_LINE      0x40
#define SSD1306_CMD_SET_SEG_REMAP       0xA1
#define SSD1306_CMD_SET_COM_SCAN_DEC    0xC8
#define SSD1306_CMD_SET_COM_PINS        0xDA
#define SSD1306_CMD_SET_CONTRAST        0x81
#define SSD1306_CMD_ENTIRE_DISPLAY_RAM  0xA4
#define SSD1306_CMD_SET_NORMAL_DISPLAY  0xA6
#define SSD1306_CMD_SET_CLOCK_DIV       0xD5
#define SSD1306_CMD_CHARGE_PUMP         0x8D
#define SSD1306_CMD_SET_MEMORY_MODE     0x20
#define SSD1306_CMD_SET_COLUMN_ADDR     0x21
#define SSD1306_CMD_SET_PAGE_ADDR       0x22

// I2C control bytes
#define SSD1306_I2C_CMD_REG             0x00
#define SSD1306_I2C_DATA_REG            0x40

// Max I2C write chunk (i2c_write_bytes uses uint8_t len, max 255; keep pages at 128)
#define SSD1306_PAGE_CHUNK              128

struct ssd1306_dev {
    ssd1306_config_t config;
    i2c_dev_handle_t i2c_dev;
    uint8_t buffer[SSD1306_BUFFER_SIZE];
};

static esp_err_t ssd1306_send_cmd(ssd1306_handle_t handle, uint8_t cmd)
{
    return i2c_write_bytes(handle->i2c_dev, SSD1306_I2C_CMD_REG, &cmd, 1);
}

static esp_err_t ssd1306_send_cmd2(ssd1306_handle_t handle, uint8_t cmd, uint8_t arg)
{
    uint8_t data[2] = { cmd, arg };
    // Send as two separate commands to avoid multi-byte command issue
    esp_err_t ret = i2c_write_bytes(handle->i2c_dev, SSD1306_I2C_CMD_REG, &data[0], 1);
    if (ret != ESP_OK) return ret;
    return i2c_write_bytes(handle->i2c_dev, SSD1306_I2C_CMD_REG, &data[1], 1);
}

static void ssd1306_hw_reset(ssd1306_handle_t handle)
{
    if (handle->config.rst_pin < 0) return;

    gpio_set_level((gpio_num_t)handle->config.rst_pin, 1);
    vTaskDelay(pdMS_TO_TICKS(10));
    gpio_set_level((gpio_num_t)handle->config.rst_pin, 0);
    vTaskDelay(pdMS_TO_TICKS(10));
    gpio_set_level((gpio_num_t)handle->config.rst_pin, 1);
    vTaskDelay(pdMS_TO_TICKS(100));
}

esp_err_t ssd1306_create(const ssd1306_config_t *config, ssd1306_handle_t *handle)
{
    if (!config || !handle) return ESP_ERR_INVALID_ARG;

    struct ssd1306_dev *dev = calloc(1, sizeof(struct ssd1306_dev));
    if (!dev) return ESP_ERR_NO_MEM;

    dev->config = *config;

    // Configure reset pin if used
    if (config->rst_pin >= 0) {
        gpio_config_t io_conf = {
            .pin_bit_mask = (1ULL << config->rst_pin),
            .mode = GPIO_MODE_OUTPUT,
            .pull_up_en = GPIO_PULLUP_DISABLE,
            .pull_down_en = GPIO_PULLDOWN_DISABLE,
            .intr_type = GPIO_INTR_DISABLE,
        };
        gpio_config(&io_conf);
    }

    // Add I2C device (bus must already be initialized)
    esp_err_t ret = i2c_bus_add_device(config->i2c_addr, &dev->i2c_dev);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to add I2C device at 0x%02X", config->i2c_addr);
        free(dev);
        return ret;
    }

    *handle = dev;
    return ESP_OK;
}

esp_err_t ssd1306_init(ssd1306_handle_t handle)
{
    if (!handle) return ESP_ERR_INVALID_ARG;

    // Hardware reset
    ssd1306_hw_reset(handle);

    // Init sequence for SSD1306 128x64
    esp_err_t ret;

    ret = ssd1306_send_cmd(handle, SSD1306_CMD_DISPLAY_OFF);
    if (ret != ESP_OK) return ret;

    ssd1306_send_cmd2(handle, SSD1306_CMD_SET_CLOCK_DIV, 0x80);
    ssd1306_send_cmd2(handle, SSD1306_CMD_SET_MUX_RATIO, 63);
    ssd1306_send_cmd2(handle, SSD1306_CMD_SET_DISPLAY_OFFSET, 0x00);
    ssd1306_send_cmd(handle, SSD1306_CMD_SET_START_LINE | 0x00);
    ssd1306_send_cmd2(handle, SSD1306_CMD_CHARGE_PUMP, 0x14);  // Enable charge pump
    ssd1306_send_cmd2(handle, SSD1306_CMD_SET_MEMORY_MODE, 0x00);  // Horizontal addressing
    ssd1306_send_cmd(handle, SSD1306_CMD_SET_SEG_REMAP);       // 0xA1: column 127 mapped to SEG0
    ssd1306_send_cmd(handle, SSD1306_CMD_SET_COM_SCAN_DEC);    // 0xC8: scan from COM63 to COM0
    ssd1306_send_cmd2(handle, SSD1306_CMD_SET_COM_PINS, 0x12); // Alternative COM pin config
    ssd1306_send_cmd2(handle, SSD1306_CMD_SET_CONTRAST, 0x7F);
    ssd1306_send_cmd(handle, SSD1306_CMD_ENTIRE_DISPLAY_RAM);
    ssd1306_send_cmd(handle, SSD1306_CMD_SET_NORMAL_DISPLAY);

    // Clear buffer and display
    memset(handle->buffer, 0, SSD1306_BUFFER_SIZE);
    ssd1306_display(handle);

    // Turn on display
    ssd1306_send_cmd(handle, SSD1306_CMD_DISPLAY_ON);

    ESP_LOGI(TAG, "SSD1306 128x64 initialized (I2C 0x%02X)", handle->config.i2c_addr);
    return ESP_OK;
}

esp_err_t ssd1306_delete(ssd1306_handle_t handle)
{
    if (!handle) return ESP_ERR_INVALID_ARG;

    ssd1306_send_cmd(handle, SSD1306_CMD_DISPLAY_OFF);

    if (handle->i2c_dev) {
        i2c_bus_remove_device(handle->i2c_dev);
    }

    free(handle);
    return ESP_OK;
}

esp_err_t ssd1306_clear(ssd1306_handle_t handle)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    memset(handle->buffer, 0x00, SSD1306_BUFFER_SIZE);
    return ESP_OK;
}

esp_err_t ssd1306_fill(ssd1306_handle_t handle)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    memset(handle->buffer, 0xFF, SSD1306_BUFFER_SIZE);
    return ESP_OK;
}

esp_err_t ssd1306_display(ssd1306_handle_t handle)
{
    if (!handle) return ESP_ERR_INVALID_ARG;

    // Set column address range 0-127
    ssd1306_send_cmd(handle, SSD1306_CMD_SET_COLUMN_ADDR);
    ssd1306_send_cmd(handle, 0);
    ssd1306_send_cmd(handle, SSD1306_WIDTH - 1);

    // Set page address range 0-7
    ssd1306_send_cmd(handle, SSD1306_CMD_SET_PAGE_ADDR);
    ssd1306_send_cmd(handle, 0);
    ssd1306_send_cmd(handle, (SSD1306_HEIGHT / 8) - 1);

    // Send framebuffer in page-sized chunks (128 bytes each)
    // i2c_write_bytes uses uint8_t len, max 255
    for (int i = 0; i < SSD1306_BUFFER_SIZE; i += SSD1306_PAGE_CHUNK) {
        esp_err_t ret = i2c_write_bytes(handle->i2c_dev, SSD1306_I2C_DATA_REG,
                                         &handle->buffer[i], SSD1306_PAGE_CHUNK);
        if (ret != ESP_OK) {
            ESP_LOGE(TAG, "Failed to write page at offset %d", i);
            return ret;
        }
    }

    return ESP_OK;
}

esp_err_t ssd1306_draw_pixel(ssd1306_handle_t handle, uint16_t x, uint16_t y, bool on)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    if (x >= SSD1306_WIDTH || y >= SSD1306_HEIGHT) return ESP_ERR_INVALID_ARG;

    uint16_t byte_idx = x + (y / 8) * SSD1306_WIDTH;
    uint8_t bit_mask = 1 << (y & 7);

    if (on) {
        handle->buffer[byte_idx] |= bit_mask;
    } else {
        handle->buffer[byte_idx] &= ~bit_mask;
    }

    return ESP_OK;
}

esp_err_t ssd1306_draw_string(ssd1306_handle_t handle, uint16_t x, uint16_t y,
                               const char *str, bool on)
{
    if (!handle || !str) return ESP_ERR_INVALID_ARG;

    uint16_t cx = x;
    while (*str) {
        uint8_t c = (uint8_t)*str;
        if (c < 32 || c > 127) c = '?';

        const uint8_t *glyph = ssd1306_font_6x8[c - 32];
        for (int col = 0; col < 6; col++) {
            if (cx + col >= SSD1306_WIDTH) break;
            uint8_t column_data = glyph[col];
            for (int row = 0; row < 8; row++) {
                if (y + row >= SSD1306_HEIGHT) break;
                bool pixel = (column_data >> row) & 1;
                ssd1306_draw_pixel(handle, cx + col, y + row, on ? pixel : !pixel);
            }
        }
        cx += 6;
        if (cx >= SSD1306_WIDTH) break;
        str++;
    }

    return ESP_OK;
}

esp_err_t ssd1306_set_contrast(ssd1306_handle_t handle, uint8_t contrast)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    return ssd1306_send_cmd2(handle, SSD1306_CMD_SET_CONTRAST, contrast);
}

esp_err_t ssd1306_set_on(ssd1306_handle_t handle, bool on)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    return ssd1306_send_cmd(handle, on ? SSD1306_CMD_DISPLAY_ON : SSD1306_CMD_DISPLAY_OFF);
}

uint16_t ssd1306_get_width(ssd1306_handle_t handle)
{
    return SSD1306_WIDTH;
}

uint16_t ssd1306_get_height(ssd1306_handle_t handle)
{
    return SSD1306_HEIGHT;
}
