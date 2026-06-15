part of 'launcher.dart';

// ── First-run wapp seeding ───────────────────────────────────────────

/// Folder names always auto-installed on first run, on top of every
/// `kind: "system"` wapp. Keeps the default set in one place.
const _kDefaultSeedNames = {'install', 'maps', 'aprs'};

/// First-run bootstrap, run as a boot task BEFORE the UI so the launcher
/// never renders an empty grid mid-seed. Installs the curated default
/// set into the active profile exactly once; a per-profile
/// `.seeded.json` marker means a later "uninstall everything" sticks —
/// we never re-seed.
Future<void> ensureProfileSeeded() async {
  // No real profile yet (fresh install before WelcomePage) — don't seed the
  // `_no_profile` fallback; the seed gate re-runs this once a profile exists.
  if (ProfileService.instance.activeProfile == null) return;
  final profileRoot = activeProfileRoot();
  if (await profileRoot.readJson('.seeded.json') != null) return;

  final installed = installedAppsStorage();
  if (await installed.directoryExists('')) {
    final entries = await installed.listDirectory('');
    if (entries.any((e) => e.isDirectory)) {
      // Already has installs — mark seeded and leave them alone.
      await profileRoot.writeJson('.seeded.json', {'seeded': true});
      return;
    }
  }

  final copied = await _seedDefaults();
  if (copied > 0) {
    await profileRoot
        .writeJson('.seeded.json', {'seeded': true, 'count': copied});
  }
}

/// Copy the default set from the in-repo ../wapps library into the
/// profile: the Wapp Store + Maps, plus every `kind: "system"` wapp.
/// Everything else (forum, movies, terminal, mediapack) is left for the
/// user to install via the store. Returns the count installed.
Future<int> _seedDefaults() async {
  final fromFs = await _seedDefaultsFromFilesystem();
  if (fromFs > 0) return fromFs;
  return _seedDefaultsFromAssets();
}

/// Upgrade already-installed wapps when the APK bundles a newer version.
///
/// Seeding (above) only ever runs once per profile, so a shipped wapp fix would
/// otherwise never reach a device that already has the wapp. This pass runs on
/// every launch and, for each `assets/wapps/*.wapp`, overwrites the installed
/// copy IFF the bundled `manifest.version` is strictly newer. It deliberately:
///   - never installs a wapp the user doesn't already have (no resurrecting
///     something they uninstalled — that's seeding's job, once),
///   - never clobbers a wapp the user edited (`user_modified`),
///   - preserves wapp DATA (messages/settings live outside the package dir, so
///     the reinstall only swaps code/UI).
/// Returns the number upgraded.
Future<int> upgradeBundledWapps() async {
  var upgraded = 0;
  const prefix = 'assets/wapps/';
  final installed = installedAppsStorage();
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final bundles = manifest
        .listAssets()
        .where((a) => a.startsWith(prefix) && a.endsWith('.wapp'));
    for (final asset in bundles) {
      final name =
          asset.substring(prefix.length, asset.length - '.wapp'.length);
      final instManifest = await installed.readJson('$name/manifest.json');
      if (instManifest == null) continue; // not installed — leave to seeding
      if (instManifest['user_modified'] == true) continue; // keep user edits
      final instVer = (instManifest['version'] as String?) ?? '0.0.0';

      final data = await rootBundle.load(asset);
      final bytes = data.buffer.asUint8List();
      final bundledVer =
          WappInstallerService.instance.versionFromZipBytes(bytes);
      if (bundledVer == null) continue;
      if (WappInstallerService.compareVersions(bundledVer, instVer) <= 0) {
        continue; // bundled not newer
      }

      final res = await WappInstallerService.instance
          .installFromBytes(wappId: name, zipBytes: bytes);
      if (res.ok) {
        upgraded++;
        debugPrint('upgradeBundledWapps: $name $instVer -> $bundledVer');
      }
    }
  } catch (_) {
    // No bundled wapps / asset manifest unavailable — nothing to upgrade.
  }
  return upgraded;
}

/// Install every default wapp bundled under `assets/wapps/*.wapp` — the
/// curated seed set packaged as flat .wapp zips so it survives into a real
/// APK / app bundle (Android/iOS, packaged desktop). Returns the count.
Future<int> _seedDefaultsFromAssets() async {
  var count = 0;
  const prefix = 'assets/wapps/';
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final bundles = manifest
        .listAssets()
        .where((a) => a.startsWith(prefix) && a.endsWith('.wapp'));
    for (final asset in bundles) {
      final name =
          asset.substring(prefix.length, asset.length - '.wapp'.length);
      final data = await rootBundle.load(asset);
      final res = await WappInstallerService.instance.installFromBytes(
          wappId: name, zipBytes: data.buffer.asUint8List());
      if (res.ok) count++;
    }
  } catch (_) {
    // No bundled wapps / asset manifest unavailable — nothing to seed.
  }
  return count;
}

/// Copy the default set from the in-repo ../wapps library (desktop run from
/// source). Returns the count installed (0 when the library isn't present,
/// e.g. on a device — the caller then falls back to the bundled assets).
Future<int> _seedDefaultsFromFilesystem() async {
  var count = 0;
  final cwd = platform.currentDirectory();
  for (final libPath in ['$cwd/../wapps', '$cwd/../../wapps']) {
    final lib = wappPackageStorage(libPath);
    if (!await lib.directoryExists('')) continue;
    final entries = await lib.listDirectory('');
    for (final entry in entries) {
      if (!entry.isDirectory) continue;
      final dir = lib.getAbsolutePath(entry.path);
      final pkg = wappPackageStorage(dir);
      final manifest = await pkg.readJson('manifest.json');
      if (manifest == null) continue;
      // The wapp editor is no longer a grid wapp — it's bundled and
      // installed to its own location (see editor_install.dart) and reached
      // only via the per-wapp Edit action. Never seed it into the grid.
      if (entry.name == 'app-creator') continue;
      final kind = manifest['kind'] as String? ?? 'app';
      if (!_kDefaultSeedNames.contains(entry.name) && kind != 'system') {
        continue;
      }
      final res = await WappInstallerService.instance
          .installFromPath(wappId: entry.name, sourceDir: dir);
      if (res.ok) count++;
    }
    break; // first existing library dir wins
  }
  return count;
}

