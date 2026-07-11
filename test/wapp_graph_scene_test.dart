// The reticulum graph's uplink grouping: the snapshot marks most hub-flooded
// announces relayer-less, so the scene groups them behind the direct node of
// the tcp connection they arrived on. These invariants keep the overview at
// "self + one orb per uplink + true local peers" no matter how big the flood.
import 'package:aurora/wapp/wapp_graph_scene.dart';
import 'package:flutter_test/flutter_test.dart';

RnsGraphNode node(
  String id, {
  String kind = 'leaf',
  int hops = 2,
  String via = 'tcp:hub.example.net:4242',
  String relayer = '',
  List<String> services = const [],
  bool geogram = false,
}) =>
    RnsGraphNode({
      'id': id,
      'label': id,
      'kind': kind,
      'hops': hops,
      'via': via,
      'relayer': relayer,
      'geogram': geogram,
      'services': services,
      'meta': const <String, dynamic>{},
    });

List<RnsGraphNode> prepared(List<RnsGraphNode> nodes) {
  resolveIfaces(nodes);
  return regroupByUplink(nodes);
}

void main() {
  group('classifyVia', () {
    test('maps interface tags onto the five networks', () {
      expect(classifyVia('ble'), RnsIface.ble);
      expect(classifyVia('ble5'), RnsIface.ble);
      expect(classifyVia('lan'), RnsIface.lanWifi);
      expect(classifyVia('wfd0'), RnsIface.lanWifi);
      expect(classifyVia('tcp:h:1'), RnsIface.internet);
      expect(classifyVia('udp'), RnsIface.internet);
      expect(classifyVia('lora0'), RnsIface.lora);
      expect(classifyVia('aprs'), RnsIface.radio);
      expect(classifyVia('', relayerIface: RnsIface.ble), RnsIface.ble);
      expect(classifyVia(''), RnsIface.internet);
    });
  });

  group('regroupByUplink', () {
    test('relayer-less remote nodes cluster behind their connection anchor',
        () {
      final all = prepared([
        node('self', kind: 'self', hops: 0, via: ''),
        node('relay-a', hops: 1, services: ['relay', 'lxmf']),
        node('r1'),
        node('r2', hops: 4),
        node('r3'),
      ]);
      final anchor = all.firstWhere((n) => n.id == 'relay-a');
      expect(anchor.effectiveKind, 'hub', reason: 'promoted');
      expect(anchor.members, 3);
      for (final id in ['r1', 'r2', 'r3']) {
        expect(all.firstWhere((n) => n.id == id).effectiveRelayer, 'relay-a');
      }
      // Overview: self + anchor only; members hidden until expanded.
      expect(visibleRnsNodes(all, null).map((n) => n.id),
          unorderedEquals(['self', 'relay-a']));
      expect(visibleRnsNodes(all, 'relay-a').length, 5);
    });

    test('a connection with no direct peer gets a synthetic anchor', () {
      final all = prepared([
        node('self', kind: 'self', hops: 0, via: ''),
        node('r1', via: 'tcp:use.inertia.chat:4242'),
        node('r2', via: 'tcp:use.inertia.chat:4242'),
      ]);
      final synth =
          all.firstWhere((n) => n.id == 'uplink:tcp:use.inertia.chat:4242');
      expect(synth.effectiveKind, 'hub');
      expect(synth.label, 'use.inertia.chat');
      expect(synth.members, 2);
      expect(synth.iface, RnsIface.internet);
      expect(all.firstWhere((n) => n.id == 'r1').effectiveRelayer, synth.id);
      // Synthetic id is derived from the via string, so expansion state
      // survives the 2s snapshot refresh.
      expect(RnsGraphNode.uplink('tcp:use.inertia.chat:4242').id, synth.id);
    });

    test('local (lan/ble) and snapshot-relayed nodes are left alone', () {
      final all = prepared([
        node('self', kind: 'self', hops: 0, via: ''),
        node('laptop', hops: 1, via: 'lan'),
        node('phone', hops: 1, via: 'ble'),
        node('hub-x', kind: 'hub', hops: 1),
        node('known', relayer: 'hub-x'),
      ]);
      expect(all.firstWhere((n) => n.id == 'laptop').effectiveRelayer, '');
      expect(all.firstWhere((n) => n.id == 'phone').effectiveRelayer, '');
      expect(all.firstWhere((n) => n.id == 'known').effectiveRelayer, 'hub-x');
      expect(all.firstWhere((n) => n.id == 'hub-x').members, 1);
      // Direct peers stay on the canvas when nothing is expanded.
      expect(visibleRnsNodes(all, null).map((n) => n.id),
          unorderedEquals(['self', 'laptop', 'phone', 'hub-x']));
    });

    test('the snapshot hub outranks a chatty leaf as connection anchor', () {
      final all = prepared([
        node('self', kind: 'self', hops: 0, via: ''),
        node('leafy', hops: 1, services: ['lxmf', 'chat', 'files']),
        node('hubby', kind: 'hub', hops: 1),
        node('r1'),
      ]);
      expect(all.firstWhere((n) => n.id == 'r1').effectiveRelayer, 'hubby');
    });
  });

  group('buildRnsScene', () {
    test('edges derive from the grouping: uplinks, directs, members', () {
      final all = prepared([
        node('self', kind: 'self', hops: 0, via: ''),
        node('laptop', hops: 1, via: 'lan'),
        node('relay-a', hops: 1, services: ['relay']),
        node('r1'),
        node('r2', hops: 5),
      ]);
      final collapsed = buildRnsScene(allNodes: all, expandedHubId: null);
      // self + laptop + anchor; one uplink edge + one direct edge.
      expect(collapsed.scene.nodes.length, 3);
      expect(collapsed.scene.edges.length, 2);

      final expanded = buildRnsScene(allNodes: all, expandedHubId: 'relay-a');
      expect(expanded.scene.nodes.length, 5);
      expect(expanded.scene.edges.length, 4);
      // The 5-hop member rides a ghost edge with one tick per unknown hop.
      final nodes = expanded.scene.nodes;
      final r2Index =
          nodes.indexWhere((n) => n.data.id == 'r2') + 1; // 1-based
      final ghost = expanded.scene.edges.firstWhere((e) => e.to == r2Index);
      expect(ghost.style.dashed, isTrue);
      expect(ghost.style.ticks, 3);
    });

    test('layout: anchors on the hub shell, members coned behind by hops', () {
      final all = prepared([
        node('self', kind: 'self', hops: 0, via: ''),
        node('relay-a', hops: 1, services: ['relay']),
        node('r1', hops: 2),
        node('r2', hops: 4),
      ]);
      final built = buildRnsScene(allNodes: all, expandedHubId: 'relay-a');
      final geometry = built.layout(built.scene.nodes);
      final byId = {
        for (var i = 0; i < built.scene.nodes.length; i++)
          built.scene.nodes[i].data.id: geometry.poses[i].position,
      };
      expect(byId['self']!.length, 0);
      expect(byId['relay-a']!.length, closeTo(kHubShell, 1e-6));
      expect(byId['r1']!.length, closeTo(kHubShell + kHopSpacing, 1));
      expect(byId['r2']!.length, closeTo(kHubShell + 3 * kHopSpacing, 1));
    });
  });
}
