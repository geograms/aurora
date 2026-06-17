/*
 * A signed "I provide this file" record stored in the DHT.
 *
 * The DHT maps a file's sha256 to a set of these. Each is signed by the
 * provider's Reticulum identity, so any node can verify it without trusting the
 * node that handed it over; content hashing on download makes a lying record
 * harmless beyond a wasted round trip. Records carry the provider's PUBLIC KEY
 * (so verifiers can check the signature AND reach the provider's files
 * destination), a capacity class (for bandwidth-aware ranking), an optional
 * manifest hash, a timestamp and a TTL. Records age out at timestamp+ttl unless
 * the provider republishes — which is how abrupt departures self-heal.
 */
import 'dart:typed_data';

import '../../reticulum/rns_identity.dart';

// Capacity classes (lower = preferred when ranking providers).
const int kCapArchive = 1; // pinned archive / always-on
const int kCapHomeFiber = 2;
const int kCapHomeWifi = 3;
const int kCapWifiTransient = 4; // a phone on wifi, may leave soon
const int kCapCellular = 5;
const int kCapBle = 6;
const int kCapUnknown = 9;

const int _ver = 1;
const int _sigLen = 64;

class ProviderRecord {
  final Uint8List sha256; // 32B file id
  final Uint8List providerPub; // 64B provider public key
  final int capacity; // capacity class
  final Uint8List? manifestHash; // 32B, optional
  final int timestampMs;
  final int ttlSec;
  final Uint8List signature; // 64B

  ProviderRecord({
    required this.sha256,
    required this.providerPub,
    required this.capacity,
    required this.manifestHash,
    required this.timestampMs,
    required this.ttlSec,
    required this.signature,
  });

  /// 16-byte DHT routing key (first 128 bits of the file sha256).
  Uint8List get fileKey => Uint8List.fromList(sha256.sublist(0, 16));

  /// The provider's (public) identity, for opening a files link or verifying.
  RnsIdentity get providerIdentity => RnsIdentity.fromPublicKey(providerPub);

  bool isExpired([int? nowMs]) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return now > timestampMs + ttlSec * 1000;
  }

  /// Build + sign a record for [sha256] using [providerIdentity] (private).
  static Future<ProviderRecord> create({
    required RnsIdentity providerIdentity,
    required Uint8List sha256,
    int capacity = kCapUnknown,
    Uint8List? manifestHash,
    int ttlSec = 2700, // 45 minutes
    int? nowMs,
  }) async {
    final pub = providerIdentity.getPublicKey();
    final ts = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final signed = _signedRegion(
        sha256, pub, capacity, manifestHash, ts, ttlSec);
    final sig = await providerIdentity.sign(signed);
    return ProviderRecord(
      sha256: Uint8List.fromList(sha256),
      providerPub: Uint8List.fromList(pub),
      capacity: capacity,
      manifestHash: manifestHash == null ? null : Uint8List.fromList(manifestHash),
      timestampMs: ts,
      ttlSec: ttlSec,
      signature: Uint8List.fromList(sig),
    );
  }

  /// Verify the signature against the provider's public key.
  Future<bool> verify() async {
    if (sha256.length != 32 || providerPub.length != 64 ||
        signature.length != _sigLen) {
      return false;
    }
    if (manifestHash != null && manifestHash!.length != 32) return false;
    final signed =
        _signedRegion(sha256, providerPub, capacity, manifestHash, timestampMs, ttlSec);
    final id = RnsIdentity.fromPublicKey(providerPub);
    return id.validate(signature, signed);
  }

  static Uint8List _signedRegion(Uint8List sha256, Uint8List pub, int capacity,
      Uint8List? manifestHash, int timestampMs, int ttlSec) {
    final b = BytesBuilder()
      ..addByte(_ver)
      ..add(sha256)
      ..add(pub)
      ..addByte(capacity & 0xff)
      ..addByte(manifestHash == null ? 0 : 1);
    if (manifestHash != null) b.add(manifestHash);
    final n = ByteData(12)
      ..setUint64(0, timestampMs, Endian.big)
      ..setUint32(8, ttlSec, Endian.big);
    b.add(n.buffer.asUint8List());
    return b.toBytes();
  }

  Uint8List encode() {
    final b = BytesBuilder()
      ..addByte(_ver)
      ..add(sha256)
      ..add(providerPub)
      ..addByte(capacity & 0xff)
      ..addByte(manifestHash == null ? 0 : 1);
    if (manifestHash != null) b.add(manifestHash!);
    final n = ByteData(12)
      ..setUint64(0, timestampMs, Endian.big)
      ..setUint32(8, ttlSec, Endian.big);
    b.add(n.buffer.asUint8List());
    b.add(signature);
    return b.toBytes();
  }

  static ProviderRecord? decode(Uint8List data) {
    try {
      var i = 0;
      if (data[i++] != _ver) return null;
      final sha = Uint8List.fromList(data.sublist(i, i + 32));
      i += 32;
      final pub = Uint8List.fromList(data.sublist(i, i + 64));
      i += 64;
      final capacity = data[i++];
      final hasManifest = data[i++] == 1;
      Uint8List? manifest;
      if (hasManifest) {
        manifest = Uint8List.fromList(data.sublist(i, i + 32));
        i += 32;
      }
      final bd = ByteData.sublistView(data, i, i + 12);
      final ts = bd.getUint64(0, Endian.big);
      final ttl = bd.getUint32(8, Endian.big);
      i += 12;
      final sig = Uint8List.fromList(data.sublist(i, i + _sigLen));
      i += _sigLen;
      return ProviderRecord(
        sha256: sha,
        providerPub: pub,
        capacity: capacity,
        manifestHash: manifest,
        timestampMs: ts,
        ttlSec: ttl,
        signature: sig,
      );
    } catch (_) {
      return null;
    }
  }
}
