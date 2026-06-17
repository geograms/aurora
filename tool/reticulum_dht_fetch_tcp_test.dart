// LIVE end-to-end over real TCP: two nodes with the DHT enabled. B holds a file
// and publishes a signed provider record into the DHT; A learns B from an
// announce, RESOLVES the file's providers over real Reticulum links, FETCHES the
// bytes from B, then AUTO-SEEDS (publishes its own provider record). Proves the
// DHT-over-links binding + the resolve->fetch->auto-seed loop.
//
//   dart run tool/reticulum_dht_fetch_tcp_test.dart [port] [file_bytes]
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
import 'package:aurora/services/files/dht/provider_record.dart';
import 'package:aurora/services/files/file_node.dart';
import 'package:aurora/services/files/file_transfer.dart';

String _hx(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void _expect(bool c, String what) {
  if (!c) {
    stderr.writeln('FAIL: $what');
    exit(1);
  }
}

class _Serializer {
  Future<void> _chain = Future.value();
  void run(Future<void> Function() fn) {
    _chain = _chain.then((_) => fn()).catchError((e) {
      stderr.writeln('dispatch error: $e');
    });
  }
}

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 4281;
  final size = args.length > 1 ? int.parse(args[1]) : 150000; // ~5 chunks
  final file = Uint8List(size);
  for (var i = 0; i < size; i++) {
    file[i] = (i * 91 + 13) & 0xff;
  }
  final sha = Uint8List.fromList(crypto.sha256.convert(file).bytes);

  // Provider B: TCP server, holds the file, DHT enabled.
  final idB = await RnsIdentity.generate();
  final transportB = RnsTransport(transportId: idB.hash);
  final serB = _Serializer();
  final bSource = MemoryFileSource()..add(file);
  late final FileTransferNode nodeB;
  final server = RnsTcpServerInterface(
    port: port,
    transport: transportB,
    onPacket: (raw, via) {
      final p = RnsPacket.parse(raw);
      if (p == null) return;
      if (p.packetType == RnsPacketType.announce) {
        serB.run(() async {
          final ann = await transportB.ingest(p, via);
          if (ann != null) nodeB.addPeerFromAnnounce(ann.identity);
        });
      } else {
        serB.run(() => nodeB.handlePacket(p));
      }
    },
  );
  await server.bind();
  nodeB = FileTransferNode(
      identity: idB, source: bSource, send: transportB.sendOnAll, enableDht: true,
      log: (m) => stdout.writeln('B $m'));

  // Fetcher A: TCP client, starts with no content, DHT enabled.
  final idA = await RnsIdentity.generate();
  final transportA = RnsTransport(transportId: idA.hash);
  final serA = _Serializer();
  final aSource = MemoryFileSource();
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
          if (ann != null) nodeA.addPeerFromAnnounce(ann.identity);
        });
      } else {
        serA.run(() => nodeA.handlePacket(p));
      }
    },
  );
  await client.connect();
  transportA.addInterface(client);
  nodeA = FileTransferNode(
      identity: idA, source: aSource, send: transportA.sendOnAll, enableDht: true,
      log: (m) => stdout.writeln('A $m'));

  // Exchange announces until both DHTs know each other.
  for (var i = 0; i < 25; i++) {
    if (nodeA.dht!.routing.size > 0 && nodeB.dht!.routing.size > 0) break;
    transportB.sendOnAll((await RnsAnnounceBuilder.build(
            idB, kFilesApp, kFilesAspects,
            appData: Uint8List.fromList('B'.codeUnits)))
        .pack());
    transportA.sendOnAll((await RnsAnnounceBuilder.build(
            idA, kFilesApp, kFilesAspects,
            appData: Uint8List.fromList('A'.codeUnits)))
        .pack());
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  _expect(nodeA.dht!.routing.size > 0 && nodeB.dht!.routing.size > 0,
      'both DHTs learned a peer');

  // B publishes itself as a provider of the file.
  final pubB = await nodeB.publishProvider(sha, capacity: kCapHomeFiber);
  _expect(pubB >= 1, 'B published a provider record (holders=$pubB)');

  // A resolves the providers and fetches the bytes over real links.
  final got = await nodeA.resolveAndFetch(sha, timeout: const Duration(seconds: 30));
  _expect(got != null, 'A resolved + fetched the file');
  _expect(_hx(crypto.sha256.convert(got!).bytes) == _hx(sha), 'fetched sha matches');
  stdout.writeln('OK resolve+fetch: $size bytes, sha=${_hx(sha).substring(0, 12)}');

  // Auto-seed: A now holds the bytes, so it serves + publishes a provider record.
  aSource.add(got);
  final pubA = await nodeA.publishProvider(sha, capacity: kCapWifiTransient);
  _expect(pubA >= 1, 'A auto-seeded a provider record (holders=$pubA)');

  // Now the file resolves to BOTH providers, best class (B/home-fiber) first.
  final providers = await nodeB.dht!.resolve(sha);
  _expect(providers.length == 2, 'file now has 2 providers (got ${providers.length})');
  _expect(providers.first.capacity == kCapHomeFiber, 'best class ranked first');
  stdout.writeln('OK auto-seed: ${providers.length} providers, '
      'first cap=${providers.first.capacity}');

  stdout.writeln('ALL OK');
  await server.close();
  await client.close();
  exit(0);
}
