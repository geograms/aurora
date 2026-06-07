// GATT client endpoint for the BLE parcel transport. Connects to a peer's GATT
// server (service FFE0, write FFF1, notify FFF2) and exposes raw write + an
// inbound-bytes callback. The queue/routing lives in BleService, which drives
// both this client and the GATT server over one BLEQueueService.

import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

class BleGattClient {
  BleGattClient(this._central, {required this.onData, this.onLinkChange});

  final CentralManager _central;

  /// Raw bytes received from the peer on FFF2 (peer uuid, bytes).
  final void Function(String from, Uint8List data) onData;

  /// Notifies when the GATT link comes up (true) or drops (false), so the
  /// service can pause scanning while connected (scan vs connection contend on
  /// a single radio, which drops the link on some stacks, e.g. Linux/BlueZ).
  final void Function(bool connected)? onLinkChange;

  Peripheral? _peer;
  GATTCharacteristic? _writeChar; // FFF1
  bool _connecting = false;
  bool _started = false;

  bool get isConnected => _peer != null && _writeChar != null;
  String? get peerId => _peer?.uuid.toString();

  void start() {
    if (_started) return;
    _started = true;

    _central.characteristicNotified.listen((e) {
      if (!e.characteristic.uuid.toString().toLowerCase().contains('fff2')) return;
      onData(e.peripheral.uuid.toString(), e.value);
    });
    _central.connectionStateChanged.listen((e) {
      if (_peer != null &&
          e.peripheral.uuid == _peer!.uuid &&
          e.state == ConnectionState.disconnected) {
        debugPrint('BleGatt(client): peer disconnected');
        _peer = null;
        _writeChar = null;
        onLinkChange?.call(false);
      }
    });
  }

  /// Offer a discovered peer; connect to the first geogram server seen.
  void considerPeer(Peripheral peripheral) {
    if (_peer != null || _connecting) return;
    _connect(peripheral);
  }

  Future<void> _connect(Peripheral peripheral) async {
    _connecting = true;
    try {
      await _central.connect(peripheral);
      try {
        await _central.requestMTU(peripheral, mtu: 512);
      } catch (_) {}
      final services = await _central.discoverGATT(peripheral);
      GATTCharacteristic? write;
      GATTCharacteristic? notify;
      for (final s in services) {
        for (final c in s.characteristics) {
          final u = c.uuid.toString().toLowerCase();
          if (u.contains('fff1')) write = c;
          if (u.contains('fff2')) notify = c;
        }
      }
      if (write == null || notify == null) {
        debugPrint('BleGatt(client): peer has no FFF1/FFF2');
        await _central.disconnect(peripheral);
        return;
      }
      await _central.setCharacteristicNotifyState(peripheral, notify, state: true);
      _peer = peripheral;
      _writeChar = write;
      debugPrint('BleGatt(client): connected to ${peripheral.uuid}');
      onLinkChange?.call(true);
    } catch (e) {
      debugPrint('BleGatt(client): connect failed: $e');
      try {
        await _central.disconnect(peripheral);
      } catch (_) {}
    } finally {
      _connecting = false;
    }
  }

  /// Write raw bytes (a parcel or receipt) to the connected peer's FFF1.
  Future<void> writeRaw(Uint8List data) async {
    final peer = _peer;
    final ch = _writeChar;
    if (peer == null || ch == null) return;
    try {
      await _central.writeCharacteristic(
        peer,
        ch,
        value: data,
        type: GATTCharacteristicWriteType.withoutResponse,
      );
    } catch (e) {
      debugPrint('BleGatt(client): write failed: $e');
    }
  }
}
