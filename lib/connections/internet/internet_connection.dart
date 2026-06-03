/*
 * Internet transport — the one connection that's actually wired up today.
 *
 * Backed by HttpTransport (package:http). Reports itself available; a real
 * online/offline probe can refine [status] later.
 */

import '../connection.dart';

class InternetConnection extends Connection {
  @override
  String get id => 'internet';

  @override
  ConnectionKind get kind => ConnectionKind.internet;

  @override
  String get displayName => 'Internet';

  @override
  ConnectionCapabilities get capabilities => const ConnectionCapabilities(
        deliveryMode: DeliveryMode.immediate,
        reach: ConnectionReach.internet,
        reliable: true,
        // Bandwidth/latency vary wildly with the user's link; leave unknown
        // rather than assert a number.
        maxBandwidthBitsPerSecond: null,
        typicalLatency: null,
      );

  @override
  // TODO: replace with a real connectivity probe (online/offline).
  ConnectionStatus get status => ConnectionStatus.available;
}
