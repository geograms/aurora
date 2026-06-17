// RNS Phase-0 interop gate (Dart side). Reads reference vectors emitted by
// tool/reticulum_vectors.py and asserts byte-equality against the Python `rns`
// reference, then writes Dart-produced artifacts for Python to verify (proving
// both directions).
//
//   python3 tool/reticulum_vectors.py gen > /tmp/rns_vectors.json
//   dart run tool/reticulum_vectors_test.dart /tmp/rns_vectors.json /tmp/rns_dart_out.json
//   python3 tool/reticulum_vectors.py verify /tmp/rns_dart_out.json
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/reticulum/rns_auto_interface.dart';
import 'package:aurora/services/reticulum/rns_crypto.dart';
import 'package:aurora/services/reticulum/rns_identity.dart';

var _pass = 0, _fail = 0;
void check(String name, bool ok, [String extra = '']) {
  if (ok) {
    _pass++;
    print('  ok   $name');
  } else {
    _fail++;
    print('  FAIL $name${extra.isNotEmpty ? "  ($extra)" : ""}');
  }
}

Uint8List unh(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

bool eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('usage: reticulum_vectors_test.dart <vectors.json> [dart_out.json]');
    exit(2);
  }
  final v = jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  print('RNS reference version: ${v["rns_version"]}');

  // 1. Identity from private key -> public key + hash match.
  final id = await RnsIdentity.fromPrivateKey(unh(v['identity_prv'] as String));
  check('identity public key', eq(id.getPublicKey(), unh(v['identity_pub'] as String)),
      hx(id.getPublicKey()));
  check('identity hash', eq(id.hash, unh(v['identity_hash'] as String)),
      hx(id.hash));

  // 2. Destination name_hash + addressable hash.
  final app = v['app_name'] as String;
  final aspects = (v['aspects'] as List).cast<String>();
  check('destination name_hash',
      eq(RnsDestination.nameHash(app, aspects), unh(v['name_hash'] as String)));
  check('destination hash',
      eq(RnsDestination.hash(id, app, aspects), unh(v['dest_hash'] as String)));

  // 3. Token deterministic encrypt (fixed key + iv) matches Python byte-for-byte.
  final tokenKey = unh(v['token_key'] as String);
  final tokenIv = unh(v['token_iv'] as String);
  final plaintext = unh(v['token_plaintext'] as String);
  final dartToken = RnsToken(tokenKey).encrypt(plaintext, iv: tokenIv);
  check('token encrypt (deterministic)',
      eq(dartToken, unh(v['token_ciphertext'] as String)), hx(dartToken));

  // 4. Token decrypt round-trips.
  check('token decrypt',
      eq(RnsToken(tokenKey).decrypt(unh(v['token_ciphertext'] as String)),
          plaintext));

  // 5. Dart decrypts a Python Identity.encrypt token (HKDF + ECDH + Token).
  try {
    final pt = await id.decrypt(unh(v['identity_token'] as String));
    check('decrypt python identity token', eq(pt, plaintext), hx(pt));
  } catch (e) {
    check('decrypt python identity token', false, '$e');
  }

  // 6. Validate a Python announce: parse, verify signature, recompute dest hash.
  await _checkAnnounce(v);

  // 7. AutoInterface discovery derivations (group address + peering token).
  final disco = RnsAutoDiscovery();
  check('auto group hash',
      eq(disco.groupHash, unh(v['auto_group_hash'] as String)));
  check('auto multicast address',
      disco.multicastAddress() == v['auto_mcast_addr'] as String,
      disco.multicastAddress());
  check(
      'auto peering token',
      eq(disco.peeringToken(v['auto_sample_lla'] as String),
          unh(v['auto_peering_token'] as String)));

  // Emit Dart artifacts for Python to verify the reverse direction.
  if (args.length >= 2) {
    final signedMessage =
        Uint8List.fromList(utf8.encode('dart-signs-this-for-rns'));
    final out = {
      'ref_identity_prv': v['identity_prv'],
      'dart_identity_token': hx(await id.encrypt(plaintext)),
      'expect_plaintext': v['token_plaintext'],
      'dart_signer_pub': hx(id.getPublicKey()),
      'signed_message': hx(signedMessage),
      'dart_signature': hx(await id.sign(signedMessage)),
    };
    File(args[1]).writeAsStringSync(jsonEncode(out));
    print('wrote dart artifacts -> ${args[1]}');
  }

  print('\n$_pass passed, $_fail failed');
  if (_fail == 0) {
    print('>>> SUCCESS: RNS crypto/identity is wire-compatible with Python.');
  } else {
    print('>>> FAILED');
  }
  exit(_fail == 0 ? 0 : 1);
}

Future<void> _checkAnnounce(Map<String, dynamic> v) async {
  final data = unh(v['announce_data'] as String);
  final destHash = unh(v['announce_dest_hash'] as String);
  final contextFlag = v['announce_context_flag'] as int;

  const keysize = 64, nameHashLen = 10, randomHashLen = 10, sigLen = 64;
  const ratchetSize = 32;
  final pub = Uint8List.sublistView(data, 0, keysize);
  final nameHash = Uint8List.sublistView(data, keysize, keysize + nameHashLen);
  final randomHash = Uint8List.sublistView(
      data, keysize + nameHashLen, keysize + nameHashLen + randomHashLen);
  var off = keysize + nameHashLen + randomHashLen;
  Uint8List ratchet = Uint8List(0);
  if (contextFlag == 1) {
    ratchet = Uint8List.sublistView(data, off, off + ratchetSize);
    off += ratchetSize;
  }
  final signature = Uint8List.sublistView(data, off, off + sigLen);
  off += sigLen;
  final appData = Uint8List.sublistView(data, off);

  // signed_data = dest_hash + public_key + name_hash + random_hash + ratchet + app_data
  final signedData = BytesBuilder()
    ..add(destHash)
    ..add(pub)
    ..add(nameHash)
    ..add(randomHash)
    ..add(ratchet)
    ..add(appData);

  final announced = RnsIdentity.fromPublicKey(pub);
  final sigOk = await announced.validate(signature, signedData.toBytes());
  check('announce signature valid', sigOk);

  // dest_hash == truncated_hash(name_hash + identity.hash)
  final expected =
      RnsCrypto.truncatedHash([...nameHash, ...announced.hash]);
  check('announce dest hash recompute', eq(expected, destHash), hx(expected));
}
