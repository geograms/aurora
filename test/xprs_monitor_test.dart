// What the device has heard on the air.
//
// The property that has to hold is the one a user would never notice being
// broken: internet traffic must not appear in a view that says "over the air".
// It is enforced by what is collected rather than by a filter, so the test is
// that offering an internet-borne packet leaves no trace at all.

import 'dart:convert';

import 'package:aurora/services/xprs/xprs_monitor.dart';
import 'package:aurora/services/xprs/xprs_packet.dart';
import 'package:flutter_test/flutter_test.dart';

XprsPacket p(String wire) => XprsPacket.parse(wire)!;

const beacon =
    't:observation f:X1RD89 link:ble peers:12 mail:3 hears:X1A67X,X32DVA';
const mailForUs = 't:message f:X1RD89 d:X1A67X ts:2026-08-08_14:26:40 m:hello';
const mailForOther =
    't:message f:X1RD89 d:X32DVA ts:2026-08-08_14:26:40 m:not yours';

void main() {
  setUp(() => XprsMonitor.instance.clear());

  group('collecting', () {
    test('a heard packet becomes a sighting and a station', () {
      XprsMonitor.instance
          .offer(p(beacon), bearer: 'ble', selfCallsign: 'X1A67X', rssi: -37);
      expect(XprsMonitor.instance.ring.length, 1);
      expect(XprsMonitor.instance.stations.keys, ['X1RD89']);
      final s = XprsMonitor.instance.stations['X1RD89']!;
      expect(s.bearer, 'ble');
      expect(s.rssi, -37);
      expect(s.peers, 12);
      expect(s.mail, 3);
    });

    test('traffic for other people is kept, and marked as not ours', () {
      final m = XprsMonitor.instance;
      m.offer(p(mailForUs), bearer: 'ble', selfCallsign: 'X1A67X');
      m.offer(p(mailForOther), bearer: 'ble', selfCallsign: 'X1A67X');
      expect(m.ring.length, 2, reason: 'both are shown; the mesh carries both');
      expect(m.ring[0].mine, isTrue);
      expect(m.ring[1].mine, isFalse);
      expect(m.ring[1].to, 'X32DVA');
    });

    test('our own packet heard back is not a sighting of somebody else', () {
      XprsMonitor.instance.offer(
          p('t:observation f:X1A67X link:ble peers:1 hears:X1RD89'),
          bearer: 'ble',
          selfCallsign: 'X1A67X');
      expect(XprsMonitor.instance.ring, isEmpty);
      expect(XprsMonitor.instance.stations, isEmpty);
    });

    test('an ordinary message does not erase what a beacon said', () {
      final m = XprsMonitor.instance;
      m.offer(p(beacon), bearer: 'ble', selfCallsign: 'X1A67X');
      m.offer(p(mailForUs), bearer: 'ble', selfCallsign: 'X1A67X');
      final s = m.stations['X1RD89']!;
      expect(s.peers, 12, reason: 'a message says nothing about peers');
      expect(s.mail, 3);
      expect(s.packets, 2);
    });

    test('the ring is bounded', () {
      final m = XprsMonitor.instance;
      for (var i = 0; i < XprsMonitor.ringMax + 50; i++) {
        m.offer(p('t:message f:X1RD89 d:X1A67X ts:2026-08-08_14:26:40 m:$i'),
            bearer: 'ble', selfCallsign: 'X1A67X');
      }
      expect(m.ring.length, XprsMonitor.ringMax);
      expect(m.ring.last.wire, endsWith('m:${XprsMonitor.ringMax + 49}'));
    });
  });

  group('the internet is not on the air', () {
    test('an internet-borne packet leaves no trace whatsoever', () {
      final m = XprsMonitor.instance;
      m.offer(p(beacon), bearer: 'internet', selfCallsign: 'X1A67X');
      expect(m.ring, isEmpty, reason: 'not in the traffic log');
      expect(m.stations, isEmpty, reason: 'and not a station either');
      expect(m.stationsJson(), isNot(contains('X1RD89')));
    });

    test('internet is not in the accepted bearer set', () {
      expect(kBearers.contains('internet'), isFalse);
      expect(kBearers, containsAll(['ble', 'lan', 'lora']));
    });

    test('an unknown bearer is dropped rather than shown as something', () {
      XprsMonitor.instance
          .offer(p(beacon), bearer: 'carrier-pigeon', selfCallsign: 'X1A67X');
      expect(XprsMonitor.instance.ring, isEmpty);
    });
  });

  group('what the wapp reads', () {
    test('stations render as people sections with bearer and counts', () {
      XprsMonitor.instance
          .offer(p(beacon), bearer: 'ble', selfCallsign: 'X1A67X', rssi: -37);
      final secs = jsonDecode(XprsMonitor.instance.stationsJson()) as List;
      expect(secs.length, 1);
      expect(secs[0]['title'], 'Heard over the air (1)');
      final row = (secs[0]['items'] as List).single as Map;
      expect(row['id'], 'X1RD89');
      expect(row['subtitle'], contains('BLE'));
      expect(row['subtitle'], contains('-37 dBm'));
      expect((row['tags'] as List), contains('BLE'));
      expect((row['tags'] as List), contains('peers 12'));
      expect((row['tags'] as List), contains('mail 3'));
    });

    test('traffic renders oldest first with the bearer on every entry', () {
      final m = XprsMonitor.instance;
      m.offer(p(beacon), bearer: 'ble', selfCallsign: 'X1A67X');
      m.offer(p(mailForOther), bearer: 'lora', selfCallsign: 'X1A67X');
      final rows = jsonDecode(m.trafficJson()) as List;
      expect(rows.length, 2);
      expect(rows[0]['type'], 'observation');
      expect(rows[0]['bearer'], 'ble');
      expect(rows[1]['type'], 'message');
      expect(rows[1]['bearer'], 'lora');
      expect(rows[1]['mine'], isFalse);
      for (final r in rows) {
        expect(kBearers.contains(r['bearer']), isTrue);
      }
    });

    test('a station that has gone quiet stops being listed', () {
      final m = XprsMonitor.instance;
      final t0 = DateTime.now().millisecondsSinceEpoch;
      m.offer(p(beacon), bearer: 'ble', selfCallsign: 'X1A67X', nowMs: t0);
      expect(m.stations.length, 1);
      m.sweep(nowMs: t0 + XprsMonitor.staleAfter.inMilliseconds + 1000);
      expect(m.stations, isEmpty);
    });

    test('the revision moves so a wapp can skip a redraw', () {
      final m = XprsMonitor.instance;
      final before = m.revision;
      m.offer(p(beacon), bearer: 'ble', selfCallsign: 'X1A67X');
      expect(m.revision, greaterThan(before));
    });
  });
}
