/*
 * WappInstallerService — writes a freshly compiled wapp into the
 * installed-apps folder and nudges the launcher to rescan.
 *
 * The service is intentionally narrow: it knows nothing about the
 * compiler, only about the shape of an installed wapp directory
 * (`manifest.json`, `app.wasm`, `screens/home.ui.json`). The caller
 * (App Creator's `install` command handler in `wapp_page.dart`)
 * hands over the compiled bytes + the metadata it collected from
 * its own fields.
 *
 * On success, fires `WappLoadedEvent` on the host `EventBus` so
 * `LauncherPage._scanArchiveBody` picks up the new wapp on its next
 * rebuild — no geogram restart required.
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../connections/internet/http_transport.dart';
import '../services/event_bus.dart';
import '../profile/profile_storage.dart';
import '../profile/storage_paths.dart';
import 'wapp_signing_service.dart';

/// Where an installed wapp came from, persisted as `source.json` inside
/// the install so it can be re-run ("Reload") from its origin without
/// the user re-entering the URL / re-picking the file.
class WappSource {
  /// 'url' | 'path' | 'file' | 'bytes' | 'compiled'
  final String type;

  /// URL for 'url', source directory for 'path', absolute .wapp path
  /// for 'file', empty otherwise.
  final String value;

  const WappSource(this.type, this.value);

  factory WappSource.url(String v) => WappSource('url', v);
  factory WappSource.path(String v) => WappSource('path', v);
  factory WappSource.file(String v) => WappSource('file', v);

  Map<String, dynamic> toJson() =>
      {'version': 1, 'type': type, 'value': value};

  factory WappSource.fromJson(Map<String, dynamic> j) =>
      WappSource(j['type'] as String? ?? '', j['value'] as String? ?? '');
}

class InstallResult {
  final bool ok;
  final String wappId;
  final String? error;

  const InstallResult({
    required this.ok,
    required this.wappId,
    this.error,
  });

  factory InstallResult.success(String wappId) =>
      InstallResult(ok: true, wappId: wappId);

  factory InstallResult.failure(String wappId, String message) =>
      InstallResult(ok: false, wappId: wappId, error: message);
}

class WappInstallerService {
  WappInstallerService._();
  static final WappInstallerService instance = WappInstallerService._();

  /// Write (or overwrite) a wapp under `installedAppsStorage()`.
  ///
  /// Field semantics:
  /// - [title] — human-readable display name. Stored as
  ///   `manifest.description` (matching the existing wapp convention
  ///   where `description` is the short/title and `summary` is the
  ///   longer body).
  /// - [folderName] — slug used as the on-disk directory and the
  ///   per-user data directory key. Sanitised to `[A-Za-z0-9_-]`.
  /// - [id] — reverse-domain identifier stored as `manifest.id`.
  /// - [description] — longer prose, stored as `manifest.summary`.
  /// - [wasmBytes] — the compiled wasm, OR null to reuse whatever
  ///   `app.wasm` is already at `apps/<folderName>/`. This is the
  ///   edit-in-place path: let the user change metadata or the UI
  ///   without recompiling.
  /// - [homeScreenJson] — raw `home.ui.json` to write. Null/empty
  ///   triggers a default label screen.
  /// - [sourceC] — original C source to preserve as `main.c` next to
  ///   `app.wasm`. Null or empty skips the write (edit-in-place
  ///   installs that don't touch the source keep whatever `main.c`
  ///   was already on disk, so we don't clobber it with nothing).
  /// - [icon] — icon string written as `manifest.icon`. Either a
  ///   short free-form character/emoji (the launcher renders this
  ///   as text inside the tile) or a path like `media/icons/foo.svg`
  ///   (reserved for future file-based rendering; today the launcher
  ///   treats path-shaped icons as "no text icon" and falls back to
  ///   its Material icon guess).
  /// - [overwrite] — collisions fail unless explicitly allowed.
  Future<InstallResult> installFromCompiled({
    required String id,
    required String title,
    required String folderName,
    required String description,
    Uint8List? wasmBytes,
    String version = '1.0.0',
    String kind = 'app',
    int tickIntervalMs = 5000,
    List<String> halRequires = const ['log'],
    List<String> providesWidgets = const [],
    String? homeScreenJson,
    String? sourceC,
    String? icon,
    Map<String, Map<String, String>>? translations,
    bool overwrite = false,
  }) async {
    if (id.isEmpty) {
      return InstallResult.failure(id, 'wapp id is required');
    }

    final folder = _sanitiseFolder(folderName, fallbackId: id);
    final installed = installedAppsStorage();
    final exists = await installed.directoryExists(folder);

    // Resolve the wasm bytes. When the caller passes null (the
    // edit-in-place path) we read the bytes already sitting at
    // apps/<folder>/app.wasm. If neither a fresh compile nor an
    // existing install exists, we have to fail — nothing to write.
    Uint8List? effectiveWasm = wasmBytes;
    if (effectiveWasm == null) {
      effectiveWasm =
          await installed.readBytes('$folder/app.wasm');
      if (effectiveWasm == null || effectiveWasm.isEmpty) {
        return InstallResult.failure(
          id,
          'no compiled wasm and no existing install at apps/$folder — '
              'compile first or fill Name with an installed wapp',
        );
      }
    }
    if (effectiveWasm.isEmpty) {
      return InstallResult.failure(id, 'wasm bytes are empty');
    }

    if (exists && !overwrite) {
      return InstallResult.failure(
        id,
        'a wapp already exists at apps/$folder — pass overwrite:true '
            'to replace (App Creator passes overwrite implicitly)',
      );
    }

    // When editing in place without a fresh sourceC, carry the
    // previous main.c forward so a pure metadata/UI edit doesn't
    // strip source preservation. Read it BEFORE the delete.
    String? effectiveSource = sourceC;
    if (exists && (effectiveSource == null || effectiveSource.isEmpty)) {
      effectiveSource = await installed.readString('$folder/main.c');
    }

    // Same carry-forward logic for the icon: a pure metadata edit
    // that leaves the icon field blank should not strip a previously
    // saved icon out of the manifest. Also grab the previous inline
    // SVG file so we can re-copy it after the delete-and-rewrite
    // dance the overwrite path does below.
    String? effectiveIcon = icon;
    String? carriedSvg;
    if (exists && (effectiveIcon == null || effectiveIcon.isEmpty)) {
      final prevManifest =
          await installed.readJson('$folder/manifest.json');
      final prevIcon = prevManifest?['icon'];
      if (prevIcon is String && prevIcon.isNotEmpty) {
        effectiveIcon = prevIcon;
        // A previously-installed wapp may have had its icon saved
        // as a media/icons/icon.svg sidecar. Read the bytes now so
        // we can restore them after the directory is cleared.
        if (prevIcon.endsWith('.svg')) {
          carriedSvg = await installed.readString('$folder/$prevIcon');
        }
      }
    }

    if (exists && overwrite) {
      await installed.deleteDirectory(folder, recursive: true);
    }

    // Split the incoming icon value into its two canonical forms:
    //   - inline SVG XML (prefixed with `svg:`) → write to
    //     media/icons/icon.svg and store the path in manifest.icon
    //   - anything else → emoji / short string / existing path →
    //     store verbatim in manifest.icon
    String? manifestIcon;
    String? svgToWrite;
    if (effectiveIcon != null && effectiveIcon.isNotEmpty) {
      const prefix = 'svg:';
      if (effectiveIcon.startsWith(prefix)) {
        svgToWrite = effectiveIcon.substring(prefix.length);
        manifestIcon = 'media/icons/icon.svg';
      } else if (carriedSvg != null && effectiveIcon.endsWith('.svg')) {
        // Carry-forward path: a metadata-only edit kept the old
        // manifest.icon path. Restore the sidecar we just read.
        svgToWrite = carriedSvg;
        manifestIcon = effectiveIcon;
      } else {
        manifestIcon = effectiveIcon;
      }
    }

    // Manifest — matches the hand-written shapes in
    // wapps/*/manifest.json. `description` carries the short
    // title (what the launcher grid shows); `summary` carries the
    // longer prose.
    final manifest = <String, dynamic>{
      'id': id,
      'version': version,
      'kind': const {'app', 'system', 'addon'}.contains(kind) ? kind : 'app',
      'description': title.isNotEmpty ? title : folder,
      'summary': description,
      'icon': manifestIcon,
      'tags': const ['user'],
      'entry_ui': 'screens/home.ui.json',
      'tick_interval_ms': tickIntervalMs,
      'permissions': const <String>[],
      'provides': {
        'functionalities': providesWidgets,
        'events': const <String>[],
        'variables': const <String>[],
      },
      'requires': {
        'hal': halRequires,
        'events': const <String>[],
        'libraries': const <String>[],
        'variables': const <String>[],
      },
    };

    try {
      await installed.writeBytes('$folder/app.wasm', effectiveWasm);
      await installed.writeJson('$folder/manifest.json', manifest);
      final homeJson = (homeScreenJson ?? '').trim().isEmpty
          ? _defaultHomeScreen(title, description)
          : homeScreenJson!;
      await installed.writeString(
        '$folder/screens/home.ui.json',
        homeJson,
      );
      // Preserve the C source alongside the binary so the user can
      // reload and keep editing later. Match the built-in archive
      // convention: main.c sits next to app.wasm.
      if (effectiveSource != null && effectiveSource.isNotEmpty) {
        await installed.writeString('$folder/main.c', effectiveSource);
      }
      // Write the inline SVG as a sidecar file when present. The
      // manifest already points at its relative location.
      if (svgToWrite != null && svgToWrite.isNotEmpty) {
        await installed.writeString(
            '$folder/media/icons/icon.svg', svgToWrite);
      }
      // Write each configured locale to lang/<locale>.json. Empty
      // maps are dropped — no point shipping a placeholder file
      // with no translations. Keys with empty string values ARE
      // persisted because they serve as "stub" entries in the
      // App Creator's Translations tab.
      if (translations != null && translations.isNotEmpty) {
        for (final entry in translations.entries) {
          final code = entry.key.trim();
          final map = entry.value;
          if (code.isEmpty || map.isEmpty) continue;
          await installed.writeJson('$folder/lang/$code.json', map);
        }
      }
    } catch (e) {
      return InstallResult.failure(id, 'failed to write wapp files: $e');
    }

    // Sign the freshly written wapp with the active profile's nsec
    // so `signature.json` lands next to the other sidecars. This is
    // best-effort: an unsigned install still succeeds, so a user
    // without a profile can still install wapps (phase 2 will turn
    // this into a hard requirement).
    final pkg = ScopedProfileStorage(installed, folder);
    await WappSigningService.instance.signPackage(
      pkg,
      wappId: id,
      wappVersion: version,
    );

    // Nudge the launcher to rescan. WappLoadedEvent is the signal
    // LauncherPage already subscribes to for other rescan triggers.
    EventBus().fire(WappLoadedEvent(wappId: id, wappName: title));

    return InstallResult.success(id);
  }

  /// Install a wapp from raw `.wapp` (ZIP) bytes. Extracts into
  /// `installedAppsStorage()/<wappId>`, validates `app.wasm`, records
  /// the origin in `source.json` (for Reload), signs with the active
  /// profile, and fires [WappLoadedEvent] so the launcher rescans on
  /// its next rebuild. Any existing install at the same slug is
  /// replaced. Works on desktop and web (pure-Dart zip extraction).
  Future<InstallResult> installFromBytes({
    required String wappId,
    required Uint8List zipBytes,
    WappSource? source,
  }) async {
    if (wappId.isEmpty) return InstallResult.failure(wappId, 'wapp id is required');
    if (zipBytes.isEmpty) return InstallResult.failure(wappId, 'empty .wapp bytes');

    final folder = _sanitiseFolder(wappId, fallbackId: wappId);
    final installed = installedAppsStorage();
    try {
      await installed.deleteDirectory(folder, recursive: true);
      await installed.createDirectory(folder);
      final decoded = ZipDecoder().decodeBytes(zipBytes);
      for (final entry in decoded) {
        if (!entry.isFile) continue;
        final rel = entry.name.replaceAll('\\', '/');
        if (rel.isEmpty) continue;
        await installed.writeBytes(
            '$folder/$rel', Uint8List.fromList(entry.content as List<int>));
      }
    } catch (e) {
      return InstallResult.failure(wappId, 'extract failed: $e');
    }

    // app.wasm is required for runnable wapps (app/system/addon) but NOT
    // for `kind: library` providers like mediapack, which are backed by
    // native host capabilities and ship no wasm.
    if (!await installed.exists('$folder/app.wasm') &&
        !await _isLibraryWapp(installed, folder)) {
      await installed.deleteDirectory(folder, recursive: true);
      return InstallResult.failure(wappId, 'invalid wapp: no app.wasm');
    }

    if (source != null) {
      try {
        await installed.writeJson('$folder/source.json', source.toJson());
      } catch (_) {}
    }

    return _finishInstall(installed, folder, fallbackId: wappId);
  }

  /// Download a `.wapp` from [url] over HTTP(S) and install it. The URL
  /// is stored as the reload source so the user can refresh later.
  Future<InstallResult> installFromUrl({
    required String wappId,
    required String url,
  }) async {
    try {
      final res = await HttpTransport.shared.get(Uri.parse(url));
      if (res.statusCode != 200) {
        return InstallResult.failure(wappId, 'HTTP ${res.statusCode} for $url');
      }
      return installFromBytes(
        wappId: wappId,
        zipBytes: res.bodyBytes,
        source: WappSource.url(url),
      );
    } catch (e) {
      return InstallResult.failure(wappId, 'download failed: $e');
    }
  }

  /// Copy a wapp from a local source directory (dev iteration). The dir
  /// must contain `manifest.json` + `app.wasm`. The directory is stored
  /// as the reload source.
  Future<InstallResult> installFromPath({
    required String wappId,
    required String sourceDir,
  }) async {
    final src = wappPackageStorage(sourceDir);
    if (!await src.exists('manifest.json')) {
      return InstallResult.failure(wappId, 'no manifest.json in $sourceDir');
    }
    final folder = _sanitiseFolder(wappId, fallbackId: wappId);
    final installed = installedAppsStorage();
    try {
      await installed.deleteDirectory(folder, recursive: true);
      await installed.createDirectory(folder);
      final entries = await src.listDirectory('', recursive: true);
      for (final e in entries) {
        if (e.isDirectory) continue;
        final bytes = await src.readBytes(e.path);
        if (bytes == null) continue;
        await installed.writeBytes('$folder/${e.path}', bytes);
      }
    } catch (e) {
      return InstallResult.failure(wappId, 'copy failed: $e');
    }
    // app.wasm is required for runnable wapps (app/system/addon) but NOT
    // for `kind: library` providers like mediapack, which are backed by
    // native host capabilities and ship no wasm.
    if (!await installed.exists('$folder/app.wasm') &&
        !await _isLibraryWapp(installed, folder)) {
      await installed.deleteDirectory(folder, recursive: true);
      return InstallResult.failure(wappId, 'invalid wapp: no app.wasm');
    }
    try {
      await installed.writeJson(
          '$folder/source.json', WappSource.path(sourceDir).toJson());
    } catch (_) {}
    return _finishInstall(installed, folder, fallbackId: wappId);
  }

  /// Re-run the original install for [wappId] from the origin recorded
  /// in its `source.json`. Fails when there is no usable origin (e.g. a
  /// one-off bytes install whose source is gone).
  Future<InstallResult> reload(String wappId) async {
    final folder = _sanitiseFolder(wappId, fallbackId: wappId);
    final installed = installedAppsStorage();
    final json = await installed.readJson('$folder/source.json');
    if (json == null) {
      return InstallResult.failure(wappId, 'no source.json — cannot reload');
    }
    final source = WappSource.fromJson(json);
    switch (source.type) {
      case 'url':
        return installFromUrl(wappId: wappId, url: source.value);
      case 'path':
        return installFromPath(wappId: wappId, sourceDir: source.value);
      case 'file':
        final sep = source.value.replaceAll('\\', '/');
        final slash = sep.lastIndexOf('/');
        if (slash <= 0) {
          return InstallResult.failure(wappId, 'bad file source: ${source.value}');
        }
        final dir = sep.substring(0, slash);
        final file = sep.substring(slash + 1);
        final bytes = await wappPackageStorage(dir).readBytes(file);
        if (bytes == null) {
          return InstallResult.failure(wappId, 'source file gone: ${source.value}');
        }
        return installFromBytes(
            wappId: wappId, zipBytes: bytes, source: source);
      default:
        return InstallResult.failure(
            wappId, 'cannot reload a "${source.type}" install');
    }
  }

  /// Remove an installed wapp and fire [WappUnloadedEvent] so the
  /// launcher drops it on the next rescan.
  Future<InstallResult> uninstall(String wappId) async {
    final folder = _sanitiseFolder(wappId, fallbackId: wappId);
    final installed = installedAppsStorage();
    try {
      await installed.deleteDirectory(folder, recursive: true);
    } catch (e) {
      return InstallResult.failure(wappId, 'uninstall failed: $e');
    }
    EventBus().fire(WappUnloadedEvent(wappId: wappId, wappName: wappId));
    return InstallResult.success(wappId);
  }

  /// Shared tail for the from-bytes/from-path installers: read the
  /// manifest for id/version/title, sign the package, and announce the
  /// new wapp to the launcher.
  Future<InstallResult> _finishInstall(
    ProfileStorage installed,
    String folder, {
    required String fallbackId,
  }) async {
    final manifest = await installed.readJson('$folder/manifest.json');
    final id = (manifest?['id'] as String?) ?? fallbackId;
    final version = (manifest?['version'] as String?) ?? '1.0.0';
    final title = (manifest?['description'] as String?) ?? folder;
    await WappSigningService.instance.signPackage(
      ScopedProfileStorage(installed, folder),
      wappId: id,
      wappVersion: version,
    );
    EventBus().fire(WappLoadedEvent(wappId: id, wappName: title));
    return InstallResult.success(id);
  }

  /// True when the just-written wapp declares `kind: library` — such
  /// wapps are capability providers with no app.wasm.
  Future<bool> _isLibraryWapp(ProfileStorage installed, String folder) async {
    final m = await installed.readJson('$folder/manifest.json');
    return (m?['kind'] as String?) == 'library';
  }

  /// Sanitise a user-provided folder slug. Keeps alphanumerics,
  /// dashes, and underscores; everything else becomes a dash. Falls
  /// back to the id's last dot-segment, then to "wapp".
  String _sanitiseFolder(String name, {required String fallbackId}) {
    String slug = name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
    while (slug.startsWith('-')) {
      slug = slug.substring(1);
    }
    while (slug.endsWith('-')) {
      slug = slug.substring(0, slug.length - 1);
    }
    if (slug.isNotEmpty) return slug;
    final parts = fallbackId.split('.');
    final leaf = parts.isNotEmpty ? parts.last : fallbackId;
    final clean = leaf.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
    return clean.isEmpty ? 'wapp' : clean;
  }

  String _defaultHomeScreen(String title, String description) {
    final screen = [
      {
        '\$': 'screen',
        'name': title.isNotEmpty ? title : 'Home',
        'tip': description.isNotEmpty ? description : null,
        'children': [
          {
            '\$': 'label',
            'text': 'Created with App Creator.',
          },
          {
            '\$': 'label',
            'text':
                'This wapp ticks every 5 seconds and writes hal_log output. '
                    'Check the tasks wapp to see its monitored task.',
          },
        ],
      },
    ];
    return const JsonEncoder.withIndent('  ').convert(screen);
  }
}
