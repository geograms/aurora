/*
 * Bluetooth (BLE) transport — capability-declaring stub.
 *
 * Mirrors the hal.ble characteristics (see connections/hal/): short range,
 * low bandwidth, immediate, small payloads. No radio code yet; reports
 * unavailable.
 */

import '../connection.dart';

class BluetoothConnection extends Connection {
  @override
  String get id => 'bluetooth';

  @override
  ConnectionKind get kind => ConnectionKind.bluetooth;

  @override
  String get displayName => 'Bluetooth LE';

  @override
  ConnectionCapabilities get capabilities => const ConnectionCapabilities(
    deliveryMode: DeliveryMode.immediate,
    reach: ConnectionReach.mesh,
    reliable: true,
    // BLE is low-throughput with small MTUs.
    maxBandwidthBitsPerSecond: 1000000,
    maxPayloadBytes: 244,
  );

  @override
  ConnectionStatus get status => ConnectionStatus.unavailable;
}
