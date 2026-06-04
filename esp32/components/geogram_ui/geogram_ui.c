/**
 * @file geogram_ui.c
 * @brief Geogram UI component for e-paper display
 */

#include <stdio.h>
#include <string.h>
#include "geogram_ui.h"
#include "lvgl_port.h"
#include "lvgl.h"
#include "esp_log.h"

static const char *TAG = "geogram_ui";

// UI element handles
static lv_obj_t *s_screen = NULL;
static lv_obj_t *s_lbl_temperature = NULL;
static lv_obj_t *s_lbl_humidity = NULL;
static lv_obj_t *s_lbl_time = NULL;
static lv_obj_t *s_lbl_date = NULL;
static lv_obj_t *s_lbl_wifi_status = NULL;
static lv_obj_t *s_lbl_ip_address = NULL;
static lv_obj_t *s_lbl_status = NULL;
static lv_obj_t *s_lbl_uptime = NULL;

// Styles
static lv_style_t s_style_title;
static lv_style_t s_style_value;
static lv_style_t s_style_small;
static lv_style_t s_style_line;

/**
 * @brief Initialize styles for the UI
 */
static void init_styles(void)
{
    // Title style (medium font)
    lv_style_init(&s_style_title);
    lv_style_set_text_font(&s_style_title, &lv_font_montserrat_14);
    lv_style_set_text_color(&s_style_title, lv_color_black());

    // Value style (large font for temperature/humidity)
    lv_style_init(&s_style_value);
    lv_style_set_text_font(&s_style_value, &lv_font_montserrat_24);
    lv_style_set_text_color(&s_style_value, lv_color_black());

    // Small style (for status messages)
    lv_style_init(&s_style_small);
    lv_style_set_text_font(&s_style_small, &lv_font_montserrat_12);
    lv_style_set_text_color(&s_style_small, lv_color_black());

    // Line style
    lv_style_init(&s_style_line);
    lv_style_set_line_width(&s_style_line, 1);
    lv_style_set_line_color(&s_style_line, lv_color_black());
}

/**
 * @brief Create a horizontal separator line
 */
static lv_obj_t *create_separator(lv_obj_t *parent, lv_coord_t y_pos)
{
    static lv_point_t line_points[] = {{0, 0}, {180, 0}};

    lv_obj_t *line = lv_line_create(parent);
    lv_line_set_points(line, line_points, 2);
    lv_obj_add_style(line, &s_style_line, 0);
    lv_obj_set_pos(line, 10, y_pos);

    return line;
}

esp_err_t geogram_ui_init(void)
{
    ESP_LOGI(TAG, "Initializing Geogram UI");

    // Acquire LVGL lock before creating UI elements
    if (!lvgl_port_lock(1000)) {
        ESP_LOGE(TAG, "Failed to acquire LVGL lock for UI init");
        return ESP_ERR_TIMEOUT;
    }

    // Initialize styles
    init_styles();

    // Get active screen
    s_screen = lv_scr_act();
    lv_obj_set_style_bg_color(s_screen, lv_color_white(), 0);

    // === Time and Date Section (Top) ===
    s_lbl_time = lv_label_create(s_screen);
    lv_obj_add_style(s_lbl_time, &s_style_value, 0);
    lv_label_set_text(s_lbl_time, "--:--");
    lv_obj_align(s_lbl_time, LV_ALIGN_TOP_MID, 0, 8);

    s_lbl_date = lv_label_create(s_screen);
    lv_obj_add_style(s_lbl_date, &s_style_small, 0);
    lv_label_set_text(s_lbl_date, "----/--/--");
    lv_obj_align_to(s_lbl_date, s_lbl_time, LV_ALIGN_OUT_BOTTOM_MID, 0, 2);

    // Separator after date
    create_separator(s_screen, 55);

    // === Temperature and Humidity Section (Middle) ===
    // Temperature
    lv_obj_t *lbl_temp_title = lv_label_create(s_screen);
    lv_obj_add_style(lbl_temp_title, &s_style_small, 0);
    lv_label_set_text(lbl_temp_title, "Temperature");
    lv_obj_set_pos(lbl_temp_title, 15, 62);

    s_lbl_temperature = lv_label_create(s_screen);
    lv_obj_add_style(s_lbl_temperature, &s_style_value, 0);
    lv_label_set_text(s_lbl_temperature, "--.-C");
    lv_obj_set_pos(s_lbl_temperature, 15, 76);

    // Humidity
    lv_obj_t *lbl_hum_title = lv_label_create(s_screen);
    lv_obj_add_style(lbl_hum_title, &s_style_small, 0);
    lv_label_set_text(lbl_hum_title, "Humidity");
    lv_obj_set_pos(lbl_hum_title, 110, 62);

    s_lbl_humidity = lv_label_create(s_screen);
    lv_obj_add_style(s_lbl_humidity, &s_style_value, 0);
    lv_label_set_text(s_lbl_humidity, "--%");
    lv_obj_set_pos(s_lbl_humidity, 110, 76);

    // Separator after sensor data
    create_separator(s_screen, 110);

    // === WiFi Status Section (Bottom) ===
    lv_obj_t *lbl_wifi_title = lv_label_create(s_screen);
    lv_obj_add_style(lbl_wifi_title, &s_style_small, 0);
    lv_label_set_text(lbl_wifi_title, "WiFi");
    lv_obj_set_pos(lbl_wifi_title, 15, 118);

    s_lbl_wifi_status = lv_label_create(s_screen);
    lv_obj_add_style(s_lbl_wifi_status, &s_style_title, 0);
    lv_label_set_text(s_lbl_wifi_status, "Disconnected");
    lv_obj_set_pos(s_lbl_wifi_status, 15, 132);

    s_lbl_ip_address = lv_label_create(s_screen);
    lv_obj_add_style(s_lbl_ip_address, &s_style_small, 0);
    lv_label_set_text(s_lbl_ip_address, "");
    lv_obj_set_pos(s_lbl_ip_address, 15, 150);

    // Uptime display (right side)
    s_lbl_uptime = lv_label_create(s_screen);
    lv_obj_add_style(s_lbl_uptime, &s_style_small, 0);
    lv_label_set_text(s_lbl_uptime, "Up: 0m");
    lv_obj_set_pos(s_lbl_uptime, 140, 150);

    // Separator before status
    create_separator(s_screen, 170);

    // === Status Message (Very Bottom) ===
    s_lbl_status = lv_label_create(s_screen);
    lv_obj_add_style(s_lbl_status, &s_style_small, 0);
    lv_label_set_text(s_lbl_status, "Geogram Ready");
    lv_obj_align(s_lbl_status, LV_ALIGN_BOTTOM_MID, 0, -8);

    ESP_LOGI(TAG, "UI initialized");

    // Release LVGL lock
    lvgl_port_unlock();

    return ESP_OK;
}

void geogram_ui_update_sensor(float temperature, float humidity)
{
    if (!lvgl_port_lock(100)) {
        ESP_LOGW(TAG, "Failed to acquire LVGL lock");
        return;
    }

    if (s_lbl_temperature != NULL) {
        char buf[16];
        snprintf(buf, sizeof(buf), "%.1fC", temperature);
        lv_label_set_text(s_lbl_temperature, buf);
    }

    if (s_lbl_humidity != NULL) {
        char buf[16];
        snprintf(buf, sizeof(buf), "%.0f%%", humidity);
        lv_label_set_text(s_lbl_humidity, buf);
    }

    lvgl_port_unlock();
}

void geogram_ui_update_wifi(ui_wifi_status_t status, const char *ip_address, const char *ssid)
{
    if (!lvgl_port_lock(100)) {
        ESP_LOGW(TAG, "Failed to acquire LVGL lock");
        return;
    }

    if (s_lbl_wifi_status != NULL) {
        switch (status) {
            case UI_WIFI_STATUS_DISCONNECTED:
                lv_label_set_text(s_lbl_wifi_status, "Disconnected");
                break;
            case UI_WIFI_STATUS_CONNECTING:
                if (ssid != NULL) {
                    char buf[32];
                    snprintf(buf, sizeof(buf), "-> %.16s", ssid);
                    lv_label_set_text(s_lbl_wifi_status, buf);
                } else {
                    lv_label_set_text(s_lbl_wifi_status, "Connecting...");
                }
                break;
            case UI_WIFI_STATUS_AP_MODE:
                if (ssid != NULL) {
                    char buf[32];
                    snprintf(buf, sizeof(buf), "AP: %.14s", ssid);
                    lv_label_set_text(s_lbl_wifi_status, buf);
                } else {
                    lv_label_set_text(s_lbl_wifi_status, "AP Mode");
                }
                break;
            case UI_WIFI_STATUS_CONNECTED:
                if (ssid != NULL) {
                    char buf[32];
                    snprintf(buf, sizeof(buf), "%.20s", ssid);
                    lv_label_set_text(s_lbl_wifi_status, buf);
                } else {
                    lv_label_set_text(s_lbl_wifi_status, "Connected");
                }
                break;
        }
    }

    if (s_lbl_ip_address != NULL) {
        if (ip_address != NULL && strlen(ip_address) > 0) {
            char buf[24];
            snprintf(buf, sizeof(buf), "IP: %s", ip_address);
            lv_label_set_text(s_lbl_ip_address, buf);
        } else {
            lv_label_set_text(s_lbl_ip_address, "");
        }
    }

    lvgl_port_unlock();
}

void geogram_ui_update_time(uint8_t hour, uint8_t minute)
{
    if (!lvgl_port_lock(100)) {
        return;
    }

    if (s_lbl_time != NULL) {
        char buf[8];
        snprintf(buf, sizeof(buf), "%02d:%02d", hour, minute);
        lv_label_set_text(s_lbl_time, buf);
    }

    lvgl_port_unlock();
}

void geogram_ui_update_date(uint16_t year, uint8_t month, uint8_t day)
{
    if (!lvgl_port_lock(100)) {
        return;
    }

    if (s_lbl_date != NULL) {
        char buf[16];
        snprintf(buf, sizeof(buf), "%04d/%02d/%02d", year, month, day);
        lv_label_set_text(s_lbl_date, buf);
    }

    lvgl_port_unlock();
}

void geogram_ui_show_status(const char *message)
{
    if (!lvgl_port_lock(100)) {
        return;
    }

    if (s_lbl_status != NULL && message != NULL) {
        lv_label_set_text(s_lbl_status, message);
    }

    lvgl_port_unlock();
}

void geogram_ui_refresh(bool full_refresh)
{
    lvgl_port_refresh(full_refresh);
}

void geogram_ui_update_uptime(uint32_t uptime_seconds)
{
    if (!lvgl_port_lock(100)) {
        return;
    }

    if (s_lbl_uptime != NULL) {
        char buf[16];
        uint32_t minutes = uptime_seconds / 60;
        uint32_t hours = minutes / 60;
        uint32_t days = hours / 24;

        if (days > 0) {
            snprintf(buf, sizeof(buf), "Up: %lud%luh", (unsigned long)days, (unsigned long)(hours % 24));
        } else if (hours > 0) {
            snprintf(buf, sizeof(buf), "Up: %luh%lum", (unsigned long)hours, (unsigned long)(minutes % 60));
        } else {
            snprintf(buf, sizeof(buf), "Up: %lum", (unsigned long)minutes);
        }
        lv_label_set_text(s_lbl_uptime, buf);
    }

    lvgl_port_unlock();
}
