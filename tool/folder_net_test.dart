// MUTABLE FOLDERS over a real rnsd (slice 3): an owner publishes a folder and
// edits to an indexer (node B); a separate browser node (C) finds the folder by
// its id and sees the current state. An authorized admin's edit is accepted; a
// post-revocation edit is rejected while the earlier one remains. Proves the
// IPNS-like folder works across the network through the relay.
//
//   dart run tool/folder_net_test.dart [port]
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/folders/folder_event.dart';
import 'package:aurora/services/folders/folder_keystore.dart';
import 'package:aurora/services/folders/folder_service.dart';
import 'package:aurora/services/reticulum/rns_announce.dart';
import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/reticulum/rns_tcp_interface.dart';
import 'package:aurora/services/reticulum/rns_transport.dart';
import 'package:aurora/services/social/relay_event_store.dart';
import 'package:aurora/services/social/relay_node.dart';
import 'package:aurora/util/nostr_crypto.dart';

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

class _Node {
  final RnsIdentity id;
  final RnsTransport transport = RnsTransport();
  final _Ser ser = _Ser();
  late final RelayEventStore store;
  late final RelayNode relay;
  late final RnsTcpInterface uplink;
  _Node(this.id) {
    store = RelayEventStore.open(':memory:');
    relay = RelayNode(
      identity: id,
      store: store,
      send: transport.sendOnAll,
      nextHopFor: (peer) => transport.nextHopForIdentity(peer),
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
          ser.run(() => relay.handlePacket(p));
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

Future<bool> _until(bool Function() c, {int tries = 40}) async {
  for (var i = 0; i < tries; i++) {
    if (c()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return c();
}

Future<void> main(List<String> args) async {
  ensureSqlite();
  final port = args.isNotEmpty ? int.parse(args[0]) : 5570;
  final rnsd = await _startRnsd('/tmp/rnsd_folder_test', port);
  await Future<void>.delayed(const Duration(seconds: 3));

  _Node? b, a, c;
  try {
    b = _Node(await RnsIdentity.generate()); // indexer
    a = _Node(await RnsIdentity.generate()); // owner + admin client
    c = _Node(await RnsIdentity.generate()); // browser
    await b.connect(port);
    await a.connect(port);
    await c.connect(port);
    await Future<void>.delayed(const Duration(seconds: 1));

    final bTimer = Timer.periodic(
        const Duration(milliseconds: 600), (_) => b!.announceRelay());

    RnsIdentity? bIdFromA, bIdFromC;
    await _until(() {
      for (final e in a!.transport.paths) {
        if (e.nextHop != null && _hx(e.identity.hash) != _hx(a.id.hash)) bIdFromA = e.identity;
      }
      for (final e in c!.transport.paths) {
        if (e.nextHop != null && _hx(e.identity.hash) != _hx(c.id.hash)) bIdFromC = e.identity;
      }
      return bIdFromA != null && bIdFromC != null;
    });
    if (bIdFromA == null || bIdFromC == null) {
      stderr.writeln('FAIL: clients never learned the indexer');
      exit(1);
    }
    final bA = bIdFromA!, bC = bIdFromC!;
    stdout.writeln('clients learned indexer B');

    var clk = 1_700_000_000;
    final admin = NostrCrypto.generateKeyPair();

    // Owner + admin publish through A to indexer B; everyone queries B.
    final owner = FolderService(
      keystore: FolderKeystore.open(':memory:'),
      publish: (e) => a!.relay.publish(bA, e),
      query: (f) => a!.relay.query(bA, f),
      adminPrivHex: () => null,
      nowSec: () => clk,
    );
    final adminSvc = FolderService(
      keystore: FolderKeystore.open(':memory:'),
      publish: (e) => a!.relay.publish(bA, e),
      query: (f) => a!.relay.query(bA, f),
      adminPrivHex: () => admin.privateKeyHex,
      nowSec: () => clk,
    );
    // The browser only reads, from the SAME indexer, over its own link.
    final browser = FolderService(
      keystore: FolderKeystore.open(':memory:'),
      publish: (e) => c!.relay.publish(bC, e),
      query: (f) => c!.relay.query(bC, f),
      adminPrivHex: () => null,
      nowSec: () => clk,
    );

    final shaA = 'a' * 64, shaB = 'b' * 64, shaC = 'c' * 64;

    final fid = await owner.createFolder(name: 'Shared', desc: 'net folder');
    clk += 10;
    await owner.addFile(fid, shaA, name: 'a.bin');
    clk += 10;

    // The browser node finds the folder by id across the network.
    var st = await browser.browse(fid);
    check('browser found folder by id over rnsd', st.name == 'Shared');
    check('browser sees the owner file', st.files.containsKey(shaA));

    // Authorize the admin; their edit (published through the relay) is accepted.
    await owner.grantAdmin(fid, admin.publicKeyHex, role: FolderRole.moderator);
    clk += 10;
    await adminSvc.addFile(fid, shaB, name: 'b by admin');
    clk += 10;
    st = await browser.browse(fid);
    check('authorized admin edit visible network-wide', st.files.containsKey(shaB));

    // Revoke; a later admin edit is rejected, the earlier one remains.
    await owner.revokeAdmin(fid, admin.publicKeyHex);
    clk += 10;
    await adminSvc.addFile(fid, shaC, name: 'c after revoke');
    clk += 10;
    st = await browser.browse(fid);
    check('post-revoke admin edit rejected', !st.files.containsKey(shaC));
    check('pre-revoke admin edit kept', st.files.containsKey(shaB));

    bTimer.cancel();
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
