// RNS Phase-2 gate (Dart side): connect to a Python echo destination over TCP,
// hear its announce, establish a Link (3-packet handshake), send encrypted data
// over the link, and verify the echoed reply decrypts to what we sent.
//
//   python3 tool/reticulum_echo.py /tmp/rns_echo_cfg 4242   # in another shell
//   dart run tool/reticulum_link_test.dart 127.0.0.1 4242
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/reticulum/rns_announce.dart';
import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_link.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/reticulum/rns_tcp_interface.dart';

const _app = 'aurora';
const _aspects = ['echo'];

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : '127.0.0.1';
  final port = args.length > 1 ? int.parse(args[1]) : 4242;

  final message = Uint8List.fromList('hello reticulum from dart'.codeUnits);
  final done = Completer<bool>();
  RnsLink? link;
  var requestSent = false;

  late RnsTcpInterface iface;
  iface = RnsTcpInterface(
    host: host,
    port: port,
    log: (m) => print('  [tcp] $m'),
    onPacket: (raw) async {
      final p = RnsPacket.parse(raw);
      if (p == null) return;

      // 1. Learn the echo destination from its announce, then start the link.
      if (p.packetType == RnsPacketType.announce && !requestSent) {
        final ann = await validateAnnounce(p);
        if (ann == null) return;
        final expected = RnsDestination.hash(ann.identity, _app, _aspects);
        if (hx(expected) != hx(ann.destHash)) return; // not aurora.echo
        print('  [rx] announce for aurora.echo dest=${hx(ann.destHash)}');
        requestSent = true;
        link = await RnsLink.initiator(ann.identity, _app, _aspects);
        final req = link!.buildRequest();
        print('  [tx] LINKREQUEST link_id=${hx(link!.linkId!)}');
        iface.sendPacket(req.pack());
        return;
      }

      final l = link;
      if (l == null || !l.ownsPacket(p)) return;

      // 2. Handle the link proof -> send LRRTT -> send our data.
      if (p.packetType == RnsPacketType.proof &&
          p.context == RnsContext.lrproof) {
        final rtt = await l.handleProof(p);
        if (rtt == null) {
          print('  [!!] link proof validation FAILED');
          if (!done.isCompleted) done.complete(false);
          return;
        }
        print('  [tx] LRRTT (link ACTIVE)');
        iface.sendPacket(rtt.pack());
        final data = l.encrypt(message);
        print('  [tx] DATA "${String.fromCharCodes(message)}"');
        iface.sendPacket(data.pack());
        return;
      }

      // 3. Receive the echoed DATA over the link.
      if (p.packetType == RnsPacketType.data &&
          p.context == RnsContext.none &&
          l.status == RnsLinkStatus.active) {
        try {
          final clear = l.decrypt(p);
          final match = hx(clear) == hx(message);
          print('  [rx] echo "${String.fromCharCodes(clear)}" '
              '(match=$match)');
          if (!done.isCompleted) done.complete(match);
        } catch (e) {
          print('  [!!] decrypt failed: $e');
          if (!done.isCompleted) done.complete(false);
        }
      }
    },
  );

  try {
    await iface.connect();
  } catch (e) {
    print('CONNECT_FAILED $e');
    exit(1);
  }

  final ok = await done.future.timeout(const Duration(seconds: 30),
      onTimeout: () => false);
  await iface.close();
  print(ok
      ? '>>> SUCCESS: link established + encrypted echo verified'
      : '>>> FAILED: no verified echo within timeout');
  exit(ok ? 0 : 1);
}
