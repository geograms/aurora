import 'package:flutter/foundation.dart' show ValueNotifier;

import 'preferences_service.dart';

/// Which wapps the launcher surfaces, and where.
///
/// Two home-screen slots — the rectangular module bars and the icon dock — each
/// prefer the user's explicit pins and otherwise fall back to a most-used
/// ranking driven by [increment]. Callers top the result up from the installed
/// list, so a slot is never short just because the user has launched few wapps.
class LaunchCountStore {
  LaunchCountStore._();
  static final LaunchCountStore instance = LaunchCountStore._();

  /// Bumped whenever a pin changes, so the home slots rebuild immediately
  /// instead of waiting for the next launcher rescan.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Future<void> increment(String wappId) async {
    final prefs = await PreferencesService.instance();
    await prefs.incrementWappLaunch(wappId);
  }

  Future<bool> isPinnedToModules(String wappId) async =>
      (await PreferencesService.instance()).isPinnedToModules(wappId);

  Future<bool> isPinnedToDock(String wappId) async =>
      (await PreferencesService.instance()).isPinnedToDock(wappId);

  Future<void> setPinnedToModules(String wappId, bool pinned) async {
    await (await PreferencesService.instance())
        .setPinnedToModules(wappId, pinned);
    revision.value++;
  }

  Future<void> setPinnedToDock(String wappId, bool pinned) async {
    await (await PreferencesService.instance()).setPinnedToDock(wappId, pinned);
    revision.value++;
  }

  Future<List<String>> topN(int n) async {
    final prefs = await PreferencesService.instance();
    return prefs.topLaunchedWapps(n);
  }

  /// Pinned module bars, or the most-used wapps when the user pinned none.
  Future<List<String>> preferredModules(int n) => _preferred(n, dock: false);

  /// Pinned dock icons, or the most-used wapps when the user pinned none.
  Future<List<String>> preferredDock(int n) => _preferred(n, dock: true);

  Future<List<String>> _preferred(int n, {required bool dock}) async {
    final prefs = await PreferencesService.instance();
    final pinned = dock ? prefs.homeDock : prefs.homeModules;
    if (pinned.isNotEmpty) return pinned.take(n).toList(growable: false);
    return prefs.topLaunchedWapps(n);
  }
}
