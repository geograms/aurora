# Geogram Serial Console CLI

The Geogram firmware provides a serial console interface for device control, configuration, and debugging. Connect via UART at 115200 baud.

## Getting Started

Connect to the device's serial port (UART0) using a terminal emulator:

```
screen /dev/ttyUSB0 115200
# or
picocom -b 115200 /dev/ttyUSB0
```

You'll see the prompt:

```
Geogram Serial Console
Type 'help' for available commands

geogram>
```

## Features

- **Line editing**: Use arrow keys to navigate, backspace to delete
- **Command history**: Use up/down arrows to recall previous commands
- **Tab completion**: Press Tab to auto-complete commands
- **JSON output mode**: Switch to JSON output for automation scripts

## Command Reference

### System Commands

#### `status`
Display full device status including firmware version, WiFi, sensors, and memory.

```
geogram> status

=== Geogram Device Status ===

Firmware: 1.0.0
Board: ESP32S3-ePaper-1.54
Callsign: ESPAB12
Uptime: 1h 23m 45s

WiFi: Connected (192.168.1.50)

Sensors:
  Temperature: 23.5 C
  Humidity: 45.2 %

SD Card: Mounted (7.45 GB)
Heap: 245632 bytes free
```

#### `version`
Display firmware version.

```
geogram> version
1.0.0
```

#### `reboot`
Reboot the device.

```
geogram> reboot
Rebooting...
```

#### `heap`
Display free heap memory.

```
geogram> heap
Free heap: 245632 bytes
Minimum free heap: 198456 bytes
```

#### `uptime`
Display device uptime.

```
geogram> uptime
Uptime: 2h 15m 30s
```

#### `format [text|json]`
Get or set the output format. JSON mode is useful for automation.

```
geogram> format
Current format: text

geogram> format json
Output format set to JSON

geogram> status
{"version":"1.0.0","callsign":"ESPAB12","uptime":5025,"wifi":"connected","ip":"192.168.1.51"}
```

#### `log <level>`
Set the ESP-IDF log level.

Levels: `none`, `error`, `warn`, `info`, `debug`, `verbose`

```
geogram> log debug
Log level set to debug
```

### WiFi Commands

#### `wifi`
Display current WiFi status.

```
geogram> wifi
WiFi: Connected
IP: 192.168.1.50
```

#### `wifi_connect <ssid> [password]`
Connect to a WiFi network. Credentials are automatically saved to NVS for reconnection on reboot.

```
geogram> wifi_connect MyNetwork secret123
Connecting to MyNetwork...
```

For open networks, omit the password:

```
geogram> wifi_connect OpenNetwork
Connecting to OpenNetwork...
```

#### `wifi_disconnect`
Disconnect from the current WiFi network.

```
geogram> wifi_disconnect
Disconnecting from WiFi...
Disconnected
```

#### `wifi_clear`
Clear saved WiFi credentials from NVS. The device will not auto-reconnect on next boot.

```
geogram> wifi_clear
WiFi credentials cleared
```

#### `wifi_saved`
Display saved WiFi credentials (password is masked).

```
geogram> wifi_saved
Saved SSID: MyNetwork
Password: ********
```

### Display Commands

#### `display`
Show current display status.

```
geogram> display
Display rotation: 0 degrees
```

#### `display_rotate [angle]`
Rotate the display. Valid angles: `0`, `90`, `180`, `270`. Omit angle to cycle through rotations.

```
geogram> display_rotate 90
Display rotated to 90 degrees

geogram> display_rotate
Display rotated to 180 degrees
```

#### `display_refresh [-f]`
Trigger a display refresh. Use `-f` for a full refresh (clears ghosting on e-paper).

```
geogram> display_refresh
Performing partial display refresh...
Display refreshed

geogram> display_refresh -f
Performing full display refresh...
Display refreshed
```

### Configuration Commands

#### `config`
Display all configuration settings.

```
geogram> config

=== Configuration ===

Callsign: ESPAB12
Firmware: 1.0.0
Board: ESP32S3-ePaper-1.54
Display rotation: 0 degrees

WiFi SSID: MyNetwork
WiFi Password: ********
```

#### `config_reset`
Reset all configuration to factory defaults. Clears WiFi credentials, display settings, and application settings.

```
geogram> config_reset
Resetting all configuration...
Configuration reset. Reboot to apply changes.
```

### NVS (Non-Volatile Storage) Commands

Low-level commands for inspecting and modifying NVS storage.

#### `nvs_list`
List known NVS namespaces.

```
geogram> nvs_list
Known NVS namespaces:
  wifi_config - WiFi credentials
  display     - Display settings
  geogram     - Application settings
```

#### `nvs_get <namespace> <key>`
Read a value from NVS.

```
geogram> nvs_get wifi_config ssid
wifi_config/ssid = "MyNetwork" (string)

geogram> nvs_get display rotation
display/rotation = 90 (i32)
```

#### `nvs_set <namespace> <key> <value> [-t <type>]`
Write a value to NVS. Default type is `str` (string).

Types: `str`, `i32`, `u32`

```
geogram> nvs_set geogram device_name "My Geogram"
Set geogram/device_name = My Geogram

geogram> nvs_set display rotation 180 -t i32
Set display/rotation = 180
```

#### `nvs_erase <namespace> [key]`
Erase a key or entire namespace from NVS.

```
geogram> nvs_erase geogram device_name
Erased key 'device_name' from namespace 'geogram'

geogram> nvs_erase wifi_config
Erased all keys from namespace 'wifi_config'
```

## JSON Output Mode

When `format json` is enabled, commands output machine-parseable JSON:

```
geogram> format json
Output format set to JSON

geogram> status
{"version":"1.0.0","callsign":"ESPAB12","uptime":5025,"wifi":"connected","ip":"192.168.1.51"}

geogram> wifi
{"status":"connected","ip":"192.168.1.50"}

geogram> heap
{"free":245632,"minimum":198456}

geogram> uptime
{"uptime":8130}

geogram> display
{"rotation":90}

geogram> config
{"callsign":"ESPAB12","version":"1.0.0","board":"ESP32S3-ePaper-1.54","display_rotation":90,"wifi_ssid":"MyNetwork"}
```

## Automation Example

Python script to interact with the console:

```python
import serial
import json

ser = serial.Serial('/dev/ttyUSB0', 115200, timeout=1)

def send_command(cmd):
    ser.write(f"{cmd}\n".encode())
    response = ser.readline().decode().strip()
    return response

# Switch to JSON mode
send_command("format json")

# Get status
status = json.loads(send_command("status"))
print(f"Device: {status['callsign']}, Uptime: {status['uptime']}s")

# Connect to WiFi
send_command("wifi_connect MyNetwork secret123")
```
