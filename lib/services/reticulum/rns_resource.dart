/*
 * RNS Resource — sender side (wire-compatible, RNS 1.3.5 — RNS/Resource.py).
 *
 * A Resource transfers a payload larger than a single packet over an established
 * Link. The sender:
 *   1. builds data = random_hash(4) + payload, then encrypts the WHOLE stream
 *      once with the link token (parts are then shipped raw, context=RESOURCE,
 *      to avoid per-part token overhead);
 *   2. splits the encrypted blob into [resourceSdu]-byte parts, each addressed by
 *      a 4-byte map_hash = full_hash(part + random_hash)[:4];
 *   3. sends an advertisement (msgpack) carrying sizes, hashes and the hashmap;
 *   4. answers RESOURCE_REQ packets with the requested parts;
 *   5. validates the receiver's RESOURCE_PRF (proof) to confirm completion.
 *
 * Scope: single RNS segment (payload <= ~1 MB) whose hashmap fits one
 * advertisement (parts <= ResourceAdvertisement.HASHMAP_MAX_LEN = 74). Larger
 * transfers (hashmap-update packets, multi-segment split) are a future extension.
 */
import 'dart:math' as math;
import 'dart:typed_data';

import 'rns_crypto.dart';
import 'rns_link.dart';
import 'rns_packet.dart';

const int _mapHashLen = 4;
const int _randomHashSize = 4;
const int _hashLen = 32; // Identity.HASHLENGTH/8
const int _hashmapMaxLen = 74; // floor((Link.MDU 431 - OVERHEAD 134)/4)
const int _hashmapExhausted = 0xFF; // 0x00 = not exhausted (the common case)

final math.Random _rng = math.Random.secure();

class RnsResourceSender {
  final RnsLink link;
  final Uint8List payload;

  late final Uint8List _encrypted; // the link-encrypted data stream
  late final int _sdu;
  late final int _n; // number of parts
  late final Uint8List _mapRandom;
  late final Uint8List resourceHash; // 32B
  late final Uint8List expectedProof; // 32B
  late final Uint8List _originalHash;
  final List<Uint8List> _parts = [];
  final List<Uint8List> _mapHashes = [];
  bool complete = false;

  RnsResourceSender(this.link, this.payload);

  int get parts => _n;
  int get transferSize => _encrypted.length;

  /// Prepare the resource (encrypt, split, hashmap). Throws if the payload would
  /// need more than one advertisement's worth of hashmap (HMU not implemented).
  void prepare() {
    final dataStream = Uint8List(_randomHashSize + payload.length)
      ..setRange(0, _randomHashSize, _randomBytes(_randomHashSize))
      ..setRange(_randomHashSize, _randomHashSize + payload.length, payload);
    _encrypted = link.tokenEncrypt(dataStream);
    _sdu = link.resourceSdu;
    _n = (_encrypted.length + _sdu - 1) ~/ _sdu;
    if (_n > _hashmapMaxLen) {
      throw StateError(
          'Resource needs $_n parts (> $_hashmapMaxLen); HMU/multi-segment not implemented');
    }
    _mapRandom = _randomBytes(_randomHashSize);
    // The resource hash and proof are over the PLAINTEXT payload (RNS computes
    // them from the pre-encryption `data`); only the parts/map_hashes use the
    // encrypted blob.
    resourceHash = RnsCrypto.fullHash([...payload, ..._mapRandom]);
    expectedProof = RnsCrypto.fullHash([...payload, ...resourceHash]);
    _originalHash = resourceHash;

    for (var i = 0; i < _n; i++) {
      final start = i * _sdu;
      final end = math.min(start + _sdu, _encrypted.length);
      final chunk = Uint8List.sublistView(_encrypted, start, end);
      final mapHash = Uint8List.sublistView(
          RnsCrypto.fullHash([...chunk, ..._mapRandom]), 0, _mapHashLen);
      _parts.add(Uint8List.fromList(chunk));
      _mapHashes.add(Uint8List.fromList(mapHash));
    }
  }

  /// The RESOURCE_ADV packet (link-encrypted) to send first.
  RnsPacket advertisementPacket() {
    final hashmap = BytesBuilder();
    for (final mh in _mapHashes) {
      hashmap.add(mh);
    }
    final adv = _MsgpackEncoder()
      ..mapHeader(11)
      ..str('t')..integer(_encrypted.length) // transfer size
      ..str('d')..integer(payload.length) // total uncompressed data size
      ..str('n')..integer(_n) // number of parts
      ..str('h')..bin(resourceHash) // resource hash
      ..str('r')..bin(_mapRandom) // map random hash
      ..str('o')..bin(_originalHash) // original (first-segment) hash
      ..str('i')..integer(1) // segment index
      ..str('l')..integer(1) // total segments
      ..str('q')..nil() // request id
      ..str('f')..integer(0x01) // flags: encrypted
      ..str('m')..bin(hashmap.toBytes()); // hashmap
    return link.encrypt(adv.bytes(), context: RnsContext.resourceAdv);
  }

  /// Handle an inbound RESOURCE_REQ (already link-decrypted). Returns the part
  /// packets to send for the requested map hashes.
  List<RnsPacket> handleRequest(Uint8List requestData) {
    final exhausted = requestData[0];
    final pad = exhausted == _hashmapExhausted ? 1 + _mapHashLen : 1;
    final hashesStart = pad + _hashLen;
    final out = <RnsPacket>[];
    for (var off = hashesStart; off + _mapHashLen <= requestData.length;
        off += _mapHashLen) {
      final want = Uint8List.sublistView(requestData, off, off + _mapHashLen);
      for (var i = 0; i < _mapHashes.length; i++) {
        if (RnsCrypto.constantTimeEquals(_mapHashes[i], want)) {
          out.add(RnsPacket(
            destHash: link.linkId!,
            data: _parts[i],
            headerType: RnsHeaderType.header1,
            destType: RnsDestType.link,
            packetType: RnsPacketType.data,
            context: RnsContext.resource,
          ));
          break;
        }
      }
    }
    return out;
  }

  /// Validate a RESOURCE_PRF proof (raw packet data = resource_hash + proof).
  bool validateProof(Uint8List proofData) {
    if (proofData.length != _hashLen * 2) return false;
    final proof = Uint8List.sublistView(proofData, _hashLen);
    if (RnsCrypto.constantTimeEquals(proof, expectedProof)) {
      complete = true;
      return true;
    }
    return false;
  }
}

Uint8List _randomBytes(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = _rng.nextInt(256);
  }
  return out;
}

/// Minimal msgpack encoder for the resource advertisement (fixmap, fixstr keys,
/// positive ints, bin, nil) — RNS uses umsgpack which accepts these forms.
class _MsgpackEncoder {
  final BytesBuilder _b = BytesBuilder();

  void mapHeader(int n) {
    if (n <= 15) {
      _b.addByte(0x80 | n);
    } else {
      _b.addByte(0xde);
      _b.addByte((n >> 8) & 0xff);
      _b.addByte(n & 0xff);
    }
  }

  void str(String s) {
    final bytes = s.codeUnits;
    if (bytes.length <= 31) {
      _b.addByte(0xa0 | bytes.length);
    } else {
      _b.addByte(0xd9);
      _b.addByte(bytes.length);
    }
    _b.add(bytes);
  }

  void integer(int v) {
    if (v >= 0 && v <= 0x7f) {
      _b.addByte(v);
    } else if (v <= 0xff) {
      _b.addByte(0xcc);
      _b.addByte(v);
    } else if (v <= 0xffff) {
      _b.addByte(0xcd);
      _b.addByte((v >> 8) & 0xff);
      _b.addByte(v & 0xff);
    } else {
      _b.addByte(0xce);
      _b.addByte((v >> 24) & 0xff);
      _b.addByte((v >> 16) & 0xff);
      _b.addByte((v >> 8) & 0xff);
      _b.addByte(v & 0xff);
    }
  }

  void bin(Uint8List data) {
    if (data.length <= 0xff) {
      _b.addByte(0xc4);
      _b.addByte(data.length);
    } else {
      _b.addByte(0xc5);
      _b.addByte((data.length >> 8) & 0xff);
      _b.addByte(data.length & 0xff);
    }
    _b.add(data);
  }

  void nil() => _b.addByte(0xc0);

  Uint8List bytes() => _b.toBytes();
}
