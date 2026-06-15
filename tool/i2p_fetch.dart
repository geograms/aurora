// Phase 3 device test (desktop side): fetch a file by sha256 from a b32
// destination over the live I2P network, verify the hash. Pair with a serving
// node (e.g. the phone).
//   dart run tool/i2p_fetch.dart <b32> <sha256hex>
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_crypto.dart';
import 'package:aurora/services/i2p/i2p_node.dart';

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _hexBytes(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/i2p_fetch.dart <b32> <sha256hex>');
    return;
  }
  final b32 = args[0];
  final sha = _hexBytes(args[1]);
  final destHash = i2pBase32Decode(b32);
  if (destHash == null) {
    print('bad b32');
    return;
  }

  final node = I2pNode(netId: 2, log: (m) => print('[fetch] $m'));
  if (!await node.start()) {
    print('>>> FAILED: node did not start');
    return;
  }
  print('fetching ${args[1].substring(0, 12)}.. from $b32 ...');
  final bytes = await node.fetch(destHash, sha, timeout: const Duration(seconds: 60));
  if (bytes != null && hx(I2pCrypto.sha256(bytes)) == hx(sha)) {
    print('\n>>> SUCCESS: fetched ${bytes.length} bytes over the LIVE I2P network, '
        'sha256 verified');
    print('content: ${String.fromCharCodes(bytes)}');
  } else {
    print('\n>>> FAILED: got ${bytes?.length} bytes');
  }
  node.close();
}
