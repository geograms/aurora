/*
 * Kademlia-style DHT over Reticulum — keyspace primitives + node contacts.
 *
 * The DHT indexes "who provides which file": sha256 -> signed provider records.
 * It runs on backbone nodes (reliable / well-connected); edge clients query it
 * recursively via an entry node (see DhtNode.resolve). Keyspace is Reticulum's
 * native 128 bits: a node's id is its DHT destination hash
 * (RnsDestination.hash(identity, 'geogram', ['dht'])), and a file's routing key is
 * the first 128 bits of its sha256. Distance is XOR; the k nodes closest to a
 * file key custody that file's provider records.
 */
import 'dart:typed_data';

import '../../reticulum/rns_identity.dart';

const String kDhtApp = 'geogram';
const List<String> kDhtAspects = ['dht'];
const int kDhtIdLen = 16; // 128-bit ids (Reticulum destination-hash width)
// Caps so a NODES/VALUE reply fits ONE link-encrypted packet (~450B plaintext;
// a contact pubkey is 64B, a record ~176B). Larger replies would need framing.
const int kDhtWireMaxContacts = 5;
const int kDhtWireMaxRecords = 2;

/// XOR distance between two ids (both [kDhtIdLen] bytes).
Uint8List dhtXor(Uint8List a, Uint8List b) {
  final out = Uint8List(kDhtIdLen);
  for (var i = 0; i < kDhtIdLen; i++) {
    out[i] = a[i] ^ b[i];
  }
  return out;
}

/// Compare two distances (big-endian): -1 if `a < b`, 0 if equal, 1 if `a > b`.
int dhtCompare(Uint8List a, Uint8List b) {
  for (var i = 0; i < kDhtIdLen; i++) {
    if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return 0;
}

bool dhtIdEquals(Uint8List a, Uint8List b) => dhtCompare(a, b) == 0;

/// Leading zero bits of a distance (0..128). Used to pick the k-bucket: closer
/// nodes share a longer prefix => more leading zeros => a higher bucket index.
int dhtLeadingZeros(Uint8List d) {
  var n = 0;
  for (final b in d) {
    if (b == 0) {
      n += 8;
      continue;
    }
    var x = b;
    while ((x & 0x80) == 0) {
      n++;
      x = (x << 1) & 0xff;
    }
    break;
  }
  return n;
}

/// The 16-byte routing key for a file (first 128 bits of its 32-byte sha256).
Uint8List dhtFileKey(Uint8List sha256) =>
    Uint8List.fromList(sha256.sublist(0, kDhtIdLen));

String dhtHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// A known DHT node: its public identity (to open links / verify) and its id
/// (its DHT destination hash, derived from the identity).
class DhtContact {
  final RnsIdentity identity; // public identity (64B key)
  final Uint8List id; // DHT destination hash (16B)
  DateTime lastSeen;

  DhtContact._(this.identity, this.id, this.lastSeen);

  /// Build a contact from a 64-byte public key (as carried in DHT messages).
  factory DhtContact.fromPublicKey(Uint8List pub64, {DateTime? seen}) {
    final id = RnsIdentity.fromPublicKey(pub64);
    final destHash = RnsDestination.hash(id, kDhtApp, kDhtAspects);
    return DhtContact._(id, destHash, seen ?? DateTime.now());
  }

  /// Build a contact for a local/known identity.
  factory DhtContact.ofIdentity(RnsIdentity identity, {DateTime? seen}) {
    final pubOnly = RnsIdentity.fromPublicKey(identity.getPublicKey());
    final destHash = RnsDestination.hash(pubOnly, kDhtApp, kDhtAspects);
    return DhtContact._(pubOnly, destHash, seen ?? DateTime.now());
  }

  Uint8List get publicKey => identity.getPublicKey();
  String get idHex => dhtHex(id);
}
