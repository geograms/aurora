/*
 * RNS Identity and Destination addressing (wire-compatible, RNS 1.3.5).
 *
 * Identity  -> RNS/Identity.py: a Curve25519 keyset = X25519 (encryption) +
 *   Ed25519 (signing). public_key = x25519_pub(32) + ed25519_pub(32) = 64B;
 *   private_key = x25519_prv(32) + ed25519_prv(32) = 64B; hash =
 *   truncated_hash(public_key) = SHA-256(public_key)[:16].
 * Destination -> RNS/Destination.py: name_hash = SHA-256(name)[:10] over the
 *   dotted app/aspect name (no identity), and the addressable hash =
 *   SHA-256(name_hash + identity.hash)[:16].
 */
import 'dart:convert';
import 'dart:typed_data';

import 'rns_crypto.dart';

/// RNS NAME_HASH_LENGTH = 80 bits = 10 bytes.
const int kRnsNameHashBytes = 10;

/// X25519 / Ed25519 public/private halves are 32 bytes each.
const int kRnsKeyHalfBytes = 32;

class RnsIdentity {
  /// X25519 private scalar (32B), null for a public-only identity.
  final Uint8List? prvBytes;

  /// Ed25519 private seed (32B), null for a public-only identity.
  final Uint8List? sigPrvBytes;

  /// X25519 public key (32B).
  final Uint8List pubBytes;

  /// Ed25519 public key (32B).
  final Uint8List sigPubBytes;

  /// truncated_hash(public_key) — 16 bytes.
  final Uint8List hash;

  RnsIdentity._({
    required this.prvBytes,
    required this.sigPrvBytes,
    required this.pubBytes,
    required this.sigPubBytes,
    required this.hash,
  });

  bool get hasPrivateKey => prvBytes != null && sigPrvBytes != null;

  /// public_key = x25519_pub + ed25519_pub (64B).
  Uint8List getPublicKey() => Uint8List(64)
    ..setRange(0, 32, pubBytes)
    ..setRange(32, 64, sigPubBytes);

  /// private_key = x25519_prv + ed25519_prv (64B), or null if public-only.
  Uint8List? getPrivateKey() {
    if (!hasPrivateKey) return null;
    return Uint8List(64)
      ..setRange(0, 32, prvBytes!)
      ..setRange(32, 64, sigPrvBytes!);
  }

  String get hexHash =>
      hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Generate a fresh identity (random X25519 + Ed25519 keypairs).
  static Future<RnsIdentity> generate() async {
    final x = await RnsCrypto.x25519Generate();
    final e = await RnsCrypto.ed25519Generate();
    return RnsIdentity._(
      prvBytes: x.priv,
      sigPrvBytes: e.priv,
      pubBytes: x.pub,
      sigPubBytes: e.pub,
      hash: RnsCrypto.truncatedHash(
          _concat(x.pub, e.pub)),
    );
  }

  /// Load from a 64-byte private key (x25519_prv(32) + ed25519_prv(32)).
  static Future<RnsIdentity> fromPrivateKey(Uint8List prv) async {
    if (prv.length != 64) {
      throw ArgumentError('RNS private key must be 64 bytes');
    }
    final xPrv = Uint8List.sublistView(prv, 0, 32);
    final ePrv = Uint8List.sublistView(prv, 32, 64);
    final xPub = await RnsCrypto.x25519PublicFromPrivate(xPrv);
    final ePub = await RnsCrypto.ed25519PublicFromSeed(ePrv);
    return RnsIdentity._(
      prvBytes: Uint8List.fromList(xPrv),
      sigPrvBytes: Uint8List.fromList(ePrv),
      pubBytes: xPub,
      sigPubBytes: ePub,
      hash: RnsCrypto.truncatedHash(_concat(xPub, ePub)),
    );
  }

  /// Load from a 64-byte public key (x25519_pub(32) + ed25519_pub(32)).
  static RnsIdentity fromPublicKey(Uint8List pub) {
    if (pub.length != 64) {
      throw ArgumentError('RNS public key must be 64 bytes');
    }
    final xPub = Uint8List.sublistView(pub, 0, 32);
    final ePub = Uint8List.sublistView(pub, 32, 64);
    return RnsIdentity._(
      prvBytes: null,
      sigPrvBytes: null,
      pubBytes: Uint8List.fromList(xPub),
      sigPubBytes: Uint8List.fromList(ePub),
      hash: RnsCrypto.truncatedHash(pub),
    );
  }

  /// Sign [message] with the Ed25519 key.
  Future<Uint8List> sign(List<int> message) {
    if (sigPrvBytes == null) {
      throw StateError('Cannot sign without a private key');
    }
    return RnsCrypto.ed25519Sign(sigPrvBytes!, message);
  }

  /// Verify an Ed25519 [signature] over [message] against this identity.
  Future<bool> validate(Uint8List signature, List<int> message) =>
      RnsCrypto.ed25519Verify(sigPubBytes, message, signature);

  /// Encrypt [plaintext] to this identity (RNS/Identity.py encrypt):
  /// ephemeral X25519 -> ECDH -> HKDF(64, salt=hash) -> Token; wire form is
  /// eph_pub(32) + token. [ephemeralSeed]/[iv] are for deterministic testing.
  Future<Uint8List> encrypt(Uint8List plaintext,
      {Uint8List? ephemeralSeed, Uint8List? iv}) async {
    final eph = await RnsCrypto.x25519Generate(ephemeralSeed);
    final shared = await RnsCrypto.x25519Shared(eph.priv, pubBytes);
    final derived = RnsCrypto.hkdf(64, shared, salt: hash);
    final token = RnsToken(derived).encrypt(plaintext, iv: iv);
    return Uint8List(eph.pub.length + token.length)
      ..setRange(0, eph.pub.length, eph.pub)
      ..setRange(eph.pub.length, eph.pub.length + token.length, token);
  }

  /// Decrypt a token produced by [encrypt] (no ratchet support yet).
  Future<Uint8List> decrypt(Uint8List ciphertextToken) async {
    if (prvBytes == null) {
      throw StateError('Cannot decrypt without a private key');
    }
    if (ciphertextToken.length <= kRnsKeyHalfBytes) {
      throw ArgumentError('Token too short');
    }
    final peerPub = Uint8List.sublistView(ciphertextToken, 0, 32);
    final token = Uint8List.sublistView(ciphertextToken, 32);
    final shared = await RnsCrypto.x25519Shared(prvBytes!, peerPub);
    final derived = RnsCrypto.hkdf(64, shared, salt: hash);
    return RnsToken(derived).decrypt(token);
  }
}

/// Helpers for RNS destination naming/addressing (RNS/Destination.py).
class RnsDestination {
  /// Build the dotted human-readable name. With [identity] given, the identity
  /// hexhash is appended (used for full names); name_hash uses identity=null.
  static String expandName(String appName, List<String> aspects,
      {RnsIdentity? identity}) {
    if (appName.contains('.')) {
      throw ArgumentError("Dots can't be used in app names");
    }
    final sb = StringBuffer(appName);
    for (final a in aspects) {
      if (a.contains('.')) {
        throw ArgumentError("Dots can't be used in aspects");
      }
      sb.write('.');
      sb.write(a);
    }
    if (identity != null) {
      sb.write('.');
      sb.write(identity.hexHash);
    }
    return sb.toString();
  }

  /// name_hash = SHA-256(expand_name(None, app, *aspects))[:10].
  static Uint8List nameHash(String appName, List<String> aspects) =>
      Uint8List.sublistView(
          RnsCrypto.fullHash(utf8.encode(expandName(appName, aspects))),
          0,
          kRnsNameHashBytes);

  /// Addressable destination hash = SHA-256(name_hash + identity.hash)[:16].
  static Uint8List hash(
      RnsIdentity identity, String appName, List<String> aspects) {
    final nh = nameHash(appName, aspects);
    return RnsCrypto.truncatedHash(_concat(nh, identity.hash));
  }
}

Uint8List _concat(Uint8List a, Uint8List b) => Uint8List(a.length + b.length)
  ..setRange(0, a.length, a)
  ..setRange(a.length, a.length + b.length, b);
