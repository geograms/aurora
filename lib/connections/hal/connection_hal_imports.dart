/*
 * Transport HAL — engine-side WASM imports for hal.http / hal.lora / hal.ble.
 *
 * These are stubs today (fixed sentinel return values); they moved out of
 * WappEngine so all connection code lives under lib/connections/. The engine
 * still owns the `stubI32` / `stubVoid` factories (they close over its
 * WasmFunction builder), so it passes them in and spreads the returned list
 * into its import table. The import names, param types and sentinel values
 * are unchanged, so the ABI presented to WASM modules is identical.
 *
 * When a real implementation lands (e.g. hal_http_* backed by the internet
 * transport's HttpTransport), it replaces the stubs here.
 */

import 'package:wasm_run/wasm_run.dart';

/// Build the `hal` imports for the transport functionalities. [stubVoid] and
/// [stubI32] are the engine's stub factories.
List<WasmImport> connectionHalImports({
  required WasmFunction Function(List<ValueTy> params) stubVoid,
  required WasmFunction Function(List<ValueTy> params, int value) stubI32,
}) {
  return [
    // HTTP (stubs)
    WasmImport('hal', 'http_request', stubI32([ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32], -1)),
    WasmImport('hal', 'http_poll', stubI32([ValueTy.i32], -1)),
    WasmImport('hal', 'http_read_response', stubI32([ValueTy.i32, ValueTy.i32, ValueTy.i32], 0)),
    WasmImport('hal', 'http_status', stubI32([ValueTy.i32], -1)),
    WasmImport('hal', 'http_free', stubVoid([ValueTy.i32])),
    // LoRa (stubs)
    WasmImport('hal', 'lora_available_hw', stubI32([], 0)),
    WasmImport('hal', 'lora_send', stubI32([ValueTy.i32, ValueTy.i32], -1)),
    WasmImport('hal', 'lora_available', stubI32([], 0)),
    WasmImport('hal', 'lora_recv', stubI32([ValueTy.i32, ValueTy.i32], 0)),
    // BLE (stubs)
    WasmImport('hal', 'ble_scan_start', stubI32([], -1)),
    WasmImport('hal', 'ble_scan_stop', stubVoid([])),
    WasmImport('hal', 'ble_scan_read', stubI32([ValueTy.i32, ValueTy.i32], 0)),
    WasmImport('hal', 'ble_advertise', stubI32([ValueTy.i32, ValueTy.i32], -1)),
    WasmImport('hal', 'ble_advertise_stop', stubVoid([])),
  ];
}
