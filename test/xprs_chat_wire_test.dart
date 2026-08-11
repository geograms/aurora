// What the chat wapp now airs, read by the host's parser.
//
// Chat builds its packets in C (`wapps/chat/xprs.c`); this file reads those
// exact strings with the Dart implementation. Two independent implementations
// agreeing on the same bytes is the only thing that makes "chat speaks XPRS"
// mean anything — a wapp that agreed only with itself would keep working while
// every other station on the device saw nothing.

import 'package:aurora/services/xprs/xprs_id.dart';
import 'package:aurora/services/xprs/xprs_packet.dart';
import 'package:aurora/services/xprs/xprs_vocab.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verbatim output of `xprs_pack`, one per thing chat routes on. Kept as
/// literals so a change to the C side that alters the wire fails here.
const direct =
    't:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 m:meet at the bridge at six';
const groupMsg =
    't:message f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 m:net starts in ten minutes';
const broadcast =
    't:message f:X1QZ3N ts:2026-08-08_14:26:40 m:anyone near the north gate?';
const position =
    't:observation f:X1QZ3N ts:2026-08-08_14:26:40 pos:38.7223,-9.1393 m:at the ferry';
const encrypted =
    't:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 m:+9eb5 ENC1:aGVsbG8= ~sig';

void main() {
  group('every frame chat airs is a packet the host reads', () {
    for (final wire in [direct, groupMsg, broadcast, position, encrypted]) {
      test('parses: ${wire.substring(0, 22)}…', () {
        final p = XprsPacket.parse(wire);
        expect(p, isNotNull);
        expect(p!.encode(), wire, reason: 'round-trips to the byte');
        expect(p.fits, isTrue, reason: '${p.byteLength} bytes');
        expect(p.fields.first.key, 't', reason: 'type is first (section 4)');
        expect(p['f'], 'X1QZ3N');
      });
    }

    test('a direct message is addressed to a station', () {
      final p = XprsPacket.parse(direct)!;
      expect(p.type, 'message');
      expect(p['d'], 'X1RD89');
    });

    test('a group keeps no # — that is chat\'s own marker, not XPRS', () {
      expect(XprsPacket.parse(groupMsg)!['d'], 'LISBOA');
      expect(groupMsg.contains('#'), isFalse);
    });

    test('a broadcast simply has no d:', () {
      expect(XprsPacket.parse(broadcast)!.has('d'), isFalse);
    });

    test('a position is an observation carrying pos:', () {
      final p = XprsPacket.parse(position)!;
      expect(p.type, 'observation');
      expect(p['pos'], '38.7223,-9.1393');
      expect(p['m'], 'at the ferry');
    });

    test("chat's own body conventions survive inside m:", () {
      // The reply marker, the ciphertext and the signature all contain
      // characters that would break a field — which is exactly why they ride
      // in m:, greedy and last.
      expect(XprsPacket.parse(encrypted)!['m'], '+9eb5 ENC1:aGVsbG8= ~sig');
    });

    test('each one has a distinct identifier', () {
      final ids = {
        for (final w in [direct, groupMsg, broadcast, position, encrypted])
          xprsIdentifier(XprsPacket.parse(w)!),
      };
      expect(ids.length, 5);
      for (final id in ids) {
        expect(id.length, 6);
      }
    });

    test('a relay may carry them, and a hop does not change what was signed',
        () {
      final p = XprsPacket.parse(direct)!;
      final relayed = xprsAppendVia(p, 'X3RLY7');
      expect(xprsIdentifier(relayed), xprsIdentifier(p),
          reason: 'via: is excluded from the identifier (section 5)');
      expect(xprsMayRelay(relayed), isTrue);
    });
  });

  group('what chat still sends the old way is not mistaken for XPRS', () {
    test('a compact frame does not parse', () {
      expect(XprsPacket.parse('X16JK8\x1fCT1ABC\x1fhello'), isNull);
    });
  });
}
