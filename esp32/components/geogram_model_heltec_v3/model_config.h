#ifndef MODEL_CONFIG_H
#define MODEL_CONFIG_H

#include "driver/gpio.h"

// ============================================================================
// Board Identification
// ============================================================================
#define MODEL_NAME              "Heltec-WiFi-LoRa-32-V3"
#define MODEL_VARIANT           "Heltec"

// ============================================================================
// SPI Configuration - SX1262 LoRa
// ============================================================================
#define LORA_SPI_HOST           SPI2_HOST
#define LORA_PIN_MOSI           GPIO_NUM_10
#define LORA_PIN_MISO           GPIO_NUM_11
#define LORA_PIN_SCK            GPIO_NUM_9
#define LORA_PIN_NSS            GPIO_NUM_8
#define LORA_PIN_RST            GPIO_NUM_12
#define LORA_PIN_BUSY           GPIO_NUM_13
#define LORA_PIN_DIO1           GPIO_NUM_14

// LoRa default frequency (868 MHz EU band)
#define LORA_DEFAULT_FREQ_HZ    868000000

// ============================================================================
// I2C Configuration - SSD1306 OLED
// ============================================================================
#define I2C_MASTER_PORT         I2C_NUM_0
#define I2C_PIN_SDA             GPIO_NUM_17
#define I2C_PIN_SCL             GPIO_NUM_18
#define I2C_MASTER_FREQ_HZ     400000
#define I2C_ADDR_OLED           0x3C

// OLED Reset Pin
#define OLED_PIN_RST            GPIO_NUM_21

// ============================================================================
// LED Configuration (white LED, PWM dimmable)
// ============================================================================
#define LED_PIN                 GPIO_NUM_35
#define LED_ACTIVE_LEVEL        1

// ============================================================================
// Vext Power Control (external peripherals power)
// ============================================================================
#define VEXT_PIN                GPIO_NUM_36
#define VEXT_ON_LEVEL           0   // Inverted: LOW = ON
#define VEXT_OFF_LEVEL          1   // HIGH = OFF

// ============================================================================
// Battery ADC
// ============================================================================
#define BATTERY_ADC_PIN         GPIO_NUM_1
#define BATTERY_ADC_SCALE       4.9f  // Divider: 390k / 100k

// ============================================================================
// Button Configuration (PRG button)
// ============================================================================
#define BTN_PIN_BOOT            GPIO_NUM_0
#define BTN_ACTIVE_LEVEL        0   // Active low

// ============================================================================
// Feature Flags
// ============================================================================
#ifndef HAS_DISPLAY
#define HAS_DISPLAY             1
#endif

#ifndef HAS_OLED_DISPLAY
#define HAS_OLED_DISPLAY        1
#endif

#ifndef HAS_EPAPER_DISPLAY
#define HAS_EPAPER_DISPLAY      0
#endif

#ifndef HAS_LORA
#define HAS_LORA                1
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

#ifndef HAS_BATTERY_ADC
#define HAS_BATTERY_ADC         1
#endif

#endif // MODEL_CONFIG_H
