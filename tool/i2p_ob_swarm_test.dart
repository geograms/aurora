// Real-network OUTBOUND-tunnel delivery validation, minimal 2-node shape (mirrors
// desktop<->phone): one seeder + one leecher, both on the live public network,
// each with inbound + outbound tunnels. The leecher swarm-downloads a 150 KB /
// 5-piece file from the seeder THROUGH its outbound tunnel (the proper I2P path
// the OB work unlocked). Pass "local" to run against the local i2pd (netid 9) —
// but note 1-router i2pd can't build a distinct OBEP, so OB delivery only shows
// on the real network.
//   dart run tool/i2p_ob_swarm_test.dart
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_crypto.dart';
import 'package:aurora/services/i2p/i2p_node.dart';

String hx(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main() async {
  I2pNode.rxDiag = true;
  final content =
      Uint8List.fromList(List.generate(150000, (i) => (i * 2654435761 + 7) & 0xff));
  final sha = I2pCrypto.sha256(content);

  final seeder = I2pNode(
    netId: 2,
    log: (m) => print('[S] $m'),
    onGet: (s) async => hx(s) == hx(sha) ? content : null,
  );
  final leech = I2pNode(netId: 2, log: (m) => print('[L] $m'));

  print('starting seeder...');
  if (!await seeder.start()) {
    print('>>> FAILED: seeder did not start');
    return;
  }
  print('starting leecher...');
  if (!await leech.start()) {
    print('>>> FAILED: leecher did not start');
    return;
  }
  await Future.delayed(const Duration(seconds: 4)); // settle leasesets
  print('S=${seeder.b32}\nL=${leech.b32}');
  print('L swarm-fetching ${hx(sha).substring(0, 12)}.. from S via outbound tunnel...');

  final got = await leech.swarmFetch(sha,
      seedProviders: [seeder.destHash],
      perPiece: const Duration(seconds: 25),
      budget: const Duration(minutes: 5));

  if (got != null && hx(I2pCrypto.sha256(got)) == hx(sha)) {
    print('\n>>> SUCCESS: ${got.length} bytes swarm-downloaded over the LIVE network '
        'via OUTBOUND tunnels, sha256 verified');
  } else {
    print('\n>>> FAILED: got ${got?.length} bytes');
  }
  leech.close();
  seeder.close();
}
