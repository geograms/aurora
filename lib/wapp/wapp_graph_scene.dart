// Scene assembly for the reticulum wapp's 3D network graph: turns the wapp's
// `ui.graph.set` {nodes,edges} snapshot into a graph3d scene — node parsing,
// interface classification, uplink grouping, orb styling, ego layout. Pure
// data + math, no widgets, so it is unit-testable and keeps wapp_graph.dart
// (a part of wapp_page.dart) free of extra imports.
//
// The point of the whole view: show WHAT is connected to this device and
// FROM WHERE. The snapshot alone can't say — a hub floods hundreds of cached
// announces at us and most arrive with no relayer (the transport path table
// only records a nextHop for destinations it routed), so naively every
// remote node looks like a direct neighbour and the graph collapses into an
// unreadable starburst. What every announce DOES carry is `via`: the local
// connection it arrived through ('tcp:host:port', 'lan', 'ble'). So the view
// groups by uplink: the hops==1 node heard on a tcp connection anchors it,
// everything else heard on that connection clusters behind the anchor, and
// the overview is self + one orb per uplink + true local peers.

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart' show Colors;
import 'package:graph3d/graph3d.dart';
import 'package:vector_math/vector_math_64.dart' show Quaternion, Vector3;

/// The network a device is reached over, grouped the way a person thinks
/// about them: LAN and WiFi are one local network, TCP and UDP are both just
/// "the internet". The palette is the graph's primary code — blue, green,
/// yellow, purple and red, far apart on a dark background. LoRa and packet
/// radio are not carried by the Dart stack yet; their chips render dimmed.
enum RnsIface {
  ble('BLE', Color(0xFF4FC3F7)),
  lanWifi('LAN/WiFi', Color(0xFF66BB6A)),
  internet('Internet', Color(0xFFFFD54F)),
  lora('LoRa', Color(0xFFB388FF), forwardLooking: true),
  radio('Radio', Color(0xFFFF5252), forwardLooking: true);

  const RnsIface(this.label, this.color, {this.forwardLooking = false});

  final String label;
  final Color color;
  final bool forwardLooking;
}

/// Classify a node's `via` tag (the local interface its announce arrived on:
/// 'lan', 'ble', 'ble5', 'tcp:host:port', 'wfd…'). An empty via — the
/// synthesized self node or a hub we route through but never heard announce —
/// falls back to its relayer's network, else the internet (bootstrap hubs are
/// TCP endpoints today).
RnsIface classifyVia(String via, {RnsIface? relayerIface}) {
  final v = via.toLowerCase();
  if (v.startsWith('ble')) return RnsIface.ble;
  if (v.startsWith('lan') || v.startsWith('wfd') || v.startsWith('wifi')) {
    return RnsIface.lanWifi;
  }
  if (v.startsWith('tcp') || v.startsWith('udp')) return RnsIface.internet;
  if (v.startsWith('lora')) return RnsIface.lora;
  if (v.startsWith('radio') || v.startsWith('aprs') || v.startsWith('kiss')) {
    return RnsIface.radio;
  }
  return relayerIface ?? RnsIface.internet;
}

/// One node of the observed-network snapshot (see RnsService.graphSnapshot).
class RnsGraphNode {
  final String id;
  final String label;
  final String kind; // self | hub | leaf (as the snapshot saw it)
  final bool geogram;
  final String relayer;
  final List<String> services;
  final int hops;
  final String via;
  final Map<String, dynamic> meta;
  final int childCount;
  // 1:1 reachability hint from the host: 'lxmf' | 'sf' | 'chat' | ''.
  final String dm;
  final String npub;
  final int firstSeenMs;
  final List<String> relayers;

  /// The network this node is reached over — resolved after parsing.
  RnsIface iface = RnsIface.internet;

  /// Who this node actually sits behind on the canvas. Starts as the
  /// snapshot's relayer; [regroupByUplink] fills it in from the shared `via`
  /// connection when the snapshot left it empty. Empty = a true direct peer.
  String effectiveRelayer = '';

  /// Promoted to an uplink anchor by [regroupByUplink]: the direct node a
  /// whole connection's worth of remote announces clusters behind.
  bool promotedHub = false;

  /// Members clustered behind this node (snapshot children + regrouped).
  int members = 0;

  /// How the view treats this node, after regrouping.
  String get effectiveKind => kind == 'self'
      ? 'self'
      : (kind == 'hub' || promotedHub)
          ? 'hub'
          : 'leaf';

  RnsGraphNode(Map<String, dynamic> m)
      : id = (m['id'] ?? '').toString(),
        label = (m['label'] ?? m['id'] ?? '').toString(),
        kind = (m['kind'] ?? 'leaf').toString(),
        dm = (m['dm'] ?? '').toString(),
        npub = ((m['meta'] as Map?)?['npub'] ?? '').toString(),
        geogram = m['geogram'] == true,
        relayer = (m['relayer'] ?? '').toString(),
        services =
            (m['services'] as List?)?.map((e) => e.toString()).toList() ??
                const [],
        hops = (m['hops'] as num?)?.toInt() ?? 0,
        via = (m['via'] ?? '').toString(),
        meta = (m['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
        firstSeenMs = ((m['meta'] as Map?)?['firstSeen'] as num?)?.toInt() ?? 0,
        relayers = ((m['meta'] as Map?)?['relayers'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        childCount = ((m['meta'] as Map?)?['children'] as num?)?.toInt() ?? 0 {
    effectiveRelayer = relayer;
    members = childCount;
  }

  /// A synthesized uplink anchor for a connection whose direct peer we never
  /// heard announce (e.g. the hub only forwards). Keyed by the via string so
  /// it keeps its identity — and any expansion state — across snapshots.
  RnsGraphNode.uplink(String viaTag)
      : id = 'uplink:$viaTag',
        label = uplinkLabel(viaTag),
        kind = 'hub',
        dm = '',
        npub = '',
        geogram = false,
        relayer = '',
        services = const [],
        hops = 1,
        via = viaTag,
        meta = const {},
        firstSeenMs = 0,
        relayers = const [],
        childCount = 0;
}

/// 'tcp:use.inertia.chat:4242' → 'use.inertia.chat' — the readable name of a
/// connection when no announce named its far end.
String uplinkLabel(String via) {
  final parts = via.split(':');
  return parts.length >= 2 ? parts[1] : via;
}

/// Resolve every node's network, letting empty-via nodes inherit from their
/// relayer.
void resolveIfaces(List<RnsGraphNode> nodes) {
  final byId = {for (final n in nodes) n.id: n};
  for (final n in nodes) {
    n.iface = classifyVia(n.via);
  }
  for (final n in nodes) {
    if (n.via.isEmpty && n.relayer.isNotEmpty) {
      final relay = byId[n.relayer];
      if (relay != null) n.iface = relay.iface;
    }
  }
}

/// Group the flood behind its uplinks. Remote nodes (hops > 1) whose snapshot
/// relayer is empty cluster behind the direct (hops == 1) node heard on the
/// same point-to-point connection — its `via` names the connection. Local
/// broadcast networks (lan/ble) have no single far end, so their nodes are
/// left as they came. Returns the full node list, plus a synthesized anchor
/// per connection that had remote nodes but no direct peer to anchor them.
///
/// Call AFTER [resolveIfaces]; mutates effectiveRelayer/promotedHub/members.
List<RnsGraphNode> regroupByUplink(List<RnsGraphNode> nodes) {
  bool pointToPoint(String via) =>
      via.startsWith('tcp') || via.startsWith('udp');

  // One anchor per connection: prefer the snapshot's own hub for that via,
  // else the direct node with the most to say for itself (a relay, then the
  // most services), else synthesize.
  final anchorByVia = <String, RnsGraphNode>{};
  for (final n in nodes) {
    if (n.hops != 1 || !pointToPoint(n.via)) continue;
    final current = anchorByVia[n.via];
    if (current == null || _anchorRank(n) > _anchorRank(current)) {
      anchorByVia[n.via] = n;
    }
  }

  final out = List<RnsGraphNode>.from(nodes);
  final needAnchor = <String>{};
  for (final n in nodes) {
    if (n.effectiveRelayer.isNotEmpty) continue; // snapshot already knew
    if (n.effectiveKind != 'leaf') continue;
    if (n.hops <= 1 || !pointToPoint(n.via)) continue;
    final anchor = anchorByVia[n.via];
    if (anchor != null) {
      n.effectiveRelayer = anchor.id;
    } else {
      n.effectiveRelayer = 'uplink:${n.via}';
      needAnchor.add(n.via);
    }
  }
  for (final via in needAnchor) {
    final synth = RnsGraphNode.uplink(via)..iface = classifyVia(via);
    anchorByVia[via] = synth;
    out.add(synth);
  }

  // Promote anchors and count everyone's clustered members.
  final memberCount = <String, int>{};
  for (final n in out) {
    if (n.effectiveRelayer.isNotEmpty) {
      memberCount[n.effectiveRelayer] =
          (memberCount[n.effectiveRelayer] ?? 0) + 1;
    }
  }
  final byId = {for (final n in out) n.id: n};
  memberCount.forEach((id, count) {
    final anchor = byId[id];
    if (anchor == null) return;
    anchor.members = math.max(anchor.childCount, count);
    if (anchor.effectiveKind == 'leaf') anchor.promotedHub = true;
  });
  return out;
}

int _anchorRank(RnsGraphNode n) {
  var rank = 0;
  if (n.kind == 'hub') rank += 100;
  if (n.services.contains('relay')) rank += 10;
  rank += n.services.length;
  return rank;
}

// Ego-layout shells (world units; graph3d's own scale reference is a
// 120-wide card, orbs 17-46).
const double kPeerShell = 620; // direct neighbours
const double kHubShell = 1300; // uplink anchors / relayers
const double kHopSpacing = 340; // extra radius per hop behind an anchor

/// Which nodes are on the canvas: self, every uplink anchor and true direct
/// peer always; clustered members only while their anchor is the expanded
/// one (one cluster at a time keeps busy-hub snapshots bounded).
List<RnsGraphNode> visibleRnsNodes(
  List<RnsGraphNode> allNodes,
  String? expandedHubId,
) {
  final seen = <String>{};
  final vis = <RnsGraphNode>[];
  void add(RnsGraphNode n) {
    if (seen.add(n.id)) vis.add(n);
  }

  for (final n in allNodes) {
    if (n.effectiveKind == 'self' || n.effectiveKind == 'hub') add(n);
  }
  for (final n in allNodes) {
    if (n.effectiveKind != 'leaf') continue;
    if (n.effectiveRelayer.isEmpty || n.effectiveRelayer == expandedHubId) {
      add(n);
    }
  }
  return vis;
}

/// Build the graph3d scene for one snapshot: visible nodes keyed by identity
/// (so the 2s refresh glides instead of flickering), edges DERIVED from the
/// grouping (the snapshot's own edges predate it), and the ego layout.
({GraphScene<RnsGraphNode> scene, LayoutStrategy<RnsGraphNode> layout})
    buildRnsScene({
  required List<RnsGraphNode> allNodes,
  required String? expandedHubId,
}) {
  final vis = visibleRnsNodes(allNodes, expandedHubId);
  final idOf = <String, int>{
    for (var i = 0; i < vis.length; i++) vis[i].id: i + 1,
  };
  int? selfId;
  for (final n in vis) {
    if (n.effectiveKind == 'self') selfId = idOf[n.id];
  }

  final nodes = <SceneNode<RnsGraphNode>>[
    for (final n in vis) SceneNode<RnsGraphNode>(key: n.id, data: n),
  ];

  final edges = <SceneEdge>[];
  for (final n in vis) {
    final to = idOf[n.id]!;
    switch (n.effectiveKind) {
      case 'self':
        break;
      case 'hub': // uplink: self → anchor, traffic crawling along it
        if (selfId != null) {
          edges.add(SceneEdge(
            selfId,
            to,
            style: EdgeStyle(
              color: n.iface.color.withValues(alpha: 0.75),
              width: 1.6,
              glow: true,
              crawler: true,
              pulseCount: 2,
            ),
          ));
        }
      default:
        final from =
            n.effectiveRelayer.isEmpty ? selfId : idOf[n.effectiveRelayer];
        if (from == null) break;
        if (n.effectiveRelayer.isEmpty) {
          // A true local peer.
          edges.add(SceneEdge(
            from,
            to,
            style: EdgeStyle(
              color: n.iface.color.withValues(alpha: 0.65),
              width: 1.0,
              glow: true,
            ),
          ));
        } else {
          // An expanded cluster member; extra hops render as ghost ticks.
          final ghost = n.hops > 2;
          edges.add(SceneEdge(
            from,
            to,
            style: EdgeStyle(
              color: n.iface.color.withValues(alpha: 0.3),
              width: 0.8,
              dashed: ghost,
              ticks: ghost ? n.hops - 2 : 0,
            ),
          ));
        }
    }
  }

  return (
    scene: GraphScene<RnsGraphNode>(nodes: nodes, edges: edges),
    layout: rnsEgoLayout,
  );
}

/// Azimuth sector per network present on the direct ring (anchors + direct
/// peers), width proportional to sqrt(member count), fixed enum order.
Map<RnsIface, (double, double)> _egoSectors(List<RnsGraphNode> all) {
  final counts = <RnsIface, int>{};
  for (final n in all) {
    if (n.effectiveKind == 'hub' ||
        (n.effectiveKind == 'leaf' && n.effectiveRelayer.isEmpty)) {
      counts[n.iface] = (counts[n.iface] ?? 0) + 1;
    }
  }
  final present = <RnsIface>[
    for (final iface in RnsIface.values)
      if (counts.containsKey(iface)) iface,
  ];
  if (present.isEmpty) return const {};
  final weights = <double>[
    for (final iface in present) math.max(math.sqrt(counts[iface]!), 1.4),
  ];
  final total = weights.fold(0.0, (a, b) => a + b);
  final sectors = <RnsIface, (double, double)>{};
  var theta = 0.0;
  for (var i = 0; i < present.length; i++) {
    final sweep = 2 * math.pi * weights[i] / total;
    sectors[present[i]] = (theta, sweep);
    theta += sweep;
  }
  return sectors;
}

/// Ego layout: self at the origin, direct peers scattered on their network's
/// sector of the inner shell, uplink anchors on the equator of the outer
/// shell, and an expanded anchor's members coned behind it with radius
/// growing by hop count (equal-hop nodes read as rings).
LayoutGeometry rnsEgoLayout(List<SceneNode<RnsGraphNode>> nodes) {
  final all = <RnsGraphNode>[for (final n in nodes) n.data];
  final sectors = _egoSectors(all);

  final positions = List<Vector3?>.filled(all.length, null);
  final azimuthOf = <String, double>{};

  final byIfacePeers = <RnsIface, List<int>>{};
  final byIfaceHubs = <RnsIface, List<int>>{};
  for (var i = 0; i < all.length; i++) {
    final n = all[i];
    if (n.effectiveKind == 'self') {
      positions[i] = Vector3.zero();
    } else if (n.effectiveKind == 'hub') {
      byIfaceHubs.putIfAbsent(n.iface, () => <int>[]).add(i);
    } else if (n.effectiveRelayer.isEmpty) {
      byIfacePeers.putIfAbsent(n.iface, () => <int>[]).add(i);
    }
  }

  byIfacePeers.forEach((iface, indices) {
    final (start, sweep) = sectors[iface] ?? (0.0, 2 * math.pi);
    final poses = sectorShellPoses(
      indices.length,
      radius: kPeerShell,
      thetaStart: start + sweep * 0.08,
      thetaSweep: sweep * 0.84,
      phiSpread: math.pi / 2.4,
    );
    for (var j = 0; j < indices.length; j++) {
      positions[indices[j]] = poses[j].position;
      azimuthOf[all[indices[j]].id] =
          start + sweep * 0.08 + (j + 0.5) / indices.length * sweep * 0.84;
    }
  });

  byIfaceHubs.forEach((iface, indices) {
    final (start, sweep) = sectors[iface] ?? (0.0, 2 * math.pi);
    for (var j = 0; j < indices.length; j++) {
      final theta = start + sweep * (j + 1) / (indices.length + 1);
      positions[indices[j]] = Vector3(
        kHubShell * math.sin(theta),
        0,
        kHubShell * math.cos(theta),
      );
      azimuthOf[all[indices[j]].id] = theta;
    }
  });

  // Expanded-cluster members: a cone of hop shells behind the anchor,
  // golden-ratio elevation jitter so big clusters fill the fan.
  final perHubCount = <String, int>{};
  for (final n in all) {
    if (n.effectiveKind == 'leaf' && n.effectiveRelayer.isNotEmpty) {
      perHubCount[n.effectiveRelayer] =
          (perHubCount[n.effectiveRelayer] ?? 0) + 1;
    }
  }
  final perHubSeen = <String, int>{};
  const golden = 0.6180339887498949;
  for (var i = 0; i < all.length; i++) {
    if (positions[i] != null) continue;
    final n = all[i];
    final hubAzimuth = azimuthOf[n.effectiveRelayer] ?? 0;
    final siblings = perHubCount[n.effectiveRelayer] ?? 1;
    final ordinal =
        perHubSeen.update(n.effectiveRelayer, (v) => v + 1, ifAbsent: () => 0);
    final spreadHalf = siblings > 40 ? 0.5 : 0.28;
    final theta =
        hubAzimuth + ((ordinal + 0.5) / siblings - 0.5) * 2 * spreadHalf;
    final phi = math.pi / 2 +
        (((ordinal * golden) % 1.0) - 0.5) * (siblings > 40 ? 0.9 : 0.45);
    final radius = kHubShell + kHopSpacing * math.max(1, n.hops - 1);
    positions[i] = Vector3(
      radius * math.sin(phi) * math.sin(theta),
      radius * math.cos(phi),
      radius * math.sin(phi) * math.cos(theta),
    );
  }

  return LayoutGeometry.fromPoses(<Pose>[
    for (final position in positions) Pose(position!, Quaternion.identity()),
  ]);
}

/// How each node looks as an orb: hierarchy by size and dressing, network by
/// colour. Geogram devices wear a green second ring (the 2D view's code).
NodeSprite spriteOfRnsNode(
  SceneNode<RnsGraphNode> node, {
  String? expandedHubId,
}) {
  final n = node.data;
  const geogramGreen = Color(0xFF3FB950);
  switch (n.effectiveKind) {
    case 'self':
      return NodeSprite(
        radius: 46,
        coreColor: const Color(0xFFA7FFF6),
        haloScale: 3.0,
        ringColor: const Color(0xFFE0FFFF),
        label: n.label.isNotEmpty ? n.label : 'this node',
        labelMinPx: 2.5,
      );
    case 'hub':
      // Anchors carry the "how big is this hub" number as their badge —
      // that number IS the point of the orb, so it renders at any distance.
      return NodeSprite(
        radius: 56,
        coreColor: n.iface.color,
        haloScale: 2.6,
        ringColor: Colors.white70,
        secondaryColor: n.geogram ? geogramGreen : null,
        badge:
            n.members > 0 && n.id != expandedHubId ? '${n.members}' : null,
        badgeMinPx: 2.5,
        label: n.label,
        labelMinPx: 2.5,
      );
    default:
      final direct = n.effectiveRelayer.isEmpty;
      return NodeSprite(
        radius: direct ? 22 : 17,
        coreColor: n.iface.color,
        secondaryColor: n.geogram ? geogramGreen : null,
        label: n.label,
        labelMinPx: direct ? 2.5 : null,
      );
  }
}
