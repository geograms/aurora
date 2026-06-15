// Phase 3 device test: run a standalone serving I2pNode on the desktop (real
// public network). It serves one fixed file by sha256 and stays up, printing
// its b32 address and the file's sha256 so the phone can fetch it over I2P.
//   dart run tool/i2p_serve.dart
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_crypto.dart';
import 'package:aurora/services/i2p/i2p_node.dart';

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main() async {
  final content = Uint8List.fromList(
      'AURORA I2P desktop->phone device test: this file crossed two networks '
      'over a pure-Dart I2P node with no native binaries and no router config.'
          .codeUnits);
  final sha = I2pCrypto.sha256(content);

  final node = I2pNode(
    netId: 2,
    log: (m) => print('[serve] $m'),
    onGet: (s) async => hx(s) == hx(sha) ? content : null,
  );
  final ok = await node.start();
  if (!ok) {
    print('SERVE_FAILED');
    return;
  }
  print('SERVE_B32=${node.b32}');
  print('SERVE_SHA256=${hx(sha)}');
  print('SERVE_LEN=${content.length}');
  print('serving; keeping node up...');
  // Re-publish periodically and stay alive.
  for (var i = 0; i < 360; i++) {
    await Future.delayed(const Duration(seconds: 10));
  }
}
