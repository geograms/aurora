// Proves the FEED-discovery fix over a real rnsd: a LEAF node (serve=false, a
// phone that won't host the network) still answers a query for ITS OWN posts,
// so a freshly-joined device can pull what that device published — directly,
// with nobody hosting the network. Also checks the safety scoping: the leaf
// only returns self-authored events and refuses to store others' events.
//
//   dart run tool/relay_leaf_net_test.dart [port]
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

class _Node {
  final RnsIdentity id;
  final RnsTransport transport;
  final _Ser ser = _Ser();
  late final RelayEventStore store;
  late final RelayNode relay;
  late final RnsTcpInterface uplink;
  _Node(this.id, {required bool serve, String? selfPub})
      : transport = RnsTransport(transportId: id.hash) {
    store = RelayEventStore.open(':memory:');
    relay = RelayNode(
      identity: id,
      store: store,
      send: transport.sendOnAll,
      nextHopFor: (peer) => transport.nextHopForIdentity(peer),
      serve: serve,
      selfPubHex: () => selfPub,
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
    try {
      final pkt = await RnsAnnounceBuilder.build(id, kRelayApp, kRelayAspects,
          appData: Uint8List.fromList('leaf'.codeUnits));
      transport.sendOnAll(pkt.pack());
    } catch (_) {
      // interface not connected yet / torn down — ignore
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

Future<bool> _until(bool Function() c, {int tries = 60}) async {
  for (var i = 0; i < tries; i++) {
    if (c()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return c();
}

NostrEvent _note(NostrKeyPair kp, String text, int ts) {
  final ev = NostrEvent(
    pubkey: kp.publicKeyHex,
    createdAt: ts,
    kind: NostrEventKind.textNote,
    tags: const [
      ['t', 'activity']
    ],
    content: text,
  );
  ev.sign(kp.privateKeyHex);
  return ev;
}

Future<void> main(List<String> args) async {
  ensureSqlite();
  final port = args.isNotEmpty ? int.parse(args[0]) : 5600;
  final rnsd = await _startRnsd('/tmp/rnsd_relayleaf_test', port);
  await Future<void>.delayed(const Duration(seconds: 3));

  _Node? leaf, joiner;
  try {
    final leafKp = NostrCrypto.generateKeyPair(); // the poster's NOSTR identity
    // LEAF: a phone that does NOT host the network (serve=false) but knows its
    // own pubkey, so it can answer for its own posts.
    leaf = _Node(await RnsIdentity.generate(),
        serve: false, selfPub: leafKp.publicKeyHex);
    joiner = _Node(await RnsIdentity.generate(), serve: false);

    // The leaf has TWO of its own FEED posts, plus (to prove scoping) a post by
    // SOMEONE ELSE that it happens to hold — which it must NOT serve.
    const t0 = 1700000000;
    leaf.store.put(_note(leafKp, 'leaf post one', t0 + 1), tier: 0);
    leaf.store.put(_note(leafKp, 'leaf post two', t0 + 2), tier: 0);
    final otherKp = NostrCrypto.generateKeyPair();
    leaf.store.put(_note(otherKp, 'someone elses post', t0 + 3), tier: 1);

    await leaf.connect(port);
    await joiner.connect(port);
    await Future<void>.delayed(const Duration(seconds: 1));

    // The leaf announces; the joiner learns the leaf's identity over the wire.
    final lTimer = Timer.periodic(
        const Duration(milliseconds: 600), (_) => leaf!.announceRelay());

    RnsIdentity? leafFromJoiner;
    await _until(() {
      for (final e in joiner!.transport.paths) {
        if (e.nextHop != null && _hx(e.identity.hash) == _hx(leaf!.id.hash)) {
          leafFromJoiner = e.identity;
        }
      }
      return leafFromJoiner != null;
    });
    check('joiner discovered the leaf over rnsd', leafFromJoiner != null);
    if (leafFromJoiner == null) {
      lTimer.cancel();
      throw 'discovery failed';
    }

    // The joiner asks the leaf (a non-hosting phone) for FEED posts.
    final filter = NostrFilter(
        kinds: const [1], tags: {'t': ['activity']}, since: t0, limit: 100);
    final got = await joiner.relay
        .query(leafFromJoiner!, filter, timeout: const Duration(seconds: 15));
    final texts = got.map((e) => e.content).toSet();
    check('leaf answered the query (did NOT refuse the link)', got.isNotEmpty);
    check('joiner pulled the leaf\'s OWN posts',
        texts.contains('leaf post one') && texts.contains('leaf post two'));
    check('leaf did NOT serve someone else\'s post (self-scoped)',
        !texts.contains('someone elses post'));

    // Safety: pushing an EVENT to a leaf is refused (it won't host others).
    final pushOk = await joiner.relay.publish(
        leafFromJoiner!, _note(otherKp, 'try to store on the leaf', t0 + 9),
        timeout: const Duration(seconds: 10));
    check('leaf refuses to STORE others\' events (not a host)', !pushOk);

    lTimer.cancel();
  } catch (e, s) {
    stderr.writeln('ERROR: $e\n$s');
    _fail++;
  } finally {
    leaf?.store.close();
    joiner?.store.close();
    rnsd.kill(ProcessSignal.sigterm);
  }

  stdout.writeln('\n$_pass passed, $_fail failed');
  exit(_fail == 0 ? 0 : 1);
}
