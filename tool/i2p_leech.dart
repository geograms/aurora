// Desktop LEECHER for the reverse-direction device test: swarm-fetch a file from
// a given b32 destination + sha256 over the live network. Pair with a phone that
// PUT the content (POST /api/i2p/put) so the phone is the seeder. This isolates
// whether the phone's I2P problem is sending or receiving:
//   - desktop leecher receives the file  => phone send+receive both work
//   - desktop's request reaches the phone (phone logs GETMANIFEST) but no reply
//     arrives => phone SEND is the broken direction
//   - phone never logs any rx               => phone RECEIVE is broken
//
//   dart run tool/i2p_leech.dart <b32> <sha256hex>
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_crypto.dart';
import 'package:aurora/services/i2p/i2p_node.dart';

String hx(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List unhex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)
    ]);

// b32 ("<52 base32 chars>.b32.i2p") -> 32-byte dest hash (inlined to avoid
// importing I2pService, which transitively pulls in Flutter UI code).
Uint8List? decodeB32(String addr) {
  var s = addr.trim().toLowerCase();
  if (s.endsWith('.b32.i2p')) s = s.substring(0, s.length - 8);
  const alpha = 'abcdefghijklmnopqrstuvwxyz234567';
  var buffer = 0, bits = 0;
  final out = <int>[];
  for (final ch in s.codeUnits) {
    final v = alpha.indexOf(String.fromCharCode(ch));
    if (v < 0) return null;
    buffer = (buffer << 5) | v;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xff);
    }
  }
  if (out.length < 32) return null;
  return Uint8List.fromList(out.sublist(0, 32));
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/i2p_leech.dart <b32> <sha256hex>');
    return;
  }
  I2pNode.rxDiag = true;
  final dest = decodeB32(args[0]);
  if (dest == null) {
    print('>>> FAILED: bad b32 ${args[0]}');
    return;
  }
  final sha = unhex(args[1].trim());

  final leech = I2pNode(netId: 2, log: (m) => print('[L] $m'));
  print('starting leecher...');
  if (!await leech.start()) {
    print('>>> FAILED: leecher did not start');
    return;
  }
  await Future.delayed(const Duration(seconds: 4));
  print('L=${leech.b32}\nseed=${hx(dest).substring(0, 12)}..  sha=${hx(sha).substring(0, 12)}..');

  final got = await leech.swarmFetch(sha,
      seedProviders: [dest],
      perPiece: const Duration(seconds: 25),
      budget: const Duration(minutes: 5));

  if (got != null && hx(I2pCrypto.sha256(got)) == hx(sha)) {
    print('\n>>> SUCCESS: ${got.length} bytes swarm-downloaded from the phone over '
        'the LIVE network, sha256 verified');
  } else {
    print('\n>>> FAILED: got ${got?.length} bytes');
  }
  leech.close();
}
