/*
 * ProfileEncryption — enable / unlock / lock / disable / change-password
 * orchestration for encrypted profiles (Phase 4 of
 * docs/plan-encrypted-storage.md).
 *
 * On-disk pieces it manages:
 *   devices/<id>/keyslot.json   wrapped profile master key (ProfileKeyslot)
 *   profiles.json entry         nsec_enc envelope instead of plaintext nsec
 *   keycache-<id>.json          optional "keep unlocked on this device"
 *                               cache ({PMK, nsec}, app-private storage)
 *
 * Enabling deletes the profile's existing user data (user decision: no
 * plain->encrypted conversion) and starts fresh encrypted. Disabling
 * deletes the encrypted data and returns to a fresh plain profile.
 */

import 'dart:convert';
import 'dart:io';

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
  static String _cachePath(String id) =>
      '${profileStorageRoot()}/keycache-$id.json';

  static bool isEncrypted(String id) =>
      ProfileKeyring.instance.isEncryptedProfile(id);

  static bool isUnlocked(String id) => ProfileKeyring.instance.isUnlocked(id);

  /// Enable encryption on a profile. DELETES its existing user data
  /// (data/ tree, avatar, every SQLite DB under wapps/) — caller must have
  /// confirmed this with the user — then writes the keyslot + nsec
  /// envelope and leaves the profile unlocked.
  static Future<void> enable(String id, String password) async {
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

    await service.update(profile.copyWith(
      nsecEnvelope: secrets.nsecEnvelope.toJson(),
      avatar: '',
    ));
    LogService.instance.add('encryption: enabled for $id');
  }

  /// Disable encryption: verifies the password, DELETES the encrypted data
  /// (profile.ear, SQLCipher DBs, data/ tree) and restores a plain profile
  /// with the plaintext nsec back in profiles.json.
  static Future<void> disable(String id, String password) async {
    final service = ProfileService.instance;
    final profile = _byId(id);
    if (profile == null) throw StateError('Unknown profile: $id');
    if (!isEncrypted(id)) return;

    // Proves the password and recovers the nsec even when locked.
    final keys = await _unlockKeys(profile, password);
    final nsec = keys.nsec;
    keys.dispose();

    ProfileKeyring.instance.lock(id);
    await EncryptedProfileStorage.closeArchive(id);
    _deleteProfileUserData(id);
    _tryDelete(_keyslotPath(id));
    clearCachedKeys(id);

    await service.update(profile.copyWith(
      nsec: nsec,
      clearNsecEnvelope: true,
      avatar: '',
    ));
    LogService.instance.add('encryption: disabled for $id');
  }

  /// Unlock with the password. Hydrates the in-memory nsec and puts the
  /// keys in the keyring (which pre-opens the archive and lets gated
  /// services start). Throws [WrongProfilePassword] on a bad password.
  static Future<void> unlock(String id, String password,
      {bool remember = false}) async {
    final profile = _byId(id);
    if (profile == null) throw StateError('Unknown profile: $id');

    final keys = await _unlockKeys(profile, password);
    ProfileKeyring.instance.putKeys(id, keys);
    await _hydrateNsec(profile, keys.nsec);

    if (remember) {
      File(_cachePath(id))
          .writeAsStringSync(jsonEncode(keys.toCacheJson()), flush: true);
    } else {
      clearCachedKeys(id);
    }
    LogService.instance.add('encryption: unlocked $id');
  }

  /// Try the "keep unlocked on this device" cache. Returns true when the
  /// profile is now unlocked.
  static Future<bool> tryUnlockCached(String id) async {
    if (!isEncrypted(id)) return true;
    if (isUnlocked(id)) return true;
    try {
      final f = File(_cachePath(id));
      if (!f.existsSync()) return false;
      final json =
          jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final keys = UnlockedProfileKeys.fromCacheJson(json);
      ProfileKeyring.instance.putKeys(id, keys);
      final profile = _byId(id);
      if (profile != null) await _hydrateNsec(profile, keys.nsec);
      LogService.instance.add('encryption: unlocked $id from device cache');
      return true;
    } catch (e) {
      LogService.instance.add('encryption: cached unlock failed for $id: $e');
      return false;
    }
  }

  /// Change the password: re-wraps the master key + nsec envelope only;
  /// archive and databases stay untouched.
  static Future<void> changePassword(
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
    // Old cached keys still work (PMK unchanged) but re-write is cheap and
    // keeps the cache format current.
    if (File(_cachePath(id)).existsSync()) {
      File(_cachePath(id)).writeAsStringSync(
          jsonEncode(changed.keys.toCacheJson()),
          flush: true);
    }
    changed.keys.dispose();
    LogService.instance.add('encryption: password changed for $id');
  }

  /// Drop the keys + close the archive. The caller is responsible for
  /// exiting/restarting the app: long-lived services still hold open
  /// database handles that cannot be revoked in place.
  static Future<void> lockNow(String id) async {
    clearCachedKeys(id);
    ProfileKeyring.instance.lock(id);
    await EncryptedProfileStorage.closeArchive(id);
    LogService.instance.add('encryption: locked $id');
  }

  static void clearCachedKeys(String id) => _tryDelete(_cachePath(id));

  static bool hasCachedKeys(String id) => File(_cachePath(id)).existsSync();

  // ── internals ──────────────────────────────────────────────────────────

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
    await ProfileService.instance
        .update(profile.copyWith(nsec: nsec));
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
