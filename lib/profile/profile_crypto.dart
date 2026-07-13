/*
 * Profile encryption key hierarchy.
 *
 * Implements the scheme from docs/plan-encrypted-storage.md:
 *
 *   password  = NFC-normalized user string (emoji allowed), utf8-encoded
 *   salt      = random 16 B, stored plaintext in keyslot + nsec envelope
 *   KEK_pw    = Argon2id(password, salt, t=3, m=64 MiB, p=1) -> 32 B
 *   nsec_ct   = AES-256-GCM(KEK_pw, nsec)          -> profiles.json entry
 *   KEK       = HKDF-SHA256(KEK_pw || nsecBytes, salt, "aurora-profile-kek-v1")
 *   PMK       = random 32 B profile master key (generated once at enable)
 *   pmk_ct    = AES-256-GCM(KEK, PMK)              -> devices/<id>/keyslot.json
 *   earPass   = hex(HKDF(PMK, "aurora-ear-v1"))    -> password for profile.ear
 *   dbKey(p)  = HKDF(PMK, "aurora-db-v1:" + relPath) -> SQLCipher raw key
 *
 * The password alone decrypts the nsec envelope (stage 1); the profile data
 * keys additionally mix in the nsec (stage 2), so a profile folder copied off
 * the device cannot be opened without BOTH the password and the nsec.
 *
 * Wrong password is detected by GCM auth failure on the nsec envelope —
 * constant-time, no oracle. Password change re-wraps PMK + nsec only.
 *
 * Argon2id runs only at unlock/enable time (async); everything derived from
 * PMK uses the sync HKDF from encrypted_archive so it can serve sync callers.
 */

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:encrypted_archive/encrypted_archive.dart' show KeyDerivation;
import 'package:hex/hex.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../util/nostr_crypto.dart';

/// Thrown when a password fails to open a profile's encryption envelope.
class WrongProfilePassword implements Exception {
  final String message;
  const WrongProfilePassword([this.message = 'Wrong password']);
  @override
  String toString() => 'WrongProfilePassword: $message';
}

/// Thrown when keyslot/envelope data is malformed.
class ProfileKeyslotCorrupt implements Exception {
  final String message;
  const ProfileKeyslotCorrupt(this.message);
  @override
  String toString() => 'ProfileKeyslotCorrupt: $message';
}

/// A small AES-256-GCM box: iv || ct || mac, base64 fields in JSON.
class GcmBox {
  final Uint8List iv;
  final Uint8List ct;
  final Uint8List mac;

  const GcmBox({required this.iv, required this.ct, required this.mac});

  Map<String, dynamic> toJson() => {
        'iv': base64Encode(iv),
        'ct': base64Encode(ct),
        'mac': base64Encode(mac),
      };

  static GcmBox fromJson(Map<String, dynamic> json) {
    try {
      return GcmBox(
        iv: base64Decode(json['iv'] as String),
        ct: base64Decode(json['ct'] as String),
        mac: base64Decode(json['mac'] as String),
      );
    } catch (e) {
      throw ProfileKeyslotCorrupt('Bad GCM box: $e');
    }
  }
}

/// `devices/<id>/keyslot.json` — presence of this file marks the profile as
/// encrypted. Contains only public parameters + the wrapped master key.
class ProfileKeyslot {
  static const int currentVersion = 1;

  final int version;
  final Uint8List salt;
  final GcmBox pmkCt;
  final int createdAt; // Unix ms

  const ProfileKeyslot({
    required this.version,
    required this.salt,
    required this.pmkCt,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'kdf': {
          'algo': 'argon2id',
          'time_cost': ProfileCrypto.argon2TimeCost,
          'memory_kib': ProfileCrypto.argon2MemoryKib,
          'parallelism': ProfileCrypto.argon2Parallelism,
          'salt': base64Encode(salt),
        },
        'pmk': pmkCt.toJson(),
        'created_at': createdAt,
      };

  static ProfileKeyslot fromJson(Map<String, dynamic> json) {
    try {
      final kdf = (json['kdf'] as Map).cast<String, dynamic>();
      return ProfileKeyslot(
        version: (json['version'] as num).toInt(),
        salt: base64Decode(kdf['salt'] as String),
        pmkCt: GcmBox.fromJson((json['pmk'] as Map).cast<String, dynamic>()),
        createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
      );
    } catch (e) {
      if (e is ProfileKeyslotCorrupt) rethrow;
      throw ProfileKeyslotCorrupt('Bad keyslot: $e');
    }
  }
}

/// The nsec-at-rest envelope stored in the profile's `profiles.json` entry.
/// Carries its own salt copy so it is decryptable without the keyslot file.
class NsecEnvelope {
  final Uint8List salt;
  final GcmBox box;

  const NsecEnvelope({required this.salt, required this.box});

  Map<String, dynamic> toJson() => {
        'encrypted': true,
        'kdf': {
          'algo': 'argon2id',
          'time_cost': ProfileCrypto.argon2TimeCost,
          'memory_kib': ProfileCrypto.argon2MemoryKib,
          'parallelism': ProfileCrypto.argon2Parallelism,
          'salt': base64Encode(salt),
        },
        ...box.toJson(),
      };

  static NsecEnvelope fromJson(Map<String, dynamic> json) {
    try {
      final kdf = (json['kdf'] as Map).cast<String, dynamic>();
      return NsecEnvelope(
        salt: base64Decode(kdf['salt'] as String),
        box: GcmBox.fromJson(json),
      );
    } catch (e) {
      if (e is ProfileKeyslotCorrupt) rethrow;
      throw ProfileKeyslotCorrupt('Bad nsec envelope: $e');
    }
  }
}

/// Everything produced by enabling encryption on a profile.
class ProfileSecrets {
  final ProfileKeyslot keyslot;
  final NsecEnvelope nsecEnvelope;
  final UnlockedProfileKeys keys;

  const ProfileSecrets({
    required this.keyslot,
    required this.nsecEnvelope,
    required this.keys,
  });
}

/// In-memory keys of an unlocked profile. Everything data-facing derives
/// from [pmk] via sync HKDF, so holders can serve sync callbacks.
class UnlockedProfileKeys {
  final Uint8List _pmk;
  final String nsec;
  bool _disposed = false;

  UnlockedProfileKeys({required Uint8List pmk, required this.nsec})
      : _pmk = pmk;

  void _ensureLive() {
    if (_disposed) {
      throw StateError('UnlockedProfileKeys used after dispose');
    }
  }

  /// Password for the profile's `.ear` archive.
  String get earPassword {
    _ensureLive();
    return HEX.encode(KeyDerivation.hkdfSha256(
      _pmk,
      Uint8List(0),
      Uint8List.fromList(utf8.encode('aurora-ear-v1')),
      32,
    ));
  }

  /// Raw 32-byte SQLCipher key for the database at profile-relative [relPath]
  /// (forward-slash separated, e.g. `data/mesh.sqlite3`).
  Uint8List dbKey(String relPath) {
    _ensureLive();
    return KeyDerivation.hkdfSha256(
      _pmk,
      Uint8List(0),
      Uint8List.fromList(utf8.encode('aurora-db-v1:$relPath')),
      32,
    );
  }

  /// SQLCipher `PRAGMA key = "x'<hex>'"` value for [relPath].
  String dbKeyHex(String relPath) => HEX.encode(dbKey(relPath));

  /// Raw 32-byte AES-GCM key for an individually-encrypted loose file at
  /// profile-relative [relPath] (used for secrets like rns_identity.key
  /// that must stay directly on the filesystem — see SecureProfileFile).
  Uint8List fileKey(String relPath) {
    _ensureLive();
    return KeyDerivation.hkdfSha256(
      _pmk,
      Uint8List(0),
      Uint8List.fromList(utf8.encode('aurora-file-v1:$relPath')),
      32,
    );
  }

  /// Serialize for the app-private "keep unlocked on this device" cache.
  Map<String, dynamic> toCacheJson() {
    _ensureLive();
    return {'pmk': base64Encode(_pmk), 'nsec': nsec};
  }

  static UnlockedProfileKeys fromCacheJson(Map<String, dynamic> json) {
    return UnlockedProfileKeys(
      pmk: base64Decode(json['pmk'] as String),
      nsec: json['nsec'] as String,
    );
  }

  /// Zero the master key. Derived keys already handed out are unaffected.
  void dispose() {
    _pmk.fillRange(0, _pmk.length, 0);
    _disposed = true;
  }
}

/// Key hierarchy operations. Stateless; all methods static.
class ProfileCrypto {
  ProfileCrypto._();

  // Argon2id parameters (mirrors encrypted_archive defaults).
  static const int argon2TimeCost = 3;
  static const int argon2MemoryKib = 65536; // 64 MiB
  static const int argon2Parallelism = 1;

  static const int saltLength = 16;
  static const String _kekInfo = 'aurora-profile-kek-v1';

  /// NFC-normalize a user password so the same emoji sequence typed on
  /// different keyboards/platforms derives the same key. No trimming —
  /// whitespace is part of the password.
  static String normalizePassword(String raw) => unorm.nfc(raw);

  /// Stage 1: derive the password-only key.
  static Future<Uint8List> deriveKekPw(String password, Uint8List salt) async {
    final argon2 = Argon2id(
      memory: argon2MemoryKib,
      iterations: argon2TimeCost,
      parallelism: argon2Parallelism,
      hashLength: 32,
    );
    final key = await argon2.deriveKey(
      secretKey: SecretKey(utf8.encode(normalizePassword(password))),
      nonce: salt,
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  /// Stage 2: mix the password key with the nsec.
  static Uint8List deriveKek(Uint8List kekPw, String nsec, Uint8List salt) {
    final nsecBytes = _nsecBytes(nsec);
    final ikm = Uint8List(kekPw.length + nsecBytes.length)
      ..setRange(0, kekPw.length, kekPw)
      ..setRange(kekPw.length, kekPw.length + nsecBytes.length, nsecBytes);
    final kek = KeyDerivation.hkdfSha256(
      ikm,
      salt,
      Uint8List.fromList(utf8.encode(_kekInfo)),
      32,
    );
    ikm.fillRange(0, ikm.length, 0);
    nsecBytes.fillRange(0, nsecBytes.length, 0);
    return kek;
  }

  /// Enable encryption: generate salt + PMK, wrap everything.
  static Future<ProfileSecrets> createProfileSecrets(
    String password,
    String nsec,
  ) async {
    final salt = randomBytes(saltLength);
    final kekPw = await deriveKekPw(password, salt);

    final nsecEnvelope = NsecEnvelope(
      salt: salt,
      box: await _gcmEncrypt(Uint8List.fromList(utf8.encode(nsec)), kekPw),
    );

    final pmk = randomBytes(32);
    final kek = deriveKek(kekPw, nsec, salt);
    final keyslot = ProfileKeyslot(
      version: ProfileKeyslot.currentVersion,
      salt: salt,
      pmkCt: await _gcmEncrypt(pmk, kek),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    kekPw.fillRange(0, kekPw.length, 0);
    kek.fillRange(0, kek.length, 0);

    return ProfileSecrets(
      keyslot: keyslot,
      nsecEnvelope: nsecEnvelope,
      keys: UnlockedProfileKeys(pmk: pmk, nsec: nsec),
    );
  }

  /// Unlock: password -> nsec -> PMK.
  ///
  /// Throws [WrongProfilePassword] on a bad password.
  static Future<UnlockedProfileKeys> unlock(
    String password,
    NsecEnvelope nsecEnvelope,
    ProfileKeyslot keyslot,
  ) async {
    var kekPw = await deriveKekPw(password, nsecEnvelope.salt);

    final String nsec;
    try {
      nsec = utf8.decode(await _gcmDecrypt(nsecEnvelope.box, kekPw));
    } on SecretBoxAuthenticationError {
      kekPw.fillRange(0, kekPw.length, 0);
      throw const WrongProfilePassword();
    }

    // Envelope and keyslot normally share one salt (single Argon2id run);
    // tolerate divergence defensively.
    if (!_bytesEqual(nsecEnvelope.salt, keyslot.salt)) {
      kekPw.fillRange(0, kekPw.length, 0);
      kekPw = await deriveKekPw(password, keyslot.salt);
    }

    final kek = deriveKek(kekPw, nsec, keyslot.salt);
    kekPw.fillRange(0, kekPw.length, 0);

    final Uint8List pmk;
    try {
      pmk = await _gcmDecrypt(keyslot.pmkCt, kek);
    } on SecretBoxAuthenticationError {
      throw const ProfileKeyslotCorrupt(
        'nsec envelope opened but keyslot did not — keyslot/profile mismatch',
      );
    } finally {
      kek.fillRange(0, kek.length, 0);
    }

    return UnlockedProfileKeys(pmk: pmk, nsec: nsec);
  }

  /// Change password: verify old, re-wrap PMK + nsec under the new one.
  /// Data keys (PMK) are unchanged, so archives/DBs are untouched.
  static Future<ProfileSecrets> changePassword(
    String oldPassword,
    String newPassword,
    NsecEnvelope nsecEnvelope,
    ProfileKeyslot keyslot,
  ) async {
    final keys = await unlock(oldPassword, nsecEnvelope, keyslot);

    final salt = randomBytes(saltLength);
    final kekPw = await deriveKekPw(newPassword, salt);
    final newEnvelope = NsecEnvelope(
      salt: salt,
      box: await _gcmEncrypt(
        Uint8List.fromList(utf8.encode(keys.nsec)),
        kekPw,
      ),
    );

    final kek = deriveKek(kekPw, keys.nsec, salt);
    final newKeyslot = ProfileKeyslot(
      version: ProfileKeyslot.currentVersion,
      salt: salt,
      pmkCt: await _gcmEncrypt(keys._pmk, kek),
      createdAt: keyslot.createdAt,
    );

    kekPw.fillRange(0, kekPw.length, 0);
    kek.fillRange(0, kek.length, 0);

    return ProfileSecrets(
      keyslot: newKeyslot,
      nsecEnvelope: newEnvelope,
      keys: keys,
    );
  }

  // ── helpers ────────────────────────────────────────────────────────────

  static Uint8List _nsecBytes(String nsec) {
    try {
      return Uint8List.fromList(
        HEX.decode(NostrCrypto.decodeNsec(nsec.trim())),
      );
    } catch (_) {
      // Not a bech32 nsec (e.g. raw hex or test value): use utf8 bytes so
      // the mix-in still binds to the exact secret string.
      return Uint8List.fromList(utf8.encode(nsec));
    }
  }

  static Future<GcmBox> _gcmEncrypt(Uint8List plaintext, Uint8List key) async {
    final algo = AesGcm.with256bits();
    final nonce = algo.newNonce();
    final box = await algo.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
    );
    return GcmBox(
      iv: Uint8List.fromList(nonce),
      ct: Uint8List.fromList(box.cipherText),
      mac: Uint8List.fromList(box.mac.bytes),
    );
  }

  static Future<Uint8List> _gcmDecrypt(GcmBox box, Uint8List key) async {
    final algo = AesGcm.with256bits();
    final clear = await algo.decrypt(
      SecretBox(box.ct, nonce: box.iv, mac: Mac(box.mac)),
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(clear);
  }

  static Uint8List randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
