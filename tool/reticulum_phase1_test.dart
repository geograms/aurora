// RNS Phase-1 gate (Dart side): connect to a Python rnsd over TCP, send a
// self-announce, and ingest/validate rnsd's announces into a path table.
//
//   dart run tool/reticulum_phase1_test.dart [host] [port] [seconds]
//
// Success proof (checked by the orchestration script): `rnpath` on the rnsd
// side lists OUR_DEST at hops=1 (rnsd accepted our announce and created a path),
// and this process validates >=1 announce from rnsd.
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/reticulum/rns_announce.dart';
import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/reticulum/rns_tcp_interface.dart';
import 'package:aurora/services/reticulum/rns_transport.dart';

const _app = 'aurora';
const _aspects = ['test'];

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : '127.0.0.1';
  final port = args.length > 1 ? int.parse(args[1]) : 4242;
  final seconds = args.length > 2 ? int.parse(args[2]) : 20;

  final id = await RnsIdentity.generate();
  final destHash = RnsDestination.hash(id, _app, _aspects);
  print('OUR_IDENTITY ${id.hexHash}');
  print('OUR_DEST ${hx(destHash)}');

  final transport = RnsTransport(log: (m) => print('  [transport] $m'));
  var validated = 0;

  final iface = RnsTcpInterface(
    host: host,
    port: port,
    log: (m) => print('  [tcp] $m'),
    onPacket: (raw) async {
      final p = RnsPacket.parse(raw);
      if (p == null) {
        print('  [rx] malformed (${raw.length}B)');
        return;
      }
      final ann = await transport.ingest(p, 'tcp');
      if (ann != null) {
        validated++;
        print('  [rx] announce dest=${hx(ann.destHash)} '
            'id=${ann.identity.hexHash} appData=${_printable(ann.appData)}');
      }
    },
  );

  try {
    await iface.connect();
  } catch (e) {
    print('CONNECT_FAILED $e');
    exit(1);
  }

  Future<void> announce() async {
    final pkt = await RnsAnnounceBuilder.build(id, _app, _aspects,
        appData: Uint8List.fromList('aurora-dart-node'.codeUnits));
    iface.sendPacket(pkt.pack());
    print('  [tx] announce sent (${pkt.pack().length}B on wire payload)');
  }

  // Announce immediately, then every 5s, for the duration.
  await announce();
  final ticker = Stream.periodic(const Duration(seconds: 5)).take(seconds ~/ 5);
  await for (final _ in ticker) {
    if (!iface.isConnected) break;
    await announce();
  }
  await Future<void>.delayed(const Duration(seconds: 2));

  print('PATHS ${transport.pathCount}');
  print('VALIDATED_ANNOUNCES $validated');
  await iface.close();
  print(validated >= 1 ? '>>> RX OK' : '>>> RX NONE (check rnsd announces)');
  exit(0);
}

String _printable(Uint8List b) {
  final sb = StringBuffer();
  for (final c in b) {
    sb.write(c >= 32 && c < 127 ? String.fromCharCode(c) : '.');
  }
  return sb.toString();
}
