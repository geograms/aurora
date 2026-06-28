import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:aurora/connections/bluetooth/ble_reassembler.dart';

// Build the chunk advert manufacturer-data bytes (company id already stripped,
// matching what the scan API hands us). Frame format includes the 1-byte sender
// discriminator (srcTag): PRIMARY [marker,sub,srcTag,msgId,idx,total,flags,…],
// CONT [marker,sub,srcTag,msgId,idx,…].
Uint8List primary(int srcTag, int msgId, int idx, int total, List<int> payload,
        {bool hasCont = false}) =>
    Uint8List.fromList([
      kBleMarker, kBleBcastPrimary, srcTag, msgId, idx, total,
      hasCont ? 1 : 0, ...payload,
    ]);
Uint8List cont(int srcTag, int msgId, int idx, List<int> payload) =>
    Uint8List.fromList([kBleMarker, kBleBcastCont, srcTag, msgId, idx, ...payload]);

// Split a payload into chunks the way the sender would, then return the advert
// entries (primary [+cont]) in transmission order.
List<Uint8List> chunkify(int srcTag, int msgId, List<int> payload,
    {int advCap = 12, int contCap = 22}) {
  final out = <Uint8List>[];
  // Plan each chunk's primary slice and optional continuation slice.
  final slices = <List<int>>[];
  var i = 0;
  while (i < payload.length) {
    final end = (i + advCap + contCap < payload.length)
        ? i + advCap + contCap
        : payload.length;
    slices.add(payload.sublist(i, end));
    i = end;
  }
  if (slices.isEmpty) slices.add(const []);
  final total = slices.length;
  for (var idx = 0; idx < total; idx++) {
    final s = slices[idx];
    final pPart = s.sublist(0, s.length < advCap ? s.length : advCap);
    final cPart = s.length > advCap ? s.sublist(advCap) : const <int>[];
    out.add(primary(srcTag, msgId, idx, total, pPart, hasCont: cPart.isNotEmpty));
    if (cPart.isNotEmpty) out.add(cont(srcTag, msgId, idx, cPart));
  }
  return out;
}

void main() {
  group('BleBroadcastReassembler', () {
    test('single-chunk message (ADV-only) reassembles', () {
      final r = BleBroadcastReassembler();
      final payload = List<int>.generate(10, (i) => i + 1);
      final entries = chunkify(1, 7, payload);
      expect(entries.length, 1); // fits one primary
      Uint8List? got;
      for (final e in entries) {
        got = r.ingest('peerA', e) ?? got;
      }
      expect(got, Uint8List.fromList(payload));
    });

    test('multi-chunk ~300B message reassembles (primary + continuation)', () {
      final r = BleBroadcastReassembler();
      final payload = List<int>.generate(300, (i) => i % 256);
      final entries = chunkify(1, 9, payload);
      expect(entries.length, greaterThan(2)); // many chunks
      Uint8List? got;
      for (final e in entries) {
        got = r.ingest('peerA', e) ?? got;
      }
      expect(got, Uint8List.fromList(payload));
    });

    test('out-of-order and duplicated chunks still reassemble once', () {
      final r = BleBroadcastReassembler();
      final payload = List<int>.generate(200, (i) => (i * 3) % 256);
      final entries = chunkify(1, 5, payload);
      final shuffled = [...entries.reversed, ...entries]; // reversed + duplicates
      var deliveries = 0;
      Uint8List? got;
      for (final e in shuffled) {
        final r2 = r.ingest('peerA', e);
        if (r2 != null) {
          deliveries++;
          got = r2;
        }
      }
      expect(deliveries, 1); // delivered exactly once
      expect(got, Uint8List.fromList(payload));
    });

    test('dedup: replaying a completed message does not re-deliver', () {
      final r = BleBroadcastReassembler();
      final payload = List<int>.generate(80, (i) => i);
      final entries = chunkify(1, 3, payload);
      var deliveries = 0;
      for (final e in [...entries, ...entries, ...entries]) {
        if (r.ingest('peerA', e) != null) deliveries++;
      }
      expect(deliveries, 1);
    });

    test('same msgId from different sources are independent', () {
      final r = BleBroadcastReassembler();
      final pa = List<int>.generate(60, (i) => i);
      final pb = List<int>.generate(90, (i) => 255 - (i % 256));
      final ea = chunkify(1, 1, pa);
      final eb = chunkify(2, 1, pb); // same msgId, different source
      Uint8List? gotA, gotB;
      for (final e in ea) gotA = r.ingest('peerA', e) ?? gotA;
      for (final e in eb) gotB = r.ingest('peerB', e) ?? gotB;
      expect(gotA, Uint8List.fromList(pa));
      expect(gotB, Uint8List.fromList(pb));
    });

    test('continuation arriving before its primary is tolerated', () {
      final r = BleBroadcastReassembler();
      final payload = List<int>.generate(50, (i) => i);
      final entries = chunkify(1, 2, payload);
      // entries = [primary0(hasCont), cont0]; deliver cont first (dropped), then primary, then cont.
      expect(r.ingest('peerA', entries[1]), isNull); // orphan cont
      Uint8List? got;
      for (final e in entries) {
        got = r.ingest('peerA', e) ?? got;
      }
      expect(got, Uint8List.fromList(payload));
    });

    test('ADV-only sender format (Flutter, no continuation) round-trips', () {
      // The Flutter sender emits primary-only chunks (flags=0) because neither
      // ble_peripheral nor BlueZ exposes scan-response data. Mirror that exact
      // split here and confirm the reassembler rebuilds the payload.
      final r = BleBroadcastReassembler();
      final payload = List<int>.generate(250, (i) => (i * 7) % 256);
      const cap = 20 - kBleBcastPrimaryHdr; // ble_peripheral budget
      final total = (payload.length + cap - 1) ~/ cap;
      Uint8List? got;
      for (var idx = 0; idx < total; idx++) {
        final off = idx * cap;
        final end = (off + cap < payload.length) ? off + cap : payload.length;
        got = r.ingest('peerA',
                primary(1, 99, idx, total, payload.sublist(off, end))) ??
            got;
      }
      expect(got, Uint8List.fromList(payload));
    });

    test('non-chunk data is ignored', () {
      final r = BleBroadcastReassembler();
      // a legacy compact APRS frame (no marker)
      expect(r.ingest('peerA', Uint8List.fromList('CT1ABC'.codeUnits)), isNull);
      // a presence beacon (0x3E + device id, not 0x50/0x51)
      expect(r.ingest('peerA', Uint8List.fromList([kBleMarker, 0x07, 0x41])), isNull);
    });
  });
}
