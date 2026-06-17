// RNS Phase-4 LAN data-plane gate (Dart side): speak RNS over UDP (one raw
// packet per datagram — the AutoInterface/UDPInterface data model) to a Python
// rnsd UDPInterface. Send a self-announce and ingest rnsd's announces. Success
// is checked on rnsd with `rnpath`: the Aurora dest appears, learned over the
// UDP interface.
//
//   dart run tool/reticulum_udp_test.dart [listenPort forwardPort seconds]
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/reticulum/rns_announce.dart';
import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/reticulum/rns_transport.dart';
import 'package:aurora/services/reticulum/rns_udp_interface.dart';

const _app = 'aurora';
const _aspects = ['test'];

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main(List<String> args) async {
  final listenPort = args.isNotEmpty ? int.parse(args[0]) : 4251;
  final forwardPort = args.length > 1 ? int.parse(args[1]) : 4250;
  final seconds = args.length > 2 ? int.parse(args[2]) : 20;

  final id = await RnsIdentity.generate();
  final destHash = RnsDestination.hash(id, _app, _aspects);
  print('OUR_DEST ${hx(destHash)}');

  final transport = RnsTransport(log: (m) => print('  [transport] $m'));
  var validated = 0;

  final iface = RnsUdpInterface(
    listenPort: listenPort,
    forwardPort: forwardPort,
    log: (m) => print('  [udp] $m'),
    onPacket: (raw) async {
      final p = RnsPacket.parse(raw);
      if (p == null) return;
      final ann = await transport.ingest(p, 'udp');
      if (ann != null) {
        validated++;
        print('  [rx] announce dest=${hx(ann.destHash)} id=${ann.identity.hexHash}');
      }
    },
  );
  await iface.bind();

  Future<void> announce() async {
    final pkt = await RnsAnnounceBuilder.build(id, _app, _aspects,
        appData: Uint8List.fromList([0x75, 0x64, 0x70])); // "udp"
    iface.send(pkt.pack());
    print('  [tx] announce sent');
  }

  await announce();
  final ticker = Stream.periodic(const Duration(seconds: 5)).take(seconds ~/ 5);
  await for (final _ in ticker) {
    await announce();
  }
  await Future<void>.delayed(const Duration(seconds: 2));
  print('PATHS ${transport.pathCount}');
  print('VALIDATED_ANNOUNCES $validated');
  await iface.close();
  exit(0);
}
