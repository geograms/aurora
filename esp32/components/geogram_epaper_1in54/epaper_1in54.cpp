#include <stdio.h>
#include <string.h>
#include "epaper_1in54.h"
#include "lut_tables.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_heap_caps.h"
#include "esp_log.h"

static const char *TAG = "epaper_1in54";

#define EPD_WIDTH  200
#define EPD_HEIGHT 200
#define EPD_BUFFER_SIZE (EPD_WIDTH * EPD_HEIGHT / 8)

struct epaper_1in54_dev {
    epaper_spi_config_t config;
    spi_device_handle_t spi;
    uint8_t *buffer;
    uint16_t width;
    uint16_t height;
};

// Private helper functions
static void epd_set_cs(epaper_1in54_handle_t handle, int level) {
    gpio_set_level(handle->config.cs, level);
}

static void epd_set_dc(epaper_1in54_handle_t handle, int level) {
    gpio_set_level(handle->config.dc, level);
}

static void epd_set_rst(epaper_1in54_handle_t handle, int level) {
    gpio_set_level(handle->config.rst, level);
}

static void epd_wait_busy(epaper_1in54_handle_t handle) {
    while (gpio_get_level(handle->config.busy) == 1) {
        vTaskDelay(pdMS_TO_TICKS(5));
    }
}

static void epd_spi_send_byte(epaper_1in54_handle_t handle, uint8_t data) {
    spi_transaction_t t = {};
    t.length = 8;
    t.tx_buffer = &data;
    spi_device_polling_transmit(handle->spi, &t);
}

static void epd_send_command(epaper_1in54_handle_t handle, uint8_t cmd) {
    epd_set_dc(handle, 0);
    epd_set_cs(handle, 0);
    epd_spi_send_byte(handle, cmd);
    epd_set_cs(handle, 1);
}

static void epd_send_data(epaper_1in54_handle_t handle, uint8_t data) {
    epd_set_dc(handle, 1);
    epd_set_cs(handle, 0);
    epd_spi_send_byte(handle, data);
    epd_set_cs(handle, 1);
}

static void epd_send_data_buffer(epaper_1in54_handle_t handle, const uint8_t *buf, int len) {
    epd_set_dc(handle, 1);
    epd_set_cs(handle, 0);

    spi_transaction_t t = {};
    t.length = 8 * len;
    t.tx_buffer = buf;
    spi_device_polling_transmit(handle->spi, &t);

    epd_set_cs(handle, 1);
}

static void epd_set_window(epaper_1in54_handle_t handle, uint16_t x_start, uint16_t y_start,
                           uint16_t x_end, uint16_t y_end) {
    epd_send_command(handle, 0x44);  // SET_RAM_X_ADDRESS_START_END_POSITION
    epd_send_data(handle, (x_start >> 3) & 0xFF);
    epd_send_data(handle, (x_end >> 3) & 0xFF);

    epd_send_command(handle, 0x45);  // SET_RAM_Y_ADDRESS_START_END_POSITION
    epd_send_data(handle, y_start & 0xFF);
    epd_send_data(handle, (y_start >> 8) & 0xFF);
    epd_send_data(handle, y_end & 0xFF);
    epd_send_data(handle, (y_end >> 8) & 0xFF);
}

static void epd_set_cursor(epaper_1in54_handle_t handle, uint16_t x, uint16_t y) {
    epd_send_command(handle, 0x4E);  // SET_RAM_X_ADDRESS_COUNTER
    epd_send_data(handle, x & 0xFF);

    epd_send_command(handle, 0x4F);  // SET_RAM_Y_ADDRESS_COUNTER
    epd_send_data(handle, y & 0xFF);
    epd_send_data(handle, (y >> 8) & 0xFF);
}

static void epd_set_lut(epaper_1in54_handle_t handle, const uint8_t *lut) {
    epd_send_command(handle, 0x32);
    epd_send_data_buffer(handle, lut, 153);
    epd_wait_busy(handle);

    epd_send_command(handle, 0x3F);
    epd_send_data(handle, lut[153]);

    epd_send_command(handle, 0x03);
    epd_send_data(handle, lut[154]);

    epd_send_command(handle, 0x04);
    epd_send_data(handle, lut[155]);
    epd_send_data(handle, lut[156]);
    epd_send_data(handle, lut[157]);

    epd_send_command(handle, 0x2C);
    epd_send_data(handle, lut[158]);
}

static void epd_turn_on_display(epaper_1in54_handle_t handle) {
    epd_send_command(handle, 0x22);
    epd_send_data(handle, 0xC7);
    epd_send_command(handle, 0x20);
    epd_wait_busy(handle);
}

static void epd_turn_on_display_partial(epaper_1in54_handle_t handle) {
    epd_send_command(handle, 0x22);
    epd_send_data(handle, 0xCF);
    epd_send_command(handle, 0x20);
    epd_wait_busy(handle);
}

static void epd_hw_reset(epaper_1in54_handle_t handle) {
    epd_set_rst(handle, 1);
    vTaskDelay(pdMS_TO_TICKS(50));
    epd_set_rst(handle, 0);
    vTaskDelay(pdMS_TO_TICKS(20));
    epd_set_rst(handle, 1);
    vTaskDelay(pdMS_TO_TICKS(50));
}

// Public API implementation
esp_err_t epaper_1in54_create(const epaper_spi_config_t *config, epaper_1in54_handle_t *handle) {
    if (config == NULL || handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    epaper_1in54_handle_t dev = (epaper_1in54_handle_t)malloc(sizeof(struct epaper_1in54_dev));
    if (dev == NULL) {
        return ESP_ERR_NO_MEM;
    }

    memcpy(&dev->config, config, sizeof(epaper_spi_config_t));
    dev->width = EPD_WIDTH;
    dev->height = EPD_HEIGHT;

    // Allocate buffer in SPIRAM if available, fallback to internal RAM
#if HAS_PSRAM
    dev->buffer = (uint8_t *)heap_caps_malloc(EPD_BUFFER_SIZE, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (dev->buffer == NULL) {
        dev->buffer = (uint8_t *)malloc(EPD_BUFFER_SIZE);
    }
#else
    dev->buffer = (uint8_t *)malloc(EPD_BUFFER_SIZE);
#endif
    if (dev->buffer == NULL) {
        free(dev);
        return ESP_ERR_NO_MEM;
    }

    // Initialize GPIO
    gpio_config_t gpio_conf = {};
    gpio_conf.intr_type = GPIO_INTR_DISABLE;
    gpio_conf.pin_bit_mask = (1ULL << config->cs) | (1ULL << config->dc) | (1ULL << config->rst);
    gpio_conf.mode = GPIO_MODE_OUTPUT;
    gpio_conf.pull_up_en = GPIO_PULLUP_ENABLE;
    gpio_conf.pull_down_en = GPIO_PULLDOWN_DISABLE;
    gpio_config(&gpio_conf);

    gpio_conf.pin_bit_mask = (1ULL << config->busy);
    gpio_conf.mode = GPIO_MODE_INPUT;
    gpio_config(&gpio_conf);

    epd_set_rst(dev, 1);

    // Initialize SPI
    spi_bus_config_t buscfg = {};
    buscfg.miso_io_num = -1;
    buscfg.mosi_io_num = config->mosi;
    buscfg.sclk_io_num = config->sclk;
    buscfg.quadwp_io_num = -1;
    buscfg.quadhd_io_num = -1;
    buscfg.max_transfer_sz = EPD_WIDTH * EPD_HEIGHT;

    esp_err_t ret = spi_bus_initialize(config->spi_host, &buscfg, SPI_DMA_CH_AUTO);
    if (ret != ESP_OK) {
        free(dev->buffer);
        free(dev);
        return ret;
    }

    spi_device_interface_config_t devcfg = {};
    devcfg.clock_speed_hz = 40 * 1000 * 1000;
    devcfg.mode = 0;
    devcfg.spics_io_num = -1;  // Manual CS control
    devcfg.queue_size = 7;

    ret = spi_bus_add_device(config->spi_host, &devcfg, &dev->spi);
    if (ret != ESP_OK) {
        spi_bus_free(config->spi_host);
        free(dev->buffer);
        free(dev);
        return ret;
    }

    ESP_LOGI(TAG, "E-paper 1.54\" display created");
    *handle = dev;
    return ESP_OK;
}

esp_err_t epaper_1in54_delete(epaper_1in54_handle_t handle) {
    if (handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    spi_bus_remove_device(handle->spi);
    spi_bus_free(handle->config.spi_host);
    free(handle->buffer);
    free(handle);

    return ESP_OK;
}

esp_err_t epaper_1in54_init(epaper_1in54_handle_t handle) {
    if (handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    epd_hw_reset(handle);
    epd_wait_busy(handle);

    epd_send_command(handle, 0x12);  // SWRESET
    epd_wait_busy(handle);

    epd_send_command(handle, 0x01);  // Driver output control
    epd_send_data(handle, 0xC7);
    epd_send_data(handle, 0x00);
    epd_send_data(handle, 0x01);

    epd_send_command(handle, 0x11);  // Data entry mode
    epd_send_data(handle, 0x01);

    epd_set_window(handle, 0, handle->width - 1, handle->height - 1, 0);

    epd_send_command(handle, 0x3C);  // BorderWaveform
    epd_send_data(handle, 0x01);

    epd_send_command(handle, 0x18);
    epd_send_data(handle, 0x80);

    epd_send_command(handle, 0x22);  // Load Temperature and waveform setting
    epd_send_data(handle, 0xB1);
    epd_send_command(handle, 0x20);

    epd_set_cursor(handle, 0, handle->height - 1);
    epd_wait_busy(handle);

    epd_set_lut(handle, WF_FULL_1IN54);

    ESP_LOGI(TAG, "Display initialized (full refresh mode)");
    return ESP_OK;
}

esp_err_t epaper_1in54_init_partial(epaper_1in54_handle_t handle) {
    if (handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    epd_hw_reset(handle);
    epd_wait_busy(handle);

    epd_set_lut(handle, WF_PARTIAL_1IN54);

    epd_send_command(handle, 0x37);
    epd_send_data(handle, 0x00);
    epd_send_data(handle, 0x00);
    epd_send_data(handle, 0x00);
    epd_send_data(handle, 0x00);
    epd_send_data(handle, 0x00);
    epd_send_data(handle, 0x40);
    epd_send_data(handle, 0x00);
    epd_send_data(handle, 0x00);
    epd_send_data(handle, 0x00);
    epd_send_data(handle, 0x00);

    epd_send_command(handle, 0x3C);  // BorderWaveform
    epd_send_data(handle, 0x80);

    epd_send_command(handle, 0x22);
    epd_send_data(handle, 0xC0);
    epd_send_command(handle, 0x20);
    epd_wait_busy(handle);

    ESP_LOGI(TAG, "Display initialized (partial refresh mode)");
    return ESP_OK;
}

esp_err_t epaper_1in54_clear(epaper_1in54_handle_t handle) {
    if (handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    memset(handle->buffer, 0xFF, EPD_BUFFER_SIZE);
    return ESP_OK;
}

esp_err_t epaper_1in54_refresh(epaper_1in54_handle_t handle) {
    if (handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    epd_send_command(handle, 0x24);
    epd_send_data_buffer(handle, handle->buffer, EPD_BUFFER_SIZE);
    epd_turn_on_display(handle);

    return ESP_OK;
}

esp_err_t epaper_1in54_refresh_partial(epaper_1in54_handle_t handle) {
    if (handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    epd_send_command(handle, 0x24);
    epd_send_data_buffer(handle, handle->buffer, EPD_BUFFER_SIZE);
    epd_turn_on_display_partial(handle);

    return ESP_OK;
}

esp_err_t epaper_1in54_draw_pixel(epaper_1in54_handle_t handle, uint16_t x, uint16_t y, epaper_color_t color) {
    if (handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    if (x >= handle->width || y >= handle->height) {
        ESP_LOGW(TAG, "Pixel out of bounds: (%d, %d)", x, y);
        return ESP_ERR_INVALID_ARG;
    }

    uint16_t index = y * (handle->width / 8) + (x >> 3);
    uint8_t bit = 7 - (x & 0x07);

    if (color == EPAPER_COLOR_WHITE) {
        handle->buffer[index] |= (1 << bit);
    } else {
        handle->buffer[index] &= ~(1 << bit);
    }

    return ESP_OK;
}

esp_err_t epaper_1in54_get_buffer(epaper_1in54_handle_t handle, uint8_t **buffer, size_t *len) {
    if (handle == NULL || buffer == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    *buffer = handle->buffer;
    if (len) {
        *len = EPD_BUFFER_SIZE;
    }

    return ESP_OK;
}

uint16_t epaper_1in54_get_width(epaper_1in54_handle_t handle) {
    return handle ? handle->width : 0;
}

uint16_t epaper_1in54_get_height(epaper_1in54_handle_t handle) {
    return handle ? handle->height : 0;
}
