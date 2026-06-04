// Shared, app-wide Bluetooth Low Energy access. There is ONE physical adapter,
// so the adapter (scan + advertise) is owned here as a singleton and shared by
// every wapp: each wapp's hal_ble_* (in WappEngine) plugs into this service.
//
// - Inbound: a single broadcast stream of decoded frames; each wapp keeps its
//   own queue fed from it, so all wapps receive every frame independently.
// - Outbound: a multiplexed advertise queue (per-owner payloads) that a
//   rotation timer broadcasts round-robin, so multiple wapps can advertise.
//
// Native implementation in ble_service_io.dart; web no-op in ble_service_stub.dart.

export 'ble_service_stub.dart' if (dart.library.io) 'ble_service_io.dart';
