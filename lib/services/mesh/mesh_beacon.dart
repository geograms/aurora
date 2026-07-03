/*
 * mesh_beacon — wire codec for the BLE street-mesh route beacon (doc/mesh.md §3).
 *
 * The beacon is the mesh's whole control plane: presence + node conditions +
 * a distance-vector digest of every destination this node can reach. It rides
 * the shared BLE5 extended-advert bus as its own subtype and must fit one
 * advert (~450 B), so the encoding is fixed, compact and versioned:
 *
 *   [0]      ver (1)
 *   [1]      class  — device type (MeshDeviceClass)
 *   [2]      cond   — bit0 powered, bits1-3 uptime bucket (log),
 *                     bits4-5 mobility (0 unknown/semi, 1 stationary, 2 moving),
 *                     bits6-7 storage headroom bucket
 *   [3]      callsign length n (≤ 9)
 *   [4..]    callsign (ASCII)
 *   [+0]     dv entry count K
 *   [+1..]   K × [hash3][cost1]  — 3-byte callsign hash + hop cost (1..6)
 *   [+]      have-digest length (1) + bloom bytes   — 0 in M1
 *
 * Cost semantics: an entry is "I can reach <hash> at <cost> hops". cost 1 =
 * my direct, bidirectionally-unconfirmed-or-confirmed neighbor. A receiver
 * adds 1 for the hop just taken. kMeshMaxCost caps the street at 6 hops;
 * anything that would exceed it is simply not advertised (DV "infinity").
 *
 * The 3-byte hash (first 3 bytes of SHA-256 of the uppercase callsign) keeps
 * ~110 destinations in one advert; at village scale (~200 nodes) collisions
 * are negligible (2-byte hashes birthday-collide ~30% — that's why 3).
 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const int kMeshBeaconVersion = 1;
const int kMeshMaxCost = 6;
const int kMeshMaxCallsign = 9;

/// Self-declared device type carried in the beacon class byte (doc/mesh.md §3).
enum MeshDeviceClass {
  other(0),
  phone(1),
  tablet(2),
  computer(3),
  router(4),
  esp32(5),
  baseStation(6);

  final int wire;
  const MeshDeviceClass(this.wire);

  static MeshDeviceClass fromWire(int v) => MeshDeviceClass.values
      .firstWhere((c) => c.wire == v, orElse: () => MeshDeviceClass.other);

  String get label => switch (this) {
        MeshDeviceClass.other => 'other',
        MeshDeviceClass.phone => 'phone',
        MeshDeviceClass.tablet => 'tablet',
        MeshDeviceClass.computer => 'computer',
        MeshDeviceClass.router => 'router',
        MeshDeviceClass.esp32 => 'esp32',
        MeshDeviceClass.baseStation => 'base',
      };
}

/// Mobility classification carried in cond bits 4-5.
enum MeshMobility { unknown, stationary, moving }

/// Node conditions (the cond byte, decoded).
class MeshConditions {
  final bool powered; // charging or on mains
  final int uptimeBucket; // 0..7 log buckets: <10m,30m,1h,3h,12h,1d,3d,>3d
  final MeshMobility mobility;
  final int storageBucket; // 0..3: <10MB, <50MB, <100MB, plenty

  const MeshConditions({
    this.powered = false,
    this.uptimeBucket = 0,
    this.mobility = MeshMobility.unknown,
    this.storageBucket = 3,
  });

  int get wire =>
      (powered ? 1 : 0) |
      ((uptimeBucket & 7) << 1) |
      ((mobility.index & 3) << 4) |
      ((storageBucket & 3) << 6);

  static MeshConditions fromWire(int b) => MeshConditions(
        powered: (b & 1) != 0,
        uptimeBucket: (b >> 1) & 7,
        mobility: MeshMobility.values[((b >> 4) & 3).clamp(0, 2)],
        storageBucket: (b >> 6) & 3,
      );

  /// Log bucket for an uptime duration (see field comment for the ladder).
  static int bucketForUptime(Duration d) {
    final m = d.inMinutes;
    if (m < 10) return 0;
    if (m < 30) return 1;
    if (m < 60) return 2;
    if (m < 180) return 3;
    if (m < 720) return 4;
    if (m < 1440) return 5;
    if (m < 4320) return 6;
    return 7;
  }

  static const uptimeLabels = [
    '<10m', '10-30m', '30m-1h', '1-3h', '3-12h', '12h-1d', '1-3d', '>3d'
  ];
}

/// One distance-vector digest entry: "I reach <hash> at <cost> hops".
class MeshDvEntry {
  final Uint8List hash; // 3 bytes
  final int cost; // 1..kMeshMaxCost
  const MeshDvEntry(this.hash, this.cost);
}

/// 3-byte routing hash of a callsign (uppercased, SHA-256 prefix).
Uint8List meshHash(String callsign) {
  final d = sha256.convert(utf8.encode(callsign.toUpperCase().trim())).bytes;
  return Uint8List.fromList(d.sublist(0, 3));
}

String meshHashHex(Uint8List h) =>
    h.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// A decoded (or to-be-encoded) route beacon.
class MeshBeacon {
  final String callsign;
  final MeshDeviceClass deviceClass;
  final MeshConditions cond;
  final List<MeshDvEntry> dv;
  final Uint8List have; // bloom have-digest of received am ids (M2)
  // M2 trailer: how much mail/bulk this node is carrying — lets neighbors
  // (and dial-capable peers of server-only nodes like the ESP32) decide to
  // open a GATT session and pull. Old decoders ignore trailing bytes.
  final int pendingMsgs; // 0..255
  final int pendingBulk; // 0..255

  MeshBeacon({
    required this.callsign,
    required this.deviceClass,
    required this.cond,
    this.dv = const [],
    Uint8List? have,
    this.pendingMsgs = 0,
    this.pendingBulk = 0,
  }) : have = have ?? Uint8List(0);

  Uint8List encode() {
    final cs = ascii.encode(
        callsign.toUpperCase().substring(0, callsign.length.clamp(0, kMeshMaxCallsign)));
    final b = BytesBuilder();
    b.addByte(kMeshBeaconVersion);
    b.addByte(deviceClass.wire);
    b.addByte(cond.wire);
    b.addByte(cs.length);
    b.add(cs);
    b.addByte(dv.length.clamp(0, 255));
    for (final e in dv.take(255)) {
      b.add(e.hash);
      b.addByte(e.cost.clamp(1, kMeshMaxCost));
    }
    b.addByte(have.length.clamp(0, 255));
    b.add(have.take(255).toList());
    b.addByte(pendingMsgs.clamp(0, 255));
    b.addByte(pendingBulk.clamp(0, 255));
    return b.toBytes();
  }

  /// Decode; returns null on any malformed/oversized field (never throws —
  /// beacons arrive from the open air).
  static MeshBeacon? decode(Uint8List d) {
    try {
      if (d.length < 5 || d[0] != kMeshBeaconVersion) return null;
      final cls = MeshDeviceClass.fromWire(d[1]);
      final cond = MeshConditions.fromWire(d[2]);
      final n = d[3];
      if (n > kMeshMaxCallsign || d.length < 4 + n + 1) return null;
      final cs = ascii.decode(d.sublist(4, 4 + n));
      var o = 4 + n;
      final k = d[o++];
      if (d.length < o + k * 4 + 1) return null;
      final dv = <MeshDvEntry>[];
      for (var i = 0; i < k; i++) {
        final h = Uint8List.fromList(d.sublist(o, o + 3));
        final c = d[o + 3];
        o += 4;
        if (c >= 1 && c <= kMeshMaxCost) dv.add(MeshDvEntry(h, c));
      }
      final hl = d[o++];
      if (d.length < o + hl) return null;
      final have = Uint8List.fromList(d.sublist(o, o + hl));
      o += hl;
      // Optional M2 pending trailer (absent on M1/dongle beacons).
      var pm = 0, pb = 0;
      if (d.length >= o + 2) {
        pm = d[o];
        pb = d[o + 1];
      }
      return MeshBeacon(
          callsign: cs,
          deviceClass: cls,
          cond: cond,
          dv: dv,
          have: have,
          pendingMsgs: pm,
          pendingBulk: pb);
    } catch (_) {
      return null;
    }
  }
}
