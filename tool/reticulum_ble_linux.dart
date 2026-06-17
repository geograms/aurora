// Headless Linux Reticulum node over BLE 5, using BlueZ (org.bluez) directly so
// it runs without the Flutter GUI. It extended-advertises RNS packets as
// manufacturer data (company 0xFFFF, [0x3E,0x55]+packet) — BlueZ uses extended
// advertising automatically for payloads beyond the legacy 31-byte cap on a
// BLE5 controller — and scans (LE) to receive the same frames from the phones.
// Runs the full Dart RNS stack (real crypto / valid announces).
//
//   dart run tool/reticulum_ble_linux.dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluez/bluez.dart';
import 'package:dbus/dbus.dart';

import 'package:aurora/services/reticulum/rns_announce.dart';
import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/reticulum/rns_transport.dart';

const int _company = 0xFFFF;
const int _marker = 0x3E;
const int _subtype = 0x55;

String _hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main(List<String> args) async {
  final client = BlueZClient();
  await client.connect();
  if (client.adapters.isEmpty) {
    print('No Bluetooth adapter');
    await client.close();
    return;
  }
  final adapter = client.adapters.first;
  if (!adapter.powered) await adapter.setPowered(true);
  print('Adapter ${adapter.name} (${adapter.address})');

  final id = await RnsIdentity.generate();
  final transport = RnsTransport(
      transportId: id.hash, log: (m) => print('  [transport] $m'));
  print('LINUX_IDENTITY ${id.hexHash}');
  print('LINUX_DEST ${_hx(RnsDestination.hash(id, "aurora", ["chat"]))}');

  final seen = <String>{};
  Future<void> handlePacket(Uint8List packet, String from) async {
    final p = RnsPacket.parse(packet);
    if (p == null) return;
    final ann = await transport.ingest(p, 'ble-linux');
    if (ann == null || ann.identity.hexHash == id.hexHash) return;
    print('LINUX_RX from=${ann.identity.hexHash} addr=$from '
        'text="${utf8.decode(ann.appData, allowMalformed: true)}"');
  }

  void inspect(BlueZDevice d) {
    for (final e in d.manufacturerData.entries) {
      if (e.key.id != _company) continue;
      final data = e.value;
      if (data.length < 2 || data[0] != _marker || data[1] != _subtype) continue;
      final packet = Uint8List.fromList(data.sublist(2));
      // Dedup identical adverts (BlueZ repeats them); RNS also dedups by hash.
      final key = '${d.address}:${_hx(data)}';
      if (!seen.add(key)) continue;
      if (seen.length > 4096) seen.clear();
      handlePacket(packet, d.address);
    }
  }

  // Watch existing + newly-discovered devices and their property updates.
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
  print('scanning (LE)…');

  BlueZAdvertisement? advert;
  Future<void> announce(String text) async {
    final pkt = await RnsAnnounceBuilder.build(id, 'aurora', ['chat'],
        appData: Uint8List.fromList(utf8.encode(text)));
    final payload = Uint8List(2 + pkt.pack().length)
      ..[0] = _marker
      ..[1] = _subtype
      ..setRange(2, 2 + pkt.pack().length, pkt.pack());
    try {
      if (advert != null) {
        await adapter.advertisingManager.unregisterAdvertisement(advert!);
        advert = null;
      }
      advert = await adapter.advertisingManager.registerAdvertisement(
        type: BlueZAdvertisementType.peripheral,
        manufacturerData: {
          BlueZManufacturerId(_company): DBusArray.byte(payload),
        },
      );
      print('LINUX_TX announced "$text" (${payload.length}B mfg, '
          'extended=${payload.length + 6 > 31})');
    } catch (e) {
      print('LINUX_TX advertise failed: $e');
    }
  }

  await announce('linux-ble online');
  var tick = 0;
  await for (final _ in Stream.periodic(const Duration(seconds: 10))) {
    tick++;
    await announce('linux-ble tick $tick');
  }
}
