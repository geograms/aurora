// Phase 2 foundation: cross-node delivery. Node B builds an inbound tunnel
// through i2pd. Node A (a separate router/session) delivers a message into B's
// inbound tunnel by sending a TunnelGateway to i2pd (B's gateway). Proves a
// destination can be reached by another party via its published lease path.
//   dart run tool/i2p_phase2_xdeliver_test.dart [router.info] [host] [port] [netid]
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_i2np.dart';
import 'package:aurora/services/i2p/i2p_ntcp2.dart';
import 'package:aurora/services/i2p/i2p_router.dart';
import 'package:aurora/services/i2p/i2p_structures.dart';
import 'package:aurora/services/i2p/i2p_tunnel_build.dart';
import 'package:aurora/services/i2p/i2p_tunnel_data.dart';

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<Ntcp2Session> connect(RouterInfo bob, Uint8List iv, int netId) async {
  final us = await OurRouter.generate(netId: netId);
  final s = Ntcp2Session(bob, us,
      log: (_) {}, hostOverride: '127.0.0.1', portOverride: 27654, ivOverride: iv, netId: netId);
  await s.handshake();
  return s;
}

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty ? args[0] : '/tmp/i2pd-data/router.info';
  final netId = args.length > 3 ? int.parse(args[3]) : 9;
  final bob = parseRouterInfo(await File(path).readAsBytes())!;
  final encKey = bob.encryptionKey!;
  final kb = await File('${File(path).parent.path}/ntcp2.keys').readAsBytes();
  final iv = Uint8List.fromList(kb.sublist(64, 80));
  final rnd = Random.secure();

  // ---- Node B: build an inbound tunnel (gateway = i2pd) ----
  final bGw = rnd.nextInt(0x7fffffff) + 1;
  final bEnd = rnd.nextInt(0x7fffffff) + 1;
  final bUs = await OurRouter.generate(netId: netId);
  final b = Ntcp2Session(bob, bUs,
      log: (_) {}, hostOverride: '127.0.0.1', portOverride: 27654, ivOverride: iv, netId: netId);
  await b.handshake();
  final bPlain = buildShortRequestPlaintext(
      receiveTunnel: bGw, nextTunnel: bEnd, nextIdent: bUs.identityHash,
      isGateway: true, isEndpoint: false, sendMsgId: rnd.nextInt(0x7fffffff) + 1);
  final (bRec, bKeys) = await buildShortRecord(
      hopIdentHash: bob.identityHash, hopStaticKey: encKey, plaintext: bPlain);
  await b.sendI2np(25, buildShortTunnelBuildMessage([bRec]));
  final bReply = await b.nextI2np(const Duration(seconds: 15));
  if (bReply == null) {
    print('>>> FAILED: B tunnel not built');
    return;
  }
  print('B inbound tunnel built (gateway tunnelId=$bGw)');

  // ---- Node A: separate session, deliver a probe into B's tunnel ----
  final a = await connect(bob, iv, netId);
  final probe = rnd.nextInt(0x7fffffff) + 1;
  final inner = buildStandardI2np(10, probe, buildDeliveryStatusBody(probe));
  await a.sendI2np(19, buildTunnelGateway(bGw, inner)); // to B's gateway (i2pd)
  print('A delivered probe=$probe into B\'s tunnel via TunnelGateway($bGw)');

  // ---- B receives the probe through its inbound tunnel ----
  final layer = TunnelLayer(bKeys.layerKey, bKeys.ivKey);
  var ok = false;
  for (var i = 0; i < 6 && !ok; i++) {
    final r = await b.nextI2np(const Duration(seconds: 8));
    if (r == null) break;
    if (r.$1 != 18) continue;
    final dec = layer.decrypt(r.$2.sublist(4, 4 + 1024));
    final frag = parseTunnelData(dec);
    if (frag != null && frag.message.isNotEmpty && frag.message[0] == 10) {
      final gotId = readBe32(frag.message, 16);
      print('B received message from A: DeliveryStatus msgId=$gotId');
      if (gotId == probe) ok = true;
    }
  }
  print(ok
      ? '\n>>> SUCCESS: node A reached node B across separate sessions over I2P'
      : '\n>>> FAILED: B did not receive A\'s message');
  a.close();
  b.close();
}
