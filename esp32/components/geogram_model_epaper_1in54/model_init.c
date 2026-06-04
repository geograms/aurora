#include <stdio.h>
#include "model_init.h"
#include "model_config.h"
#include "board_power.h"
#include "i2c_bsp.h"
#include "epaper_1in54.h"
#include "pcf85063.h"
#include "shtc3.h"
#include "button_bsp.h"
#include "lvgl_port.h"
#include "sdcard.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "model_init";

// Device handles
static epaper_1in54_handle_t s_display = NULL;
static pcf85063_handle_t s_rtc = NULL;
static shtc3_handle_t s_env_sensor = NULL;
static i2c_dev_handle_t s_rtc_i2c = NULL;
static i2c_dev_handle_t s_shtc3_i2c = NULL;
static button_handle_t s_boot_button = NULL;
static button_handle_t s_power_button = NULL;
static bool s_sdcard_mounted = false;

static void button_event_handler(gpio_num_t gpio, button_event_t event, void *user_data) {
    const char *btn_name = (gpio == BTN_PIN_BOOT) ? "BOOT(GPIO0)" : "POWER(GPIO18)";
    const char *event_name = "unknown";

    switch (event) {
        case BUTTON_EVENT_PRESSED:
            event_name = "PRESSED";
            break;
        case BUTTON_EVENT_RELEASED:
            event_name = "RELEASED";
            break;
        case BUTTON_EVENT_CLICK:
            event_name = "CLICK";
            // BOOT button (GPIO 0) short click: turn on backlight for 3 seconds
            if (gpio == BTN_PIN_BOOT) {
                ESP_LOGI(TAG, ">>> Turning on backlight for 3 seconds <<<");
                board_power_backlight_timed(3000);
            }
            break;
        case BUTTON_EVENT_DOUBLE_CLICK:
            event_name = "DOUBLE-CLICK";
            break;
        case BUTTON_EVENT_LONG_PRESS:
            event_name = "LONG-PRESS";
            // BOOT button (GPIO 0) long press: rotate display 90 degrees clockwise
            if (gpio == BTN_PIN_BOOT) {
                ESP_LOGI(TAG, ">>> Rotating display 90 degrees clockwise <<<");
                lvgl_port_rotate_cw();
            }
            break;
        default:
            event_name = "NONE";
            break;
    }

    ESP_LOGI(TAG, "Button %s event: %s", btn_name, event_name);
}

esp_err_t model_init(void) {
    esp_err_t ret;

    ESP_LOGI(TAG, "Initializing %s (%s)", MODEL_NAME, MODEL_VARIANT);

    // Initialize NVS early (needed for display rotation persistence)
    ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES) {
        // NVS partition was truncated and needs to be erased
        ESP_LOGW(TAG, "NVS no free pages, erasing...");
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    // Note: We don't erase on ESP_ERR_NVS_NEW_VERSION_FOUND to preserve user settings
    if (ret != ESP_OK && ret != ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_LOGE(TAG, "NVS init failed: %s", esp_err_to_name(ret));
        return ret;
    }
    ESP_LOGI(TAG, "NVS initialized");

    // Initialize power management
    ret = board_power_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize power management");
        return ret;
    }

    // Turn on e-paper power
    board_power_epd_on();
    vTaskDelay(pdMS_TO_TICKS(100));  // Wait for power stabilization

    // Initialize I2C bus
    i2c_bus_config_t i2c_config = {
        .sda_pin = I2C_PIN_SDA,
        .scl_pin = I2C_PIN_SCL,
        .port = I2C_MASTER_PORT,
        .freq_hz = I2C_MASTER_FREQ_HZ,
    };
    ret = i2c_bus_init(&i2c_config);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize I2C bus");
        return ret;
    }

    // Add I2C devices
    ret = i2c_bus_add_device(I2C_ADDR_RTC, &s_rtc_i2c);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Failed to add RTC I2C device");
    }

    ret = i2c_bus_add_device(I2C_ADDR_SHTC3, &s_shtc3_i2c);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Failed to add SHTC3 I2C device");
    }

    // Initialize e-paper display
#if HAS_EPAPER_DISPLAY
    epaper_spi_config_t epd_config = {
        .cs = EPD_PIN_CS,
        .dc = EPD_PIN_DC,
        .rst = EPD_PIN_RST,
        .busy = EPD_PIN_BUSY,
        .mosi = EPD_PIN_MOSI,
        .sclk = EPD_PIN_SCK,
        .spi_host = EPD_SPI_HOST,
    };
    ret = epaper_1in54_create(&epd_config, &s_display);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to create e-paper display");
    } else {
        ret = epaper_1in54_init(s_display);
        if (ret != ESP_OK) {
            ESP_LOGE(TAG, "Failed to initialize e-paper display");
        }
    }
#endif

    // Initialize RTC
#if HAS_RTC
    if (s_rtc_i2c != NULL) {
        ret = pcf85063_create(s_rtc_i2c, &s_rtc);
        if (ret != ESP_OK) {
            ESP_LOGW(TAG, "Failed to initialize RTC");
        }
    }
#endif

    // Initialize humidity/temperature sensor
#if HAS_HUMIDITY_SENSOR
    if (s_shtc3_i2c != NULL) {
        ret = shtc3_create(s_shtc3_i2c, &s_env_sensor);
        if (ret != ESP_OK) {
            ESP_LOGW(TAG, "Failed to initialize SHTC3");
        }
    }
#endif

    // Initialize buttons
    button_config_t boot_btn_config = {
        .gpio = BTN_PIN_BOOT,
        .active_low = true,
        .debounce_ms = 20,
        .long_press_ms = 2000,
    };
    ret = button_create(&boot_btn_config, button_event_handler, NULL, &s_boot_button);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Failed to create boot button");
    }

    button_config_t pwr_btn_config = {
        .gpio = BTN_PIN_POWER,
        .active_low = true,
        .debounce_ms = 20,
        .long_press_ms = 1500,  // 1.5 seconds for long press
    };
    ret = button_create(&pwr_btn_config, button_event_handler, NULL, &s_power_button);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Failed to create power button");
    }

    // Initialize SD card
#if HAS_SDCARD
    ret = sdcard_init();
    if (ret == ESP_OK) {
        s_sdcard_mounted = true;
        ESP_LOGI(TAG, "SD card mounted (%.2f GB)", sdcard_get_capacity_gb());
    } else {
        ESP_LOGI(TAG, "No SD card or card not readable");
        s_sdcard_mounted = false;
    }
#endif

    ESP_LOGI(TAG, "Board initialization complete");
    return ESP_OK;
}

esp_err_t model_deinit(void) {
#if HAS_SDCARD
    if (s_sdcard_mounted) {
        sdcard_deinit();
        s_sdcard_mounted = false;
    }
#endif

    if (s_boot_button) {
        button_delete(s_boot_button);
        s_boot_button = NULL;
    }

    if (s_power_button) {
        button_delete(s_power_button);
        s_power_button = NULL;
    }

    if (s_env_sensor) {
        shtc3_delete(s_env_sensor);
        s_env_sensor = NULL;
    }

    if (s_rtc) {
        pcf85063_delete(s_rtc);
        s_rtc = NULL;
    }

    if (s_display) {
        epaper_1in54_delete(s_display);
        s_display = NULL;
    }

    board_power_epd_off();
    i2c_bus_deinit();

    return ESP_OK;
}

epaper_1in54_handle_t model_get_display(void) {
    return s_display;
}

pcf85063_handle_t model_get_rtc(void) {
    return s_rtc;
}

shtc3_handle_t model_get_env_sensor(void) {
    return s_env_sensor;
}

bool model_has_sdcard(void) {
#if HAS_SDCARD
    return s_sdcard_mounted && sdcard_is_mounted();
#else
    return false;
#endif
}
