#include <stdio.h>
#include "model_init.h"
#include "model_config.h"
#include "i2c_bsp.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "driver/gpio.h"
#include "driver/ledc.h"
#include "driver/adc.h"

static const char *TAG = "model_init";

// Device handles
static ssd1306_handle_t s_display = NULL;
static sx1262_handle_t s_lora = NULL;
static bool s_adc_initialized = false;

// ============================================================================
// Vext power control
// ============================================================================

void model_vext_on(void)
{
    gpio_set_level(VEXT_PIN, VEXT_ON_LEVEL);
}

void model_vext_off(void)
{
    gpio_set_level(VEXT_PIN, VEXT_OFF_LEVEL);
}

// ============================================================================
// LED control (LEDC PWM)
// ============================================================================

void model_led_on(void)
{
    ledc_set_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, 255);
    ledc_update_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0);
}

void model_led_off(void)
{
    ledc_set_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, 0);
    ledc_update_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0);
}

void model_led_set_brightness(uint8_t brightness)
{
    ledc_set_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, brightness);
    ledc_update_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0);
}

// ============================================================================
// Battery voltage
// ============================================================================

float model_get_battery_voltage(void)
{
    if (!s_adc_initialized) return 0.0f;

    int raw = adc1_get_raw(ADC1_CHANNEL_0);
    if (raw < 0) return 0.0f;

    // ESP32-S3 ADC: 12-bit (0-4095), ~0-2.5V reference
    // Battery divider: 390k / 100k -> scale = (390+100)/100 = 4.9
    float voltage = ((float)raw / 4095.0f) * 2.5f * BATTERY_ADC_SCALE;
    return voltage;
}

// ============================================================================
// Accessors
// ============================================================================

ssd1306_handle_t model_get_display(void)
{
    return s_display;
}

sx1262_handle_t model_get_lora(void)
{
    return s_lora;
}

// ============================================================================
// Init / Deinit
// ============================================================================

esp_err_t model_init(void)
{
    ESP_LOGI(TAG, "Initializing %s (%s)", MODEL_NAME, MODEL_VARIANT);
    ESP_LOGI(TAG, "ESP32-S3 LX7 @ 240MHz, 512KB SRAM, 8MB Flash");

    esp_err_t ret;

    // 1. Initialize NVS (required for WiFi)
    ret = nvs_flash_init();
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

    // 2. Initialize Vext power control and turn ON (powers OLED + LoRa)
    gpio_config_t vext_conf = {
        .pin_bit_mask = (1ULL << VEXT_PIN),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&vext_conf);
    model_vext_on();
    vTaskDelay(pdMS_TO_TICKS(100));  // Wait for power stabilization
    ESP_LOGI(TAG, "Vext power ON (GPIO%d)", VEXT_PIN);

    // 3. Initialize I2C bus
    i2c_bus_config_t i2c_config = {
        .sda_pin = I2C_PIN_SDA,
        .scl_pin = I2C_PIN_SCL,
        .port = I2C_MASTER_PORT,
        .freq_hz = I2C_MASTER_FREQ_HZ,
    };
    ret = i2c_bus_init(&i2c_config);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "I2C init failed: %s", esp_err_to_name(ret));
        return ret;
    }
    ESP_LOGI(TAG, "I2C bus initialized (SDA=%d, SCL=%d, %luHz)",
             I2C_PIN_SDA, I2C_PIN_SCL, (unsigned long)I2C_MASTER_FREQ_HZ);

    // 4. Initialize SSD1306 OLED display
    ssd1306_config_t oled_config = {
        .sda_pin = I2C_PIN_SDA,
        .scl_pin = I2C_PIN_SCL,
        .rst_pin = OLED_PIN_RST,
        .i2c_addr = I2C_ADDR_OLED,
    };
    ret = ssd1306_create(&oled_config, &s_display);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "SSD1306 create failed: %s", esp_err_to_name(ret));
        return ret;
    }
    ret = ssd1306_init(s_display);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "SSD1306 init failed: %s", esp_err_to_name(ret));
        return ret;
    }
    ESP_LOGI(TAG, "OLED display initialized (128x64, I2C 0x%02X)", I2C_ADDR_OLED);

    // 5. Initialize SX1262 LoRa radio
    sx1262_spi_config_t lora_spi = {
        .mosi_pin = LORA_PIN_MOSI,
        .miso_pin = LORA_PIN_MISO,
        .sck_pin = LORA_PIN_SCK,
        .cs_pin = LORA_PIN_NSS,
        .rst_pin = LORA_PIN_RST,
        .busy_pin = LORA_PIN_BUSY,
        .dio1_pin = LORA_PIN_DIO1,
    };
    ret = sx1262_create(&lora_spi, &s_lora);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "SX1262 create failed: %s", esp_err_to_name(ret));
        // Non-fatal: continue without LoRa
        s_lora = NULL;
    } else {
        sx1262_lora_config_t lora_config = {
            .frequency_hz = LORA_DEFAULT_FREQ_HZ,
            .sf = SX1262_SF7,
            .bw = SX1262_BW_125,
            .cr = SX1262_CR_4_5,
            .tx_power_dbm = 14,
            .preamble_len = 8,
            .crc_on = true,
            .use_tcxo = true,
            .use_dio2_rf_switch = true,
        };
        ret = sx1262_init(s_lora, &lora_config);
        if (ret != ESP_OK) {
            ESP_LOGE(TAG, "SX1262 init failed: %s", esp_err_to_name(ret));
            sx1262_delete(s_lora);
            s_lora = NULL;
        } else {
            ESP_LOGI(TAG, "LoRa initialized (freq=%luHz, SF7, BW125)",
                     (unsigned long)LORA_DEFAULT_FREQ_HZ);
        }
    }

    // 6. Initialize LED (LEDC PWM)
    ledc_timer_config_t ledc_timer = {
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .duty_resolution = LEDC_TIMER_8_BIT,
        .timer_num = LEDC_TIMER_0,
        .freq_hz = 5000,
        .clk_cfg = LEDC_AUTO_CLK,
    };
    ledc_timer_config(&ledc_timer);

    ledc_channel_config_t ledc_channel = {
        .gpio_num = LED_PIN,
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .channel = LEDC_CHANNEL_0,
        .intr_type = LEDC_INTR_DISABLE,
        .timer_sel = LEDC_TIMER_0,
        .duty = 0,
        .hpoint = 0,
    };
    ledc_channel_config(&ledc_channel);
    ESP_LOGI(TAG, "LED initialized on GPIO%d (PWM)", LED_PIN);

    // 7. Initialize battery ADC (legacy driver)
    ret = adc1_config_width(ADC_WIDTH_BIT_12);
    if (ret == ESP_OK) {
        ret = adc1_config_channel_atten(ADC1_CHANNEL_0, ADC_ATTEN_DB_12);
    }
    if (ret == ESP_OK) {
        s_adc_initialized = true;
        ESP_LOGI(TAG, "Battery ADC initialized on GPIO%d", BATTERY_ADC_PIN);
    } else {
        ESP_LOGW(TAG, "Battery ADC init failed: %s", esp_err_to_name(ret));
        s_adc_initialized = false;
    }

    ESP_LOGI(TAG, "Board initialization complete");
    return ESP_OK;
}

esp_err_t model_deinit(void)
{
    if (s_lora) {
        sx1262_delete(s_lora);
        s_lora = NULL;
    }
    if (s_display) {
        ssd1306_delete(s_display);
        s_display = NULL;
    }
    s_adc_initialized = false;
    i2c_bus_deinit();
    model_vext_off();
    ESP_LOGI(TAG, "Board deinitialization complete");
    return ESP_OK;
}
