// MULTI-HOP over a real Reticulum transport node (rnsd): two leaf nodes connect
// ONLY to a public-style rnsd (no direct link between them, like two phones on
// different networks). One serves a file; the other learns it via a relayed
// announce and fetches it THROUGH rnsd. Proves transport-addressed links +
// resource transfer route across the Reticulum network.
//
//   dart run tool/reticulum_internet_test.dart [port] [file_bytes]
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'package:aurora/services/reticulum/rns_announce.dart';
import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/reticulum/rns_tcp_interface.dart';
import 'package:aurora/services/reticulum/rns_transport.dart';
import 'package:aurora/services/files/file_node.dart';
import 'package:aurora/services/files/file_transfer.dart';

String _hx(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

const _rnsd = '/home/brito/.platformio/penv/bin/rnsd';

Future<Process> _startRnsd(String cfgDir, int port) async {
  await Directory(cfgDir).create(recursive: true);
  await File('$cfgDir/config').writeAsString('''
[reticulum]
  enable_transport = True
  share_instance = No
  panic_on_interface_error = No

[logging]
  loglevel = 3

[interfaces]
  [[TCPServer]]
    type = TCPServerInterface
    enabled = True
    listen_ip = 127.0.0.1
    listen_port = $port
''');
  final p = await Process.start(_rnsd, ['--config', cfgDir, '-v']);
  p.stdout.listen((_) {});
  p.stderr.listen((_) {});
  return p;
}

class _Ser {
  Future<void> _c = Future.value();
  void run(Future<void> Function() f) {
    _c = _c.then((_) => f()).catchError((e) => stderr.writeln('disp: $e'));
  }
}

/// A leaf node: own transport (NOT a transport node), one TCP uplink to rnsd.
class _Leaf {
  final RnsIdentity id;
  final RnsTransport transport;
  late final FileTransferNode node;
  late final RnsTcpInterface uplink;
  final _ser = _Ser();

  _Leaf(this.id) : transport = RnsTransport();

  Future<void> connect(int port, FileSource source) async {
    node = FileTransferNode(
      identity: id,
      source: source,
      send: transport.sendOnAll,
      nextHopFor: (peer) => transport.nextHopForIdentity(peer),
      log: (m) => stdout.writeln('${_hx(id.hash).substring(0, 6)} $m'),
    );
    uplink = RnsTcpInterface(
      host: '127.0.0.1',
      port: port,
      label: 'rnsd',
      onPacket: (raw) {
        final p = RnsPacket.parse(raw);
        if (p == null) return;
        if (p.packetType == RnsPacketType.announce) {
          _ser.run(() async => transport.ingest(p, 'rnsd'));
        } else {
          _ser.run(() => node.handlePacket(p));
        }
      },
    );
    await uplink.connect();
    transport.addInterface(uplink);
  }

  Future<void> announceFiles() async {
    final pkt = await RnsAnnounceBuilder.build(id, kFilesApp, kFilesAspects,
        appData: Uint8List.fromList('node'.codeUnits));
    transport.sendOnAll(pkt.pack());
  }
}

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 5252;
  final size = args.length > 1 ? int.parse(args[1]) : 150000;
  final cfg = '/tmp/rnsd_aurora_test';
  final file = Uint8List(size);
  for (var i = 0; i < size; i++) {
    file[i] = (i * 53 + 9) & 0xff;
  }
  final sha = Uint8List.fromList(crypto.sha256.convert(file).bytes);

  stdout.writeln('starting rnsd transport node on :$port ...');
  final rnsd = await _startRnsd(cfg, port);
  await Future<void>.delayed(const Duration(seconds: 3));

  var ok = false;
  try {
    final a = _Leaf(await RnsIdentity.generate()); // provider
    final b = _Leaf(await RnsIdentity.generate()); // fetcher
    await a.connect(port, MemoryFileSource()..add(file));
    await b.connect(port, const EmptyFileSource());
    await Future<void>.delayed(const Duration(seconds: 1));

    // Announce until B has a TRANSPORTED path to A (nextHop via rnsd).
    RnsIdentity? provider;
    for (var i = 0; i < 40; i++) {
      await a.announceFiles();
      await b.announceFiles();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      for (final e in b.transport.paths) {
        if (_hx(e.identity.hash) != _hx(b.id.hash) && e.nextHop != null) {
          provider = e.identity;
          break;
        }
      }
      if (provider != null) break;
    }
    if (provider == null) {
      stderr.writeln('FAIL: B never learned a transported path to A');
    } else {
      stdout.writeln('B learned provider via rnsd (nextHop set); fetching...');
      final got = await b.node
          .fetch(sha, provider, timeout: const Duration(seconds: 40));
      if (got == null) {
        stderr.writeln('FAIL: fetch returned null (multi-hop route failed)');
      } else if (_hx(crypto.sha256.convert(got).bytes) != _hx(sha)) {
        stderr.writeln('FAIL: fetched bytes sha mismatch');
      } else {
        stdout.writeln('OK internet/multi-hop fetch: $size bytes through rnsd, '
            'sha=${_hx(sha).substring(0, 12)}');
        ok = true;
      }
    }
  } finally {
    rnsd.kill(ProcessSignal.sigterm);
  }
  exit(ok ? 0 : 1);
}
