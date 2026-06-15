// Phase 1 self-test: validate the Noise_N init constant and the ECIES short
// tunnel build record crypto by round-tripping (creator encrypts, hop decrypts)
// and checking both sides derive identical reply/layer/IV keys.
//   dart run tool/i2p_tunnel_crypto_test.dart
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_crypto.dart';
import 'package:aurora/services/i2p/i2p_tunnel_build.dart';

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
  // Noise_N hh constant: SHA256("Noise_N_25519_ChaChaPoly_SHA256\0")
  final ck = Uint8List(32);
  ck.setRange(0, noiseNName.length, noiseNName.codeUnits);
  final hh = I2pCrypto.sha256(ck);
  check(
      'noise_N hh constant',
      hx(hh) ==
          '694d52445a27d9adfad29c7632395dc1e4354c69b4f92eac8a1ee46a9ed21554',
      hx(hh));

  // Round-trip a record between creator and hop.
  final hopStatic = await I2pCrypto.x25519Generate();
  final hopIdentHash = I2pCrypto.sha256('fake-router-identity'.codeUnits);
  final plain = Uint8List.fromList(
      List.generate(shortRecordClearTextSize, (i) => (i * 7) & 0xff));

  final (record, ck1) = await buildShortRecord(
    hopIdentHash: hopIdentHash,
    hopStaticKey: hopStatic.pub,
    plaintext: plain,
  );
  check('record size 218', record.length == shortRecordSize);
  check('record trunc hash', hx(record.sublist(0, 16)) == hx(hopIdentHash.sublist(0, 16)));

  final (recovered, ck2) = await openShortRecord(
    record: record,
    hopStaticPriv: hopStatic.priv,
    hopStaticPub: hopStatic.pub,
  );
  check('plaintext roundtrip', hx(recovered) == hx(plain));
  check('replyKey agree', hx(ck1.replyKey) == hx(ck2.replyKey));
  check('layerKey agree', hx(ck1.layerKey) == hx(ck2.layerKey));
  check('ivKey agree', hx(ck1.ivKey) == hx(ck2.ivKey));
  check('reply-AD h agree', hx(ck1.h) == hx(ck2.h));

  print('\n$pass passed, $fail failed');
  print(fail == 0
      ? '>>> SUCCESS: ECIES short build record crypto correct.'
      : '>>> FAILED.');
}
