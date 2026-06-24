/*
 * UpdateService — in-app updater for Geogram Aurora.
 *
 * Decentralized, authenticated updates over Reticulum. The publisher owns two
 * signed mutable folders (an IPNS-like, secp256k1-signed content-addressed
 * store) — one per channel:
 *   stable -> the stable folder npub  (only non-prerelease releases)
 *   beta   -> the beta folder npub    (all releases)
 * Each release's per-platform binaries are packed into the folder as
 * content-addressed entries named `aurora-<version>-<platform>` (see
 * update_models.versionFromAssetName). The app browses the channel folder
 * (signature-verified by reduceFolder, so only the folder owner can publish a
 * binary), compares the running version (lib/version.dart kAppVersion) with
 * semver (pre-release aware), fetches the artifact bytes peer-to-peer by sha256,
 * verifies sha256(bytes) == the entry hash, and applies it natively (see
 * update_native_io.dart). No central web host; any device that holds a binary
 * re-seeds it. Web is a no-op. Both folder npubs are overridable at runtime
 * (Update Center) for self-hosters.
 */

import 'dart:async';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../version.dart';
import 'reticulum/rns_service.dart';
import 'update_models.dart';
import 'update_platform.dart';
import 'update_native.dart';
import 'notification_service.dart';

enum UpdateStatus { idle, checking, available, downloading, downloaded, error }

class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  // Release source — two signed Reticulum mutable folders (the publisher holds
  // the master private key of each; consumers verify the op signatures and the
  // sha256 of every binary). The stable folder carries only non-prerelease
  // builds; the beta folder carries all builds. Pinned here as the folder
  // addresses (npub or hex folderId); overridable at runtime in the Update
  // Center so self-hosters can point at their own folders. Empty by default
  // until the publisher's folders are created and their npubs baked in — an
  // empty pin simply yields "no release on that channel", never an error.
  static const String defaultUpdateFolderStableNpub = '';
  static const String defaultUpdateFolderBetaNpub = '';

  String _stableFolder = defaultUpdateFolderStableNpub;
  String _betaFolder = defaultUpdateFolderBetaNpub;
  String get stableFolder => _stableFolder;
  String get betaFolder => _betaFolder;

  // Persisted settings keys (SharedPreferences, "flutter." prefixed on disk).
  static const _kBeta = 'update.betaEnabled';
  static const _kAutoCheck = 'update.autoCheck';
  static const _kNotified = 'update.lastNotifiedVersion';
  static const _kStableFolder = 'update.folder.stable';
  static const _kBetaFolder = 'update.folder.beta';

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
  String? get downloadedPath => _downloadedPath;

  Future<void> _prefs(void Function(SharedPreferences p) fn) async {
    final p = await SharedPreferences.getInstance();
    fn(p);
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _betaEnabled = p.getBool(_kBeta) ?? false;
    _autoCheck = p.getBool(_kAutoCheck) ?? true;
    final s = p.getString(_kStableFolder);
    final b = p.getString(_kBetaFolder);
    _stableFolder =
        (s != null && s.isNotEmpty) ? s : defaultUpdateFolderStableNpub;
    _betaFolder = (b != null && b.isNotEmpty) ? b : defaultUpdateFolderBetaNpub;
  }

  Future<void> setBetaEnabled(bool v) async {
    _betaEnabled = v;
    await _prefs((p) => p.setBool(_kBeta, v));
  }

  /// Change the stable-channel folder address (npub or hex folderId). Pass
  /// empty to reset to the default pin. Returns the normalised value stored.
  Future<String> setStableFolder(String input) async {
    final v = input.trim();
    _stableFolder = v.isEmpty ? defaultUpdateFolderStableNpub : v;
    await _prefs((p) => p.setString(_kStableFolder, _stableFolder));
    return _stableFolder;
  }

  /// Change the beta-channel folder address (npub or hex folderId). Pass empty
  /// to reset to the default pin. Returns the normalised value stored.
  Future<String> setBetaFolder(String input) async {
    final v = input.trim();
    _betaFolder = v.isEmpty ? defaultUpdateFolderBetaNpub : v;
    await _prefs((p) => p.setString(_kBetaFolder, _betaFolder));
    return _betaFolder;
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

  /// Browse both channel folders over Reticulum and pick the newest release on
  /// each. Safe to call from the Update Center on open and from a background
  /// check. An empty/unconfigured folder, or one we can't reach yet, is treated
  /// as "no release on that channel", not an error.
  Future<void> checkForUpdates() async {
    if (!supported) return;
    status.value = UpdateStatus.checking;
    error = null;
    try {
      stable.value = await _newestFromFolder(_stableFolder, prereleaseOk: false);
      // The beta channel falls back to the newest stable when the beta folder
      // is empty/unreachable (mirrors the old stable<-beta feed fallback).
      beta.value =
          await _newestFromFolder(_betaFolder, prereleaseOk: true) ??
              stable.value;
      final sel = selectedRelease;
      status.value =
          isNewer(sel) ? UpdateStatus.available : UpdateStatus.idle;
    } catch (e) {
      error = e.toString();
      status.value = UpdateStatus.error;
    }
  }

  /// Browse one channel folder and return its newest release (or null). With
  /// [prereleaseOk] false, prerelease versions are ignored so the stable
  /// channel never offers a beta even if the folder happens to hold one.
  Future<ReleaseInfo?> _newestFromFolder(String folder,
      {required bool prereleaseOk}) async {
    if (folder.isEmpty) return null;
    final state = await RnsService.instance.folderBrowseAsync(folder);
    ReleaseInfo? best;
    for (final r in releasesFromFolder(state)) {
      if (!prereleaseOk && r.isPrerelease) continue;
      if (best == null || _compareSemver(r.version, best.version) > 0) {
        best = r;
      }
    }
    return best;
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

  /// Download the artifact for [release] on the current platform — fetched
  /// peer-to-peer over Reticulum by its content hash, then verified before it
  /// is written to disk.
  Future<bool> download(ReleaseInfo release) async {
    if (!supported) return false;
    final platform = currentUpdatePlatform();
    final asset = release.assetFor(platform);
    if (asset == null || asset.url.isEmpty) {
      error = 'No download for this platform in ${release.version}';
      status.value = UpdateStatus.error;
      return false;
    }
    // asset.url holds the sha256 hex of the binary (the fetch handle) for the
    // folder source. The matching channel folder is where we look it up.
    final folder = release.isPrerelease ? _betaFolder : _stableFolder;
    status.value = UpdateStatus.downloading;
    progress.value = 0;
    error = null;
    UpdateNative.serviceStart('Downloading Aurora ${release.version}');
    try {
      final shaHex = asset.url.toLowerCase();
      // Pass the artifact's extension (e.g. "apk") so the content-addressed
      // fetch can archive + re-seed it. Without it the archive step rejected the
      // empty extension and discarded the already-fetched bytes.
      final dot = asset.name.lastIndexOf('.');
      final ext = dot >= 0 ? asset.name.substring(dot + 1) : '';
      final bytes = await RnsService.instance.folderFetchBytes(folder, shaHex,
          ext: ext, timeout: const Duration(minutes: 5));
      if (bytes == null) {
        error = 'Could not fetch the update over Reticulum (no provider yet)';
        status.value = UpdateStatus.error;
        return false;
      }
      // Integrity: the entry hash is content-addressed, but assert it anyway —
      // strictly stronger than the old unverified HTTPS download.
      final got = crypto.sha256.convert(bytes).toString();
      if (got != shaHex) {
        error = 'Update failed integrity check (sha mismatch)';
        status.value = UpdateStatus.error;
        return false;
      }
      final path = await UpdateNative.writeBytes(asset.name, bytes,
          (received, total) {
        if (total > 0) {
          final v = received / total;
          progress.value = v;
          UpdateNative.serviceProgress(
              (v * 100).round(), 'Downloading ${release.version}');
        }
      });
      if (path == null) {
        error = 'Could not write the update to disk';
        status.value = UpdateStatus.error;
        return false;
      }
      _downloadedPath = path;
      progress.value = 1;
      status.value = UpdateStatus.downloaded;
      return true;
    } finally {
      UpdateNative.serviceStop();
    }
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
