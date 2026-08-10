// The frame swap: we emit XPRS, we still read the compact frame.
//
// MeshFrame is the seam. Everything above it — custody admission, the store
// key, the courier's ingest — asks it for from/to/id/body and never learns
// which format arrived. These tests hold that seam to both halves, because the
// day the legacy half is deleted the XPRS half has to already be carrying
// everything.

import 'dart:convert';
import 'dart:typed_data';

import 'package:aurora/services/mesh/mesh_frame.dart';
import 'package:aurora/services/xprs/xprs_id.dart';
import 'package:aurora/services/xprs/xprs_packet.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

/// The compact frame the chat wapp and the dongle still emit.
Uint8List compact(String from, String to, String text) =>
    bytes('$from\x1F$to\x1F$text');

void main() {
  group('reading XPRS', () {
    const wire =
        't:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 m:meet at the bridge';

    test('from, to and body come off the packet', () {
      final f = MeshFrame.parse(bytes(wire))!;
      expect(f.isXprs, isTrue);
      expect(f.from, 'X1QZ3N');
      expect(f.to, 'X1RD89');
      expect(f.body, 'meet at the bridge');
    });

    test('the id is derived, not carried', () {
      final f = MeshFrame.parse(bytes(wire))!;
      expect(f.id, xprsIdentifier(XprsPacket.parse(wire)!));
      expect(f.id.length, 6, reason: 'the store column holds six hex');
      expect(wire.contains(f.id), isFalse,
          reason: 'nothing announces its own identifier (section 5)');
    });

    test('a sealed body is x:, and comes back sealed', () {
      final f = MeshFrame.parse(bytes(
          't:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 x:AAAABBBB'))!;
      expect(f.body, 'AAAABBBB');
      expect(f.packet!.has('x'), isTrue);
    });

    test('relaying does not change the id the store keys on', () {
      final a = MeshFrame.parse(bytes(wire))!;
      final b = MeshFrame.parse(bytes(
          't:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 via:X32DVA '
          'm:meet at the bridge'))!;
      expect(b.id, a.id,
          reason: 'a carried copy and the original are one message');
    });
  });

  group('still reading the compact frame', () {
    test('from, to and text come off the 0x1F fields', () {
      final f = MeshFrame.parse(compact('X1A33T', 'X1RD89', 'am:40c124 hi'))!;
      expect(f.isXprs, isFalse);
      expect(f.from, 'X1A33T');
      expect(f.to, 'X1RD89');
      expect(f.body, 'am:40c124 hi');
    });

    test('the id is the am: token the sender wrote', () {
      final f = MeshFrame.parse(compact('X1A33T', 'X1RD89', 'am:40c124 hi'))!;
      expect(f.id, '40c124');
    });

    test('a frame with no am: still parses, with no id', () {
      final f = MeshFrame.parse(compact('X1A33T', 'X1RD89', 'hello'))!;
      expect(f.id, isEmpty);
      expect(f.body, 'hello');
    });

    test('a control frame is readable so custody can act on it', () {
      final f = MeshFrame.parse(compact('X3RLY7', '', '?ACK 40c124 d'))!;
      expect(f.body, startsWith('?ACK '));
    });
  });

  group('telling them apart', () {
    test('the test is unambiguous and needs no version marker', () {
      // A compact frame always has two 0x1F bytes; an XPRS packet has none and
      // starts with `t:`. Nothing has to be negotiated.
      expect(MeshFrame.parse(bytes('t:message f:X1QZ3N m:x'))!.isXprs, isTrue);
      expect(MeshFrame.parse(compact('A', 'B', 'c'))!.isXprs, isFalse);
    });

    test('rubbish is refused rather than guessed at', () {
      expect(MeshFrame.parse(bytes('hello world')), isNull);
      expect(MeshFrame.parse(bytes('')), isNull);
      expect(MeshFrame.parse(bytes('\x1Fonly one separator')), isNull);
    });

    test('a compact frame whose text merely mentions t: is still compact', () {
      final f = MeshFrame.parse(compact('X1A33T', 'X1RD89', 't:message f:X'))!;
      expect(f.isXprs, isFalse);
      expect(f.from, 'X1A33T');
    });
  });
}
