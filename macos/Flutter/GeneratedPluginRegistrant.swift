//
//  Generated file. Do not edit.
//

import FlutterMacOS
import Foundation

import ble_peripheral
import bluetooth_low_energy_darwin
import file_selector_macos
import geolocator_apple
import path_provider_foundation
import shared_preferences_foundation
import sqlite3_flutter_libs

func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {
  BlePeripheralPlugin.register(with: registry.registrar(forPlugin: "BlePeripheralPlugin"))
  BluetoothLowEnergyDarwinPlugin.register(with: registry.registrar(forPlugin: "BluetoothLowEnergyDarwinPlugin"))
  FileSelectorPlugin.register(with: registry.registrar(forPlugin: "FileSelectorPlugin"))
  GeolocatorPlugin.register(with: registry.registrar(forPlugin: "GeolocatorPlugin"))
  PathProviderPlugin.register(with: registry.registrar(forPlugin: "PathProviderPlugin"))
  SharedPreferencesPlugin.register(with: registry.registrar(forPlugin: "SharedPreferencesPlugin"))
  Sqlite3FlutterLibsPlugin.register(with: registry.registrar(forPlugin: "Sqlite3FlutterLibsPlugin"))
}
