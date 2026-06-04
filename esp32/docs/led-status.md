# LED Status Indicator

This document describes the LED status indicator system for ESP32-C3 boards.

## Overview

The ESP32-C3 Super Mini board includes an addressable WS2812 RGB LED on GPIO8. This LED provides visual feedback about the device's operational status.

## Hardware

| Board | LED Type | GPIO Pin |
|-------|----------|----------|
| ESP32-C3 Super Mini | WS2812 RGB | GPIO8 |

## LED States

| State | Color | Pattern | Meaning |
|-------|-------|---------|---------|
| Boot/Connecting | Yellow | Blinking (500ms) | Device is starting up |
| System OK | Green | Solid | WiFi AP running, system operating normally |
| Error | Red | Blinking (500ms) | WiFi or system initialization failed |
| Chat Notification | Blue | 3 blinks (150ms) | Incoming chat message received |

## State Transitions

```
Boot
  │
  ▼
[Yellow Blinking] ──► WiFi Init Failed ──► [Red Blinking]
  │
  ▼
WiFi AP Started
  │
  ▼
[Green Solid] ◄───────────────────────────────────────────
       │                                                  │
       │ Chat Message                                     │
       ▼                                                  │
[Blue 3x Blink] ──► Return to Green ──────────────────────┘
```

## API Reference

### Initialization

```c
#include "led_bsp.h"

// Initialize LED on specified GPIO
esp_err_t led_init(int gpio_num);

// Deinitialize LED driver
void led_deinit(void);
```

### Basic Control

```c
// Set LED to predefined color
esp_err_t led_set_color(led_color_t color);

// Set LED to custom RGB value
esp_err_t led_set_rgb(uint8_t r, uint8_t g, uint8_t b);

// Turn LED off
esp_err_t led_off(void);
```

### Available Colors

```c
typedef enum {
    LED_COLOR_OFF,
    LED_COLOR_RED,
    LED_COLOR_GREEN,
    LED_COLOR_BLUE,
    LED_COLOR_WHITE,
    LED_COLOR_YELLOW,
    LED_COLOR_CYAN,
    LED_COLOR_MAGENTA,
} led_color_t;
```

### State Management

```c
// Set LED to a status state (manages blinking automatically)
esp_err_t led_set_state(led_state_t state);

// Get current state
led_state_t led_get_state(void);
```

### Available States

```c
typedef enum {
    LED_STATE_OFF,          // LED off
    LED_STATE_OK,           // Solid green
    LED_STATE_ERROR,        // Blinking red
    LED_STATE_CONNECTING,   // Blinking yellow
} led_state_t;
```

### Notifications

```c
// Blink LED a specific number of times
esp_err_t led_blink(led_color_t color, int count, int on_ms, int off_ms);

// Convenience function for chat notifications (blue, 3 blinks)
esp_err_t led_notify_chat(void);
```

## Configuration

The LED is configured in the board's `model_config.h`:

```c
// Enable LED support
#define HAS_LED     1

// GPIO pin for WS2812 LED
#define LED_PIN     GPIO_NUM_8
```

## Implementation Details

### WS2812 Protocol

The driver uses the ESP-IDF RMT (Remote Control) peripheral to generate the precise timing required by WS2812 LEDs:

| Signal | Duration |
|--------|----------|
| T0H (bit 0 high) | 350ns |
| T0L (bit 0 low) | 900ns |
| T1H (bit 1 high) | 900ns |
| T1L (bit 1 low) | 350ns |
| Reset | 280us |

### Memory Usage

The LED driver uses minimal resources:
- ~2KB code
- ~512 bytes RAM for RMT buffers
- One FreeRTOS task for blinking states (~2KB stack)

### Thread Safety

All LED functions are thread-safe. A mutex protects concurrent access to the LED hardware.

## Integration Points

### Board Initialization (model_init.c)

```c
#if HAS_LED
    ret = led_init(LED_PIN);
    if (ret == ESP_OK) {
        led_set_state(LED_STATE_CONNECTING);
    }
#endif
```

### Mesh Events (main.cpp)

```c
case GEOGRAM_MESH_EVENT_CONNECTED:
    led_set_state(LED_STATE_OK);
    break;

case GEOGRAM_MESH_EVENT_DISCONNECTED:
    led_set_state(LED_STATE_ERROR);
    break;
```

### Chat Messages (mesh_chat.c)

```c
// On incoming message from another node
led_notify_chat();
```

## Files Reference

| File | Description |
|------|-------------|
| `components/geogram_led/include/led_bsp.h` | Public API header |
| `components/geogram_led/led_bsp.c` | WS2812 driver implementation |
| `components/geogram_led/CMakeLists.txt` | Build configuration |
| `components/geogram_model_esp32c3_mini/model_config.h` | LED pin configuration |
