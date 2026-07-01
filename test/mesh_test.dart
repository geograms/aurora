import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:aurora/services/mesh/mesh_beacon.dart';
import 'package:aurora/services/mesh/mesh_table.dart';

void main() {
  group('MeshBeacon codec', () {
    test('round-trips all fields', () {
      final b = MeshBeacon(
        callsign: 'X1A67X',
        deviceClass: MeshDeviceClass.phone,
        cond: MeshConditions(
            powered: true,
            uptimeBucket: 5,
            mobility: MeshMobility.stationary,
            storageBucket: 2),
        dv: [
          MeshDvEntry(meshHash('X1V22Y'), 1),
          MeshDvEntry(meshHash('X13HJT'), 3),
        ],
      );
      final d = MeshBeacon.decode(b.encode());
      expect(d, isNotNull);
      expect(d!.callsign, 'X1A67X');
      expect(d.deviceClass, MeshDeviceClass.phone);
      expect(d.cond.powered, true);
      expect(d.cond.uptimeBucket, 5);
      expect(d.cond.mobility, MeshMobility.stationary);
      expect(d.cond.storageBucket, 2);
      expect(d.dv.length, 2);
      expect(meshHashHex(d.dv[0].hash), meshHashHex(meshHash('X1V22Y')));
      expect(d.dv[1].cost, 3);
    });

    test('100-entry digest fits one BLE5 advert', () {
      final dv = List.generate(
          100, (i) => MeshDvEntry(meshHash('X1TEST$i'), 1 + i % 6));
      final b = MeshBeacon(
          callsign: 'X1LONGCS',
          deviceClass: MeshDeviceClass.baseStation,
          cond: const MeshConditions(),
          dv: dv);
      final bytes = b.encode();
      expect(bytes.length, lessThanOrEqualTo(450));
      expect(MeshBeacon.decode(bytes)!.dv.length, 100);
    });

    test('rejects garbage without throwing', () {
      expect(MeshBeacon.decode(Uint8List(0)), isNull);
      expect(MeshBeacon.decode(Uint8List.fromList([9, 1, 2, 3, 4])), isNull);
      expect(
          MeshBeacon.decode(Uint8List.fromList([1, 1, 0, 200, 65])), isNull);
      // truncated dv section
      final good = MeshBeacon(
          callsign: 'X1A67X',
          deviceClass: MeshDeviceClass.phone,
          cond: const MeshConditions(),
          dv: [MeshDvEntry(meshHash('X1V22Y'), 2)]).encode();
      expect(MeshBeacon.decode(
              Uint8List.fromList(good.sublist(0, good.length - 3))),
          isNull);
    });
  });

  group('MeshTable', () {
    MeshBeacon beaconFrom(String cs, Map<String, int> reach,
        {MeshDeviceClass cls = MeshDeviceClass.phone}) {
      return MeshBeacon(
        callsign: cs,
        deviceClass: cls,
        cond: const MeshConditions(),
        dv: [for (final e in reach.entries) MeshDvEntry(meshHash(e.key), e.value)],
      );
    }

    test('bidirectional gate: routes only via neighbors that list us', () {
      final t = MeshTable('A');
      // B hears us (lists A at cost 1) and reaches C at 1.
      t.ingest(beaconFrom('B', {'A': 1, 'C': 1}));
      expect(t.neighbors['B']!.bidirectional, true);
      expect(t.routes[meshHashHex(meshHash('C'))]!.cost, 2);
      expect(t.routes[meshHashHex(meshHash('C'))]!.viaCallsign, 'B');

      // D does NOT list us: one-way link, no routes learned through it.
      t.ingest(beaconFrom('D', {'E': 1}));
      expect(t.neighbors['D']!.bidirectional, false);
      expect(t.routes.containsKey(meshHashHex(meshHash('E'))), false);
    });

    test('prefers lower cost and caps at 6 hops', () {
      final t = MeshTable('A');
      t.ingest(beaconFrom('B', {'A': 1, 'Z': 4}));
      expect(t.routes[meshHashHex(meshHash('Z'))]!.cost, 5);
      t.ingest(beaconFrom('C', {'A': 1, 'Z': 2}));
      expect(t.routes[meshHashHex(meshHash('Z'))]!.viaCallsign, 'C');
      expect(t.routes[meshHashHex(meshHash('Z'))]!.cost, 3);
      // Cost 6 advertised → would be 7 here → over the cap, not learned.
      t.ingest(beaconFrom('D', {'A': 1, 'Q': 6}));
      expect(t.routes.containsKey(meshHashHex(meshHash('Q'))), false);
    });

    test('never routes to self', () {
      final t = MeshTable('A');
      t.ingest(beaconFrom('B', {'A': 1}));
      expect(t.routes.containsKey(t.selfHashHex), false);
    });

    test('sweep drops dead neighbors and their routes', () {
      final t = MeshTable('A');
      final past = DateTime.now().subtract(const Duration(minutes: 10));
      t.ingest(beaconFrom('B', {'A': 1, 'C': 1}), at: past);
      expect(t.routes.length, 1);
      t.sweep();
      expect(t.neighbors.isEmpty, true);
      expect(t.routes.isEmpty, true);
    });

    test('exportDv: neighbors at cost 1 then routes, capped', () {
      final t = MeshTable('A');
      t.ingest(beaconFrom('B', {'A': 1, 'C': 2}));
      final dv = t.exportDv();
      // B at cost 1, C at learned cost 3.
      expect(dv.length, 2);
      expect(dv[0].cost, 1);
      expect(meshHashHex(dv[0].hash), meshHashHex(meshHash('B')));
      expect(dv[1].cost, 3);
    });

    test('contact ratio rises with sightings', () {
      final t = MeshTable('A');
      final t0 = DateTime.now();
      for (var i = 0; i < 10; i++) {
        t.ingest(beaconFrom('B', {'A': 1}), at: t0.add(Duration(seconds: i)));
      }
      expect(t.neighbors['B']!.contactRatio, greaterThan(0.3));
    });
  });
}
