/*
 * UpdateService — in-app updater for Geogram Aurora.
 *
 * Self-hosted feed at geogram.radio (NO github.com runtime dependency — keeps
 * the app within store policies). Two channels, each a static JSON file:
 *   stable -> <feed>/stable.json
 *   beta   -> <feed>/beta.json
 * Compares the running version (lib/version.dart kAppVersion) against the feed
 * with semver (pre-release aware), downloads the per-platform artifact, and
 * applies it natively (see update_native_io.dart). Web is a no-op. The feed
 * base URL is overridable at runtime (Update Center) for future relocation.
 *
 * Mirrors geogram/lib/services/update_service.dart (station-feed style),
 * trimmed to the three target platforms (Android/Linux/Windows).
 */

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../version.dart';
import 'update_models.dart';
import 'update_native.dart';
import 'notification_service.dart';

enum UpdateStatus { idle, checking, available, downloading, downloaded, error }

class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  // Release source — self-hosted feed at geogram.radio (NO github.com runtime
  // dependency, so the app stays store-policy friendly). The base directory
  // holds two channel files: <base>/stable.json and <base>/beta.json (see
  // ReleaseInfo.fromFeed for the schema). Overridable at runtime (Update
  // Center) so a future deployment can point elsewhere without rebuilding.
  static const String defaultFeedUrl = 'https://geogram.radio/updates';
  String _feedUrl = defaultFeedUrl;
  String get feedUrl => _feedUrl;

  // Persisted settings keys (SharedPreferences, "flutter." prefixed on disk).
  static const _kBeta = 'update.betaEnabled';
  static const _kAutoCheck = 'update.autoCheck';
  static const _kNotified = 'update.lastNotifiedVersion';
  static const _kFeedUrl = 'update.feedUrl';

  final ValueNotifier<UpdateStatus> status =
      ValueNotifier(UpdateStatus.idle);
  final ValueNotifier<double> progress = ValueNotifier(0); // 0..1
  final ValueNotifier<ReleaseInfo?> stable = ValueNotifier(null);
  final ValueNotifier<ReleaseInfo?> beta = ValueNotifier(null);
  String? error;
  String? _downloadedPath;

  bool _betaEnabled = false;
  bool _autoCheck = true;
  bool get betaEnabled => _betaEnabled;
  bool get autoCheck => _autoCheck;

  String get currentVersion => kAppVersion;
  bool get supported => UpdateNative.supported;

  Future<void> _prefs(void Function(SharedPreferences p) fn) async {
    final p = await SharedPreferences.getInstance();
    fn(p);
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _betaEnabled = p.getBool(_kBeta) ?? false;
    _autoCheck = p.getBool(_kAutoCheck) ?? true;
    final url = p.getString(_kFeedUrl);
    _feedUrl = (url != null && url.isNotEmpty) ? url : defaultFeedUrl;
  }

  Future<void> setBetaEnabled(bool v) async {
    _betaEnabled = v;
    await _prefs((p) => p.setBool(_kBeta, v));
  }

  /// Change the update feed base URL (the directory holding stable.json and
  /// beta.json). Trailing slashes are trimmed; pass empty to reset to the
  /// default (geogram.radio). Returns the normalised URL actually stored.
  Future<String> setFeedUrl(String input) async {
    final url = normalizeFeedUrl(input);
    _feedUrl = url;
    await _prefs((p) => p.setString(_kFeedUrl, url));
    return url;
  }

  /// Normalise a feed base URL: trim whitespace and trailing slashes, and
  /// fall back to the default when blank.
  static String normalizeFeedUrl(String input) {
    var s = input.trim();
    if (s.isEmpty) return defaultFeedUrl;
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Future<void> setAutoCheck(bool v) async {
    _autoCheck = v;
    await _prefs((p) => p.setBool(_kAutoCheck, v));
  }

  /// The release the user should be offered, honouring the beta toggle.
  ReleaseInfo? get selectedRelease => _betaEnabled ? beta.value : stable.value;

  /// True if [r] is newer than what's running.
  bool isNewer(ReleaseInfo? r) =>
      r != null && _compareSemver(r.version, kAppVersion) > 0;

  /// Fetch both channels from the self-hosted feed. Safe to call from the
  /// Update Center on open and from a background check. A missing channel
  /// file (404) is treated as "no release on that channel", not an error.
  Future<void> checkForUpdates() async {
    if (!supported) return;
    status.value = UpdateStatus.checking;
    error = null;
    try {
      final results = await Future.wait([
        _fetch('$_feedUrl/stable.json'),
        _fetch('$_feedUrl/beta.json'),
      ]);
      stable.value = results[0];
      beta.value = results[1] ?? results[0];
      final sel = selectedRelease;
      status.value =
          isNewer(sel) ? UpdateStatus.available : UpdateStatus.idle;
    } catch (e) {
      error = e.toString();
      status.value = UpdateStatus.error;
    }
  }

  /// Background check at startup: refresh channels and, if a newer version is
  /// out (and we haven't already nagged about it), surface one notification.
  Future<void> backgroundCheck() async {
    if (!supported || !_autoCheck) return;
    await load();
    await checkForUpdates();
    final sel = selectedRelease;
    if (!isNewer(sel)) return;
    final p = await SharedPreferences.getInstance();
    if (p.getString(_kNotified) == sel!.version) return;
    await p.setString(_kNotified, sel.version);
    NotificationService.instance.show(GeogramNotification(
      level: NotificationLevel.info,
      title: 'Update available',
      body: 'Geogram Aurora ${sel.version} is available. Open Settings → '
          'Updates to install.',
      source: 'host:updates',
      scope: NotificationScope.both,
    ));
  }

  /// Fetch and parse one channel file from the feed. Returns null when the
  /// channel doesn't exist yet (404) so a fresh deployment isn't an error.
  /// The directory the file lives in becomes the base for resolving relative
  /// asset URLs.
  Future<ReleaseInfo?> _fetch(String url) async {
    final resp = await http.get(
      Uri.parse(url),
      headers: const {'User-Agent': 'geogram-aurora-updater'},
    );
    if (resp.statusCode == 404) return null; // channel not published yet
    if (resp.statusCode != 200) {
      throw 'Update feed HTTP ${resp.statusCode}';
    }
    final decoded = jsonDecode(resp.body);
    // Base = the directory portion of the channel file's URL.
    final slash = url.lastIndexOf('/');
    final base = slash > 0 ? url.substring(0, slash) : url;
    if (decoded is List) {
      if (decoded.isEmpty) return null;
      return ReleaseInfo.fromFeed(
          (decoded.first as Map).cast<String, dynamic>(), baseUrl: base);
    }
    return ReleaseInfo.fromFeed(
        (decoded as Map).cast<String, dynamic>(), baseUrl: base);
  }

  /// Download the artifact for [release] on the current platform.
  Future<bool> download(ReleaseInfo release) async {
    if (!supported) return false;
    final platform = currentUpdatePlatform();
    final asset = release.assetFor(platform);
    if (asset == null || asset.url.isEmpty) {
      error = 'No download for this platform in ${release.version}';
      status.value = UpdateStatus.error;
      return false;
    }
    status.value = UpdateStatus.downloading;
    progress.value = 0;
    error = null;
    UpdateNative.serviceStart('Downloading Aurora ${release.version}');
    final path = await UpdateNative.download(asset.url, asset.name,
        (received, total) {
      if (total > 0) {
        final v = received / total;
        progress.value = v;
        UpdateNative.serviceProgress(
            (v * 100).round(), 'Downloading ${release.version}');
      }
    });
    UpdateNative.serviceStop();
    if (path == null) {
      error = 'Download failed';
      status.value = UpdateStatus.error;
      return false;
    }
    _downloadedPath = path;
    progress.value = 1;
    status.value = UpdateStatus.downloaded;
    return true;
  }

  /// Apply the downloaded artifact. On Android, ensures the install permission
  /// first (opens settings if missing). Quits the app on desktop to swap files.
  Future<bool> install(ReleaseInfo release) async {
    if (!supported || _downloadedPath == null) return false;
    final platform = currentUpdatePlatform();
    if (platform == UpdatePlatform.android && !await UpdateNative.canInstall()) {
      await UpdateNative.openInstallSettings();
      error = 'Allow installing apps from Aurora, then tap Install again.';
      status.value = UpdateStatus.error;
      return false;
    }
    await UpdateNative.apply(platform, _downloadedPath!);
    return true;
  }

  // ── semver compare (pre-release aware, semver §11) ──────────────────
  static int _compareSemver(String a, String b) {
    a = a.split('+').first;
    b = b.split('+').first;
    final ap = a.split('-');
    final bp = b.split('-');
    List<int> core(String s) =>
        s.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final ac = core(ap.first), bc = core(bp.first);
    for (var i = 0; i < 3; i++) {
      final x = i < ac.length ? ac[i] : 0;
      final y = i < bc.length ? bc[i] : 0;
      if (x != y) return x < y ? -1 : 1;
    }
    final aPre = ap.length > 1, bPre = bp.length > 1;
    if (aPre && !bPre) return -1; // 1.0.0-beta < 1.0.0
    if (!aPre && bPre) return 1;
    if (!aPre && !bPre) return 0;
    final aId = ap.sublist(1).join('-').split('.');
    final bId = bp.sublist(1).join('-').split('.');
    for (var i = 0; i < aId.length && i < bId.length; i++) {
      final an = int.tryParse(aId[i]), bn = int.tryParse(bId[i]);
      int c;
      if (an != null && bn != null) {
        c = an.compareTo(bn);
      } else if (an != null) {
        c = -1; // numeric identifiers rank lower than alphanumeric
      } else if (bn != null) {
        c = 1;
      } else {
        c = aId[i].compareTo(bId[i]);
      }
      if (c != 0) return c < 0 ? -1 : 1;
    }
    return aId.length.compareTo(bId.length).clamp(-1, 1);
  }
}
