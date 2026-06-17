// RNS Phase-3 gate (Dart side): act as a TRANSPORT node bridging two rnsd-style
// instances. Connect to instance A (an announcing destination) and instance B,
// rebroadcast A's announces onto B. Success is checked on B with `rnpath`: A's
// destination becomes reachable THROUGH this Dart node (2 hops, via our
// transport id).
//
//   dart run tool/reticulum_transport_test.dart [hostA portA hostB portB secs]
import 'dart:io';

import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/reticulum/rns_tcp_interface.dart';
import 'package:aurora/services/reticulum/rns_transport.dart';

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main(List<String> args) async {
  final hostA = args.isNotEmpty ? args[0] : '127.0.0.1';
  final portA = args.length > 1 ? int.parse(args[1]) : 4242;
  final hostB = args.length > 2 ? args[2] : '127.0.0.1';
  final portB = args.length > 3 ? int.parse(args[3]) : 4343;
  final seconds = args.length > 4 ? int.parse(args[4]) : 25;

  final id = await RnsIdentity.generate();
  print('TRANSPORT_ID ${id.hexHash}');

  final transport = RnsTransport(
    transportId: id.hash,
    log: (m) => print('  [transport] $m'),
  );

  RnsTcpInterface mk(String host, int port, String label) {
    late RnsTcpInterface iface;
    iface = RnsTcpInterface(
      host: host,
      port: port,
      label: label,
      log: (m) => print('  [$label] $m'),
      onPacket: (raw) async {
        final p = RnsPacket.parse(raw);
        if (p == null) return;
        await transport.ingest(p, label);
      },
    );
    return iface;
  }

  final ifaceA = mk(hostA, portA, 'A');
  final ifaceB = mk(hostB, portB, 'B');
  transport.addInterface(ifaceA);
  transport.addInterface(ifaceB);

  try {
    await ifaceA.connect();
    await ifaceB.connect();
  } catch (e) {
    print('CONNECT_FAILED $e');
    exit(1);
  }
  print('BRIDGING A($hostA:$portA) <-> B($hostB:$portB) for ${seconds}s');

  await Future<void>.delayed(Duration(seconds: seconds));
  print('PATHS ${transport.pathCount}');
  for (final p in transport.paths) {
    print('  KNOWN ${hx(p.destHash)} hops=${p.hops} via=${p.via}');
  }
  await ifaceA.close();
  await ifaceB.close();
  exit(0);
}
