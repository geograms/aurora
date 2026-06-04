#include <stdio.h>
#include <string.h>
#include "button_bsp.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"

static const char *TAG = "button";

#define MAX_BUTTONS 4
#define BUTTON_POLL_INTERVAL_MS 10
#define DOUBLE_CLICK_TIMEOUT_MS 300
#define BUTTON_TASK_STACK_SIZE 3072

struct button_dev {
    button_config_t config;
    button_callback_t callback;
    void *user_data;
    bool is_pressed;
    bool was_pressed;
    uint32_t press_time;
    uint32_t release_time;
    uint8_t click_count;
    bool long_press_fired;
    bool in_use;
};

static struct button_dev s_buttons[MAX_BUTTONS];
static TaskHandle_t s_button_task = NULL;
static bool s_initialized = false;
static bool s_task_running = false;

static uint32_t get_time_ms(void) {
    return xTaskGetTickCount() * portTICK_PERIOD_MS;
}

static bool read_button_state(button_handle_t handle) {
    int level = gpio_get_level(handle->config.gpio);
    return handle->config.active_low ? (level == 0) : (level == 1);
}

static void button_poll_loop(void *pvParameter) {
    ESP_LOGI(TAG, "Button polling task started");

    while (s_task_running) {
        uint32_t now = get_time_ms();

        for (int i = 0; i < MAX_BUTTONS; i++) {
            button_handle_t btn = &s_buttons[i];
            if (!btn->in_use) continue;

            bool is_pressed = read_button_state(btn);

            // Debounce
            if (is_pressed != btn->is_pressed) {
                uint32_t last_change = btn->is_pressed ? btn->press_time : btn->release_time;
                if ((now - last_change) < btn->config.debounce_ms) {
                    continue;
                }
            }

            // Button pressed
            if (is_pressed && !btn->was_pressed) {
                btn->is_pressed = true;
                btn->press_time = now;
                btn->long_press_fired = false;
                ESP_LOGI(TAG, "GPIO %d: PRESSED", btn->config.gpio);

                if (btn->callback) {
                    btn->callback(btn->config.gpio, BUTTON_EVENT_PRESSED, btn->user_data);
                }
            }

            // Button released
            if (!is_pressed && btn->was_pressed) {
                btn->is_pressed = false;
                btn->release_time = now;
                ESP_LOGI(TAG, "GPIO %d: RELEASED (held %lu ms)",
                         btn->config.gpio, (unsigned long)(now - btn->press_time));

                if (btn->callback) {
                    btn->callback(btn->config.gpio, BUTTON_EVENT_RELEASED, btn->user_data);
                }

                // Check for click (not a long press)
                if (!btn->long_press_fired) {
                    btn->click_count++;
                }
            }

            // Long press detection
            if (btn->is_pressed && !btn->long_press_fired) {
                if ((now - btn->press_time) >= btn->config.long_press_ms) {
                    btn->long_press_fired = true;
                    btn->click_count = 0;
                    ESP_LOGI(TAG, "GPIO %d: LONG PRESS triggered", btn->config.gpio);

                    if (btn->callback) {
                        btn->callback(btn->config.gpio, BUTTON_EVENT_LONG_PRESS, btn->user_data);
                    }
                }
            }

            // Double click detection
            if (btn->click_count > 0 && !btn->is_pressed) {
                if ((now - btn->release_time) >= DOUBLE_CLICK_TIMEOUT_MS) {
                    if (btn->click_count == 1) {
                        ESP_LOGI(TAG, "GPIO %d: CLICK triggered", btn->config.gpio);
                        if (btn->callback) {
                            btn->callback(btn->config.gpio, BUTTON_EVENT_CLICK, btn->user_data);
                        }
                    } else if (btn->click_count >= 2) {
                        ESP_LOGI(TAG, "GPIO %d: DOUBLE CLICK triggered", btn->config.gpio);
                        if (btn->callback) {
                            btn->callback(btn->config.gpio, BUTTON_EVENT_DOUBLE_CLICK, btn->user_data);
                        }
                    }
                    btn->click_count = 0;
                }
            }

            btn->was_pressed = is_pressed;
        }

        vTaskDelay(pdMS_TO_TICKS(BUTTON_POLL_INTERVAL_MS));
    }

    ESP_LOGI(TAG, "Button polling task stopped");
    vTaskDelete(NULL);
}

esp_err_t button_init(void) {
    if (s_initialized) {
        return ESP_OK;
    }

    memset(s_buttons, 0, sizeof(s_buttons));

    s_task_running = true;
    BaseType_t ret = xTaskCreate(button_poll_loop, "btn_poll", BUTTON_TASK_STACK_SIZE,
                                  NULL, 5, &s_button_task);
    if (ret != pdPASS) {
        ESP_LOGE(TAG, "Failed to create button task");
        s_task_running = false;
        return ESP_ERR_NO_MEM;
    }

    s_initialized = true;

    ESP_LOGI(TAG, "Button subsystem initialized");
    return ESP_OK;
}

esp_err_t button_deinit(void) {
    if (!s_initialized) {
        return ESP_OK;
    }

    s_task_running = false;

    // Give the task time to exit
    vTaskDelay(pdMS_TO_TICKS(50));

    s_button_task = NULL;
    s_initialized = false;
    return ESP_OK;
}

esp_err_t button_create(const button_config_t *config, button_callback_t callback,
                        void *user_data, button_handle_t *handle) {
    if (config == NULL || handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    if (!s_initialized) {
        esp_err_t ret = button_init();
        if (ret != ESP_OK) {
            return ret;
        }
    }

    // Find free slot
    button_handle_t btn = NULL;
    for (int i = 0; i < MAX_BUTTONS; i++) {
        if (!s_buttons[i].in_use) {
            btn = &s_buttons[i];
            break;
        }
    }

    if (btn == NULL) {
        ESP_LOGE(TAG, "No free button slots");
        return ESP_ERR_NO_MEM;
    }

    // Configure GPIO
    gpio_config_t io_conf = {
        .intr_type = GPIO_INTR_DISABLE,
        .mode = GPIO_MODE_INPUT,
        .pin_bit_mask = (1ULL << config->gpio),
        .pull_up_en = config->active_low ? GPIO_PULLUP_ENABLE : GPIO_PULLUP_DISABLE,
        .pull_down_en = config->active_low ? GPIO_PULLDOWN_DISABLE : GPIO_PULLDOWN_ENABLE,
    };
    gpio_config(&io_conf);

    // Initialize button structure
    memcpy(&btn->config, config, sizeof(button_config_t));
    btn->callback = callback;
    btn->user_data = user_data;
    btn->is_pressed = false;
    btn->was_pressed = false;
    btn->press_time = 0;
    btn->release_time = 0;
    btn->click_count = 0;
    btn->long_press_fired = false;
    btn->in_use = true;

    // Set defaults if not specified
    if (btn->config.debounce_ms == 0) {
        btn->config.debounce_ms = 20;
    }
    if (btn->config.long_press_ms == 0) {
        btn->config.long_press_ms = 1000;
    }

    ESP_LOGI(TAG, "Button created on GPIO %d", config->gpio);
    *handle = btn;
    return ESP_OK;
}

esp_err_t button_delete(button_handle_t handle) {
    if (handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    handle->in_use = false;
    return ESP_OK;
}

bool button_is_pressed(button_handle_t handle) {
    if (handle == NULL || !handle->in_use) {
        return false;
    }
    return handle->is_pressed;
}
