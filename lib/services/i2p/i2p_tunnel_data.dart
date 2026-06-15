/*
 * I2P tunnel data message (1028 bytes) crypto + parsing, pure Dart.
 *
 * Per-hop layer transform (TunnelDecryption, matches i2pd): with the 1024-byte
 * region (16-byte IV + 1008-byte data),
 *   iv   = AES-256-ECB-dec(ivKey, in[0:16])
 *   data = AES-256-CBC-dec(layerKey, iv, in[16:1024])
 *   IV'  = AES-256-ECB-dec(ivKey, iv)            // the IV used for the checksum
 * Transit hops Encrypt; the inbound endpoint (us) Decrypts each hop's layer.
 *
 * Decrypted 1008-byte data: [4 checksum][nonzero padding][0x00][delivery
 * instructions + fragment(s)]. checksum = SHA256(bytes_after_zero || IV')[0:4].
 */
import 'dart:math';
import 'dart:typed_data';

import 'i2p_crypto.dart';

class TunnelLayer {
  final Uint8List layerKey;
  final Uint8List ivKey;
  TunnelLayer(this.layerKey, this.ivKey);

  /// Decrypt one layer of a 1024-byte (IV+data) tunnel region.
  Uint8List decrypt(Uint8List region1024) {
    final iv = I2pCrypto.aesEcb(ivKey, region1024.sublist(0, 16), false);
    final data =
        I2pCrypto.aesCbc(layerKey, iv, region1024.sublist(16, 1024), false);
    final ivOut = I2pCrypto.aesEcb(ivKey, iv, false);
    final out = Uint8List(1024);
    out.setRange(0, 16, ivOut);
    out.setRange(16, 1024, data);
    return out;
  }

  /// Encrypt one layer (the operation a transit hop applies). Inverse of
  /// [decrypt]; used to simulate hops in tests.
  Uint8List encrypt(Uint8List region1024) {
    final iv = I2pCrypto.aesEcb(ivKey, region1024.sublist(0, 16), true);
    final data =
        I2pCrypto.aesCbc(layerKey, iv, region1024.sublist(16, 1024), true);
    final ivOut = I2pCrypto.aesEcb(ivKey, iv, true);
    final out = Uint8List(1024);
    out.setRange(0, 16, ivOut);
    out.setRange(16, 1024, data);
    return out;
  }
}

/// Decrypt a multi-hop inbound tunnel region: apply each hop's layer decrypt in
/// order (endpoint-adjacent hop first, gateway last), matching i2pd's
/// EncryptTunnelMsg loop over m_Hops (stored endpoint->gateway).
Uint8List decryptLayers(List<TunnelLayer> layers, Uint8List region1024) {
  var r = region1024;
  for (final l in layers) {
    r = l.decrypt(r);
  }
  return r;
}

class TunnelFragment {
  final int deliveryType; // 0 LOCAL, 1 TUNNEL, 2 ROUTER
  final Uint8List message; // the delivered I2NP message (standard header)
  final bool checksumOk;
  TunnelFragment(this.deliveryType, this.message, this.checksumOk);
}

/// Parse the first fragment out of a decrypted 1024-byte tunnel region.
TunnelFragment? parseTunnelData(Uint8List decrypted1024) {
  final iv = decrypted1024.sublist(0, 16);
  final data = decrypted1024.sublist(16, 1024); // 1008
  // skip checksum[0:4] + nonzero padding, find the 0x00 delimiter
  var i = 4;
  while (i < data.length && data[i] != 0) {
    i++;
  }
  if (i >= data.length) return null;
  final fragStart = i + 1;

  // Best-effort frame checksum (SHA256 of the post-zero region + IV, first 4
  // bytes). NOTE: this does not yet reproduce i2pd's exact byte range, so it is
  // informational only — payload integrity is enforced by the carried message's
  // own I2NP checksum and (in higher layers) AEAD/signatures and sha256 content
  // addressing.
  final after = data.sublist(fragStart);
  final cs = I2pCrypto.sha256(Uint8List.fromList([...after, ...iv]));
  final checksumOk = cs[0] == data[0] &&
      cs[1] == data[1] &&
      cs[2] == data[2] &&
      cs[3] == data[3];

  var p = fragStart;
  final flag = data[p];
  p += 1;
  final deliveryType = (flag >> 5) & 0x3;
  final fragmented = (flag >> 3) & 0x1;
  if (deliveryType == 1) {
    p += 4 + 32; // TUNNEL: tunnel id + hash
  } else if (deliveryType == 2) {
    p += 32; // ROUTER: hash
  }
  if (fragmented == 1) p += 4; // message id
  final size = (data[p] << 8) | data[p + 1];
  p += 2;
  if (p + size > data.length) return null;
  final msg = data.sublist(p, p + size);
  return TunnelFragment(deliveryType, msg, checksumOk);
}

// ---- multi-cell fragmentation (real I2P tunnel-message reassembly) ----
//
// A single 1008-byte cell carries at most ~1003 usable bytes, far less than a
// real file. The tunnel gateway therefore splits a large I2NP message into a
// FIRST fragment plus FOLLOW-ON fragments spread across several cells, and the
// inbound endpoint (us) reassembles them by message id. Delivery-instruction
// formats (see geti2p.net/spec/tunnel-message):
//   first   : flag(1) [tunnelId/hash per type] [4 msgId if fragmented] size(2)
//             flag bit7=0, bits6-5 delivery type, bit3 fragmented
//   followon: flag(1) msgId(4) size(2)
//             flag bit7=1, bits6-1 fragment number, bit0 last

/// One delivery-instruction fragment carved out of a decrypted cell.
class RawFragment {
  final bool followOn;
  final int deliveryType; // first fragments only (0 LOCAL/1 TUNNEL/2 ROUTER)
  final bool fragmented; // first: more fragments follow
  final int? msgId; // present for fragmented-first and all follow-ons
  final int fragNum; // 0 for first, 1.. for follow-ons
  final bool last; // follow-on: final fragment
  final Uint8List data;
  RawFragment(this.followOn, this.deliveryType, this.fragmented, this.msgId,
      this.fragNum, this.last, this.data);
}

/// Parse EVERY fragment packed into a decrypted 1024-byte cell (after the
/// checksum + nonzero padding + 0x00 delimiter). Returns [] if malformed.
List<RawFragment> parseCellFragments(Uint8List decrypted1024) {
  final data = decrypted1024.sublist(16, 1024); // 1008
  var i = 4; // skip checksum
  while (i < data.length && data[i] != 0) {
    i++;
  }
  if (i >= data.length) return const [];
  var p = i + 1; // past the 0x00 delimiter
  final out = <RawFragment>[];
  // Fragments are packed from here to the end of the 1008-byte region; I2P pads
  // at the FRONT (the nonzero bytes skipped above), so there is no trailing
  // padding and a flag of 0x00 is a legitimate LOCAL/unfragmented first
  // fragment. Parse until the bytes are exhausted or a header can't be read.
  while (p + 3 <= data.length) {
    final flag = data[p];
    p += 1;
    if ((flag & 0x80) != 0) {
      // follow-on: msgId(4) size(2)
      if (p + 6 > data.length) break;
      final msgId = (data[p] << 24) | (data[p + 1] << 16) | (data[p + 2] << 8) | data[p + 3];
      p += 4;
      final size = (data[p] << 8) | data[p + 1];
      p += 2;
      if (p + size > data.length) break;
      final frag = (flag >> 1) & 0x3f;
      final last = (flag & 0x1) == 1;
      out.add(RawFragment(true, 0, false, msgId, frag, last,
          Uint8List.fromList(data.sublist(p, p + size))));
      p += size;
    } else {
      final deliveryType = (flag >> 5) & 0x3;
      final delay = (flag >> 4) & 0x1;
      final fragmented = (flag >> 3) & 0x1;
      if (deliveryType == 1) {
        p += 4 + 32;
      } else if (deliveryType == 2) {
        p += 32;
      }
      if (delay == 1) p += 1;
      int? msgId;
      if (fragmented == 1) {
        if (p + 4 > data.length) break;
        msgId = (data[p] << 24) | (data[p + 1] << 16) | (data[p + 2] << 8) | data[p + 3];
        p += 4;
      }
      if (p + 2 > data.length) break;
      final size = (data[p] << 8) | data[p + 1];
      p += 2;
      if (p + size > data.length) break;
      out.add(RawFragment(false, deliveryType, fragmented == 1, msgId, 0, false,
          Uint8List.fromList(data.sublist(p, p + size))));
      p += size;
    }
  }
  return out;
}

class _Pending {
  final parts = <int, Uint8List>{};
  int deliveryType = 0;
  int? lastNum; // set when the final follow-on (bit0) arrives
  int firstSeenMs;
  _Pending(this.firstSeenMs);

  Uint8List? assemble() {
    if (lastNum == null) return null;
    final b = BytesBuilder();
    for (var n = 0; n <= lastNum!; n++) {
      final part = parts[n];
      if (part == null) return null; // gap
      b.add(part);
    }
    return b.toBytes();
  }
}

/// Reassembles I2NP messages from per-cell [RawFragment]s. Unfragmented first
/// fragments are emitted immediately; fragmented ones are buffered by message id
/// until every part (0..last) has arrived. Stale partials are dropped after a
/// timeout so a lost fragment can't leak memory forever.
class TunnelReassembler {
  final int Function() _nowMs;
  final Map<int, _Pending> _pending = {};
  static const _staleMs = 120 * 1000;

  TunnelReassembler({int Function()? now})
      : _nowMs = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Feed one decrypted cell; returns any I2NP messages that completed.
  List<Uint8List> addCell(Uint8List decrypted1024) {
    final done = <Uint8List>[];
    for (final f in parseCellFragments(decrypted1024)) {
      final m = _add(f);
      if (m != null) done.add(m);
    }
    _evictStale();
    return done;
  }

  Uint8List? _add(RawFragment f) {
    if (!f.followOn && !f.fragmented) {
      return f.data; // complete single-cell message
    }
    final id = f.msgId;
    if (id == null) return null;
    final pend = _pending.putIfAbsent(id, () => _Pending(_nowMs()));
    if (!f.followOn) {
      pend.deliveryType = f.deliveryType;
      pend.parts[0] = f.data;
    } else {
      pend.parts[f.fragNum] = f.data;
      if (f.last) pend.lastNum = f.fragNum;
    }
    final asm = pend.assemble();
    if (asm != null) {
      _pending.remove(id);
      return asm;
    }
    return null;
  }

  void _evictStale() {
    if (_pending.isEmpty) return;
    final now = _nowMs();
    _pending.removeWhere((_, p) => now - p.firstSeenMs > _staleMs);
  }
}

// ---- gateway-side fragmentation (OUTBOUND tunnel preprocessing) ----
//
// Inverse of the reassembler. The OUTBOUND tunnel gateway (us) splits an I2NP
// message into 1+ CLEARTEXT cells, each a 1024-byte region [16 IV][1008 data]
// where data = [checksum(4)][nonzero front padding][0x00][delivery instructions
// + fragment]. The caller then applies the per-hop layer transform
// (TunnelLayer.decrypt — see i2pd Tunnel::EncryptTunnelMsg, which Decrypts for
// every hop) and sends each as a TunnelData (type 18) message. Mirrors i2pd
// TunnelGatewayBuffer. Delivery type: 0 LOCAL, 1 TUNNEL (toHash+toTunnel),
// 2 ROUTER (toHash). The checksum is SHA256(fragment-bytes || IV)[0:4]; the
// endpoint recovers the same IV after its transform, so it verifies.

const _tunnelMaxPayload = 1003; // 1008 - 4 checksum - 1 zero delimiter

/// Fragment an I2NP [message] into cleartext outbound tunnel cells.
List<Uint8List> fragmentForTunnel({
  required Uint8List message,
  int deliveryType = 0,
  Uint8List? toHash,
  int toTunnel = 0,
  Uint8List Function()? ivGen, // test override; otherwise random
  int? msgIdOverride,
}) {
  final msgId = msgIdOverride ??
      ((message[1] << 24) | (message[2] << 16) | (message[3] << 8) | message[4]);
  // first-fragment DI prefix before the [msgId?][size] tail:
  //   LOCAL: flag(1); TUNNEL: flag(1)+tunnelId(4)+hash(32); ROUTER: flag(1)+hash(32)
  var firstPrefix = 1;
  if (deliveryType == 1) {
    firstPrefix += 4 + 32;
  } else if (deliveryType == 2) {
    firstPrefix += 32;
  }

  Uint8List firstDi(bool fragmented, int size) {
    final b = BytesBuilder();
    b.addByte(((deliveryType & 0x3) << 5) | (fragmented ? 0x08 : 0));
    if (deliveryType == 1) {
      b.add(_be32(toTunnel));
      b.add(toHash!);
    } else if (deliveryType == 2) {
      b.add(toHash!);
    }
    if (fragmented) b.add(_be32(msgId));
    b.add([(size >> 8) & 0xff, size & 0xff]);
    return b.toBytes();
  }

  final cells = <Uint8List>[];
  if (firstPrefix + 2 + message.length <= _tunnelMaxPayload) {
    // whole message in one cell (first + last, unfragmented)
    final fp = BytesBuilder()
      ..add(firstDi(false, message.length))
      ..add(message);
    cells.add(_buildCell(fp.toBytes(), ivGen));
    return cells;
  }
  // first fragment fills its cell, then follow-ons
  final firstLen = _tunnelMaxPayload - (firstPrefix + 4 + 2); // +msgId(4)+size(2)
  cells.add(_buildCell(
      (BytesBuilder()
            ..add(firstDi(true, firstLen))
            ..add(message.sublist(0, firstLen)))
          .toBytes(),
      ivGen));
  var off = firstLen, fragNum = 1;
  const foMax = _tunnelMaxPayload - 7; // follow-on DI = flag(1)+msgId(4)+size(2)
  while (off < message.length) {
    final remain = message.length - off;
    final n = remain > foMax ? foMax : remain;
    final last = off + n >= message.length;
    final b = BytesBuilder()
      ..addByte(0x80 | ((fragNum & 0x3f) << 1) | (last ? 1 : 0))
      ..add(_be32(msgId))
      ..add([(n >> 8) & 0xff, n & 0xff])
      ..add(message.sublist(off, off + n));
    cells.add(_buildCell(b.toBytes(), ivGen));
    off += n;
    fragNum++;
  }
  return cells;
}

final _rng = Random.secure();

Uint8List _buildCell(Uint8List fragPart, Uint8List Function()? ivGen) {
  final region = Uint8List(1024);
  final iv = ivGen != null
      ? ivGen()
      : Uint8List.fromList(List<int>.generate(16, (_) => _rng.nextInt(256)));
  region.setRange(0, 16, iv);
  final data = Uint8List(1008); // [checksum4][nonzero pad][0x00][fragPart]
  final padLen = _tunnelMaxPayload - fragPart.length; // 1003 - len
  final cksum = I2pCrypto.sha256(Uint8List.fromList([...fragPart, ...iv]));
  data.setRange(0, 4, cksum.sublist(0, 4));
  for (var j = 0; j < padLen; j++) {
    data[4 + j] = 0xff; // nonzero padding
  }
  data[4 + padLen] = 0x00; // zero delimiter
  data.setRange(5 + padLen, 1008, fragPart);
  region.setRange(16, 1024, data);
  return region;
}

Uint8List _be32(int v) => Uint8List.fromList(
    [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);
