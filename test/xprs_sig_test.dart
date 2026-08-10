// Signing, and the one property the whole relaying design rests on: a relay
// appends itself to `via:` and the signature still verifies.
//
// `docs/XPRS.md` section 13 states that "relaying alters neither the identifier
// nor a signature". Section 9.1 originally said `sig:` covered the whole packet,
// which made that false — every relayed packet would have read as forged. The
// rule now excludes `via:` as well, and the third test here is what holds it
// to that.

import 'dart:typed_data';

import 'package:aurora/services/xprs/xprs_id.dart';
import 'package:aurora/services/xprs/xprs_packet.dart';
import 'package:aurora/services/xprs/xprs_sig.dart';
import 'package:aurora/services/xprs/xprs_vocab.dart';
import 'package:aurora/util/nostr_crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';

BigInt _scalar(String privHex) {
  var d = BigInt.zero;
  for (final b in HEX.decode(privHex)) {
    d = (d << 8) | BigInt.from(b);
  }
  return d;
}

void main() {
  final kp = NostrCrypto.generateKeyPair();
  final d = _scalar(kp.privateKeyHex);
  final pub = Uint8List.fromList(HEX.decode(kp.publicKeyHex));

  XprsPacket p(String w) => XprsPacket.parse(w)!;

  group('signing', () {
    test('a signed packet verifies against the signer key', () {
      final signed = xprsSign(p('t:message f:X1QZ3N d:LISBOA m:hello'), d);
      expect(signed['sig'], isNotNull);
      expect(signed['sig']!.length, 60,
          reason: 'the base85 value type is 60 characters');
      expect(xprsVerify(signed, pub), XprsSigState.verified);
    });

    test('sig: lands before m:, so the message stays last', () {
      final signed = xprsSign(p('t:message f:X1QZ3N m:hello there'), d);
      expect(signed.fields.last.key, 'm');
      expect(signed['m'], 'hello there');
      // and the packet still round-trips through the parser
      expect(XprsPacket.parse(signed.encode())!.encode(), signed.encode());
    });

    test('a relay appending via: does not break the signature', () {
      final signed = xprsSign(p('t:message f:X1QZ3N d:X1RD89 m:meet at six'), d);
      var hop = xprsAppendVia(signed, 'X32DVA');
      hop = xprsAppendVia(hop, 'CT1ABC-9');
      hop = xprsAppendVia(hop, 'X3RLY7');

      expect(hop['via'], 'X32DVA,CT1ABC-9,X3RLY7');
      expect(xprsVerify(hop, pub), XprsSigState.verified,
          reason: 'section 13: relaying alters neither identifier nor signature');
      expect(xprsIdentifier(hop), xprsIdentifier(signed));
    });

    test('changing anything else does break it', () {
      final signed = xprsSign(p('t:message f:X1QZ3N d:X1RD89 m:meet at six'), d);
      final tampered = XprsPacket.parse(
          signed.encode().replaceFirst('meet at six', 'meet at ten'))!;
      expect(xprsVerify(tampered, pub), XprsSigState.forged);
    });

    test('another key does not verify it', () {
      final other = NostrCrypto.generateKeyPair();
      final signed = xprsSign(p('t:message f:X1QZ3N m:hello'), d);
      expect(
          xprsVerify(
              signed, Uint8List.fromList(HEX.decode(other.publicKeyHex))),
          XprsSigState.forged);
    });
  });

  group('the four states of section 9.1', () {
    test('unsigned when there is no signature', () {
      expect(xprsVerify(p('t:message f:X1QZ3N m:hi'), pub),
          XprsSigState.unsigned);
    });

    test('unverified when the signer key is not held', () {
      final signed = xprsSign(p('t:message f:X1QZ3N m:hi'), d);
      expect(xprsVerify(signed, null), XprsSigState.unverified);
    });

    test('forged when the signature is not even well formed', () {
      final bad = p('t:message f:X1QZ3N m:hi').with_('sig', 'nonsense');
      expect(xprsVerify(bad, pub), XprsSigState.forged);
    });
  });

  test('the signed text is the packet without sig: and via:', () {
    // Stated explicitly because this is the contract a second implementation
    // has to match, and it cannot be inferred from a passing round-trip.
    final signed = xprsSign(p('t:message f:X1QZ3N d:LISBOA m:hi'), d);
    final hop = xprsAppendVia(signed, 'X32DVA');
    expect(xprsSignedText(hop), 't:message f:X1QZ3N d:LISBOA m:hi');
  });
}
