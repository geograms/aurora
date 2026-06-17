// Multi-transport CHAIN: leaf A -- hub1 -- hub2 -- leaf B. A and B connect to
// different hubs; the hubs are linked, so a transfer must traverse TWO Dart
// transport nodes in series. Proves link + resource forwarding generalises to
// arbitrary transport chains (not just leaf-hub-leaf).
//
//   dart run tool/reticulum_chain_test.dart [port1] [port2] [bytes]
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

/// A Dart transport hub: a TCP server (clients become interfaces) and, optionally,
/// an outbound uplink to another hub.
class _Hub {
  final RnsTransport transport;
  final _Ser ser = _Ser();
  late final RnsTcpServerInterface server;
  RnsTcpInterface? uplink;
  _Hub(RnsIdentity id) : transport = RnsTransport(transportId: id.hash);

  Future<void> bind(int port) async {
    server = RnsTcpServerInterface(
      port: port,
      transport: transport,
      onPacket: (raw, via) {
        final p = RnsPacket.parse(raw);
        if (p != null) ser.run(() async => transport.ingest(p, via));
      },
    );
    await server.bind();
  }

  Future<void> connectUplink(int port) async {
    final c = RnsTcpInterface(
      host: '127.0.0.1',
      port: port,
      label: 'uplink',
      onPacket: (raw) {
        final p = RnsPacket.parse(raw);
        if (p != null) ser.run(() async => transport.ingest(p, 'uplink'));
      },
    );
    await c.connect();
    transport.addInterface(c);
    uplink = c;
  }
}

class _Leaf {
  final RnsIdentity id;
  final RnsTransport transport = RnsTransport();
  late final FileTransferNode node;
  late final RnsTcpInterface uplink;
  final _Ser ser = _Ser();
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
      label: 'up',
      onPacket: (raw) {
        final p = RnsPacket.parse(raw);
        if (p == null) return;
        if (p.packetType == RnsPacketType.announce) {
          ser.run(() async => transport.ingest(p, 'up'));
        } else {
          ser.run(() => node.handlePacket(p));
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
  final hubCount = args.isNotEmpty ? int.parse(args[0]) : 2;
  final basePort = args.length > 1 ? int.parse(args[1]) : 5400;
  final size = args.length > 2 ? int.parse(args[2]) : 250000;
  final file = Uint8List(size);
  for (var i = 0; i < size; i++) {
    file[i] = (i * 41 + 7) & 0xff;
  }
  final sha = Uint8List.fromList(crypto.sha256.convert(file).bytes);

  // Build a line of hubs: hub[0] is the root; hub[i] uplinks to hub[i-1].
  final hubs = <_Hub>[];
  for (var i = 0; i < hubCount; i++) {
    final h = _Hub(await RnsIdentity.generate());
    await h.bind(basePort + i);
    if (i > 0) await h.connectUplink(basePort + i - 1);
    hubs.add(h);
  }
  stdout.writeln('chain of $hubCount Dart transports built');

  // A at one end, B at the other -> a transfer must cross every hub.
  final a = _Leaf(await RnsIdentity.generate()); // provider, on hub[0]
  final b = _Leaf(await RnsIdentity.generate()); // fetcher, on hub[last]
  await a.connect(basePort, MemoryFileSource()..add(file));
  await b.connect(basePort + hubCount - 1, const EmptyFileSource());
  await Future<void>.delayed(const Duration(milliseconds: 500));

  RnsIdentity? provider;
  for (var i = 0; i < 40; i++) {
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

  var ok = false;
  if (provider == null) {
    stderr.writeln('FAIL: B never learned A across the 2-hub chain');
  } else {
    stdout.writeln('B learned A across $hubCount hubs; fetching through the chain...');
    final got =
        await b.node.fetch(sha, provider, timeout: const Duration(seconds: 45));
    if (got != null && _hx(crypto.sha256.convert(got).bytes) == _hx(sha)) {
      stdout.writeln('OK chain forwarding: $size bytes across $hubCount Dart '
          'transports, sha=${_hx(sha).substring(0, 12)}');
      ok = true;
    } else {
      stderr.writeln('FAIL: fetch across the chain failed');
    }
  }

  await a.uplink.close();
  await b.uplink.close();
  for (final h in hubs) {
    await h.uplink?.close();
    await h.server.close();
  }
  exit(ok ? 0 : 1);
}
