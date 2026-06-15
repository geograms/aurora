// Phase 1 proof of a WORKING inbound tunnel: build a 1-hop inbound tunnel
// through local i2pd, then inject a DeliveryStatus into the gateway via a
// TunnelGateway message and receive it back as a TunnelData message through the
// tunnel, decrypt the layer, and confirm the delivered message matches.
//   dart run tool/i2p_tunnel_data_test.dart [router.info] [host] [port] [netid]
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
  final gwTunnel = rnd.nextInt(0x7fffffff) + 1;
  final ourTunnel = rnd.nextInt(0x7fffffff) + 1;
  final plain = buildShortRequestPlaintext(
    receiveTunnel: gwTunnel,
    nextTunnel: ourTunnel,
    nextIdent: us.identityHash,
    isGateway: true,
    isEndpoint: false,
    sendMsgId: rnd.nextInt(0x7fffffff) + 1,
  );
  final (record, keys) = await buildShortRecord(
      hopIdentHash: bob.identityHash, hopStaticKey: encKey, plaintext: plain);
  await s.sendI2np(25, buildShortTunnelBuildMessage([record]));
  final reply = await s.nextI2np(const Duration(seconds: 15));
  if (reply == null) return _fail('no build reply', s);
  final rp = await openShortReplyRecord(
      record: reply.$2.sublist(1, 1 + shortRecordSize),
      replyKey: keys.replyKey, h: keys.h, recordIndex: 0);
  if (rp[shortReplyRetOffset] != 0) return _fail('build declined', s);
  print('inbound tunnel up: gateway tunnelId=$gwTunnel endpoint tunnelId=$ourTunnel');

  // Inject a DeliveryStatus into the gateway and expect it back via TunnelData.
  final probeId = rnd.nextInt(0x7fffffff) + 1;
  final inner = buildStandardI2np(
      10, probeId, buildDeliveryStatusBody(probeId)); // DeliveryStatus
  await s.sendI2np(19, buildTunnelGateway(gwTunnel, inner)); // TunnelGateway
  print('injected DeliveryStatus probeId=$probeId via TunnelGateway($gwTunnel)');

  final layer = TunnelLayer(keys.layerKey, keys.ivKey);
  var ok = false;
  for (var i = 0; i < 6 && !ok; i++) {
    final r = await s.nextI2np(const Duration(seconds: 8));
    if (r == null) break;
    print('<- I2NP type=${r.$1} len=${r.$2.length}');
    if (r.$1 == 18) {
      // TunnelData: tunnelId(4) + 1024
      final tid = readBe32(r.$2, 0);
      final dec = layer.decrypt(r.$2.sublist(4, 4 + 1024));
      final frag = parseTunnelData(dec);
      if (frag == null) {
        print('   could not parse tunnel data');
        continue;
      }
      print('   tunnelId=$tid deliveryType=${frag.deliveryType} '
          'checksumOk=${frag.checksumOk} innerType=${frag.message[0]}');
      if (frag.message[0] == 10) {
        final gotId = readBe32(frag.message, 16); // DeliveryStatus msgId in body
        print('   DeliveryStatus msgId=$gotId (sent $probeId)');
        if (gotId == probeId) ok = true;
      }
    }
  }
  print(ok
      ? '\n>>> SUCCESS: message delivered through our pure-Dart inbound I2P tunnel'
      : '\n>>> FAILED: did not receive the probe back through the tunnel');
  s.close();
}

void _fail(String why, Ntcp2Session s) {
  print('>>> FAILED: $why');
  s.close();
}
