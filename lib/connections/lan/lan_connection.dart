/*
 * LAN transport — capability-declaring stub.
 *
 * No discovery/socket code yet; reports unavailable. Declares the
 * characteristics a wapp would reason about once it's implemented: fast,
 * immediate, reaches the local network segment.
 */

import '../connection.dart';

class LanConnection extends Connection {
  @override
  String get id => 'lan';

  @override
  ConnectionKind get kind => ConnectionKind.lan;

  @override
  String get displayName => 'Local network';

  @override
  ConnectionCapabilities get capabilities => const ConnectionCapabilities(
        deliveryMode: DeliveryMode.immediate,
        reach: ConnectionReach.lan,
        reliable: true,
        maxBandwidthBitsPerSecond: null,
      );

  @override
  ConnectionStatus get status => ConnectionStatus.unavailable;
}
