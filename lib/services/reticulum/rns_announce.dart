/*
 * RNS announce build/parse/validate (wire-compatible, RNS 1.3.5).
 *
 * announce DATA = public_key(64) + name_hash(10) + random_hash(10)
 *                 [+ ratchet(32) if context_flag set] + signature(64) [+ app_data]
 * signed_data   = dest_hash + public_key + name_hash + random_hash + ratchet
 *                 + app_data   (Ed25519 over this)
 * random_hash   = 5 random bytes + 5 big-endian seconds-since-epoch bytes
 *
 * We EMIT announces without a ratchet (context_flag unset); we PARSE both forms.
 */
import 'dart:math' as math;
import 'dart:typed_data';

import 'rns_crypto.dart';
import 'rns_identity.dart';
import 'rns_packet.dart';

const int _keysize = 64;
const int _nameHashLen = 10;
const int _randomHashLen = 10;
const int _sigLen = 64;
const int _ratchetSize = 32;

final math.Random _rng = math.Random.secure();

/// A validated inbound announce.
class RnsAnnounce {
  final Uint8List destHash;
  final Uint8List publicKey; // 64B
  final Uint8List nameHash; // 10B
  final Uint8List? ratchet; // 32B or null
  final Uint8List appData; // possibly empty
  final RnsIdentity identity;

  RnsAnnounce({
    required this.destHash,
    required this.publicKey,
    required this.nameHash,
    required this.ratchet,
    required this.appData,
    required this.identity,
  });
}

class RnsAnnounceBuilder {
  /// Build the announce packet for [identity]'s SINGLE/IN destination named
  /// (appName, aspects). Emits without a ratchet. Returns a ready-to-send
  /// [RnsPacket] (ANNOUNCE, HEADER_1, broadcast).
  static Future<RnsPacket> build(
    RnsIdentity identity,
    String appName,
    List<String> aspects, {
    Uint8List? appData,
    int nowSeconds = -1,
  }) async {
    final destHash = RnsDestination.hash(identity, appName, aspects);
    final nameHash = RnsDestination.nameHash(appName, aspects);
    final publicKey = identity.getPublicKey();
    final randomHash = _randomHash(nowSeconds);
    final ad = appData ?? Uint8List(0);

    final signedData = BytesBuilder()
      ..add(destHash)
      ..add(publicKey)
      ..add(nameHash)
      ..add(randomHash)
      ..add(ad); // ratchet is empty
    final signature = await identity.sign(signedData.toBytes());

    final announceData = BytesBuilder()
      ..add(publicKey)
      ..add(nameHash)
      ..add(randomHash)
      ..add(signature)
      ..add(ad);

    return RnsPacket(
      destHash: destHash,
      data: announceData.toBytes(),
      headerType: RnsHeaderType.header1,
      contextFlag: RnsFlag.unset,
      transportType: RnsTransportType.broadcast,
      destType: RnsDestType.single,
      packetType: RnsPacketType.announce,
      context: RnsContext.none,
    );
  }

  static Uint8List _randomHash(int nowSeconds) {
    final secs = nowSeconds >= 0
        ? nowSeconds
        : DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final out = Uint8List(_randomHashLen);
    for (var i = 0; i < 5; i++) {
      out[i] = _rng.nextInt(256);
    }
    // 5 big-endian bytes of the (40-bit-truncated) timestamp.
    for (var i = 0; i < 5; i++) {
      out[9 - i] = (secs >> (8 * i)) & 0xff;
    }
    return out;
  }
}

/// Parse + cryptographically validate an inbound ANNOUNCE packet. Returns null
/// if the packet isn't a valid announce (bad signature or dest-hash mismatch).
///
/// [trustIf], when supplied, is called after the (cheap) structural parse and
/// dest-hash binding check with the parsed (destHash, publicKey, appData). If it
/// returns true, the expensive Ed25519 signature verification is skipped — used
/// to avoid re-verifying an unchanged re-announce of a destination we already
/// verified once. The dest-hash↔key binding is always enforced, so a skipped
/// verify can only ever reuse trust in the *same* key the caller already holds.
Future<RnsAnnounce?> validateAnnounce(
  RnsPacket p, {
  bool Function(Uint8List destHash, Uint8List publicKey, Uint8List appData)?
      trustIf,
}) async {
  if (p.packetType != RnsPacketType.announce) return null;
  final data = p.data;
  final hasRatchet = p.contextFlag == RnsFlag.set;
  final minLen =
      _keysize + _nameHashLen + _randomHashLen + _sigLen + (hasRatchet ? _ratchetSize : 0);
  if (data.length < minLen) return null;

  final publicKey = Uint8List.sublistView(data, 0, _keysize);
  final nameHash =
      Uint8List.sublistView(data, _keysize, _keysize + _nameHashLen);
  final randomHash = Uint8List.sublistView(
      data, _keysize + _nameHashLen, _keysize + _nameHashLen + _randomHashLen);
  var off = _keysize + _nameHashLen + _randomHashLen;
  Uint8List ratchet = Uint8List(0);
  if (hasRatchet) {
    ratchet = Uint8List.sublistView(data, off, off + _ratchetSize);
    off += _ratchetSize;
  }
  final signature = Uint8List.sublistView(data, off, off + _sigLen);
  off += _sigLen;
  final appData = Uint8List.sublistView(data, off);

  final signedData = BytesBuilder()
    ..add(p.destHash)
    ..add(publicKey)
    ..add(nameHash)
    ..add(randomHash)
    ..add(ratchet)
    ..add(appData);

  final identity = RnsIdentity.fromPublicKey(publicKey);

  // dest_hash must equal truncated_hash(name_hash + identity.hash). Cheap, and
  // binds the destination to this public key — always enforced.
  final expected = RnsCrypto.truncatedHash([...nameHash, ...identity.hash]);
  if (!RnsCrypto.constantTimeEquals(expected, p.destHash)) return null;

  // The Ed25519 verify is the costly step. Skip it only when the caller already
  // trusts this exact (destHash, key, appData) — i.e. a re-announce of a dest we
  // verified before. New/changed announces are always fully verified.
  final trusted = trustIf?.call(p.destHash, publicKey, appData) ?? false;
  if (!trusted && !await identity.validate(signature, signedData.toBytes())) {
    return null;
  }

  return RnsAnnounce(
    destHash: Uint8List.fromList(p.destHash),
    publicKey: Uint8List.fromList(publicKey),
    nameHash: Uint8List.fromList(nameHash),
    ratchet: hasRatchet ? Uint8List.fromList(ratchet) : null,
    appData: Uint8List.fromList(appData),
    identity: identity,
  );
}
