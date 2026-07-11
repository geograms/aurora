// Scene assembly for the reticulum wapp's 3D network graph: turns the wapp's
// `ui.graph.set` {nodes,edges} snapshot into a graph3d scene — node parsing,
// interface classification, orb styling, ego layout. Pure data + math, no
// widgets, so it is unit-testable and keeps wapp_graph.dart (a part of
// wapp_page.dart) free of extra imports.
//
// The topology mirrors what one Reticulum vantage node can actually know:
// self at the centre, direct neighbours on an inner shell, the hubs it routes
// through on an outer shell, and each hub's heard peers behind it. Relayed
// leaves stay aggregated behind their hub's badge until it is expanded (one
// cluster at a time keeps hundreds-of-node snapshots bounded).

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
/// 'lan', 'ble', 'ble5', 'tcp:host:port', 'wfd…', …). An empty via — the
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
  final String kind; // self | hub | leaf
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

  /// The network this node is reached over — resolved after parsing (empty-via
  /// nodes inherit their relayer's network, see [resolveIfaces]).
  RnsIface iface = RnsIface.internet;

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
        childCount = ((m['meta'] as Map?)?['children'] as num?)?.toInt() ?? 0;
}

/// Resolve every node's network, letting empty-via nodes inherit from their
/// relayer. Mutates [nodes] in place (iface is the one non-final field).
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

class RnsGraphEdge {
  final String from, to, kind; // kind: uplink | relay | direct
  RnsGraphEdge(this.from, this.to, this.kind);
}

// Ego-layout shells (world units; graph3d's own scale reference is a
// 120-wide card, orbs 17-46).
const double kPeerShell = 620; // direct neighbours
const double kHubShell = 1300; // hubs / relayers
const double kHopSpacing = 340; // extra radius per hop behind a hub

/// Which snapshot nodes are on the canvas: self + hubs + direct leaves
/// always; relayed leaves only while their hub is the expanded one.
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
    if (n.kind == 'self' || n.kind == 'hub') add(n);
  }
  for (final n in allNodes) {
    if (n.kind != 'leaf') continue;
    if (n.relayer.isEmpty || n.relayer == expandedHubId) add(n);
  }
  return vis;
}

/// Build the graph3d scene for one snapshot: visible nodes keyed by identity
/// (so the 2s refresh glides instead of flickering), edges styled by network
/// colour, and the ego layout.
({GraphScene<RnsGraphNode> scene, LayoutStrategy<RnsGraphNode> layout})
    buildRnsScene({
  required List<RnsGraphNode> allNodes,
  required List<RnsGraphEdge> allEdges,
  required String? expandedHubId,
}) {
  final vis = visibleRnsNodes(allNodes, expandedHubId);
  final idOf = <String, int>{
    for (var i = 0; i < vis.length; i++) vis[i].id: i + 1,
  };
  final byId = {for (final n in vis) n.id: n};

  final nodes = <SceneNode<RnsGraphNode>>[
    for (final n in vis) SceneNode<RnsGraphNode>(key: n.id, data: n),
  ];

  final edges = <SceneEdge>[];
  for (final e in allEdges) {
    final from = idOf[e.from];
    final to = idOf[e.to];
    if (from == null || to == null) continue;
    final target = byId[e.to]!;
    switch (e.kind) {
      case 'uplink': // self → hub
        edges.add(SceneEdge(
          from,
          to,
          style: EdgeStyle(
            color: target.iface.color.withValues(alpha: 0.75),
            width: 1.6,
            glow: true,
            crawler: true,
            pulseCount: 2,
          ),
        ));
      case 'relay': // hub → expanded leaf; extra hops render as ghost ticks
        final ghost = target.hops > 2;
        edges.add(SceneEdge(
          from,
          to,
          style: EdgeStyle(
            color: target.iface.color.withValues(alpha: 0.3),
            width: 0.8,
            dashed: ghost,
            ticks: ghost ? target.hops - 2 : 0,
          ),
        ));
      default: // direct: self → neighbour
        edges.add(SceneEdge(
          from,
          to,
          style: EdgeStyle(
            color: target.iface.color.withValues(alpha: 0.65),
            width: 1.0,
            glow: true,
          ),
        ));
    }
  }

  return (
    scene: GraphScene<RnsGraphNode>(nodes: nodes, edges: edges),
    layout: rnsEgoLayout,
  );
}

/// Azimuth sector per network present among the direct ring (hubs + direct
/// leaves), width proportional to sqrt(member count), fixed enum order.
Map<RnsIface, (double, double)> _egoSectors(List<RnsGraphNode> all) {
  final counts = <RnsIface, int>{};
  for (final n in all) {
    if (n.kind == 'hub' || (n.kind == 'leaf' && n.relayer.isEmpty)) {
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

/// Ego layout: self at the origin, direct neighbours scattered on their
/// network's sector of the inner shell, hubs on the equator of the outer
/// shell, and an expanded hub's peers coned behind it with radius growing by
/// hop count (equal-hop nodes read as rings).
LayoutGeometry rnsEgoLayout(List<SceneNode<RnsGraphNode>> nodes) {
  final all = <RnsGraphNode>[for (final n in nodes) n.data];
  final sectors = _egoSectors(all);

  final positions = List<Vector3?>.filled(all.length, null);
  final azimuthOf = <String, double>{};

  final byIfacePeers = <RnsIface, List<int>>{};
  final byIfaceHubs = <RnsIface, List<int>>{};
  for (var i = 0; i < all.length; i++) {
    final n = all[i];
    if (n.kind == 'self') {
      positions[i] = Vector3.zero();
    } else if (n.kind == 'hub') {
      byIfaceHubs.putIfAbsent(n.iface, () => <int>[]).add(i);
    } else if (n.relayer.isEmpty) {
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

  // Expanded-hub peers: a cone of hop shells behind the hub, golden-ratio
  // elevation jitter so big clusters fill the fan instead of a line.
  final perHubCount = <String, int>{};
  for (final n in all) {
    if (positionsPending(n)) {
      perHubCount[n.relayer] = (perHubCount[n.relayer] ?? 0) + 1;
    }
  }
  final perHubSeen = <String, int>{};
  const golden = 0.6180339887498949;
  for (var i = 0; i < all.length; i++) {
    if (positions[i] != null) continue;
    final n = all[i];
    final hubAzimuth = azimuthOf[n.relayer] ?? 0;
    final siblings = perHubCount[n.relayer] ?? 1;
    final ordinal = perHubSeen.update(n.relayer, (v) => v + 1, ifAbsent: () => 0);
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

/// A node still awaiting a position after the direct passes: a relayed leaf.
bool positionsPending(RnsGraphNode n) =>
    n.kind == 'leaf' && n.relayer.isNotEmpty;

/// How each node looks as an orb: hierarchy by size and dressing, network by
/// colour. Geogram devices wear a green second ring (the 2D view's code).
NodeSprite spriteOfRnsNode(
  SceneNode<RnsGraphNode> node, {
  String? expandedHubId,
}) {
  final n = node.data;
  const geogramGreen = Color(0xFF3FB950);
  switch (n.kind) {
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
      return NodeSprite(
        radius: 40,
        coreColor: n.iface.color,
        haloScale: 2.8,
        ringColor: Colors.white70,
        badge: n.childCount > 0 && n.id != expandedHubId
            ? '${n.childCount}'
            : null,
        label: n.label,
        labelMinPx: 2.5,
      );
    default:
      final direct = n.relayer.isEmpty;
      return NodeSprite(
        radius: direct ? 22 : 17,
        coreColor: n.iface.color,
        secondaryColor: n.geogram ? geogramGreen : null,
        label: n.label,
        labelMinPx: direct ? 2.5 : null,
      );
  }
}
