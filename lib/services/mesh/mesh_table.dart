/*
 * mesh_table — neighbor registry + distance-vector routing table
 * (doc/mesh.md §4).
 *
 * Fed exclusively by received route beacons. Android hears adverts in batched
 * bursts with gaps of tens of seconds, so nothing here reacts to a single
 * sighting or a single miss: neighbors age out only after kNeighborTtl of
 * silence, and the contact ratio is an EWMA over sightings, not a boolean.
 *
 * Routing rules implemented (classic RIP guards):
 *  - learn dest→(via N, cost+1) when better than what we hold;
 *  - routes THROUGH a neighbor die with that neighbor's beacon (aging);
 *  - a neighbor is usable as a next-hop only when the link is confirmed
 *    bidirectional — N's own DV digest lists US at cost 1 (asymmetric BLE
 *    links are common and a one-way neighbor is a black hole);
 *  - cost is capped at kMeshMaxCost (6): dv entries that would exceed it are
 *    not exported (DV "infinity").
 *
 * Split horizon happens at export time: [exportDv] takes the neighbor the
 * digest is being offered to and omits every route learned via that neighbor.
 * (The broadcast beacon serves all neighbors at once, so its digest can't be
 * per-neighbor — instead receivers ignore entries that point back at
 * themselves, which [ingest] does by skipping our own hash.)
 */
import 'dart:typed_data';

import 'mesh_beacon.dart';

/// How long a neighbor survives without being heard. Must ride out several
/// Android scan gaps (worst ~2 min each).
const Duration kNeighborTtl = Duration(minutes: 5);

/// A directly-heard node and everything its latest beacon told us.
class MeshNeighbor {
  final String callsign;
  final Uint8List hash;
  MeshDeviceClass deviceClass;
  MeshConditions cond;
  DateTime firstHeard;
  DateTime lastHeard;
  int lastRssi;
  int beaconsHeard = 0;

  /// EWMA of "was this neighbor heard in a given minute" — the contact ratio
  /// used for custodian scoring (doc/mesh.md §6). Updated lazily on sightings.
  double contactRatio = 0;
  DateTime _contactStamp;

  /// True when the neighbor's own DV digest lists us at cost 1 — the link is
  /// confirmed to work both ways and may carry routes.
  bool bidirectional = false;

  /// The neighbor's advertised reach: hashHex → cost (its own digest).
  Map<String, int> digest = {};

  MeshNeighbor(this.callsign, this.hash, this.deviceClass, this.cond,
      DateTime now, this.lastRssi)
      : firstHeard = now,
        lastHeard = now,
        _contactStamp = now;

  bool aliveAt(DateTime now) => now.difference(lastHeard) < kNeighborTtl;

  /// Sighting update: decay the EWMA for the minutes that passed, then count
  /// this minute as heard. Half-life ≈ 45 min of silence.
  void touchContact(DateTime now) {
    final mins = now.difference(_contactStamp).inMinutes;
    if (mins > 0) {
      var r = contactRatio;
      for (var i = 0; i < mins && i < 720; i++) r *= 0.985;
      contactRatio = r;
      _contactStamp = now;
    }
    contactRatio = contactRatio * 0.9 + 0.1;
  }
}

/// A destination we can reach through the mesh.
class MeshRoute {
  final String destHashHex;
  String viaCallsign; // next-hop neighbor
  int cost; // hops, ≤ kMeshMaxCost
  DateTime updated;
  MeshRoute(this.destHashHex, this.viaCallsign, this.cost, this.updated);
}

class MeshTable {
  final String selfCallsign;
  late final Uint8List selfHash = meshHash(selfCallsign);
  late final String selfHashHex = meshHashHex(selfHash);

  /// callsign → neighbor (direct, heard over the air).
  final Map<String, MeshNeighbor> neighbors = {};

  /// destination hashHex → best route (multi-hop, via a neighbor).
  final Map<String, MeshRoute> routes = {};

  /// hashHex → callsign, learned from beacons so the UI can name multi-hop
  /// destinations (beacons carry the sender's callsign in clear).
  final Map<String, String> names = {};

  MeshTable(this.selfCallsign);

  /// Ingest one received beacon. Returns true when topology changed (used to
  /// trigger an early beacon of our own, doc/mesh.md §4 "triggered updates").
  bool ingest(MeshBeacon b, {int rssi = 0, DateTime? at}) {
    final now = at ?? DateTime.now();
    if (b.callsign.isEmpty || b.callsign == selfCallsign) return false;
    var changed = false;

    final h = meshHash(b.callsign);
    final n = neighbors[b.callsign];
    MeshNeighbor nb;
    if (n == null) {
      nb = MeshNeighbor(b.callsign, h, b.deviceClass, b.cond, now, rssi);
      neighbors[b.callsign] = nb;
      changed = true;
    } else {
      nb = n
        ..deviceClass = b.deviceClass
        ..cond = b.cond
        ..lastHeard = now
        ..lastRssi = rssi;
    }
    nb.beaconsHeard++;
    nb.touchContact(now);
    names[meshHashHex(h)] = b.callsign;

    // The neighbor's digest: what it says it reaches (hashHex → cost).
    final dig = <String, int>{};
    var seesUs = false;
    for (final e in b.dv) {
      final hex = meshHashHex(e.hash);
      dig[hex] = e.cost;
      if (hex == selfHashHex && e.cost == 1) seesUs = true;
    }
    if (nb.bidirectional != seesUs) changed = true;
    nb.bidirectional = seesUs;
    nb.digest = dig;

    // DV learn — only through bidirectionally-confirmed neighbors.
    if (seesUs) {
      for (final ent in dig.entries) {
        if (ent.key == selfHashHex) continue; // route to self: skip
        final cost = ent.value + 1;
        if (cost > kMeshMaxCost) continue;
        final cur = routes[ent.key];
        if (cur == null ||
            cost < cur.cost ||
            (cur.viaCallsign == b.callsign && cost != cur.cost)) {
          routes[ent.key] =
              MeshRoute(ent.key, b.callsign, cost, now);
          if (cur == null || cost < cur.cost) changed = true;
        } else if (cur.viaCallsign == b.callsign) {
          cur.updated = now;
        }
      }
    }
    return changed;
  }

  /// Drop dead neighbors and every route that depended on them. Returns true
  /// when something was evicted.
  bool sweep({DateTime? at}) {
    final now = at ?? DateTime.now();
    final deadN = neighbors.values.where((n) => !n.aliveAt(now)).toList();
    for (final n in deadN) {
      neighbors.remove(n.callsign);
    }
    final live = neighbors.keys.toSet();
    final deadR = routes.values
        .where((r) =>
            !live.contains(r.viaCallsign) ||
            now.difference(r.updated) > kNeighborTtl)
        .map((r) => r.destHashHex)
        .toList();
    for (final k in deadR) {
      routes.remove(k);
    }
    return deadN.isNotEmpty || deadR.isNotEmpty;
  }

  /// The DV digest for OUR beacon: direct neighbors at cost 1 (all of them —
  /// this is also the bidirectional confirmation signal), plus learned routes.
  /// Routes are exported with split horizon per broadcast rules: a route is
  /// skipped when re-advertising it would just point its own next-hop back at
  /// us (the receiver-side skip in [ingest] handles the rest).
  List<MeshDvEntry> exportDv({int maxEntries = 100}) {
    final out = <MeshDvEntry>[];
    final seen = <String>{};
    // Direct neighbors first: freshest + they carry the bidirectional signal.
    final ns = neighbors.values.toList()
      ..sort((a, b) => b.lastHeard.compareTo(a.lastHeard));
    for (final n in ns) {
      final hex = meshHashHex(n.hash);
      if (seen.add(hex)) out.add(MeshDvEntry(n.hash, 1));
      if (out.length >= maxEntries) return out;
    }
    final rs = routes.values.toList()..sort((a, b) => a.cost.compareTo(b.cost));
    for (final r in rs) {
      if (r.cost >= kMeshMaxCost) continue; // would exceed cap downstream
      if (seen.add(r.destHashHex)) {
        out.add(MeshDvEntry(_hexBytes(r.destHashHex), r.cost));
      }
      if (out.length >= maxEntries) break;
    }
    return out;
  }

  static Uint8List _hexBytes(String hex) {
    final b = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < b.length; i++) {
      b[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return b;
  }
}
