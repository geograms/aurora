#include <stdio.h>
#include "model_init.h"
#include "model_config.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "led_bsp.h"

static const char *TAG = "model_init";

esp_err_t model_init(void) {
    ESP_LOGI(TAG, "Initializing %s (%s)", MODEL_NAME, MODEL_VARIANT);
    ESP_LOGI(TAG, "ESP32-C3 RISC-V @ 160MHz, 400KB SRAM, 4MB Flash");

    // Initialize NVS (required for WiFi)
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_LOGW(TAG, "NVS partition was truncated, erasing...");
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize NVS: %s", esp_err_to_name(ret));
        return ret;
    }
    ESP_LOGI(TAG, "NVS initialized");

#if HAS_LED
    // Initialize WS2812 RGB LED
    ret = led_init(LED_PIN);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Failed to initialize LED: %s", esp_err_to_name(ret));
    } else {
        ESP_LOGI(TAG, "LED initialized on GPIO%d", LED_PIN);
        // Show connecting state during boot
        led_set_state(LED_STATE_CONNECTING);
    }
#endif

    ESP_LOGI(TAG, "Board initialization complete");
    return ESP_OK;
}

esp_err_t model_deinit(void) {
    ESP_LOGI(TAG, "Board deinitialization complete");
    return ESP_OK;
}
