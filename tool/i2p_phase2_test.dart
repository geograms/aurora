// Phase 2 gate: two of our own destinations exchange repliable datagrams over
// real I2P tunnels, and a GET-by-sha256 returns the right bytes (hash-verified).
// Flow: B publishes a LeaseSet2 and serves content; A looks up B's LeaseSet,
// sends a signed GET datagram into B's inbound tunnel; B verifies A, finds the
// bytes, and replies into A's inbound tunnel; A verifies the sha256.
//   dart run tool/i2p_phase2_test.dart [router.info] [host] [port] [netid]
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_datagram.dart';
import 'package:aurora/services/i2p/i2p_crypto.dart';
import 'package:aurora/services/i2p/i2p_i2np.dart';
import 'package:aurora/services/i2p/i2p_leaseset.dart';
import 'package:aurora/services/i2p/i2p_ntcp2.dart';
import 'package:aurora/services/i2p/i2p_router.dart';
import 'package:aurora/services/i2p/i2p_structures.dart';
import 'package:aurora/services/i2p/i2p_tunnel_build.dart';
import 'package:aurora/services/i2p/i2p_tunnel_data.dart';

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

late RouterInfo i2pd;
late Uint8List i2pdEnc;
late Uint8List i2pdIv;
int netId = 9;
final rnd = Random.secure();

class Node {
  final OurRouter router;
  final Destination dest;
  final Ntcp2Session s;
  final int gwTunnel; // i2pd's receive tunnel id = our inbound gateway tunnel
  final TunnelLayer layer;
  Node(this.router, this.dest, this.s, this.gwTunnel, this.layer);
}

Future<Node> buildNode(String name) async {
  final router = await OurRouter.generate(netId: netId);
  final dest = await Destination.generate();
  final s = Ntcp2Session(i2pd, router,
      log: (_) {}, hostOverride: '127.0.0.1', portOverride: 27654,
      ivOverride: i2pdIv, netId: netId);
  await s.handshake();
  final gw = rnd.nextInt(0x7fffffff) + 1;
  final plain = buildShortRequestPlaintext(
      receiveTunnel: gw, nextTunnel: rnd.nextInt(0x7fffffff) + 1,
      nextIdent: router.identityHash, isGateway: true, isEndpoint: false,
      sendMsgId: rnd.nextInt(0x7fffffff) + 1);
  final (rec, keys) = await buildShortRecord(
      hopIdentHash: i2pd.identityHash, hopStaticKey: i2pdEnc, plaintext: plain);
  await s.sendI2np(25, buildShortTunnelBuildMessage([rec]));
  final reply = await s.nextI2np(const Duration(seconds: 15));
  if (reply == null) throw 'tunnel build failed for $name';
  // publish leaseset
  final end = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 540;
  final ls = await dest.buildLeaseSet2([Lease2(i2pd.identityHash, gw, end)]);
  await s.sendI2np(I2npType.databaseStore,
      buildLeaseSetStore(dest.hash, ls, leaseSetStoreType));
  print('$name up: dest=${hx(dest.hash).substring(0, 12)}.. inbound tunnelId=$gw');
  return Node(router, dest, s, gw, TunnelLayer(keys.layerKey, keys.ivKey));
}

/// Send an I2NP Data message carrying [datagram] into [targetTunnelId] via the
/// gateway, over [from]'s session.
Future<void> sendDatagram(Node from, int targetTunnelId, Uint8List datagram) async {
  final dataMsg = buildStandardI2np(i2npData, randomMsgId(), wrapDataBody(datagram));
  await from.s.sendI2np(19, buildTunnelGateway(targetTunnelId, dataMsg));
}

/// Wait for a datagram to arrive through [n]'s inbound tunnel.
Future<ParsedDatagram?> recvDatagram(Node n, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final r = await n.s.nextI2np(deadline.difference(DateTime.now()));
    if (r == null) return null;
    if (r.$1 != 18) continue; // not TunnelData
    final dec = n.layer.decrypt(r.$2.sublist(4, 4 + 1024));
    final frag = parseTunnelData(dec);
    if (frag == null || frag.message.isEmpty || frag.message[0] != i2npData) continue;
    final m = frag.message;
    final size = (m[13] << 8) | m[14];
    final body = m.sublist(16, 16 + size);
    final dg = unwrapDataBody(body);
    if (dg == null) continue;
    return parseDatagram(dg);
  }
  return null;
}

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty ? args[0] : '/tmp/i2pd-data/router.info';
  netId = args.length > 3 ? int.parse(args[3]) : 9;
  i2pd = parseRouterInfo(await File(path).readAsBytes())!;
  i2pdEnc = i2pd.encryptionKey!;
  i2pdIv = Uint8List.fromList(
      (await File('${File(path).parent.path}/ntcp2.keys').readAsBytes()).sublist(64, 80));

  // B serves a piece of content addressed by its sha256.
  final content = Uint8List.fromList(
      'aurora i2p phase 2: file content shared device-to-device'.codeUnits);
  final contentHash = I2pCrypto.sha256(content);

  final b = await buildNode('B');
  final a = await buildNode('A');
  await Future.delayed(const Duration(seconds: 2)); // let leasesets settle

  // A looks up B's LeaseSet and extracts B's inbound lease.
  await a.s.sendI2np(
      I2npType.databaseLookup, buildLeaseSetLookup(b.dest.hash, a.router.identityHash));
  int? bTunnel;
  for (var i = 0; i < 6 && bTunnel == null; i++) {
    final r = await a.s.nextI2np(const Duration(seconds: 8));
    if (r == null) break;
    if (r.$1 == I2npType.databaseStore && hx(r.$2.sublist(0, 32)) == hx(b.dest.hash)) {
      final leases = parseLeaseSet2Leases(r.$2.sublist(37));
      if (leases.isNotEmpty) bTunnel = leases.first.tunnelId;
    }
  }
  if (bTunnel == null) {
    print('>>> FAILED: A could not look up B\'s LeaseSet');
    return;
  }
  print('A looked up B\'s LeaseSet -> B inbound tunnelId=$bTunnel');

  // A -> B: signed GET datagram (with A's reply lease), into B's tunnel.
  final get = buildGet(contentHash, i2pd.identityHash, a.gwTunnel);
  await sendDatagram(a, bTunnel, await buildDatagram(a.dest, get));
  print('A sent GET for ${hx(contentHash).substring(0, 12)}.. into B\'s tunnel');

  // B receives, authenticates A, serves the content into A's reply lease.
  final reqDg = await recvDatagram(b, const Duration(seconds: 20));
  if (reqDg == null) {
    print('>>> FAILED: B did not receive the GET');
    return;
  }
  final req = parseGet(reqDg.payload);
  print('B received GET (sender sig valid=${reqDg.sigValid}) for '
      '${req != null ? hx(req.sha256).substring(0, 12) : "?"}..');
  if (req == null || !reqDg.sigValid) {
    print('>>> FAILED: bad GET');
    return;
  }
  final serve = hx(req.sha256) == hx(contentHash) ? content : Uint8List(0);
  await sendDatagram(b, req.replyTunnelId, await buildDatagram(b.dest, buildDat(req.sha256, serve)));
  print('B served ${serve.length} bytes into A\'s reply tunnel');

  // A receives the response and verifies the hash.
  final resDg = await recvDatagram(a, const Duration(seconds: 20));
  if (resDg == null) {
    print('>>> FAILED: A did not receive the response');
    return;
  }
  final dat = parseDat(resDg.payload);
  if (dat == null) {
    print('>>> FAILED: bad response');
    return;
  }
  final gotHash = I2pCrypto.sha256(dat.bytes);
  final match = hx(gotHash) == hx(contentHash);
  print('A received ${dat.bytes.length} bytes (sender sig valid=${resDg.sigValid}); '
      'sha256 match=$match');
  print(match && resDg.sigValid
      ? '\n>>> SUCCESS: GET-by-sha256 over I2P returned the right bytes between two destinations'
      : '\n>>> FAILED: hash or signature mismatch');
  a.s.close();
  b.s.close();
}
