/*
 * mesh_custodian — who should carry mail we can't deliver ourselves?
 * (docs/mesh.md §6 custodian selection, M3.)
 *
 * Score = contactRatio × stability. contactRatio is the neighbor's sighting
 * EWMA (how reliably we meet it); stability rewards powered, long-uptime,
 * stationary infrastructure — the corner-shop base station beats a passing
 * phone even when both are equally audible right now.
 */
import 'mesh_beacon.dart';
import 'mesh_table.dart';

/// Stability of a node as a custodian, 0..1.
double meshStability(MeshNeighbor n) {
  var s = 0.25; // baseline: it exists
  if (n.cond.powered) s += 0.35;
  s += 0.25 * (n.cond.uptimeBucket / 7.0);
  if (n.cond.mobility == MeshMobility.stationary) s += 0.15;
  // Infrastructure classes edge out phones at equal conditions.
  if (n.deviceClass == MeshDeviceClass.baseStation ||
      n.deviceClass == MeshDeviceClass.router ||
      n.deviceClass == MeshDeviceClass.esp32) {
    s += 0.10;
  }
  return s.clamp(0.0, 1.0);
}

/// Custodian score of [n] for carrying mail toward [targetHashHex].
/// A neighbor that advertises reaching the target outranks everyone.
double meshCustodianScore(MeshNeighbor n, String? targetHashHex) {
  var score = n.contactRatio * meshStability(n);
  if (targetHashHex != null && n.digest.containsKey(targetHashHex)) {
    // It claims a path to the target — strong signal, dominate the field.
    score += 1.0;
  }
  return score;
}

/// Pick the best custodian among [table]'s bidirectional neighbors for a
/// message toward [target] (callsign). Returns its callsign, or null when
/// no neighbor clears [minScore] (better to hold than to spray). One fresh
/// sighting gives contactRatio 0.1, so a solid base station (stability ~1)
/// qualifies immediately while a flaky fresh phone (~0.25) does not.
String? meshPickCustodian(MeshTable table, String target,
    {double minScore = 0.05}) {
  final targetHex = meshHashHex(meshHash(target));
  String? best;
  var bestScore = minScore;
  for (final n in table.neighbors.values) {
    if (!n.bidirectional) continue;
    if (n.callsign.toUpperCase() == target.toUpperCase()) continue;
    final s = meshCustodianScore(n, targetHex);
    if (s > bestScore) {
      bestScore = s;
      best = n.callsign;
    }
  }
  return best;
}
