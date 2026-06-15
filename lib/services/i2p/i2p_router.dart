/*
 * Our own I2P router identity + RouterInfo, pure Dart.
 *
 * Builds a modern RouterIdentity (ECIES-X25519 crypto key + Ed25519 signing
 * key, KeyCertificate type 5) and a signed RouterInfo containing a single
 * NTCP2 address that carries our static key 's'. We are an outbound-only
 * client for Phase 0, so the address has no host/port (we are not reachable
 * inbound) — it exists so the router we connect to can match the static key
 * we present in the NTCP2 SessionConfirmed (message 3) against our RouterInfo.
 *
 * Byte layout (I2P Common Structures):
 *   RouterIdentity = pubkey[256] + signingkey[128] + certificate
 *     - X25519 static key (32B) at offset 0 of the 256B field, rest padding
 *     - Ed25519 signing key (32B) at the END of the 128B field, rest padding
 *     - KeyCertificate: type=5, len=4, sigType=7 (Ed25519), cryptoType=4 (X25519)
 *   RouterInfo = identity + date[8] + addrCount[1] + addresses
 *                + peer_size[1]=0 + options(Mapping) + signature[64]
 *   Signature (Ed25519) covers identity..options (everything but the signature).
 */
import 'dart:math';
import 'dart:typed_data';

import 'i2p_crypto.dart';

/// Encode an I2P Mapping: 2-byte BE length, then sorted key=value; pairs.
Uint8List encodeMapping(Map<String, String> opts) {
  final keys = opts.keys.toList()..sort();
  final body = BytesBuilder();
  for (final k in keys) {
    final kb = Uint8List.fromList(k.codeUnits);
    final vb = Uint8List.fromList(opts[k]!.codeUnits);
    body.addByte(kb.length);
    body.add(kb);
    body.addByte(0x3d); // '='
    body.addByte(vb.length);
    body.add(vb);
    body.addByte(0x3b); // ';'
  }
  final bytes = body.toBytes();
  final out = BytesBuilder();
  out.addByte((bytes.length >> 8) & 0xff);
  out.addByte(bytes.length & 0xff);
  out.add(bytes);
  return out.toBytes();
}

Uint8List _u64BE(int v) {
  final out = Uint8List(8);
  for (var i = 7; i >= 0; i--) {
    out[i] = v & 0xff;
    v >>= 8;
  }
  return out;
}

/// I2P base64 alphabet ('-' and '~' for '+' and '/'), no padding.
String i2pBase64Encode(Uint8List data) {
  const std =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final sb = StringBuffer();
  var i = 0;
  for (; i + 3 <= data.length; i += 3) {
    final n = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
    sb.write(std[(n >> 18) & 63]);
    sb.write(std[(n >> 12) & 63]);
    sb.write(std[(n >> 6) & 63]);
    sb.write(std[n & 63]);
  }
  final rem = data.length - i;
  if (rem == 1) {
    final n = data[i] << 16;
    sb.write(std[(n >> 18) & 63]);
    sb.write(std[(n >> 12) & 63]);
    sb.write('==');
  } else if (rem == 2) {
    final n = (data[i] << 16) | (data[i + 1] << 8);
    sb.write(std[(n >> 18) & 63]);
    sb.write(std[(n >> 12) & 63]);
    sb.write(std[(n >> 6) & 63]);
    sb.write('=');
  }
  return sb.toString().replaceAll('+', '-').replaceAll('/', '~');
}

/// Build a 391-byte KeysAndCert (RouterIdentity / Destination): a 256-byte
/// public key field with the X25519 key at the front, a 128-byte signing field
/// with the Ed25519 key at the end, then a KeyCertificate (sigType 7 Ed25519,
/// cryptoType 4 X25519). Used for both our router identity and a destination.
Uint8List buildKeysAndCert(Uint8List x25519Pub, Uint8List ed25519Pub) {
  final b = BytesBuilder();
  final pubField = Uint8List(256);
  pubField.setRange(0, 32, x25519Pub);
  b.add(pubField);
  final signField = Uint8List(128);
  signField.setRange(96, 128, ed25519Pub);
  b.add(signField);
  b.add(Uint8List.fromList([5, 0x00, 0x04, 0x00, 0x07, 0x00, 0x04]));
  return b.toBytes();
}

class OurRouter {
  final Uint8List staticPriv; // X25519 private (32)
  final Uint8List staticPub; // X25519 public (32) — the NTCP2 's'
  final Uint8List signPriv; // Ed25519 seed (32)
  final Uint8List signPub; // Ed25519 public (32)
  final Uint8List identity; // serialized RouterIdentity
  final Uint8List identityHash; // SHA-256(identity)
  final Uint8List routerInfo; // serialized + signed RouterInfo

  OurRouter._(this.staticPriv, this.staticPub, this.signPriv, this.signPub,
      this.identity, this.identityHash, this.routerInfo);

  static Future<OurRouter> generate({int netId = 2}) async {
    final rnd = Random.secure();
    final s = await I2pCrypto.x25519Generate();
    final sign = await I2pCrypto.ed25519Generate();

    // ---- RouterIdentity ----
    final identityBytes = buildKeysAndCert(s.pub, sign.pub);
    final identityHash = I2pCrypto.sha256(identityBytes);

    // ---- RouterInfo (unsigned part) ----
    final ri = BytesBuilder();
    ri.add(identityBytes);
    ri.add(_u64BE(DateTime.now().millisecondsSinceEpoch)); // published

    ri.addByte(1); // address count
    // NTCP2 address: no host/port (outbound-only), carries static key 's'.
    ri.addByte(0); // cost
    ri.add(Uint8List(8)); // expiration (all zero)
    const style = 'NTCP2';
    ri.addByte(style.length);
    ri.add(Uint8List.fromList(style.codeUnits));
    ri.add(encodeMapping({
      's': i2pBase64Encode(s.pub),
      'v': '2',
    }));

    ri.addByte(0); // peer_size
    ri.add(encodeMapping({
      'caps': 'L',
      'netId': '$netId',
      'router.version': '0.9.63',
    }));

    final unsigned = ri.toBytes();
    final sig = await I2pCrypto.ed25519Sign(sign.priv, unsigned);

    final full = BytesBuilder();
    full.add(unsigned);
    full.add(sig);

    // silence unused warning for rnd if reserved for future padding
    rnd.nextInt(1);
    return OurRouter._(s.priv, s.pub, sign.priv, sign.pub, identityBytes,
        identityHash, full.toBytes());
  }
}
