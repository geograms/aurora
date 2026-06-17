// LXMF INTEROP over rnsd: an Aurora Dart node and a reference python LXMF peer
// both connect to the same rnsd and exchange messages BOTH ways:
//   python LXMF -> Dart  (Dart verifies + delivers)
//   Dart        -> python LXMF (python prints PY_RECV)
// Proves on-wire interop with the Reticulum LXMF ecosystem (Sideband/NomadNet).
//
//   dart run tool/lxmf_interop_test.dart [port]
import 'dart:async';
import 'dart:convert';
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
const _py = '/home/brito/.platformio/penv/bin/python3';

Future<Process> _startRnsd(String cfg, int port) async {
  await Directory(cfg).create(recursive: true);
  await File('$cfg/config').writeAsString('''
[reticulum]
  enable_transport = True
  share_instance = No
  panic_on_interface_error = No
[logging]
  loglevel = 6
[interfaces]
  [[TCPServer]]
    type = TCPServerInterface
    enabled = True
    listen_ip = 127.0.0.1
    listen_port = $port
''');
  final p = await Process.start(_rnsd, ['--config', cfg, '-v']);
  final logf = File('/tmp/rnsd_hub.log').openWrite();
  p.stdout.transform(utf8.decoder).listen(logf.write);
  p.stderr.transform(utf8.decoder).listen(logf.write);
  return p;
}

class _Ser {
  Future<void> _c = Future.value();
  void run(Future<void> Function() f) {
    _c = _c.then((_) => f()).catchError((e) => stderr.writeln('disp: $e'));
  }
}

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 5550;
  final rnsdCfg = '/tmp/rnsd_lxmf_interop';
  final pyCfg = '/tmp/lxmf_pypeer';
  await Directory(pyCfg).create(recursive: true);
  final dartDestFile = File('$pyCfg/dart_dest.txt');
  if (dartDestFile.existsSync()) dartDestFile.deleteSync();

  final rnsd = await _startRnsd(rnsdCfg, port);
  await Future<void>.delayed(const Duration(seconds: 3));

  var dartRecvOk = false;
  var pyRecvOk = false;
  Process? py;
  try {
    // Aurora Dart node (leaf to rnsd) with an LXMF router.
    final id = await RnsIdentity.generate();
    final transport = RnsTransport();
    final ser = _Ser();
    final gotPy = Completer<LxmfMessage>();
    final router = LxmfRouter(
      identity: id,
      send: transport.sendOnAll,
      nextHopFor: (peer) => transport.nextHopForIdentity(peer),
      identityForDest: (h) => transport.pathFor(h)?.identity,
      onMessage: (m) {
        if (!gotPy.isCompleted) gotPy.complete(m);
      },
    );
    final uplink = RnsTcpInterface(
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
    final dartDest = _hx(router.deliveryDestHash);

    // Start the python LXMF peer.
    py = await Process.start(_py, ['tool/lxmf_peer.py', pyCfg, '$port']);
    final pyLines = StreamController<String>();
    py.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      stdout.writeln('  [py] $l');
      pyLines.add(l);
    });
    py.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      stdout.writeln('  [py.e] $l');
    });

    String? pyDest;
    final pySent = Completer<void>();
    pyLines.stream.listen((l) {
      if (l.startsWith('PY_DEST ')) pyDest = l.substring(8).trim();
      if (l.startsWith('PY_RECV ')) {
        if (l.contains('hello python from aurora')) pyRecvOk = true;
      }
      if (l.startsWith('PY_SENT') && !pySent.isCompleted) pySent.complete();
    });

    // Announce our LXMF delivery dest until python learns us, and tell python
    // our dest hash so it can send to us.
    final lxAnnounce = await RnsAnnounceBuilder.build(
        id, kLxmfApp, kLxmfDeliveryAspects,
        appData: Uint8List.fromList('aurora'.codeUnits));

    // Wait for python's dest, write ours for it.
    for (var i = 0; i < 30 && pyDest == null; i++) {
      transport.sendOnAll(lxAnnounce.pack());
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (pyDest == null) throw 'python never announced PY_DEST';
    await dartDestFile.writeAsString(dartDest);
    stdout.writeln('exchanged dests; dart=$dartDest py=$pyDest');

    // Keep announcing so rnsd has our path; wait for python -> Dart message.
    final pump = Timer.periodic(const Duration(milliseconds: 600),
        (_) => transport.sendOnAll(lxAnnounce.pack()));

    try {
      final m = await gotPy.future.timeout(const Duration(seconds: 40));
      if (m.contentString.contains('hello dart from python')) dartRecvOk = true;
      stdout.writeln('Dart received from python: "${m.contentString}"');
    } catch (_) {
      stderr.writeln('Dart did NOT receive python message in time');
    }

    // Dart -> python.
    final out = await LxmfMessage.create(
      destinationHash: Uint8List.fromList(_unhex(pyDest!)),
      source: id,
      title: 'aurora',
      content: 'hello python from aurora',
    );
    final sent = await router.send_(out, timeout: const Duration(seconds: 30));
    stdout.writeln('Dart->python send returned $sent');
    try {
      await pySent.future.timeout(const Duration(seconds: 5));
    } catch (_) {}
    // Give python a moment to print PY_RECV.
    await Future<void>.delayed(const Duration(seconds: 6));
    pump.cancel();
  } catch (e) {
    stderr.writeln('ERROR: $e');
  } finally {
    py?.kill(ProcessSignal.sigterm);
    rnsd.kill(ProcessSignal.sigterm);
  }

  stdout.writeln('RESULT python->Dart: ${dartRecvOk ? "OK" : "FAIL"}; '
      'Dart->python: ${pyRecvOk ? "OK" : "FAIL"}');
  exit(dartRecvOk && pyRecvOk ? 0 : 1);
}

List<int> _unhex(String h) =>
    [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];
