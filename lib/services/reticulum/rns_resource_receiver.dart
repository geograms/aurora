/*
 * RNS Resource — receiver side (wire-compatible, RNS 1.3.5 — RNS/Resource.py).
 *
 * The counterpart to RnsResourceSender. The receiver:
 *   1. parses the RESOURCE_ADV advertisement (msgpack) for the transfer size,
 *      part count, resource hash, map-random and the hashmap of per-part hashes;
 *   2. sends a RESOURCE_REQ listing the map-hashes it wants;
 *   3. ingests RESOURCE parts (raw slices of the once-encrypted stream), matching
 *      each to its index via map_hash = full_hash(part + map_random)[:4];
 *   4. once all parts are in, reassembles the encrypted stream, link-token-
 *      decrypts it, strips the 4-byte stream random, and verifies
 *      full_hash(payload + map_random) == resource_hash;
 *   5. returns the RESOURCE_PRF proof packet = full_hash(payload + resource_hash)
 *      so the sender can confirm completion.
 *
 * Scope mirrors the sender: single RNS segment whose hashmap fits one
 * advertisement (parts <= 74). Larger transfers are chunked above this layer.
 */
import 'dart:typed_data';

import 'rns_crypto.dart';
import 'rns_link.dart';
import 'rns_packet.dart';

const int _mapHashLen = 4;
const int _randomHashSize = 4;
const int _hashLen = 32;

/// Receiver-side state machine for one inbound Resource over an active link.
class RnsResourceReceiver {
  final RnsLink link;

  int _n = 0; // expected part count
  int _transferSize = 0; // size of the encrypted stream
  int _dataSize = 0; // size of the plaintext payload (advisory)
  Uint8List _resourceHash = Uint8List(0); // 32B, over plaintext+mapRandom
  Uint8List _mapRandom = Uint8List(0); // 4B
  bool _encrypted = true;
  final List<Uint8List> _wantedMapHashes = []; // index -> 4B map hash
  final Map<int, Uint8List> _parts = {}; // index -> raw part bytes

  Uint8List? _payload; // assembled + verified plaintext
  bool _complete = false;
  String? _error;

  RnsResourceReceiver(this.link);

  bool get complete => _complete;
  String? get error => _error;
  Uint8List? get payload => _payload;
  int get expectedParts => _n;
  int get receivedParts => _parts.length;

  /// Parse a link-decrypted RESOURCE_ADV. Returns false on a malformed/oversized
  /// advertisement (the caller should drop the resource).
  bool ingestAdvertisement(Uint8List advPlaintext) {
    try {
      final m = _MsgpackDecoder(advPlaintext).decode();
      if (m is! Map) return _fail('advertisement not a map');
      _transferSize = _asInt(m['t']);
      _dataSize = _asInt(m['d']);
      _n = _asInt(m['n']);
      _resourceHash = _asBin(m['h']);
      _mapRandom = _asBin(m['r']);
      final flags = _asInt(m['f']);
      _encrypted = (flags & 0x01) != 0;
      final hashmap = _asBin(m['m']);
      if (_n <= 0 || _resourceHash.length != _hashLen ||
          _mapRandom.length != _randomHashSize) {
        return _fail('advertisement fields invalid');
      }
      if (hashmap.length < _n * _mapHashLen) {
        return _fail('hashmap shorter than part count');
      }
      _wantedMapHashes.clear();
      for (var i = 0; i < _n; i++) {
        _wantedMapHashes.add(Uint8List.sublistView(
            hashmap, i * _mapHashLen, (i + 1) * _mapHashLen));
      }
      return true;
    } catch (e) {
      return _fail('advertisement parse error: $e');
    }
  }

  /// Build the RESOURCE_REQ packet for all parts we still need. The wire form the
  /// sender expects: [exhausted(1)=0x00][resource_hash(32)][map_hash(4)]*. Send
  /// its pack() over the wire; call again after a timeout to re-request gaps.
  RnsPacket buildRequest() {
    final b = BytesBuilder()
      ..addByte(0x00) // hashmap not exhausted
      ..add(_resourceHash);
    for (var i = 0; i < _n; i++) {
      if (!_parts.containsKey(i)) b.add(_wantedMapHashes[i]);
    }
    return link.encrypt(b.toBytes(), context: RnsContext.resourceReq);
  }

  /// True while at least one part is still missing.
  bool get hasMissing => _parts.length < _n;

  /// Ingest one RESOURCE part (the raw packet data; parts are NOT per-part
  /// encrypted — the whole stream was token-encrypted once by the sender). Matches
  /// the part to its index by map-hash. Returns true once all parts are present
  /// and the payload verified (then [payload] is set and [complete] is true).
  bool ingestPart(Uint8List part) {
    if (_complete) return true;
    final mapHash = Uint8List.sublistView(
        RnsCrypto.fullHash([...part, ..._mapRandom]), 0, _mapHashLen);
    for (var i = 0; i < _n; i++) {
      if (_parts.containsKey(i)) continue;
      if (RnsCrypto.constantTimeEquals(_wantedMapHashes[i], mapHash)) {
        _parts[i] = Uint8List.fromList(part);
        break;
      }
    }
    if (_parts.length < _n) return false;
    return _assembleAndVerify();
  }

  bool _assembleAndVerify() {
    final encrypted = BytesBuilder();
    for (var i = 0; i < _n; i++) {
      final p = _parts[i];
      if (p == null) return false; // still missing one
      encrypted.add(p);
    }
    final enc = encrypted.toBytes();
    if (_transferSize > 0 && enc.length != _transferSize) {
      return _fail('encrypted stream size ${enc.length} != advertised $_transferSize');
    }
    Uint8List dataStream;
    try {
      dataStream = _encrypted ? link.tokenDecrypt(enc) : enc;
    } catch (e) {
      return _fail('stream decrypt failed: $e');
    }
    if (dataStream.length < _randomHashSize) {
      return _fail('stream shorter than random header');
    }
    final payload = Uint8List.sublistView(dataStream, _randomHashSize);
    if (_dataSize > 0 && payload.length != _dataSize) {
      return _fail('payload size ${payload.length} != advertised $_dataSize');
    }
    final check = Uint8List.sublistView(
        RnsCrypto.fullHash([...payload, ..._mapRandom]), 0, _hashLen);
    if (!RnsCrypto.constantTimeEquals(check, _resourceHash)) {
      return _fail('resource hash mismatch');
    }
    _payload = Uint8List.fromList(payload);
    _complete = true;
    return true;
  }

  /// The RESOURCE_PRF proof packet to send once [complete]: data = resource_hash
  /// (32) + proof(32) where proof = full_hash(payload + resource_hash). Returns
  /// null if not complete.
  RnsPacket? proofPacket() {
    final pl = _payload;
    if (!_complete || pl == null) return null;
    final proof = RnsCrypto.fullHash([...pl, ..._resourceHash]);
    final data = BytesBuilder()
      ..add(_resourceHash)
      ..add(proof);
    return link.encrypt(data.toBytes(), context: RnsContext.resourcePrf);
  }

  bool _fail(String why) {
    _error = why;
    return false;
  }

  static int _asInt(Object? v) => v is int ? v : 0;
  static Uint8List _asBin(Object? v) =>
      v is Uint8List ? v : (v is List<int> ? Uint8List.fromList(v) : Uint8List(0));
}

/// Minimal msgpack decoder for the resource advertisement: fixmap/map16,
/// fixstr/str8, positive/uint ints, bin8/bin16, nil. Mirrors the encoder in
/// rns_resource.dart (umsgpack subset).
class _MsgpackDecoder {
  final Uint8List _b;
  int _i = 0;
  _MsgpackDecoder(this._b);

  Object? decode() {
    final c = _b[_i++];
    if (c <= 0x7f) return c; // positive fixint
    if (c >= 0xe0) return c - 256; // negative fixint
    if ((c & 0xf0) == 0x80) return _map(c & 0x0f); // fixmap
    if ((c & 0xe0) == 0xa0) return _str(c & 0x1f); // fixstr
    switch (c) {
      case 0xc0:
        return null; // nil
      case 0xc2:
        return false;
      case 0xc3:
        return true;
      case 0xc4:
        return _bin(_b[_i++]); // bin8
      case 0xc5:
        final n = (_b[_i] << 8) | _b[_i + 1];
        _i += 2;
        return _bin(n); // bin16
      case 0xcc:
        return _b[_i++]; // uint8
      case 0xcd:
        final v = (_b[_i] << 8) | _b[_i + 1];
        _i += 2;
        return v; // uint16
      case 0xce:
        final v = (_b[_i] << 24) | (_b[_i + 1] << 16) | (_b[_i + 2] << 8) | _b[_i + 3];
        _i += 4;
        return v; // uint32
      case 0xd9:
        return _str(_b[_i++]); // str8
      case 0xde:
        final n = (_b[_i] << 8) | _b[_i + 1];
        _i += 2;
        return _map(n); // map16
      default:
        throw FormatException('unsupported msgpack byte 0x${c.toRadixString(16)}');
    }
  }

  Map<String, Object?> _map(int n) {
    final out = <String, Object?>{};
    for (var k = 0; k < n; k++) {
      final key = decode();
      final val = decode();
      out['$key'] = val;
    }
    return out;
  }

  String _str(int n) {
    final s = String.fromCharCodes(_b.sublist(_i, _i + n));
    _i += n;
    return s;
  }

  Uint8List _bin(int n) {
    final out = Uint8List.sublistView(_b, _i, _i + n);
    _i += n;
    return Uint8List.fromList(out);
  }
}
