import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';
import 'package:crypto/crypto.dart';

import 'package:aurora/util/aprx_sign.dart';
import 'package:aurora/util/nostr_crypto.dart';

Uint8List _digest(String s) =>
    Uint8List.fromList(sha256.convert(utf8.encode(s)).bytes);

BigInt _big(String hex) {
  var r = BigInt.zero;
  for (final b in HEX.decode(hex)) {
    r = (r << 8) | BigInt.from(b);
  }
  return r;
}

void main() {
  test('base85 alphabet is exactly 85 distinct chars', () {
    // ignore: invalid_use_of_visible_for_testing_member
    final data = Uint8List.fromList(List.generate(48, (i) => (i * 37) & 0xff));
    final enc = AprxSign.b85encode(data);
    expect(enc.length, 60); // 48 bytes -> 60 chars
    final dec = AprxSign.b85decode(enc);
    expect(dec, isNotNull);
    expect(dec, equals(data));
    // no APRS-reserved chars
    expect(enc.contains('{'), isFalse);
    expect(enc.contains('|'), isFalse);
    expect(enc.contains('~'), isFalse);
    expect(enc.contains(' '), isFalse);
  });

  test('sign/verify round-trip', () {
    // A fixed test key (nsec from the dev profile is fine; any valid key works).
    const nsec =
        'nsec18m4wzr72429dma6qxwku58me32ur59ve07fzzsw2danm3xyahrssrka3cf';
    final privHex = NostrCrypto.decodeNsec(nsec);
    final d = _big(privHex);
    final pubHex = NostrCrypto.derivePublicKey(privHex); // x-only 32 bytes
    final pub = Uint8List.fromList(HEX.decode(pubHex));

    final m = _digest('X10EGL|#TEST|hello world');
    final sig = AprxSign.sign(m, d);
    expect(sig.length, 48);
    expect(AprxSign.verify(m, sig, pub), isTrue);

    // wrong message → fail
    final m2 = _digest('X10EGL|#TEST|hello world!');
    expect(AprxSign.verify(m2, sig, pub), isFalse);

    // tampered signature → fail
    final bad = Uint8List.fromList(sig);
    bad[20] ^= 0x01;
    expect(AprxSign.verify(m, bad, pub), isFalse);

    // wrong key → fail
    final otherPriv = NostrCrypto.generateKeyPair().privateKeyHex;
    final otherPub =
        Uint8List.fromList(HEX.decode(NostrCrypto.derivePublicKey(otherPriv)));
    expect(AprxSign.verify(m, sig, otherPub), isFalse);
  });

  test('encoded signature fits one APRS line', () {
    const nsec =
        'nsec18m4wzr72429dma6qxwku58me32ur59ve07fzzsw2danm3xyahrssrka3cf';
    final d = _big(NostrCrypto.decodeNsec(nsec));
    final sig = AprxSign.sign(_digest('a|b|c'), d);
    final enc = AprxSign.b85encode(sig);
    expect(enc.length, 60);
    expect(enc.length <= 67, isTrue);
  });
}
