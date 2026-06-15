/*
 * ECIES-X25519 short tunnel build records (proposal 152/157), pure Dart.
 *
 * Each hop in a tunnel gets a 218-byte encrypted ShortBuildRequestRecord:
 *   [0:16]   first 16 bytes of the hop's router identity hash
 *   [16:48]  our one-time ephemeral X25519 public key
 *   [48:218] ChaCha20-Poly1305(154-byte plaintext) + 16-byte tag
 *
 * Per-hop crypto is a Noise_N handshake to the hop's router encryption key:
 *   ck = "Noise_N_25519_ChaChaPoly_SHA256\0" (32 bytes)
 *   h  = SHA256(ck); h = SHA256(h || hopStaticKey)         // MixHash(rs)
 *   h  = SHA256(h || ephemeralPub)                          // MixHash(e)
 *   MixKey(DH(e, rs)): [ck,k] = HKDF(ck, ss, "")
 *   record = AEAD(k, n=0, ad=h, plaintext)
 *   h  = SHA256(h || record)                                // for reply AD
 *   replyKey = HKDF(ck,"SMTunnelReplyKey")[1]; ck = [0]
 *   layerKey = HKDF(ck,"SMTunnelLayerKey")[1]; ck = [0]
 *   ivKey    = HKDF(ck,"TunnelLayerIVKey")[1]; ck = [0]
 */
import 'dart:typed_data';

import 'i2p_crypto.dart';

const noiseNName = 'Noise_N_25519_ChaChaPoly_SHA256';

const shortRecordClearTextSize = 154;
const shortRecordSize = 218; // 16 + 32 + 154 + 16

/// Keys derived for a hop when building its record. [h] is the handshake hash
/// used as AEAD associated data when decrypting that hop's reply record.
class HopBuildKeys {
  final Uint8List replyKey;
  final Uint8List layerKey;
  final Uint8List ivKey;
  final Uint8List h;
  /// Endpoint hops only: the symmetric garlic key (32) + tag (8) used to
  /// encrypt/decrypt the build reply (i2pd "RGarlicKeyAndTag"). Null otherwise.
  final Uint8List? garlicKey;
  final Uint8List? garlicTag;
  HopBuildKeys(this.replyKey, this.layerKey, this.ivKey, this.h,
      {this.garlicKey, this.garlicTag});
}

Uint8List _noiseCk() {
  final b = Uint8List(32);
  b.setRange(0, noiseNName.length, noiseNName.codeUnits);
  return b; // name (31 bytes) + trailing 0x00
}

/// Build one hop's 218-byte record. [plaintext] must be 154 bytes.
Future<(Uint8List, HopBuildKeys)> buildShortRecord({
  required Uint8List hopIdentHash, // full 32-byte SHA256(RouterIdentity)
  required Uint8List hopStaticKey, // hop's X25519 router encryption key
  required Uint8List plaintext,
  bool isEndpoint = false, // tunnel endpoint hop? affects the IV-key derivation
  Uint8List? ephemeralPriv, // for tests; otherwise random
}) async {
  assert(plaintext.length == shortRecordClearTextSize);
  var ck = _noiseCk();
  var h = I2pCrypto.sha256(ck);
  h = I2pCrypto.sha256(_cat(h, hopStaticKey));

  final eph = await I2pCrypto.x25519Generate(ephemeralPriv);
  final record = Uint8List(shortRecordSize);
  record.setRange(0, 16, hopIdentHash);
  record.setRange(16, 48, eph.pub);
  h = I2pCrypto.sha256(_cat(h, eph.pub));

  final ss = await I2pCrypto.x25519Shared(eph.priv, hopStaticKey);
  final mk = I2pCrypto.hkdf(ck, ss, '', 2);
  ck = mk[0];
  final k = mk[1];

  final ct = await I2pCrypto.chachaEncrypt(k, _nonce(0), plaintext, h);
  record.setRange(48, shortRecordSize, ct);
  h = I2pCrypto.sha256(_cat(h, ct));

  final keys = _deriveHopKeys(ck, h, isEndpoint);
  return (record, keys);
}

/// Decrypt a hop's record as that hop would (test/verification helper):
/// returns the 154-byte plaintext and the identical derived keys.
Future<(Uint8List, HopBuildKeys)> openShortRecord({
  required Uint8List record,
  required Uint8List hopStaticPriv,
  required Uint8List hopStaticPub,
  bool isEndpoint = false,
}) async {
  var ck = _noiseCk();
  var h = I2pCrypto.sha256(ck);
  h = I2pCrypto.sha256(_cat(h, hopStaticPub));

  final ephPub = record.sublist(16, 48);
  h = I2pCrypto.sha256(_cat(h, ephPub));

  final ss = await I2pCrypto.x25519Shared(hopStaticPriv, ephPub);
  final mk = I2pCrypto.hkdf(ck, ss, '', 2);
  ck = mk[0];
  final k = mk[1];

  final ct = record.sublist(48, shortRecordSize);
  final plain = await I2pCrypto.chachaDecrypt(k, _nonce(0), ct, h);
  h = I2pCrypto.sha256(_cat(h, ct));

  return (plain, _deriveHopKeys(ck, h, isEndpoint));
}

/// Decrypt a hop's 218-byte reply record. The hop AEAD-encrypts its own reply
/// with replyKey, nonce = record index in byte 4, associated data = the build
/// hash h. Returns the 202-byte plaintext; byte 201 is the reply (0 = accept).
Future<Uint8List> openShortReplyRecord({
  required Uint8List record,
  required Uint8List replyKey,
  required Uint8List h,
  required int recordIndex,
}) async {
  return I2pCrypto.chachaDecrypt(replyKey, _nonce(recordIndex), record, h);
}

const shortReplyRetOffset = 201;

/// Decrypt + parse an OUTBOUND tunnel build reply, which i2pd wraps in a
/// symmetric garlic. [garlicBody] is the I2NP Garlic message body (after its
/// 16-byte header): [length(4)][tag(8)][ChaCha20-Poly1305 ciphertext]. Returns
/// this hop's reply byte (0 = accepted) for [recordIndex], or null on any
/// mismatch. Chain (i2pd SymmetricKeyTagSet + HandleECIESx25519GarlicClove):
///   tag == garlicTag; AEAD(key=garlicKey, nonce=0, ad=tag) -> plaintext;
///   plaintext = [blk=11 GarlicClove][size(2)][clove];
///   clove(LOCAL) = [flag(1)][typeID(1)][msgID(4)][exp(4)][count(1) + records].
Future<int?> openShortBuildReplyGarlic({
  required Uint8List garlicBody,
  required Uint8List garlicKey,
  required Uint8List garlicTag,
  required Uint8List replyKey,
  required Uint8List h,
  required int recordIndex,
}) async {
  if (garlicBody.length < 12) return null;
  final length =
      (garlicBody[0] << 24) | (garlicBody[1] << 16) | (garlicBody[2] << 8) | garlicBody[3];
  if (4 + length > garlicBody.length || length < 24) return null;
  final tag = garlicBody.sublist(4, 12);
  for (var i = 0; i < 8; i++) {
    if (tag[i] != garlicTag[i]) return null; // not our reply
  }
  final cipherAndTag = garlicBody.sublist(12, 4 + length); // ciphertext + 16 poly
  Uint8List plain;
  try {
    plain = await I2pCrypto.chachaDecrypt(garlicKey, Uint8List(12), cipherAndTag, tag);
  } catch (_) {
    return null;
  }
  if (plain.length < 3 || plain[0] != 11) return null; // expect a GarlicClove block
  final cloveSize = (plain[1] << 8) | plain[2];
  if (3 + cloveSize > plain.length) return null;
  final clove = plain.sublist(3, 3 + cloveSize);
  // clove delivery instructions
  var off = 1; // flag
  final dt = (clove[0] >> 5) & 0x3;
  if (dt == 1) {
    off += 32 + 4; // TUNNEL: gwHash + gwTunnel
  } else if (dt == 2 || dt == 3) {
    off += 32; // ROUTER/DESTINATION hash
  }
  off += 1 + 4 + 4; // typeID + msgID + expiration
  if (off >= clove.length) return null;
  final body = clove.sublist(off); // [count(1)][records × shortRecordSize]
  final count = body[0];
  if (recordIndex >= count || 1 + (recordIndex + 1) * shortRecordSize > body.length) {
    return null;
  }
  final rec = body.sublist(
      1 + recordIndex * shortRecordSize, 1 + (recordIndex + 1) * shortRecordSize);
  final rp = await openShortReplyRecord(
      record: rec, replyKey: replyKey, h: h, recordIndex: recordIndex);
  return rp[shortReplyRetOffset];
}

/// Undo one hop's ChaCha20 stream transform of another hop's 218-byte record
/// (DecryptRecord: ChaCha20(replyKey, nonce[4]=recordIndex)). Self-inverse.
Uint8List streamRecord(Uint8List record, Uint8List replyKey, int recordIndex) =>
    I2pCrypto.chacha20Raw(replyKey, _nonce(recordIndex), record);

/// De-layer a multi-hop short tunnel build REPLY and return each hop's reply
/// byte (0 = accepted). [hopKeys] are in hop order (gateway..endpoint) and
/// [recordIndex] gives each hop's record slot. Mirrors i2pd's
/// HandleTunnelBuildResponse: iterate hops last->first; each AEAD-decrypts its
/// own record then ChaCha20-undoes all preceding hops' records.
Future<List<int>> openMultiHopReply({
  required Uint8List message, // [count][218-byte records...]
  required List<HopBuildKeys> hopKeys,
  required List<int> recordIndex,
}) async {
  final count = message.isEmpty ? 0 : message[0];
  final n = hopKeys.length;
  if (1 + count * shortRecordSize > message.length || count < n) {
    return List<int>.filled(n, -1); // malformed / not a build reply
  }
  final records = <Uint8List>[];
  for (var i = 0; i < count; i++) {
    records.add(Uint8List.fromList(
        message.sublist(1 + i * shortRecordSize, 1 + (i + 1) * shortRecordSize)));
  }
  final accepts = List<int>.filled(n, -1);
  for (var h = n - 1; h >= 0; h--) {
    final plain = await openShortReplyRecord(
        record: records[recordIndex[h]],
        replyKey: hopKeys[h].replyKey,
        h: hopKeys[h].h,
        recordIndex: recordIndex[h]);
    accepts[h] = plain[shortReplyRetOffset];
    for (var p = 0; p < h; p++) {
      records[recordIndex[p]] =
          streamRecord(records[recordIndex[p]], hopKeys[h].replyKey, recordIndex[p]);
    }
  }
  return accepts;
}

HopBuildKeys _deriveHopKeys(Uint8List ck0, Uint8List h, bool isEndpoint) {
  // Mirrors i2pd ShortECIESTunnelHopConfig (TunnelConfig.cpp): after the layer
  // key, the IV key derivation DIFFERS by role:
  //   endpoint hop      : ivKey = HKDF(ck, "TunnelLayerIVKey")  (then a garlic HKDF)
  //   non-endpoint hop  : ivKey = ck  (the chaining key after the layer-key HKDF;
  //                       NO extra HKDF)
  // Our inbound tunnels build only gateway/transit (non-endpoint) hops, so using
  // the endpoint derivation gave a wrong ivKey -> corrupted CBC block 0 (the IV
  // only affects the first 16 bytes). That broke full fragment cells (whose
  // delivery instructions live in block 0) while heavily-padded cells survived.
  var ck = ck0;
  final r = I2pCrypto.hkdf(ck, const [], 'SMTunnelReplyKey', 2);
  ck = r[0];
  final replyKey = r[1];
  final l = I2pCrypto.hkdf(ck, const [], 'SMTunnelLayerKey', 2);
  ck = l[0];
  final layerKey = l[1];
  final Uint8List ivKey;
  Uint8List? garlicKey, garlicTag;
  if (isEndpoint) {
    final iv = I2pCrypto.hkdf(ck, const [], 'TunnelLayerIVKey', 2);
    ck = iv[0];
    ivKey = iv[1];
    // endpoint reply is symmetric-garlic-wrapped (i2pd ShortECIESTunnelHopConfig
    // GetGarlicKey): garlicKey = m_CK[32:64], garlicTag = m_CK[0:8] after this HKDF.
    final g = I2pCrypto.hkdf(ck, const [], 'RGarlicKeyAndTag', 2);
    garlicTag = g[0].sublist(0, 8);
    garlicKey = g[1];
  } else {
    ivKey = ck; // chaining key after the layer-key HKDF
  }
  return HopBuildKeys(replyKey, layerKey, ivKey, h,
      garlicKey: garlicKey, garlicTag: garlicTag);
}

// ---- ShortBuildRequestRecord plaintext (154 bytes) ----
const _flagGateway = 0x80; // IBGW
const _flagEndpoint = 0x40; // OBEP

/// Build the 154-byte clear-text short build request record.
Uint8List buildShortRequestPlaintext({
  required int receiveTunnel,
  required int nextTunnel,
  required Uint8List nextIdent, // 32-byte router hash
  required bool isGateway,
  required bool isEndpoint,
  required int sendMsgId,
  int expirationSecs = 600,
}) {
  final p = Uint8List(shortRecordClearTextSize);
  _be32(p, 0, receiveTunnel); // receive tunnel
  _be32(p, 4, nextTunnel); // next tunnel
  p.setRange(8, 40, nextIdent); // next ident (32)
  var flags = 0;
  if (isGateway) flags |= _flagGateway;
  if (isEndpoint) flags |= _flagEndpoint;
  p[40] = flags;
  // 41-42 more flags = 0; 43 layer encryption type = 0 (AES/ChaCha default)
  final minutes = DateTime.now().millisecondsSinceEpoch ~/ 60000;
  _be32(p, 44, minutes); // request time (minutes)
  _be32(p, 48, expirationSecs); // request expiration (seconds)
  _be32(p, 52, sendMsgId); // next/send message id
  // 56-57 options mapping length = 0 (empty mapping)
  p[56] = 0;
  p[57] = 0;
  // remaining bytes are random padding
  final rnd = _rand();
  for (var i = 58; i < shortRecordClearTextSize; i++) {
    p[i] = rnd();
  }
  return p;
}

/// Assemble a ShortTunnelBuild message body: [1-byte record count][records...].
Uint8List buildShortTunnelBuildMessage(List<Uint8List> records) {
  final out = Uint8List(1 + records.length * shortRecordSize);
  out[0] = records.length;
  var off = 1;
  for (final r in records) {
    out.setRange(off, off + shortRecordSize, r);
    off += shortRecordSize;
  }
  return out;
}

void _be32(Uint8List b, int o, int v) {
  b[o] = (v >> 24) & 0xff;
  b[o + 1] = (v >> 16) & 0xff;
  b[o + 2] = (v >> 8) & 0xff;
  b[o + 3] = v & 0xff;
}

int Function() _rand() {
  var s = DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
  return () {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    return (s >> 16) & 0xff;
  };
}

Uint8List _nonce(int counter) {
  final n = Uint8List(12);
  n.setRange(4, 12, I2pCrypto.u64LE(counter));
  return n;
}

Uint8List _cat(Uint8List a, Uint8List b) {
  final out = Uint8List(a.length + b.length);
  out.setRange(0, a.length, a);
  out.setRange(a.length, out.length, b);
  return out;
}
