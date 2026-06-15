// Probe: build a 1-HOP OUTBOUND tunnel through the local i2pd (the OBEP) and see
// how the build reply comes back. We dial the OBEP directly and route the reply
// to ourselves (nextIdent = our router), hoping the OBEP replies over the same
// session like a 1-hop inbound gateway does (no garlic). If accepted, outbound
// tunnels are buildable without ECIES garlic.
//   (local i2pd must be running on 27654, netid 9)
//   dart run tool/i2p_ob_build_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_ntcp2.dart';
import 'package:aurora/services/i2p/i2p_router.dart';
import 'package:aurora/services/i2p/i2p_structures.dart';
import 'package:aurora/services/i2p/i2p_tunnel_build.dart';

Future<void> main() async {
  final ri = parseRouterInfo(await File('/tmp/i2pd-data/router.info').readAsBytes())!;
  final iv = Uint8List.fromList(
      (await File('/tmp/i2pd-data/ntcp2.keys').readAsBytes()).sublist(64, 80));
  final us = await OurRouter.generate(netId: 9);

  Ntcp2Session dial() => Ntcp2Session(ri, us,
      hostOverride: '127.0.0.1', portOverride: 27654, ivOverride: iv, netId: 9);

  final s = dial();
  await s.handshake().timeout(const Duration(seconds: 15));
  print('handshake OK with OBEP ${_hx(ri.identityHash).substring(0, 12)}');

  final t = DateTime.now().microsecondsSinceEpoch;
  final outTun = (t & 0x7fffffff) | 1;
  final plain = buildShortRequestPlaintext(
    receiveTunnel: outTun, // OBEP receives our outbound tunnel data on this id
    nextTunnel: 0, // endpoint: no forward tunnel; reply routing only
    nextIdent: us.identityHash, // reply to us (we're adjacent -> over the session)
    isGateway: false,
    isEndpoint: true, // OUTBOUND endpoint
    sendMsgId: (t >> 16) & 0x7fffffff,
  );
  final (rec, keys) = await buildShortRecord(
      hopIdentHash: ri.identityHash,
      hopStaticKey: ri.encryptionKey!,
      plaintext: plain,
      isEndpoint: true); // endpoint IV-key derivation
  await s.sendI2np(25, buildShortTunnelBuildMessage([rec]));
  print('sent ShortTunnelBuild (1-hop outbound), awaiting reply...');

  final reply = await s.nextI2np(const Duration(seconds: 15));
  if (reply == null) {
    print('>>> NO REPLY (reply not routed back over the session — likely needs '
        'a reply tunnel / garlic)');
    s.close();
    return;
  }
  print('reply: i2npType=${reply.$1} len=${reply.$2.length}');
  if (reply.$1 == 19) {
    // TunnelGateway: [tunnelId(4)][len(2)][inner I2NP message]
    final b = reply.$2;
    final tid = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    final ilen = (b[4] << 8) | b[5];
    final inner = b.sublist(6, 6 + ilen);
    print('  TunnelGateway tunnelId=$tid innerLen=$ilen innerType=${inner[0]} '
        'inner[0:20]=${_hx(inner.sublist(0, inner.length < 20 ? inner.length : 20))}');
    // inner has a 16-byte standard I2NP header; body starts at 16
    final body = inner.sublist(16); // garlic body: [length(4)][tag(8)][ct]
    if (inner[0] == 11 && keys.garlicKey != null) {
      final ret = await openShortBuildReplyGarlic(
        garlicBody: body,
        garlicKey: keys.garlicKey!,
        garlicTag: keys.garlicTag!,
        replyKey: keys.replyKey,
        h: keys.h,
        recordIndex: 0,
      );
      if (ret == null) {
        print('>>> garlic reply decrypt FAILED (tag/AEAD/parse mismatch)');
      } else {
        print(ret == 0
            ? '>>> SUCCESS: OB build ACCEPTED — symmetric-garlic reply decrypted (ret=0)'
            : '>>> DECLINED ret=$ret (but garlic decrypted OK)');
      }
    } else {
      print('>>> inner type ${inner[0]} unexpected');
    }
    s.close();
    return;
  }
  if (reply.$1 == 25 && reply.$2.length >= 1 + shortRecordSize) {
    final rp = await openShortReplyRecord(
        record: reply.$2.sublist(1, 1 + shortRecordSize),
        replyKey: keys.replyKey, h: keys.h, recordIndex: 0);
    final ret = rp[shortReplyRetOffset];
    print(ret == 0
        ? '>>> SUCCESS: outbound tunnel build ACCEPTED (ret=0) — reply over the '
            'session, no garlic needed'
        : '>>> DECLINED ret=$ret');
  } else {
    print('>>> reply is not a plain ShortTunnelBuild (type ${reply.$1}) — may be '
        'garlic-wrapped; needs ECIES');
  }
  s.close();
}

String _hx(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
