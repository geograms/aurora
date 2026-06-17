/*
 * DhtNode — the Kademlia engine: a routing table, a local record store, and the
 * iterative FIND_NODE / FIND_VALUE / STORE algorithms plus publish() and
 * resolve(). Transport-agnostic: the owner supplies [sendRpc] (send a DhtMessage
 * to a contact, await the reply) — in-process for tests, or over a Reticulum link
 * in the live node. handle()/handleEncoded() implement the responder side.
 *
 * resolve(sha256) is what an edge client's entry node runs on its behalf:
 * recursively walk to the nodes closest to the file key, collecting verified,
 * unexpired provider records, ranked by capacity class (best providers first).
 */
import 'dart:async';
import 'dart:typed_data';

import '../../reticulum/rns_identity.dart';
import 'dht_core.dart';
import 'dht_message.dart';
import 'provider_record.dart';
import 'routing_table.dart';

/// Send a DHT message to [to] and await the reply (null on failure/timeout).
typedef DhtRpc = Future<DhtMessage?> Function(DhtContact to, DhtMessage req);

class DhtNode {
  final RnsIdentity identity; // full identity (private) — to sign nothing here,
  // but it identifies us; records are signed by the provider, not the DHT node.
  final int k;
  final int alpha;
  final DhtRpc sendRpc;
  final void Function(String msg)? log;

  late final Uint8List myId = DhtContact.ofIdentity(identity).id;
  late final Uint8List myPub = identity.getPublicKey();
  late final RoutingTable routing = RoutingTable(myId, k: k);

  // fileKey(16B) hex -> provider records this node custodies.
  final Map<String, List<ProviderRecord>> _store = {};

  DhtNode({
    required this.identity,
    this.k = 8,
    this.alpha = 3,
    required this.sendRpc,
    this.log,
  });

  int get storedKeys => _store.length;

  // ── Responder side ───────────────────────────────────────────────────────
  Future<DhtMessage> handle(DhtMessage req) async {
    routing.add(req.sender); // learn whoever contacts us
    switch (req.op) {
      case DhtOp.ping:
        return DhtMessage.pong(myPub);
      case DhtOp.findNode:
        return DhtMessage.nodes(
            myPub, _cap(routing.closest(req.target!, k), kDhtWireMaxContacts));
      case DhtOp.findValue:
        final key = dhtFileKey(req.sha!);
        final recs = _liveRecords(key, req.sha!);
        return recs.isNotEmpty
            ? DhtMessage.valueRecords(myPub, _cap(recs, kDhtWireMaxRecords))
            : DhtMessage.valueNodes(
                myPub, _cap(routing.closest(key, k), kDhtWireMaxContacts));
      case DhtOp.store:
        final ok = await _accept(req.records.first);
        return DhtMessage.storeOk(myPub, ok);
      default:
        return DhtMessage.pong(myPub);
    }
  }

  /// Wire entry point for the live transport.
  Future<Uint8List?> handleEncoded(Uint8List raw) async {
    final m = DhtMessage.decode(raw);
    if (m == null) return null;
    return (await handle(m)).encode();
  }

  // ── Initiator side ─────────────────────────────────────────────────────────
  /// Seed the routing table and warm it by looking ourselves up.
  Future<void> bootstrap(List<DhtContact> seeds) async {
    for (final s in seeds) {
      routing.add(s);
    }
    await iterativeFindNode(myId);
  }

  /// Publish a signed provider record at the k nodes closest to its file key.
  /// Returns how many accepted it.
  Future<int> publish(ProviderRecord r) async {
    final closest = await iterativeFindNode(r.fileKey);
    var ok = 0;
    for (final c in closest) {
      final resp = await sendRpc(c, DhtMessage.store(myPub, r));
      if (resp != null && resp.op == DhtOp.storeOk && resp.ok) ok++;
      routing.add(c);
    }
    if (closest.isEmpty && await _accept(r)) ok = 1; // tiny/isolated network
    log?.call('publish ${dhtHex(r.sha256).substring(0, 8)} -> $ok holders');
    return ok;
  }

  /// Resolve a file id to its providers (verified, unexpired), best class first.
  Future<List<ProviderRecord>> resolve(Uint8List sha256) async {
    final target = dhtFileKey(sha256);
    final found = <String, ProviderRecord>{}; // providerPub hex -> record
    for (final r in _liveRecords(target, sha256)) {
      found[dhtHex(r.providerPub)] = r;
    }
    await _iterate(
      target,
      makeReq: () => DhtMessage.findValue(myPub, sha256),
      onResponse: (resp) async {
        if (!resp.hasValue) return;
        for (final r in resp.records) {
          if (!_eq(r.sha256, sha256) || r.isExpired()) continue;
          if (!await r.verify()) continue;
          found[dhtHex(r.providerPub)] = r;
        }
      },
    );
    final list = found.values.toList()
      ..sort((a, b) => a.capacity.compareTo(b.capacity));
    return list;
  }

  /// Find the k contacts closest to [target] (iterative).
  Future<List<DhtContact>> iterativeFindNode(Uint8List target) async {
    final shortlist = await _iterate(target, makeReq: null, onResponse: null);
    return shortlist;
  }

  /// Core iterative lookup. With [makeReq]/[onResponse] it does FIND_VALUE
  /// (collecting via onResponse), else FIND_NODE. Returns the k closest contacts
  /// discovered.
  Future<List<DhtContact>> _iterate(
    Uint8List target, {
    DhtMessage Function()? makeReq,
    Future<void> Function(DhtMessage resp)? onResponse,
  }) async {
    final shortlist = <String, DhtContact>{};
    for (final c in routing.closest(target, k)) {
      shortlist[c.idHex] = c;
    }
    final queried = <String>{};
    final failed = <String>{};
    int cmp(DhtContact a, DhtContact b) =>
        dhtCompare(dhtXor(a.id, target), dhtXor(b.id, target));

    for (var round = 0; round < 24; round++) {
      final candidates = shortlist.values
          .where((c) => !queried.contains(c.idHex) && !failed.contains(c.idHex))
          .toList()
        ..sort(cmp);
      if (candidates.isEmpty) break;
      final batch = candidates.take(alpha).toList();
      final results = await Future.wait(batch.map((c) async {
        queried.add(c.idHex);
        final req = makeReq != null
            ? makeReq()
            : DhtMessage.findNode(myPub, target);
        final resp = await sendRpc(c, req);
        return MapEntry(c, resp);
      }));
      var improved = false;
      for (final e in results) {
        final resp = e.value;
        if (resp == null) {
          failed.add(e.key.idHex);
          continue;
        }
        routing.add(e.key);
        if (onResponse != null) await onResponse(resp);
        for (final nc in resp.contacts) {
          if (dhtIdEquals(nc.id, myId)) continue;
          routing.add(nc);
          if (!shortlist.containsKey(nc.idHex)) {
            shortlist[nc.idHex] = nc;
            improved = true;
          }
        }
      }
      final top = (shortlist.values.toList()..sort(cmp)).take(k);
      if (top.every((c) => queried.contains(c.idHex) || failed.contains(c.idHex))) {
        break;
      }
      if (!improved && batch.length < alpha) break;
    }
    final out = shortlist.values.toList()..sort(cmp);
    return out.take(k).toList();
  }

  // ── Local store ────────────────────────────────────────────────────────────
  Future<bool> _accept(ProviderRecord r) async {
    if (r.isExpired()) return false;
    if (!await r.verify()) return false;
    final key = dhtHex(r.fileKey);
    final list = _store.putIfAbsent(key, () => <ProviderRecord>[]);
    list.removeWhere((e) => _eq(e.providerPub, r.providerPub));
    list.add(r);
    return true;
  }

  List<ProviderRecord> _liveRecords(Uint8List fileKey16, Uint8List sha256) {
    final key = dhtHex(fileKey16);
    final list = _store[key];
    if (list == null) return const [];
    list.removeWhere((r) => r.isExpired());
    if (list.isEmpty) {
      _store.remove(key);
      return const [];
    }
    return list.where((r) => _eq(r.sha256, sha256)).toList();
  }

  // Cap a list so a NODES/VALUE response fits one ~450B link-encrypted packet
  // (no per-RPC fragmentation needed). Routing still uses the full k internally.
  static List<T> _cap<T>(List<T> xs, int n) =>
      xs.length <= n ? xs : xs.sublist(0, n);

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
