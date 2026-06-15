// Phase 3: exercise the top-level I2pNode API. Two nodes start (tunnel +
// LeaseSet), then one fetches content by sha256 from the other through the node
// abstraction. Defaults to the local i2pd (netid 9); pass "real" to run against
// the live public network (netid 2, reseed).
//   dart run tool/i2p_node_test.dart            # local i2pd
//   dart run tool/i2p_node_test.dart real       # live network
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_crypto.dart';
import 'package:aurora/services/i2p/i2p_node.dart';
import 'package:aurora/services/i2p/i2p_structures.dart';

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main(List<String> args) async {
  final real = args.contains('real');
  final content = Uint8List.fromList(
      'aurora i2p phase 3: content fetched device-to-device over a pure-Dart node'
          .codeUnits);
  final contentHash = I2pCrypto.sha256(content);

  Future<I2pNode> mk(String name, {Future<Uint8List?> Function(Uint8List)? onGet}) async {
    if (real) {
      final n = I2pNode(netId: 2, log: (m) => print('[$name] $m'), onGet: onGet);
      final ok = await n.start();
      if (!ok) throw 'node $name failed to start on live network';
      return n;
    } else {
      const path = '/tmp/i2pd-data/router.info';
      final ri = parseRouterInfo(await File(path).readAsBytes())!;
      final iv = Uint8List.fromList(
          (await File('/tmp/i2pd-data/ntcp2.keys').readAsBytes()).sublist(64, 80));
      final n = I2pNode(netId: 9, log: (m) => print('[$name] $m'), onGet: onGet);
      final ok = await n.start(
          peers: [ri], hostOverride: '127.0.0.1', portOverride: 27654, ivOverride: iv);
      if (!ok) throw 'node $name failed to start';
      return n;
    }
  }

  final b = await mk('B', onGet: (sha) async =>
      hx(sha) == hx(contentHash) ? content : null);
  final a = await mk('A');
  print('B dest b32 = ${b.b32}');
  await Future.delayed(const Duration(seconds: 3)); // settle leasesets

  print('A fetching ${hx(contentHash).substring(0, 12)}.. from B ...');
  final got = await a.fetch(b.destHash, contentHash,
      timeout: Duration(seconds: real ? 60 : 25));
  if (got != null && hx(I2pCrypto.sha256(got)) == hx(contentHash)) {
    print('\n>>> SUCCESS: fetched ${got.length} bytes, sha256 verified, via I2pNode'
        '${real ? " on the LIVE I2P network" : ""}');
  } else {
    print('\n>>> FAILED: fetch returned ${got?.length} bytes');
  }
  a.close();
  b.close();
}
