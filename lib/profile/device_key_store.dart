/*
 * Where an encrypted profile's device key lives.
 *
 * Profiles are encrypted BY DEFAULT (no password step at onboarding), so
 * something has to hold the secret that unlocks them:
 *
 *   Android/iOS: flutter_secure_storage — the OS keychain, i.e. an
 *     AES key held by the Android Keystore (hardware-backed where the
 *     device has a TEE/StrongBox). Another app cannot read it; a wiped
 *     app loses it, which is why the nsec is mirrored separately (see
 *     identity_backup.dart).
 *   Desktop: an app-private file next to profiles.json. Linux has no
 *     universal keychain we can depend on headlessly, so this protects a
 *     profile folder that is copied off the machine, not a local attacker
 *     with the whole home directory. Adding a user password (profile edit)
 *     is what raises that bar.
 *
 * Two things are stored per profile:
 *   - the DEVICE PASSWORD: a random 32-byte secret that plays the role of
 *     the user's password in the key hierarchy (ProfileCrypto). Present
 *     only while the profile is in "device key" mode; adding a user
 *     password deletes it.
 *   - the KEY CACHE ({PMK, nsec}) — the "keep unlocked on this device"
 *     material that lets a headless boot open the profile.
 */

import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../platform/platform.dart' as platform;
import 'profile_crypto.dart';
import 'profile_db.dart';

class DeviceKeyStore {
  DeviceKeyStore._();
  static final DeviceKeyStore instance = DeviceKeyStore._();

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  bool get _useKeychain =>
      platform.platformName() == 'android' || platform.platformName() == 'ios';

  String _devicePasswordKey(String profileId) => 'aurora.devicepw.$profileId';
  String _cacheKey(String profileId) => 'aurora.keycache.$profileId';

  String _cacheFile(String profileId) =>
      '${profileStorageRoot()}/keycache-$profileId.json';
  String _devicePasswordFile(String profileId) =>
      '${profileStorageRoot()}/devicekey-$profileId.txt';

  // ── device password (device-key mode) ──────────────────────────────────

  Future<String?> readDevicePassword(String profileId) async {
    if (_useKeychain) {
      return _secure.read(key: _devicePasswordKey(profileId));
    }
    final f = File(_devicePasswordFile(profileId));
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  /// Mint (or return the existing) random device password for [profileId].
  Future<String> ensureDevicePassword(String profileId) async {
    final existing = await readDevicePassword(profileId);
    if (existing != null && existing.isNotEmpty) return existing;
    final secret = base64UrlEncode(ProfileCrypto.randomBytes(32));
    if (_useKeychain) {
      await _secure.write(key: _devicePasswordKey(profileId), value: secret);
    } else {
      File(_devicePasswordFile(profileId))
          .writeAsStringSync(secret, flush: true);
    }
    return secret;
  }

  Future<void> clearDevicePassword(String profileId) async {
    if (_useKeychain) {
      await _secure.delete(key: _devicePasswordKey(profileId));
    } else {
      _tryDelete(_devicePasswordFile(profileId));
    }
  }

  Future<bool> hasDevicePassword(String profileId) async {
    final pw = await readDevicePassword(profileId);
    return pw != null && pw.isNotEmpty;
  }

  // ── key cache ("keep unlocked on this device") ─────────────────────────

  Future<UnlockedProfileKeys?> readCachedKeys(String profileId) async {
    try {
      final raw = _useKeychain
          ? await _secure.read(key: _cacheKey(profileId))
          : (File(_cacheFile(profileId)).existsSync()
              ? File(_cacheFile(profileId)).readAsStringSync()
              : null);
      if (raw == null || raw.isEmpty) return null;
      return UnlockedProfileKeys.fromCacheJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeCachedKeys(
      String profileId, UnlockedProfileKeys keys) async {
    final raw = jsonEncode(keys.toCacheJson());
    if (_useKeychain) {
      await _secure.write(key: _cacheKey(profileId), value: raw);
    } else {
      File(_cacheFile(profileId)).writeAsStringSync(raw, flush: true);
    }
  }

  Future<void> clearCachedKeys(String profileId) async {
    if (_useKeychain) {
      await _secure.delete(key: _cacheKey(profileId));
    } else {
      _tryDelete(_cacheFile(profileId));
    }
  }

  Future<bool> hasCachedKeys(String profileId) async {
    if (_useKeychain) {
      final raw = await _secure.read(key: _cacheKey(profileId));
      return raw != null && raw.isNotEmpty;
    }
    return File(_cacheFile(profileId)).existsSync();
  }

  /// Everything for this profile is gone — called when encryption is
  /// removed or the profile is deleted.
  Future<void> clearAll(String profileId) async {
    await clearDevicePassword(profileId);
    await clearCachedKeys(profileId);
  }

  void _tryDelete(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}
