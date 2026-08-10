part of 'launcher.dart';

// ── First-run wapp seeding ───────────────────────────────────────────

/// Folder names always auto-installed on first run, on top of every
/// `kind: "system"` wapp. Keeps the default set in one place.
const _kDefaultSeedNames = {
  'install',
  'mail',
  'chat',
  'mp4player',
  'reticulum',
  'social',
  'xprs',
  'torrents',
};

/// One-time migration for a wapp FOLDER rename ([oldName] -> [newName]).
///
/// A wapp's folder name is its install key: it names the extracted package dir,
/// the data dir that holds its history and settings, its autostart preference,
/// and its entry in the two offered-sets. So a rename that only swaps the
/// bundled `.wapp` would leave the old install (and its history) orphaned and
/// install the new one as a stranger.
///
/// Moves all four:
///   - program dir  `wapps/<old>`      -> `wapps/<new>`
///   - data dir     `data/<old>`       -> `data/<new>`   (history + settings)
///   - preference   `wapp.autostart.*`
///   - offered-sets `.seed_offered.json` / `.seeded.json` — without these,
///     [upgradeBundledWapps] would treat the renamed bundle as a first-time
///     addition and reinstall it even for a user who deliberately uninstalled
///     the wapp under its old name.
///
/// Idempotent: a no-op once `<new>` exists / `<old>` is gone. Runs before
/// seeding + the bundled-wapp upgrade, so the renamed install then upgrades to
/// the new bundle (new id/title/icon).
Future<void> _migrateWappFolder(String oldName, String newName) async {
  if (ProfileService.instance.activeProfile == null) return;
  final tag = 'migrate wapp $oldName -> $newName';
  final prefs = await PreferencesService.instance();
  final installed = installedAppsStorage();
  // Program dir: the extracted .wapp package.
  try {
    final hasOld = await installed.directoryExists(oldName);
    final hasNew = await installed.directoryExists(newName);
    if (hasOld && !hasNew) {
      await installed.renameDirectory(oldName, newName);
      debugPrint('$tag: program dir moved');
    } else if (hasOld && hasNew) {
      // BOTH exist — seen live: the rename was skipped on an earlier launch
      // while the bundled `<new>.wapp` installed itself as a first-time
      // addition, leaving the old install behind. The launcher then lists the
      // wapp TWICE, under both names. The new dir is the current bundle, so
      // the old one is a stale copy: drop it. A user-edited copy is never
      // deleted — that is somebody's source, not a package we can re-extract.
      final oldManifest = await installed.readJson('$oldName/manifest.json');
      if (oldManifest?['user_modified'] == true) {
        debugPrint('$tag: both dirs exist, keeping user-modified $oldName');
      } else {
        await installed.deleteDirectory(oldName, recursive: true);
        debugPrint('$tag: removed stale duplicate program dir $oldName');
      }
    }
  } catch (e) {
    debugPrint('$tag program: $e');
  }
  // Data dir: the wapp's messages, settings and archives — keyed by wapp name,
  // so it must move too or history is lost. Honours the user's wappDataDir
  // override via wappsDataStorage.
  try {
    final data = wappsDataStorage(prefs);
    if (await data.directoryExists(oldName) &&
        !await data.directoryExists(newName)) {
      await data.renameDirectory(oldName, newName);
      debugPrint('$tag: data dir moved');
    }
  } catch (e) {
    debugPrint('$tag data: $e');
  }
  await prefs.migrateWappAutostart(oldName, newName);
  // Offered-sets: carry the "was offered" record across the rename so an
  // uninstall under the old name keeps sticking for the renamed bundle.
  try {
    final j = jsonDecode(await installed.readString('.seed_offered.json') ?? '');
    if (j is Map && j['offered'] is List) {
      final offered = (j['offered'] as List).whereType<String>().toSet();
      if (offered.remove(oldName)) {
        offered.add(newName);
        await installed
            .writeJson('.seed_offered.json', {'offered': offered.toList()});
        debugPrint('$tag: .seed_offered updated');
      }
    }
  } catch (_) {}
  try {
    final profileRoot = activeProfileRoot();
    final marker = await profileRoot.readJson('.seeded.json');
    final offeredList = marker?['offered'];
    if (marker != null && offeredList is List) {
      final offered = offeredList.map((e) => e.toString()).toSet();
      if (offered.remove(oldName)) {
        offered.add(newName);
        await profileRoot
            .writeJson('.seeded.json', {...marker, 'offered': offered.toList()});
        debugPrint('$tag: .seeded offered updated');
      }
    }
  } catch (e) {
    debugPrint('$tag seeded marker: $e');
  }
}

/// Rename aprs -> chat: an existing profile transitions to the renamed "Chat"
/// wapp instead of keeping the old "APRS" one (or losing it).
Future<void> migrateAprsToChat() => _migrateWappFolder('aprs', 'chat');

/// Rename nostr -> social.
Future<void> migrateNostrToSocial() => _migrateWappFolder('nostr', 'social');

/// Rename messages -> mail: the one kind-4 inbox keeps its conversation
/// history, its dedup ring and its autostart setting across the rename.
Future<void> migrateMessagesToMail() => _migrateWappFolder('messages', 'mail');

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
  // Names ever offered to this profile: a wapp newly ADDED to the bundle is
  // installed once even for existing profiles (seeding only runs at profile
  // creation, so it would otherwise never appear), while a wapp the user
  // uninstalled stays gone (its name is already recorded here).
  final offered = <String>{};
  var offeredChanged = false;
  try {
    final j = jsonDecode(await installed.readString('.seed_offered.json') ?? '');
    if (j is Map && j['offered'] is List) {
      offered.addAll((j['offered'] as List).whereType<String>());
    }
  } catch (_) {}
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final bundles = manifest
        .listAssets()
        .where((a) => a.startsWith(prefix) && a.endsWith('.wapp'));
    for (final asset in bundles) {
      final name =
          asset.substring(prefix.length, asset.length - '.wapp'.length);
      final instManifest = await installed.readJson('$name/manifest.json');
      if (instManifest == null) {
        // Not installed: first-time bundle addition → install once.
        if (!offered.add(name)) continue; // previously offered → respect uninstall
        offeredChanged = true;
        final data = await rootBundle.load(asset);
        final res = await WappInstallerService.instance.installFromBytes(
            wappId: name, zipBytes: data.buffer.asUint8List());
        if (res.ok) {
          upgraded++;
          debugPrint('upgradeBundledWapps: installed new bundled wapp $name');
        }
        continue;
      }
      // Installed wapps count as offered — a later uninstall then sticks.
      if (offered.add(name)) offeredChanged = true;
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
  if (offeredChanged) {
    try {
      await installed.writeString(
          '.seed_offered.json', jsonEncode({'offered': offered.toList()}));
    } catch (_) {}
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

/// Default wapps added AFTER the first seeding shipped. A profile seeded before
/// these existed would never receive them — seeding runs once per profile, and
/// the upgrade pass only touches already-installed wapps. So backfill each of
/// these exactly ONCE per profile, recorded in `.seeded.json['offered']` so a
/// wapp the user later uninstalls is never resurrected.
const _kBackfillDefaults = {'mp4player', 'reticulum'};

/// Install any [_kBackfillDefaults] not yet offered to this profile. Runs every
/// launch (cheap: a marker read + a set check). Returns the count installed.
Future<int> ensureNewDefaultWapps() async {
  if (ProfileService.instance.activeProfile == null) return 0;
  final profileRoot = activeProfileRoot();
  final marker = await profileRoot.readJson('.seeded.json');
  // Never seeded yet — ensureProfileSeeded() installs the full default set
  // (which already includes these). Nothing to backfill.
  if (marker == null) return 0;

  final offered = <String>{
    for (final e in (marker['offered'] as List? ?? const [])) e.toString(),
  };
  final installed = installedAppsStorage();
  var added = 0;
  var changed = false;
  for (final name in _kBackfillDefaults) {
    if (offered.contains(name)) continue; // offered before — respect the user
    final has = await installed.readJson('$name/manifest.json');
    if (has != null) {
      offered.add(name); // already present — record so we don't re-offer
      changed = true;
      continue;
    }
    if (await _installDefaultWapp(name)) {
      offered.add(name);
      added++;
      changed = true;
      debugPrint('ensureNewDefaultWapps: installed $name');
    }
    // install failed → leave unoffered so a later launch retries.
  }
  if (changed) {
    await profileRoot
        .writeJson('.seeded.json', {...marker, 'offered': offered.toList()});
  }
  return added;
}

/// Install one wapp by [name] from the in-repo ../wapps library (desktop run
/// from source) or, failing that, the bundled `assets/wapps/[name].wapp`.
Future<bool> _installDefaultWapp(String name) async {
  final cwd = platform.currentDirectory();
  for (final dir in ['$cwd/../wapps/$name', '$cwd/../../wapps/$name']) {
    final pkg = wappPackageStorage(dir);
    if (await pkg.exists('manifest.json')) {
      final res = await WappInstallerService.instance
          .installFromPath(wappId: name, sourceDir: dir);
      if (res.ok) return true;
    }
  }
  try {
    final data = await rootBundle.load('assets/wapps/$name.wapp');
    final res = await WappInstallerService.instance
        .installFromBytes(wappId: name, zipBytes: data.buffer.asUint8List());
    return res.ok;
  } catch (_) {
    return false;
  }
}

