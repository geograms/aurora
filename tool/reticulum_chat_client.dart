// A headless RNS chat client: connect to a hub (TCP), announce "aurora.chat"
// messages, and print messages received from other nodes. Used to validate the
// LAN relay (hub + 2 clients) before testing on phones.
//
//   dart run tool/reticulum_chat_client.dart [host port name]
import 'dart:convert';
import 'dart:typed_data';

import 'package:aurora/services/reticulum/rns_announce.dart';
import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/reticulum/rns_tcp_interface.dart';
import 'package:aurora/services/reticulum/rns_transport.dart';

Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : '127.0.0.1';
  final port = args.length > 1 ? int.parse(args[1]) : 4242;
  final name = args.length > 2 ? args[2] : 'client';

  final id = await RnsIdentity.generate();
  final transport = RnsTransport(); // leaf node, no rebroadcast
  print('$name identity ${id.hexHash}');

  late RnsTcpInterface iface;
  iface = RnsTcpInterface(
    host: host,
    port: port,
    label: 'tcp',
    log: (m) => print('  [$name tcp] $m'),
    onPacket: (raw) async {
      final p = RnsPacket.parse(raw);
      if (p == null) return;
      final ann = await transport.ingest(p, 'tcp');
      if (ann == null || ann.identity.hexHash == id.hexHash) return;
      print('$name RX from=${ann.identity.hexHash} '
          'text="${utf8.decode(ann.appData, allowMalformed: true)}"');
    },
  );
  await iface.connect();
  transport.addInterface(iface);

  Future<void> announce(String text) async {
    final pkt = await RnsAnnounceBuilder.build(id, 'aurora', ['chat'],
        appData: Uint8List.fromList(utf8.encode(text)));
    iface.sendPacket(pkt.pack());
    print('$name TX "$text"');
  }

  await announce('$name online');
  var tick = 0;
  await for (final _ in Stream.periodic(const Duration(seconds: 6))) {
    tick++;
    await announce('$name msg $tick');
  }
}
