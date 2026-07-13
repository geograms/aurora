import 'dart:convert';

import 'package:reticulum/reticulum.dart';
import 'package:reticulum/src/services/social/listening_schedule.dart';
import 'package:reticulum/src/services/social/node_profile.dart';

import '../files/capacity_governor.dart';
import '../preferences_service.dart';

/// The device's physical profile: what it is made of, and how much of that we
/// actually measured (docs/NOSTR.md, *The physical profile*).
///
/// Split by who can honestly know a thing:
///
///  - **Measured, never typed**: the percentage of the last 7 days this device
///    really had power, and its observed uplink class. The governor already
///    samples charging state and network kind on a timer; we just keep the
///    history.
///  - **Stated by a human**: the power source, the antennas, the autonomy in
///    hours, the coverage region. No Android API reports that there is a solar
///    panel on the roof or a LoRa hat on the windowsill, and pretending to
///    infer it would be a lie with a battery attached.
///
/// A node announces FACTS and never a self-assessment — there is no "I am
/// precious" field. Every asker scores what it hears for itself, and what we
/// have *observed* about a peer always beats what the peer *claimed*.
///
/// Performance: this is a few integers and a preference read. The 7-day ring is
/// 168 hourly buckets in a string. Nothing here touches the network, and the
/// caller (the announce path) is already off the UI's critical path.
class NodeProfileService {
  NodeProfileService._();
  static final NodeProfileService instance = NodeProfileService._();

  static const int _hours = 7 * 24;

  /// Called by the capacity governor's tick. Records whether we had power in
  /// this hour, so `poweredPct` is an observation rather than a boast.
  void sample({required bool powered, int? nowMs}) {
    final p = PreferencesService.instanceSync;
    if (p == null) return;
    final hour =
        (nowMs ?? DateTime.now().millisecondsSinceEpoch) ~/ 3600000;
    if (p.poweredRingHour == hour) return; // one sample per hour is enough
    final ring = p.poweredRing;
    final next = (ring + (powered ? '1' : '0'));
    p.poweredRing =
        next.length > _hours ? next.substring(next.length - _hours) : next;
    p.poweredRingHour = hour;
  }

  /// Percent of the recorded week this device actually had power. Returns 0
  /// when we have not watched it long enough to say — an honest "I don't know"
  /// beats an optimistic guess that another node would then rank us on.
  int get poweredPct {
    final ring = PreferencesService.instanceSync?.poweredRing ?? '';
    if (ring.length < 12) return 0; // less than half a day: say nothing
    final on = ring.split('').where((c) => c == '1').length;
    return (on * 100 / ring.length).round();
  }

  /// The uplink we can SEE. A user who is on Starlink says so in Settings
  /// (it looks like ordinary WiFi/Ethernet from here, and that difference is
  /// the whole point of the field), so their statement wins over the guess.
  UplinkKind get uplink {
    final stated = PreferencesService.instanceSync?.nodeUplink ?? -1;
    if (stated >= 0 && stated < UplinkKind.values.length) {
      return UplinkKind.values[stated];
    }
    final net = CapacityGovernor.instance.lastNet;
    return switch (net) {
      NetKind.ethernet => UplinkKind.fibre,
      NetKind.wifi => UplinkKind.wifi,
      NetKind.cellular => UplinkKind.cellular,
      NetKind.none => UplinkKind.none,
      _ => UplinkKind.unknown,
    };
  }

  PowerSource get power {
    final stated = PreferencesService.instanceSync?.nodePower ?? -1;
    if (stated >= 0 && stated < PowerSource.values.length) {
      return PowerSource.values[stated];
    }
    // Unstated: a phone is a phone. We do NOT guess "solar" for anybody.
    return PowerSource.unknown;
  }

  List<RadioEntry> get radios {
    final raw = PreferencesService.instanceSync?.nodeRadios ?? '';
    if (raw.isEmpty) return const [];
    try {
      return [
        for (final j in (jsonDecode(raw) as List))
          if (j is Map)
            RadioEntry(
              link: (j['link'] as num?)?.toInt() ?? 0,
              rangeKm: (j['rangeKm'] as num?)?.toInt() ?? 0,
              freqKhz: (j['freqKhz'] as num?)?.toInt() ?? 0,
              mode: '${j['mode'] ?? ''}',
              schedule: ListeningSchedule.parse(j['schedule'] as String?),
            )
      ];
    } catch (_) {
      return const [];
    }
  }

  set radios(List<RadioEntry> v) {
    PreferencesService.instanceSync?.nodeRadios = jsonEncode([
      for (final r in v)
        {
          'link': r.link,
          'rangeKm': r.rangeKm,
          'freqKhz': r.freqKhz,
          'mode': r.mode,
          'schedule': r.schedule.text,
        }
    ]);
  }

  /// Everything this device can be reached on: the radios the user declared,
  /// plus Bluetooth, which every phone has and nobody should have to type.
  int get links {
    var l = 0;
    for (final r in radios) {
      l |= r.link;
    }
    if (RnsPlatform.hasBluetooth) l |= LinkFlag.bluetooth;
    return l;
  }

  /// Assemble the profile for the announce. Cheap; called on each re-announce so
  /// a new antenna or a move to Starlink shows up without a restart.
  NodeProfile build() {
    final p = PreferencesService.instanceSync;
    return NodeProfile(
      power: power,
      poweredPct: poweredPct,
      uplink: uplink,
      bwClass: _bwClass,
      links: links,
      autonomyHours: p?.nodeAutonomyHours ?? 0,
      // Off by default and it stays off unless the owner opts in: a phone in
      // somebody's pocket has no business advertising where it sleeps. This is
      // for infrastructure that WANTS to be found.
      geohash: p?.nodeGeohash ?? '',
      radios: radios,
    );
  }

  /// Observed throughput, log-bucketed (bytes/sec ≈ 2^bwClass). 0 = we have not
  /// measured anything yet, and we do not invent a number.
  int get _bwClass {
    final bps = PreferencesService.instanceSync?.observedBytesPerSec ?? 0;
    if (bps <= 0) return 0;
    var c = 0;
    var v = bps;
    while (v > 1) {
      v >>= 1;
      c++;
    }
    return c.clamp(0, 31);
  }

  /// Record a measured transfer rate (a real one, from a real transfer).
  void observeThroughput(int bytesPerSec) {
    if (bytesPerSec <= 0) return;
    final p = PreferencesService.instanceSync;
    if (p == null) return;
    // Keep the best honest observation, decayed slowly: one lucky burst should
    // not make a phone look like a fibre box for ever.
    final prev = p.observedBytesPerSec;
    p.observedBytesPerSec =
        bytesPerSec > prev ? bytesPerSec : ((prev * 7 + bytesPerSec) ~/ 8);
  }
}

/// Platform capabilities we can honestly detect without asking anybody.
class RnsPlatform {
  static bool hasBluetooth = false; // set at startup by the host
}
