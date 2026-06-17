// STORE-AND-FORWARD over a real rnsd (slice 4): three Aurora nodes.
//   B = propagation indexer (charger+wifi => storeForward).
//   A = sender. C = recipient, initially OFFLINE.
// A sends an LXMF message to C; direct delivery fails (C offline) so A deposits
// it at indexer B. Later C comes online and announces; B flushes the queued mail
// to C, which receives and verifies the ORIGINAL sender's (A's) signature.
//
//   dart run tool/social_relay_sf_test.dart [port]
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/files/capacity_policy.dart';
import 'package:aurora/services/reticulum/lxmf/lxmf.dart';
import 'package:aurora/services/reticulum/lxmf/lxmf_message.dart';
import 'package:aurora/services/reticulum/lxmf/lxmf_router.dart';
import 'package:aurora/services/reticulum/rns_announce.dart';
import 'package:aurora/services/reticulum/rns_crypto.dart';
import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/reticulum/rns_tcp_interface.dart';
import 'package:aurora/services/reticulum/rns_transport.dart';
import 'package:aurora/services/social/relay_event_store.dart';
import 'package:aurora/services/social/relay_node.dart';
import 'package:aurora/services/social/relay_role.dart';
import 'package:aurora/services/social/store_forward.dart';

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

String _hx(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

class _Node {
  final RnsIdentity id;
  final RnsTransport transport = RnsTransport();
  final RelayDirectory dir = RelayDirectory();
  final _Ser ser = _Ser();
  late final RelayEventStore store;
  late final RelayNode relay;
  late final LxmfRouter lxmf;
  late final StoreForward sf;
  late final RnsTcpInterface uplink;
  LxmfMessage? received;
  final Completer<LxmfMessage> gotMsg = Completer<LxmfMessage>();

  _Node(this.id) {
    store = RelayEventStore.open(':memory:');
    relay = RelayNode(
      identity: id,
      store: store,
      send: transport.sendOnAll,
      nextHopFor: (peer) => transport.nextHopForIdentity(peer),
    );
    lxmf = LxmfRouter(
      identity: id,
      send: transport.sendOnAll,
      nextHopFor: (peer) => transport.nextHopForIdentity(peer),
      identityForDest: (h) => transport.pathFor(h)?.identity,
      onMessage: (m) {
        received = m;
        if (!gotMsg.isCompleted) gotMsg.complete(m);
      },
    );
    sf = StoreForward(node: relay, router: lxmf, directory: dir);
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
            if (ann != null) {
              final relayHash =
                  RnsDestination.hash(ann.identity, kRelayApp, kRelayAspects);
              if (RnsCrypto.constantTimeEquals(ann.destHash, relayHash)) {
                dir.observe(ann.identity, ann.appData, hops: p.hops + 1);
              }
            }
          });
        } else {
          ser.run(() async {
            if (!await relay.handlePacket(p)) await lxmf.handlePacket(p);
          });
        }
      },
    );
    await uplink.connect();
    transport.addInterface(uplink);
  }

  Future<void> announceRelay(Uint8List appData) async {
    final pkt = await RnsAnnounceBuilder.build(id, kRelayApp, kRelayAspects,
        appData: appData);
    transport.sendOnAll(pkt.pack());
  }

  Future<void> announceLxmf() async {
    final pkt = await RnsAnnounceBuilder.build(id, kLxmfApp, kLxmfDeliveryAspects,
        appData: Uint8List.fromList('node'.codeUnits));
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

Future<bool> _until(bool Function() cond, {int tries = 40}) async {
  for (var i = 0; i < tries; i++) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return cond();
}

Future<void> main(List<String> args) async {
  ensureSqlite();
  final port = args.isNotEmpty ? int.parse(args[0]) : 5566;
  final rnsd = await _startRnsd('/tmp/rnsd_sf_test', port);
  await Future<void>.delayed(const Duration(seconds: 3));

  _Node? a, b, c;
  try {
    b = _Node(await RnsIdentity.generate()); // propagation indexer
    a = _Node(await RnsIdentity.generate()); // sender
    c = _Node(await RnsIdentity.generate()); // recipient (offline at first)

    // B advertises itself as a store-forward indexer (charger + wifi).
    final bAnn = RelayAnnouncement.forCapacity(
        policyFor(NetKind.wifi, true, serveOnCellular: false, quotaMb: 1024),
        InterestSet());

    await b.connect(port);
    await a.connect(port);
    await Future<void>.delayed(const Duration(seconds: 1));

    // Keep B announcing its relay role + lxmf dest; A announcing its lxmf dest.
    final bRelayTimer = Timer.periodic(
        const Duration(milliseconds: 600), (_) => b!.announceRelay(bAnn.encode()));
    final bLxTimer = Timer.periodic(
        const Duration(milliseconds: 600), (_) => b!.announceLxmf());
    final aLxTimer = Timer.periodic(
        const Duration(milliseconds: 600), (_) => a!.announceLxmf());

    // A learns B as a store-forward propagation node.
    final learnedB = await _until(() =>
        a!.dir.indexers().any((e) => e.announcement.has(RelayCap.storeForward)));
    check('A discovered B as a store-forward indexer', learnedB);

    // A composes a signed LXMF message addressed to (currently offline) C.
    final cDeliveryHash =
        RnsDestination.hash(c.id, kLxmfApp, kLxmfDeliveryAspects);
    final msg = await LxmfMessage.create(
      destinationHash: cDeliveryHash,
      source: a.id,
      title: 'offline',
      content: 'hello C, sent while you were away',
    );

    // Direct fails (C offline) -> A deposits at B.
    final outcome = await a.sf.sendOrStore(msg);
    check('send falls back to store-and-forward', outcome == SendOutcome.stored);
    check('indexer B queued the message', b.store.sfCount() == 1);
    check('C has not received yet', c.received == null);

    // C comes online and announces its LXMF delivery dest.
    await c.connect(port);
    final cLxTimer = Timer.periodic(
        const Duration(milliseconds: 600), (_) => c!.announceLxmf());

    // Wait until B has a path to C, and C has learned A (to verify A's sig).
    final bSeesC = await _until(() => b!.transport.pathFor(cDeliveryHash) != null);
    check('B learned a path to C once online', bSeesC);
    final aDeliveryHash =
        RnsDestination.hash(a.id, kLxmfApp, kLxmfDeliveryAspects);
    await _until(() => c!.transport.pathFor(aDeliveryHash) != null);

    // B flushes queued mail to C (driven by C's announce in production).
    final delivered = await b.sf.onRecipientOnline(c.id);
    check('B delivered 1 queued message', delivered == 1);

    final got = await c.gotMsg.future
        .timeout(const Duration(seconds: 15), onTimeout: () => throw 'no msg at C');
    check('C received the original content',
        got.contentString == 'hello C, sent while you were away');
    check('C verified it is from A',
        _hx(got.sourceHash) == _hx(aDeliveryHash));
    check('mailbox drained after delivery', b.store.sfCount() == 0);

    bRelayTimer.cancel();
    bLxTimer.cancel();
    aLxTimer.cancel();
    cLxTimer.cancel();
  } catch (e, st) {
    stderr.writeln('ERROR: $e\n$st');
  } finally {
    a?.store.close();
    b?.store.close();
    c?.store.close();
    rnsd.kill(ProcessSignal.sigterm);
  }

  stdout.writeln('\n$_pass passed, $_fail failed');
  exit(_fail == 0 ? 0 : 1);
}
