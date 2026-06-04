#ifndef MODEL_CONFIG_H
#define MODEL_CONFIG_H

#include "driver/gpio.h"

// ============================================================================
// Board Identification
// ============================================================================
#define MODEL_NAME              "ESP32-C3-mini"
#define MODEL_VARIANT           "Minimal"

// ============================================================================
// Feature Flags - ESP32-C3 mini has no peripherals
// ============================================================================
#ifndef HAS_DISPLAY
#define HAS_DISPLAY             0
#endif

#ifndef HAS_EPAPER_DISPLAY
#define HAS_EPAPER_DISPLAY      0
#endif

#ifndef HAS_RTC
#define HAS_RTC                 0
#endif

#ifndef HAS_HUMIDITY_SENSOR
#define HAS_HUMIDITY_SENSOR     0
#endif

#ifndef HAS_PSRAM
#define HAS_PSRAM               0
#endif

#ifndef HAS_SDCARD
#define HAS_SDCARD              0
#endif

#ifndef HAS_LED
#define HAS_LED                 1
#endif

// ============================================================================
// ESP32-C3 GPIO Defaults
// ============================================================================

// WS2812 RGB LED (ESP32-C3 Super Mini has LED on GPIO8)
#define LED_PIN                 GPIO_NUM_8

// I2C (ESP32-C3 typical defaults)
#define I2C_PIN_SDA             GPIO_NUM_5
#define I2C_PIN_SCL             GPIO_NUM_4

// Button (boot button on GPIO9 for ESP32-C3)
#define BTN_PIN_BOOT            GPIO_NUM_9
#define BTN_ACTIVE_LEVEL        0

#endif // MODEL_CONFIG_H
