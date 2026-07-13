/*
 * Per-file encryption for profile secrets that must live directly on the
 * filesystem (bound by absolute path from RnsService and friends, so they
 * can't move into the profile.ear archive): rns_identity.key, folders.json.
 *
 * Format: 'AEF1' magic || 12-byte nonce || ciphertext || 16-byte GCM tag.
 * Key = HKDF(PMK, "aurora-file-v1:<profile-relative path>").
 *
 * For plain profiles (no keyslot) reads/writes pass straight through, and
 * a read of a plain (pre-encryption) file inside an encrypted profile
 * still returns its bytes — the next write encrypts it.
 */

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_archive/encrypted_archive.dart'
    show ArchiveCryptoException, KeyDerivation;

import 'profile_crypto.dart';
import 'profile_db.dart';

/// Reads/writes profile files with transparent at-rest encryption for
/// encrypted profiles. All methods are synchronous (call sites are sync).
class SecureProfileFile {
  SecureProfileFile._();

  static final Uint8List _magic = Uint8List.fromList('AEF1'.codeUnits);
  static const int _nonceLen = 12;
  static const int _tagLen = 16;

  static UnlockedProfileKeys? _keysFor(String absPath) {
    final loc = locateProfileDb(absPath);
    if (loc == null) return null;
    if (!ProfileKeyring.instance.isEncryptedProfile(loc.profileId)) return null;
    final keys = ProfileKeyring.instance.keysFor(loc.profileId);
    if (keys == null) {
      throw ProfileLockedException(loc.profileId, absPath);
    }
    return keys;
  }

  static bool _isWrapped(Uint8List bytes) =>
      bytes.length >= _magic.length + _nonceLen + _tagLen &&
      bytes[0] == _magic[0] &&
      bytes[1] == _magic[1] &&
      bytes[2] == _magic[2] &&
      bytes[3] == _magic[3];

  /// Read [absPath], decrypting when it belongs to an unlocked encrypted
  /// profile. Returns null when the file does not exist. Throws
  /// [ProfileLockedException] / [ArchiveCryptoException] on locked profile
  /// or tampered content.
  static Uint8List? readBytes(String absPath) {
    final f = File(absPath);
    if (!f.existsSync()) return null;
    final raw = f.readAsBytesSync();

    if (!_isWrapped(raw)) return raw; // plain file (plain profile or pre-encryption)

    final keys = _keysFor(absPath);
    if (keys == null) {
      // Wrapped file but no encryption context — cannot decrypt.
      throw const ArchiveCryptoException(
          'Encrypted file found outside an unlocked encrypted profile');
    }
    final loc = locateProfileDb(absPath)!;
    final nonce = Uint8List.sublistView(
        raw, _magic.length, _magic.length + _nonceLen);
    final ct = Uint8List.sublistView(
        raw, _magic.length + _nonceLen, raw.length - _tagLen);
    final tag = Uint8List.sublistView(raw, raw.length - _tagLen);
    return KeyDerivation.decryptSync(ct, tag, keys.fileKey(loc.relPath), nonce);
  }

  /// Write [bytes] to [absPath], encrypting when it belongs to an unlocked
  /// encrypted profile.
  static void writeBytes(String absPath, Uint8List bytes) {
    final parent = File(absPath).parent;
    if (!parent.existsSync()) parent.createSync(recursive: true);

    final keys = _keysFor(absPath);
    if (keys == null) {
      File(absPath).writeAsBytesSync(bytes);
      return;
    }
    final loc = locateProfileDb(absPath)!;
    final nonce = ProfileCrypto.randomBytes(_nonceLen);
    final enc =
        KeyDerivation.encryptSync(bytes, keys.fileKey(loc.relPath), nonce);
    final out = BytesBuilder(copy: false)
      ..add(_magic)
      ..add(nonce)
      ..add(enc.ciphertext)
      ..add(enc.authTag);
    File(absPath).writeAsBytesSync(out.toBytes());
  }

  static String? readString(String absPath) {
    final bytes = readBytes(absPath);
    return bytes == null ? null : utf8.decode(bytes);
  }

  static void writeString(String absPath, String content) =>
      writeBytes(absPath, Uint8List.fromList(utf8.encode(content)));
}
