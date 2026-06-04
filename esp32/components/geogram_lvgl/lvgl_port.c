/**
 * @file lvgl_port.c
 * @brief LVGL port for Geogram e-paper display
 */

#include <stdio.h>
#include <string.h>
#include "lvgl_port.h"
#include "lvgl.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "esp_task_wdt.h"
#include "nvs.h"

static const char *TAG = "lvgl_port";

// NVS namespace and key for rotation persistence
#define NVS_NAMESPACE "display"
#define NVS_KEY_ROTATION "rotation"

#define LVGL_TASK_PRIORITY      5
#define LVGL_TASK_STACK_SIZE    4096
#define LVGL_TICK_PERIOD_MS     5

// Display dimensions
#define EPD_WIDTH   200
#define EPD_HEIGHT  200

// LVGL buffer size (full screen)
#define LVGL_BUFF_SIZE (EPD_WIDTH * EPD_HEIGHT)

// Static handles
static epaper_1in54_handle_t s_epaper = NULL;
static lv_disp_draw_buf_t s_draw_buf;
static lv_disp_drv_t s_disp_drv;
static lv_disp_t *s_disp = NULL;
static lv_color_t *s_buf1 = NULL;
static TaskHandle_t s_lvgl_task = NULL;
static SemaphoreHandle_t s_lvgl_mutex = NULL;
static bool s_use_full_refresh = false;
static int s_rotation_degrees = 0;  // Current rotation: 0, 90, 180, 270

/**
 * @brief Load rotation from NVS
 */
static void load_rotation_from_nvs(void)
{
    nvs_handle_t nvs_handle;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READONLY, &nvs_handle);
    if (err == ESP_OK) {
        int32_t rotation = 0;
        err = nvs_get_i32(nvs_handle, NVS_KEY_ROTATION, &rotation);
        if (err == ESP_OK) {
            // Validate rotation value
            if (rotation == 0 || rotation == 90 || rotation == 180 || rotation == 270) {
                s_rotation_degrees = (int)rotation;
                ESP_LOGI(TAG, "Loaded rotation from NVS: %d degrees", s_rotation_degrees);
            }
        } else if (err == ESP_ERR_NVS_NOT_FOUND) {
            ESP_LOGI(TAG, "No saved rotation found, using default: 0 degrees");
        }
        nvs_close(nvs_handle);
    } else {
        ESP_LOGW(TAG, "Failed to open NVS for reading rotation: %s", esp_err_to_name(err));
    }
}

/**
 * @brief Save rotation to NVS
 */
static void save_rotation_to_nvs(void)
{
    nvs_handle_t nvs_handle;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &nvs_handle);
    if (err == ESP_OK) {
        err = nvs_set_i32(nvs_handle, NVS_KEY_ROTATION, (int32_t)s_rotation_degrees);
        if (err == ESP_OK) {
            err = nvs_commit(nvs_handle);
            if (err == ESP_OK) {
                ESP_LOGI(TAG, "Saved rotation to NVS: %d degrees", s_rotation_degrees);
            }
        }
        nvs_close(nvs_handle);
    } else {
        ESP_LOGW(TAG, "Failed to open NVS for writing rotation: %s", esp_err_to_name(err));
    }
}

/**
 * @brief Transform coordinates based on rotation
 */
static void transform_coords(int x, int y, int *tx, int *ty)
{
    switch (s_rotation_degrees) {
        case 90:
            *tx = EPD_HEIGHT - 1 - y;
            *ty = x;
            break;
        case 180:
            *tx = EPD_WIDTH - 1 - x;
            *ty = EPD_HEIGHT - 1 - y;
            break;
        case 270:
            *tx = y;
            *ty = EPD_WIDTH - 1 - x;
            break;
        default: // 0 degrees
            *tx = x;
            *ty = y;
            break;
    }
}

/**
 * @brief LVGL display flush callback for e-paper
 *
 * Converts LVGL's 16-bit color to 1-bit e-paper format.
 */
static void epaper_flush_cb(lv_disp_drv_t *drv, const lv_area_t *area, lv_color_t *color_map)
{
    if (s_epaper == NULL) {
        lv_disp_flush_ready(drv);
        return;
    }

    // Clear the e-paper buffer
    epaper_1in54_clear(s_epaper);

    // Convert LVGL color buffer to e-paper 1-bit format with rotation
    uint16_t *buffer = (uint16_t *)color_map;

    for (int y = area->y1; y <= area->y2; y++) {
        for (int x = area->x1; x <= area->x2; x++) {
            // LVGL uses RGB565 - check brightness threshold
            // If pixel value is dark (< half brightness), draw black
            uint16_t pixel = *buffer++;
            epaper_color_t color = (pixel < 0x7FFF) ? EPAPER_COLOR_BLACK : EPAPER_COLOR_WHITE;

            // Apply rotation transformation
            int tx, ty;
            transform_coords(x, y, &tx, &ty);
            epaper_1in54_draw_pixel(s_epaper, tx, ty, color);
        }
    }

    // Feed watchdog before long e-paper refresh operation
    esp_task_wdt_reset();

    // Refresh display
    if (s_use_full_refresh) {
        epaper_1in54_init(s_epaper);
        esp_task_wdt_reset();  // Feed watchdog again
        epaper_1in54_refresh(s_epaper);
        s_use_full_refresh = false;
    } else {
        epaper_1in54_init_partial(s_epaper);
        esp_task_wdt_reset();  // Feed watchdog again
        epaper_1in54_refresh_partial(s_epaper);
    }

    // Signal LVGL that flush is complete
    lv_disp_flush_ready(drv);
}

/**
 * @brief LVGL task - handles timer and refresh
 */
static void lvgl_task(void *pvParameter)
{
    ESP_LOGI(TAG, "LVGL task started");

    // Subscribe to task watchdog but with longer timeout for e-paper operations
    esp_task_wdt_add(NULL);

    while (1) {
        // Feed watchdog before potentially long operations
        esp_task_wdt_reset();

        if (xSemaphoreTake(s_lvgl_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
            lv_timer_handler();
            xSemaphoreGive(s_lvgl_mutex);
        }
        vTaskDelay(pdMS_TO_TICKS(LVGL_TICK_PERIOD_MS));
    }
}

esp_err_t lvgl_port_init(epaper_1in54_handle_t epaper_handle)
{
    if (epaper_handle == NULL) {
        ESP_LOGE(TAG, "Invalid e-paper handle");
        return ESP_ERR_INVALID_ARG;
    }

    s_epaper = epaper_handle;

    // Load saved rotation from NVS
    load_rotation_from_nvs();

    // Create mutex for thread safety
    s_lvgl_mutex = xSemaphoreCreateMutex();
    if (s_lvgl_mutex == NULL) {
        ESP_LOGE(TAG, "Failed to create LVGL mutex");
        return ESP_ERR_NO_MEM;
    }

    // Initialize LVGL library
    lv_init();

    // Allocate draw buffer from SPIRAM (PSRAM) for better memory management
    // The buffer is large (200x200x2 = 80KB) so SPIRAM is preferred
    s_buf1 = (lv_color_t *)heap_caps_malloc(LVGL_BUFF_SIZE * sizeof(lv_color_t), MALLOC_CAP_SPIRAM);
    if (s_buf1 == NULL) {
        // Fallback to DMA-capable internal RAM
        ESP_LOGW(TAG, "SPIRAM allocation failed, trying DMA-capable memory");
        s_buf1 = (lv_color_t *)heap_caps_malloc(LVGL_BUFF_SIZE * sizeof(lv_color_t), MALLOC_CAP_DMA);
    }
    if (s_buf1 == NULL) {
        // Last resort: regular internal RAM
        ESP_LOGW(TAG, "DMA allocation failed, trying regular memory");
        s_buf1 = (lv_color_t *)malloc(LVGL_BUFF_SIZE * sizeof(lv_color_t));
    }
    if (s_buf1 == NULL) {
        ESP_LOGE(TAG, "Failed to allocate LVGL buffer");
        vSemaphoreDelete(s_lvgl_mutex);
        return ESP_ERR_NO_MEM;
    }
    ESP_LOGI(TAG, "LVGL buffer allocated: %d bytes", LVGL_BUFF_SIZE * sizeof(lv_color_t));

    // Initialize draw buffer
    lv_disp_draw_buf_init(&s_draw_buf, s_buf1, NULL, LVGL_BUFF_SIZE);

    // Initialize display driver
    lv_disp_drv_init(&s_disp_drv);
    s_disp_drv.hor_res = EPD_WIDTH;
    s_disp_drv.ver_res = EPD_HEIGHT;
    s_disp_drv.flush_cb = epaper_flush_cb;
    s_disp_drv.draw_buf = &s_draw_buf;
    s_disp_drv.full_refresh = 1;  // E-paper needs full buffer transfers
    // NOTE: sw_rotate disabled - rotation handled in flush callback

    // Register display driver
    s_disp = lv_disp_drv_register(&s_disp_drv);
    if (s_disp == NULL) {
        ESP_LOGE(TAG, "Failed to register display driver");
        free(s_buf1);
        vSemaphoreDelete(s_lvgl_mutex);
        return ESP_FAIL;
    }

    // Apply mono theme for e-paper
    lv_theme_t *theme = lv_theme_mono_init(s_disp, false, &lv_font_montserrat_14);
    lv_disp_set_theme(s_disp, theme);

    // Create LVGL task
    BaseType_t ret = xTaskCreate(lvgl_task, "lvgl_task", LVGL_TASK_STACK_SIZE,
                                  NULL, LVGL_TASK_PRIORITY, &s_lvgl_task);
    if (ret != pdPASS) {
        ESP_LOGE(TAG, "Failed to create LVGL task");
        free(s_buf1);
        vSemaphoreDelete(s_lvgl_mutex);
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "LVGL port initialized");
    return ESP_OK;
}

esp_err_t lvgl_port_deinit(void)
{
    if (s_lvgl_task != NULL) {
        vTaskDelete(s_lvgl_task);
        s_lvgl_task = NULL;
    }

    if (s_buf1 != NULL) {
        free(s_buf1);
        s_buf1 = NULL;
    }

    if (s_lvgl_mutex != NULL) {
        vSemaphoreDelete(s_lvgl_mutex);
        s_lvgl_mutex = NULL;
    }

    s_epaper = NULL;
    s_disp = NULL;

    return ESP_OK;
}

void lvgl_port_refresh(bool full_refresh)
{
    s_use_full_refresh = full_refresh;
    if (s_disp != NULL && lvgl_port_lock(500)) {
        lv_obj_invalidate(lv_scr_act());
        lvgl_port_unlock();
        ESP_LOGI(TAG, "Display refresh requested (full=%d)", full_refresh);
    }
}

bool lvgl_port_lock(uint32_t timeout_ms)
{
    if (s_lvgl_mutex == NULL) {
        return false;
    }
    return xSemaphoreTake(s_lvgl_mutex, pdMS_TO_TICKS(timeout_ms)) == pdTRUE;
}

void lvgl_port_unlock(void)
{
    if (s_lvgl_mutex != NULL) {
        xSemaphoreGive(s_lvgl_mutex);
    }
}

void lvgl_port_rotate_cw(void)
{
    if (s_disp == NULL) {
        return;
    }

    // Cycle through rotations: 0 -> 90 -> 180 -> 270 -> 0
    s_rotation_degrees = (s_rotation_degrees + 90) % 360;
    ESP_LOGI(TAG, "Display rotation set to %d degrees", s_rotation_degrees);

    // Save rotation to NVS for persistence across reboots
    save_rotation_to_nvs();

    // Trigger a full refresh to apply rotation
    s_use_full_refresh = true;
    if (lvgl_port_lock(100)) {
        lv_obj_invalidate(lv_scr_act());
        lvgl_port_unlock();
    }
}

int lvgl_port_get_rotation(void)
{
    return s_rotation_degrees;
}
