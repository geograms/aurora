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
  BleGattServer({required this.onData});

  /// Raw bytes a peer wrote to FFF1 (client deviceId, bytes).
  final void Function(String from, Uint8List data) onData;

  bool _inited = false;
  bool _running = false;
  String _callsign = '';
  final Set<String> _clients = {};

  bool get isRunning => _running;
  Set<String> get clientIds => _clients;

  Future<void> start(String callsign) async {
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
          if (!connected && _clients.isEmpty) {
            _advertise();
          }
        });
        BlePeripheral.setCharacteristicSubscriptionChangeCallback(
            (deviceId, charId, subscribed, name) {
          if (subscribed) _clients.add(deviceId);
        });
        BlePeripheral.setWriteRequestCallback((deviceId, charId, offset, value) {
          if (value != null && value.isNotEmpty &&
              charId.toLowerCase().contains('fff1')) {
            _clients.add(deviceId);
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
      await _advertise();
    } catch (e) {
      debugPrint('BleGatt(server): start failed: $e');
    }
  }

  // Presence beacon: company 0xFFFF, [0x3E marker, callsign] — peers connect on
  // seeing the 0x3E marker (same shape the ESP32 advertises). No pairing.
  Future<void> _advertise() async {
    if (!_running) return;
    final cs = _callsign;
    final data = Uint8List.fromList(
        [0x3E, ...utf8.encode(cs.length > 8 ? cs.substring(0, 8) : cs)]);
    try {
      await BlePeripheral.stopAdvertising();
    } catch (_) {}
    try {
      await BlePeripheral.startAdvertising(
        services: [_svcUuid],
        manufacturerData: ManufacturerData(manufacturerId: 0xFFFF, data: data),
      );
      debugPrint('BleGatt(server): advertising as $cs (parcel server up)');
    } catch (e) {
      debugPrint('BleGatt(server): advertise failed: $e');
    }
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
