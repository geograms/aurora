// BlueZ BLE diagnostic: find the largest advertisement that registers (reveals
// whether extended advertising works) and dump inbound 0xFFFF manufacturer data
// (reveals whether the phones' extended-adv payloads are surfaced).
//   dart run tool/reticulum_ble_diag.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:bluez/bluez.dart';
import 'package:dbus/dbus.dart';

String _hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main() async {
  final client = BlueZClient();
  await client.connect();
  final adapter = client.adapters.first;
  if (!adapter.powered) await adapter.setPowered(true);

  // TX threshold: try increasing manufacturer-data sizes.
  for (final n in [16, 25, 31, 60, 120, 200]) {
    final data = Uint8List(n);
    for (var i = 0; i < n; i++) {
      data[i] = i & 0xff;
    }
    try {
      final a = await adapter.advertisingManager.registerAdvertisement(
        type: BlueZAdvertisementType.peripheral,
        manufacturerData: {BlueZManufacturerId(0xFFFF): DBusArray.byte(data)},
      );
      print('TX size $n: OK');
      await adapter.advertisingManager.unregisterAdvertisement(a);
    } catch (e) {
      print('TX size $n: FAIL (${e.toString().split(':').last.trim()})');
    }
  }

  // RX dump: list every 0xFFFF manufacturer payload head seen for ~18s.
  final seen = <String>{};
  void inspect(BlueZDevice d) {
    for (final e in d.manufacturerData.entries) {
      if (e.key.id != 0xFFFF) continue;
      final v = e.value;
      final k = '${d.address}:${v.length}:${_hx(v.take(3).toList())}';
      if (seen.add(k)) {
        print('RX ${d.address} len=${v.length} head=${_hx(v.take(6).toList())}');
      }
    }
  }

  for (final d in client.devices) {
    inspect(d);
    d.propertiesChanged.listen((_) => inspect(d));
  }
  client.deviceAdded.listen((d) {
    inspect(d);
    d.propertiesChanged.listen((_) => inspect(d));
  });
  await adapter.setDiscoveryFilter(transport: 'le', duplicateData: true);
  await adapter.startDiscovery();
  print('scanning 18s…');
  await Future<void>.delayed(const Duration(seconds: 18));
  await adapter.stopDiscovery();
  await client.close();
  print('done');
}
