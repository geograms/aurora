// Swarm over real I2P tunnels: two full seeders + one leecher. The leecher
// discovers nothing up front (we seed it with both providers) and pulls the
// file's pieces from BOTH seeders in parallel, reassembling each 32 KiB piece
// from ~33 tunnel cells (exercises the new multi-cell fragment reassembly) and
// verifying every piece + the whole file by sha256.
//   (local i2pd must be running on 27654, netid 9)
//   dart run tool/i2p_swarm_real_test.dart          # local i2pd
//   dart run tool/i2p_swarm_real_test.dart real     # live public network
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_crypto.dart';
import 'package:aurora/services/i2p/i2p_node.dart';
import 'package:aurora/services/i2p/i2p_structures.dart';

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main(List<String> args) async {
  final real = args.contains('real');
  // ~150 KB -> 5 pieces of 32 KiB (the last short). Big enough that the whole
  // file CANNOT travel as one datagram, so pieces + reassembly are mandatory.
  final content =
      Uint8List.fromList(List.generate(150000, (i) => (i * 1103515245 + 12345) & 0xff));
  final contentHash = I2pCrypto.sha256(content);

  Future<I2pNode> mk(String name, {Future<Uint8List?> Function(Uint8List)? onGet}) async {
    if (real) {
      final n = I2pNode(netId: 2, log: (m) => print('[$name] $m'), onGet: onGet);
      if (!await n.start()) throw 'node $name failed to start on live network';
      return n;
    }
    final ri = parseRouterInfo(await File('/tmp/i2pd-data/router.info').readAsBytes())!;
    final iv = Uint8List.fromList(
        (await File('/tmp/i2pd-data/ntcp2.keys').readAsBytes()).sublist(64, 80));
    final n = I2pNode(netId: 9, log: (m) => print('[$name] $m'), onGet: onGet);
    if (!await n.start(
        peers: [ri], hostOverride: '127.0.0.1', portOverride: 27654, ivOverride: iv)) {
      throw 'node $name failed to start';
    }
    return n;
  }

  Future<Uint8List?> serve(Uint8List sha) async =>
      hx(sha) == hx(contentHash) ? content : null;

  final s1 = await mk('S1', onGet: serve);
  final s2 = await mk('S2', onGet: serve);
  final l = await mk('L'); // leecher holds nothing
  print('S1=${s1.b32}\nS2=${s2.b32}\nL =${l.b32}');
  await Future.delayed(const Duration(seconds: 4)); // settle leasesets

  print('L swarm-fetching ${hx(contentHash).substring(0, 12)}.. from 2 seeders ...');
  final got = await l.swarmFetch(contentHash,
      seedProviders: [s1.destHash, s2.destHash],
      perPiece: Duration(seconds: real ? 20 : 10),
      budget: Duration(minutes: 4),
      cap: 6);

  if (got != null && hx(I2pCrypto.sha256(got)) == hx(contentHash)) {
    print('\n>>> SUCCESS: collectively swarm-downloaded ${got.length} bytes '
        '(${(got.length / 32768).ceil()} pieces) from 2 devices, sha256 verified'
        '${real ? " on the LIVE I2P network" : ""}');
  } else {
    print('\n>>> FAILED: swarm fetch returned ${got?.length} bytes');
  }
  l.close();
  s1.close();
  s2.close();
}
