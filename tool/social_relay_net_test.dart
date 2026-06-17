// RELAY over a real rnsd: two Aurora nodes connect as leaves through one rnsd.
// Node B is an indexer (relay + event store). Node A publishes NOSTR events to B,
// then runs NIP-01 filter queries and a NIP-50 full-text SEARCH against B and
// gets the matching events back. Exercises RelayNode + RelayProtocol over
// transport-addressed RnsLinks (request as packet, large RESULT as a Resource).
//
//   dart run tool/social_relay_net_test.dart [port]
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/reticulum/rns_announce.dart';
import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/reticulum/rns_tcp_interface.dart';
import 'package:aurora/services/reticulum/rns_transport.dart';
import 'package:aurora/services/social/relay_event_store.dart';
import 'package:aurora/services/social/relay_node.dart';
import 'package:aurora/util/nostr_crypto.dart';
import 'package:aurora/util/nostr_event.dart';

import 'sqlite_loader.dart';

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
  final _Ser ser = _Ser();
  late final RelayNode relay;
  late final RnsTcpInterface uplink;
  _Node(this.id, RelayEventStore store) {
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

  Future<void> announce() async {
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

NostrEvent _ev(NostrKeyPair kp,
    {required int kind, String content = '', List<List<String>> tags = const [], int? at}) {
  final e = NostrEvent(
    pubkey: kp.publicKeyHex,
    createdAt: at ?? (1_700_000_000 + kind),
    kind: kind,
    tags: tags,
    content: content,
  );
  e.sign(kp.privateKeyHex);
  return e;
}

Future<void> main(List<String> args) async {
  ensureSqlite();
  final port = args.isNotEmpty ? int.parse(args[0]) : 5560;
  final cfg = '/tmp/rnsd_relay_test';

  final rnsd = await _startRnsd(cfg, port);
  await Future<void>.delayed(const Duration(seconds: 3));

  final storeA = RelayEventStore.open(':memory:');
  final storeB = RelayEventStore.open(':memory:');

  try {
    final a = _Node(await RnsIdentity.generate(), storeA);
    final b = _Node(await RnsIdentity.generate(), storeB);
    await a.connect(port);
    await b.connect(port);
    await Future<void>.delayed(const Duration(seconds: 1));

    // Announce until A has a transported path to B's relay identity.
    RnsIdentity? bId;
    for (var i = 0; i < 40 && bId == null; i++) {
      await a.announce();
      await b.announce();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      for (final e in a.transport.paths) {
        if (e.nextHop != null &&
            _hx(e.identity.hash) != _hx(a.id.hash)) {
          bId = e.identity;
          break;
        }
      }
    }
    if (bId == null) {
      stderr.writeln('FAIL: A never learned B via rnsd');
      exit(1);
    }
    stdout.writeln('A learned indexer B; publishing events...');

    // Author + publish events from A to indexer B.
    final author = NostrCrypto.generateKeyPair();
    final posts = <NostrEvent>[
      _ev(author, kind: 1, content: 'Reticulum mesh over LoRa is magic', tags: [['t', 'reticulum']], at: 1_700_000_100),
      _ev(author, kind: 1, content: 'Solar charging my field node today', tags: [['t', 'solar'], ['t', 'reticulum']], at: 1_700_000_200),
      _ev(author, kind: 0, content: '{"name":"fieldop","about":"meshnet tinkerer"}', at: 1_700_000_050),
      _ev(author, kind: kKindFileMetadata, content: 'Antenna build guide', tags: [
        ['x', 'b' * 64],
        ['name', 'antenna_build_guide.pdf'],
        ['t', 'docs'],
      ], at: 1_700_000_300),
    ];
    var published = 0;
    for (final e in posts) {
      if (await a.relay.publish(bId, e)) published++;
    }
    check('all events published to indexer', published == posts.length);
    check('indexer stored events', storeB.count() == posts.length);

    // Query back from A over the link.
    final kind1 = await a.relay.query(bId, const NostrFilter(kinds: [1]));
    check('REQ kind=1 returns 2 posts', kind1.length == 2);

    final byTopic = await a.relay.query(
        bId, const NostrFilter(kinds: [1], tags: {'t': ['reticulum']}));
    check('REQ #t=reticulum returns 2', byTopic.length == 2);

    final searchMesh = await a.relay.query(bId, const NostrFilter(search: 'mesh', kinds: [1]));
    check('SEARCH "mesh" finds the LoRa post', searchMesh.any((e) => e.content.contains('LoRa')));

    final fileSearch = await a.relay.query(bId, const NostrFilter(search: 'antenna'));
    check('SEARCH "antenna" finds file-meta', fileSearch.any((e) => e.kind == kKindFileMetadata));

    final byHash = await a.relay.query(bId, NostrFilter(kinds: [kKindFileMetadata], tags: {'x': ['b' * 64]}));
    check('REQ file by sha256 #x', byHash.length == 1);

    final n = await a.relay.countMatches(bId, const NostrFilter(kinds: [1]));
    check('COUNT kind=1 = 2', n == 2);
  } catch (e, st) {
    stderr.writeln('ERROR: $e\n$st');
  } finally {
    storeA.close();
    storeB.close();
    rnsd.kill(ProcessSignal.sigterm);
  }

  stdout.writeln('\n$_pass passed, $_fail failed');
  exit(_fail == 0 ? 0 : 1);
}

String _hx(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
