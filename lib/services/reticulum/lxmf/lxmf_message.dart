/*
 * LXMessage — the LXMF message format, wire-compatible with markqvist/LXMF.
 *
 * Wire layout of `packed`:
 *   destination_hash(16) + source_hash(16) + signature(64) + msgpack(payload)
 * where payload = [timestamp(double), title(bytes), content(bytes), fields(map)]
 * (a 5th element, the optional spam-control "stamp", may follow on inbound msgs).
 *
 * Integrity (matches LXMF.LXMessage):
 *   hashed_part  = destination_hash + source_hash + msgpack(payload[:4])
 *   hash         = SHA-256(hashed_part)               // the message id
 *   signed_part  = hashed_part + hash
 *   signature    = source_identity.sign(signed_part)  // Ed25519
 * For the common (no-stamp) case the transmitted payload bytes are hashed
 * verbatim by both ends, so any valid msgpack interoperates; a stamped payload is
 * re-packed without the stamp to recover hashed_part.
 */
import 'dart:convert';
import 'dart:typed_data';

import '../rns_crypto.dart';
import '../rns_identity.dart';
import 'lxmf.dart';
import 'lxmf_msgpack.dart';

const int _destLen = 16; // RNS.Identity.TRUNCATED_HASHLENGTH/8
const int _sigLen = 64; // RNS.Identity.SIGLENGTH/8

class LxmfMessage {
  Uint8List destinationHash; // 16B recipient lxmf-delivery identity hash
  Uint8List sourceHash; // 16B sender identity hash
  double timestamp; // seconds since epoch (double)
  Uint8List title; // bytes (UTF-8)
  Uint8List content; // bytes (UTF-8)
  Map<Object?, Object?> fields; // msgpack map (int keys, see LxmfField)
  Uint8List? stamp; // optional spam-control stamp (payload[4])

  Uint8List signature; // 64B
  Uint8List hash; // 32B message id
  Uint8List packed; // full wire bytes

  LxmfMessage._({
    required this.destinationHash,
    required this.sourceHash,
    required this.timestamp,
    required this.title,
    required this.content,
    required this.fields,
    required this.signature,
    required this.hash,
    required this.packed,
    this.stamp,
  });

  String get titleString => utf8.decode(title, allowMalformed: true);
  String get contentString => utf8.decode(content, allowMalformed: true);

  /// Build and sign a message from [source] (must hold private keys) to the
  /// recipient identified by [destinationHash].
  static Future<LxmfMessage> create({
    required Uint8List destinationHash,
    required RnsIdentity source,
    String title = '',
    String content = '',
    Map<int, Object?>? fields,
    double? timestamp,
  }) async {
    final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch / 1000.0;
    final titleB = Uint8List.fromList(utf8.encode(title));
    final contentB = Uint8List.fromList(utf8.encode(content));
    final fieldMap = <Object?, Object?>{...?fields};
    // Source hash is the sender's LXMF DELIVERY destination hash (not the bare
    // identity hash) — matches LXMF, where source = Destination(id,...,'lxmf',
    // 'delivery'). The recipient's [destinationHash] is likewise a delivery dest.
    final sourceHash =
        RnsDestination.hash(source, kLxmfApp, kLxmfDeliveryAspects);

    final payload = [ts, titleB, contentB, fieldMap];
    final packedPayload = msgpackEncode(payload);
    final hashedPart = BytesBuilder()
      ..add(destinationHash)
      ..add(sourceHash)
      ..add(packedPayload);
    final hash = RnsCrypto.fullHash(hashedPart.toBytes());
    final signedPart = BytesBuilder()
      ..add(hashedPart.toBytes())
      ..add(hash);
    final sig = await source.sign(signedPart.toBytes());

    final packed = BytesBuilder()
      ..add(destinationHash)
      ..add(sourceHash)
      ..add(sig)
      ..add(packedPayload);

    return LxmfMessage._(
      destinationHash: Uint8List.fromList(destinationHash),
      sourceHash: Uint8List.fromList(sourceHash),
      timestamp: ts,
      title: titleB,
      content: contentB,
      fields: fieldMap,
      signature: Uint8List.fromList(sig),
      hash: Uint8List.fromList(hash),
      packed: packed.toBytes(),
    );
  }

  /// Parse wire bytes into a message (does NOT verify the signature; call
  /// [verify] with the source's identity). Returns null if malformed.
  static LxmfMessage? unpack(Uint8List bytes) {
    try {
      if (bytes.length < 2 * _destLen + _sigLen) return null;
      final destHash = Uint8List.sublistView(bytes, 0, _destLen);
      final sourceHash = Uint8List.sublistView(bytes, _destLen, 2 * _destLen);
      final sig = Uint8List.sublistView(
          bytes, 2 * _destLen, 2 * _destLen + _sigLen);
      final packedPayload =
          Uint8List.sublistView(bytes, 2 * _destLen + _sigLen);
      final payload = msgpackDecode(packedPayload);
      if (payload is! List || payload.length < 4) return null;

      Uint8List? stamp;
      var hashPayloadBytes = packedPayload;
      if (payload.length > 4) {
        // Strip the stamp and re-pack the 4-element payload to recover the
        // hashed part the sender signed.
        stamp = _asBytes(payload[4]);
        hashPayloadBytes =
            msgpackEncode([payload[0], payload[1], payload[2], payload[3]]);
      }
      final hashedPart = BytesBuilder()
        ..add(destHash)
        ..add(sourceHash)
        ..add(hashPayloadBytes);
      final hash = RnsCrypto.fullHash(hashedPart.toBytes());

      return LxmfMessage._(
        destinationHash: Uint8List.fromList(destHash),
        sourceHash: Uint8List.fromList(sourceHash),
        timestamp: (payload[0] as num).toDouble(),
        title: _asBytes(payload[1]) ?? Uint8List(0),
        content: _asBytes(payload[2]) ?? Uint8List(0),
        fields: payload[3] is Map
            ? (payload[3] as Map).cast<Object?, Object?>()
            : <Object?, Object?>{},
        stamp: stamp,
        signature: Uint8List.fromList(sig),
        hash: Uint8List.fromList(hash),
        packed: Uint8List.fromList(bytes),
      );
    } catch (_) {
      return null;
    }
  }

  /// Verify the signature against [sourceIdentity] (the sender's public identity,
  /// learned from its announce). Also checks the source's LXMF delivery
  /// destination hash matches the message's source hash.
  Future<bool> verify(RnsIdentity sourceIdentity) async {
    final srcDest =
        RnsDestination.hash(sourceIdentity, kLxmfApp, kLxmfDeliveryAspects);
    if (!RnsCrypto.constantTimeEquals(srcDest, sourceHash)) {
      return false;
    }
    final signedPart = BytesBuilder()
      ..add(destinationHash)
      ..add(sourceHash)
      ..add(_hashPayloadBytes())
      ..add(hash);
    return sourceIdentity.validate(signature, signedPart.toBytes());
  }

  // The payload bytes the hash/signature cover (payload[:4], stamp excluded).
  Uint8List _hashPayloadBytes() {
    if (stamp == null) {
      return Uint8List.sublistView(packed, 2 * _destLen + _sigLen);
    }
    return msgpackEncode([timestamp, title, content, fields]);
  }

  static Uint8List? _asBytes(Object? v) =>
      v is Uint8List ? v : (v is List<int> ? Uint8List.fromList(v) : null);
}
