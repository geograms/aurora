import 'package:flutter/foundation.dart' show ValueNotifier;

import 'preferences_service.dart';

/// Which wapps arrived since the user last looked.
///
/// A wapp added to the bundle installs itself into existing profiles on the
/// next launch (`upgradeBundledWapps`), and then sits in the all-apps grid
/// where nobody has any reason to look: the home screen is ranked by launch
/// count, and something installed a minute ago has none. So it is invisible
/// until somebody goes hunting for it, which is the same as not shipping it.
///
/// This is the missing signal. A newly installed wapp is remembered as *fresh*
/// until it is opened once; while it is fresh the launcher pulls it into the
/// dock and badges the tile. Opening it is the acknowledgement — no dialog, no
/// "what's new" screen.
///
/// [reconcile] is deliberately silent the first time it runs for a profile: on
/// a fresh install every wapp would otherwise be "new", which would badge the
/// entire grid and mean nothing.
class NewWappTracker {
  NewWappTracker._();
  static final NewWappTracker instance = NewWappTracker._();

  /// The fresh set, so tiles and the dock rebuild the moment it changes.
  final ValueNotifier<Set<String>> fresh = ValueNotifier<Set<String>>({});

  bool isNew(String wappId) => fresh.value.contains(wappId);

  /// Compare what is installed against what this profile has already seen.
  ///
  /// Called after every launcher scan. Ids are the launcher's folder names —
  /// the same key pins, launch counts and autostart use.
  Future<void> reconcile(Iterable<String> installedIds) async {
    final prefs = await PreferencesService.instance();
    final installed = installedIds.toSet();
    final known = prefs.knownWapps;

    if (known == null) {
      // First look at this profile: adopt everything silently.
      await prefs.setKnownWapps(installed.toList());
      await prefs.setFreshWapps(const []);
      _publish(const {});
      return;
    }

    // Fresh survives a restart, and an uninstall takes its entry with it.
    final next = prefs.freshWapps.toSet()..retainAll(installed);
    next.addAll(installed.difference(known.toSet()));

    // `known` only ever grows with what is installed now: a wapp the user
    // uninstalls and the bundle later reinstalls counts as new again, which is
    // the honest reading of what happened.
    final mergedKnown = known.toSet()..addAll(installed);
    await prefs.setKnownWapps(mergedKnown.toList());
    await prefs.setFreshWapps(next.toList());
    _publish(next);
  }

  /// The user opened it — it is not new any more.
  Future<void> markSeen(String wappId) async {
    if (!fresh.value.contains(wappId)) return;
    final next = fresh.value.toSet()..remove(wappId);
    _publish(next);
    final prefs = await PreferencesService.instance();
    await prefs.setFreshWapps(next.toList());
  }

  void _publish(Set<String> next) {
    if (next.length == fresh.value.length &&
        next.every(fresh.value.contains)) {
      return; // unchanged — do not churn the launcher's rebuilds
    }
    fresh.value = next;
  }
}
