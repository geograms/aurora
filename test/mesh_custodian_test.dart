/*
 * Custodian scoring tests (docs/mesh.md §6, M3).
 */
import 'package:aurora/services/mesh/mesh_beacon.dart';
import 'package:aurora/services/mesh/mesh_custodian.dart';
import 'package:aurora/services/mesh/mesh_table.dart';
import 'package:flutter_test/flutter_test.dart';

MeshBeacon _b(String cs,
        {bool powered = false,
        int uptime = 0,
        MeshMobility mob = MeshMobility.unknown,
        MeshDeviceClass cls = MeshDeviceClass.phone,
        List<MeshDvEntry> dv = const []}) =>
    MeshBeacon(
      callsign: cs,
      deviceClass: cls,
      cond: MeshConditions(
          powered: powered, uptimeBucket: uptime, mobility: mob),
      dv: dv,
    );

void main() {
  test('powered stationary base station outranks passing phone', () {
    final t = MeshTable('ME');
    final me = MeshDvEntry(meshHash('ME'), 1);
    t.ingest(_b('PHONE', dv: [me]));
    t.ingest(_b('BASE',
        powered: true,
        uptime: 7,
        mob: MeshMobility.stationary,
        cls: MeshDeviceClass.baseStation,
        dv: [me]));
    // Equal contact history (each seen once).
    expect(meshStability(t.neighbors['BASE']!),
        greaterThan(meshStability(t.neighbors['PHONE']!)));
    expect(meshPickCustodian(t, 'FARAWAY'), 'BASE');
  });

  test('neighbor claiming a path to the target dominates', () {
    final t = MeshTable('ME');
    final me = MeshDvEntry(meshHash('ME'), 1);
    t.ingest(_b('BASE',
        powered: true,
        uptime: 7,
        mob: MeshMobility.stationary,
        cls: MeshDeviceClass.baseStation,
        dv: [me]));
    t.ingest(_b('KNOWER', dv: [me, MeshDvEntry(meshHash('TGT'), 2)]));
    expect(meshPickCustodian(t, 'TGT'), 'KNOWER');
  });

  test('one-way neighbors are never custodians; weak field returns null', () {
    final t = MeshTable('ME');
    t.ingest(_b('ONEWAY')); // no dv listing ME -> not bidirectional
    expect(meshPickCustodian(t, 'X'), isNull);
  });
}
