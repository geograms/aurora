// Desktop seeder for the desktop<->phone SWARM test on the REAL public network.
// Serves one fixed LARGE file (150 KB -> 5 pieces) by sha256 and stays up,
// announcing it and printing its b32 + sha256 so the phone can swarm-download it
// over I2P (multi-cell pieces, the path the IV-key fix unblocked).
//   dart run tool/i2p_serve_swarm.dart
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_crypto.dart';
import 'package:aurora/services/i2p/i2p_node.dart';

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main() async {
  I2pNode.rxDiag = true; // log every I2NP arriving on our gateways
  final content =
      Uint8List.fromList(List.generate(150000, (i) => (i * 2654435761 + 7) & 0xff));
  final sha = I2pCrypto.sha256(content);

  final node = I2pNode(
    netId: 2,
    log: (m) => print('[serve] $m'),
    onGet: (s) async => hx(s) == hx(sha) ? content : null,
  );
  if (!await node.start()) {
    print('SERVE_FAILED');
    return;
  }
  await node.announce(sha); // discoverable too (directed fetch doesn't need it)
  print('SERVE_B32=${node.b32}');
  print('SERVE_SHA256=${hx(sha)}');
  print('SERVE_LEN=${content.length}');
  print('serving 150KB (5 pieces); keeping node up...');
  for (var i = 0; i < 600; i++) {
    await Future.delayed(const Duration(seconds: 10));
  }
}
