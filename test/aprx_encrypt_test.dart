import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';

import 'package:aurora/util/aprx_sign.dart';
import 'package:aurora/util/nostr_crypto.dart';

BigInt _big(String hex) {
  var r = BigInt.zero;
  for (final b in HEX.decode(hex)) {
    r = (r << 8) | BigInt.from(b);
  }
  return r;
}

Uint8List _pub(String privHex) =>
    Uint8List.fromList(HEX.decode(NostrCrypto.derivePublicKey(privHex)));

void main() {
  const privA =
      'a1b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00';
  final privB = NostrCrypto.generateKeyPair().privateKeyHex;
  final dA = _big(privA), dB = _big(privB);
  final pubA = _pub(privA), pubB = _pub(privB);

  test('A->B encrypt/decrypt round-trip', () {
    for (final msg in ['hi', 'meet at the repeater 19:00 73!', 'x' * 200]) {
      final pt = Uint8List.fromList(utf8.encode(msg));
      final blob = AprxSign.encryptFor(dA, pubB, pt);
      expect(blob, isNotNull);
      // B decrypts with B's key + A's pubkey
      final dec = AprxSign.decryptFrom(dB, pubA, blob!);
      expect(dec, isNotNull);
      expect(utf8.decode(dec!), msg);
      // A can also decrypt its own (symmetric shared secret)
      final decSelf = AprxSign.decryptFrom(dA, pubB, blob);
      expect(utf8.decode(decSelf!), msg);
    }
  });

  test('wrong key fails (returns null or garbage, never the plaintext)', () {
    final blob = AprxSign.encryptFor(dA, pubB, Uint8List.fromList(utf8.encode('secret')))!;
    final wrong = _pub(NostrCrypto.generateKeyPair().privateKeyHex);
    final dec = AprxSign.decryptFrom(dB, wrong, blob); // wrong sender pub
    if (dec != null) {
      expect(utf8.decode(dec, allowMalformed: true), isNot('secret'));
    }
  });

  test('blob base64url-encodes compactly', () {
    final blob = AprxSign.encryptFor(dA, pubB, Uint8List.fromList(utf8.encode('hi')))!;
    final b64 = base64Url.encode(blob).replaceAll('=', '');
    // "hi" -> 16-byte block + 16-byte iv = 32 bytes -> 43 base64url chars
    expect(b64.length, lessThanOrEqualTo(48));
    expect(b64.contains(' '), isFalse);
  });
}
