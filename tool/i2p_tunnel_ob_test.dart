// Phase 1: verify an OUTBOUND tunnel build. We are the gateway, i2pd is the
// outbound endpoint (OBEP). Same ECIES record crypto as inbound, with the
// ENDPOINT flag. Confirms i2pd accepts and creates the endpoint transit tunnel
// (check its log: "TransitTunnel: endpoint <id> created").
//   dart run tool/i2p_tunnel_ob_test.dart [router.info] [host] [port] [netid]
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
  final encKey = bob.encryptionKey!;
  Uint8List? iv;
  final keysFile = File('${File(path).parent.path}/ntcp2.keys');
  if (keysFile.existsSync()) {
    final kb = await keysFile.readAsBytes();
    if (kb.length >= 80) iv = Uint8List.fromList(kb.sublist(64, 80));
  }
  final us = await OurRouter.generate(netId: netId);
  final s = Ntcp2Session(bob, us,
      log: print, hostOverride: host, portOverride: port, ivOverride: iv, netId: netId);
  await s.handshake();

  final rnd = Random.secure();
  final obepTunnel = rnd.nextInt(0x7fffffff) + 1;
  // 1-hop outbound: i2pd is the endpoint (OBEP). next ident/tunnel = 0 (the OBEP
  // delivers decrypted messages onward per their delivery instructions).
  final plain = buildShortRequestPlaintext(
    receiveTunnel: obepTunnel,
    nextTunnel: 0,
    nextIdent: Uint8List(32),
    isGateway: false,
    isEndpoint: true,
    sendMsgId: rnd.nextInt(0x7fffffff) + 1,
  );
  final (record, keys) = await buildShortRecord(
      hopIdentHash: bob.identityHash, hopStaticKey: encKey, plaintext: plain);
  await s.sendI2np(25, buildShortTunnelBuildMessage([record]));
  print('sent outbound ShortTunnelBuild: OBEP tunnelId=$obepTunnel');

  final reply = await s.nextI2np(const Duration(seconds: 15));
  if (reply != null && reply.$2.length >= 1 + shortRecordSize) {
    final rp = await openShortReplyRecord(
        record: reply.$2.sublist(1, 1 + shortRecordSize),
        replyKey: keys.replyKey, h: keys.h, recordIndex: 0);
    final ret = rp[shortReplyRetOffset];
    print(ret == 0
        ? '\n>>> SUCCESS: i2pd accepted our outbound tunnel build (OBEP)'
        : '\n>>> outbound build declined ret=$ret');
  } else {
    // No direct reply for OBEP is normal (it routes via a reply tunnel); the
    // i2pd log "endpoint $obepTunnel created" confirms acceptance.
    print('\n(no direct reply; check i2pd log for "endpoint $obepTunnel created")');
  }
  s.close();
}
