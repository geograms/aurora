import 'package:reticulum/src/services/social/archiver_policy.dart';

import '../preferences_service.dart';

/// The owner's standing offer to hold other people's data (docs/NOSTR.md).
///
/// Volunteering storage is an act, not a side effect. A device that never said
/// yes holds nothing for anybody, and a quota is a ceiling rather than a target:
/// full is full, and no clever reason gets past it.
///
/// The interesting half is the **direct links**. A peer that reached us over the
/// LAN, over Bluetooth or over LoRa has no route to anywhere else — its data
/// dies if we refuse it. So those links get their own switches, because a LoRa
/// gateway wants a very different deal (tiny, precious, slow) from a box on a
/// home LAN.
class ArchiverService {
  ArchiverService._();
  static final ArchiverService instance = ArchiverService._();

  ArchiverPolicy get policy {
    final p = PreferencesService.instanceSync;
    if (p == null) return ArchiverPolicy.none;
    final gb = p.archiveQuotaGb;
    if (gb <= 0) return ArchiverPolicy.none;
    return ArchiverPolicy(
      quotaBytes: gb * 1024 * 1024 * 1024,
      keepFollowedAuthors: p.archiveFollowed,
      topics: p.archiveTopics.map((t) => t.toLowerCase()).toSet(),
      acceptFrom: {
        if (p.archiveFromLan) ArrivedOver.lan,
        if (p.archiveFromBluetooth) ArrivedOver.bluetooth,
        if (p.archiveFromRadio) ArrivedOver.radio,
        if (p.archiveFromWifiDirect) ArrivedOver.wifiDirect,
      },
      mirrorSmallDevices: p.archiveMirrorSmall,
    );
  }

  bool get isArchiving => policy.isArchiving;

  /// Map the interface a link arrived on to the policy's idea of where it came
  /// from. Unknown interfaces are treated as the internet — the *conservative*
  /// reading, because the direct-link exception is generous and must never be
  /// granted by accident.
  static ArrivedOver arrivedOver(String? iface) {
    final i = (iface ?? '').toLowerCase();
    if (i.contains('lan') || i.contains('udp') || i.contains('local')) {
      return ArrivedOver.lan;
    }
    if (i.contains('ble') || i.contains('bluetooth')) {
      return ArrivedOver.bluetooth;
    }
    if (i.contains('lora') || i.contains('radio') || i.contains('serial')) {
      return ArrivedOver.radio;
    }
    if (i.contains('wfd') || i.contains('direct')) return ArrivedOver.wifiDirect;
    return ArrivedOver.internet;
  }
}
