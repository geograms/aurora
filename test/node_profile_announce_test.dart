/// The physical profile has to fit in the announce it rides in.
///
/// An RNS announce carries ~350 bytes of app_data before it needs a second
/// packet, and a second packet for a *description of the hardware* would be a
/// tax on every node on the mesh, for ever. So: a realistic worst case — a solar
/// station with three radios, a coverage region, and a full interest set — must
/// still fit.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum/src/services/files/capacity_policy.dart';
import 'package:reticulum/src/services/social/listening_schedule.dart';
import 'package:reticulum/src/services/social/node_profile.dart';
import 'package:reticulum/src/services/social/relay_role.dart';

void main() {
  test('a fully-loaded announce still fits one packet', () {
    final interests = InterestSet()
      ..wide = false
      ..addTopic('reticulum')
      ..addTopic('offgrid')
      ..addAuthor('a' * 64)
      ..addAuthor('b' * 64);

    final node = NodeProfile(
      power: PowerSource.solarBattery,
      poweredPct: 96,
      uplink: UplinkKind.satellite,
      bwClass: 22,
      links: LinkFlag.lora | LinkFlag.packetRadio | LinkFlag.bluetooth,
      autonomyHours: 72,
      geohash: 'ezjmg',
      radios: [
        RadioEntry(
          link: LinkFlag.packetRadio,
          rangeKm: 80,
          freqKhz: 144800,
          mode: 'AX.25-1200',
          schedule: ListeningSchedule.parse('06:00-22:00'),
        ),
        RadioEntry(
          link: LinkFlag.lora,
          rangeKm: 12,
          freqKhz: 868200,
          mode: 'LoRa-SF7BW125',
          schedule: ListeningSchedule.parse('every 15m for 2m'),
        ),
        const RadioEntry(link: LinkFlag.bluetooth, rangeKm: 1),
      ],
    );

    final a = RelayAnnouncement.forCapacity(
      const CapacityProfile(
        capacity: 2,
        servingAllowed: true,
        unlimited: true,
        dailyBudgetBytes: 1 << 30,
      ),
      interests,
      pubkey: 'c' * 64,
      node: node,
    );

    final bytes = a.encode(uptimeSeconds: 987654);
    expect(bytes.length, lessThan(350),
        reason: 'the hardware description must never cost a second packet');

    final back = RelayAnnouncement.decode(bytes)!;
    expect(back.role, RelayRole.indexer);
    expect(back.profile.power, PowerSource.solarBattery);
    expect(back.profile.uplink, UplinkKind.satellite);
    expect(back.profile.radios.first.freqKhz, 144800,
        reason: 'the longest-range radio survives the cap');
    expect(back.profile.radios.first.schedule.text, '06:00-22:00');
    expect(
        back.profile.radios
            .firstWhere((r) => r.link == LinkFlag.lora)
            .schedule
            .retryWindow,
        const Duration(minutes: 15),
        reason: 'a caller knows how long to keep trying the thrifty LoRa leg');
  });

  test('a plain phone adds almost nothing to its announce', () {
    final bare = RelayAnnouncement.forCapacity(
      const CapacityProfile(
        capacity: 5,
        servingAllowed: false,
        unlimited: false,
        dailyBudgetBytes: 0,
      ),
      InterestSet(),
      pubkey: 'd' * 64,
    );
    expect(bare.encode().length, lessThan(120));
    expect(bare.profile.geohash, isEmpty,
        reason: 'a phone in a pocket says nothing about where it sleeps');
  });
}
