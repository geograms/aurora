// Phase 1 gate: against local i2pd, build a 1-hop inbound tunnel, publish a
// signed LeaseSet2 for a fresh destination via DatabaseStore, then look it up
// and get it back -> "LeaseSet2 accepted and retrievable from netDB".
//   dart run tool/i2p_phase1_test.dart [router.info] [host] [port] [netid]
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_i2np.dart';
import 'package:aurora/services/i2p/i2p_leaseset.dart';
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

  // ---- 1. Build a 1-hop inbound tunnel: gateway = i2pd, endpoint = us ----
  final rnd = Random.secure();
  final gwTunnel = rnd.nextInt(0x7fffffff) + 1; // i2pd's receive tunnel id
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
  if (reply == null) {
    print('>>> FAILED: no tunnel build reply');
    return s.close();
  }
  final rec = reply.$2.sublist(1, 1 + shortRecordSize);
  final rp = await openShortReplyRecord(
      record: rec, replyKey: keys.replyKey, h: keys.h, recordIndex: 0);
  if (rp[shortReplyRetOffset] != 0) {
    print('>>> FAILED: tunnel build declined ret=${rp[shortReplyRetOffset]}');
    return s.close();
  }
  print('inbound tunnel built: gateway=${hx(bob.identityHash).substring(0, 12)}.. '
      'tunnelId=$gwTunnel');

  // ---- 2. Destination + LeaseSet2 ----
  final dest = await Destination.generate();
  final endDate = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 540;
  final ls2 = await dest.buildLeaseSet2(
      [Lease2(bob.identityHash, gwTunnel, endDate)]);
  print('destination ${hx(dest.hash).substring(0, 16)}... leaseset ${ls2.length}b');

  // ---- 3. Publish via DatabaseStore (direct over NTCP2) ----
  await s.sendI2np(I2npType.databaseStore,
      buildLeaseSetStore(dest.hash, ls2, leaseSetStoreType));
  print('sent DatabaseStore for our LeaseSet2');
  await Future.delayed(const Duration(seconds: 2));

  // ---- 4. Retrieve via DatabaseLookup (LS) ----
  await s.sendI2np(
      I2npType.databaseLookup, buildLeaseSetLookup(dest.hash, us.identityHash));
  print('sent DatabaseLookup for our destination');

  for (var i = 0; i < 6; i++) {
    final r = await s.nextI2np(const Duration(seconds: 8));
    if (r == null) break;
    if (r.$1 == I2npType.databaseStore) {
      final key = r.$2.sublist(0, 32);
      final st = r.$2[32];
      if (hx(key) == hx(dest.hash)) {
        print('\n>>> SUCCESS: our LeaseSet2 retrieved from netDB '
            '(storeType=$st, ${r.$2.length}b)');
        return s.close();
      }
      print('   DatabaseStore for other key ${hx(key).substring(0, 12)}..');
    } else if (r.$1 == I2npType.databaseSearchReply) {
      print('   got DatabaseSearchReply (not found)');
    }
  }
  print('\n>>> FAILED: LeaseSet2 not retrievable');
  s.close();
}
