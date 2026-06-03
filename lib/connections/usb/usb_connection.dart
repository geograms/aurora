/*
 * USB transport — capability-declaring stub.
 *
 * A directly-attached peripheral: high bandwidth, immediate, local reach.
 * No device code yet; reports unavailable.
 */

import '../connection.dart';

class UsbConnection extends Connection {
  @override
  String get id => 'usb';

  @override
  ConnectionKind get kind => ConnectionKind.usb;

  @override
  String get displayName => 'USB';

  @override
  ConnectionCapabilities get capabilities => const ConnectionCapabilities(
        deliveryMode: DeliveryMode.immediate,
        reach: ConnectionReach.local,
        reliable: true,
        maxBandwidthBitsPerSecond: null,
      );

  @override
  ConnectionStatus get status => ConnectionStatus.unavailable;
}
