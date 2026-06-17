/*
 * Pure-Dart cryptographic primitives for the Aurora Reticulum (RNS) node.
 *
 * Wire-compatible with the canonical Python reference (markqvist/Reticulum,
 * pinned to RNS 1.3.5). Every primitive here mirrors a specific reference file:
 *   - SHA-256 / truncated hashes      -> RNS/Identity.py full_hash/truncated_hash
 *   - HKDF (RFC-5869, HMAC-SHA256)    -> RNS/Cryptography/HKDF.py
 *   - AES-256-CBC + PKCS7            -> RNS/Cryptography/AES.py + PKCS7.py
 *   - Token (Fernet-like)            -> RNS/Cryptography/Token.py
 *   - X25519 ECDH / Ed25519 sign     -> RNS/Identity.py (Curve25519 keyset)
 *
 * All pure Dart, no native binaries: X25519/Ed25519 from `cryptography`,
 * SHA-256/HMAC from `crypto`, AES from `pointycastle`.
 */
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart' as c;
import 'package:pointycastle/export.dart' as pc;

/// RNS truncated-hash length: 128 bits = 16 bytes (destination / identity hash).
const int kRnsTruncatedHashBytes = 16;

class RnsCrypto {
  static final _x25519 = c.X25519();
  static final _ed25519 = c.Ed25519();

  // ---- hashing (RNS/Identity.py) ----

  /// SHA-256 of [data] (RNS `full_hash`).
  static Uint8List fullHash(List<int> data) =>
      Uint8List.fromList(crypto.sha256.convert(data).bytes);

  /// First 16 bytes of SHA-256 (RNS `truncated_hash`).
  static Uint8List truncatedHash(List<int> data) =>
      Uint8List.sublistView(fullHash(data), 0, kRnsTruncatedHashBytes);

  static Uint8List hmacSha256(List<int> key, List<int> data) =>
      Uint8List.fromList(crypto.Hmac(crypto.sha256, key).convert(data).bytes);

  /// HKDF exactly as RNS/Cryptography/HKDF.py (RFC-5869, HMAC-SHA256).
  /// PRK = HMAC(salt, ikm); T(i) = HMAC(PRK, T(i-1) || context || byte(i)),
  /// with i counting from 1 and wrapping at 256. salt defaults to 32 zero bytes,
  /// context defaults to empty.
  static Uint8List hkdf(int length, List<int> deriveFrom,
      {List<int>? salt, List<int>? context}) {
    if (length < 1) throw ArgumentError('Invalid output key length');
    if (deriveFrom.isEmpty) {
      throw ArgumentError('Cannot derive key from empty input material');
    }
    final saltBytes =
        (salt == null || salt.isEmpty) ? Uint8List(32) : salt;
    final ctx = context ?? const <int>[];
    final prk = hmacSha256(saltBytes, deriveFrom);
    final out = BytesBuilder();
    var block = <int>[];
    final blocks = (length + 31) ~/ 32;
    for (var i = 0; i < blocks; i++) {
      block = hmacSha256(prk, [...block, ...ctx, (i + 1) % 256]);
      out.add(block);
    }
    return Uint8List.sublistView(out.toBytes(), 0, length);
  }

  /// Constant-time byte comparison.
  static bool constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  // ---- AES-256-CBC + PKCS7 (RNS/Cryptography/AES.py + PKCS7.py) ----

  static Uint8List _aes256CbcRaw(
      Uint8List key, Uint8List iv, Uint8List data, bool encrypt) {
    if (key.length != 32) throw ArgumentError('AES-256 key must be 32 bytes');
    final cipher = pc.CBCBlockCipher(pc.AESEngine())
      ..init(encrypt, pc.ParametersWithIV(pc.KeyParameter(key), iv));
    final out = Uint8List(data.length);
    var off = 0;
    while (off < data.length) {
      off += cipher.processBlock(data, off, out, off);
    }
    return out;
  }

  static Uint8List pkcs7Pad(Uint8List data, [int bs = 16]) {
    final n = bs - (data.length % bs);
    final out = Uint8List(data.length + n)..setRange(0, data.length, data);
    for (var i = data.length; i < out.length; i++) {
      out[i] = n;
    }
    return out;
  }

  static Uint8List pkcs7Unpad(Uint8List data, [int bs = 16]) {
    if (data.isEmpty) throw ArgumentError('Cannot unpad empty data');
    final n = data[data.length - 1];
    if (n == 0 || n > bs || n > data.length) {
      throw ArgumentError('Invalid PKCS7 padding length $n');
    }
    return Uint8List.sublistView(data, 0, data.length - n);
  }

  // ---- X25519 (RNS Curve25519 ECDH) ----

  static Future<({Uint8List priv, Uint8List pub})> x25519Generate(
      [Uint8List? seed]) async {
    final kp = seed != null
        ? await _x25519.newKeyPairFromSeed(seed)
        : await _x25519.newKeyPair();
    final priv = Uint8List.fromList(await kp.extractPrivateKeyBytes());
    final pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
    return (priv: priv, pub: pub);
  }

  static Future<Uint8List> x25519PublicFromPrivate(Uint8List priv) async {
    final kp = await _x25519.newKeyPairFromSeed(priv);
    return Uint8List.fromList((await kp.extractPublicKey()).bytes);
  }

  static Future<Uint8List> x25519Shared(
      Uint8List ourPriv, Uint8List theirPub) async {
    final kp = await _x25519.newKeyPairFromSeed(ourPriv);
    final shared = await _x25519.sharedSecretKey(
      keyPair: kp,
      remotePublicKey: c.SimplePublicKey(theirPub, type: c.KeyPairType.x25519),
    );
    return Uint8List.fromList(await shared.extractBytes());
  }

  // ---- Ed25519 (RNS signature keyset) ----

  static Future<({Uint8List priv, Uint8List pub})> ed25519Generate(
      [Uint8List? seed]) async {
    final kp = seed != null
        ? await _ed25519.newKeyPairFromSeed(seed)
        : await _ed25519.newKeyPair();
    final priv = Uint8List.fromList(await kp.extractPrivateKeyBytes());
    final pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
    return (priv: priv, pub: pub);
  }

  static Future<Uint8List> ed25519PublicFromSeed(Uint8List seed) async {
    final kp = await _ed25519.newKeyPairFromSeed(seed);
    return Uint8List.fromList((await kp.extractPublicKey()).bytes);
  }

  static Future<Uint8List> ed25519Sign(
      Uint8List seed, List<int> message) async {
    final kp = await _ed25519.newKeyPairFromSeed(seed);
    final sig = await _ed25519.sign(message, keyPair: kp);
    return Uint8List.fromList(sig.bytes);
  }

  static Future<bool> ed25519Verify(
      Uint8List pub, List<int> message, Uint8List sig) async {
    return _ed25519.verify(message,
        signature: c.Signature(sig,
            publicKey: c.SimplePublicKey(pub, type: c.KeyPairType.ed25519)));
  }
}

/// Slightly-modified Fernet token used by RNS (RNS/Cryptography/Token.py).
/// AES-256-CBC + HMAC-SHA256, no version/timestamp fields. The 64-byte key is
/// split into a 32-byte signing key and a 32-byte encryption key.
class RnsToken {
  final Uint8List _signingKey;
  final Uint8List _encryptionKey;

  RnsToken(Uint8List key)
      : assert(key.length == 64, 'RNS token key must be 64 bytes'),
        _signingKey = Uint8List.sublistView(key, 0, 32),
        _encryptionKey = Uint8List.sublistView(key, 32, 64);

  /// token = iv(16) + AES256CBC(PKCS7(plaintext)) + HMAC_SHA256(signing, iv+ct).
  /// [iv] is for deterministic testing only; production passes null (random).
  Uint8List encrypt(Uint8List plaintext, {Uint8List? iv}) {
    final theIv = iv ?? _randomBytes(16);
    if (theIv.length != 16) throw ArgumentError('IV must be 16 bytes');
    final ct = RnsCrypto._aes256CbcRaw(
        _encryptionKey, theIv, RnsCrypto.pkcs7Pad(plaintext), true);
    final signed = Uint8List(16 + ct.length)
      ..setRange(0, 16, theIv)
      ..setRange(16, 16 + ct.length, ct);
    final mac = RnsCrypto.hmacSha256(_signingKey, signed);
    return Uint8List(signed.length + 32)
      ..setRange(0, signed.length, signed)
      ..setRange(signed.length, signed.length + 32, mac);
  }

  bool verifyHmac(Uint8List token) {
    if (token.length <= 32) return false;
    final received = Uint8List.sublistView(token, token.length - 32);
    final expected = RnsCrypto.hmacSha256(
        _signingKey, Uint8List.sublistView(token, 0, token.length - 32));
    return RnsCrypto.constantTimeEquals(received, expected);
  }

  Uint8List decrypt(Uint8List token) {
    if (!verifyHmac(token)) throw ArgumentError('Token HMAC was invalid');
    final iv = Uint8List.sublistView(token, 0, 16);
    final ct = Uint8List.sublistView(token, 16, token.length - 32);
    return RnsCrypto.pkcs7Unpad(
        RnsCrypto._aes256CbcRaw(_encryptionKey, iv, ct, false));
  }
}

final math.Random _secureRng = math.Random.secure();

Uint8List _randomBytes(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = _secureRng.nextInt(256);
  }
  return out;
}
