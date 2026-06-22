// LIVE end-to-end experiment for the DECENTRALIZED UPDATE mechanism over a real
// rnsd. Proves the whole concept on real Reticulum sockets — not the thin
// RnsService wrappers, but the actual moving parts they call:
//
//   Publisher (P) owns a signed mutable folder (the "beta" channel) holding real
//   release binaries named aurora-<version>-<platform>, and serves their bytes
//   from a FileTransferNode. An indexer (B) hosts the folder's signed op-log.
//   Consumer (C) — a separate identity — browses the folder over the network,
//   runs the SAME releasesFromFolder() adapter the app uses to pick the newest
//   stable vs beta, fetches the chosen binary by sha256 over a Reticulum link,
//   and verifies sha256(bytes) == the folder entry hash before "installing".
//
// This is exactly the consumer path of UpdateService.checkForUpdates +
// download(), minus the singleton wrappers (folderBrowseAsync == relay query;
// folderFetchBytes == FileTransferNode.fetch + sha verify), which can't run
// twice in one process.
//
//   dart run tool/update_net_test.dart [port]
import 'dart:async';
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
import 'package:aurora/services/update_models.dart';

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

/// A node on the rnsd hub: relay (for the folder op-log) and, optionally, a
/// FileTransferNode (to serve / fetch real binary bytes).
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
          // Files node first (link/Resource), then relay (folder op-log query).
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

// Build a deterministic pseudo-binary of [size] bytes (a stand-in release file).
Uint8List _artifact(int size, int seed) {
  final b = Uint8List(size);
  for (var i = 0; i < size; i++) {
    b[i] = (i * 73 + seed * 17 + 11) & 0xff;
  }
  return b;
}

Future<void> main(List<String> args) async {
  ensureSqlite();
  final port = args.isNotEmpty ? int.parse(args[0]) : 5580;
  final rnsd = await _startRnsd('/tmp/rnsd_update_test', port);
  await Future<void>.delayed(const Duration(seconds: 3));

  _Node? b, p, c;
  try {
    b = _Node(await RnsIdentity.generate()); // indexer (hosts the op-log)
    p = _Node(await RnsIdentity.generate()); // publisher (owns folder + serves)
    c = _Node(await RnsIdentity.generate()); // consumer (the updating app)

    // Three real release binaries for one "beta channel" folder (which holds
    // every build): two stable platforms + one prerelease.
    final stableLinux = _artifact(130000, 1); // ~5 chunks
    final stableApk = _artifact(60000, 2);
    final betaLinux = _artifact(90000, 3);
    final shStableLinux = _hx(crypto.sha256.convert(stableLinux).bytes);
    final shStableApk = _hx(crypto.sha256.convert(stableApk).bytes);
    final shBetaLinux = _hx(crypto.sha256.convert(betaLinux).bytes);

    // Publisher serves all three from memory.
    final src = MemoryFileSource()
      ..add(stableLinux)
      ..add(stableApk)
      ..add(betaLinux);
    p.enableFiles(src);
    c.enableFiles(MemoryFileSource()); // consumer holds nothing yet; it fetches

    await b.connect(port);
    await p.connect(port);
    await c.connect(port);
    await Future<void>.delayed(const Duration(seconds: 1));

    // B announces as the indexer; P announces its files destination so C learns
    // a route to fetch from.
    final bTimer = Timer.periodic(
        const Duration(milliseconds: 600), (_) => b!.announceRelay());
    final pTimer = Timer.periodic(
        const Duration(milliseconds: 600), (_) => p!.announceFiles());

    // C learns the indexer B and the provider P over the wire.
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
    check('publisher + consumer learned the indexer', bFromP != null && bFromC != null);
    check('consumer learned the provider (route to fetch binaries)', pFromC != null);
    if (bFromP == null || bFromC == null || pFromC == null) {
      bTimer.cancel();
      pTimer.cancel();
      throw 'discovery failed';
    }

    var clk = 1700000000;

    // ── PUBLISHER: create the signed folder and add the three real binaries. ──
    final owner = FolderService(
      keystore: FolderKeystore.open(':memory:'),
      publish: (e) => p!.relay.publish(bFromP!, e),
      query: (f) => p!.relay.query(bFromP!, f),
      adminPrivHex: () => null,
      nowSec: () => clk,
    );
    final fid = await owner.createFolder(name: 'Aurora updates (beta)');
    clk += 5;
    await owner.addFile(fid, shStableLinux,
        name: 'aurora-9.9.9-linux-x64.tar.gz', size: stableLinux.length);
    clk += 5;
    await owner.addFile(fid, shStableApk,
        name: 'aurora-9.9.9.apk', size: stableApk.length);
    clk += 5;
    await owner.addFile(fid, shBetaLinux,
        name: 'aurora-9.9.10-beta.1-linux-x64.tar.gz', size: betaLinux.length);
    clk += 5;
    stdout.writeln('publisher created folder $fid with 3 binaries');

    // ── CONSUMER: browse the folder over the network (the app's "check"). ──
    final app = FolderService(
      keystore: FolderKeystore.open(':memory:'),
      publish: (e) => c!.relay.publish(bFromC!, e),
      query: (f) => c!.relay.query(bFromC!, f),
      adminPrivHex: () => null,
      nowSec: () => clk,
    );
    final state = await app.browse(fid);
    check('consumer browsed the signed folder over rnsd', state.files.length == 3);

    // Run the REAL adapter on the REAL folder state.
    final releases = releasesFromFolder(state.toJson());
    check('adapter parsed both versions from the folder',
        releases.map((r) => r.version).toSet().containsAll(
            {'9.9.9', '9.9.10-beta.1'}));

    int cmp(String a, String x) => _semver(a, x);
    ReleaseInfo? newest(bool prereleaseOk) {
      ReleaseInfo? best;
      for (final r in releases) {
        if (!prereleaseOk && r.isPrerelease) continue;
        if (best == null || cmp(r.version, best.version) > 0) best = r;
      }
      return best;
    }

    final newestStable = newest(false);
    final newestBeta = newest(true);
    check('newest STABLE picked = 9.9.9', newestStable?.version == '9.9.9');
    check('newest BETA picked = 9.9.10-beta.1',
        newestBeta?.version == '9.9.10-beta.1');

    // ── CONSUMER: download the chosen binary over Reticulum + verify sha. ──
    // (Stable channel: fetch the newest stable's linux artifact.)
    final asset = newestStable!.assetFor(UpdatePlatform.linux);
    check('asset resolved for platform', asset != null &&
        asset.name == 'aurora-9.9.9-linux-x64.tar.gz');
    check('asset.url is the content sha (fetch handle)',
        asset!.url == shStableLinux);

    final bytes = await c!.files!.fetch(
        _hexToBytes(asset.url), pFromC!,
        timeout: const Duration(seconds: 40));
    check('fetched the binary bytes over a real Reticulum link', bytes != null);
    if (bytes != null) {
      final got = _hx(crypto.sha256.convert(bytes).bytes);
      check('downloaded size matches the folder entry',
          bytes.length == stableLinux.length);
      check('sha256(bytes) == folder entry hash (integrity verified)',
          got == asset.url);

      // "Install": write the verified binary to a temp updates dir.
      final dir = await Directory.systemTemp.createTemp('aurora_upd_');
      final out = File('${dir.path}/${asset.name}');
      await out.writeAsBytes(bytes, flush: true);
      check('verified binary written to disk', await out.exists() &&
          (await out.length()) == stableLinux.length);
      await dir.delete(recursive: true);
    }

    // Negative control: a binary the publisher does NOT serve cannot be fetched.
    final bogus =
        _hx(crypto.sha256.convert(_artifact(1000, 99)).bytes);
    final none = await c.files!
        .fetch(_hexToBytes(bogus), pFromC!, timeout: const Duration(seconds: 8));
    check('unknown sha is not fetchable (no false positive)', none == null);

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

// Same prerelease-aware semver compare UpdateService uses to pick the newest.
int _semver(String a, String b) {
  a = a.split('+').first;
  b = b.split('+').first;
  final ap = a.split('-');
  final bp = b.split('-');
  List<int> core(String s) =>
      s.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final ac = core(ap.first), bc = core(bp.first);
  for (var i = 0; i < 3; i++) {
    final x = i < ac.length ? ac[i] : 0;
    final y = i < bc.length ? bc[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  final aPre = ap.length > 1, bPre = bp.length > 1;
  if (aPre && !bPre) return -1;
  if (!aPre && bPre) return 1;
  if (!aPre && !bPre) return 0;
  final aId = ap.sublist(1).join('-').split('.');
  final bId = bp.sublist(1).join('-').split('.');
  for (var i = 0; i < aId.length && i < bId.length; i++) {
    final an = int.tryParse(aId[i]), bn = int.tryParse(bId[i]);
    int cc;
    if (an != null && bn != null) {
      cc = an.compareTo(bn);
    } else if (an != null) {
      cc = -1;
    } else if (bn != null) {
      cc = 1;
    } else {
      cc = aId[i].compareTo(bId[i]);
    }
    if (cc != 0) return cc < 0 ? -1 : 1;
  }
  return aId.length.compareTo(bId.length).clamp(-1, 1);
}
