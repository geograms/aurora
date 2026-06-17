// RNS Phase-3b gate (Dart side): establish a Link to a Python resource sink and
// SEND a multi-part Resource over it; the sink reassembles, verifies, and proves
// receipt. Success = the sink's SHA-256 matches our payload AND we validate the
// returned proof.
//
//   python3 tool/reticulum_resource_sink.py /tmp/rns_rsink_cfg 4242   # other shell
//   dart run tool/reticulum_resource_test.dart 127.0.0.1 4242 [payload_bytes]
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'package:aurora/services/reticulum/rns_announce.dart';
import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_link.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/reticulum/rns_resource.dart';
import 'package:aurora/services/reticulum/rns_tcp_interface.dart';

const _app = 'aurora';
const _aspects = ['resource'];

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : '127.0.0.1';
  final port = args.length > 1 ? int.parse(args[1]) : 4242;
  final payloadLen = args.length > 2 ? int.parse(args[2]) : 32000;

  // Build an incompressible payload (so the reference sender wouldn't compress;
  // our sender never compresses).
  final payload = Uint8List(payloadLen);
  var s = 0x12345678;
  for (var i = 0; i < payloadLen; i++) {
    s = (1103515245 * s + 12345) & 0x7fffffff;
    payload[i] = (s >> 16) & 0xff;
  }
  final payloadSha = hx(crypto.sha256.convert(payload).bytes);
  print('PAYLOAD_LEN $payloadLen');
  print('PAYLOAD_SHA256 $payloadSha');

  final done = Completer<bool>();
  RnsLink? link;
  RnsResourceSender? sender;
  var requestSent = false;

  late RnsTcpInterface iface;
  iface = RnsTcpInterface(
    host: host,
    port: port,
    log: (m) => print('  [tcp] $m'),
    onPacket: (raw) async {
      final p = RnsPacket.parse(raw);
      if (p == null) return;

      if (p.packetType == RnsPacketType.announce && !requestSent) {
        final ann = await validateAnnounce(p);
        if (ann == null) return;
        if (hx(RnsDestination.hash(ann.identity, _app, _aspects)) !=
            hx(ann.destHash)) {
          return;
        }
        print('  [rx] announce for aurora.resource');
        requestSent = true;
        link = await RnsLink.initiator(ann.identity, _app, _aspects);
        iface.sendPacket(link!.buildRequest().pack());
        print('  [tx] LINKREQUEST');
        return;
      }

      final l = link;
      if (l == null || !l.ownsPacket(p)) return;

      if (p.packetType == RnsPacketType.proof &&
          p.context == RnsContext.lrproof) {
        final rtt = await l.handleProof(p);
        if (rtt == null) {
          print('  [!!] link proof failed');
          if (!done.isCompleted) done.complete(false);
          return;
        }
        iface.sendPacket(rtt.pack());
        print('  [tx] LRRTT (link ACTIVE) — preparing resource');
        sender = RnsResourceSender(l, payload);
        sender!.prepare();
        print('  resource: ${sender!.parts} parts, '
            '${sender!.transferSize}B encrypted');
        iface.sendPacket(sender!.advertisementPacket().pack());
        print('  [tx] RESOURCE_ADV');
        return;
      }

      final snd = sender;
      if (snd == null) return;

      // Receiver requests parts (link-encrypted DATA, context RESOURCE_REQ).
      if (p.packetType == RnsPacketType.data &&
          p.context == RnsContext.resourceReq) {
        final req = l.decrypt(p);
        final partsOut = snd.handleRequest(req);
        for (final part in partsOut) {
          iface.sendPacket(part.pack());
        }
        print('  [tx] served ${partsOut.length} parts');
        return;
      }

      // Receiver proves the resource (raw PROOF, context RESOURCE_PRF).
      if (p.packetType == RnsPacketType.proof &&
          p.context == RnsContext.resourcePrf) {
        final ok = snd.validateProof(p.data);
        print('  [rx] RESOURCE_PRF valid=$ok');
        if (!done.isCompleted) done.complete(ok);
        return;
      }
    },
  );

  try {
    await iface.connect();
  } catch (e) {
    print('CONNECT_FAILED $e');
    exit(1);
  }

  final ok = await done.future
      .timeout(const Duration(seconds: 60), onTimeout: () => false);
  await iface.close();
  print(ok
      ? '>>> SUCCESS: resource sent + proof verified (payload sha256 $payloadSha)'
      : '>>> FAILED: no verified proof within timeout');
  exit(ok ? 0 : 1);
}
