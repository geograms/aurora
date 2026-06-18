/*
 * RNS transport: announce/path table + transport-node forwarding (RNS 1.3.5).
 *
 * Reticulum is NOT a DHT — destinations announce themselves and each node keeps,
 * per destination, the path it last heard the most recent announce on. A
 * TRANSPORT node also rebroadcasts inbound announces onto its other interfaces
 * so destinations on one segment become reachable from another (the bridging
 * that lets BLE / LoRa / LAN segments interconnect).
 *
 * Hop accounting (RNS/Transport.py): a received packet's hop count is +1'd on
 * arrival (the hop just taken). The path table stores that incremented value,
 * and a rebroadcast carries it on the wire as HEADER_2 with transport_type=
 * TRANSPORT and transport_id = this node's (relay) identity hash. The origin's
 * announce signature does not cover hops, so the original announce data is reused
 * verbatim.
 */
import 'dart:typed_data';

import 'rns_announce.dart';
import 'rns_identity.dart';
import 'rns_link.dart';
import 'rns_packet.dart';

/// RNS PATHFINDER_M — maximum hops.
const int kRnsMaxHops = 128;

/// A transport interface: something that can send a raw RNS packet, with a
/// stable label so the transport can avoid echoing a packet back out the way it
/// came.
abstract class RnsInterface {
  String get label;
  void send(Uint8List packetRaw);
}

class RnsPathEntry {
  final Uint8List destHash;
  final RnsIdentity identity;
  final Uint8List publicKey;
  Uint8List appData;
  int hops; // RNS convention: received wire hops + 1
  String via; // interface label the announce arrived on
  // Next-hop transport id (16B) when the destination is reachable THROUGH a
  // transport node (the relayer's id from the HEADER_2 announce); null when the
  // destination is a direct neighbour. To send to a transported destination we
  // emit HEADER_2 with transport_type=TRANSPORT and transport_id=[nextHop] so the
  // transport forwards it.
  Uint8List? nextHop;
  int updatedMs;

  RnsPathEntry({
    required this.destHash,
    required this.identity,
    required this.publicKey,
    required this.appData,
    required this.hops,
    required this.via,
    required this.nextHop,
    required this.updatedMs,
  });
}

class RnsTransport {
  final void Function(String msg)? log;

  /// When set, this node acts as a TRANSPORT node and rebroadcasts inbound
  /// announces onto its other interfaces, tagged with [transportId] (16-byte
  /// relay identity hash).
  Uint8List? transportId;

  final List<RnsInterface> _interfaces = [];
  final Map<String, RnsPathEntry> _paths = {};

  /// LRU cap on the path table. A phone leaf attached to a full transport hub
  /// hears the entire network's announces; without a cap the table grows
  /// unbounded (the old out-of-memory). 2048 is far more than any one device
  /// talks to while keeping memory bounded.
  static const int _maxPaths = 2048;

  // Per-second budget for verifying announces from *new* destinations, so the
  // live network's announce flood can't saturate the UI isolate. Re-announces of
  // known destinations are exempt (cheap, and keep active paths fresh).
  static const int _annBudgetPerSec = 20;
  int _annWindowStart = 0;
  int _annCount = 0;
  final Set<String> _seenPackets = {};
  // Link table for transport forwarding: link_id hex -> the two interfaces the
  // link bridges (created when we forward a LINKREQUEST). Lets us route every
  // subsequent link-addressed packet (proof, link data, resource) both ways.
  final Map<String, _LinkRoute> _linkTable = {};
  static const int _maxLinkRoutes = 4096;
  static const int _linkRouteTtlMs = 3600 * 1000; // 1h idle

  RnsTransport({this.log, this.transportId});

  int get pathCount => _paths.length;
  Iterable<RnsPathEntry> get paths => _paths.values;
  bool get isTransportNode => transportId != null;

  void addInterface(RnsInterface iface) => _interfaces.add(iface);
  void removeInterface(RnsInterface iface) =>
      _interfaces.removeWhere((i) => identical(i, iface));

  /// Originate a locally-produced packet on every interface (e.g. our own
  /// announce). Inbound relaying uses [ingest]'s rebroadcast instead.
  void sendOnAll(Uint8List raw) {
    for (final i in _interfaces) {
      i.send(raw);
    }
  }

  RnsPathEntry? pathFor(Uint8List destHash) => _paths[_hex(destHash)];
  bool hasPath(Uint8List destHash) => _paths.containsKey(_hex(destHash));

  /// The next-hop transport for reaching [identity]'s destinations. A peer
  /// announces one destination (e.g. its chat dest), but every destination of
  /// that identity is reached via the same next hop, so we look up by identity.
  /// Returns null when the peer is a direct neighbour (single hop) or unknown.
  Uint8List? nextHopForIdentity(RnsIdentity identity) {
    final want = _hex(identity.hash);
    for (final e in _paths.values) {
      if (_hex(e.identity.hash) == want) return e.nextHop;
    }
    return null;
  }

  /// Ingest an inbound packet that arrived on interface [via]. Validates
  /// announces, updates the path table, and (if a transport node) rebroadcasts
  /// the announce onto the other interfaces. Returns the validated announce or
  /// null.
  Future<RnsAnnounce?> ingest(RnsPacket p, String via) async {
    // Dedup by packet hash (RNS uses the same hashable-part scheme).
    final ph = _hex(p.packetHash());
    if (_seenPackets.contains(ph)) return null;
    _seenPackets.add(ph);
    if (_seenPackets.length > 8192) {
      _seenPackets.remove(_seenPackets.first);
    }

    // As a transport node, forward link/resource traffic that isn't for us.
    if (transportId != null && _maybeForward(p, via)) return null;

    if (p.packetType != RnsPacketType.announce) return null;

    // Connected to a busy transport hub, a phone leaf hears the WHOLE network's
    // announce stream — hundreds of new destinations a second. Verifying an
    // Ed25519 signature for each on the UI isolate pegs a core and ANRs the app.
    // So budget the verification of *new* destinations per second (the flood);
    // re-announces of destinations we already track are cheap (see trustIf) and
    // never throttled, so paths we actually use keep refreshing. A dropped new
    // announce costs nothing — that destination re-announces periodically and
    // outbound traffic reaches the hub regardless.
    final destKey = _hex(p.destHash);
    if (!_paths.containsKey(destKey)) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - _annWindowStart >= 1000) {
        _annWindowStart = nowMs;
        _annCount = 0;
      }
      if (_annCount >= _annBudgetPerSec) return null; // shed the flood
      _annCount++;
    }

    // Skip re-verifying an unchanged re-announce of a destination we already
    // verified (same key + app_data) — the common case once the table is warm.
    final ann = await validateAnnounce(p, trustIf: (dh, pk, ad) {
      final e = _paths[_hex(dh)];
      return e != null && _eq(e.publicKey, pk) && _eq(e.appData, ad);
    });
    if (ann == null) return null;

    final pathHops = p.hops + 1; // hop just taken to reach us
    // If the announce arrived relayed (HEADER_2), the relayer's id is the next
    // hop toward this destination; a direct (HEADER_1) announce is a neighbour.
    final nextHop =
        p.headerType == RnsHeaderType.header2 ? p.transportId : null;
    final key = _hex(ann.destHash);
    final existing = _paths[key];
    if (existing == null || pathHops <= existing.hops) {
      // Re-insert at the tail so recently-heard destinations are youngest —
      // the table is an LRU bounded by [_maxPaths] (below) so the network-wide
      // announce flood can't grow it without bound (the old OOM).
      _paths.remove(key);
      _paths[key] = RnsPathEntry(
        destHash: ann.destHash,
        identity: ann.identity,
        publicKey: ann.publicKey,
        appData: ann.appData,
        hops: pathHops,
        via: via,
        nextHop: nextHop,
        updatedMs: DateTime.now().millisecondsSinceEpoch,
      );
      // Evict the oldest entries past the cap (insertion order = age).
      while (_paths.length > _maxPaths) {
        _paths.remove(_paths.keys.first);
      }
    }

    _rebroadcast(p, ann, pathHops, via);
    return ann;
  }

  /// Transport-node forwarding of non-announce packets. Returns true if the
  /// packet was forwarded (i.e. it was transit traffic, not for this node):
  ///   - destType==LINK with a tracked route -> forward to the other interface
  ///     (proof, link data, resource — both directions);
  ///   - HEADER_2 addressed to us (transport_id==ours) -> forward toward the
  ///     destination's path next hop, and (for a LINKREQUEST) remember the link
  ///     so its reverse + data packets route back.
  bool _maybeForward(RnsPacket p, String via) {
    final myId = transportId;
    if (myId == null) return false;
    if (p.hops >= kRnsMaxHops) return false;

    // 1) A packet addressed to a link we bridge.
    if (p.destType == RnsDestType.link) {
      final route = _linkTable[_hex(p.destHash)];
      if (route == null) return false;
      final out = route.other(via);
      if (out == null) return false;
      route.touch();
      out.send(_reframeLink(p).pack());
      return true;
    }

    // 2) A transport-addressed packet whose next hop is us.
    if (p.headerType == RnsHeaderType.header2 &&
        p.transportId != null &&
        _eq(p.transportId!, myId) &&
        p.transportType == RnsTransportType.transport) {
      final path = _paths[_hex(p.destHash)];
      if (path == null) return false; // no route to the destination
      final outIface = _ifaceByLabel(path.via);
      if (outIface == null) return false;

      if (p.packetType == RnsPacketType.linkRequest) {
        final inIface = _ifaceByLabel(via);
        if (inIface != null) {
          _pruneLinkRoutes();
          _linkTable[_hex(RnsLink.linkIdFromRequest(p))] =
              _LinkRoute(inIface, outIface);
        }
      }
      outIface.send(_forwardToward(p, path).pack());
      return true;
    }
    return false;
  }

  // Forward a dest-addressed packet one hop toward [path]. If the destination is
  // a direct neighbour of the next node (path.nextHop == null) send HEADER_1
  // (consume the transport id); otherwise keep transport-addressing to the next
  // transport. hops is incremented.
  RnsPacket _forwardToward(RnsPacket p, RnsPathEntry path) {
    final toTransport = path.nextHop != null;
    return RnsPacket(
      destHash: p.destHash,
      data: p.data,
      headerType:
          toTransport ? RnsHeaderType.header2 : RnsHeaderType.header1,
      transportType: toTransport
          ? RnsTransportType.transport
          : RnsTransportType.broadcast,
      destType: p.destType,
      packetType: p.packetType,
      context: p.context,
      contextFlag: p.contextFlag,
      transportId: toTransport ? path.nextHop : null,
      hops: p.hops + 1,
    );
  }

  // Forward a link-addressed packet to the opposite side of the bridge. The next
  // node is a direct neighbour here (leaf-hub-leaf), so HEADER_1 by link_id; the
  // endpoint matches on the link_id regardless of header form.
  RnsPacket _reframeLink(RnsPacket p) => RnsPacket(
        destHash: p.destHash, // = link_id
        data: p.data,
        headerType: RnsHeaderType.header1,
        transportType: RnsTransportType.broadcast,
        destType: RnsDestType.link,
        packetType: p.packetType,
        context: p.context,
        contextFlag: p.contextFlag,
        hops: p.hops + 1,
      );

  RnsInterface? _ifaceByLabel(String label) {
    for (final i in _interfaces) {
      if (i.label == label) return i;
    }
    return null;
  }

  void _pruneLinkRoutes() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _linkTable.removeWhere((_, r) => now - r.lastMs > _linkRouteTtlMs);
    while (_linkTable.length >= _maxLinkRoutes) {
      _linkTable.remove(_linkTable.keys.first);
    }
  }

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // Rebroadcast an announce onto every interface except the one it arrived on.
  void _rebroadcast(RnsPacket p, RnsAnnounce ann, int pathHops, String via) {
    final tid = transportId;
    if (tid == null) return;
    if (pathHops >= kRnsMaxHops) return;
    final others = _interfaces.where((i) => i.label != via).toList();
    if (others.isEmpty) return;

    final relay = RnsPacket(
      destHash: ann.destHash,
      data: p.data,
      headerType: RnsHeaderType.header2,
      transportType: RnsTransportType.transport,
      destType: RnsDestType.single,
      packetType: RnsPacketType.announce,
      context: p.context,
      contextFlag: p.contextFlag,
      transportId: tid,
      hops: pathHops,
    );
    final raw = relay.pack();
    for (final iface in others) {
      iface.send(raw);
      log?.call(
          'rebroadcast ${_hex(ann.destHash)} -> ${iface.label} hops=$pathHops');
    }
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}

/// A bridged link: the two interfaces a transit link's packets route between.
class _LinkRoute {
  final RnsInterface a;
  final RnsInterface b;
  int lastMs;
  _LinkRoute(this.a, this.b) : lastMs = DateTime.now().millisecondsSinceEpoch;

  /// The interface opposite to the one a packet arrived on ([viaLabel]).
  RnsInterface? other(String viaLabel) {
    if (viaLabel == a.label) return b;
    if (viaLabel == b.label) return a;
    return null;
  }

  void touch() => lastMs = DateTime.now().millisecondsSinceEpoch;
}
