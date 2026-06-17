/*
 * RNS packet codec (wire-compatible, RNS 1.3.5 — RNS/Packet.py).
 *
 * Header (HEADER_1): flags(1) + hops(1) + dest_hash(16) + context(1) + data
 * Header (HEADER_2): flags(1) + hops(1) + transport_id(16) + dest_hash(16) +
 *                    context(1) + data
 *   flags = (header_type<<6)|(context_flag<<5)|(transport_type<<4)|
 *           (dest_type<<2)|packet_type
 *
 * For DATA packets to a SINGLE destination the data field is the encrypted
 * token; for ANNOUNCE / LINKREQUEST / link-proof packets it is carried as-is
 * (announce data is plaintext-signed; link material is its own ciphertext).
 */
import 'dart:typed_data';

import 'rns_crypto.dart';

/// RNS MTU (RNS/Reticulum.py).
const int kRnsMtu = 500;
const int kRnsDestHashBytes = 16;

class RnsPacketType {
  static const int data = 0x00;
  static const int announce = 0x01;
  static const int linkRequest = 0x02;
  static const int proof = 0x03;
}

class RnsHeaderType {
  static const int header1 = 0x00;
  static const int header2 = 0x01;
}

class RnsTransportType {
  static const int broadcast = 0x00;
  static const int transport = 0x01;
}

class RnsDestType {
  static const int single = 0x00;
  static const int group = 0x01;
  static const int plain = 0x02;
  static const int link = 0x03;
}

/// Packet contexts (RNS/Packet.py). Only the ones we use are named.
class RnsContext {
  static const int none = 0x00;
  static const int resource = 0x01;
  static const int resourceAdv = 0x02;
  static const int resourceReq = 0x03;
  static const int resourceHmu = 0x04;
  static const int resourcePrf = 0x05;
  static const int pathResponse = 0x0B;
  static const int keepalive = 0xFA;
  static const int linkClose = 0xFC;
  static const int lrrtt = 0xFE;
  static const int lrproof = 0xFF;
}

class RnsFlag {
  static const int set = 0x01;
  static const int unset = 0x00;
}

/// A parsed or to-be-built RNS packet.
class RnsPacket {
  int headerType;
  int contextFlag;
  int transportType;
  int destType;
  int packetType;
  int hops;
  Uint8List? transportId; // 16B, only for HEADER_2
  Uint8List destHash; // 16B
  int context;
  Uint8List data;

  RnsPacket({
    required this.destHash,
    required this.data,
    this.headerType = RnsHeaderType.header1,
    this.contextFlag = RnsFlag.unset,
    this.transportType = RnsTransportType.broadcast,
    this.destType = RnsDestType.single,
    this.packetType = RnsPacketType.data,
    this.hops = 0,
    this.transportId,
    this.context = RnsContext.none,
  });

  int get _flags =>
      (headerType << 6) |
      (contextFlag << 5) |
      (transportType << 4) |
      (destType << 2) |
      packetType;

  /// Serialize to wire bytes (RNS/Packet.py pack). For announce/link packets the
  /// caller has already placed the correct bytes in [data]; this does not
  /// encrypt.
  Uint8List pack() {
    final b = BytesBuilder();
    b.addByte(_flags);
    b.addByte(hops);
    if (headerType == RnsHeaderType.header2) {
      b.add(transportId ?? Uint8List(kRnsDestHashBytes));
    }
    b.add(destHash);
    b.addByte(context);
    b.add(data);
    final raw = b.toBytes();
    if (raw.length > kRnsMtu) {
      throw StateError('Packet size ${raw.length} exceeds MTU $kRnsMtu');
    }
    return raw;
  }

  /// Packet hash = SHA-256(hashable_part), hashable_part = [flags & 0x0F] +
  /// (HEADER_2 ? raw[18:] : raw[2:]). Used for transport dedup / announce ids.
  Uint8List packetHash() {
    final raw = pack();
    final hashable = BytesBuilder()..addByte(raw[0] & 0x0F);
    final skip = headerType == RnsHeaderType.header2
        ? kRnsDestHashBytes + 2
        : 2;
    hashable.add(Uint8List.sublistView(raw, skip));
    return RnsCrypto.fullHash(hashable.toBytes());
  }

  /// Parse wire bytes (RNS/Packet.py unpack). Returns null on malformed input.
  static RnsPacket? parse(Uint8List raw) {
    if (raw.length < 2 + kRnsDestHashBytes + 1) return null;
    final flags = raw[0];
    final hops = raw[1];
    final headerType = (flags & 0x40) >> 6;
    final contextFlag = (flags & 0x20) >> 5;
    final transportType = (flags & 0x10) >> 4;
    final destType = (flags & 0x0C) >> 2;
    final packetType = flags & 0x03;
    const dl = kRnsDestHashBytes;

    try {
      if (headerType == RnsHeaderType.header2) {
        if (raw.length < 2 + 2 * dl + 1) return null;
        return RnsPacket(
          headerType: headerType,
          contextFlag: contextFlag,
          transportType: transportType,
          destType: destType,
          packetType: packetType,
          hops: hops,
          transportId: Uint8List.fromList(raw.sublist(2, dl + 2)),
          destHash: Uint8List.fromList(raw.sublist(dl + 2, 2 * dl + 2)),
          context: raw[2 * dl + 2],
          data: Uint8List.fromList(raw.sublist(2 * dl + 3)),
        );
      } else {
        return RnsPacket(
          headerType: headerType,
          contextFlag: contextFlag,
          transportType: transportType,
          destType: destType,
          packetType: packetType,
          hops: hops,
          destHash: Uint8List.fromList(raw.sublist(2, dl + 2)),
          context: raw[dl + 2],
          data: Uint8List.fromList(raw.sublist(dl + 3)),
        );
      }
    } catch (_) {
      return null;
    }
  }
}
