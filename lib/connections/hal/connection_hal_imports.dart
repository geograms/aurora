/*
 * Transport HAL — engine-side WASM imports for hal.lora.
 *
 * These are stubs today (fixed sentinel return values); they moved out of
 * WappEngine so all connection code lives under lib/connections/. The engine
 * still owns the `stubI32` / `stubVoid` factories (they close over its
 * WasmFunction builder), so it passes them in and spreads the returned list
 * into its import table. The import names, param types and sentinel values
 * are unchanged, so the ABI presented to WASM modules is identical.
 *
 * hal.http is now implemented for real in WappEngine (backed by the internet
 * transport's HttpTransport) and hal.ble is real too — neither is stubbed
 * here. What remains is hal.lora, pending real radio hardware.
 */

import 'package:wasm_run/wasm_run.dart';

/// Build the `hal` imports for the transport functionalities. [stubVoid] and
/// [stubI32] are the engine's stub factories.
List<WasmImport> connectionHalImports({
  required WasmFunction Function(List<ValueTy> params) stubVoid,
  required WasmFunction Function(List<ValueTy> params, int value) stubI32,
}) {
  return [
    // LoRa (stubs)
    WasmImport('hal', 'lora_available_hw', stubI32([], 0)),
    WasmImport('hal', 'lora_send', stubI32([ValueTy.i32, ValueTy.i32], -1)),
    WasmImport('hal', 'lora_available', stubI32([], 0)),
    WasmImport('hal', 'lora_recv', stubI32([ValueTy.i32, ValueTy.i32], 0)),
    // BLE (ble_*) is implemented for real in WappEngine, backed by the shared
    // BleService (lib/connections/bluetooth/ble_service.dart) — NOT stubbed
    // here, so multiple wapps share the single adapter.
  ];
}
