/*
 * Pure-Dart cryptographic primitives for the Aurora I2P node (Phase 0).
 *
 * I2P (modern, NTCP2 + ECIES-X25519) needs: X25519 ECDH, Ed25519 signatures,
 * ChaCha20-Poly1305 AEAD, HKDF-SHA256, SHA-256, SipHash-2-4 (NTCP2 frame-length
 * obfuscation) and AES-256-CBC (NTCP2 ephemeral-key obfuscation). All pure Dart,
 * no native binaries: X25519/Ed25519/ChaCha20-Poly1305 from the `cryptography`
 * package, SHA-256/HMAC from `crypto`, AES from `pointycastle`, SipHash here.
 */
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart' as c;
import 'package:pointycastle/export.dart' as pc;

class I2pCrypto {
  static final _x25519 = c.X25519();
  static final _ed25519 = c.Ed25519();
  static final _chacha = c.Chacha20.poly1305Aead();

  // ---- hashing ----
  static Uint8List sha256(List<int> data) =>
      Uint8List.fromList(crypto.sha256.convert(data).bytes);

  static Uint8List hmacSha256(List<int> key, List<int> data) =>
      Uint8List.fromList(crypto.Hmac(crypto.sha256, key).convert(data).bytes);

  /// Noise HKDF: returns [numOutputs] 32-byte outputs from a chaining key and
  /// input key material (RFC 5869 / Noise spec).
  static List<Uint8List> noiseHkdf(
      List<int> chainingKey, List<int> ikm, int numOutputs) {
    final tempKey = hmacSha256(chainingKey, ikm);
    final out = <Uint8List>[];
    var prev = <int>[];
    for (var i = 1; i <= numOutputs; i++) {
      prev = hmacSha256(tempKey, [...prev, i]);
      out.add(Uint8List.fromList(prev));
    }
    return out;
  }

  /// General HKDF (RFC 5869) used by I2P's ECIES code, with an info string and
  /// [numOutputs] 32-byte outputs. PRK = HMAC(salt, ikm); each output T(i) =
  /// HMAC(PRK, T(i-1) || info || byte(i)). i2p calls this as HKDF(salt, ikm,
  /// info, 64) -> [ck', k]. With empty ikm this is the "expand only" form.
  static List<Uint8List> hkdf(
      List<int> salt, List<int> ikm, String info, int numOutputs) {
    final prk = hmacSha256(salt, ikm);
    final infoBytes = info.codeUnits;
    final out = <Uint8List>[];
    var prev = <int>[];
    for (var i = 1; i <= numOutputs; i++) {
      prev = hmacSha256(prk, [...prev, ...infoBytes, i]);
      out.add(Uint8List.fromList(prev));
    }
    return out;
  }

  // ---- X25519 ----
  static Future<({Uint8List priv, Uint8List pub})> x25519Generate(
      [Uint8List? seed]) async {
    final kp = seed != null
        ? await _x25519.newKeyPairFromSeed(seed)
        : await _x25519.newKeyPair();
    final priv = Uint8List.fromList(await kp.extractPrivateKeyBytes());
    final pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
    return (priv: priv, pub: pub);
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

  // ---- Ed25519 ----
  static Future<({Uint8List priv, Uint8List pub})> ed25519Generate(
      [Uint8List? seed]) async {
    final kp = seed != null
        ? await _ed25519.newKeyPairFromSeed(seed)
        : await _ed25519.newKeyPair();
    final priv = Uint8List.fromList(await kp.extractPrivateKeyBytes());
    final pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
    return (priv: priv, pub: pub);
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

  // ---- ChaCha20-Poly1305 (IETF, 12-byte nonce, 16-byte tag) ----
  /// Returns ciphertext || 16-byte tag.
  static Future<Uint8List> chachaEncrypt(Uint8List key, Uint8List nonce12,
      List<int> plaintext, List<int> aad) async {
    final box = await _chacha.encrypt(plaintext,
        secretKey: c.SecretKey(key), nonce: nonce12, aad: aad);
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  /// Input is ciphertext || 16-byte tag. Throws on auth failure.
  static Future<Uint8List> chachaDecrypt(Uint8List key, Uint8List nonce12,
      List<int> cipherAndTag, List<int> aad) async {
    final ct = cipherAndTag.sublist(0, cipherAndTag.length - 16);
    final tag = cipherAndTag.sublist(cipherAndTag.length - 16);
    final clear = await _chacha.decrypt(
      c.SecretBox(ct, nonce: nonce12, mac: c.Mac(tag)),
      secretKey: c.SecretKey(key),
      aad: aad,
    );
    return Uint8List.fromList(clear);
  }

  // ---- AES-256-CBC (no padding; NTCP2 uses it on whole 16-byte blocks) ----
  static Uint8List aesCbc(
      Uint8List key, Uint8List iv, Uint8List data, bool encrypt) {
    final cipher = pc.CBCBlockCipher(pc.AESEngine())
      ..init(encrypt, pc.ParametersWithIV(pc.KeyParameter(key), iv));
    final out = Uint8List(data.length);
    var off = 0;
    while (off < data.length) {
      off += cipher.processBlock(data, off, out, off);
    }
    return out;
  }

  // ---- raw ChaCha20 (IETF, 96-bit nonce, 32-bit counter from 0) ----
  // Used to undo the per-record stream transform in multi-hop tunnel build
  // replies. XOR keystream, so it is its own inverse. pointycastle ChaCha7539
  // is RFC 8439 with the counter starting at 0 (matches i2pd's ChaCha20).
  static Uint8List chacha20Raw(Uint8List key, Uint8List nonce12, Uint8List data) {
    final c = pc.ChaCha7539Engine()
      ..init(true, pc.ParametersWithIV(pc.KeyParameter(key), nonce12));
    final out = Uint8List(data.length);
    c.processBytes(data, 0, data.length, out, 0);
    return out;
  }

  // ---- AES-256-ECB (per 16-byte block; tunnel IV encryption) ----
  static Uint8List aesEcb(Uint8List key, Uint8List data, bool encrypt) {
    final c = pc.AESEngine()..init(encrypt, pc.KeyParameter(key));
    final out = Uint8List(data.length);
    for (var o = 0; o < data.length; o += 16) {
      c.processBlock(data, o, out, o);
    }
    return out;
  }

  // ---- SipHash-2-4 (64-bit) — NTCP2 frame length obfuscation ----
  // Dart VM int is 64-bit two's-complement and wraps on overflow, which is what
  // SipHash needs. (VM only; the network layer is never run on web.)
  static int _rotl(int x, int b) => (x << b) | (x >>> (64 - b));

  static int sipHash24(Uint8List key16, List<int> data) {
    final k0 = _readU64LE(key16, 0);
    final k1 = _readU64LE(key16, 8);
    var v0 = 0x736f6d6570736575 ^ k0;
    var v1 = 0x646f72616e646f6d ^ k1;
    var v2 = 0x6c7967656e657261 ^ k0;
    var v3 = 0x7465646279746573 ^ k1;

    void round() {
      v0 += v1; v1 = _rotl(v1, 13); v1 ^= v0; v0 = _rotl(v0, 32);
      v2 += v3; v3 = _rotl(v3, 16); v3 ^= v2;
      v0 += v3; v3 = _rotl(v3, 21); v3 ^= v0;
      v2 += v1; v1 = _rotl(v1, 17); v1 ^= v2; v2 = _rotl(v2, 32);
    }

    final len = data.length;
    final end = len - (len % 8);
    for (var i = 0; i < end; i += 8) {
      final m = _readU64LE(data, i);
      v3 ^= m;
      round();
      round();
      v0 ^= m;
    }
    // last block: remaining bytes + length in top byte
    var b = len << 56;
    for (var i = 0; i < len - end; i++) {
      b |= data[end + i] << (8 * i);
    }
    v3 ^= b;
    round();
    round();
    v0 ^= b;
    v2 ^= 0xff;
    round();
    round();
    round();
    round();
    return v0 ^ v1 ^ v2 ^ v3;
  }

  static int _readU64LE(List<int> b, int off) {
    var r = 0;
    for (var i = 0; i < 8; i++) {
      r |= b[off + i] << (8 * i);
    }
    return r;
  }

  static Uint8List u64LE(int v) {
    final out = Uint8List(8);
    for (var i = 0; i < 8; i++) {
      out[i] = (v >>> (8 * i)) & 0xff;
    }
    return out;
  }
}
