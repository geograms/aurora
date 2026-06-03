/*
 * Central resolution of geogram storage roots. Every ProfileStorage instance
 * in iwi/lib/ should be obtained through this file so there is exactly one
 * place that knows the on-disk layout.
 *
 * Layout under the user home:
 *
 *   ~/.local/share/aurora/
 *     profiles.json             ← ProfileService state (list + active id)
 *     devices/<id>/
 *       wapps/<wapp-id>/        ← installed wapp packages (manifest, app.wasm, screens…)
 *       data/<wapp-id>/         ← each wapp's own data/settings (kv.json, hal_file_*)
 *
 * So `wapps/` holds the programs and `data/` holds their per-wapp
 * settings — two different things, one folder each. Every path below
 * resolves through the active ProfileService profile, so switching
 * profiles switches which `wapps/` and `data/` folders the launcher sees.
 *
 * IMPORTANT: aurora stores under ~/.local/share/aurora — NOT
 * ~/.local/share/geogram. The geogram dir belongs to the separate, real
 * geogram app and holds the user's real data; aurora must never read,
 * write, or delete there. (The old iwi fork wrongly pointed here at
 * geogram's dir; that is fixed.)
 */

import '../platform/platform.dart' as platform;
import '../services/preferences_service.dart';
import 'profile_service.dart';
import 'profile_storage.dart';
import 'profile_storage_factory.dart';

String _geogramBaseDir() {
  final home = platform.homeDir() ?? '/tmp';
  return '$home/.local/share/aurora';
}

/// Root storage — everything the geogram launcher persists lives under this.
/// Non-profile data (profiles.json itself, future cross-profile caches)
/// is written directly here; everything else flows through
/// [activeProfileRoot] below. On web the factory returns an in-memory
/// store, so the path string is purely cosmetic there.
ProfileStorage geogramRootStorage() =>
    makeFilesystemStorage(_geogramBaseDir());

/// Root storage for the currently-active profile. Returns a scoped
/// `devices/<id>/` storage when a profile is active, or
/// falls back to a scoped `devices/_no_profile/` bucket when nothing
/// has been chosen yet (which should only happen during the welcome
/// page lifecycle — any real I/O should go through
/// [ProfileService.instance.activeProfile] first and gate on null).
ProfileStorage activeProfileRoot() {
  final scoped = ProfileService.instance.activeProfileStorage();
  if (scoped != null) return scoped;
  return ScopedProfileStorage(geogramRootStorage(), 'devices/_no_profile');
}

/// Installed-wapps directory for the active profile. Each subdirectory
/// is an extracted .wapp package (the program). Lives under `wapps/`.
ProfileStorage installedAppsStorage() =>
    ScopedProfileStorage(activeProfileRoot(), 'wapps');

/// Absolute path to the installed-apps root — used only by code that must
/// hand an absolute path to an external tool (e.g. `unzip -d`).
String installedAppsDirPath() => installedAppsStorage().basePath;

/// Per-wapp data/settings root — honours the user-selectable override
/// from [PreferencesService.wappDataDir] if set, otherwise falls back to
/// the default `data/` subfolder inside the active profile.
ProfileStorage wappsDataStorage(PreferencesService prefs) {
  final override = prefs.wappDataDir;
  if (override != null && override.isNotEmpty) {
    return makeFilesystemStorage(override);
  }
  return ScopedProfileStorage(activeProfileRoot(), 'data');
}

/// Storage scoped to a single wapp's runtime data dir.
ProfileStorage wappDataStorageFor(PreferencesService prefs, String wappId) =>
    ScopedProfileStorage(wappsDataStorage(prefs), wappId);

/// Storage rooted at an arbitrary wapp package directory — either a built-in
/// source dir under `wapps/<name>/` or an installed-apps entry.
ProfileStorage wappPackageStorage(String wappDir) =>
    makeFilesystemStorage(wappDir);

/// One-time layout migration: the per-profile data folder was renamed
/// from `profiles/<id>/` to `devices/<id>/`. This renames the single
/// top-level dir in place, carrying every `<id>/apps`, `<id>/wapps`,
/// `.seeded` marker and the `_no_profile` bucket along with it. The
/// root-level `profiles.json` file is a sibling, not inside this dir,
/// so it is untouched.
///
/// Idempotent and safe to run on every boot: it no-ops when there is no
/// old `profiles/` dir (fresh install / already migrated) and refuses to
/// clobber an existing `devices/` dir. Must run before the launcher
/// scans the active profile's `apps/`.
Future<void> migrateProfilesDirToDevices() async {
  final root = geogramRootStorage();
  if (!await root.directoryExists('profiles')) return;
  if (await root.directoryExists('devices')) return;
  await root.renameDirectory('profiles', 'devices');
}

/// Run all on-disk layout migrations in order. Wired as the boot
/// `migrate-storage-layout` task. Idempotent.
Future<void> migrateStorageLayout() async {
  await migrateProfilesDirToDevices();
  await _migrateAppsAndDataFolders();
}

/// One-time per-device rename of the old layout
///   <id>/apps/   (installed packages)  -> <id>/wapps/
///   <id>/wapps/  (per-wapp data)       -> <id>/data/
/// The data rename runs FIRST so the `wapps/` name is free before the
/// packages rename takes it. Idempotent: each step is guarded so a
/// re-run (or an already-new layout) is a no-op.
Future<void> _migrateAppsAndDataFolders() async {
  final root = geogramRootStorage();
  if (!await root.directoryExists('devices')) return;
  final devices = await root.listDirectory('devices');
  for (final d in devices) {
    if (!d.isDirectory) continue;
    final dev = ScopedProfileStorage(root, 'devices/${d.name}');
    // old data dir `wapps` -> `data` (do first to free the `wapps` name)
    if (await dev.directoryExists('wapps') &&
        !await dev.directoryExists('data')) {
      await dev.renameDirectory('wapps', 'data');
    }
    // installed packages `apps` -> `wapps`
    if (await dev.directoryExists('apps') &&
        !await dev.directoryExists('wapps')) {
      await dev.renameDirectory('apps', 'wapps');
    }
  }
}
