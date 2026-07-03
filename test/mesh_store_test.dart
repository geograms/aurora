/*
 * MeshStore (SCF sqlite) tests — park/dedup/purge/route-aware pending,
 * have-bloom build+apply, TTL/quota sweep.
 */
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/mesh/mesh_beacon.dart';
import 'package:aurora/services/mesh/mesh_bloom.dart';
import 'package:aurora/services/mesh/mesh_store.dart';
import 'package:aurora/services/mesh/mesh_table.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';

Uint8List _wire(String from, String to, String text) =>
    Uint8List.fromList('$from\x1F$to\x1F$text'.codeUnits);

void main() {
  late Directory tmp;
  late MeshStore store;

  setUpAll(() {
    // Host test runner: the distro ships libsqlite3.so.0, not the dev symlink.
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('meshstore');
    store = MeshStore.instance;
    store.init('${tmp.path}/mesh.sqlite3');
  });

  tearDown(() {
    store.close();
    tmp.deleteSync(recursive: true);
  });

  test('offer parks once; duplicates rejected by am and by content', () {
    final w = _wire('AAA', 'BBB', 'am:a1b2c3 hello');
    expect(store.offer(target: 'BBB', sender: 'AAA', wire: w, am: 'a1b2c3'),
        true);
    expect(store.offer(target: 'BBB', sender: 'AAA', wire: w, am: 'a1b2c3'),
        false);
    // am-less frame: content-keyed
    final w2 = _wire('AAA', 'BBB', 'plain');
    expect(store.offer(target: 'BBB', sender: 'AAA', wire: w2), true);
    expect(store.offer(target: 'BBB', sender: 'AAA', wire: w2), false);
    expect(store.pendingCount(), 2);
  });

  test('already-received am is not parked; ?ACK purges', () {
    store.recordReceivedAm('dededе'.substring(0, 6)); // any 6 chars
    final w = _wire('AAA', 'BBB', 'am:ffffff x');
    store.recordReceivedAm('ffffff');
    expect(store.offer(target: 'BBB', sender: 'AAA', wire: w, am: 'ffffff'),
        false);
    final w2 = _wire('AAA', 'BBB', 'am:abcdef y');
    store.offer(target: 'BBB', sender: 'AAA', wire: w2, am: 'abcdef');
    expect(store.purgeAm('abcdef'), 1);
    expect(store.pendingCount(), 0);
  });

  test('pendingFor: direct target and routed next-hop', () {
    final table = MeshTable('ME');
    // Route to CCC via BBB (BBB is a bidirectional neighbor advertising CCC).
    table.ingest(MeshBeacon(
      callsign: 'BBB',
      deviceClass: MeshDeviceClass.phone,
      cond: const MeshConditions(),
      dv: [
        MeshDvEntry(meshHash('ME'), 1), // sees us → bidirectional
        MeshDvEntry(meshHash('CCC'), 1),
      ],
    ));
    store.offer(
        target: 'BBB', sender: 'ME', wire: _wire('ME', 'BBB', 'direct'));
    store.offer(
        target: 'CCC', sender: 'ME', wire: _wire('ME', 'CCC', 'routed'));
    store.offer(
        target: 'ZZZ', sender: 'ME', wire: _wire('ME', 'ZZZ', 'unreachable'));

    final forB = store.pendingFor('BBB', table);
    expect(forB.length, 2); // direct + routed-via
    final forZ = store.pendingFor('ZZZ', table);
    expect(forZ.length, 1); // only its own
    // Archive one; it stops being pending.
    store.markArchived(forB.first.key);
    expect(store.pendingFor('BBB', table).length, 1);
  });

  test('have-bloom: built from received, applyPeerBloom purges only the owner',
      () {
    store.offer(
        target: 'BBB',
        sender: 'AAA',
        wire: _wire('AAA', 'BBB', 'am:aaaaaa m'),
        am: 'aaaaaa');
    store.offer(
        target: 'CCC',
        sender: 'AAA',
        wire: _wire('AAA', 'CCC', 'am:cccccc m'),
        am: 'cccccc');

    // BBB's beacon says it has aaaaaa (and cccccc — but that row targets CCC).
    final bloom = Uint8List(kMeshBloomBytes);
    meshBloomAdd(bloom, 'aaaaaa');
    meshBloomAdd(bloom, 'cccccc');
    expect(store.applyPeerBloom('BBB', bloom), 1);
    expect(store.pendingCount(), 1); // CCC's copy survives

    // Our own bloom round-trip.
    store.recordReceivedAm('zzzzzz');
    final have = store.buildHaveBloom();
    expect(meshBloomHas(have, 'zzzzzz'), true);
    expect(meshBloomHas(have, 'yyyyyy'), false);
  });

  test('quota sweep evicts archives before in-transit', () {
    store.quotaBytes = 60; // tiny quota: each row ~20B
    for (var i = 0; i < 5; i++) {
      store.offer(
          target: 'BBB',
          sender: 'AAA',
          wire: _wire('AAA', 'BBB', 'msg$i pad pad'),
          am: 'aaaa0$i');
    }
    store.markArchived('aaaa00');
    store.markArchived('aaaa01');
    store.sweep();
    final c = store.counts();
    expect(c.bytes, lessThanOrEqualTo(60));
    // In-transit survived preferentially.
    expect(c.inTransit, greaterThanOrEqualTo(c.archived));
  });

  test('mule custody: own unreachable mail goes to any session peer', () {
    final table = MeshTable('ME');
    table.ingest(MeshBeacon(
      callsign: 'BBB',
      deviceClass: MeshDeviceClass.phone,
      cond: const MeshConditions(),
      dv: [MeshDvEntry(meshHash('ME'), 1)],
    ));
    // Our own message to an unknown target...
    store.offer(target: 'ZZZ', sender: 'ME', wire: _wire('ME', 'ZZZ', 'x'));
    // ...someone else's message to an unknown target (must NOT be muled).
    store.offer(target: 'YYY', sender: 'AAA', wire: _wire('AAA', 'YYY', 'y'));
    final forB =
        store.pendingFor('BBB', table, selfCallsign: 'ME');
    expect(forB.length, 1);
    expect(store.ownPendingTargets('ME'), ['ZZZ']);
  });

  test('bulk handover records', () {
    expect(store.bulkHandedOver('sha1', 'BBB'), false);
    store.recordBulkHandover('sha1', 'BBB', 'CCC');
    expect(store.bulkHandedOver('sha1', 'BBB'), true);
  });
}

// M3 additions exercised on the same store fixture set.
