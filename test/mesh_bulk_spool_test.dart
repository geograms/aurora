/*
 * MeshBulkSpool tests — offer/resume/verify/custody-relay lifecycle on a
 * temp dir, with a real MediaArchive for the origin path.
 */
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/mesh/mesh_bulk_spool.dart';
import 'package:aurora/services/mesh/mesh_session.dart';
import 'package:aurora/services/mesh/mesh_store.dart';
import 'package:aurora/util/media_archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';

void main() {
  late Directory tmp;
  late MeshBulkSpool spool;
  late MediaArchive archive;

  setUpAll(() {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('meshbulk');
    archive = MediaArchive.forDirectory(tmp.path);
    spool = MeshBulkSpool.instance;
    spool.init('${tmp.path}/bulk', archive);
    MeshStore.instance.init('${tmp.path}/mesh.sqlite3');
  });

  tearDown(() {
    MeshStore.instance.close();
    tmp.deleteSync(recursive: true);
  });

  Uint8List blob(int n) =>
      Uint8List.fromList(List.generate(n, (i) => (i * 31 + 7) & 0xFF));

  MspFileOffer offerFor(Uint8List data, {String target = 'ME'}) {
    final sha = Uint8List.fromList(crypto.sha256.convert(data).bytes);
    return MspFileOffer(
      xfer: 1,
      sha256: sha,
      size: data.length,
      ttlS: 3600,
      origin: 'AAA',
      target: target,
      ext: 'bin',
      name: 'test.bin',
    );
  }

  test('inbound: offer -> chunks -> verify -> archive for final target', () {
    final data = blob(300000);
    final o = offerFor(data);
    final d = spool.offered('AAA', o);
    expect(d.accept, true);
    expect(d.offset, 0);
    for (var off = 0; off < data.length; off += 498) {
      final end = (off + 498).clamp(0, data.length);
      expect(
          spool.writeAt(
              o.sha256, off, Uint8List.sublistView(data, off, end)),
          true);
    }
    expect(spool.verify(o.sha256), true);
    spool.completeInbound(o.sha256, selfCallsign: 'ME');
    // The bytes landed content-addressed in the archive.
    expect(archive.get('file:${MeshBulkSpool.shaB64u(o.sha256)}.bin'),
        isNotNull);
    // Re-offer now dup-accepts at size.
    final d2 = spool.offered('AAA', o);
    expect(d2.accept, true);
    expect(d2.offset, o.size);
  });

  test('resume: partial .part -> offer answers with its length', () {
    final data = blob(50000);
    final o = offerFor(data);
    spool.offered('AAA', o);
    spool.writeAt(o.sha256, 0, Uint8List.sublistView(data, 0, 20000));
    // "New session": offer again — resume from 20000.
    final d = spool.offered('AAA', o);
    expect(d.accept, true);
    expect(d.offset, 20000);
    spool.writeAt(o.sha256, 20000, Uint8List.sublistView(data, 20000));
    expect(spool.verify(o.sha256), true);
  });

  test('relay custody: complete for OTHER target -> ready -> handover deletes',
      () {
    final data = blob(10000);
    final o = offerFor(data, target: 'CCC');
    spool.offered('AAA', o);
    spool.writeAt(o.sha256, 0, data);
    expect(spool.verify(o.sha256), true);
    spool.completeInbound(o.sha256, selfCallsign: 'ME');
    // We are custodian: pending for CCC, but never back to AAA (the giver).
    expect(spool.pendingCount(), 1);
    expect(spool.nextFor('CCC', null), isNotNull);
    expect(spool.nextFor('AAA', null), isNull);
    // Handover downstream drops the payload + records it.
    spool.handedOver(o.sha256, 'CCC');
    expect(spool.pendingCount(), 0);
    expect(
        MeshStore.instance.bulkHandedOver(MeshBulkSpool.shaHex(o.sha256), 'CCC'),
        true);
  });

  test('origin: enqueueFromArchive serves reads from the archive blob', () {
    final data = blob(5000);
    final token = archive.putBytes(data, 'bin', name: 'pic');
    expect(spool.enqueueFromArchive(token, 'BBB', 'ME'), true);
    expect(spool.enqueueFromArchive(token, 'BBB', 'ME'), false); // dedup
    final p = spool.nextFor('BBB', null);
    expect(p, isNotNull);
    expect(p!.size, data.length);
    final chunk = spool.readAt(p.sha256, 1000, 498);
    expect(chunk, Uint8List.sublistView(data, 1000, 1498));
    spool.handedOver(p.sha256, 'BBB');
    expect(spool.nextFor('BBB', null), isNull); // done
  });

  test('verify failure truncates the poison partial', () {
    final data = blob(2000);
    final o = offerFor(data);
    spool.offered('AAA', o);
    spool.writeAt(o.sha256, 0, blob(1999)); // wrong bytes, right-ish length
    spool.writeAt(o.sha256, 1999, Uint8List.fromList([1]));
    expect(spool.verify(o.sha256), false);
    // Partial removed → next offer restarts at 0.
    final d = spool.offered('AAA', o);
    expect(d.offset, 0);
  });
}
