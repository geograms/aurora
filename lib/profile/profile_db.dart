/*
 * Central SQLite opener for profile databases + the in-memory keyring of
 * unlocked profiles (docs/plan-encrypted-storage.md, Phase 2).
 *
 * Every `sqlite3.open()` on a database that lives under a profile folder
 * MUST go through [openProfileDb]. For plain profiles it behaves exactly
 * like `sqlite3.open`. For encrypted profiles (a `keyslot.json` exists in
 * the profile root) it applies the per-database SQLCipher key derived from
 * the profile master key, or throws [ProfileLockedException] when the
 * profile has not been unlocked yet.
 *
 * The native library is SQLCipher on every platform
 * (sqlcipher_flutter_libs); it opens plain SQLite databases identically
 * when no key is set, so unencrypted profiles are unaffected.
 *
 * io-only: do not import from web-shared code.
 */

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqlcipher_flutter_libs/sqlcipher_flutter_libs.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import 'profile_crypto.dart';
import 'storage_paths.dart';

/// Test seam: overrides the storage root used to map database paths to
/// profiles (normally `geogramRootStorage().basePath`).
@visibleForTesting
String? profileDbRootOverride;

/// Storage root used for profile-path mapping (override-aware; normally
/// `geogramRootStorage().basePath`).
String profileStorageRoot() =>
    profileDbRootOverride ?? geogramRootStorage().basePath;

/// Thrown when a database inside an encrypted profile is opened before the
/// profile has been unlocked.
class ProfileLockedException implements Exception {
  final String profileId;
  final String path;
  const ProfileLockedException(this.profileId, this.path);
  @override
  String toString() =>
      'ProfileLockedException: profile $profileId is locked (wanted $path)';
}

/// File name that marks a profile as encrypted (written at enable time,
/// holds the wrapped master key — see ProfileKeyslot).
const String keyslotFileName = 'keyslot.json';

/// In-memory keyring of unlocked profiles. UI (unlock page) or the
/// remember-key cache put keys in; [openProfileDb] and the encrypted
/// ProfileStorage backend read them out.
class ProfileKeyring {
  ProfileKeyring._();
  static final ProfileKeyring instance = ProfileKeyring._();

  final Map<String, UnlockedProfileKeys> _unlocked = {};

  /// Listeners fired (fire-and-forget) when a profile locks, so holders of
  /// derived resources (open profile.ear archives) can close them.
  final List<Future<void> Function(String profileId)> onLock = [];

  /// Listeners fired (fire-and-forget) right after a profile unlocks. The
  /// encrypted storage backend uses this to pre-open profile.ear so the
  /// sync (WASM HAL) paths find it ready.
  final List<Future<void> Function(String profileId)> onUnlock = [];

  bool isUnlocked(String profileId) => _unlocked.containsKey(profileId);

  UnlockedProfileKeys? keysFor(String profileId) => _unlocked[profileId];

  void putKeys(String profileId, UnlockedProfileKeys keys) {
    _unlocked[profileId]?.dispose();
    _unlocked[profileId] = keys;
    for (final listener in onUnlock) {
      unawaited(listener(profileId));
    }
  }

  /// Drop a profile's keys (zeroing the master key). Fires [onLock] so the
  /// encrypted storage backend closes its archive; database handles opened
  /// via [openProfileDb] must be closed by their owners.
  void lock(String profileId) {
    final keys = _unlocked.remove(profileId);
    if (keys == null) return;
    for (final listener in onLock) {
      unawaited(listener(profileId));
    }
    keys.dispose();
  }

  void lockAll() {
    for (final id in _unlocked.keys.toList()) {
      lock(id);
    }
  }

  /// Whether the profile with [profileId] has encryption enabled on disk.
  bool isEncryptedProfile(String profileId) =>
      File(_keyslotPath(profileId)).existsSync();

  String _keyslotPath(String profileId) =>
      '${profileStorageRoot()}/devices/$profileId/$keyslotFileName';
}

bool _sqlcipherLoaded = false;

/// Make package:sqlite3 resolve to the bundled SQLCipher library. Safe to
/// call repeatedly; must run before the first database open on Android
/// (package:sqlite3 caches the loaded library on first use — since every
/// profile DB open goes through [openProfileDb], that holds).
void ensureSqlCipherLoaded() {
  if (_sqlcipherLoaded) return;
  if (Platform.isAndroid) {
    open.overrideFor(OperatingSystem.android, openCipherOnAndroid);
  }
  // Desktop + iOS/macOS: sqlcipher_flutter_libs bundles the library under
  // the default resolution names, no override needed.
  _sqlcipherLoaded = true;
}

/// The native SQLite library a BACKGROUND ISOLATE must load before it opens
/// a database, or null when the platform default is right.
///
/// package:sqlite3's loader override lives per-isolate: [ensureSqlCipherLoaded]
/// only fixes the isolate it runs on. Any isolate that opens SQLite (the NOSTR
/// engine) has to be told the same thing, or it looks for a plain libsqlite3.so
/// that this app does not ship — and dies. Pass this into the spawn message.
String? engineSqliteLibrary() => Platform.isAndroid ? 'libsqlcipher.so' : null;

/// SQLCipher key (raw hex) for the database at [absPath], or null when it is
/// not inside an encrypted profile. For isolates that cannot reach the
/// keyring; on the main isolate, [openProfileDb] does this itself.
String? profileDbKeyHex(String absPath) {
  final loc = locateProfileDb(absPath);
  if (loc == null) return null;
  if (!ProfileKeyring.instance.isEncryptedProfile(loc.profileId)) return null;
  return ProfileKeyring.instance.keysFor(loc.profileId)?.dbKeyHex(loc.relPath);
}

/// Result of mapping an absolute path into the profile layout.
class ProfileDbLocation {
  final String profileId;

  /// Forward-slash path relative to `devices/<id>/`, e.g. `data/mesh.sqlite3`.
  /// This exact string feeds the per-DB key derivation — treat as stable API.
  final String relPath;

  const ProfileDbLocation(this.profileId, this.relPath);
}

/// Map [absPath] to (profileId, profile-relative path), or null when the
/// path is not inside `devices/<id>/` (e.g. the user pointed the wapp data
/// dir somewhere else via preferences — those databases stay plain; the
/// plan documents this limitation).
ProfileDbLocation? locateProfileDb(String absPath) {
  final root = profileStorageRoot().replaceAll('\\', '/');
  final norm = absPath.replaceAll('\\', '/');
  final prefix = '$root/devices/';
  if (!norm.startsWith(prefix)) return null;
  final rest = norm.substring(prefix.length);
  final slash = rest.indexOf('/');
  if (slash <= 0 || slash == rest.length - 1) return null;
  final profileId = rest.substring(0, slash);
  final relPath = rest.substring(slash + 1);
  return ProfileDbLocation(profileId, relPath);
}

/// Open a SQLite database that (possibly) lives inside a profile folder.
///
/// - Plain profile / non-profile path: behaves exactly like `sqlite3.open`.
/// - Encrypted profile, unlocked: opens with the derived SQLCipher key.
/// - Encrypted profile, locked: throws [ProfileLockedException].
/// - Wrong key / corrupt file: throws [SqliteException] (NOTADB).
Database openProfileDb(String absPath) {
  ensureSqlCipherLoaded();

  final loc = locateProfileDb(absPath);
  if (loc == null || !ProfileKeyring.instance.isEncryptedProfile(loc.profileId)) {
    return sqlite3.open(absPath);
  }

  final keys = ProfileKeyring.instance.keysFor(loc.profileId);
  if (keys == null) {
    throw ProfileLockedException(loc.profileId, absPath);
  }

  final db = sqlite3.open(absPath);
  try {
    db.execute('PRAGMA key = "x\'${keys.dbKeyHex(loc.relPath)}\'";');

    // If the plain sqlite3 library got loaded instead of SQLCipher the key
    // pragma silently no-ops and we would write PLAINTEXT — fail loud.
    final cipherVersion = db.select('PRAGMA cipher_version;');
    if (cipherVersion.isEmpty) {
      throw StateError(
        'SQLCipher not loaded (cipher_version empty) — refusing to open '
        'encrypted profile database $absPath without encryption',
      );
    }

    // Force key verification now (wrong key surfaces here as NOTADB
    // instead of at some later random query).
    db.select('SELECT count(*) FROM sqlite_master;');
    return db;
  } catch (_) {
    db.dispose();
    rethrow;
  }
}
