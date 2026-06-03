/*
 * lib/connections/ — Aurora's transport subsystem.
 *
 * The single home for connection code: the capability model wapps reason
 * about, the registry of known transports, the transports themselves
 * (internet today; LAN/Bluetooth/LoRa/USB stubs), the relocated transport
 * HAL ABI (hal/), and the one host-side HTTP client.
 *
 * Import this barrel for the public surface; reach into subfolders only for
 * a specific transport implementation.
 */

export 'connection.dart';
export 'connection_registry.dart';
export 'builtin_connections.dart';
export 'internet/internet_connection.dart';
export 'internet/http_transport.dart';
export 'lan/lan_connection.dart';
export 'bluetooth/bluetooth_connection.dart';
export 'lora/lora_connection.dart';
export 'usb/usb_connection.dart';
