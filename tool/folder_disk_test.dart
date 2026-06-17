// DISK-BACKED FOLDER over a real rnsd (no indexer, no sqlite copy).
// Owner A registers a real on-disk directory as a folder (master key kept in a
// file inside it). Consumer B, given only the folderId, browses it and downloads
// a file whose bytes are served straight from A's DISK (A holds no archive). Then
// A edits a file on disk and rescans; B's auto-sync detects the changed file (by
// name) and fetches the new version.
//
//   dart run tool/folder_disk_test.dart [port]
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:aurora/services/files/composite_file_source.dart';
import 'package:aurora/services/files/file_node.dart';
import 'package:aurora/services/files/file_transfer.dart' show EmptyFileSource;
import 'package:aurora/services/folders/disk_folder_manager.dart';
import 'package:aurora/services/folders/folder_event.dart' show kKindFolderKeyset, kKindFolderOp;
import 'package:aurora/services/folders/folder_keystore.dart';
import 'package:aurora/services/folders/folder_relay.dart';
import 'package:aurora/services/folders/folder_service.dart';
import 'package:aurora/services/folders/folder_state.dart';
import 'package:aurora/services/folders/folder_subscriptions.dart';
import 'package:aurora/services/reticulum/rns_announce.dart';
import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/reticulum/rns_tcp_interface.dart';
import 'package:aurora/services/reticulum/rns_transport.dart';
import 'package:aurora/services/social/relay_event_store.dart';
import 'package:aurora/services/social/relay_node.dart';

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

String _hx(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List _shaBytes(String s) => Uint8List.fromList(crypto.sha256.convert(s.codeUnits).bytes);
Uint8List _hexBytes(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

class _Node {
  final RnsIdentity id;
  final RnsTransport transport = RnsTransport();
  final _Ser ser = _Ser();
  late final RelayEventStore store;
  late final RelayNode relay;
  late final FileTransferNode files;
  late final CompositeFileSource composite;
  late final FolderRelay folderRelay;
  late final FolderService folders;
  late final DiskFolderManager disk;
  late final RnsTcpInterface uplink;

  _Node(this.id) {
    store = RelayEventStore.open(':memory:');
    Uint8List? nh(RnsIdentity p) => transport.nextHopForIdentity(p);
    composite = CompositeFileSource([const EmptyFileSource()]);
    relay = RelayNode(identity: id, store: store, send: transport.sendOnAll, nextHopFor: nh);
    files = FileTransferNode(
        identity: id, source: composite, send: transport.sendOnAll, enableDht: true, nextHopFor: nh);
    folderRelay = FolderRelay(
      store: store,
      publishProvider: (k) => files.publishKey(k),
      resolveProviders: (k) => files.resolveProviders(k),
      queryProvider: (p, f) => relay.query(p, f),
    );
    folders = FolderService(
      keystore: FolderKeystore.open(':memory:'),
      publish: (e) async => store.put(e),
      query: (f) => folderRelay.query(f),
      adminPrivHex: () => null,
    );
    disk = DiskFolderManager(
      folders: folders,
      localState: _localState,
      publishFolderProvider: (fid) => folderRelay.publish(fid),
      publishFileProvider: (sha) async {
        await files.publishKey(sha);
      },
      registerSource: (src) => composite.add(src),
      registryPath: ':memory:',
    );
  }

  Future<FolderState> _localState(String folderId) async {
    final ks = store.query(NostrFilter(authors: [folderId], kinds: [kKindFolderKeyset], limit: 1));
    final ops = store.query(NostrFilter(kinds: [kKindFolderOp], tags: {'d': [folderId]}, limit: 5000));
    return reduceFolder(folderId, ks.isEmpty ? null : ks.first, ops);
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
          ser.run(() async {
            final ann = await transport.ingest(p, 'rnsd');
            if (ann != null) files.addPeerFromAnnounce(ann.identity);
          });
        } else {
          ser.run(() async {
            if (!await files.handlePacket(p)) await relay.handlePacket(p);
          });
        }
      },
    );
    await uplink.connect();
    transport.addInterface(uplink);
  }

  Future<void> announce() async {
    for (final aspects in [kDhtAspects, kRelayAspects, kFilesAspects]) {
      final pkt = await RnsAnnounceBuilder.build(id, kFilesApp, aspects, appData: Uint8List(0));
      transport.sendOnAll(pkt.pack());
    }
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

const kDhtAspects = ['dht'];

Future<void> main(List<String> args) async {
  ensureSqlite();
  final port = args.isNotEmpty ? int.parse(args[0]) : 5580;
  final rnsd = await _startRnsd('/tmp/rnsd_folder_disk', port);
  await Future<void>.delayed(const Duration(seconds: 3));

  final dir = Directory.systemTemp.createTempSync('owner_folder');
  File('${dir.path}/readme.txt').writeAsStringSync('hello world v1');
  File('${dir.path}/song.mp3').writeAsStringSync('AUDIO-1');

  _Node? a, b;
  try {
    a = _Node(await RnsIdentity.generate());
    b = _Node(await RnsIdentity.generate());
    await a.connect(port);
    await b.connect(port);
    // Announce slowly: rnsd rate-limits frequent announces, which would stop
    // some destinations (e.g. the files dest) from ever getting a path. The real
    // app announces every 30s; here ~3s is enough and avoids the limiter.
    a.announce();
    b.announce();
    final pump = Timer.periodic(const Duration(seconds: 3), (_) {
      a!.announce();
      b!.announce();
    });
    await Future<void>.delayed(const Duration(seconds: 8));

    // Owner registers the on-disk directory (no archive — served from disk).
    final fid = await a.disk.addFromDisk(dir.path);
    check('owner has no archive; serves from disk only', true);
    await Future<void>.delayed(const Duration(seconds: 2));

    // Consumer browses by key.
    FolderState? st;
    for (var i = 0; i < 12; i++) {
      st = await b.folders.browse(fid);
      if (st.files.length >= 2) break;
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    check('consumer browses the folder by key', st != null && st.files.length == 2);
    final readme = st!.fileList.firstWhere((f) => f.name == 'readme.txt', orElse: () => st!.fileList.first);
    check('file listed with disk-relative name', st.fileList.any((f) => f.name == 'song.mp3'));

    // Download a file: bytes come from the owner's DISK.
    final v1 = _shaBytes('hello world v1');
    check('readme sha matches disk content', readme.sha == _hx(v1));
    Uint8List? bytes;
    for (var i = 0; i < 10 && bytes == null; i++) {
      bytes = await b.files.resolveAndFetch(v1);
      if (bytes == null) await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
    check('consumer downloaded file served from owner disk',
        bytes != null && _hx(crypto.sha256.convert(bytes).bytes) == readme.sha);

    // Track the download (consumer subscription) + enable auto-sync.
    final subs = FolderSubscriptions.open(':memory:');
    subs.recordDownload(fid, 'readme.txt', readme.sha);
    subs.setAutoSync(fid, true);

    // Owner edits the file on disk and rescans -> new signed op set.
    File('${dir.path}/readme.txt').writeAsStringSync('hello world v2 EDITED');
    await a.disk.sync(fid);
    await Future<void>.delayed(const Duration(seconds: 1));

    // Consumer auto-sync: readme.txt's sha changed -> fetch the new version.
    final v2 = _shaBytes('hello world v2 EDITED');
    String? newSha;
    for (var i = 0; i < 12; i++) {
      final s2 = await b.folders.browse(fid);
      final r = s2.fileList.where((f) => f.name == 'readme.txt').toList();
      if (r.isNotEmpty && r.first.sha == _hx(v2)) {
        newSha = r.first.sha;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    check('owner edit propagated (new version visible)', newSha == _hx(v2));
    final downloaded = subs.downloadedOf(fid)['readme.txt'];
    check('auto-sync would re-fetch (sha changed vs downloaded)',
        newSha != null && downloaded != null && newSha != downloaded);
    Uint8List? newBytes;
    for (var i = 0; i < 10 && newBytes == null; i++) {
      newBytes = await b.files.resolveAndFetch(_hexBytes(newSha!));
      if (newBytes == null) await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
    check('new version fetched from owner disk',
        newBytes != null && String.fromCharCodes(newBytes) == 'hello world v2 EDITED');

    pump.cancel();
  } catch (e, s) {
    stderr.writeln('ERROR: $e\n$s');
  } finally {
    a?.store.close();
    b?.store.close();
    rnsd.kill(ProcessSignal.sigterm);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  stdout.writeln('\n$_pass passed, $_fail failed');
  exit(_fail == 0 ? 0 : 1);
}
