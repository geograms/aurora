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
  DateTime? _lastDrop; // cooldown after a disconnect, to avoid rapid flapping
  static const Duration _reconnectCooldown = Duration(seconds: 4);

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
        _lastDrop = DateTime.now();
        onLinkChange?.call(false);
      }
    });
  }

  /// Offer a discovered peer; connect to the first geogram server seen.
  void considerPeer(Peripheral peripheral) {
    if (_peer != null || _connecting) return;
    final last = _lastDrop;
    if (last != null && DateTime.now().difference(last) < _reconnectCooldown) {
      return; // brief cooldown after a drop to avoid flapping
    }
    _connect(peripheral);
  }

  Future<void> _connect(Peripheral peripheral) async {
    _connecting = true;
    try {
      // Bound the connect: the underlying stack otherwise waits ~30s before it
      // reports a failed establishment (status 147), keeping the radio quiet for
      // the caller far too long. A short timeout lets scans resume and a fresh
      // discovery retry promptly.
      await _central.connect(peripheral).timeout(const Duration(seconds: 12));
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
        _lastDrop = DateTime.now();
        onLinkChange?.call(false);
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
      _lastDrop = DateTime.now();
      // Tell the service the attempt ended so it can resume scanning and retry on
      // the next discovery (the connect path otherwise never signals failure).
      onLinkChange?.call(false);
    } finally {
      _connecting = false;
    }
  }

  /// Drop the current GATT link (e.g. when idle) so the radio is free to scan /
  /// advertise the connectionless broadcast again. No-op if not connected.
  Future<void> disconnect() async {
    final peer = _peer;
    if (peer == null) return;
    try {
      await _central.disconnect(peer);
    } catch (e) {
      debugPrint('BleGatt(client): disconnect failed: $e');
    }
    // connectionStateChanged also clears these, but do it eagerly so a caller
    // that checks isConnected right after sees the link as down.
    _peer = null;
    _writeChar = null;
    _lastDrop = DateTime.now();
    onLinkChange?.call(false);
  }

  /// Write raw bytes (a parcel or receipt) to the connected peer's FFF1.
  ///
  /// Uses WRITE-WITH-RESPONSE: the await completes only when the peer ACKs the
  /// write at the ATT layer, which paces the sender (the queue awaits this before
  /// the next parcel). Write-WITHOUT-response has no flow control, so rapid
  /// successive parcels overrun the controller buffer and only the first lands —
  /// exactly the "header arrives, data parcels lost" failure. The peer's FFF1 is
  /// a plain/unencrypted characteristic, so with-response does NOT trigger
  /// bonding/pairing (this mirrors the proven geogram-android sender).
  Future<void> writeRaw(Uint8List data) async {
    final peer = _peer;
    final ch = _writeChar;
    if (peer == null || ch == null) return;
    try {
      await _central.writeCharacteristic(
        peer,
        ch,
        value: data,
        type: GATTCharacteristicWriteType.withResponse,
      );
    } catch (e) {
      debugPrint('BleGatt(client): write failed: $e');
    }
  }
}
