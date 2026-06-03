/*
 * LoRa transport — capability-declaring stub.
 *
 * Mirrors the hal.lora characteristics (see connections/hal/): very low
 * bandwidth, tiny payloads, long range, and crucially store-and-forward —
 * a wapp that picks LoRa must tolerate delayed, best-effort delivery across
 * a mesh. No radio code yet; reports unavailable.
 */

import '../connection.dart';

class LoraConnection extends Connection {
  @override
  String get id => 'lora';

  @override
  ConnectionKind get kind => ConnectionKind.lora;

  @override
  String get displayName => 'LoRa radio';

  @override
  ConnectionCapabilities get capabilities => const ConnectionCapabilities(
        deliveryMode: DeliveryMode.storeAndForward,
        reach: ConnectionReach.mesh,
        reliable: false,
        // Single-digit kbps and ~256-byte frames are typical for LoRa.
        maxBandwidthBitsPerSecond: 27000,
        maxPayloadBytes: 256,
        typicalLatency: Duration(seconds: 2),
      );

  @override
  ConnectionStatus get status => ConnectionStatus.unavailable;
}
