// Web / unsupported-platform stub for the shared BLE service: everything is a
// no-op and the inbound stream never emits. Selected by the conditional export
// in ble_service.dart when dart:io is unavailable.

import 'dart:async';
import 'dart:typed_data';

/// APRS-over-BLE manufacturer id carried in advertisement manufacturer data.
/// Must match peer firmware (e.g. ESP32). 0xFFFF is the reserved test id.
const int kBleCompanyId = 0xFFFF;

/// One decoded inbound advertisement carrying our manufacturer payload.
class BleInboundFrame {
  final String from; // peer identifier
  final int rssi;
  final Uint8List data; // the manufacturer payload (e.g. an APRS TNC2 frame)
  BleInboundFrame(this.from, this.rssi, this.data);
}

/// Shared, app-wide BLE access. On web this does nothing.
class BleService {
  BleService._();
  static final BleService instance = BleService._();

  bool get supported => false;
  bool get advertiseSupported => false;
  bool get poweredOn => false;

  final _inbound = StreamController<BleInboundFrame>.broadcast();
  Stream<BleInboundFrame> get inbound => _inbound.stream;

  Future<bool> startScan() async => false;
  Future<void> stopScan() async {}
  void enqueueAdvert(Object owner, Uint8List payload,
      {Duration ttl = const Duration(seconds: 30)}) {}
  void clearAdverts(Object owner) {}
  Map<String, dynamic> gattStatus() => {'autoPair': false, 'clientLinkUp': false};
  void gattSendTest(int size) {}
}
