// XPRS stations heard over the air join the Mesh wapp's graph snapshot as
// kind:"xprs" nodes edged to self — and stay OUT of it by default, so the
// localOnly consumers (the Chat wapp's nearby list) never see them.
import 'package:flutter_test/flutter_test.dart';

import 'package:aurora/services/reticulum/rns_service.dart';
import 'package:aurora/services/xprs/xprs_monitor.dart';
import 'package:aurora/services/xprs/xprs_packet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an XPRS beacon becomes a graph node with its stability account', () {
    XprsMonitor.instance.clear();
    final beacon = XprsPacket.parse(
        't:observation f:X3JS7Y link:ble peers:2 mail:3 uptime:26h lifetime:38day');
    expect(beacon, isNotNull);
    XprsMonitor.instance.offer(beacon!,
        bearer: 'ble', selfCallsign: 'X1TEST', rssi: -49);

    final snap = RnsService.instance.graphSnapshot(includeXprs: true);
    final nodes = (snap['nodes'] as List).cast<Map<String, dynamic>>();
    final st =
        nodes.where((n) => n['id'] == 'xprs:X3JS7Y').toList();
    expect(st, hasLength(1), reason: 'the station must appear exactly once');
    expect(st.first['kind'], 'xprs');
    expect(st.first['via'], 'ble');
    expect(st.first['geogram'], true);
    final meta = st.first['meta'] as Map;
    expect(meta['rssi'], -49);
    expect(meta['uptime'], '26h');
    expect(meta['lifetime'], '38day');
    expect(meta['mail'], 3);

    final edges = (snap['edges'] as List).cast<Map<String, dynamic>>();
    expect(
        edges.any((e) => e['to'] == 'xprs:X3JS7Y' && e['kind'] == 'xprs'), true,
        reason: 'the station is edged to self — it was heard HERE');

    // Default off: the same snapshot without the opt-in carries no xprs nodes.
    final plain = RnsService.instance.graphSnapshot();
    expect(
        (plain['nodes'] as List)
            .cast<Map<String, dynamic>>()
            .any((n) => n['kind'] == 'xprs'),
        false);

    // localOnly (the Chat nearby list) never sees them, even when asked.
    final local = RnsService.instance
        .graphSnapshot(localOnly: true, includeXprs: true);
    expect(
        (local['nodes'] as List)
            .cast<Map<String, dynamic>>()
            .any((n) => n['kind'] == 'xprs'),
        false);

    XprsMonitor.instance.clear();
  });
}
