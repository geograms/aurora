// Shared BLE 5 connectionless-broadcast bus (Android). Bridges to the native
// Ble5 plugin (android/.../com/example/iwi/Ble5.kt), which owns ONE extended
// advertising set and multiplexes every registered frame onto it (round-robin
// with per-frame TTL). Every subsystem that wants connectionless broadcast —
// Reticulum announces (subtype 0x55) and APRS group chat (subtype 0x41) — shares
// this one bus, because phones generally can't run two extended advertising sets
// at once and two independent writers of one set would clobber each other.
//
// Send:    advertiseFrame(key, subtype, data, ttl)  — register/refresh a frame
//          removeFrame(key)                          — drop it early
// Receive: onFrame(subtype, handler)                 — demuxed inbound by subtype
//          startScan()                               — one shared extended scan
import 'dart:async';

import 'package:flutter/services.dart';

/// Manufacturer-data subtypes carried under company id 0xFFFF, marker 0x3E.
class Ble5Subtype {
  static const int rns = 0x55; // Reticulum packet
  static const int aprs = 0x41; // APRS broadcast parcel ('A')
  static const int presence = 0x47; // GATT presence beacon ('G'): callsign
}

/// One inbound connectionless frame, already demuxed to a single subtype.
class Ble5Frame {
  final String addr; // advertiser address (rotating random MAC)
  final int rssi;
  final Uint8List data; // payload after marker+subtype
  const Ble5Frame(this.addr, this.rssi, this.data);
}

class Ble5Bus {
  Ble5Bus._();
  static final Ble5Bus instance = Ble5Bus._();

  /// Max payload that fits one extended advert here (leaves envelope headroom).
  /// APRS caps a message well under this (250 chars + metadata); longer content
  /// is split into multiline frames by the wapp.
  static const int maxFrame = 450;

  static const MethodChannel _method =
      MethodChannel('com.geogram.aurora/ble5');
  static const EventChannel _scan =
      EventChannel('com.geogram.aurora/ble5_scan');
  static const EventChannel _gattEvents =
      EventChannel('com.geogram.aurora/ble5_gatt');

  final Map<int, void Function(Ble5Frame)> _handlers = {};
  StreamSubscription? _sub;
  StreamSubscription? _gattSub;
  bool _scanning = false;
  bool? _supported;

  // Native GATT callbacks. The whole GATT large-file path is native (server +
  // client + legacy connectable advert + legacy discovery scan) — one coordinated
  // stack, unlike the two Flutter plugins whose dual-role confused Android's GATT
  // handle cache.
  void Function()? onGattConnected; // our client link is up + ready
  void Function()? onGattDisconnected; // our client link dropped
  void Function(Uint8List data)? onGattData; // client received on FFF2 (receipts)
  void Function(String address, String callsign)? onGattDiscovered; // peer beacon
  void Function(String address, Uint8List data)? onGattServerData; // FFF1 write in
  void Function(String address)? onGattServerConnected;
  void Function(String address)? onGattServerDisconnected;

  /// Whether the device supports BLE 5 extended advertising.
  Future<bool> supported() async {
    final cached = _supported;
    if (cached != null) return cached;
    bool ok;
    try {
      ok = (await _method.invokeMethod<bool>('supported')) ?? false;
    } catch (_) {
      ok = false;
    }
    _supported = ok;
    return ok;
  }

  /// Route inbound frames of [subtype] to [handler]. One handler per subtype.
  void onFrame(int subtype, void Function(Ble5Frame) handler) =>
      _handlers[subtype] = handler;

  /// Begin the shared extended scan (idempotent). Demuxes by subtype.
  Future<void> startScan() async {
    if (_scanning) return;
    _sub = _scan.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      final subtype = (event['subtype'] as int?) ?? -1;
      final h = _handlers[subtype];
      if (h == null) return;
      final raw = event['data'];
      final data = raw is Uint8List
          ? raw
          : (raw is List<int> ? Uint8List.fromList(raw) : Uint8List(0));
      final addr = (event['addr'] as String?) ?? '';
      final rssi = (event['rssi'] as int?) ?? 0;
      h(Ble5Frame(addr, rssi, data));
    });
    try {
      await _method.invokeMethod('startScan');
      _scanning = true;
    } catch (_) {}
  }

  /// Register/refresh a keyed broadcast frame. Re-calling with the same [key]
  /// refreshes its TTL (and replaces the data). The native rotation airs it.
  Future<void> advertiseFrame(String key, int subtype, Uint8List data,
      {Duration ttl = const Duration(seconds: 35)}) async {
    try {
      await _method.invokeMethod('advertiseFrame', {
        'key': key,
        'subtype': subtype,
        'data': data,
        'ttlMs': ttl.inMilliseconds,
      });
    } catch (_) {}
  }

  Future<void> removeFrame(String key) async {
    try {
      await _method.invokeMethod('removeFrame', {'key': key});
    } catch (_) {}
  }

  /// Begin listening for native GATT-client events (connected/disconnected/data).
  void startGattEvents() {
    _gattSub ??= _gattEvents.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      Uint8List? bytes(dynamic raw) => raw is Uint8List
          ? raw
          : (raw is List<int> ? Uint8List.fromList(raw) : null);
      final addr = (event['address'] as String?) ?? '';
      switch (event['event']) {
        case 'connected':
          onGattConnected?.call();
          break;
        case 'disconnected':
          onGattDisconnected?.call();
          break;
        case 'data':
          final d = bytes(event['data']);
          if (d != null) onGattData?.call(d);
          break;
        case 'discovered':
          onGattDiscovered?.call(addr, (event['callsign'] as String?) ?? '');
          break;
        case 'server_data':
          final d = bytes(event['data']);
          if (d != null) onGattServerData?.call(addr, d);
          break;
        case 'server_connected':
          onGattServerConnected?.call(addr);
          break;
        case 'server_disconnected':
          onGattServerDisconnected?.call(addr);
          break;
      }
    });
  }

  /// Start the native GATT server + legacy connectable presence beacon + legacy
  /// discovery scan (the whole point-to-point transfer endpoint).
  Future<void> startServer(String callsign) async {
    try {
      await _method.invokeMethod('startServer', {'callsign': callsign});
    } catch (_) {}
  }

  Future<void> stopServer() async {
    try {
      await _method.invokeMethod('stopServer');
    } catch (_) {}
  }

  /// Notify the connected central on FFF2 (receipts / reverse data).
  Future<void> serverNotify(Uint8List data) async {
    try {
      await _method.invokeMethod('serverNotify', {'data': data});
    } catch (_) {}
  }

  /// Open a GATT link to a peer by BLE address (learned from the scan).
  Future<void> gattConnect(String address) async {
    try {
      await _method.invokeMethod('gattConnect', {'address': address});
    } catch (_) {}
  }

  /// Write bytes to the connected peer's FFF1 (no response).
  Future<void> gattWrite(Uint8List data) async {
    try {
      await _method.invokeMethod('gattWrite', {'data': data});
    } catch (_) {}
  }

  Future<void> gattDisconnect() async {
    try {
      await _method.invokeMethod('gattDisconnect');
    } catch (_) {}
  }

  Future<void> stopAdvertise() async {
    try {
      await _method.invokeMethod('stopAdvertise');
    } catch (_) {}
  }

  Future<void> stopScan() async {
    try {
      await _method.invokeMethod('stopScan');
    } catch (_) {}
    _scanning = false;
    await _sub?.cancel();
    _sub = null;
  }
}
