// LIVE end-to-end experiment for the DECENTRALIZED WAPP STORE over a real rnsd.
// Mirrors update_net_test.dart but for the wapp catalog: a publisher owns a
// signed mutable folder holding an `index.json` catalog plus the .wapp packages
// it lists; a consumer (separate identity) browses the folder over Reticulum,
// reads the catalog, maps each entry's filename to the content sha (exactly what
// the host's _fetchIndexFromRns does), then fetches the chosen .wapp by sha over
// a Reticulum link and verifies sha256(bytes) == the folder entry hash (what
// _installWappFromRns + folderFetchBytes do before installFromBytes runs).
//
//   dart run tool/wapp_store_net_test.dart [port]
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'package:aurora/services/folders/folder_keystore.dart';
import 'package:aurora/services/folders/folder_service.dart';
import 'package:aurora/services/reticulum/rns_announce.dart';
import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/reticulum/rns_tcp_interface.dart';
import 'package:aurora/services/reticulum/rns_transport.dart';
import 'package:aurora/services/social/relay_event_store.dart';
import 'package:aurora/services/social/relay_node.dart';
import 'package:aurora/services/files/file_node.dart';
import 'package:aurora/services/files/file_transfer.dart';

import 'sqlite_loader.dart';

const _rnsd = '/home/brito/.platformio/penv/bin/rnsd';

Future<Process> _startRnsd(String cfg, int port) async {
  await Directory(cfg).create(recursive: true);
  await File('$cfg/config').writeAsString('''
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
  final p = await Process.start(_rnsd, ['--config', cfg, '-v']);
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

String _hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List _hexToBytes(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

class _Node {
  final RnsIdentity id;
  final RnsTransport transport;
  final _Ser ser = _Ser();
  late final RelayEventStore store;
  late final RelayNode relay;
  late final RnsTcpInterface uplink;
  FileTransferNode? files;
  _Node(this.id) : transport = RnsTransport(transportId: id.hash) {
    store = RelayEventStore.open(':memory:');
    relay = RelayNode(
      identity: id,
      store: store,
      send: transport.sendOnAll,
      nextHopFor: (peer) => transport.nextHopForIdentity(peer),
    );
  }
  void enableFiles(FileSource source) {
    files = FileTransferNode(
      identity: id,
      source: source,
      send: transport.sendOnAll,
      nextHopFor: (peer) => transport.nextHopForIdentity(peer),
      log: (_) {},
    );
  }

  Future<void> connect(int port) async {
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
          ser.run(() async {
            if (await files?.handlePacket(p) ?? false) return;
            await relay.handlePacket(p);
          });
        }
      },
    );
    await uplink.connect();
    transport.addInterface(uplink);
  }

  Future<void> announceRelay() async {
    final pkt = await RnsAnnounceBuilder.build(id, kRelayApp, kRelayAspects,
        appData: Uint8List.fromList('indexer'.codeUnits));
    transport.sendOnAll(pkt.pack());
  }

  Future<void> announceFiles() async {
    final pkt = await RnsAnnounceBuilder.build(id, kFilesApp, kFilesAspects,
        appData: Uint8List.fromList('provider'.codeUnits));
    transport.sendOnAll(pkt.pack());
  }
}

int _pass = 0, _fail = 0;
void check(String name, bool ok) {
  if (ok) {
    _pass++;
    stdout.writeln('  ok   $name');
  } else {
    _fail++;
    stdout.writeln('  FAIL $name');
  }
}

Future<bool> _until(bool Function() c, {int tries = 60}) async {
  for (var i = 0; i < tries; i++) {
    if (c()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return c();
}

Uint8List _blob(int size, int seed) {
  final b = Uint8List(size);
  for (var i = 0; i < size; i++) {
    b[i] = (i * 73 + seed * 17 + 11) & 0xff;
  }
  return b;
}

Future<void> main(List<String> args) async {
  ensureSqlite();
  final port = args.isNotEmpty ? int.parse(args[0]) : 5590;
  final rnsd = await _startRnsd('/tmp/rnsd_wappstore_test', port);
  await Future<void>.delayed(const Duration(seconds: 3));

  _Node? b, p, c;
  try {
    b = _Node(await RnsIdentity.generate()); // indexer
    p = _Node(await RnsIdentity.generate()); // publisher (store owner)
    c = _Node(await RnsIdentity.generate()); // consumer (the app's store)

    // Two real .wapp packages + an index.json catalog (same shape the HTTP
    // store consumes).
    final helloWapp = _blob(40000, 1);
    final mapsWapp = _blob(70000, 2);
    final shHello = _hx(crypto.sha256.convert(helloWapp).bytes);
    final shMaps = _hx(crypto.sha256.convert(mapsWapp).bytes);
    final indexJson = utf8.encode(jsonEncode([
      {
        'name': 'hello',
        'version': '1.0.0',
        'file': 'hello-1.0.0.wapp',
        'description': 'Hello world wapp',
      },
      {
        'name': 'maps',
        'version': '2.1.0',
        'file': 'maps-2.1.0.wapp',
        'description': 'Offline maps',
      },
    ]));
    final shIndex = _hx(crypto.sha256.convert(indexJson).bytes);

    final src = MemoryFileSource()
      ..add(helloWapp)
      ..add(mapsWapp)
      ..add(Uint8List.fromList(indexJson));
    p.enableFiles(src);
    c.enableFiles(MemoryFileSource());

    await b.connect(port);
    await p.connect(port);
    await c.connect(port);
    await Future<void>.delayed(const Duration(seconds: 1));

    final bTimer = Timer.periodic(
        const Duration(milliseconds: 600), (_) => b!.announceRelay());
    final pTimer = Timer.periodic(
        const Duration(milliseconds: 600), (_) => p!.announceFiles());

    RnsIdentity? bFromP, bFromC, pFromC;
    await _until(() {
      for (final e in p!.transport.paths) {
        if (e.nextHop != null && _hx(e.identity.hash) == _hx(b!.id.hash)) {
          bFromP = e.identity;
        }
      }
      for (final e in c!.transport.paths) {
        if (e.nextHop == null) continue;
        if (_hx(e.identity.hash) == _hx(b!.id.hash)) bFromC = e.identity;
        if (_hx(e.identity.hash) == _hx(p!.id.hash)) pFromC = e.identity;
      }
      return bFromP != null && bFromC != null && pFromC != null;
    });
    check('consumer learned indexer + provider over the wire',
        bFromP != null && bFromC != null && pFromC != null);
    if (bFromP == null || bFromC == null || pFromC == null) {
      bTimer.cancel();
      pTimer.cancel();
      throw 'discovery failed';
    }

    var clk = 1700000000;

    // ── PUBLISHER: a signed folder with the catalog + the two packages. ──
    final owner = FolderService(
      keystore: FolderKeystore.open(':memory:'),
      publish: (e) => p!.relay.publish(bFromP!, e),
      query: (f) => p!.relay.query(bFromP!, f),
      adminPrivHex: () => null,
      nowSec: () => clk,
    );
    final fid = await owner.createFolder(name: 'Aurora wapp store');
    clk += 5;
    await owner.addFile(fid, shIndex, name: 'index.json', size: indexJson.length);
    clk += 5;
    await owner.addFile(fid, shHello,
        name: 'hello-1.0.0.wapp', size: helloWapp.length);
    clk += 5;
    await owner.addFile(fid, shMaps,
        name: 'maps-2.1.0.wapp', size: mapsWapp.length);
    clk += 5;
    stdout.writeln('publisher created store folder $fid (index + 2 wapps)');

    // ── CONSUMER: browse + resolve the catalog (host _fetchIndexFromRns). ──
    final app = FolderService(
      keystore: FolderKeystore.open(':memory:'),
      publish: (e) => c!.relay.publish(bFromC!, e),
      query: (f) => c!.relay.query(bFromC!, f),
      adminPrivHex: () => null,
      nowSec: () => clk,
    );
    final state = await app.browse(fid);
    final stateJson = state.toJson();
    final files = (stateJson['files'] as List?) ?? const [];
    check('consumer browsed the signed store folder', files.length == 3);

    // Index folder by leaf filename -> sha (the host's byBasename map).
    final byBasename = <String, String>{};
    String? indexSha;
    for (final f in files) {
      if (f is! Map) continue;
      final name = (f['name'] ?? '').toString();
      final sha = (f['x'] ?? '').toString();
      final base = name.split('/').last;
      byBasename[base] = sha;
      if (base == 'index.json') indexSha = sha;
    }
    check('catalog file (index.json) present in folder', indexSha != null);

    // Fetch + parse the catalog over Reticulum.
    final idxBytes =
        await c!.files!.fetch(_hexToBytes(indexSha!), pFromC!,
            timeout: const Duration(seconds: 30));
    check('fetched index.json over a real Reticulum link', idxBytes != null);
    check('index.json integrity (sha matches)',
        idxBytes != null && _hx(crypto.sha256.convert(idxBytes).bytes) == indexSha);
    final catalog = jsonDecode(utf8.decode(idxBytes!)) as List;

    // Enrich: rewrite each entry's `file` to the content sha (host behaviour).
    final enriched = <Map<String, dynamic>>[];
    for (final e in catalog) {
      final entry = Map<String, dynamic>.from(e as Map);
      final base = (entry['file'] ?? '').toString().split('/').last;
      entry['file'] = byBasename[base];
      enriched.add(entry);
    }
    check('catalog parsed with 2 wapps', enriched.length == 2);
    check('hello entry resolved to its sha',
        enriched.firstWhere((e) => e['name'] == 'hello')['file'] == shHello);
    check('maps entry resolved to its sha',
        enriched.firstWhere((e) => e['name'] == 'maps')['file'] == shMaps);

    // ── CONSUMER: install "maps" — fetch the .wapp by sha + verify. ──
    final mapsEntry = enriched.firstWhere((e) => e['name'] == 'maps');
    final wappSha = mapsEntry['file'] as String;
    final wappBytes = await c.files!
        .fetch(_hexToBytes(wappSha), pFromC!, timeout: const Duration(seconds: 40));
    check('fetched the .wapp package over Reticulum', wappBytes != null);
    if (wappBytes != null) {
      check('downloaded size matches the folder entry',
          wappBytes.length == mapsWapp.length);
      check('sha256(.wapp) == folder entry hash (verified before install)',
          _hx(crypto.sha256.convert(wappBytes).bytes) == wappSha);
    }

    // Negative control: a .wapp the publisher doesn't hold is not fetchable.
    final bogus = _hx(crypto.sha256.convert(_blob(500, 99)).bytes);
    final none = await c.files!
        .fetch(_hexToBytes(bogus), pFromC!, timeout: const Duration(seconds: 8));
    check('unknown package is not fetchable (no false positive)', none == null);

    bTimer.cancel();
    pTimer.cancel();
  } catch (e, s) {
    stderr.writeln('ERROR: $e\n$s');
    _fail++;
  } finally {
    b?.store.close();
    p?.store.close();
    c?.store.close();
    rnsd.kill(ProcessSignal.sigterm);
  }

  stdout.writeln('\n$_pass passed, $_fail failed');
  exit(_fail == 0 ? 0 : 1);
}
