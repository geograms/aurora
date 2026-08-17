// XPRS stations heard over the air join the Mesh wapp's graph snapshot as
// kind:"xprs" nodes edged to self — and stay OUT of it by default, so the
// localOnly consumers (the Chat wapp's nearby list) never see them.
import 'package:flutter_test/flutter_test.dart';

import 'package:aurora/services/reticulum/rns_service.dart';
import 'package:aurora/services/xprs/xprs_monitor.dart';
import 'package:aurora/services/xprs/xprs_packet.dart';
import 'package:aurora/services/xprs/xprs_sig.dart';

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

  test('a station that says serve:index reads as an indexer', () {
    XprsMonitor.instance.clear();
    // What the T-Dongle airs every 600 s (docs/device-tdongle.md).
    final svc = XprsPacket.parse('t:service f:X3WWAJ '
        'serve:index,history,mailbox count:212 ts:2026-08-17_15:00:00');
    XprsMonitor.instance
        .offer(svc!, bearer: 'lan', selfCallsign: 'X1TEST');

    final node = (RnsService.instance.graphSnapshot(includeXprs: true)['nodes']
            as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((n) => n['id'] == 'xprs:X3WWAJ');
    expect((node['services'] as List), containsAll(['index', 'history']));
    expect((node['meta'] as Map)['role'], 'indexer',
        reason: 'serve:index is the whole difference from a passing phone');
    expect((node['meta'] as Map)['count'], 212);

    // A service filter now SELECTS these stations instead of dropping them.
    final indexers = (RnsService.instance
            .graphSnapshot(includeXprs: true, service: 'index')['nodes'] as List)
        .cast<Map<String, dynamic>>();
    expect(indexers.any((n) => n['id'] == 'xprs:X3WWAJ'), true);
    final files = (RnsService.instance
            .graphSnapshot(includeXprs: true, service: 'files')['nodes'] as List)
        .cast<Map<String, dynamic>>();
    expect(files.any((n) => n['id'] == 'xprs:X3WWAJ'), false,
        reason: 'it never claimed files');

    XprsMonitor.instance.clear();
  });

  test('a station is badged by the spool\'s verdict, and a forgery sticks', () {
    XprsMonitor.instance.clear();
    final beacon =
        XprsPacket.parse('t:observation f:X3WWAJ link:lan peers:1');
    XprsMonitor.instance
        .offer(beacon!, bearer: 'lan', selfCallsign: 'X1TEST');

    Map meta() => ((RnsService.instance.graphSnapshot(includeXprs: true)['nodes']
                as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((n) => n['id'] == 'xprs:X3WWAJ')['meta'] as Map);

    // Nothing judged yet says nothing — which is not the same as "unsigned".
    expect(meta().containsKey('sig'), false);

    XprsMonitor.instance.recordVerdict('X3WWAJ', XprsSigState.verified);
    expect(meta()['sig'], 'verified');

    // One forgery outranks any number of good packets, and does not wash out.
    XprsMonitor.instance.recordVerdict('X3WWAJ', XprsSigState.forged);
    XprsMonitor.instance.recordVerdict('X3WWAJ', XprsSigState.verified);
    expect(meta()['sig'], 'forged',
        reason: 'a later good packet must not clear a forgery');
    expect(meta()['sigForged'], 1);

    // A verdict for a station the air view never heard is not a sighting.
    XprsMonitor.instance.recordVerdict('X9GHOST', XprsSigState.verified);
    expect(
        (RnsService.instance.graphSnapshot(includeXprs: true)['nodes'] as List)
            .cast<Map<String, dynamic>>()
            .any((n) => n['id'] == 'xprs:X9GHOST'),
        false);

    XprsMonitor.instance.clear();
  });

  test('hears: carries through to the snapshot, and a relayed copy does not '
      'count as directly heard', () {
    XprsMonitor.instance.clear();
    final beacon = XprsPacket.parse(
        't:observation f:X3WWAJ link:lan peers:3 hears:X1TEST,X1BOA3');
    XprsMonitor.instance
        .offer(beacon!, bearer: 'lan', selfCallsign: 'X1TEST');

    final meta = ((RnsService.instance.graphSnapshot(includeXprs: true)['nodes']
                as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((n) => n['id'] == 'xprs:X3WWAJ')['meta'] as Map);
    expect(meta['hears'], ['X1TEST', 'X1BOA3'],
        reason: 'our own callsign in here is the station saying it hears us');
    expect(meta['peers'], 3);

    // A station known ONLY through a digipeater is not directly heard, so it
    // must never enter our own hears: list (section 10.6.3).
    final relayed =
        XprsPacket.parse('t:observation f:X5FAR1 link:lan via:X3WWAJ');
    XprsMonitor.instance
        .offer(relayed!, bearer: 'lan', selfCallsign: 'X1TEST');
    final direct = XprsMonitor.instance.directlyHeard();
    expect(direct, contains('X3WWAJ'));
    expect(direct, isNot(contains('X5FAR1')));

    XprsMonitor.instance.clear();
  });
}
