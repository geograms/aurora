// PEER-TO-PEER FOLDER DISCOVERY over a real rnsd, with NO indexer (slice).
// Three plain Aurora nodes connect through one rnsd. Node A creates + edits a
// folder and advertises itself in the DHT under the folder key. Node B and node
// C, given ONLY the folder id, resolve providers via the DHT and browse the
// folder directly from A — no indexer, no RelayDirectory. B then holds the
// events (auto-seed ready), so any device can serve a folder it has seen.
//
//   dart run tool/folder_discovery_test.dart [port]
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/files/dht/dht_core.dart' show kDhtApp, kDhtAspects;
import 'package:aurora/services/files/file_node.dart';
import 'package:aurora/services/files/file_transfer.dart' show EmptyFileSource;
import 'package:aurora/services/folders/folder_event.dart' show kKindFolderOp;
import 'package:aurora/services/folders/folder_keystore.dart';
import 'package:aurora/services/folders/folder_relay.dart';
import 'package:aurora/services/folders/folder_service.dart';
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

int _clk = 1_700_000_000;

class _Node {
  final RnsIdentity id;
  final RnsTransport transport = RnsTransport();
  final _Ser ser = _Ser();
  late final RelayEventStore store;
  late final RelayNode relay;
  late final FileTransferNode files;
  late final FolderRelay folderRelay;
  late final FolderService folders;
  late final RnsTcpInterface uplink;

  _Node(this.id) {
    store = RelayEventStore.open(':memory:');
    Uint8List? nh(RnsIdentity p) => transport.nextHopForIdentity(p);
    relay = RelayNode(
        identity: id, store: store, send: transport.sendOnAll, nextHopFor: nh);
    files = FileTransferNode(
        identity: id,
        source: const EmptyFileSource(),
        send: transport.sendOnAll,
        enableDht: true,
        nextHopFor: nh);
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
      nowSec: () => _clk,
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
    for (final aspects in [kDhtAspects, kRelayAspects]) {
      final pkt = await RnsAnnounceBuilder.build(id, kDhtApp, aspects,
          appData: Uint8List(0));
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

Future<void> main(List<String> args) async {
  ensureSqlite();
  final port = args.isNotEmpty ? int.parse(args[0]) : 5574;
  final rnsd = await _startRnsd('/tmp/rnsd_folder_disc', port);
  await Future<void>.delayed(const Duration(seconds: 3));

  _Node? a, b, c;
  try {
    a = _Node(await RnsIdentity.generate());
    b = _Node(await RnsIdentity.generate());
    c = _Node(await RnsIdentity.generate());
    await a.connect(port);
    await b.connect(port);
    await c.connect(port);

    // Let everyone announce so DHT contacts + paths form (no indexer role).
    final pump = Timer.periodic(const Duration(milliseconds: 700), (_) {
      a!.announce();
      b!.announce();
      c!.announce();
    });
    await Future<void>.delayed(const Duration(seconds: 5));

    final shaA = 'a' * 64;

    // A creates + populates a folder, then advertises itself in the DHT.
    final fid = await a.folders.createFolder(name: 'Shared', desc: 'p2p');
    _clk += 10;
    await a.folders.addFile(fid, shaA, name: 'a.bin');
    _clk += 10;
    await a.folderRelay.publish(fid); // DHT provider record under the folder key
    await Future<void>.delayed(const Duration(seconds: 2));

    Future<bool> browseHas(_Node n, String shaHex, {int tries = 12}) async {
      for (var i = 0; i < tries; i++) {
        final st = await n.folders.browse(fid);
        if (st.files.containsKey(shaHex) && st.name == 'Shared') return true;
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      return false;
    }

    check('B finds the folder by key alone (no indexer)', await browseHas(b, shaA));
    check('C finds the folder by key alone (no indexer)', await browseHas(c, shaA));

    // B now holds the folder's events locally -> it can serve them (auto-seed).
    final bHeld = b.store
        .query(NostrFilter(kinds: const [kKindFolderOp], tags: {
      'd': [fid]
    })).isNotEmpty;
    check('B cached the events (any device can re-share)', bHeld);

    pump.cancel();
  } catch (e, s) {
    stderr.writeln('ERROR: $e\n$s');
  } finally {
    a?.store.close();
    b?.store.close();
    c?.store.close();
    rnsd.kill(ProcessSignal.sigterm);
  }

  stdout.writeln('\n$_pass passed, $_fail failed');
  exit(_fail == 0 ? 0 : 1);
}
