// Headless Linux Reticulum node/hub for device-to-device validation. Uses the
// exact same pure-Dart RNS stack the Aurora app runs (transport + TCP server
// interface), so it represents "the Linux version" without needing the GUI.
//
// Acts as a TCP-server transport hub: phones connect in (via `adb reverse
// tcp:4242 tcp:4242`), and the hub relays announces between them and itself, so
// all three nodes can talk. It announces "aurora.chat" with app_data text and
// prints inbound chat messages.
//
//   dart run tool/reticulum_hub.dart [port]
import 'dart:convert';
import 'dart:typed_data';

import 'package:aurora/services/reticulum/rns_announce.dart';
import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/reticulum/rns_tcp_server_interface.dart';
import 'package:aurora/services/reticulum/rns_transport.dart';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 4242;

  final id = await RnsIdentity.generate();
  final transport =
      RnsTransport(transportId: id.hash, log: (m) => print('  [transport] $m'));
  print('HUB_IDENTITY ${id.hexHash}');
  print('HUB_DEST ${_hx(RnsDestination.hash(id, "aurora", ["chat"]))}');

  Future<void> onPacket(Uint8List raw, String via) async {
    final p = RnsPacket.parse(raw);
    if (p == null) return;
    final ann = await transport.ingest(p, via);
    if (ann == null) return;
    if (ann.identity.hexHash == id.hexHash) return;
    final text = utf8.decode(ann.appData, allowMalformed: true);
    print('HUB_RX from=${ann.identity.hexHash} via=$via text="$text"');
  }

  final server = RnsTcpServerInterface(
    port: port,
    transport: transport,
    onPacket: onPacket,
    log: (m) => print('  [tcps] $m'),
  );
  await server.bind();
  print('HUB listening on 0.0.0.0:$port');

  Future<void> announce(String text) async {
    final pkt = await RnsAnnounceBuilder.build(id, 'aurora', ['chat'],
        appData: Uint8List.fromList(utf8.encode(text)));
    transport.sendOnAll(pkt.pack());
    print('HUB_TX announced "$text" (conns=${server.connectionCount})');
  }

  // Announce periodically so newly-connected phones learn the hub too.
  var tick = 0;
  await announce('linux-hub-online');
  await for (final _ in Stream.periodic(const Duration(seconds: 8))) {
    tick++;
    await announce('linux-hub tick $tick');
    print('HUB_STATUS conns=${server.connectionCount} paths=${transport.pathCount}');
  }
}

String _hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
