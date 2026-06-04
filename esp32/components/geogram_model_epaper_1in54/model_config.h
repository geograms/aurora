#ifndef MODEL_CONFIG_H
#define MODEL_CONFIG_H

#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "driver/i2c.h"

// ============================================================================
// Board Identification
// ============================================================================
#define MODEL_NAME              "ESP32-S3-ePaper-1.54"
#define MODEL_VARIANT           "Waveshare"

// ============================================================================
// SPI Configuration - E-Paper Display
// ============================================================================
#define EPD_SPI_HOST            SPI2_HOST
#define EPD_SPI_CLOCK_HZ        (40 * 1000 * 1000)

// E-Paper Pin Definitions
#define EPD_PIN_DC              GPIO_NUM_10
#define EPD_PIN_CS              GPIO_NUM_11
#define EPD_PIN_SCK             GPIO_NUM_12
#define EPD_PIN_MOSI            GPIO_NUM_13
#define EPD_PIN_RST             GPIO_NUM_9
#define EPD_PIN_BUSY            GPIO_NUM_8

// E-Paper Display Dimensions
#define EPD_WIDTH               200
#define EPD_HEIGHT              200
#define EPD_BUFFER_SIZE         (EPD_WIDTH * EPD_HEIGHT / 8)

// ============================================================================
// I2C Configuration
// ============================================================================
#define I2C_MASTER_PORT         I2C_NUM_0
#define I2C_PIN_SDA             GPIO_NUM_47
#define I2C_PIN_SCL             GPIO_NUM_48
#define I2C_MASTER_FREQ_HZ      300000

// I2C Device Addresses
#define I2C_ADDR_RTC            0x51    // PCF85063
#define I2C_ADDR_SHTC3          0x70    // SHTC3

// ============================================================================
// Power Control Pins
// ============================================================================
#define PWR_PIN_EPD             GPIO_NUM_6
#define PWR_PIN_AUDIO           GPIO_NUM_42
#define PWR_PIN_VBAT            GPIO_NUM_17

// Power control active levels (active low for EPD and Audio)
#define PWR_EPD_ON_LEVEL        0
#define PWR_EPD_OFF_LEVEL       1
#define PWR_AUDIO_ON_LEVEL      0
#define PWR_AUDIO_OFF_LEVEL     1
#define PWR_VBAT_ON_LEVEL       1
#define PWR_VBAT_OFF_LEVEL      0

// ============================================================================
// SD Card Configuration (1-bit SDMMC mode)
// ============================================================================
#define SDCARD_D0_PIN           GPIO_NUM_40
#define SDCARD_CLK_PIN          GPIO_NUM_39
#define SDCARD_CMD_PIN          GPIO_NUM_41
#define SDCARD_MOUNT_POINT      "/sdcard"

// ============================================================================
// Backlight/LED Configuration
// ============================================================================
#define BACKLIGHT_PIN           GPIO_NUM_3

// ============================================================================
// Button Configuration
// ============================================================================
#define BTN_PIN_BOOT            GPIO_NUM_0
#define BTN_PIN_POWER           GPIO_NUM_18
#define BTN_ACTIVE_LEVEL        0   // Active low

// ============================================================================
// Wake-up Configuration
// ============================================================================
#define WAKEUP_PIN_BOOT         GPIO_NUM_0
#define WAKEUP_PIN_RTC          GPIO_NUM_5
#define WAKEUP_PIN_POWER        GPIO_NUM_18

// ============================================================================
// Feature Flags
// ============================================================================
#ifndef HAS_EPAPER_DISPLAY
#define HAS_EPAPER_DISPLAY      1
#endif

#ifndef HAS_RTC
#define HAS_RTC                 1
#endif

#ifndef HAS_HUMIDITY_SENSOR
#define HAS_HUMIDITY_SENSOR     1
#endif

#ifndef HAS_PSRAM
#define HAS_PSRAM               1
#endif

#ifndef HAS_SDCARD
#define HAS_SDCARD              1
#endif

#endif // MODEL_CONFIG_H
