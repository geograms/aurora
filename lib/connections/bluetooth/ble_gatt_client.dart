// Generic GATT client for the BLE parcel transport (the standard text exchange;
// APRS and any other wapp ride on top). Connects to a peer's GATT server
// (service FFE0, write FFF1, notify FFF2 — the geogram/ESP32 server), and
// bridges the ported BLEQueueService: outgoing text is enqueued as parcels and
// written to FFF1; FFF2 notifications feed the queue; reassembled messages are
// handed back via [onInbound]. App-agnostic: it moves opaque text frames.

import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import 'ble_parcel.dart';
import 'ble_queue_service.dart';

class BleGattClient {
  BleGattClient(this._central, {required this.onInbound});

  final CentralManager _central;

  /// Delivered a reassembled inbound text frame (peer uuid, rssi, bytes).
  final void Function(String from, int rssi, Uint8List data) onInbound;

  final BLEQueueService _queue = BLEQueueService();

  // Single active connection (desktop <-> one ESP32 for now).
  Peripheral? _peer;
  GATTCharacteristic? _writeChar; // FFF1
  bool _connecting = false;
  int _lastRssi = 0;
  bool _started = false;

  bool get isConnected => _peer != null && _writeChar != null;

  /// Wire the queue and central event streams. Call once.
  void start() {
    if (_started) return;
    _started = true;

    // Queue -> BLE: write each parcel/receipt to the peer's FFF1.
    _queue.setSendCallback((deviceId, data) async {
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
        debugPrint('BleGatt: write failed: $e');
      }
    });

    // BLE -> queue: FFF2 notifications carry parcels and receipts.
    _central.characteristicNotified.listen((e) {
      final u = e.characteristic.uuid.toString().toLowerCase();
      if (!u.contains('fff2')) return;
      _queue.onDataReceived(e.peripheral.uuid.toString(), e.value);
    });

    // Reassembled inbound messages -> caller (the BLE HAL inbound stream).
    _queue.incomingMessages.listen((m) {
      onInbound(m.sourceDeviceId, _lastRssi, m.payload);
    });

    // Drop our connection state when the peer disconnects.
    _central.connectionStateChanged.listen((e) {
      if (_peer != null &&
          e.peripheral.uuid == _peer!.uuid &&
          e.state == ConnectionState.disconnected) {
        debugPrint('BleGatt: peer disconnected');
        _peer = null;
        _writeChar = null;
      }
    });
  }

  /// Offer a freshly-discovered peer; connect to the first geogram server seen.
  void considerPeer(Peripheral peripheral, int rssi) {
    _lastRssi = rssi;
    if (_peer != null || _connecting) return;
    _connect(peripheral);
  }

  Future<void> _connect(Peripheral peripheral) async {
    _connecting = true;
    try {
      await _central.connect(peripheral);
      try {
        await _central.requestMTU(peripheral, mtu: 512);
      } catch (_) {
        // Best effort — chat-sized parcels fit even a modest MTU.
      }
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
        debugPrint('BleGatt: peer has no FFF1/FFF2 — disconnecting');
        await _central.disconnect(peripheral);
        return;
      }
      await _central.setCharacteristicNotifyState(peripheral, notify, state: true);
      _peer = peripheral;
      _writeChar = write;
      debugPrint('BleGatt: connected to ${peripheral.uuid} (parcel transport up)');
    } catch (e) {
      debugPrint('BleGatt: connect failed: $e');
      try {
        await _central.disconnect(peripheral);
      } catch (_) {}
    } finally {
      _connecting = false;
    }
  }

  /// Send an opaque text frame to the connected peer as parcel(s).
  void sendText(Uint8List payload) {
    final peer = _peer;
    if (peer == null) return;
    _queue.enqueue(BLEOutgoingMessage(
      payload: payload,
      targetDeviceId: peer.uuid.toString(),
    ));
  }
}
