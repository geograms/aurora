/// Adding the FIRST radio must work.
///
/// It did not: the getter handed back a `const []` when nothing was declared
/// yet, so `radios..add(entry)` threw UnsupportedError on the very first
/// antenna — and because the dialog had already popped, the failure looked
/// exactly like "the Add button does nothing". Caught on the C61, not here,
/// which is why it is now pinned by a test.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum/src/services/social/listening_schedule.dart';
import 'package:reticulum/src/services/social/node_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aurora/services/preferences_service.dart';
import 'package:aurora/services/social/node_profile_service.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PreferencesService.instance();
    // PreferencesService is a singleton and holds the SharedPreferences it was
    // built with, so resetting the mock does not reset IT. Clear the one key
    // these tests own, or test 2 inherits test 1's antennas.
    PreferencesService.instanceSync!.nodeRadios = '';
  });

  test('the first radio can be added to an empty list', () {
    final svc = NodeProfileService.instance;
    expect(svc.radios, isEmpty);

    final rs = svc.radios
      ..add(RadioEntry(
        link: LinkFlag.lora,
        rangeKm: 12,
        freqKhz: 868200,
        mode: 'LoRa-SF7BW125',
        schedule: ListeningSchedule.parse('every 30m for 3m'),
      ));
    svc.radios = rs;

    expect(svc.radios, hasLength(1));
    final r = svc.radios.single;
    expect(r.rangeKm, 12);
    expect(r.freqKhz, 868200);
    expect(r.schedule.retryWindow, const Duration(minutes: 30));
  });

  test('a second radio joins the first, and both reach the announce', () {
    final svc = NodeProfileService.instance;
    svc.radios = svc.radios
      ..add(const RadioEntry(link: LinkFlag.lora, rangeKm: 12, freqKhz: 868200));
    svc.radios = svc.radios
      ..add(const RadioEntry(
          link: LinkFlag.packetRadio, rangeKm: 80, freqKhz: 144800));

    expect(svc.radios, hasLength(2));
    final profile = svc.build();
    expect(profile.maxRangeKm, 80);
    expect(profile.has(LinkFlag.lora), isTrue);
    expect(profile.has(LinkFlag.packetRadio), isTrue);
    expect(profile.reachableOffgrid, isTrue,
        reason: 'this box can now be reached with no internet at all');

    // And it still survives the round trip through an announce.
    final back = NodeProfile.decode(profile.encode());
    expect(back.radios, hasLength(2));
    expect(back.radios.first.rangeKm, 80, reason: 'longest range first');
  });

  test('a corrupt stored value degrades to empty, and stays addable', () {
    PreferencesService.instanceSync!.nodeRadios = 'not json at all';
    final svc = NodeProfileService.instance;
    expect(svc.radios, isEmpty);
    expect(() => svc.radios..add(const RadioEntry(link: LinkFlag.bluetooth)),
        returnsNormally);
  });
}
