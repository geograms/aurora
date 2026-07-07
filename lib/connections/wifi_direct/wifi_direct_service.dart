// Thin platform wrapper over the native WiFi Direct (WifiP2p) channel.
//
// BLE coordinates who opens/joins a group; this service only talks to
// WifiDirect.kt: ensure/reuse ONE group (single-group invariant), silently
// join a peer's group by SSID/PSK (WifiP2pConfig credential join — no dialogs
// on API 29+), and report state. No RNS knowledge here.
//
// Android-only for now; Linux/ESP32 get different implementations behind the
// same API later.
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Live group credentials (GO side) or join target (client side).
class WfdGroupCredentials {
  final String ssid;
  final String psk;
  final String goIp;
  final bool reused; // true = an existing group was reused (invariant proof)
  const WfdGroupCredentials(this.ssid, this.psk, this.goIp, {this.reused = false});

  Map<String, dynamic> toJson() =>
      {'ssid': ssid, 'psk': psk, 'goIp': goIp, 'reused': reused};
}

/// A native WiFi-Direct event (p2pState / connection / group).
class WfdEvent {
  final String event;
  final Map<String, dynamic> data;
  const WfdEvent(this.event, this.data);
  bool get connected => data['connected'] == true;
  bool get isGo => data['isGo'] == true;
  String? get goIp => data['goIp'] as String?;
}

class WifiDirectService {
  WifiDirectService._();
  static final WifiDirectService instance = WifiDirectService._();

  static const _method = MethodChannel('com.geogram.aurora/wifidirect');
  static const _events = EventChannel('com.geogram.aurora/wifidirect_events');

  Stream<WfdEvent>? _stream;

  /// Broadcast stream of native events.
  Stream<WfdEvent> get events {
    _stream ??= _events.receiveBroadcastStream().map((e) {
      final m = (e as Map).cast<String, dynamic>();
      return WfdEvent((m['event'] ?? '').toString(), m);
    }).asBroadcastStream();
    return _stream!;
  }

  Future<bool> supported() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _method.invokeMethod<bool>('supported') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Ensure this device hosts a group (reusing a live one) and return its
  /// credentials, or null on failure ({ok:false} — busy/unsupported/etc).
  Future<WfdGroupCredentials?> ensureGroup() async {
    try {
      final m = (await _method.invokeMethod<Map>('ensureGroup'))
          ?.cast<String, dynamic>();
      if (m == null || m['ok'] != true) return null;
      return WfdGroupCredentials(
        (m['ssid'] ?? '').toString(),
        (m['psk'] ?? '').toString(),
        (m['goIp'] ?? '192.168.49.1').toString(),
        reused: m['reused'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// Silent credential join of a peer's group. Resolves true when the join was
  /// INITIATED ok (or we're already in that group); the 'connection' event
  /// reports actual link-up.
  Future<bool> connectToGroup(String ssid, String psk) async {
    try {
      final m = (await _method.invokeMethod<Map>(
              'connectToGroup', {'ssid': ssid, 'psk': psk}))
          ?.cast<String, dynamic>();
      return m?['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Wait for the P2P link to come up (after connectToGroup) and return the
  /// GO's IP, or null on timeout.
  Future<String?> awaitConnected({Duration timeout = const Duration(seconds: 20)}) async {
    try {
      // Already connected?
      final g = await groupInfo();
      if (g != null && g['goIp'] != null) return g['goIp'].toString();
      final ev = await events
          .firstWhere((e) => e.event == 'connection' && e.connected)
          .timeout(timeout);
      return ev.goIp;
    } catch (_) {
      return null;
    }
  }

  /// Leave/tear down the group (policy calls only — idle teardown, wifi-off).
  Future<bool> removeGroup() async {
    try {
      return await _method.invokeMethod<bool>('removeGroup') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Current group state or null: {active, isGo, ssid, psk?, clientCount,
  /// iface, goIp}.
  Future<Map<String, dynamic>?> groupInfo() async {
    try {
      return (await _method.invokeMethod<Map>('groupInfo'))
          ?.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }
}
