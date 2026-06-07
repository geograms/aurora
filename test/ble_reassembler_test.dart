import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:aurora/connections/bluetooth/ble_reassembler.dart';

Uint8List b(List<int> x) => Uint8List.fromList(x);

// A compact APRS payload "<from>\x1f<to>\x1f<text>" as the manufacturer data
// the package hands us (company id already stripped). No 0x3E marker.
Uint8List compact(String from, String to, String text) =>
    b([...from.codeUnits, 0x1f, ...to.codeUnits, 0x1f, ...text.codeUnits]);

// A continuation entry: [0x3E, 0x42, overflow bytes].
Uint8List cont(List<int> overflow) => b([kBleMarker, kBleContSubtype, ...overflow]);

void main() {
  group('BleReassembler', () {
    test('lone short frame is held, then delivered on expire', () {
      // A primary with no marker could be a complete short frame OR the head of
      // a long one, so it is held until the continuation arrives or the hold
      // window elapses (the caller's timer calls expire).
      final r = BleReassembler();
      final f = compact('CT1ABC', 'X3WWAJ', 'hi');
      expect(r.ingest('peer', [f]), isEmpty);
      expect(r.held('peer'), isTrue);
      expect(r.expire('peer'), f);
    });

    test('long frame reassembles when both parts arrive in one event', () {
      final r = BleReassembler();
      final head = b([...'CT1ABC'.codeUnits, 0x1f]); // primary (truncated head)
      final tail = b([...'X3WWAJ'.codeUnits, 0x1f, ...'long message'.codeUnits]);
      final out = r.ingest('peer', [head, cont(tail)]);
      expect(out.length, 1);
      expect(out.first, b([...head, ...tail]));
      expect(r.held('peer'), isFalse);
    });

    test('long frame reassembles across two separate events', () {
      final r = BleReassembler();
      final head = b([...'CT1ABC'.codeUnits, 0x1f, ...'X3'.codeUnits]);
      final tail = b('WWAJ'.codeUnits + [0x1f] + 'over ble'.codeUnits);
      // Event 1: only the primary (BlueZ-style separate delivery) -> held.
      expect(r.ingest('peer', [head]), isEmpty);
      expect(r.held('peer'), isTrue);
      // Event 2: the continuation -> full frame, nothing held.
      final out = r.ingest('peer', [cont(tail)]);
      expect(out.length, 1);
      expect(out.first, b([...head, ...tail]));
      expect(r.held('peer'), isFalse);
    });

    test('held primary with no continuation is delivered on expire', () {
      final r = BleReassembler();
      final f = compact('CT1ABC', '', 'short');
      expect(r.ingest('peer', [f]), isEmpty);
      expect(r.held('peer'), isTrue);
      expect(r.expire('peer'), f);
      expect(r.held('peer'), isFalse);
      expect(r.expire('peer'), isNull);
    });

    test('orphan continuation is dropped', () {
      final r = BleReassembler();
      expect(r.ingest('peer', [cont('xyz'.codeUnits)]), isEmpty);
      expect(r.held('peer'), isFalse);
    });

    test('a new primary flushes the previously held one', () {
      final r = BleReassembler();
      final a = compact('AA1AAA', '', 'first');
      final c = compact('BB2BBB', '', 'second');
      expect(r.ingest('peer', [a]), isEmpty); // a held
      final out = r.ingest('peer', [c]); // a flushed as short, c now held
      expect(out, [a]);
      expect(r.held('peer'), isTrue);
      expect(r.expire('peer'), c);
    });

    test('presence-style marked frame passes through, not treated as primary', () {
      final r = BleReassembler();
      // Presence beacon: 0x3E marker, then device id + callsign (not subtype B).
      final presence = b([kBleMarker, 0x07, ...'X3WWAJ'.codeUnits]);
      final out = r.ingest('peer', [presence]);
      expect(out, [presence]);
      expect(r.held('peer'), isFalse);
    });

    test('held primaries are tracked per peer independently', () {
      final r = BleReassembler();
      final pa = b([...'AA1AAA'.codeUnits, 0x1f, ...'p'.codeUnits]);
      final pb = b([...'BB2BBB'.codeUnits, 0x1f, ...'q'.codeUnits]);
      r.ingest('peerA', [pa]);
      r.ingest('peerB', [pb]);
      expect(r.held('peerA'), isTrue);
      expect(r.held('peerB'), isTrue);
      final outA = r.ingest('peerA', [cont('xx'.codeUnits)]);
      expect(outA.first, b([...pa, ...'xx'.codeUnits]));
      expect(r.held('peerB'), isTrue); // peerB untouched
    });
  });
}
