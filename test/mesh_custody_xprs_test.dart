// Custody delivery must read the format the device actually airs.
//
// The carrier side of the mesh (parking a frame, deciding who it is for) was
// taught XPRS; the RECEIVING side of a custody handover was not, and still
// split the compact `from\x1Fto\x1Ftext` frame only. So a carried XPRS
// message — which is what MeshCourier and the chat wapp now hand over —
// was answered "malformed" at the last hop and thrown away by both ends: the
// carrier archived its copy as delivered, the recipient never saw it.
//
// The property here is narrow and worth keeping: whatever a station can PARK,
// it can also RECEIVE.

import 'dart:convert';
import 'dart:typed_data';

import 'package:aurora/services/mesh/mesh_frame.dart';
import 'package:aurora/services/mesh/mesh_session.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List wire(String s) => Uint8List.fromList(utf8.encode(s));

const xprsForUs =
    't:message f:X1RD89 d:X1A67X ts:2026-08-08_14:26:40 m:meet at the bridge';
const xprsForOther =
    't:message f:X1RD89 d:X32DVA ts:2026-08-08_14:26:40 m:not yours';
const compactForUs = 'X1RD89\x1FX1A67X\x1Fmeet at the bridge';

void main() {
  group('what a custody handover can read', () {
    test('an XPRS frame yields the addressing custody routes on', () {
      final f = MeshFrame.parse(wire(xprsForUs));
      expect(f, isNotNull, reason: 'this is what the courier hands over');
      expect(f!.from, 'X1RD89');
      expect(f.to, 'X1A67X');
      expect(f.isXprs, isTrue);
      expect(f.id.length, 6, reason: 'the store keys on six hex either way');
    });

    test('the compact frame still reads, unchanged', () {
      final f = MeshFrame.parse(wire(compactForUs));
      expect(f, isNotNull);
      expect(f!.from, 'X1RD89');
      expect(f.to, 'X1A67X');
      expect(f.isXprs, isFalse);
    });

    test('a frame for somebody else is still addressed to somebody else', () {
      // The branch that decides deliver-to-us vs take-custody reads `to`; it
      // has to keep telling them apart across formats.
      expect(MeshFrame.parse(wire(xprsForOther))!.to, 'X32DVA');
    });

    test('junk is refused rather than delivered as an empty message', () {
      expect(MeshFrame.parse(wire('not a frame at all')), isNull);
      expect(MeshFrame.parse(Uint8List(0)), isNull);
    });

    test('an MSP message carries the frame through unchanged', () {
      // The bytes the carrier moves are the bytes the recipient parses: a
      // round-trip through the wire encoding must not disturb them.
      final m = MspMsg(seq: 3, am: 'abc123', ts: 1786199200, wire: wire(xprsForUs));
      final f = MeshFrame.parse(m.wire);
      expect(f!.to, 'X1A67X');
      expect(utf8.decode(m.wire), xprsForUs);
    });
  });
}
