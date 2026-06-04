#ifndef MODEL_CONFIG_H
#define MODEL_CONFIG_H

#include "driver/gpio.h"

// ============================================================================
// Board Identification
// ============================================================================
#define MODEL_NAME              "ESP32-Generic"
#define MODEL_VARIANT           "Generic"

// ============================================================================
// Feature Flags - Generic board has minimal features
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

// ============================================================================
// Placeholder pin definitions (to be customized per board)
// ============================================================================

// I2C (common ESP32 defaults)
#define I2C_PIN_SDA             GPIO_NUM_21
#define I2C_PIN_SCL             GPIO_NUM_22

// Button (boot button)
#define BTN_PIN_BOOT            GPIO_NUM_0
#define BTN_ACTIVE_LEVEL        0

#endif // MODEL_CONFIG_H
