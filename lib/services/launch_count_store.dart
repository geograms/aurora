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

  /// What the module bars show on a fresh install: the user has launched
  /// nothing yet, so "most used" is empty and the bars would fall back to
  /// whatever the app list happens to order first. These are the ones a new
  /// user is meant to open, most important first. Only the first three fit,
  /// so this is a starting position, not a fixed layout — it is overridden the
  /// moment the user pins or launches anything, and a wapp they actually use
  /// takes the bar instead.
  ///
  /// Every id here must also be in `_kDefaultSeedNames` (launcher/seeding.dart)
  /// or it is never installed on a fresh profile, and naming it here does
  /// nothing at all: the resolver silently skips ids it cannot find.
  static const List<String> kDefaultModuleWapps = [
    'social',
    'torrents',
    'chat',
    'mp4player',
  ];

  /// Pinned module bars, or the most-used wapps when the user pinned none,
  /// topped up with [kDefaultModuleWapps] on a fresh profile.
  Future<List<String>> preferredModules(int n) => _preferred(n, dock: false);

  /// Pinned dock icons, or the most-used wapps when the user pinned none.
  Future<List<String>> preferredDock(int n) => _preferred(n, dock: true);

  Future<List<String>> _preferred(int n, {required bool dock}) async {
    final prefs = await PreferencesService.instance();
    final pinned = dock ? prefs.homeDock : prefs.homeModules;
    if (pinned.isNotEmpty) return pinned.take(n).toList(growable: false);
    final top = prefs.topLaunchedWapps(n);
    if (dock || top.length >= n) return top;
    // Fresh profile (or barely used): fill the remaining bars with the
    // defaults, keeping any real launch history first.
    final out = List<String>.of(top);
    for (final id in kDefaultModuleWapps) {
      if (out.length >= n) break;
      if (!out.contains(id)) out.add(id);
    }
    return out;
  }
}
