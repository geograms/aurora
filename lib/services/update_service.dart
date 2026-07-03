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
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
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

  // Preferred, authoritative source: the self-hosted geogram.radio feed (no
  // github.com at runtime — required by the F-Droid policy). Each channel is a
  // small JSON document with relative asset URLs resolved against this base; the
  // binaries are served from the same site. Reticulum (the folders above) is the
  // decentralized fallback used only when the website can't be reached.
  // Overridable at runtime for self-hosters.
  static const String defaultUpdateFeedBase = 'https://geogram.radio/updates';
  String _feedBase = defaultUpdateFeedBase;
  String get feedBase => _feedBase;

  /// Device ABIs in preference order (Android), cached; drives per-ABI split-APK
  /// selection. Empty on non-Android.
  List<String>? _androidAbis;
  Future<List<String>> _abis() async =>
      _androidAbis ??= await UpdateNative.supportedAbis();

  // Persisted settings keys (SharedPreferences, "flutter." prefixed on disk).
  static const _kBeta = 'update.betaEnabled';
  static const _kAutoCheck = 'update.autoCheck';
  static const _kNotified = 'update.lastNotifiedVersion';
  static const _kStableFolder = 'update.folder.stable';
  static const _kBetaFolder = 'update.folder.beta';
  static const _kFeedBase = 'update.feed.base';
  // Active DownloadManager job (Android), persisted so an interrupted or
  // backgrounded download can be re-attached when the Update Center reopens or
  // the app is relaunched.
  static const _kDlId = 'update.dl.id';
  static const _kDlVersion = 'update.dl.version';
  static const _kDlName = 'update.dl.name';
  static const _kDlSize = 'update.dl.size';
  static const _kDlSha = 'update.dl.sha';
  static const _kDlPre = 'update.dl.prerelease';

  final ValueNotifier<UpdateStatus> status =
      ValueNotifier(UpdateStatus.idle);
  final ValueNotifier<double> progress = ValueNotifier(0); // 0..1
  final ValueNotifier<ReleaseInfo?> stable = ValueNotifier(null);
  final ValueNotifier<ReleaseInfo?> beta = ValueNotifier(null);
  String? error;
  String? _downloadedPath;

  // True while a DownloadManager poll loop is running, so we never spin up a
  // second tracker (e.g. resume racing a fresh download).
  bool _tracking = false;

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
    final f = p.getString(_kFeedBase);
    _feedBase = (f != null && f.isNotEmpty) ? f : defaultUpdateFeedBase;
  }

  /// Change the website feed base URL (e.g. https://geogram.radio/updates). Pass
  /// empty to reset to the default. Returns the normalised value stored.
  Future<String> setFeedBase(String input) async {
    final v = input.trim();
    _feedBase = v.isEmpty ? defaultUpdateFeedBase : v;
    await _prefs((p) => p.setString(_kFeedBase, _feedBase));
    return _feedBase;
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
      // Website first (preferred, authoritative), Reticulum folder as fallback.
      stable.value =
          await _newestFromFeed('stable.json', prereleaseOk: false) ??
              await _newestFromFolder(_stableFolder, prereleaseOk: false);
      // The beta channel falls back to the newest stable when there's no beta
      // build on either source.
      beta.value = await _newestFromFeed('beta.json', prereleaseOk: true) ??
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

  /// Fetch one channel from the geogram.radio feed over HTTP and parse it. The
  /// feed's relative asset URLs are resolved against the feed base. Returns null
  /// on any error / non-200 / empty so the caller falls back to Reticulum. With
  /// [prereleaseOk] false, a prerelease document is ignored.
  Future<ReleaseInfo?> _newestFromFeed(String channelFile,
      {required bool prereleaseOk}) async {
    final raw = _feedBase.trim();
    if (raw.isEmpty) return null;
    final base = raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
    try {
      final resp = await http
          .get(Uri.parse('$base/$channelFile'))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(utf8.decode(resp.bodyBytes));
      if (json is! Map<String, dynamic>) return null;
      final r = ReleaseInfo.fromFeed(json, baseUrl: base);
      if (r.version.isEmpty) return null;
      if (!prereleaseOk && r.isPrerelease) return null;
      return r;
    } catch (_) {
      return null; // unreachable / malformed → fall back to Reticulum
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
    if (!supported) return;
    await load();
    // Re-attach to any download left running/finished by a prior session even
    // when auto-check is off — the user already asked for that download.
    await resumeActiveDownload();
    if (!_autoCheck) return;
    await checkForUpdates();
    final sel = selectedRelease;
    if (!isNewer(sel)) return;
    final p = await SharedPreferences.getInstance();
    if (p.getString(_kNotified) == sel!.version) return;
    await p.setString(_kNotified, sel.version);
    NotificationService.instance.show(GeogramNotification(
      level: NotificationLevel.info,
      title: 'Update available',
      body: 'Geogram ${sel.version} is available. Open Settings → '
          'Updates to install.',
      source: 'host:updates',
      scope: NotificationScope.both,
    ));
  }

  /// Download the artifact for [release] on the current platform. A website
  /// (http/https) asset is streamed over HTTPS from geogram.radio; a Reticulum
  /// asset (sha256 handle) is fetched peer-to-peer and sha-verified. The right
  /// per-ABI split APK is chosen on Android.
  Future<bool> download(ReleaseInfo release) async {
    if (!supported) return false;
    final platform = currentUpdatePlatform();
    final abis =
        platform == UpdatePlatform.android ? await _abis() : const <String>[];
    final asset = release.assetFor(platform, androidAbis: abis);
    if (asset == null || asset.url.isEmpty) {
      error = 'No download for this platform in ${release.version}';
      status.value = UpdateStatus.error;
      return false;
    }

    final lower0 = asset.url.toLowerCase();
    final isHttp0 =
        lower0.startsWith('http://') || lower0.startsWith('https://');
    // Android HTTP feed → the system DownloadManager: it keeps running after the
    // panel/app closes, resumes an interrupted transfer, and reports success
    // only once the whole file is on disk. The Dart isolate just mirrors its
    // progress. The Reticulum (sha handle) and desktop paths stay below.
    if (isHttp0 && UpdateNative.hasDownloadManager) {
      return _downloadViaManager(release, asset);
    }

    status.value = UpdateStatus.downloading;
    progress.value = 0;
    error = null;
    UpdateNative.serviceStart('Downloading Geogram ${release.version}');
    try {
      void onProgress(int received, int total) {
        if (total > 0) {
          final v = received / total;
          progress.value = v;
          UpdateNative.serviceProgress(
              (v * 100).round(), 'Downloading ${release.version}');
        }
      }

      final lower = asset.url.toLowerCase();
      final isHttp =
          lower.startsWith('http://') || lower.startsWith('https://');
      String? path;
      if (isHttp) {
        // Website source (geogram.radio): stream the binary over HTTPS. Trust is
        // the TLS connection to the authoritative site; a size mismatch (when the
        // feed advertised one) is treated as a failed/partial download.
        path = await UpdateNative.download(asset.url, asset.name, onProgress);
        if (path == null) {
          error = 'Could not download the update from the website';
          status.value = UpdateStatus.error;
          return false;
        }
      } else {
        // Reticulum source: asset.url holds the sha256 hex (content-addressed
        // fetch handle). The matching channel folder is where we look it up.
        final folder = release.isPrerelease ? _betaFolder : _stableFolder;
        final shaHex = lower;
        // Pass the artifact's extension (e.g. "apk") so the content-addressed
        // fetch can archive + re-seed it.
        final dot = asset.name.lastIndexOf('.');
        final ext = dot >= 0 ? asset.name.substring(dot + 1) : '';
        final bytes = await RnsService.instance.folderFetchBytes(folder, shaHex,
            ext: ext, timeout: const Duration(minutes: 5));
        if (bytes == null) {
          error = 'Could not fetch the update over Reticulum (no provider yet)';
          status.value = UpdateStatus.error;
          return false;
        }
        // Integrity: the entry hash is content-addressed; assert it anyway.
        final got = crypto.sha256.convert(bytes).toString();
        if (got != shaHex) {
          error = 'Update failed integrity check (sha mismatch)';
          status.value = UpdateStatus.error;
          return false;
        }
        path = await UpdateNative.writeBytes(asset.name, bytes, onProgress);
        if (path == null) {
          error = 'Could not write the update to disk';
          status.value = UpdateStatus.error;
          return false;
        }
      }
      _downloadedPath = path;
      progress.value = 1;
      status.value = UpdateStatus.downloaded;
      return true;
    } finally {
      UpdateNative.serviceStop();
    }
  }

  // ── Android DownloadManager path ────────────────────────────────────

  /// Enqueue [asset] with the system DownloadManager, persist the job so it can
  /// be re-attached later, and start mirroring its progress.
  Future<bool> _downloadViaManager(
      ReleaseInfo release, ReleaseAsset asset) async {
    status.value = UpdateStatus.downloading;
    progress.value = 0;
    error = null;
    _downloadedPath = null;
    // Drop any previous job so a re-download doesn't leave an orphan behind.
    final prev = await _activeDownloadId();
    if (prev != null) await UpdateNative.removeDownload(prev);
    final id = await UpdateNative.enqueueDownload(
        asset.url, asset.name, 'Downloading Geogram ${release.version}');
    if (id == null) {
      error = 'Could not start the download';
      status.value = UpdateStatus.error;
      return false;
    }
    await _persistActiveDownload(id, release, asset);
    return _trackManagedDownload(id, release, asset);
  }

  /// Poll a DownloadManager job to completion, mirroring bytes into [progress]
  /// and verifying the finished file before marking it installable.
  Future<bool> _trackManagedDownload(
      int id, ReleaseInfo release, ReleaseAsset asset) async {
    if (_tracking) return false;
    _tracking = true;
    try {
      while (true) {
        final r = await UpdateNative.pollDownload(id);
        final st = (r['status'] as String?) ?? 'unknown';
        final downloaded = (r['downloaded'] as num?)?.toInt() ?? 0;
        // DownloadManager reports total -1 until it learns Content-Length; fall
        // back to the feed's advertised size so the bar still moves.
        final reported = (r['total'] as num?)?.toInt() ?? -1;
        final total = reported > 0 ? reported : asset.size;
        if (st == 'pending' || st == 'running' || st == 'paused') {
          if (total > 0) {
            progress.value = (downloaded / total).clamp(0.0, 1.0);
          }
          status.value = UpdateStatus.downloading;
          await Future<void>.delayed(const Duration(milliseconds: 700));
          continue;
        }
        if (st == 'success') {
          final path = r['localPath'] as String?;
          if (path == null) {
            return _failManaged(
                id, 'Download finished but the file could not be found');
          }
          final ok = await UpdateNative.verifyFile(path,
              expectedSize: asset.size, expectedSha: asset.sha256);
          if (!ok) {
            return _failManaged(
                id, 'Update failed its integrity check — tap Download to retry');
          }
          _downloadedPath = path;
          progress.value = 1;
          status.value = UpdateStatus.downloaded;
          return true;
        }
        // 'failed' / 'unknown'
        return _failManaged(id, 'Download failed — check your connection and '
            'tap Download to retry');
      }
    } finally {
      _tracking = false;
    }
  }

  bool _failManaged(int id, String message) {
    error = message;
    status.value = UpdateStatus.error;
    // Fire-and-forget cleanup of the (partial) job.
    UpdateNative.removeDownload(id);
    _clearActiveDownload();
    return false;
  }

  /// Re-attach to a DownloadManager job left running/finished by a previous
  /// session (panel closed, app backgrounded or relaunched). Safe to call on
  /// every Update Center open and at startup; no-ops when nothing is pending.
  Future<void> resumeActiveDownload() async {
    if (!supported || _tracking || !UpdateNative.hasDownloadManager) return;
    final p = await SharedPreferences.getInstance();
    final id = p.getInt(_kDlId);
    if (id == null) return;
    final version = p.getString(_kDlVersion) ?? '';
    final asset = ReleaseAsset(
      name: p.getString(_kDlName) ?? '',
      url: '',
      size: p.getInt(_kDlSize) ?? 0,
      sha256: p.getString(_kDlSha) ?? '',
    );
    final release = ReleaseInfo(
      version: version,
      tagName: 'v$version',
      isPrerelease: p.getBool(_kDlPre) ?? false,
      assets: const [],
    );
    final r = await UpdateNative.pollDownload(id);
    final st = (r['status'] as String?) ?? 'unknown';
    if (st == 'unknown') {
      // The record is stale (job evicted); forget it silently.
      await _clearActiveDownload();
      return;
    }
    // Hand off to the tracker (handles running → progress, success → verify).
    unawaited(_trackManagedDownload(id, release, asset));
  }

  Future<int?> _activeDownloadId() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kDlId);
  }

  Future<void> _persistActiveDownload(
      int id, ReleaseInfo release, ReleaseAsset asset) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kDlId, id);
    await p.setString(_kDlVersion, release.version);
    await p.setString(_kDlName, asset.name);
    await p.setInt(_kDlSize, asset.size);
    await p.setString(_kDlSha, asset.sha256);
    await p.setBool(_kDlPre, release.isPrerelease);
  }

  Future<void> _clearActiveDownload() async {
    final p = await SharedPreferences.getInstance();
    for (final k in [_kDlId, _kDlVersion, _kDlName, _kDlSize, _kDlSha, _kDlPre]) {
      await p.remove(k);
    }
  }

  /// Apply the downloaded artifact. On Android, ensures the install permission
  /// first (opens settings if missing). Quits the app on desktop to swap files.
  Future<bool> install(ReleaseInfo release) async {
    if (!supported || _downloadedPath == null) return false;
    final platform = currentUpdatePlatform();
    if (platform == UpdatePlatform.android && !await UpdateNative.canInstall()) {
      await UpdateNative.openInstallSettings();
      error = 'Allow installing apps from Geogram, then tap Install again.';
      status.value = UpdateStatus.error;
      return false;
    }
    await UpdateNative.apply(platform, _downloadedPath!);
    // The installer now owns the file; forget the DownloadManager record so a
    // later reopen doesn't re-offer an already-applied build.
    await _clearActiveDownload();
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
