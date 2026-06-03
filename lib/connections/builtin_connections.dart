/*
 * Registers the built-in transports into the ConnectionRegistry.
 *
 * Called once at boot (see lib/main.dart). Internet is live; LAN, Bluetooth,
 * LoRa and USB are capability-declaring stubs that report unavailable until
 * their I/O is implemented.
 */

import 'bluetooth/bluetooth_connection.dart';
import 'connection_registry.dart';
import 'internet/internet_connection.dart';
import 'lan/lan_connection.dart';
import 'lora/lora_connection.dart';
import 'usb/usb_connection.dart';

void registerBuiltinConnections() {
  final reg = ConnectionRegistry.instance;
  reg.register(InternetConnection());
  reg.register(LanConnection());
  reg.register(BluetoothConnection());
  reg.register(LoraConnection());
  reg.register(UsbConnection());
}
