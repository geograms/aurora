// LIVE two-node file fetch over real TCP sockets (no Python). Node B binds a TCP
// server and serves a file from memory; node A connects, learns B's identity from
// an announce, opens a Reticulum link to B's "files" destination, and fetches the
// file by sha256 — exercising the real wire path (HDLC framing, packet codec,
// link handshake, multi-chunk Resource transfer) end to end.
//
//   dart run tool/reticulum_file_tcp_test.dart [port] [file_bytes]
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

void _expect(bool c, String what) {
  if (!c) {
    stderr.writeln('FAIL: $what');
    exit(1);
  }
}

/// Serialize async packet handling per node so concurrent socket callbacks don't
/// interleave the link/fetch state machines.
class _Serializer {
  Future<void> _chain = Future.value();
  void run(Future<void> Function() fn) {
    _chain = _chain.then((_) => fn()).catchError((e) {
      stderr.writeln('dispatch error: $e');
    });
  }
}

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 4252;
  final size = args.length > 1 ? int.parse(args[1]) : 120000; // ~4 chunks
  final file = Uint8List(size);
  for (var i = 0; i < size; i++) {
    file[i] = (i * 73 + 11) & 0xff;
  }
  final wantSha = crypto.sha256.convert(file).bytes;

  // ── Provider (B): TCP server + files node serving the file from memory. ──
  final idB = await RnsIdentity.generate();
  final transportB = RnsTransport(transportId: idB.hash);
  final serB = _Serializer();
  late final FileTransferNode nodeB;
  final server = RnsTcpServerInterface(
    port: port,
    transport: transportB,
    onPacket: (raw, via) {
      final p = RnsPacket.parse(raw);
      if (p == null) return;
      if (p.packetType == RnsPacketType.announce) {
        serB.run(() async => transportB.ingest(p, via));
      } else {
        serB.run(() => nodeB.handlePacket(p));
      }
    },
  );
  await server.bind();
  nodeB = FileTransferNode(
    identity: idB,
    source: MemoryFileSource()..add(file),
    send: transportB.sendOnAll,
    log: (m) => stdout.writeln('B $m'),
  );

  // ── Fetcher (A): TCP client + files node; learns B from an announce. ──
  final idA = await RnsIdentity.generate();
  final transportA = RnsTransport(transportId: idA.hash);
  final serA = _Serializer();
  final learned = Completer<RnsIdentity>();
  late final FileTransferNode nodeA;
  final client = RnsTcpInterface(
    host: '127.0.0.1',
    port: port,
    label: 'tcp',
    onPacket: (raw) {
      final p = RnsPacket.parse(raw);
      if (p == null) return;
      if (p.packetType == RnsPacketType.announce) {
        serA.run(() async {
          final ann = await transportA.ingest(p, 'tcp');
          if (ann != null && !learned.isCompleted) learned.complete(ann.identity);
        });
      } else {
        serA.run(() => nodeA.handlePacket(p));
      }
    },
  );
  await client.connect();
  transportA.addInterface(client);
  nodeA = FileTransferNode(
    identity: idA,
    source: MemoryFileSource(),
    send: transportA.sendOnAll,
    log: (m) => stdout.writeln('A $m'),
  );

  // B announces its files destination until A learns the identity.
  RnsIdentity? provider;
  for (var i = 0; i < 25; i++) {
    if (learned.isCompleted) {
      provider = await learned.future;
      break;
    }
    final ann = await RnsAnnounceBuilder.build(
      idB, kFilesApp, kFilesAspects,
      appData: Uint8List.fromList('provider'.codeUnits));
    transportB.sendOnAll(ann.pack());
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  _expect(provider != null, 'A learned provider identity from announce');

  // A fetches the file by sha256 from B over the real link.
  final got = await nodeA.fetch(Uint8List.fromList(wantSha), provider!,
      timeout: const Duration(seconds: 30));
  _expect(got != null, 'fetch returned bytes');
  final gotSha = crypto.sha256.convert(got!).bytes;
  _expect(_hx(gotSha) == _hx(wantSha), 'fetched sha256 matches');

  stdout.writeln('OK live TCP fetch: $size bytes, sha256=${_hx(gotSha)}');
  await server.close();
  await client.close();
  exit(0);
}
