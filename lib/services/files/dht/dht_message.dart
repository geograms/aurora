/*
 * DHT RPC messages (binary wire format) for transport over Reticulum links.
 *
 * Every message carries the sender's 64-byte public key so the receiver can
 * learn the sender as a contact and reply. Requests: PING, FIND_NODE(target),
 * FIND_VALUE(sha256), STORE(record). Responses: PONG, NODES(contacts),
 * VALUE(records | nodes), STORE_OK(ok).
 */
import 'dart:typed_data';

import 'dht_core.dart';
import 'provider_record.dart';

class DhtOp {
  static const int ping = 0x01;
  static const int findNode = 0x02;
  static const int findValue = 0x03;
  static const int store = 0x04;
  static const int pong = 0x81;
  static const int nodes = 0x82;
  static const int value = 0x83;
  static const int storeOk = 0x84;
}

class DhtMessage {
  final int op;
  final Uint8List senderPub; // 64B
  Uint8List? target; // 16B (FIND_NODE)
  Uint8List? sha; // 32B (FIND_VALUE)
  List<Uint8List> contactPubs = []; // 64B each (NODES / VALUE-as-nodes)
  List<ProviderRecord> records = []; // VALUE-as-records
  bool hasValue = false; // VALUE: records vs nodes
  bool ok = false; // STORE_OK

  DhtMessage(this.op, this.senderPub);

  DhtContact get sender => DhtContact.fromPublicKey(senderPub);
  List<DhtContact> get contacts =>
      contactPubs.map((p) => DhtContact.fromPublicKey(p)).toList();

  static DhtMessage ping(Uint8List senderPub) =>
      DhtMessage(DhtOp.ping, senderPub);
  static DhtMessage pong(Uint8List senderPub) =>
      DhtMessage(DhtOp.pong, senderPub);

  static DhtMessage findNode(Uint8List senderPub, Uint8List target) =>
      DhtMessage(DhtOp.findNode, senderPub)..target = target;

  static DhtMessage nodes(Uint8List senderPub, List<DhtContact> cs) =>
      DhtMessage(DhtOp.nodes, senderPub)
        ..contactPubs = cs.map((c) => c.publicKey).toList();

  static DhtMessage findValue(Uint8List senderPub, Uint8List sha) =>
      DhtMessage(DhtOp.findValue, senderPub)..sha = sha;

  static DhtMessage valueRecords(Uint8List senderPub, List<ProviderRecord> recs) =>
      DhtMessage(DhtOp.value, senderPub)
        ..hasValue = true
        ..records = recs;
  static DhtMessage valueNodes(Uint8List senderPub, List<DhtContact> cs) =>
      DhtMessage(DhtOp.value, senderPub)
        ..hasValue = false
        ..contactPubs = cs.map((c) => c.publicKey).toList();

  static DhtMessage store(Uint8List senderPub, ProviderRecord r) =>
      DhtMessage(DhtOp.store, senderPub)..records = [r];
  static DhtMessage storeOk(Uint8List senderPub, bool ok) =>
      DhtMessage(DhtOp.storeOk, senderPub)..ok = ok;

  Uint8List encode() {
    final b = BytesBuilder()
      ..addByte(op)
      ..add(senderPub);
    switch (op) {
      case DhtOp.findNode:
        b.add(target!);
        break;
      case DhtOp.findValue:
        b.add(sha!);
        break;
      case DhtOp.nodes:
        _putContacts(b, contactPubs);
        break;
      case DhtOp.value:
        b.addByte(hasValue ? 1 : 0);
        if (hasValue) {
          b.addByte(records.length & 0xff);
          for (final r in records) {
            final e = r.encode();
            b.add(_u16(e.length));
            b.add(e);
          }
        } else {
          _putContacts(b, contactPubs);
        }
        break;
      case DhtOp.store:
        final e = records.first.encode();
        b.add(_u16(e.length));
        b.add(e);
        break;
      case DhtOp.storeOk:
        b.addByte(ok ? 1 : 0);
        break;
      default:
        break; // ping/pong: nothing extra
    }
    return b.toBytes();
  }

  static DhtMessage? decode(Uint8List data) {
    try {
      var i = 0;
      final op = data[i++];
      final senderPub = Uint8List.fromList(data.sublist(i, i + 64));
      i += 64;
      final m = DhtMessage(op, senderPub);
      switch (op) {
        case DhtOp.findNode:
          m.target = Uint8List.fromList(data.sublist(i, i + kDhtIdLen));
          break;
        case DhtOp.findValue:
          m.sha = Uint8List.fromList(data.sublist(i, i + 32));
          break;
        case DhtOp.nodes:
          i = _getContacts(data, i, m);
          break;
        case DhtOp.value:
          m.hasValue = data[i++] == 1;
          if (m.hasValue) {
            final n = data[i++];
            for (var k = 0; k < n; k++) {
              final len = (data[i] << 8) | data[i + 1];
              i += 2;
              final r = ProviderRecord.decode(
                  Uint8List.sublistView(data, i, i + len));
              if (r != null) m.records.add(r);
              i += len;
            }
          } else {
            i = _getContacts(data, i, m);
          }
          break;
        case DhtOp.store:
          final len = (data[i] << 8) | data[i + 1];
          i += 2;
          final r = ProviderRecord.decode(Uint8List.sublistView(data, i, i + len));
          if (r == null) return null;
          m.records.add(r);
          break;
        case DhtOp.storeOk:
          m.ok = data[i++] == 1;
          break;
        default:
          break;
      }
      return m;
    } catch (_) {
      return null;
    }
  }

  static void _putContacts(BytesBuilder b, List<Uint8List> pubs) {
    b.addByte(pubs.length & 0xff);
    for (final p in pubs) {
      b.add(p);
    }
  }

  static int _getContacts(Uint8List data, int i, DhtMessage m) {
    final n = data[i++];
    for (var k = 0; k < n; k++) {
      m.contactPubs.add(Uint8List.fromList(data.sublist(i, i + 64)));
      i += 64;
    }
    return i;
  }

  static Uint8List _u16(int v) => Uint8List.fromList([(v >> 8) & 0xff, v & 0xff]);
}
