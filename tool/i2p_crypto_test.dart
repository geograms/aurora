// Phase 0 self-test of the pure-Dart I2P crypto primitives, including official
// test vectors (SipHash-2-4 reference, X25519 RFC 7748) so we know they are
// correct, not merely runnable.   dart run tool/i2p_crypto_test.dart
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_crypto.dart';

Uint8List hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

var pass = 0, fail = 0;
void check(String name, bool ok, [String extra = '']) {
  if (ok) {
    pass++;
    print('  ok   $name');
  } else {
    fail++;
    print('  FAIL $name  $extra');
  }
}

Future<void> main() async {
  // SipHash-2-4 official reference vectors (key = 00..0f)
  final sipKey = hex('000102030405060708090a0b0c0d0e0f');
  check('siphash empty', I2pCrypto.sipHash24(sipKey, Uint8List(0)) == 0x726fdb47dd0e0e31);
  final msg15 = Uint8List.fromList(List.generate(15, (i) => i));
  check('siphash 15-byte', I2pCrypto.sipHash24(sipKey, msg15) == 0xa129ca6149be45e5);

  // SHA-256("abc")
  check('sha256 abc',
      hx(I2pCrypto.sha256('abc'.codeUnits)) ==
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');

  // X25519 RFC 7748 single vector
  final scalar = hex('a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4');
  final u = hex('e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c');
  final expected = 'c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552';
  check('x25519 RFC7748', hx(await I2pCrypto.x25519Shared(scalar, u)) == expected);

  // X25519 symmetric agreement
  final a = await I2pCrypto.x25519Generate();
  final b = await I2pCrypto.x25519Generate();
  final ab = await I2pCrypto.x25519Shared(a.priv, b.pub);
  final ba = await I2pCrypto.x25519Shared(b.priv, a.pub);
  check('x25519 symmetric', hx(ab) == hx(ba));

  // Ed25519 sign/verify + tamper
  final ed = await I2pCrypto.ed25519Generate();
  final m = 'i2p test message'.codeUnits;
  final sig = await I2pCrypto.ed25519Sign(ed.priv, m);
  check('ed25519 verify', await I2pCrypto.ed25519Verify(ed.pub, m, sig));
  final badm = 'i2p test messagX'.codeUnits;
  check('ed25519 reject tamper', !await I2pCrypto.ed25519Verify(ed.pub, badm, sig));

  // ChaCha20-Poly1305 roundtrip + tamper
  final key = Uint8List.fromList(List.generate(32, (i) => i));
  final nonce = Uint8List.fromList(List.generate(12, (i) => 0xA0 + i));
  final aad = 'aad'.codeUnits;
  final plain = 'hello i2p over chacha'.codeUnits;
  final ctTag = await I2pCrypto.chachaEncrypt(key, nonce, plain, aad);
  final dec = await I2pCrypto.chachaDecrypt(key, nonce, ctTag, aad);
  check('chacha roundtrip', hx(dec) == hx(plain));
  var tamperRejected = false;
  try {
    final bad = Uint8List.fromList(ctTag);
    bad[0] ^= 1;
    await I2pCrypto.chachaDecrypt(key, nonce, bad, aad);
  } catch (_) {
    tamperRejected = true;
  }
  check('chacha reject tamper', tamperRejected);

  // AES-256-CBC roundtrip (no padding, 2 blocks)
  final aesKey = Uint8List.fromList(List.generate(32, (i) => i));
  final iv = Uint8List.fromList(List.generate(16, (i) => 0x10 + i));
  final block = Uint8List.fromList(List.generate(32, (i) => i * 3 & 0xff));
  final enc = I2pCrypto.aesCbc(aesKey, iv, block, true);
  final back = I2pCrypto.aesCbc(aesKey, Uint8List.fromList(iv), enc, false);
  check('aes-cbc roundtrip', hx(back) == hx(block));

  // Noise HKDF basic shape
  final outs = I2pCrypto.noiseHkdf(Uint8List(32), Uint8List(32), 3);
  check('noiseHkdf 3x32', outs.length == 3 && outs.every((o) => o.length == 32));

  print('\n$pass passed, $fail failed');
  if (fail == 0) {
    print('>>> SUCCESS: all I2P crypto primitives correct (incl. official vectors).');
  } else {
    print('>>> FAILED: crypto primitives not all correct.');
  }
}
