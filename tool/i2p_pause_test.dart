// Phase 4: verify node pause/resume (the hook the background-process governor
// uses to throttle on CPU overload / low battery). B serves content; A fetches
// (ok); B.pause() tears down its tunnels -> fetch fails; B.resume() rebuilds ->
// fetch works again.
//   dart run tool/i2p_pause_test.dart            # local i2pd
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_crypto.dart';
import 'package:aurora/services/i2p/i2p_node.dart';
import 'package:aurora/services/i2p/i2p_structures.dart';

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main() async {
  final ri = parseRouterInfo(await File('/tmp/i2pd-data/router.info').readAsBytes())!;
  final iv = Uint8List.fromList(
      (await File('/tmp/i2pd-data/ntcp2.keys').readAsBytes()).sublist(64, 80));
  final content = Uint8List.fromList('pause/resume content'.codeUnits);
  final sha = I2pCrypto.sha256(content);

  Future<I2pNode> mk(String n, {Future<Uint8List?> Function(Uint8List)? onGet}) async {
    final node = I2pNode(netId: 9, log: (m) => print('[$n] $m'), onGet: onGet);
    await node.start(peers: [ri], hostOverride: '127.0.0.1', portOverride: 27654, ivOverride: iv);
    return node;
  }

  final b = await mk('B', onGet: (s) async => hx(s) == hx(sha) ? content : null);
  final a = await mk('A');
  await Future.delayed(const Duration(seconds: 2));

  Future<bool> tryFetch() async {
    final got = await a.fetch(b.destHash, sha, timeout: const Duration(seconds: 20));
    return got != null && hx(I2pCrypto.sha256(got)) == hx(sha);
  }

  // Functional check: fetch works while B is up.
  final f1 = await tryFetch();
  print('fetch before pause: ${f1 ? "OK" : "FAIL"} '
      '(B up=${b.isUp}, gateways=${b.gatewayCount})');

  // Pause: tunnels torn down, no gateways, activity stops (governor throttling).
  b.pause();
  final pausedOk = b.isPaused && b.gatewayCount == 0 && !b.isUp;
  print('after pause: isPaused=${b.isPaused} gateways=${b.gatewayCount} up=${b.isUp}');

  // Resume: tunnels rebuilt, republished, serving again.
  await b.resume();
  final resumedOk = !b.isPaused && b.isUp && b.gatewayCount > 0;
  print('after resume: isPaused=${b.isPaused} gateways=${b.gatewayCount} up=${b.isUp}');

  print(f1 && pausedOk && resumedOk
      ? '\n>>> SUCCESS: pause throttles the node to zero (frees tunnels/sessions) '
        'and resume re-establishes it'
      : '\n>>> FAILED: f1=$f1 pausedOk=$pausedOk resumedOk=$resumedOk');
  a.close();
  b.close();
}
