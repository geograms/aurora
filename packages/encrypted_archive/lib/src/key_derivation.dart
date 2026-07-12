/// Cryptographic key derivation and encryption utilities.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/api.dart' as pc;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';

import 'exceptions.dart';
import 'options.dart';

/// Size of the salt in bytes.
const int saltSize = 32;

/// Size of encryption keys in bytes.
const int keySize = 32;

/// Size of AES-GCM nonce in bytes.
const int nonceSize = 12;

/// Size of AES-GCM authentication tag in bytes.
const int authTagSize = 16;

/// Size of verification hash in bytes.
const int verificationHashSize = 32;

/// Total size of master key material derived from password.
const int masterKeyMaterialSize = 128;

/// Key material derived from password.
class MasterKeyMaterial {
  /// Master key for file encryption.
  final Uint8List masterKey;

  /// Metadata key for encrypting metadata.
  final Uint8List metadataKey;

  /// Authentication key for message authentication.
  final Uint8List authKey;

  /// Verification hash for password checking.
  final Uint8List verificationHash;

  MasterKeyMaterial({
    required this.masterKey,
    required this.metadataKey,
    required this.authKey,
    required this.verificationHash,
  });

  /// Clear all keys from memory.
  void dispose() {
    masterKey.fillRange(0, masterKey.length, 0);
    metadataKey.fillRange(0, metadataKey.length, 0);
    authKey.fillRange(0, authKey.length, 0);
    verificationHash.fillRange(0, verificationHash.length, 0);
  }
}

/// Key derivation functions.
class KeyDerivation {
  final ArchiveOptions options;

  // Lazy-initialized algorithm instances
  Argon2id? _argon2;
  AesGcm? _aesGcm;

  KeyDerivation(this.options);

  Argon2id get _argon2Instance => _argon2 ??= Argon2id(
        memory: options.argon2MemoryCost,
        iterations: options.argon2TimeCost,
        parallelism: options.argon2Parallelism,
        hashLength: masterKeyMaterialSize,
      );

  AesGcm get _aesGcmInstance => _aesGcm ??= AesGcm.with256bits();

  /// Generate a random salt.
  static Uint8List generateSalt() {
    final random = SecureRandom.fast;
    final salt = Uint8List(saltSize);
    for (var i = 0; i < saltSize; i++) {
      salt[i] = random.nextInt(256);
    }
    return salt;
  }

  /// Generate a random nonce for file encryption.
  static Uint8List generateNonce() {
    final random = SecureRandom.fast;
    final nonce = Uint8List(nonceSize);
    for (var i = 0; i < nonceSize; i++) {
      nonce[i] = random.nextInt(256);
    }
    return nonce;
  }

  /// Derive master key material from password.
  Future<MasterKeyMaterial> deriveFromPassword(
    String password,
    Uint8List salt,
  ) async {
    try {
      // Derive master key material using Argon2id
      final secretKey = await _argon2Instance.deriveKey(
        secretKey: SecretKey(utf8.encode(password)),
        nonce: salt,
      );

      final material = await secretKey.extractBytes();
      final bytes = Uint8List.fromList(material);

      if (bytes.length < masterKeyMaterialSize) {
        throw const ArchiveCryptoException(
          'Derived key material too short',
        );
      }

      return MasterKeyMaterial(
        masterKey: Uint8List.fromList(bytes.sublist(0, keySize)),
        metadataKey: Uint8List.fromList(bytes.sublist(keySize, keySize * 2)),
        authKey: Uint8List.fromList(bytes.sublist(keySize * 2, keySize * 3)),
        verificationHash: Uint8List.fromList(
          bytes.sublist(keySize * 3, keySize * 3 + verificationHashSize),
        ),
      );
    } catch (e) {
      if (e is ArchiveException) rethrow;
      throw ArchiveCryptoException('Failed to derive key: $e', e);
    }
  }

  /// Derive a file-specific key from master key using HKDF.
  Future<SecretKey> deriveFileKey(
    Uint8List masterKey,
    int fileId,
  ) async {
    try {
      final info = utf8.encode('file:$fileId');
      // Use HKDF to derive a file-specific key
      final algorithm = Hkdf(
        hmac: Hmac.sha256(),
        outputLength: keySize,
      );
      final derivedKey = await algorithm.deriveKey(
        secretKey: SecretKey(masterKey),
        info: info,
        nonce: Uint8List(0), // HKDF doesn't need nonce when using info
      );
      return derivedKey;
    } catch (e) {
      throw ArchiveCryptoException('Failed to derive file key: $e', e);
    }
  }

  /// Derive a file-specific key from master key using HKDF (synchronous).
  ///
  /// Produces byte-identical output to [deriveFileKey] (RFC 5869 HKDF-SHA256
  /// with empty salt and info `file:<fileId>`), but runs synchronously so it
  /// can be called from sync host callbacks (e.g. WASM HAL file ops).
  Uint8List deriveFileKeySync(Uint8List masterKey, int fileId) {
    final info = utf8.encode('file:$fileId');
    return hkdfSha256(masterKey, Uint8List(0), Uint8List.fromList(info), keySize);
  }

  /// RFC 5869 HKDF-SHA256, synchronous.
  static Uint8List hkdfSha256(
    Uint8List ikm,
    Uint8List salt,
    Uint8List info,
    int length,
  ) {
    // Extract: PRK = HMAC-SHA256(salt, IKM). Empty salt -> HashLen zero bytes.
    final effectiveSalt = salt.isEmpty ? Uint8List(32) : salt;
    final prk = crypto.Hmac(crypto.sha256, effectiveSalt).convert(ikm).bytes;

    // Expand.
    final out = BytesBuilder(copy: false);
    var previous = <int>[];
    var counter = 1;
    while (out.length < length) {
      final hmac = crypto.Hmac(crypto.sha256, prk);
      final block = hmac.convert([...previous, ...info, counter]).bytes;
      out.add(block);
      previous = block;
      counter++;
    }
    return Uint8List.fromList(out.toBytes().sublist(0, length));
  }

  /// Encrypt data using AES-256-GCM, synchronous (pointycastle).
  ///
  /// Byte-compatible with [encrypt]: same key/nonce produce the same
  /// ciphertext and 16-byte auth tag.
  EncryptedData encryptSync(
    Uint8List plaintext,
    Uint8List keyBytes,
    Uint8List nonce,
  ) {
    try {
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          true,
          pc.AEADParameters(
            pc.KeyParameter(keyBytes),
            authTagSize * 8,
            nonce,
            Uint8List(0),
          ),
        );
      final output = cipher.process(plaintext); // ciphertext || tag
      return EncryptedData(
        ciphertext: Uint8List.sublistView(output, 0, output.length - authTagSize),
        authTag: Uint8List.sublistView(output, output.length - authTagSize),
      );
    } catch (e) {
      throw ArchiveCryptoException('Encryption failed: $e', e);
    }
  }

  /// Decrypt data using AES-256-GCM, synchronous (pointycastle).
  ///
  /// Throws [ArchiveCryptoException] on authentication failure.
  Uint8List decryptSync(
    Uint8List ciphertext,
    Uint8List authTag,
    Uint8List keyBytes,
    Uint8List nonce,
  ) {
    try {
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          pc.AEADParameters(
            pc.KeyParameter(keyBytes),
            authTagSize * 8,
            nonce,
            Uint8List(0),
          ),
        );
      final input = Uint8List(ciphertext.length + authTag.length)
        ..setRange(0, ciphertext.length, ciphertext)
        ..setRange(ciphertext.length, ciphertext.length + authTag.length, authTag);
      return cipher.process(input);
    } catch (e) {
      if (e is ArchiveException) rethrow;
      throw ArchiveCryptoException('Decryption failed: $e', e);
    }
  }

  /// Create chunk nonce from file nonce and sequence number.
  Uint8List createChunkNonce(Uint8List fileNonce, int sequence) {
    // First 8 bytes from file nonce, last 4 bytes from sequence
    final nonce = Uint8List(nonceSize);
    nonce.setRange(0, 8, fileNonce.sublist(0, 8));

    // Little-endian sequence number
    nonce[8] = sequence & 0xFF;
    nonce[9] = (sequence >> 8) & 0xFF;
    nonce[10] = (sequence >> 16) & 0xFF;
    nonce[11] = (sequence >> 24) & 0xFF;

    return nonce;
  }

  /// Encrypt data using AES-256-GCM.
  Future<EncryptedData> encrypt(
    Uint8List plaintext,
    SecretKey key,
    Uint8List nonce,
  ) async {
    try {
      final secretBox = await _aesGcmInstance.encrypt(
        plaintext,
        secretKey: key,
        nonce: nonce,
      );

      return EncryptedData(
        ciphertext: Uint8List.fromList(secretBox.cipherText),
        authTag: Uint8List.fromList(secretBox.mac.bytes),
      );
    } catch (e) {
      throw ArchiveCryptoException('Encryption failed: $e', e);
    }
  }

  /// Decrypt data using AES-256-GCM.
  Future<Uint8List> decrypt(
    Uint8List ciphertext,
    Uint8List authTag,
    SecretKey key,
    Uint8List nonce,
  ) async {
    try {
      final secretBox = SecretBox(
        ciphertext,
        nonce: nonce,
        mac: Mac(authTag),
      );

      final plaintext = await _aesGcmInstance.decrypt(
        secretBox,
        secretKey: key,
      );

      return Uint8List.fromList(plaintext);
    } catch (e) {
      throw ArchiveCryptoException('Decryption failed: $e', e);
    }
  }

  /// Encrypt the master key for storage (for password change support).
  Future<Uint8List> encryptMasterKey(
    Uint8List masterKey,
    Uint8List wrapKey,
  ) async {
    final nonce = generateNonce();
    final key = SecretKey(wrapKey);
    final encrypted = await encrypt(masterKey, key, nonce);

    // Prepend nonce to ciphertext + auth tag
    final result = Uint8List(nonceSize + encrypted.ciphertext.length + authTagSize);
    result.setRange(0, nonceSize, nonce);
    result.setRange(nonceSize, nonceSize + encrypted.ciphertext.length, encrypted.ciphertext);
    result.setRange(
      nonceSize + encrypted.ciphertext.length,
      result.length,
      encrypted.authTag,
    );

    return result;
  }

  /// Decrypt the master key.
  Future<Uint8List> decryptMasterKey(
    Uint8List encryptedMasterKey,
    Uint8List wrapKey,
  ) async {
    if (encryptedMasterKey.length < nonceSize + keySize + authTagSize) {
      throw const ArchiveCryptoException('Invalid encrypted master key');
    }

    final nonce = encryptedMasterKey.sublist(0, nonceSize);
    final ciphertext = encryptedMasterKey.sublist(
      nonceSize,
      encryptedMasterKey.length - authTagSize,
    );
    final authTag = encryptedMasterKey.sublist(
      encryptedMasterKey.length - authTagSize,
    );

    final key = SecretKey(wrapKey);
    return decrypt(Uint8List.fromList(ciphertext), Uint8List.fromList(authTag), key, Uint8List.fromList(nonce));
  }

  /// Compute SHA-256 hash of data.
  static Uint8List sha256(Uint8List data) {
    return Uint8List.fromList(crypto.sha256.convert(data).bytes);
  }

  /// Constant-time comparison of two byte arrays.
  static bool constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;

    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }
}

/// Result of encryption operation.
class EncryptedData {
  final Uint8List ciphertext;
  final Uint8List authTag;

  const EncryptedData({
    required this.ciphertext,
    required this.authTag,
  });

  /// Total size of encrypted data.
  int get totalSize => ciphertext.length + authTag.length;
}
