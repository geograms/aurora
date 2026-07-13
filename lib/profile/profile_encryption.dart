/*
 * ProfileEncryption — enable / unlock / lock / disable / password
 * orchestration for encrypted profiles (docs/plan-encrypted-storage.md).
 *
 * Profiles are encrypted BY DEFAULT. A new profile gets "device key" mode:
 * a random secret in the OS keychain (DeviceKeyStore) plays the role of the
 * password, and unlocking asks for fingerprint/face (BiometricGate) instead
 * of typing anything. The user can ADD a password later — that replaces the
 * device secret with something they carry in their head, which is the only
 * thing that also protects the profile from someone who owns the unlocked
 * phone.
 *
 * On-disk pieces:
 *   devices/<id>/keyslot.json   wrapped profile master key (ProfileKeyslot)
 *   profiles.json entry         nsec_enc envelope instead of plaintext nsec
 *   OS keychain (or, on desktop, app-private files)
 *                               device password + the {PMK, nsec} key cache
 *
 * Enabling deletes the profile's existing user data (no plain->encrypted
 * conversion, by decision). Disabling deletes the encrypted data.
 */

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'biometric_gate.dart';
import 'device_key_store.dart';
import 'iwi_profile.dart';
import 'profile_crypto.dart';
import 'profile_db.dart';
import 'profile_service.dart';
import 'profile_storage_encrypted.dart';
import '../services/log_service.dart';

class ProfileEncryption {
  ProfileEncryption._();

  static String _profileDir(String id) =>
      '${profileStorageRoot()}/devices/$id';
  static String _keyslotPath(String id) =>
      '${_profileDir(id)}/$keyslotFileName';

  static bool isEncrypted(String id) =>
      ProfileKeyring.instance.isEncryptedProfile(id);

  static bool isUnlocked(String id) => ProfileKeyring.instance.isUnlocked(id);

  /// True while the profile is unlocked by a device secret rather than by a
  /// password the user knows (the default for new profiles).
  static Future<bool> usesDeviceKey(String id) =>
      DeviceKeyStore.instance.hasDevicePassword(id);

  static Future<bool> hasCachedKeys(String id) =>
      DeviceKeyStore.instance.hasCachedKeys(id);

  /// A Flutter engine with no views: the headless Android boot (BgService)
  /// and the background service. There is no screen to prompt on, so the
  /// device key unlocks silently — that is the whole point of it. With a UI
  /// present, a device-key profile must pass the biometric prompt instead.
  static bool get isHeadless =>
      PlatformDispatcher.instance.views.isEmpty;

  /// Whether the UI must show the unlock page for this profile, or the keys
  /// can be taken from the keychain without asking.
  ///
  /// Password profiles that the user told to stay unlocked: silent. Device-key
  /// profiles: never silent in the UI — the fingerprint prompt IS the lock.
  static Future<bool> canUnlockSilently(String id) async {
    if (!isEncrypted(id)) return true;
    if (isUnlocked(id)) return true;
    if (isHeadless) return true;
    if (await usesDeviceKey(id)) return false;
    return hasCachedKeys(id);
  }

  /// Encrypt a brand-new profile with no user interaction: mint a random
  /// device secret, hold it in the OS keychain, leave the profile unlocked
  /// and remembered. Called right after profile creation.
  ///
  /// Safe on an already-encrypted profile (no-op) and on a profile with data
  /// (it deletes it, same as [enable] — but a fresh profile has none).
  static Future<void> enableWithDeviceKey(String id) async {
    if (isEncrypted(id)) return;
    final password = await DeviceKeyStore.instance.ensureDevicePassword(id);
    try {
      await enable(id, password, remember: true);
    } catch (e) {
      await DeviceKeyStore.instance.clearDevicePassword(id);
      rethrow;
    }
    LogService.instance.add('encryption: device-key mode for $id');
  }

  /// Enable encryption on a profile. DELETES its existing user data
  /// (data/ tree, avatar, every SQLite DB under wapps/) — caller must have
  /// confirmed this with the user — then writes the keyslot + nsec
  /// envelope and leaves the profile unlocked.
  static Future<void> enable(String id, String password,
      {bool remember = false}) async {
    final service = ProfileService.instance;
    final profile = _byId(id);
    if (profile == null) throw StateError('Unknown profile: $id');
    if (profile.nsec.isEmpty) {
      throw StateError('Profile has no nsec — cannot enable encryption');
    }
    if (isEncrypted(id)) return;

    final secrets =
        await ProfileCrypto.createProfileSecrets(password, profile.nsec);

    // Old plaintext data dies here (no conversion, by decision). Best
    // effort; on flash the real protection is enabling encryption early.
    _deleteProfileUserData(id);

    File(_keyslotPath(id))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(secrets.keyslot.toJson()), flush: true);

    ProfileKeyring.instance.putKeys(id, secrets.keys);
    if (remember) {
      await DeviceKeyStore.instance.writeCachedKeys(id, secrets.keys);
    }

    await service.update(profile.copyWith(
      nsecEnvelope: secrets.nsecEnvelope.toJson(),
      avatar: '',
    ));
    LogService.instance.add('encryption: enabled for $id');
  }

  /// Disable encryption: verifies the secret ([password] null = use the
  /// device key), DELETES the encrypted data and restores a plain profile
  /// with the plaintext nsec back in profiles.json.
  static Future<void> disable(String id, {String? password}) async {
    final service = ProfileService.instance;
    final profile = _byId(id);
    if (profile == null) throw StateError('Unknown profile: $id');
    if (!isEncrypted(id)) return;

    final secret = password ?? await _requireDevicePassword(id);
    // Proves the secret and recovers the nsec even when locked.
    final keys = await _unlockKeys(profile, secret);
    final nsec = keys.nsec;
    keys.dispose();

    ProfileKeyring.instance.lock(id);
    await EncryptedProfileStorage.closeArchive(id);
    _deleteProfileUserData(id);
    _tryDelete(_keyslotPath(id));
    await DeviceKeyStore.instance.clearAll(id);

    await service.update(profile.copyWith(
      nsec: nsec,
      clearNsecEnvelope: true,
      avatar: '',
    ));
    LogService.instance.add('encryption: disabled for $id');
  }

  /// Unlock with a password the user typed. Throws [WrongProfilePassword] on
  /// a bad password.
  static Future<void> unlock(String id, String password,
      {bool remember = false}) async {
    final profile = _byId(id);
    if (profile == null) throw StateError('Unknown profile: $id');

    final keys = await _unlockKeys(profile, password);
    ProfileKeyring.instance.putKeys(id, keys);
    await _hydrateNsec(profile, keys.nsec);

    if (remember) {
      await DeviceKeyStore.instance.writeCachedKeys(id, keys);
    } else {
      await DeviceKeyStore.instance.clearCachedKeys(id);
    }
    LogService.instance.add('encryption: unlocked $id');
  }

  /// Unlock without a typed password: fingerprint/face, then the keychain.
  ///
  /// Returns false when the user failed/cancelled the biometric prompt or
  /// there is nothing in the keychain for this profile (then it's a
  /// password profile, and the UI must ask).
  static Future<bool> unlockWithBiometrics(String id,
      {String reason = 'Unlock your profile'}) async {
    if (!isEncrypted(id)) return true;
    if (isUnlocked(id)) return true;
    if (!await DeviceKeyStore.instance.hasCachedKeys(id) &&
        !await DeviceKeyStore.instance.hasDevicePassword(id)) {
      return false;
    }
    if (!await BiometricGate.instance.authenticate(reason: reason)) {
      LogService.instance.add('encryption: biometric refused for $id');
      return false;
    }
    return _unlockFromStore(id);
  }

  /// Silent unlock from the keychain — no biometric prompt. This is the
  /// HEADLESS path (Android boot, background service): there is no UI to
  /// prompt with, and the whole point of the device key is that background
  /// message reception keeps working.
  static Future<bool> tryUnlockCached(String id) async {
    if (!isEncrypted(id)) return true;
    if (isUnlocked(id)) return true;
    return _unlockFromStore(id);
  }

  static Future<bool> _unlockFromStore(String id) async {
    try {
      final keys = await DeviceKeyStore.instance.readCachedKeys(id);
      if (keys != null) {
        ProfileKeyring.instance.putKeys(id, keys);
        final profile = _byId(id);
        if (profile != null) await _hydrateNsec(profile, keys.nsec);
        LogService.instance.add('encryption: unlocked $id from device key');
        return true;
      }
      // No cache but a device password: derive the keys from it (slower —
      // one Argon2id pass — but it keeps working after a cache wipe).
      final password = await DeviceKeyStore.instance.readDevicePassword(id);
      if (password == null || password.isEmpty) return false;
      final profile = _byId(id);
      if (profile == null) return false;
      final derived = await _unlockKeys(profile, password);
      ProfileKeyring.instance.putKeys(id, derived);
      await _hydrateNsec(profile, derived.nsec);
      await DeviceKeyStore.instance.writeCachedKeys(id, derived);
      LogService.instance.add('encryption: unlocked $id from device password');
      return true;
    } catch (e) {
      LogService.instance.add('encryption: device unlock failed for $id: $e');
      return false;
    }
  }

  /// Add a password to a device-key profile: re-wraps the master key under
  /// what the user typed and drops the device secret, so from now on the
  /// profile cannot be opened without them.
  static Future<void> addPassword(String id, String newPassword) async {
    final devicePassword = await _requireDevicePassword(id);
    await _rewrap(id, devicePassword, newPassword);
    await DeviceKeyStore.instance.clearDevicePassword(id);
    LogService.instance.add('encryption: password set for $id');
  }

  /// Drop the user's password and go back to device-key mode (biometric
  /// unlock, nothing to remember). Verifies the current password first.
  static Future<void> removePassword(String id, String currentPassword) async {
    final devicePassword =
        await DeviceKeyStore.instance.ensureDevicePassword(id);
    try {
      await _rewrap(id, currentPassword, devicePassword);
    } catch (e) {
      await DeviceKeyStore.instance.clearDevicePassword(id);
      rethrow;
    }
    LogService.instance.add('encryption: back to device key for $id');
  }

  /// Change the password: re-wraps the master key + nsec envelope only;
  /// archive and databases stay untouched.
  static Future<void> changePassword(
          String id, String oldPassword, String newPassword) =>
      _rewrap(id, oldPassword, newPassword);

  static Future<void> _rewrap(
      String id, String oldPassword, String newPassword) async {
    final service = ProfileService.instance;
    final profile = _byId(id);
    if (profile == null) throw StateError('Unknown profile: $id');
    final envelope = _envelopeOf(profile);
    final keyslot = _readKeyslot(id);

    final changed = await ProfileCrypto.changePassword(
        oldPassword, newPassword, envelope, keyslot);

    File(_keyslotPath(id)).writeAsStringSync(
        jsonEncode(changed.keyslot.toJson()),
        flush: true);
    await service.update(profile.copyWith(
      nsecEnvelope: changed.nsecEnvelope.toJson(),
    ));
    // The cached keys still work (the PMK never changes) — rewriting keeps
    // the stored blob current.
    if (await DeviceKeyStore.instance.hasCachedKeys(id)) {
      await DeviceKeyStore.instance.writeCachedKeys(id, changed.keys);
    }
    changed.keys.dispose();
  }

  /// Drop the keys + the device cache and close the archive. The caller is
  /// responsible for exiting/restarting the app: long-lived services still
  /// hold open database handles that cannot be revoked in place.
  static Future<void> lockNow(String id) async {
    await DeviceKeyStore.instance.clearCachedKeys(id);
    ProfileKeyring.instance.lock(id);
    await EncryptedProfileStorage.closeArchive(id);
    LogService.instance.add('encryption: locked $id');
  }

  static Future<void> clearCachedKeys(String id) =>
      DeviceKeyStore.instance.clearCachedKeys(id);

  // ── internals ──────────────────────────────────────────────────────────

  static Future<String> _requireDevicePassword(String id) async {
    final pw = await DeviceKeyStore.instance.readDevicePassword(id);
    if (pw == null || pw.isEmpty) {
      throw StateError('Profile $id has no device key — a password is needed');
    }
    return pw;
  }

  static IwiProfile? _byId(String id) {
    for (final p in ProfileService.instance.profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  static NsecEnvelope _envelopeOf(IwiProfile profile) {
    final raw = profile.nsecEnvelope;
    if (raw == null) {
      throw const ProfileKeyslotCorrupt('Profile has no nsec envelope');
    }
    return NsecEnvelope.fromJson(raw);
  }

  static ProfileKeyslot _readKeyslot(String id) {
    final f = File(_keyslotPath(id));
    if (!f.existsSync()) {
      throw const ProfileKeyslotCorrupt('keyslot.json missing');
    }
    return ProfileKeyslot.fromJson(
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
  }

  static Future<UnlockedProfileKeys> _unlockKeys(
      IwiProfile profile, String password) {
    return ProfileCrypto.unlock(
        password, _envelopeOf(profile), _readKeyslot(profile.id));
  }

  static Future<void> _hydrateNsec(IwiProfile profile, String nsec) async {
    if (profile.nsec == nsec) return;
    // Safe to persist: toJson writes the envelope, never the plaintext
    // nsec, for encrypted profiles.
    await ProfileService.instance.update(profile.copyWith(nsec: nsec));
  }

  /// Delete a profile's user data, keeping wapp code, seed markers and the
  /// keyslot: data/ tree, avatar, profile.ear(+wal/shm), every *.sqlite3*
  /// under wapps/.
  static void _deleteProfileUserData(String id) {
    final base = _profileDir(id);
    _tryDeleteDir('$base/data');
    for (final name in ['avatar.png', 'avatar.jpg']) {
      _tryDelete('$base/$name');
    }
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      _tryDelete('$base/$profileArchiveName$suffix');
    }
    final wapps = Directory('$base/wapps');
    if (wapps.existsSync()) {
      for (final f in wapps.listSync(recursive: true).whereType<File>()) {
        if (f.path.contains('.sqlite3')) _tryDelete(f.path);
      }
    }
  }

  static void _tryDelete(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  static void _tryDeleteDir(String path) {
    try {
      final d = Directory(path);
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {}
  }
}
