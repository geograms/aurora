// Proves a DART node is a full forwarding transport (not just announces): a Dart
// hub (transport node, TCP server) bridges two leaf nodes that connect only to it
// and have no direct link. One serves a file; the other learns it via a relayed
// announce and fetches it THROUGH the Dart hub — link handshake + resource all
// forwarded by our own transport. (Same role rnsd played, now in pure Dart.)
//
//   dart run tool/reticulum_hub_test.dart [port] [file_bytes]
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'package:aurora/services/reticulum/rns_announce.dart';
import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/reticulum/rns_tcp_interface.dart';
import 'package:aurora/services/reticulum/rns_tcp_server_interface.dart';
import 'package:aurora/services/reticulum/rns_transport.dart';
import 'package:aurora/services/files/file_node.dart';
import 'package:aurora/services/files/file_transfer.dart';

String _hx(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

class _Ser {
  Future<void> _c = Future.value();
  void run(Future<void> Function() f) {
    _c = _c.then((_) => f()).catchError((e) => stderr.writeln('disp: $e'));
  }
}

class _Leaf {
  final RnsIdentity id;
  final RnsTransport transport = RnsTransport(); // pure leaf (no forwarding)
  late final FileTransferNode node;
  late final RnsTcpInterface uplink;
  final _ser = _Ser();
  _Leaf(this.id);

  Future<void> connect(int port, FileSource source) async {
    node = FileTransferNode(
      identity: id,
      source: source,
      send: transport.sendOnAll,
      nextHopFor: (peer) => transport.nextHopForIdentity(peer),
    );
    uplink = RnsTcpInterface(
      host: '127.0.0.1',
      port: port,
      label: 'hub',
      onPacket: (raw) {
        final p = RnsPacket.parse(raw);
        if (p == null) return;
        if (p.packetType == RnsPacketType.announce) {
          _ser.run(() async => transport.ingest(p, 'hub'));
        } else {
          _ser.run(() => node.handlePacket(p));
        }
      },
    );
    await uplink.connect();
    transport.addInterface(uplink);
  }

  Future<void> announce() async {
    final pkt = await RnsAnnounceBuilder.build(id, kFilesApp, kFilesAspects,
        appData: Uint8List.fromList('n'.codeUnits));
    transport.sendOnAll(pkt.pack());
  }
}

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 5300;
  final size = args.length > 1 ? int.parse(args[1]) : 200000;
  final file = Uint8List(size);
  for (var i = 0; i < size; i++) {
    file[i] = (i * 29 + 3) & 0xff;
  }
  final sha = Uint8List.fromList(crypto.sha256.convert(file).bytes);

  // The Dart HUB: a transport node with a TCP server (each client = an interface).
  final hubId = await RnsIdentity.generate();
  final hub = RnsTransport(transportId: hubId.hash);
  final hubSer = _Ser();
  final server = RnsTcpServerInterface(
    port: port,
    transport: hub,
    onPacket: (raw, via) {
      final p = RnsPacket.parse(raw);
      if (p == null) return;
      hubSer.run(() async => hub.ingest(p, via)); // ingest forwards + rebroadcasts
    },
  );
  await server.bind();

  var ok = false;
  final a = _Leaf(await RnsIdentity.generate());
  final b = _Leaf(await RnsIdentity.generate());
  await a.connect(port, MemoryFileSource()..add(file));
  await b.connect(port, const EmptyFileSource());
  await Future<void>.delayed(const Duration(milliseconds: 500));

  RnsIdentity? provider;
  for (var i = 0; i < 30; i++) {
    await a.announce();
    await b.announce();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    for (final e in b.transport.paths) {
      if (_hx(e.identity.hash) != _hx(b.id.hash) && e.nextHop != null) {
        provider = e.identity;
        break;
      }
    }
    if (provider != null) break;
  }

  if (provider == null) {
    stderr.writeln('FAIL: B never learned a transported path via the Dart hub');
  } else {
    stdout.writeln('B learned A via the Dart hub; fetching through it...');
    final got =
        await b.node.fetch(sha, provider, timeout: const Duration(seconds: 40));
    if (got != null && _hx(crypto.sha256.convert(got).bytes) == _hx(sha)) {
      stdout.writeln('OK Dart-hub forwarding: $size bytes through a Dart '
          'transport, sha=${_hx(sha).substring(0, 12)}');
      ok = true;
    } else {
      stderr.writeln('FAIL: fetch through Dart hub failed');
    }
  }

  await server.close();
  await a.uplink.close();
  await b.uplink.close();
  exit(ok ? 0 : 1);
}
