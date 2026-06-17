// LXMF DELIVERY over a real rnsd: two leaf nodes (different "networks", reachable
// only through rnsd) each register an LXMF delivery destination; node A sends an
// LXMF message to node B, which receives, verifies the signature, and reads it.
// Exercises the LxmfRouter over transport-addressed links through rnsd.
//
//   dart run tool/lxmf_delivery_test.dart [port] [content_len]
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/reticulum/rns_announce.dart';
import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/reticulum/rns_tcp_interface.dart';
import 'package:aurora/services/reticulum/rns_transport.dart';
import 'package:aurora/services/reticulum/lxmf/lxmf.dart';
import 'package:aurora/services/reticulum/lxmf/lxmf_message.dart';
import 'package:aurora/services/reticulum/lxmf/lxmf_router.dart';

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

class _Node {
  final RnsIdentity id;
  final RnsTransport transport = RnsTransport();
  late final LxmfRouter router;
  late final RnsTcpInterface uplink;
  final _Ser ser = _Ser();
  LxmfMessage? received;
  final Completer<LxmfMessage> gotMsg = Completer<LxmfMessage>();
  _Node(this.id);

  Future<void> connect(int port) async {
    router = LxmfRouter(
      identity: id,
      send: transport.sendOnAll,
      nextHopFor: (peer) => transport.nextHopForIdentity(peer),
      identityForDest: (h) => transport.pathFor(h)?.identity,
      onMessage: (m) {
        received = m;
        if (!gotMsg.isCompleted) gotMsg.complete(m);
      },
    );
    uplink = RnsTcpInterface(
      host: '127.0.0.1',
      port: port,
      label: 'rnsd',
      onPacket: (raw) {
        final p = RnsPacket.parse(raw);
        if (p == null) return;
        if (p.packetType == RnsPacketType.announce) {
          ser.run(() async => transport.ingest(p, 'rnsd'));
        } else {
          ser.run(() => router.handlePacket(p));
        }
      },
    );
    await uplink.connect();
    transport.addInterface(uplink);
  }

  Future<void> announce() async {
    final pkt = await RnsAnnounceBuilder.build(id, kLxmfApp, kLxmfDeliveryAspects,
        appData: Uint8List.fromList('lxmf-node'.codeUnits));
    transport.sendOnAll(pkt.pack());
  }
}

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 5500;
  final contentLen = args.length > 1 ? int.parse(args[1]) : 40;
  final content = 'lxmf:${List.filled(contentLen, 'x').join()}';
  final cfg = '/tmp/rnsd_lxmf_test';

  final rnsd = await _startRnsd(cfg, port);
  await Future<void>.delayed(const Duration(seconds: 3));

  var ok = false;
  try {
    final a = _Node(await RnsIdentity.generate());
    final b = _Node(await RnsIdentity.generate());
    await a.connect(port);
    await b.connect(port);
    await Future<void>.delayed(const Duration(seconds: 1));

    // Announce until A has a transported path to B's LXMF delivery dest.
    Uint8List? bDest;
    for (var i = 0; i < 40; i++) {
      await a.announce();
      await b.announce();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      for (final e in a.transport.paths) {
        if (_hx(e.identity.hash) != _hx(a.id.hash) && e.nextHop != null) {
          bDest = e.destHash;
          break;
        }
      }
      if (bDest != null) break;
    }
    if (bDest == null) {
      stderr.writeln('FAIL: A never learned B\'s LXMF dest via rnsd');
    } else {
      final msg = await LxmfMessage.create(
        destinationHash: bDest,
        source: a.id,
        title: 'hi',
        content: content,
      );
      stdout.writeln('A sending LXMF (${msg.packed.length}B) to B through rnsd...');
      final sent = await a.router.send_(msg, timeout: const Duration(seconds: 30));
      if (!sent) {
        stderr.writeln('FAIL: send_ returned false');
      } else {
        final got = await b.gotMsg.future.timeout(const Duration(seconds: 10),
            onTimeout: () => throw 'no message at B');
        if (got.contentString == content && got.titleString == 'hi') {
          stdout.writeln('OK LXMF delivery: B received + verified '
              '"${got.contentString.substring(0, 12)}..." (${msg.packed.length}B)');
          ok = true;
        } else {
          stderr.writeln('FAIL: content mismatch at B');
        }
      }
    }
  } catch (e) {
    stderr.writeln('FAIL: $e');
  } finally {
    rnsd.kill(ProcessSignal.sigterm);
  }
  exit(ok ? 0 : 1);
}
