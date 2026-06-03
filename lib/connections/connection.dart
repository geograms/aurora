/*
 * The connection abstraction.
 *
 * Aurora hides the underlying transport from wapps. A wapp never opens a
 * socket or knows whether bytes leave over the internet, the LAN,
 * Bluetooth, LoRa or USB — it only reasons about a connection's
 * *characteristics*: how fast it is, whether delivery is immediate or
 * store-and-forward, how far it reaches, whether it's reliable, and how
 * big a single payload may be.
 *
 * Everything in lib/connections/ is pure Dart (no Flutter import) so the
 * CLI runner (bin/wapp_cli.dart) can use it too.
 */

/// How a transport delivers a payload.
enum DeliveryMode {
  /// Delivered now or it fails now (HTTP, a TCP socket, USB).
  immediate,

  /// Queued and forwarded when a path becomes available; the sender does
  /// not wait for the recipient to be reachable (LoRa mesh, sneakernet).
  storeAndForward,
}

/// How far a transport can carry data.
enum ConnectionReach {
  /// Same machine / directly attached peripheral (USB).
  local,

  /// The local network segment (Wi-Fi/Ethernet LAN, BLE range).
  lan,

  /// The public internet.
  internet,

  /// A multi-hop mesh of intermittently-connected peers (LoRa).
  mesh,
}

/// The kind of physical/logical transport. Extensible — add a value when a
/// new transport family is implemented.
enum ConnectionKind { internet, lan, bluetooth, lora, usb }

/// Runtime availability of a connection.
enum ConnectionStatus {
  /// Present and usable right now.
  available,

  /// Known to the registry but not usable (no hardware, offline, not yet
  /// implemented).
  unavailable,

  /// In the middle of establishing a link.
  connecting,
}

/// The characteristics a wapp can query about a connection. Immutable and
/// const-constructible so transports can declare them as compile-time
/// constants.
class ConnectionCapabilities {
  /// Best-case throughput in bits per second, or null when unknown /
  /// effectively unbounded.
  final int? maxBandwidthBitsPerSecond;

  /// Rough round-trip latency, or null when unknown.
  final Duration? typicalLatency;

  /// Whether payloads go out immediately or are queued for later.
  final DeliveryMode deliveryMode;

  /// How far this transport reaches.
  final ConnectionReach reach;

  /// Whether delivery is ordered and guaranteed (vs best-effort).
  final bool reliable;

  /// Largest single payload in bytes, or null when unbounded / streaming.
  final int? maxPayloadBytes;

  /// Whether using this transport may cost the user money (cellular, some
  /// satellite links).
  final bool isMetered;

  const ConnectionCapabilities({
    this.maxBandwidthBitsPerSecond,
    this.typicalLatency,
    required this.deliveryMode,
    required this.reach,
    this.reliable = true,
    this.maxPayloadBytes,
    this.isMetered = false,
  });

  Map<String, dynamic> toJson() => {
        if (maxBandwidthBitsPerSecond != null)
          'maxBandwidthBitsPerSecond': maxBandwidthBitsPerSecond,
        if (typicalLatency != null)
          'typicalLatencyMs': typicalLatency!.inMilliseconds,
        'deliveryMode': deliveryMode.name,
        'reach': reach.name,
        'reliable': reliable,
        if (maxPayloadBytes != null) 'maxPayloadBytes': maxPayloadBytes,
        'isMetered': isMetered,
      };
}

/// One transport the host knows about. Concrete transports (internet, LAN,
/// Bluetooth, LoRa, USB) live in sibling folders and are registered into the
/// [ConnectionRegistry] at boot.
abstract class Connection {
  /// Stable identifier, unique within the registry (e.g. `internet`).
  String get id;

  /// Which transport family this is.
  ConnectionKind get kind;

  /// Human-readable label for settings / diagnostics UIs.
  String get displayName;

  /// The characteristics a wapp reasons about.
  ConnectionCapabilities get capabilities;

  /// Current availability. Stubs for not-yet-implemented transports return
  /// [ConnectionStatus.unavailable].
  ConnectionStatus get status;

  /// Convenience: whether [status] is [ConnectionStatus.available].
  bool get isAvailable => status == ConnectionStatus.available;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'displayName': displayName,
        'status': status.name,
        'capabilities': capabilities.toJson(),
      };
}
