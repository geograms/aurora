part of 'launcher.dart';

// ── First-run wapp seeding ───────────────────────────────────────────

/// Folder names always auto-installed on first run, on top of every
/// `kind: "system"` wapp. Keeps the default set in one place.
const _kDefaultSeedNames = {'install', 'maps'};

/// First-run bootstrap, run as a boot task BEFORE the UI so the launcher
/// never renders an empty grid mid-seed. Installs the curated default
/// set into the active profile exactly once; a per-profile
/// `.seeded.json` marker means a later "uninstall everything" sticks —
/// we never re-seed.
Future<void> ensureProfileSeeded() async {
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

