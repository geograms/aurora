/**
 * @file led_bsp.c
 * @brief WS2812 RGB LED driver using RMT peripheral
 */

#include "led_bsp.h"
#include "driver/rmt_tx.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_log.h"
#include <string.h>

static const char *TAG = "led_bsp";

// WS2812 timing parameters (in RMT ticks at 10MHz = 100ns per tick)
// T0H = 350ns = 3.5 ticks -> 4 ticks
// T0L = 900ns = 9 ticks
// T1H = 900ns = 9 ticks
// T1L = 350ns = 3.5 ticks -> 4 ticks
#define WS2812_T0H_TICKS   4
#define WS2812_T0L_TICKS   9
#define WS2812_T1H_TICKS   9
#define WS2812_T1L_TICKS   4
#define WS2812_RESET_TICKS 2800  // 280us = 2800 ticks at 10MHz

// RMT resolution (10MHz = 100ns per tick)
#define RMT_RESOLUTION_HZ 10000000

// State
static bool s_initialized = false;
static rmt_channel_handle_t s_led_channel = NULL;
static rmt_encoder_handle_t s_led_encoder = NULL;
static led_state_t s_current_state = LED_STATE_OFF;
static TaskHandle_t s_blink_task = NULL;
static SemaphoreHandle_t s_led_mutex = NULL;
static volatile bool s_stop_blink = false;

// Current RGB values for restoring after blink
static uint8_t s_current_r = 0;
static uint8_t s_current_g = 0;
static uint8_t s_current_b = 0;

// WS2812 encoder
typedef struct {
    rmt_encoder_t base;
    rmt_encoder_t *bytes_encoder;
    rmt_encoder_t *copy_encoder;
    int state;
    rmt_symbol_word_t reset_code;
} ws2812_encoder_t;

static size_t ws2812_encode(rmt_encoder_t *encoder, rmt_channel_handle_t channel,
                            const void *primary_data, size_t data_size, rmt_encode_state_t *ret_state)
{
    ws2812_encoder_t *ws2812_encoder = __containerof(encoder, ws2812_encoder_t, base);
    rmt_encoder_handle_t bytes_encoder = ws2812_encoder->bytes_encoder;
    rmt_encoder_handle_t copy_encoder = ws2812_encoder->copy_encoder;
    rmt_encode_state_t session_state = RMT_ENCODING_RESET;
    int state = RMT_ENCODING_RESET;
    size_t encoded_symbols = 0;

    switch (ws2812_encoder->state) {
        case 0: // Send RGB data
            encoded_symbols += bytes_encoder->encode(bytes_encoder, channel, primary_data, data_size, &session_state);
            if (session_state & RMT_ENCODING_COMPLETE) {
                ws2812_encoder->state = 1;
            }
            if (session_state & RMT_ENCODING_MEM_FULL) {
                state |= RMT_ENCODING_MEM_FULL;
                goto out;
            }
            // fall through
        case 1: // Send reset code
            encoded_symbols += copy_encoder->encode(copy_encoder, channel, &ws2812_encoder->reset_code,
                                                    sizeof(ws2812_encoder->reset_code), &session_state);
            if (session_state & RMT_ENCODING_COMPLETE) {
                ws2812_encoder->state = RMT_ENCODING_RESET;
                state |= RMT_ENCODING_COMPLETE;
            }
            if (session_state & RMT_ENCODING_MEM_FULL) {
                state |= RMT_ENCODING_MEM_FULL;
                goto out;
            }
    }

out:
    *ret_state = state;
    return encoded_symbols;
}

static esp_err_t ws2812_encoder_reset(rmt_encoder_t *encoder)
{
    ws2812_encoder_t *ws2812_encoder = __containerof(encoder, ws2812_encoder_t, base);
    rmt_encoder_reset(ws2812_encoder->bytes_encoder);
    rmt_encoder_reset(ws2812_encoder->copy_encoder);
    ws2812_encoder->state = RMT_ENCODING_RESET;
    return ESP_OK;
}

static esp_err_t ws2812_encoder_del(rmt_encoder_t *encoder)
{
    ws2812_encoder_t *ws2812_encoder = __containerof(encoder, ws2812_encoder_t, base);
    rmt_del_encoder(ws2812_encoder->bytes_encoder);
    rmt_del_encoder(ws2812_encoder->copy_encoder);
    free(ws2812_encoder);
    return ESP_OK;
}

static esp_err_t create_ws2812_encoder(rmt_encoder_handle_t *ret_encoder)
{
    ws2812_encoder_t *ws2812_encoder = calloc(1, sizeof(ws2812_encoder_t));
    if (!ws2812_encoder) {
        return ESP_ERR_NO_MEM;
    }

    ws2812_encoder->base.encode = ws2812_encode;
    ws2812_encoder->base.del = ws2812_encoder_del;
    ws2812_encoder->base.reset = ws2812_encoder_reset;

    // Bytes encoder for RGB data
    rmt_bytes_encoder_config_t bytes_config = {
        .bit0 = {
            .level0 = 1,
            .duration0 = WS2812_T0H_TICKS,
            .level1 = 0,
            .duration1 = WS2812_T0L_TICKS,
        },
        .bit1 = {
            .level0 = 1,
            .duration0 = WS2812_T1H_TICKS,
            .level1 = 0,
            .duration1 = WS2812_T1L_TICKS,
        },
        .flags.msb_first = 1,
    };
    ESP_ERROR_CHECK(rmt_new_bytes_encoder(&bytes_config, &ws2812_encoder->bytes_encoder));

    // Copy encoder for reset code
    rmt_copy_encoder_config_t copy_config = {};
    ESP_ERROR_CHECK(rmt_new_copy_encoder(&copy_config, &ws2812_encoder->copy_encoder));

    // Reset code (low for 280us = 2800 ticks at 10MHz)
    ws2812_encoder->reset_code = (rmt_symbol_word_t){
        .level0 = 0,
        .duration0 = WS2812_RESET_TICKS,
        .level1 = 0,
        .duration1 = WS2812_RESET_TICKS,
    };

    *ret_encoder = &ws2812_encoder->base;
    return ESP_OK;
}

// Internal function to set LED without mutex
static esp_err_t led_set_rgb_internal(uint8_t r, uint8_t g, uint8_t b)
{
    if (!s_initialized) {
        return ESP_ERR_INVALID_STATE;
    }

    // WS2812 expects GRB order
    uint8_t grb[3] = {g, r, b};

    rmt_transmit_config_t tx_config = {
        .loop_count = 0,
    };

    esp_err_t ret = rmt_transmit(s_led_channel, s_led_encoder, grb, sizeof(grb), &tx_config);
    if (ret != ESP_OK) {
        return ret;
    }

    return rmt_tx_wait_all_done(s_led_channel, portMAX_DELAY);
}

// Blink task for state-based blinking
static void led_state_blink_task(void *arg)
{
    led_state_t state = (led_state_t)(uintptr_t)arg;
    bool on = false;

    while (!s_stop_blink) {
        on = !on;

        if (xSemaphoreTake(s_led_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
            switch (state) {
                case LED_STATE_ERROR:
                    // Red blinking
                    if (on) {
                        led_set_rgb_internal(255, 0, 0);
                    } else {
                        led_set_rgb_internal(0, 0, 0);
                    }
                    break;

                case LED_STATE_CONNECTING:
                    // Yellow blinking
                    if (on) {
                        led_set_rgb_internal(255, 200, 0);
                    } else {
                        led_set_rgb_internal(0, 0, 0);
                    }
                    break;

                default:
                    break;
            }
            xSemaphoreGive(s_led_mutex);
        }

        vTaskDelay(pdMS_TO_TICKS(500));  // 500ms on, 500ms off
    }

    s_blink_task = NULL;
    vTaskDelete(NULL);
}

// One-shot blink task
typedef struct {
    led_color_t color;
    int count;
    int on_ms;
    int off_ms;
} blink_params_t;

static void led_oneshot_blink_task(void *arg)
{
    blink_params_t *params = (blink_params_t *)arg;
    uint8_t r = 0, g = 0, b = 0;

    // Convert color enum to RGB
    switch (params->color) {
        case LED_COLOR_RED:     r = 255; break;
        case LED_COLOR_GREEN:   g = 255; break;
        case LED_COLOR_BLUE:    b = 255; break;
        case LED_COLOR_WHITE:   r = g = b = 255; break;
        case LED_COLOR_YELLOW:  r = 255; g = 200; break;
        case LED_COLOR_CYAN:    g = b = 255; break;
        case LED_COLOR_MAGENTA: r = b = 255; break;
        default: break;
    }

    for (int i = 0; i < params->count && !s_stop_blink; i++) {
        if (xSemaphoreTake(s_led_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
            led_set_rgb_internal(r, g, b);
            xSemaphoreGive(s_led_mutex);
        }
        vTaskDelay(pdMS_TO_TICKS(params->on_ms));

        if (xSemaphoreTake(s_led_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
            led_set_rgb_internal(0, 0, 0);
            xSemaphoreGive(s_led_mutex);
        }
        vTaskDelay(pdMS_TO_TICKS(params->off_ms));
    }

    // Restore previous state
    if (xSemaphoreTake(s_led_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
        led_set_rgb_internal(s_current_r, s_current_g, s_current_b);
        xSemaphoreGive(s_led_mutex);
    }

    free(params);
    vTaskDelete(NULL);
}

esp_err_t led_init(int gpio_num)
{
    if (s_initialized) {
        return ESP_OK;
    }

    ESP_LOGI(TAG, "Initializing WS2812 LED on GPIO%d", gpio_num);

    // Create mutex
    s_led_mutex = xSemaphoreCreateMutex();
    if (!s_led_mutex) {
        ESP_LOGE(TAG, "Failed to create mutex");
        return ESP_ERR_NO_MEM;
    }

    // Create RMT TX channel
    rmt_tx_channel_config_t tx_config = {
        .gpio_num = gpio_num,
        .clk_src = RMT_CLK_SRC_DEFAULT,
        .resolution_hz = RMT_RESOLUTION_HZ,
        .mem_block_symbols = 64,
        .trans_queue_depth = 4,
    };

    esp_err_t ret = rmt_new_tx_channel(&tx_config, &s_led_channel);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to create RMT TX channel: %s", esp_err_to_name(ret));
        vSemaphoreDelete(s_led_mutex);
        return ret;
    }

    // Create encoder
    ret = create_ws2812_encoder(&s_led_encoder);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to create WS2812 encoder: %s", esp_err_to_name(ret));
        rmt_del_channel(s_led_channel);
        vSemaphoreDelete(s_led_mutex);
        return ret;
    }

    // Enable channel
    ret = rmt_enable(s_led_channel);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to enable RMT channel: %s", esp_err_to_name(ret));
        rmt_del_encoder(s_led_encoder);
        rmt_del_channel(s_led_channel);
        vSemaphoreDelete(s_led_mutex);
        return ret;
    }

    s_initialized = true;

    // Turn LED off initially
    led_off();

    ESP_LOGI(TAG, "WS2812 LED initialized");
    return ESP_OK;
}

void led_deinit(void)
{
    if (!s_initialized) {
        return;
    }

    // Stop blink task
    s_stop_blink = true;
    if (s_blink_task) {
        vTaskDelay(pdMS_TO_TICKS(100));
    }

    led_off();

    rmt_disable(s_led_channel);
    rmt_del_encoder(s_led_encoder);
    rmt_del_channel(s_led_channel);
    vSemaphoreDelete(s_led_mutex);

    s_led_channel = NULL;
    s_led_encoder = NULL;
    s_led_mutex = NULL;
    s_initialized = false;

    ESP_LOGI(TAG, "LED deinitialized");
}

esp_err_t led_set_color(led_color_t color)
{
    switch (color) {
        case LED_COLOR_OFF:     return led_set_rgb(0, 0, 0);
        case LED_COLOR_RED:     return led_set_rgb(255, 0, 0);
        case LED_COLOR_GREEN:   return led_set_rgb(0, 255, 0);
        case LED_COLOR_BLUE:    return led_set_rgb(0, 0, 255);
        case LED_COLOR_WHITE:   return led_set_rgb(255, 255, 255);
        case LED_COLOR_YELLOW:  return led_set_rgb(255, 200, 0);
        case LED_COLOR_CYAN:    return led_set_rgb(0, 255, 255);
        case LED_COLOR_MAGENTA: return led_set_rgb(255, 0, 255);
        default:                return ESP_ERR_INVALID_ARG;
    }
}

esp_err_t led_set_rgb(uint8_t r, uint8_t g, uint8_t b)
{
    if (!s_initialized) {
        return ESP_ERR_INVALID_STATE;
    }

    if (xSemaphoreTake(s_led_mutex, pdMS_TO_TICKS(100)) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }

    // Save current color
    s_current_r = r;
    s_current_g = g;
    s_current_b = b;

    esp_err_t ret = led_set_rgb_internal(r, g, b);

    xSemaphoreGive(s_led_mutex);
    return ret;
}

esp_err_t led_off(void)
{
    return led_set_rgb(0, 0, 0);
}

esp_err_t led_set_state(led_state_t state)
{
    if (!s_initialized) {
        return ESP_ERR_INVALID_STATE;
    }

    // Stop any existing blink task
    if (s_blink_task) {
        s_stop_blink = true;
        vTaskDelay(pdMS_TO_TICKS(100));
        s_stop_blink = false;
    }

    s_current_state = state;

    switch (state) {
        case LED_STATE_OFF:
            led_off();
            break;

        case LED_STATE_OK:
            // Solid green
            led_set_color(LED_COLOR_GREEN);
            break;

        case LED_STATE_ERROR:
        case LED_STATE_CONNECTING:
            // Start blink task
            xTaskCreate(led_state_blink_task, "led_blink", 2048,
                        (void *)(uintptr_t)state, 5, &s_blink_task);
            break;
    }

    return ESP_OK;
}

led_state_t led_get_state(void)
{
    return s_current_state;
}

esp_err_t led_blink(led_color_t color, int count, int on_ms, int off_ms)
{
    if (!s_initialized) {
        return ESP_ERR_INVALID_STATE;
    }

    blink_params_t *params = malloc(sizeof(blink_params_t));
    if (!params) {
        return ESP_ERR_NO_MEM;
    }

    params->color = color;
    params->count = count;
    params->on_ms = on_ms;
    params->off_ms = off_ms;

    // Create one-shot blink task
    BaseType_t ret = xTaskCreate(led_oneshot_blink_task, "led_blink1", 2048,
                                  params, 6, NULL);
    if (ret != pdPASS) {
        free(params);
        return ESP_ERR_NO_MEM;
    }

    return ESP_OK;
}

esp_err_t led_notify_chat(void)
{
    ESP_LOGI(TAG, "Chat notification - blinking blue 3 times");
    return led_blink(LED_COLOR_BLUE, 3, 150, 150);
}
