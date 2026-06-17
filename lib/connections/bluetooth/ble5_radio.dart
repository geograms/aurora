// BLE 5 extended-advertising radio for the Reticulum broadcast transport
// (Android). A thin adapter over the shared Ble5Bus (see ble5_bus.dart): RNS
// announces ride the bus under subtype 0x55, multiplexed on the single extended
// advertising set with APRS (and anything else). This replaces the legacy
// 31-byte advertising path that forced a ~167-byte announce into ~14 chunks.
import 'package:flutter/services.dart';

import '../../services/reticulum/rns_ble_interface.dart';
import 'ble5_bus.dart';

class Ble5Radio implements RnsBleRadio {
  void Function(Uint8List frame)? _handler;

  /// Whether the device supports BLE 5 extended advertising.
  Future<bool> supported() => Ble5Bus.instance.supported();

  /// Begin receiving inbound RNS extended advertisements (subtype 0x55).
  Future<void> startScan() async {
    Ble5Bus.instance.onFrame(Ble5Subtype.rns, (f) => _handler?.call(f.data));
    await Ble5Bus.instance.startScan();
  }

  Future<void> stop() async {
    await Ble5Bus.instance.removeFrame(_kRnsKey);
    // Note: the scan is shared; do not stop it here (APRS may still need it).
  }

  // ── RnsBleRadio ──
  @override
  int get broadcastCap => 500; // a whole RNS packet fits one extended advert

  @override
  void broadcast(Uint8List frame) {
    // Single 'rns' key: announces supersede each other (latest presence wins),
    // refreshed by the service's periodic re-announce. TTL > re-announce period.
    Ble5Bus.instance.advertiseFrame(_kRnsKey, Ble5Subtype.rns, frame,
        ttl: const Duration(seconds: 35));
  }

  @override
  bool unicast(Uint8List frame) => false; // BLE5 path is broadcast-only

  @override
  void onReceive(void Function(Uint8List frame) handler) => _handler = handler;

  static const String _kRnsKey = 'rns';
}
