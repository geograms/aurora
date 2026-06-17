// In-process Kademlia DHT gate: builds an N-node network (RPCs round-tripped
// through the real wire encode/decode), then validates publish + resolve, content
// replication across providers, capacity-class ranking, and misses. No network.
//
//   dart run tool/reticulum_dht_test.dart [nodes]
import 'dart:typed_data';

import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/files/dht/dht_core.dart';
import 'package:aurora/services/files/dht/dht_message.dart';
import 'package:aurora/services/files/dht/dht_node.dart';
import 'package:aurora/services/files/dht/provider_record.dart';

void _expect(bool c, String what) {
  if (!c) {
    // ignore: avoid_print
    print('FAIL: $what');
    throw StateError(what);
  }
}

Uint8List _sha(int seed) {
  // Deterministic 32-byte pseudo hash for the test.
  final out = Uint8List(32);
  var x = (seed * 2654435761) & 0xffffffff;
  for (var i = 0; i < 32; i++) {
    x = (x * 1103515245 + 12345) & 0xffffffff;
    out[i] = (x >> 16) & 0xff;
  }
  return out;
}

Future<void> main(List<String> args) async {
  final n = args.isNotEmpty ? int.parse(args[0]) : 40;
  final nodes = <String, DhtNode>{};

  Future<DhtMessage?> rpc(DhtContact to, DhtMessage req) async {
    final target = nodes[to.idHex];
    if (target == null) return null;
    // Round-trip both directions to exercise the wire format.
    final respBytes = await target.handleEncoded(req.encode());
    if (respBytes == null) return null;
    return DhtMessage.decode(respBytes);
  }

  final ids = <RnsIdentity>[];
  for (var i = 0; i < n; i++) {
    final id = await RnsIdentity.generate();
    ids.add(id);
    final node = DhtNode(identity: id, k: 8, alpha: 3, sendRpc: rpc);
    nodes[dhtHex(node.myId)] = node;
  }
  final nodeList = nodes.values.toList();
  final seed = DhtContact.ofIdentity(ids[0]);

  // Bootstrap every node off node 0, then a second pass so tables fill out.
  for (var i = 1; i < nodeList.length; i++) {
    await nodeList[i].bootstrap([seed]);
  }
  for (var i = 1; i < nodeList.length; i++) {
    await nodeList[i].iterativeFindNode(nodeList[i].myId);
  }

  // 1) Provider publishes a record; a different node resolves it.
  final sha1 = _sha(101);
  final provider = nodeList[5];
  final rec1 = await ProviderRecord.create(
      providerIdentity: ids[5], sha256: sha1, capacity: kCapHomeFiber);
  final holders = await provider.publish(rec1);
  _expect(holders >= 3, 'record replicated to >=3 holders (got $holders)');

  final asker = nodeList[20];
  final got = await asker.resolve(sha1);
  _expect(got.isNotEmpty, 'resolve found the provider');
  _expect(
      _eq(got.first.providerPub, ids[5].getPublicKey()), 'resolved correct provider');
  // ignore: avoid_print
  print('OK publish/resolve: $holders holders, resolved ${got.length} record(s)');

  // 2) Content replication + capacity ranking: a second provider (archive class)
  //    publishes the SAME file; resolve returns both, best class first.
  final rec2 = await ProviderRecord.create(
      providerIdentity: ids[6], sha256: sha1, capacity: kCapArchive);
  await nodeList[6].publish(rec2);
  final both = await nodeList[20].resolve(sha1);
  _expect(both.length == 2, 'resolve returns both providers (got ${both.length})');
  _expect(both.first.capacity == kCapArchive,
      'best capacity class ranked first (got ${both.first.capacity})');
  // ignore: avoid_print
  print('OK replication+ranking: ${both.length} providers, first cap=${both.first.capacity}');

  // 3) Miss: an unknown file resolves to nothing.
  final miss = await nodeList[12].resolve(_sha(999999));
  _expect(miss.isEmpty, 'unknown file resolves empty');

  // 4) Signature integrity: a tampered record fails verification.
  final tampered = ProviderRecord(
    sha256: rec1.sha256,
    providerPub: rec1.providerPub,
    capacity: rec1.capacity,
    manifestHash: rec1.manifestHash,
    timestampMs: rec1.timestampMs,
    ttlSec: rec1.ttlSec,
    signature: Uint8List(64), // wrong signature
  );
  _expect(!(await tampered.verify()), 'tampered record rejected');
  // A re-encoded genuine record still verifies.
  final reenc = ProviderRecord.decode(rec1.encode())!;
  _expect(await reenc.verify(), 'genuine record verifies after round-trip');
  // ignore: avoid_print
  print('OK integrity: tampered rejected, genuine verifies');

  // ignore: avoid_print
  print('ALL OK ($n nodes)');
}

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
