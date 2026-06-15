/*
 * Minimal I2NP message support for Phase 0: build a DatabaseLookup and parse
 * the DatabaseStore / DatabaseSearchReply replies. Bodies only — the NTCP2
 * short I2NP header (type, msgId, 4-byte expiration) is added by the NTCP2
 * layer when it wraps a body into an I2NP block (block type 3).
 */
import 'dart:math';
import 'dart:typed_data';

import 'i2p_crypto.dart';

class I2npType {
  static const databaseStore = 1;
  static const databaseLookup = 2;
  static const databaseSearchReply = 3;
}

/// DatabaseLookup body for a RouterInfo (RI) lookup with a direct reply (no
/// reply tunnel): key[32] + from[32] + flag[1] + size[2]=0.
///   flag bits: bit0 deliveryFlag=0 (direct), bits3-2 lookup type=10 (RI).
///   => 0b00001000 = 0x08.
Uint8List buildDatabaseLookup(Uint8List key, Uint8List fromHash) {
  final b = BytesBuilder();
  b.add(key);
  b.add(fromHash);
  b.addByte(0x08); // direct reply, RI lookup
  b.addByte(0); // size hi
  b.addByte(0); // size lo (no excluded peers)
  return b.toBytes();
}

/// DatabaseLookup for a LeaseSet (LS lookup, direct reply): flag bits 3-2 = 01.
Uint8List buildLeaseSetLookup(Uint8List key, Uint8List fromHash) {
  final b = BytesBuilder();
  b.add(key);
  b.add(fromHash);
  b.addByte(0x04); // direct reply, LS lookup
  b.addByte(0);
  b.addByte(0);
  return b.toBytes();
}

/// DatabaseStore for a LeaseSet2. [leaseSet2] is the full signed buffer whose
/// first byte is the store type. Header: key(32) + storeType(1) + replyToken(4);
/// with replyToken 0 the leaseset data (including its leading store-type byte)
/// follows immediately. Matches i2pd's CreateDatabaseStoreMsg.
Uint8List buildLeaseSetStore(Uint8List key, Uint8List leaseSet2, int storeType) {
  final b = BytesBuilder();
  b.add(key); // 32
  b.addByte(storeType); // type
  b.add(Uint8List(4)); // reply token = 0
  // The store-type byte is carried only in the header; the leaseset data begins
  // at the Destination. i2pd re-injects the store type at buf[-1] for signature
  // verification, so drop the leading store-type byte from our signed buffer.
  b.add(leaseSet2.sublist(1));
  return b.toBytes();
}

/// A parsed reply we recognise.
class I2npReply {
  final int type;
  final String summary;
  I2npReply(this.type, this.summary);
}

String _hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Parse the body (after the short I2NP header) of a reply message.
I2npReply? parseReply(int type, Uint8List body) {
  try {
    if (type == I2npType.databaseStore) {
      final key = body.sublist(0, 32);
      final t = body[32];
      return I2npReply(type,
          'DatabaseStore key=${_hx(key).substring(0, 16)}... storeType=$t len=${body.length}');
    }
    if (type == I2npType.databaseSearchReply) {
      final key = body.sublist(0, 32);
      final num = body[32];
      final peers = <String>[];
      var p = 33;
      for (var i = 0; i < num && p + 32 <= body.length; i++) {
        peers.add(_hx(body.sublist(p, p + 16)));
        p += 32;
      }
      final from = (p + 32 <= body.length) ? _hx(body.sublist(p, p + 16)) : '?';
      return I2npReply(type,
          'DatabaseSearchReply key=${_hx(key).substring(0, 16)}... peers=$num from=$from...');
    }
    return I2npReply(type, 'I2NP type=$type len=${body.length}');
  } catch (_) {
    return null;
  }
}

int randomMsgId() => Random.secure().nextInt(0x7fffffff) + 1;

/// Build a full I2NP message with the STANDARD 16-byte header (used for messages
/// carried inside tunnels): type(1) + msgId(4) + expiration(8 ms) + size(2) +
/// checksum(1 = first byte of SHA256(body)) + body.
Uint8List buildStandardI2np(int type, int msgId, Uint8List body) {
  final exp = DateTime.now().millisecondsSinceEpoch + 60000;
  final b = BytesBuilder();
  b.addByte(type);
  b.add([(msgId >> 24) & 0xff, (msgId >> 16) & 0xff, (msgId >> 8) & 0xff, msgId & 0xff]);
  final e = Uint8List(8);
  for (var i = 7; i >= 0; i--) {
    e[i] = (exp >> (8 * (7 - i))) & 0xff;
  }
  b.add(e);
  b.add([(body.length >> 8) & 0xff, body.length & 0xff]);
  b.addByte(_sha256First(body));
  b.add(body);
  return b.toBytes();
}

int _sha256First(Uint8List body) => I2pCrypto.sha256(body)[0];

/// DeliveryStatus (type 10) body: msgId(4) + timestamp(8 ms).
Uint8List buildDeliveryStatusBody(int msgId) {
  final ts = DateTime.now().millisecondsSinceEpoch;
  final b = BytesBuilder();
  b.add([(msgId >> 24) & 0xff, (msgId >> 16) & 0xff, (msgId >> 8) & 0xff, msgId & 0xff]);
  final e = Uint8List(8);
  for (var i = 7; i >= 0; i--) {
    e[i] = (ts >> (8 * (7 - i))) & 0xff;
  }
  b.add(e);
  return b.toBytes();
}

/// TunnelGateway (type 19) body: tunnelId(4) + length(2) + I2NP message.
Uint8List buildTunnelGateway(int tunnelId, Uint8List i2npMessage) {
  final b = BytesBuilder();
  b.add([(tunnelId >> 24) & 0xff, (tunnelId >> 16) & 0xff, (tunnelId >> 8) & 0xff, tunnelId & 0xff]);
  b.add([(i2npMessage.length >> 8) & 0xff, i2npMessage.length & 0xff]);
  b.add(i2npMessage);
  return b.toBytes();
}

int readBe32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

/// I2NP Data message (type 20) body: length(4 BE) + data.
Uint8List wrapDataBody(Uint8List data) {
  final b = BytesBuilder();
  b.add([(data.length >> 24) & 0xff, (data.length >> 16) & 0xff,
        (data.length >> 8) & 0xff, data.length & 0xff]);
  b.add(data);
  return b.toBytes();
}

/// Extract the payload from a Data message body (strip the 4-byte length).
Uint8List? unwrapDataBody(Uint8List body) {
  if (body.length < 4) return null;
  final len = readBe32(body, 0);
  if (body.length < 4 + len) return null;
  return body.sublist(4, 4 + len);
}

const i2npData = 20;
