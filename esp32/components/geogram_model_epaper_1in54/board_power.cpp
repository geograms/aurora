#include <stdio.h>
#include "board_power.h"
#include "model_config.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/timers.h"
#include "driver/gpio.h"
#include "driver/rtc_io.h"
#include "esp_sleep.h"
#include "esp_log.h"

static const char *TAG = "board_power";
static TimerHandle_t s_backlight_timer = NULL;

// Timer callback to turn off backlight
static void backlight_timer_callback(TimerHandle_t xTimer) {
    board_power_backlight_off();
}

esp_err_t board_power_init(void) {
    // Reset GPIO pins
    gpio_reset_pin(PWR_PIN_EPD);
    gpio_reset_pin(PWR_PIN_AUDIO);
    gpio_reset_pin(PWR_PIN_VBAT);
    gpio_reset_pin(BACKLIGHT_PIN);

    // Configure power control pins as outputs
    gpio_config_t gpio_conf = {};
    gpio_conf.intr_type = GPIO_INTR_DISABLE;
    gpio_conf.pin_bit_mask = (1ULL << PWR_PIN_EPD) | (1ULL << PWR_PIN_AUDIO) | (1ULL << PWR_PIN_VBAT) | (1ULL << BACKLIGHT_PIN);
    gpio_conf.mode = GPIO_MODE_OUTPUT;
    gpio_conf.pull_up_en = GPIO_PULLUP_ENABLE;
    gpio_conf.pull_down_en = GPIO_PULLDOWN_DISABLE;

    esp_err_t ret = gpio_config(&gpio_conf);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to configure power GPIO");
        return ret;
    }

    // Set default states (all off)
    board_power_epd_off();
    board_power_audio_off();
    board_power_vbat_off();
    board_power_backlight_off();

    // Create backlight timer (one-shot)
    s_backlight_timer = xTimerCreate("backlight_timer", pdMS_TO_TICKS(3000), pdFALSE, NULL, backlight_timer_callback);

    ESP_LOGI(TAG, "Board power initialized");
    return ESP_OK;
}

void board_power_epd_on(void) {
    gpio_set_level(PWR_PIN_EPD, PWR_EPD_ON_LEVEL);
    ESP_LOGD(TAG, "EPD power ON");
}

void board_power_epd_off(void) {
    gpio_set_level(PWR_PIN_EPD, PWR_EPD_OFF_LEVEL);
    ESP_LOGD(TAG, "EPD power OFF");
}

void board_power_audio_on(void) {
    gpio_set_level(PWR_PIN_AUDIO, PWR_AUDIO_ON_LEVEL);
    ESP_LOGD(TAG, "Audio power ON");
}

void board_power_audio_off(void) {
    gpio_set_level(PWR_PIN_AUDIO, PWR_AUDIO_OFF_LEVEL);
    ESP_LOGD(TAG, "Audio power OFF");
}

void board_power_vbat_on(void) {
    gpio_set_level(PWR_PIN_VBAT, PWR_VBAT_ON_LEVEL);
    ESP_LOGD(TAG, "VBAT power ON");
}

void board_power_vbat_off(void) {
    gpio_set_level(PWR_PIN_VBAT, PWR_VBAT_OFF_LEVEL);
    ESP_LOGD(TAG, "VBAT power OFF");
}

void board_power_backlight_on(void) {
    gpio_set_level(BACKLIGHT_PIN, 0);  // Active low
    ESP_LOGI(TAG, "Backlight ON");
}

void board_power_backlight_off(void) {
    gpio_set_level(BACKLIGHT_PIN, 1);  // Inactive high
    ESP_LOGD(TAG, "Backlight OFF");
}

void board_power_backlight_timed(uint32_t duration_ms) {
    board_power_backlight_on();

    if (s_backlight_timer != NULL) {
        // Update the timer period and start/restart it
        xTimerChangePeriod(s_backlight_timer, pdMS_TO_TICKS(duration_ms), 0);
        xTimerStart(s_backlight_timer, 0);
    }
}

void board_power_deep_sleep(uint32_t wakeup_time_sec) {
    ESP_LOGI(TAG, "Entering deep sleep...");

    // Disable all wake-up sources first
    esp_sleep_disable_wakeup_source(ESP_SLEEP_WAKEUP_ALL);

    // Configure power button (GPIO18) as wake-up source
    // Using ext1 wake-up which supports multiple GPIOs
    const uint64_t ext_wakeup_mask = (1ULL << WAKEUP_PIN_POWER);

    // Wake up when the button is pressed (active low, so wake on low level)
    // ESP_EXT1_WAKEUP_ANY_LOW was renamed to ESP_EXT1_WAKEUP_ALL_LOW in ESP-IDF 5.x
    // but for a single pin they behave the same
    esp_err_t ret = esp_sleep_enable_ext1_wakeup(ext_wakeup_mask, ESP_EXT1_WAKEUP_ANY_LOW);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to enable ext1 wakeup: %s", esp_err_to_name(ret));
        // Try alternative method if ext1 fails
        ret = esp_sleep_enable_ext0_wakeup(WAKEUP_PIN_POWER, 0);  // Wake on low level
        if (ret != ESP_OK) {
            ESP_LOGE(TAG, "Failed to enable ext0 wakeup: %s", esp_err_to_name(ret));
        }
    }

    // Configure RTC GPIO for power button
    rtc_gpio_pulldown_dis(WAKEUP_PIN_POWER);
    rtc_gpio_pullup_en(WAKEUP_PIN_POWER);

    // Configure timer wake-up if specified
    if (wakeup_time_sec > 0) {
        esp_sleep_enable_timer_wakeup(wakeup_time_sec * 1000000ULL);
        ESP_LOGI(TAG, "Timer wake-up set for %lu seconds", wakeup_time_sec);
    }

    ESP_LOGI(TAG, "Deep sleep configured - wake on power button press");

    // Small delay to allow log output
    vTaskDelay(pdMS_TO_TICKS(100));

    // Enter deep sleep
    esp_deep_sleep_start();
}

void board_power_enable_low_power_mode(void) {
    // Turn off non-essential peripherals
    board_power_epd_off();
    board_power_audio_off();

    ESP_LOGI(TAG, "Low power mode enabled");
}
