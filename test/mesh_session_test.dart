/*
 * MSP (Mesh Session Protocol) tests — codec fixtures + session FSM loopback.
 *
 * The hex fixtures here are the shared source of truth with the C mirror
 * (esp32/components/geogram_blemesh/blemesh_session.c, checked by
 * test_msp_host.c) — a codec change that breaks one must break both.
 */
import 'dart:typed_data';

import 'package:aurora/services/mesh/mesh_bloom.dart';
import 'package:aurora/services/mesh/mesh_session.dart';
import 'package:flutter_test/flutter_test.dart';

String hex(Uint8List d) =>
    d.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String s) {
  final d = Uint8List(s.length ~/ 2);
  for (var i = 0; i < d.length; i++) {
    d[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return d;
}

void main() {
  group('MSP codec fixtures (shared with C)', () {
    test('HELLO', () {
      final f = MspHello(
        caps: 0x000F,
        callsign: 'X1A67X',
        maxFrame: 509,
        spoolFreeKb: 1024,
        pendingMsgs: 3,
        pendingBulk: 1,
      ).encode();
      expect(hex(f), '4d01010f0006583141363758fd0100040000030001');
      final d = mspDecode(f) as MspHello?;
      expect(d!.caps, 0x000F);
      expect(d.callsign, 'X1A67X');
      expect(d.maxFrame, 509);
      expect(d.spoolFreeKb, 1024);
      expect(d.pendingMsgs, 3);
      expect(d.pendingBulk, 1);
    });

    test('MSG', () {
      final f = MspMsg(
        seq: 7,
        am: 'a1b2c3',
        ts: 0x01020304,
        wire: Uint8List.fromList('X1\x1FX2\x1Fhi'.codeUnits),
      ).encode();
      expect(hex(f),
          '4d0110070161316232633304030201080058311f58321f6869');
      final d = mspDecode(f) as MspMsg?;
      expect(d!.seq, 7);
      expect(d.am, 'a1b2c3');
      expect(d.ts, 0x01020304);
      expect(String.fromCharCodes(d.wire), 'X1\x1FX2\x1Fhi');
    });

    test('MSG_ACK', () {
      expect(hex(MspMsgAck([7, 9]).encode()), '4d0111020709');
      final d = mspDecode(unhex('4d0111020709')) as MspMsgAck?;
      expect(d!.seqs, [7, 9]);
    });

    test('GOSSIP', () {
      final f = MspGossip(
        more: false,
        entries: [
          MspGossipEntry(Uint8List.fromList([0xaa, 0xbb, 0xcc]), 2),
          MspGossipEntry(Uint8List.fromList([0x11, 0x22, 0x33]), 1),
        ],
        bloom: Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]),
      ).encode();
      expect(hex(f), '4d01020002aabbcc021122330104 00deadbeef'.replaceAll(' ', ''));
      final d = mspDecode(f) as MspGossip?;
      expect(d!.entries.length, 2);
      expect(d.entries[0].cost, 2);
      expect(hex(d.bloom), 'deadbeef');
    });

    test('FILE_OFFER', () {
      final sha = Uint8List.fromList(List.generate(32, (i) => i));
      final f = MspFileOffer(
        xfer: 0xDEADBEEF,
        sha256: sha,
        size: 104857600,
        ttlS: 604800,
        origin: 'X32DVA',
        target: 'X1A67X',
        ext: 'bin',
        name: 'test.bin',
      ).encode();
      expect(
          hex(f),
          '4d0120efbeadde'
          '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
          '0000400600000000'
          '803a0900'
          '06583332445641'
          '06583141363758'
          '0362696e'
          '08746573742e62696e');
      final d = mspDecode(f) as MspFileOffer?;
      expect(d!.xfer, 0xDEADBEEF);
      expect(hex(d.sha256), hex(sha));
      expect(d.size, 104857600);
      expect(d.ttlS, 604800);
      expect(d.origin, 'X32DVA');
      expect(d.target, 'X1A67X');
      expect(d.ext, 'bin');
      expect(d.name, 'test.bin');
    });

    test('CHUNK / WIN_ACK / ACCEPT / BYE', () {
      expect(
          hex(MspChunk(0xDEADBEEF, 65536, Uint8List.fromList([0xde, 0xad]))
              .encode()),
          '4d0123efbeadde00000100dead');
      expect(hex(MspWinAck(0xDEADBEEF, 131072, 16).encode()),
          '4d0124efbeadde000002001000');
      expect(hex(MspFileAccept(1, 0, 16).encode()),
          '4d012101000000000000001000');
      expect(hex(MspBye(MspBye.politeness).encode()), '4d010301');
      final c = mspDecode(unhex('4d0123efbeadde00000100dead')) as MspChunk?;
      expect(c!.offset, 65536);
      expect(hex(c.data), 'dead');
    });

    test('demux never collides with legacy parcels or JSON', () {
      // Legacy parcel: msgId is two A-Z letters -> byte[1] in 0x41..0x5A.
      expect(mspIsFrame(Uint8List.fromList([0x41, 0x42, 0x00, 0x01])), false);
      // JSON receipt starts '{'.
      expect(mspIsFrame(Uint8List.fromList('{"t":1}'.codeUnits)), false);
      expect(mspIsFrame(Uint8List.fromList([0x4D, 0x01, 0x01])), true);
      expect(mspIsFrame(Uint8List.fromList([0x4D, 0x02, 0x01])), false);
      // Every encoded frame demuxes as MSP.
      expect(mspIsFrame(MspBye(0).encode()), true);
    });

    test('malformed frames decode to null, never throw', () {
      for (final f in [
        '4d0101', // empty hello body
        '4d0110070161', // truncated msg
        '4d0120efbeadde0001', // truncated offer
      ]) {
        expect(mspDecode(unhex(f)), isNull, reason: f);
      }
    });
  });

  group('mesh bloom', () {
    test('add/has + fixture (shared with C)', () {
      final b = Uint8List(kMeshBloomBytes);
      meshBloomAdd(b, 'a1b2c3');
      expect(meshBloomHas(b, 'a1b2c3'), true);
      expect(meshBloomHas(b, 'ffffff'), false);
      // Fixture: exact filter bytes after one add — C must reproduce.
      // ignore: avoid_print
      print('BLOOM_FIXTURE a1b2c3 -> ${hex(b)}');
    });

    test('capacity: 150 ams, low false-positive rate', () {
      final ams = List.generate(150, (i) => i.toRadixString(16).padLeft(6, '0'));
      final b = meshBloomBuild(ams);
      for (final am in ams) {
        expect(meshBloomHas(b, am), true);
      }
      var fp = 0;
      for (var i = 1000; i < 2000; i++) {
        if (meshBloomHas(b, i.toRadixString(16).padLeft(6, '0'))) fp++;
      }
      expect(fp, lessThan(60)); // ~3.9% theoretical at 150 entries
    });
  });

  group('MSP session FSM loopback', () {
    test('hello handshake + gossip swap', () async {
      final net = _Net();
      expect(net.a.state, MeshSessionState.hello);
      await net.run();
      expect(net.a.state, MeshSessionState.active);
      expect(net.b.state, MeshSessionState.active);
      expect(net.a.peerCallsign, 'BBB');
      expect(net.b.peerCallsign, 'AAA');
      expect(net.da.gossipsSeen, 1);
      expect(net.db.gossipsSeen, 1);
    });

    test('message custody transfers and archives', () async {
      final net = _Net();
      net.da.outbox.addAll([
        MeshPendingMsg(am: 'aaaaaa', wire: _w('X\x1FY\x1Fm1'), ts: 1),
        MeshPendingMsg(am: 'bbbbbb', wire: _w('X\x1FY\x1Fm2'), ts: 2),
      ]);
      await net.run();
      expect(net.db.msgsReceived.map((m) => m.am), ['aaaaaa', 'bbbbbb']);
      expect(net.da.transferred.map((m) => m.am), ['aaaaaa', 'bbbbbb']);
    });

    test('duplicate custody msg still archives at sender', () async {
      final net = _Net();
      net.db.msgResult = MspMsgRej.duplicate;
      net.da.outbox
          .add(MeshPendingMsg(am: 'cccccc', wire: _w('X\x1FY\x1Fm'), ts: 1));
      await net.run();
      expect(net.da.transferred.length, 1);
      expect(net.db.msgsReceived.length, 1); // delivered to delegate; it deduped
    });

    test('bulk transfer end-to-end with integrity', () async {
      final net = _Net();
      final data = Uint8List.fromList(
          List.generate(100 * 1024, (i) => (i * 31 + 7) & 0xFF));
      net.da.serveBulk(data, target: 'BBB', name: 'blob.bin');
      await net.run();
      expect(net.db.rxFiles.length, 1);
      expect(hex(net.db.rxFiles.values.first), hex(data));
      expect(net.da.bulkDoneOk, [true]);
      expect(net.db.bulkDoneOk, [true]);
    });

    test('bulk resume from receiver-stated offset', () async {
      final net = _Net();
      final data = Uint8List.fromList(
          List.generate(50 * 1024, (i) => (i * 13 + 1) & 0xFF));
      net.da.serveBulk(data, target: 'BBB', name: 'blob.bin');
      // Receiver already holds the first 20000 bytes from an earlier session.
      net.db.resumeOffset = 20000;
      net.db.preload(net.da.bulkSha!, data.sublist(0, 20000));
      await net.run();
      expect(hex(net.db.rxFiles.values.first), hex(data));
      // Nothing before the resume point was re-sent.
      expect(net.db.minChunkOffset, 20000);
    });

    test('dup suppression: accept-at-size hands custody without bytes',
        () async {
      final net = _Net();
      final data = Uint8List.fromList(List.generate(1024, (i) => i & 0xFF));
      net.da.serveBulk(data, target: 'BBB', name: 'dup.bin');
      net.db.resumeOffset = data.length; // "already have it"
      await net.run();
      expect(net.da.bulkDoneOk, [true]);
      expect(net.db.chunksSeen, 0);
    });

    test('interrupted transfer resumes in a new session and completes',
        () async {
      // Simulate a politeness cycle / link drop: kill both ends mid-transfer.
      var net = _Net();
      final data = Uint8List.fromList(
          List.generate(64 * 1024, (i) => (i * 7 + 3) & 0xFF));
      net.da.serveBulk(data, target: 'BBB', name: 'big.bin');
      final theNet = net;
      net.db.afterChunk = (n) {
        if (n == 20) {
          theNet.a.close(clean: false);
          theNet.b.close(clean: false);
        }
      };
      await net.run();
      expect(net.db.rxFiles, isEmpty); // interrupted
      final partial = net.db.partial(net.da.bulkSha!);
      expect(partial, isNotNull);
      expect(partial!.length, greaterThan(0));
      expect(partial.length, lessThan(data.length));

      // New session, same delegates (spool persisted): resumes at offset.
      final da = net.da, db = net.db;
      db.afterChunk = null;
      db.resumeOffset = partial.length;
      db.minChunkOffset = 1 << 62;
      net = _Net(da: da, db: db);
      await net.run();
      expect(hex(db.rxFiles.values.single), hex(data));
      expect(db.minChunkOffset, partial.length);
    });

    test('hash mismatch fails the transfer and truncates nothing silently',
        () async {
      final net = _Net();
      final data = Uint8List.fromList(List.generate(2048, (i) => i & 0xFF));
      net.da.serveBulk(data, target: 'BBB', name: 'bad.bin');
      net.db.verifyResult = false;
      await net.run();
      expect(net.da.bulkDoneOk, [false]);
      expect(net.db.bulkDoneOk, [false]);
    });
  });
}

Uint8List _w(String s) => Uint8List.fromList(s.codeUnits);

// ---------------------------------------------------------------------------
// In-memory harness: two sessions joined by ordered frame queues.
// ---------------------------------------------------------------------------

class _Delegate implements MeshSessionDelegate {
  final List<MeshPendingMsg> outbox = [];
  final List<MeshPendingMsg> transferred = [];
  final List<MspMsg> msgsReceived = [];
  int msgResult = 0;
  int gossipsSeen = 0;

  // bulk tx side
  Uint8List? bulkData;
  Uint8List? bulkSha;
  MeshBulkPending? bulkPending;
  bool bulkServed = false;

  // bulk rx side
  int resumeOffset = 0;
  bool verifyResult = true;
  final Map<String, List<int>> _spool = {};
  final Map<String, Uint8List> rxFiles = {};
  final List<bool> bulkDoneOk = [];
  int chunksSeen = 0;
  int minChunkOffset = 1 << 62;
  void Function(int chunksSeen)? afterChunk;

  void serveBulk(Uint8List data, {required String target, required String name}) {
    bulkData = data;
    bulkSha = Uint8List.fromList(List.generate(32, (i) => (data.length + i) & 0xFF));
    bulkPending = MeshBulkPending(
      sha256: bulkSha!,
      size: data.length,
      ttlS: 3600,
      origin: 'AAA',
      target: target,
      ext: 'bin',
      name: name,
    );
    bulkServed = false;
  }

  void preload(Uint8List sha, Uint8List head) {
    _spool[hex(sha)] = List<int>.from(head);
  }

  Uint8List? partial(Uint8List sha) {
    final l = _spool[hex(sha)];
    return l == null ? null : Uint8List.fromList(l);
  }

  @override
  List<MeshPendingMsg> custodyBatchFor(String peer, int max) {
    final batch = outbox.take(max).toList();
    outbox.removeRange(0, batch.length);
    return batch;
  }

  @override
  void custodyTransferred(String peer, MeshPendingMsg m) => transferred.add(m);

  @override
  int msgReceived(String peer, MspMsg m) {
    msgsReceived.add(m);
    return msgResult;
  }

  @override
  MspGossip gossipData() => MspGossip(bloom: Uint8List(kMeshBloomBytes));

  @override
  void gossipReceived(String peer, MspGossip g) => gossipsSeen++;

  @override
  MeshBulkPending? nextBulkFor(String peer) {
    if (bulkPending == null || bulkServed) return null;
    return bulkPending;
  }

  @override
  MeshBulkDecision bulkOffered(String peer, MspFileOffer offer) =>
      MeshBulkDecision.accept(resumeOffset);

  @override
  Uint8List bulkRead(Uint8List sha256, int offset, int len) {
    final d = bulkData;
    if (d == null || offset >= d.length) return Uint8List(0);
    final end = (offset + len).clamp(0, d.length);
    return Uint8List.sublistView(d, offset, end);
  }

  @override
  bool bulkWrite(Uint8List sha256, int offset, Uint8List data) {
    chunksSeen++;
    if (offset < minChunkOffset) minChunkOffset = offset;
    final key = hex(sha256);
    final l = _spool.putIfAbsent(key, () => []);
    if (l.length != offset) return false; // harness writes are contiguous
    l.addAll(data);
    afterChunk?.call(chunksSeen);
    return true;
  }

  @override
  bool bulkVerified(Uint8List sha256) => verifyResult;

  @override
  void bulkDone(String peer, Uint8List sha256, bool ok, {required bool toPeer}) {
    if (toPeer) {
      bulkDoneOk.add(ok);
      if (ok) bulkServed = true;
    } else {
      bulkDoneOk.add(ok);
      if (ok) {
        rxFiles[hex(sha256)] =
            Uint8List.fromList(_spool[hex(sha256)] ?? const []);
      }
    }
  }

  @override
  void sessionClosed(String peer, {required bool clean}) {}
}

class _Net {
  final _Delegate da;
  final _Delegate db;
  late final MeshSession a;
  late final MeshSession b;
  final List<Uint8List> _toA = [];
  final List<Uint8List> _toB = [];

  _Net({Duration sessionCap = const Duration(seconds: 300),
      _Delegate? da, _Delegate? db})
      : da = da ?? _Delegate(),
        db = db ?? _Delegate() {
    a = MeshSession(
      dialer: true,
      selfCallsign: 'AAA',
      send: (f) async => _toB.add(f),
      delegate: this.da,
      sessionCap: sessionCap,
    );
    b = MeshSession(
      dialer: false,
      selfCallsign: 'BBB',
      send: (f) async => _toA.add(f),
      delegate: this.db,
    );
  }

  /// Start both sessions and pump frames until the network is quiet
  /// (including the 150 ms ack batch timer).
  Future<void> run() async {
    await a.start();
    await b.start();
    for (var quiet = 0; quiet < 3;) {
      var moved = false;
      while (_toB.isNotEmpty || _toA.isNotEmpty) {
        moved = true;
        if (_toB.isNotEmpty) await b.onFrame(_toB.removeAt(0));
        if (_toA.isNotEmpty) await a.onFrame(_toA.removeAt(0));
      }
      if (moved) {
        quiet = 0;
      } else {
        quiet++;
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }
}

