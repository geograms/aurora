/*
 * Kademlia k-bucket routing table over the 128-bit DHT keyspace.
 *
 * Buckets are indexed by the shared-prefix length (leading zero bits of the XOR
 * distance from us): closer nodes land in higher-index buckets. Each bucket holds
 * up to k contacts in least-recently-seen..most-recently-seen order. On a full
 * bucket we keep the existing (proven-live) contacts and drop the newcomer — the
 * conservative choice under heavy churn; stale eviction is a later refinement.
 */
import 'dart:typed_data';

import 'dht_core.dart';

class RoutingTable {
  final Uint8List selfId;
  final int k;
  final List<List<DhtContact>> _buckets =
      List.generate(kDhtIdLen * 8, (_) => <DhtContact>[]);

  RoutingTable(this.selfId, {this.k = 8});

  int _bucketIndex(Uint8List id) {
    final lz = dhtLeadingZeros(dhtXor(selfId, id));
    return lz >= kDhtIdLen * 8 ? kDhtIdLen * 8 - 1 : lz;
  }

  /// Record a contact we just heard from. Moves an existing one to most-recent;
  /// adds a new one if its bucket has room.
  void add(DhtContact c) {
    if (dhtIdEquals(c.id, selfId)) return; // never store ourselves
    final bucket = _buckets[_bucketIndex(c.id)];
    final idx = bucket.indexWhere((e) => dhtIdEquals(e.id, c.id));
    if (idx >= 0) {
      bucket[idx].lastSeen = DateTime.now();
      final existing = bucket.removeAt(idx);
      bucket.add(existing); // most-recently-seen at the tail
      return;
    }
    if (bucket.length < k) bucket.add(c);
  }

  /// The [count] contacts closest (by XOR distance) to [target].
  List<DhtContact> closest(Uint8List target, int count) {
    final all = <DhtContact>[];
    for (final b in _buckets) {
      all.addAll(b);
    }
    all.sort((a, b) =>
        dhtCompare(dhtXor(a.id, target), dhtXor(b.id, target)));
    return all.length <= count ? all : all.sublist(0, count);
  }

  int get size => _buckets.fold(0, (s, b) => s + b.length);
}
