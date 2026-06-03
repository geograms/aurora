/*
 * Transport HAL ABI — the wapp-facing endpoint definitions for the
 * connection capabilities (hal.http, hal.lora, hal.ble).
 *
 * These used to live inline in lib/wapp/functionality_registry.dart. They
 * moved here so all connection code has one home; the registry spreads
 * [connectionFunctionalities] back into its core functionalities map, so
 * the ABI advertised to WASM modules is unchanged.
 *
 * The matching engine-side import stubs are in connection_hal_imports.dart.
 */

import '../../wapp/functionality_def.dart';

/// hal.http / hal.lora / hal.ble endpoint definitions, keyed by id.
final Map<String, FunctionalityDef> connectionFunctionalities =
    <String, FunctionalityDef>{
  'hal.http':
      FunctionalityDef('hal.http', 'HTTP requests (async polling)', [
    EndpointDef('hal_http_request', 'Start an HTTP request', [
      ParamDef('method', 'int', '0=GET, 1=POST, 2=PUT, 3=DELETE'),
      ParamDef('url', 'string'),
      ParamDef('body', 'string', 'Request body (empty for GET)'),
    ], ReturnDef('int', 'Request ID or -1 on error')),
    EndpointDef('hal_http_poll', 'Check if request is complete', [
      ParamDef('request_id', 'int'),
    ], ReturnDef('int', '0=pending, 1=complete, -1=error')),
    EndpointDef('hal_http_read_response', 'Read response body', [
      ParamDef('request_id', 'int'),
    ], ReturnDef('bytes', 'Response body bytes')),
    EndpointDef('hal_http_status', 'Get HTTP status code', [
      ParamDef('request_id', 'int'),
    ], ReturnDef('int', 'HTTP status code or -1 if pending')),
    EndpointDef('hal_http_free', 'Free request resources', [
      ParamDef('request_id', 'int'),
    ], ReturnDef('void')),
  ]),
  'hal.lora': FunctionalityDef('hal.lora', 'LoRa radio communication', [
    EndpointDef('hal_lora_available_hw', 'Check if LoRa hardware is present', [],
        ReturnDef('int', '1 if present, 0 otherwise')),
    EndpointDef('hal_lora_send', 'Send data over LoRa', [
      ParamDef('data', 'bytes'),
    ], ReturnDef('int', '0 on success, -1 on error')),
    EndpointDef('hal_lora_available', 'Bytes available to read', [],
        ReturnDef('uint32')),
    EndpointDef('hal_lora_recv', 'Receive LoRa data', [],
        ReturnDef('bytes', 'Received data')),
  ]),
  'hal.ble': FunctionalityDef('hal.ble', 'Bluetooth Low Energy', [
    EndpointDef('hal_ble_scan_start', 'Start BLE scanning', [],
        ReturnDef('int', '0 on success')),
    EndpointDef('hal_ble_scan_stop', 'Stop BLE scanning', [],
        ReturnDef('void')),
    EndpointDef('hal_ble_scan_read', 'Read scan results (JSON)', [],
        ReturnDef('string', 'JSON scan results, empty if none')),
    EndpointDef('hal_ble_advertise', 'Start BLE advertising', [
      ParamDef('data', 'bytes', 'Advertisement payload'),
    ], ReturnDef('int', '0 on success')),
    EndpointDef('hal_ble_advertise_stop', 'Stop BLE advertising', [],
        ReturnDef('void')),
  ]),
};
