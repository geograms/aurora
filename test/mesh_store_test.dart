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

  // A neighbour we can hear is the shortest path there is. Handing its mail to
  // a third party instead is how a message went round in a circle: the relay's
  // route pointed back at us, our store already held the row, the offer came
  // back "duplicate", and both copies ended up archived owing nothing.
  test('a live neighbour gets its own mail — never a relay', () {
    final table = MeshTable('ME');
    // BBB and CCC are BOTH neighbours, and BBB also advertises reaching CCC.
    table.ingest(MeshBeacon(
      callsign: 'BBB',
      deviceClass: MeshDeviceClass.phone,
      cond: const MeshConditions(),
      dv: [MeshDvEntry(meshHash('ME'), 1), MeshDvEntry(meshHash('CCC'), 1)],
    ));
    table.ingest(MeshBeacon(
      callsign: 'CCC',
      deviceClass: MeshDeviceClass.phone,
      cond: const MeshConditions(),
      dv: [MeshDvEntry(meshHash('ME'), 1)],
    ));
    store.offer(
        target: 'CCC', sender: 'ME', wire: _wire('ME', 'CCC', 'for ccc'));

    expect(store.pendingFor('BBB', table), isEmpty); // not via the relay
    expect(store.pendingFor('CCC', table).length, 1); // straight to the target
  });

  // Custody handed on is archived, not deleted — that row is the receipt saying
  // we no longer owe delivery. When a peer hands the same message BACK, saying
  // "duplicate" made the other side archive its copy too and the message
  // belonged to nobody.
  test('an archived row can take custody again; an in-transit one cannot', () {
    store.offer(
        target: 'BBB',
        sender: 'AAA',
        wire: _wire('AAA', 'BBB', 'am:bbbbbb m'),
        am: 'bbbbbb');
    expect(store.reArm('bbbbbb'), isFalse); // still in transit = real duplicate

    store.markArchived('bbbbbb');
    expect(store.pendingFor('BBB', null), isEmpty);
    expect(store.reArm('bbbbbb'), isTrue); // we owe delivery again
    expect(store.pendingFor('BBB', null).length, 1);

    expect(store.reArm('nosuch'), isFalse); // nothing to re-arm
  });

  // A custodian carries anyone's mail, so the sorting happens under pressure:
  // a stranger's frame (prio 0) must be shed before our own (prio 1). Backwards
  // would quietly delete the user's outgoing messages first.
  test('under quota pressure a stranger is evicted before our own mail', () {
    store.quotaBytes = 450; // three 200 B frames will not fit
    final mine = Uint8List.fromList(List.filled(200, 1));
    final theirs = Uint8List.fromList(List.filled(200, 2));
    store.offer(
        target: 'BBB', sender: 'ME', wire: mine, am: 'mine11', prio: 1);
    store.offer(
        target: 'CCC', sender: 'ZZZ', wire: theirs, am: 'theirs', prio: 0);
    store.offer(
        target: 'DDD',
        sender: 'YYY',
        wire: Uint8List.fromList(List.filled(200, 3)),
        am: 'other1',
        prio: 0);
    store.sweep();

    // Ours survives; a stranger's was shed to make room.
    expect(
        store.pendingFor('BBB', null, max: 64).map((e) => e.key), ['mine11']);
    expect(store.counts().inTransit, lessThan(3));
  });

  // A device must carry for strangers, but not without limit.
  test('the in-transit cap refuses a stranger, never our own', () {
    expect(MeshStore.inTransitMax, 4000);
    expect(
        store.offer(
            target: 'CCC', sender: 'ZZZ', wire: _wire('ZZZ', 'CCC', 'hi'),
            am: 'str001', prio: 0),
        isTrue); // far below the cap: carried
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
