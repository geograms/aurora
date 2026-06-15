// Phase 1: send a real ShortTunnelBuild to local i2pd and see it decrypt and
// accept our ECIES build record. Builds a 1-hop INBOUND tunnel with i2pd as the
// gateway and us as the endpoint, so i2pd forwards the build reply straight back
// to us over the same NTCP2 session.
//   dart run tool/i2p_tunnel_build_test.dart [router.info] [host] [port] [netid]
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_ntcp2.dart';
import 'package:aurora/services/i2p/i2p_router.dart';
import 'package:aurora/services/i2p/i2p_structures.dart';
import 'package:aurora/services/i2p/i2p_tunnel_build.dart';

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty ? args[0] : '/tmp/i2pd-data/router.info';
  final host = args.length > 1 ? args[1] : '127.0.0.1';
  final port = args.length > 2 ? int.parse(args[2]) : 27654;
  final netId = args.length > 3 ? int.parse(args[3]) : 2;

  final bob = parseRouterInfo(await File(path).readAsBytes())!;
  final encKey = bob.encryptionKey;
  print('hop ${hx(bob.identityHash).substring(0, 16)}... '
      'ecies=${bob.isEcies} encKey=${encKey != null}');
  if (encKey == null) {
    print('>>> hop is not ECIES, cannot build');
    return;
  }

  Uint8List? iv;
  final keysFile = File('${File(path).parent.path}/ntcp2.keys');
  if (keysFile.existsSync()) {
    final kb = await keysFile.readAsBytes();
    if (kb.length >= 80) iv = Uint8List.fromList(kb.sublist(64, 80));
  }

  final us = await OurRouter.generate(netId: netId);
  print('our hash ${hx(us.identityHash).substring(0, 16)}...');

  final s = Ntcp2Session(bob, us,
      log: print, hostOverride: host, portOverride: port, ivOverride: iv, netId: netId);
  await s.handshake();

  final rnd = Random.secure();
  final hopRecvTunnel = rnd.nextInt(0x7fffffff) + 1;
  final ourRecvTunnel = rnd.nextInt(0x7fffffff) + 1;
  final sendMsgId = rnd.nextInt(0x7fffffff) + 1;

  // 1-hop inbound: i2pd is the gateway, next hop = us (endpoint).
  final plain = buildShortRequestPlaintext(
    receiveTunnel: hopRecvTunnel,
    nextTunnel: ourRecvTunnel,
    nextIdent: us.identityHash,
    isGateway: true,
    isEndpoint: false,
    sendMsgId: sendMsgId,
  );
  final (record, keys) = await buildShortRecord(
    hopIdentHash: bob.identityHash,
    hopStaticKey: encKey,
    plaintext: plain,
  );
  final msg = buildShortTunnelBuildMessage([record]);
  print('sending ShortTunnelBuild: 1 record, hopRecvTunnel=$hopRecvTunnel '
      'ourRecvTunnel=$ourRecvTunnel msgId=$sendMsgId');

  await s.sendI2np(25, msg); // eI2NPShortTunnelBuild

  var verdict = '';
  await s.pumpI2np(const Duration(seconds: 15), (type, body) async {
    print('<- I2NP type=$type len=${body.length}');
    if ((type == 26 || type == 25) && body.isNotEmpty) {
      final count = body[0];
      // our reply record is record index 0
      final rec = body.sublist(1, 1 + shortRecordSize);
      try {
        final plain = await openShortReplyRecord(
          record: rec,
          replyKey: keys.replyKey,
          h: keys.h,
          recordIndex: 0,
        );
        final ret = plain[shortReplyRetOffset];
        verdict = ret == 0 ? 'ACCEPTED' : 'declined (ret=$ret)';
        print('   reply: $count record(s), our hop verdict: $verdict');
      } catch (e) {
        verdict = 'decrypt-failed';
        print('   reply record decrypt FAILED: $e');
      }
    }
  });
  print(verdict == 'ACCEPTED'
      ? '\n>>> SUCCESS: i2pd accepted our pure-Dart tunnel build record'
      : '\n>>> result: ${verdict.isEmpty ? "no reply" : verdict}');
  s.close();
}
