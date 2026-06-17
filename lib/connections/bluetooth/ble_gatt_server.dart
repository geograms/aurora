// GATT server endpoint for the BLE parcel transport (makes this device a
// connectable peer). Serves the geogram service FFE0 with write FFF1 (peers
// write parcels here) and notify FFF2 (we push parcels/receipts), and
// advertises a presence beacon so peers connect automatically — no pairing
// (characteristics are open, no encryption). Uses the ble_peripheral package
// (Android/iOS/macOS/Windows; not Linux/BlueZ — there the device stays a
// client only for now). The queue/routing lives in BleService.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:flutter/foundation.dart';

const String _svcUuid = '0000ffe0-0000-1000-8000-00805f9b34fb';
const String _writeUuid = '0000fff1-0000-1000-8000-00805f9b34fb';
const String _notifyUuid = '0000fff2-0000-1000-8000-00805f9b34fb';

class BleGattServer {
  BleGattServer({required this.onData, this.onClientsChanged});

  /// Raw bytes a peer wrote to FFF1 (client deviceId, bytes).
  final void Function(String from, Uint8List data) onData;

  /// Notifies when the set of connected clients changes, so the service can
  /// pause scanning while serving a client (scan vs connection contend on one
  /// radio and the link drops otherwise).
  final void Function()? onClientsChanged;

  bool _inited = false;
  bool _running = false;
  bool _advertiseEnabled = true; // false on BLE5 (extended advert is connectable)
  String _callsign = '';
  final Set<String> _clients = {};

  bool get isRunning => _running;
  Set<String> get clientIds => _clients;

  /// Register the FFE0 GATT server (and, when [advertise] is true, air the
  /// legacy connectable presence beacon). On BLE5 the caller advertises
  /// connectably via the extended advert instead, so it passes advertise:false —
  /// the server still accepts the incoming connection (Android routes it to the
  /// registered server regardless of which advert is on air).
  Future<void> start(String callsign, {bool advertise = true}) async {
    if (_running) return;
    // ble_peripheral has no Linux implementation (the channel throws there);
    // on Linux this device stays a client only.
    if (Platform.isLinux) return;
    try {
      if (!await BlePeripheral.isSupported()) {
        debugPrint('BleGatt(server): peripheral not supported on this platform');
        return;
      }
      if (!_inited) {
        await BlePeripheral.initialize();
        BlePeripheral.setConnectionStateChangeCallback((deviceId, connected) {
          if (connected) {
            _clients.add(deviceId);
          } else {
            _clients.remove(deviceId);
          }
          debugPrint('BleGatt(server): $deviceId ${connected ? "connected" : "disconnected"} '
              '(${_clients.length} client(s))');
          // Android stops advertising while a central is connected; re-advertise
          // once the last client leaves so we stay discoverable/reconnectable.
          if (!connected && _clients.isEmpty && _advertiseEnabled) {
            _advertise();
          }
          onClientsChanged?.call();
        });
        BlePeripheral.setCharacteristicSubscriptionChangeCallback(
            (deviceId, charId, subscribed, name) {
          if (subscribed) {
            _clients.add(deviceId);
            onClientsChanged?.call();
          }
        });
        BlePeripheral.setWriteRequestCallback((deviceId, charId, offset, value) {
          if (value != null && value.isNotEmpty &&
              charId.toLowerCase().contains('fff1')) {
            if (_clients.add(deviceId)) onClientsChanged?.call();
            onData(deviceId, value);
          }
          return WriteRequestResult(status: 0);
        });
        await BlePeripheral.addService(BleService(
          uuid: _svcUuid,
          primary: true,
          characteristics: [
            BleCharacteristic(
              uuid: _writeUuid,
              properties: [
                CharacteristicProperties.write.index,
                CharacteristicProperties.writeWithoutResponse.index,
              ],
              permissions: [AttributePermissions.writeable.index],
            ),
            BleCharacteristic(
              uuid: _notifyUuid,
              properties: [
                CharacteristicProperties.notify.index,
                CharacteristicProperties.read.index,
              ],
              permissions: [AttributePermissions.readable.index],
            ),
          ],
        ));
        _inited = true;
      }
      _callsign = callsign.isEmpty ? 'AURORA' : callsign;
      _running = true;
      _advertiseEnabled = advertise;
      if (advertise) await _advertise();
    } catch (e) {
      debugPrint('BleGatt(server): start failed: $e');
    }
  }

  /// Re-air the presence beacon. Needed because Android has a single
  /// BluetoothLeAdvertiser: the broadcast-parcel rotation and this presence
  /// advert clobber each other, so when the rotation goes idle the caller calls
  /// this to make presence the steady-state advert again (so peers — and the
  /// ESP32 iGate — keep hearing our callsign). No-op if not running / no clients
  /// rule needed (presence is fine while connected too).
  Future<void> readvertise() async {
    if (!_running) return;
    await _advertise();
  }

  // Presence beacon: company 0xFFFF, [0x3E marker, deviceId, callsign] — the
  // geogram standard the ESP32 expects (it reads the callsign from offset 4,
  // i.e. after a 1-byte device id). No pairing; peers connect on the 0x3E marker.
  // NOTE: advertise manufacturer data ONLY — no service UUID. The service UUID
  // here is a 128-bit string; including it (18B) + flags (3B) + this data
  // overflows the 31-byte legacy advert and makes Android switch to EXTENDED
  // advertising, which the ESP32's legacy scanner can't see (so the iGate never
  // hears us). The device stays connectable without it, and the central scan is
  // unfiltered, so discovery still works.
  Future<void> _advertise() async {
    if (!_running) return;
    final cs = _callsign;
    final csBytes = utf8.encode(cs.length > 6 ? cs.substring(0, 6) : cs);
    final data = Uint8List.fromList([0x3E, _deviceId(cs), ...csBytes]);
    try {
      await BlePeripheral.stopAdvertising();
    } catch (_) {}
    try {
      await BlePeripheral.startAdvertising(
        services: const [],
        manufacturerData: ManufacturerData(manufacturerId: 0xFFFF, data: data),
      );
      debugPrint('BleGatt(server): advertising as $cs (parcel server up)');
    } catch (e) {
      debugPrint('BleGatt(server): advertise failed: $e');
    }
  }

  // Small non-zero device id (1..15) derived from the callsign — mirrors the
  // ESP32's MAC-hash scheme; the value only needs to be stable, not unique.
  static int _deviceId(String cs) {
    var h = 2166136261;
    for (final b in utf8.encode(cs)) {
      h = (h ^ b) * 16777619 & 0xffffffff;
    }
    return (h % 15) + 1;
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    try {
      await BlePeripheral.stopAdvertising();
    } catch (_) {}
  }

  /// Notify [data] (a parcel or receipt) to a connected client on FFF2.
  Future<void> notify(String deviceId, Uint8List data) async {
    try {
      await BlePeripheral.updateCharacteristic(
        characteristicId: _notifyUuid,
        value: data,
        deviceId: deviceId,
      );
    } catch (e) {
      debugPrint('BleGatt(server): notify failed: $e');
    }
  }
}
