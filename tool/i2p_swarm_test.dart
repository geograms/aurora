// Pure (no-network) unit tests for the swarm layer:
//  1. multi-cell tunnel fragment reassembly (the foundation for any file > one
//     ~1 KB cell), including out-of-order cells and multiple fragments per cell;
//  2. deterministic manifest build / encode / decode;
//  3. the temp-file-backed SwarmStore (write, verify-reject, read, bitmap,
//     assemble);
//  4. piece / manifest / have datagram payload roundtrips.
//   dart run tool/i2p_swarm_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_crypto.dart';
import 'package:aurora/services/i2p/i2p_datagram.dart' show ReplyLease;
import 'package:aurora/services/i2p/i2p_swarm.dart';
import 'package:aurora/services/i2p/i2p_tunnel_data.dart';

var _pass = 0, _fail = 0;
void ok(bool c, String m) {
  if (c) {
    _pass++;
    print('  ok   $m');
  } else {
    _fail++;
    print('  FAIL $m');
  }
}

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List be32(int v) =>
    Uint8List.fromList([(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);

/// Build a decrypted 1024-byte cell ([16 IV][1008 data]) carrying the given
/// fragments back-to-back, mimicking how a tunnel gateway packs a cell:
/// data = [4 checksum][0x00 delimiter][fragments...].
Uint8List makeCell(List<Uint8List> fragments) {
  final region = Uint8List(1024);
  var fragLen = 0;
  for (final f in fragments) {
    fragLen += f.length;
  }
  // Real I2P layout: [4 checksum][nonzero front padding][0x00][fragments...]
  // filling the 1008-byte region exactly (no trailing padding).
  final pad = 1008 - 4 - 1 - fragLen;
  final body = BytesBuilder();
  body.add([0xaa, 0xbb, 0xcc, 0xdd]); // checksum (ignored by the parser)
  if (pad > 0) body.add(Uint8List(pad)..fillRange(0, pad, 0xff)); // nonzero pad
  body.addByte(0x00); // delimiter
  for (final f in fragments) {
    body.add(f);
  }
  final bytes = body.toBytes();
  region.setRange(16, 16 + bytes.length, bytes);
  return region;
}

Uint8List firstFragment(Uint8List data, {int? msgId}) {
  final b = BytesBuilder();
  final fragmented = msgId != null;
  b.addByte((fragmented ? 0x08 : 0x00)); // delivery type LOCAL(0), frag bit
  if (fragmented) b.add(be32(msgId));
  b.add([(data.length >> 8) & 0xff, data.length & 0xff]);
  b.add(data);
  return b.toBytes();
}

Uint8List followOn(int msgId, int fragNum, bool last, Uint8List data) {
  final b = BytesBuilder();
  b.addByte(0x80 | ((fragNum & 0x3f) << 1) | (last ? 1 : 0));
  b.add(be32(msgId));
  b.add([(data.length >> 8) & 0xff, data.length & 0xff]);
  b.add(data);
  return b.toBytes();
}

Future<void> testReassembly() async {
  print('reassembly:');
  // single unfragmented fragment -> emitted immediately
  {
    final r = TunnelReassembler();
    final payload = Uint8List.fromList(List.generate(500, (i) => i & 0xff));
    final out = r.addCell(makeCell([firstFragment(payload)]));
    ok(out.length == 1 && hex(out[0]) == hex(payload), 'single-cell message');
  }
  // multi-cell fragmented message, in order
  {
    final r = TunnelReassembler();
    const msgId = 0x11223344;
    final msg = Uint8List.fromList(List.generate(2600, (i) => (i * 7) & 0xff));
    final chunks = <Uint8List>[];
    for (var o = 0; o < msg.length; o += 900) {
      chunks.add(msg.sublist(o, (o + 900 <= msg.length) ? o + 900 : msg.length));
    }
    final emitted = <Uint8List>[];
    emitted.addAll(r.addCell(makeCell([firstFragment(chunks[0], msgId: msgId)])));
    for (var i = 1; i < chunks.length; i++) {
      emitted.addAll(r.addCell(
          makeCell([followOn(msgId, i, i == chunks.length - 1, chunks[i])])));
    }
    ok(emitted.length == 1 && hex(emitted[0]) == hex(msg),
        'multi-cell in order (${chunks.length} cells)');
  }
  // multi-cell, cells delivered OUT OF ORDER
  {
    final r = TunnelReassembler();
    const msgId = 0x55667788;
    final msg = Uint8List.fromList(List.generate(3000, (i) => (i * 13) & 0xff));
    final chunks = <Uint8List>[];
    for (var o = 0; o < msg.length; o += 800) {
      chunks.add(msg.sublist(o, (o + 800 <= msg.length) ? o + 800 : msg.length));
    }
    final cells = <Uint8List>[];
    cells.add(makeCell([firstFragment(chunks[0], msgId: msgId)]));
    for (var i = 1; i < chunks.length; i++) {
      cells.add(
          makeCell([followOn(msgId, i, i == chunks.length - 1, chunks[i])]));
    }
    // reverse order
    final emitted = <Uint8List>[];
    for (final c in cells.reversed) {
      emitted.addAll(r.addCell(c));
    }
    ok(emitted.length == 1 && hex(emitted[0]) == hex(msg),
        'multi-cell out of order');
  }
  // multiple fragments packed into one cell
  {
    final r = TunnelReassembler();
    final a = Uint8List.fromList(List.filled(100, 0x41));
    final b = Uint8List.fromList(List.filled(120, 0x42));
    final out = r.addCell(makeCell([firstFragment(a), firstFragment(b)]));
    ok(out.length == 2 && hex(out[0]) == hex(a) && hex(out[1]) == hex(b),
        'two messages in one cell');
  }
}

Future<void> testManifest() async {
  print('manifest:');
  final data = Uint8List.fromList(List.generate(200000, (i) => (i * 31) & 0xff));
  final m1 = TorrentManifest.fromBytes(data);
  final m2 = TorrentManifest.fromBytes(Uint8List.fromList(data));
  ok(hex(m1.fileSha) == hex(I2pCrypto.sha256(data)), 'fileSha matches content');
  ok(hex(m1.encode()) == hex(m2.encode()), 'deterministic (same bytes -> same manifest)');
  ok(m1.pieceCount == pieceCountFor(data.length, m1.pieceLen), 'piece count consistent');
  final dec = TorrentManifest.decode(m1.encode());
  ok(dec != null && hex(dec.fileSha) == hex(m1.fileSha) &&
      dec.pieceCount == m1.pieceCount && dec.pieceLen == m1.pieceLen,
      'encode/decode roundtrip');
  ok(TorrentManifest.decode(Uint8List.fromList([0, 1, 2, 3])) == null,
      'rejects garbage');
  ok(swarmSupported(50 * 1024 * 1024), '50MB supported');
}

Future<void> testStore() async {
  print('store:');
  final tmp = await Directory.systemTemp.createTemp('swarmtest');
  try {
    final data = Uint8List.fromList(List.generate(200000, (i) => (i * 91) & 0xff));
    final m = TorrentManifest.fromBytes(data);
    final store = await SwarmStore.open(m, tmp);
    ok(store.haveCount == 0 && !store.isComplete, 'starts empty');
    // wrong bytes are rejected
    final bad = await store.writePiece(0, Uint8List(m.pieceSize(0)));
    ok(!bad, 'rejects piece failing hash');
    // write every real piece (out of order)
    final order = List.generate(m.pieceCount, (i) => i)..shuffle();
    var allOk = true;
    for (final i in order) {
      final start = i * m.pieceLen;
      final end = (start + m.pieceLen <= data.length) ? start + m.pieceLen : data.length;
      if (!await store.writePiece(i, Uint8List.fromList(data.sublist(start, end)))) {
        allOk = false;
      }
    }
    ok(allOk && store.isComplete, 'accepts all verified pieces -> complete');
    // bitmap full
    final bm = store.bitmap();
    var bits = true;
    for (var i = 0; i < m.pieceCount; i++) {
      if (!bitmapHas(bm, i)) bits = false;
    }
    ok(bits, 'bitmap reports all pieces');
    final mid = m.pieceCount ~/ 2;
    final pc = await store.readPiece(mid);
    final s = mid * m.pieceLen;
    final e = (s + m.pieceLen <= data.length) ? s + m.pieceLen : data.length;
    ok(pc != null && hex(pc) == hex(data.sublist(s, e)), 'readPiece returns bytes');
    final asm = await store.assemble();
    ok(asm != null && hex(asm) == hex(data), 'assemble reconstructs the file');
    await store.dispose();
  } finally {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  }
}

Future<void> testPayloads() async {
  print('payloads:');
  final sha = I2pCrypto.sha256([1, 2, 3]);
  final leases = [ReplyLease(I2pCrypto.sha256([9]), 0x01020304)];
  final gm = parseFileShaReq(buildGetManifest(sha, leases));
  ok(gm != null && hex(gm.$1) == hex(sha) && gm.$2.length == 1, 'GETMANIFEST');
  final man = TorrentManifest.fromBytes(Uint8List.fromList(List.filled(5000, 7)));
  final dm = parseDatManifest(buildDatManifest(sha, man.encode()));
  ok(dm != null && hex(dm.$1) == hex(sha) && hex(dm.$2) == hex(man.encode()), 'DATMANIFEST');
  final bm = Uint8List.fromList([0xff, 0x80]);
  final dh = parseDatHave(buildDatHave(sha, 9, bm));
  ok(dh != null && dh.$2 == 9 && hex(dh.$3) == hex(bm), 'DATHAVE');
  final gp = parseGetPiece(buildGetPiece(sha, 42, leases));
  ok(gp != null && gp.$2 == 42 && gp.$3.length == 1 && gp.$3[0].tunnelId == 0x01020304, 'GETPIECE');
  final piece = Uint8List.fromList(List.generate(32768, (i) => i & 0xff));
  final dp = parseDatPiece(buildDatPiece(sha, 42, piece));
  ok(dp != null && dp.$2 == 42 && hex(dp.$3) == hex(piece), 'DATPIECE 32KiB');
}

Future<void> main() async {
  await testReassembly();
  await testManifest();
  await testStore();
  await testPayloads();
  print('\n$_pass passed, $_fail failed');
  if (_fail == 0) {
    print('>>> SUCCESS: swarm fragment reassembly + manifest + store + payloads');
  }
  exit(_fail == 0 ? 0 : 1);
}
