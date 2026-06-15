// Phase 4: content discovery by hash. Three nodes share a peer roster; node C
// provides a file and announces it; node A discovers a provider for that sha256
// (knowing only the roster, NOT who holds it) and fetches the verified bytes.
//   dart run tool/i2p_discover_test.dart          # local i2pd (netid 9)
//   dart run tool/i2p_discover_test.dart real     # live network
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
      'AURORA Phase 4: file found by content hash across the I2P network with no '
      'prior knowledge of which device holds it (IPFS-style provider routing).'
          .codeUnits);
  final sha = I2pCrypto.sha256(content);

  RouterInfo? ri;
  Uint8List? iv;
  if (!real) {
    ri = parseRouterInfo(await File('/tmp/i2pd-data/router.info').readAsBytes())!;
    iv = Uint8List.fromList(
        (await File('/tmp/i2pd-data/ntcp2.keys').readAsBytes()).sublist(64, 80));
  }

  Future<I2pNode> mk(String name, {Future<Uint8List?> Function(Uint8List)? onGet}) async {
    final n = I2pNode(
        netId: real ? 2 : 9, log: (m) => print('[$name] $m'), onGet: onGet);
    final ok = real
        ? await n.start()
        : await n.start(peers: [ri!], hostOverride: '127.0.0.1', portOverride: 27654, ivOverride: iv);
    if (!ok) throw 'node $name failed to start';
    return n;
  }

  final twoNode = args.contains('2node');
  // C holds the content; A (and B) do not.
  final c = await mk('C', onGet: (s) async => hx(s) == hx(sha) ? content : null);
  final a = await mk('A');
  final b = twoNode ? null : await mk('B');

  // Everyone learns the roster (as if via beacons).
  final nodes = [a, c, if (b != null) b];
  final roster = [for (final n in nodes) n.destHash];
  for (final n in nodes) {
    n.setRoster(roster);
  }
  print('roster: A=${hx(a.destHash).substring(0, 8)} '
      '${b != null ? "B=${hx(b.destHash).substring(0, 8)} " : ""}'
      'C=${hx(c.destHash).substring(0, 8)}');
  print('content sha256=${hx(sha).substring(0, 16)}..');

  await Future.delayed(const Duration(seconds: 3)); // settle leasesets

  // C announces it provides the content.
  await c.announce(sha);
  print('C announced provision of the content');
  await Future.delayed(const Duration(seconds: 2));

  // A discovers a provider by hash alone and fetches.
  print('A discovering + fetching by hash (does not know C has it)...');
  final got = await a.discoverFetch(sha, timeout: Duration(seconds: real ? 60 : 25));
  if (got != null && hx(I2pCrypto.sha256(got)) == hx(sha)) {
    print('\n>>> SUCCESS: A found and fetched ${got.length} bytes by content hash '
        '${real ? "on the LIVE I2P network" : ""}, sha256 verified');
  } else {
    print('\n>>> FAILED: discovery/fetch returned ${got?.length} bytes');
  }
  a.close();
  b?.close();
  c.close();
}
