/*
 * ConnectionRegistry — the set of transports the host knows about.
 *
 * Host code (and, later, a wapp-facing `hal.conn` query API) reads this to
 * pick a transport by kind or by capability. Singleton, mirroring
 * FunctionalityRegistry and TaskMonitorService.
 *
 * Built-in transports are registered once at boot by
 * registerBuiltinConnections() (see builtin_connections.dart).
 */

import 'connection.dart';

class ConnectionRegistry {
  ConnectionRegistry._();
  static final ConnectionRegistry instance = ConnectionRegistry._();

  final Map<String, Connection> _byId = {};

  /// Add (or replace, by [Connection.id]) a transport.
  void register(Connection connection) {
    _byId[connection.id] = connection;
  }

  /// Remove every registered transport. Mainly for tests.
  void clear() => _byId.clear();

  /// All registered transports, in registration order.
  List<Connection> get all => List.unmodifiable(_byId.values);

  /// Only those currently usable.
  List<Connection> get available =>
      _byId.values.where((c) => c.isAvailable).toList(growable: false);

  /// Look up a transport by its stable id.
  Connection? byId(String id) => _byId[id];

  /// Every transport of a given family.
  List<Connection> byKind(ConnectionKind kind) =>
      _byId.values.where((c) => c.kind == kind).toList(growable: false);

  /// First *available* transport whose capabilities satisfy [test], or null.
  /// Lets callers say "give me an available, immediate, internet-reaching
  /// link" without naming a specific transport.
  Connection? firstWhereCapable(
      bool Function(ConnectionCapabilities caps) test) {
    for (final c in _byId.values) {
      if (c.isAvailable && test(c.capabilities)) return c;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'connections': [for (final c in _byId.values) c.toJson()],
      };
}
