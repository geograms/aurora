# Geogram ESP32 Firmware Summary

This repository contains ESP32 firmware for Geogram network stations, with a primary target of the ESP32-S3 ePaper 1.54" board and a skeleton for generic ESP32 and ESP32-C3 mini variants.

## High-level architecture

- Entry point is `code/src/main.cpp`, which selects board models at compile time and wires together board init, UI, networking, and services.
- Board-specific initialization lives in `code/components/geogram_model_*`, e.g. `code/components/geogram_model_epaper_1in54/model_init.c` for power, NVS, I2C, display, RTC, sensors, buttons, and SD card.
- Shared subsystems are split into components:
  - Networking: `code/components/geogram_wifi`, `code/components/geogram_http`, `code/components/geogram_ws`
  - Station state/API: `code/components/geogram_station`
  - Console/remote access: `code/components/geogram_console`, `code/components/geogram_telnet`, `code/components/geogram_ssh`
  - UI/display: `code/components/geogram_lvgl`, `code/components/geogram_ui`, `code/components/geogram_epaper_1in54`
  - Sensors/RTC: `code/components/geogram_shtc3`, `code/components/geogram_pcf85063`
  - Storage/maps/updates: `code/components/geogram_sdcard`, `code/components/geogram_tiles`, `code/components/geogram_updates`
  - Geolocation: `code/components/geogram_geoloc`
  - NOSTR keys/callsign: `code/components/geogram_nostr`

## Boot flow (ESP32-S3 ePaper 1.54")

1. `app_main` logs firmware/version and initializes the board via `model_init`.
2. Hardware handles for display, RTC, and sensors are obtained from the model layer.
3. LVGL is initialized and the UI is created; the display is refreshed on boot.
4. NOSTR keys are initialized to derive a callsign (used for SSID and station identity).
5. WiFi starts and attempts STA credentials; if missing, it starts AP mode for configuration.
6. Sensor and RTC tasks update the UI and uptime continuously.

## Networking and services

- WiFi abstraction is defined in `code/components/geogram_wifi/include/wifi_bsp.h` with STA/AP support and NVS-stored credentials.
- HTTP server (`code/components/geogram_http`) serves a WiFi configuration portal and the Station API endpoints (plus WebSocket support).
- Station state (`code/components/geogram_station/station.c`) tracks clients, uptime, callsign, and geolocation, and builds JSON responses for API usage.
- Telnet/SSH/Serial console provide CLI access for device management.

## Mesh mode (optional)

- When `CONFIG_GEOGRAM_MESH_ENABLED` is set, mesh events in `code/src/main.cpp` start or stop AP/HTTP/Telnet services and enable bridging.

## Key files to start with

- `code/src/main.cpp` - firmware entry point and overall wiring
- `code/components/geogram_model_epaper_1in54/model_init.c` - primary board init
- `code/components/geogram_station/station.c` - station state and JSON
- `code/components/geogram_http/http_server.c` - WiFi config + API server
- `code/components/geogram_wifi/wifi_bsp.c` - WiFi abstraction

