//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <ble_peripheral/ble_peripheral_plugin_c_api.h>
#include <bluetooth_low_energy_windows/bluetooth_low_energy_windows_plugin_c_api.h>
#include <file_selector_windows/file_selector_windows.h>
#include <permission_handler_windows/permission_handler_windows_plugin.h>
#include <sqlite3_flutter_libs/sqlite3_flutter_libs_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  BlePeripheralPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("BlePeripheralPluginCApi"));
  BluetoothLowEnergyWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("BluetoothLowEnergyWindowsPluginCApi"));
  FileSelectorWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FileSelectorWindows"));
  PermissionHandlerWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("PermissionHandlerWindowsPlugin"));
  Sqlite3FlutterLibsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("Sqlite3FlutterLibsPlugin"));
}
