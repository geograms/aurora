/*
 * RNS AutoInterface — zero-config LAN discovery (wire-compatible, RNS 1.3.5 —
 * RNS/Interfaces/AutoInterface.py).
 *
 * Discovery: each node multicasts a discovery token =
 *   full_hash(group_id + own_link_local_address_string)
 * to an IPv6 link-local multicast group derived from full_hash(group_id), on the
 * discovery port. A receiver authenticates a sender by recomputing
 *   full_hash(group_id + observed_source_address)
 * and, on a match, peers with it. Thereafter packets flow as raw RNS packets,
 * one per UDP datagram, unicast to each peer's link-local address on the data
 * port (the [RnsUdpInterface] data-plane model).
 *
 * Defaults (RNS): group_id "reticulum", discovery_port 29716, data_port 42671,
 * multicast group ff12:0:<g3g2>:<g5g4>:<g7g6>:<g9g8>:<g11g10>:<g13g12> (temporary
 * address type, link scope) where g = full_hash(group_id).
 *
 * NOTE: genuine peering requires two nodes with DISTINCT link-local addresses
 * (two hosts / NICs); two processes on one host share the host's link-local and
 * classify each other as a self multicast-echo, so single-host peering is not
 * possible. The discovery-token and group derivations here are byte-identical to
 * the reference (vector-tested); the data plane reuses the proven UDP path.
 */
import 'dart:typed_data';

import 'rns_crypto.dart';

const String kRnsDefaultGroupId = 'reticulum';
const int kRnsDiscoveryPort = 29716;
const int kRnsDataPort = 42671;

/// AutoInterface discovery helpers (group address + peering token), split out so
/// they can be unit/vector-tested independently of live sockets.
class RnsAutoDiscovery {
  final Uint8List groupId;
  late final Uint8List groupHash;

  /// multicast_address_type: "1" temporary (RNS default). scope: "2" link.
  final String multicastAddressType;
  final String discoveryScope;

  RnsAutoDiscovery({
    String groupId = kRnsDefaultGroupId,
    this.multicastAddressType = '1',
    this.discoveryScope = '2', // SCOPE_LINK
  }) : groupId = Uint8List.fromList(groupId.codeUnits) {
    groupHash = RnsCrypto.fullHash(this.groupId);
  }

  /// The IPv6 multicast discovery address, derived from the group hash exactly
  /// as RNS does: "ff"+type+scope+":0:"+ six 16-bit big-endian hex groups from
  /// group_hash bytes [2..13].
  String multicastAddress() {
    final g = groupHash;
    // Match RNS "{:02x}" — minimum two hex digits (values can be up to 4).
    String grp(int hi, int lo) =>
        (g[lo] + (g[hi] << 8)).toRadixString(16).padLeft(2, '0');
    final gt = StringBuffer('0');
    gt.write(':${grp(2, 3)}');
    gt.write(':${grp(4, 5)}');
    gt.write(':${grp(6, 7)}');
    gt.write(':${grp(8, 9)}');
    gt.write(':${grp(10, 11)}');
    gt.write(':${grp(12, 13)}');
    return 'ff$multicastAddressType$discoveryScope:$gt';
  }

  /// Discovery/peering token a node multicasts for its own [linkLocalAddress],
  /// and which a receiver recomputes from the observed source address to
  /// authenticate the peer.
  Uint8List peeringToken(String linkLocalAddress) =>
      RnsCrypto.fullHash([...groupId, ...linkLocalAddress.codeUnits]);

  /// Authenticate an inbound token against the observed [sourceAddress].
  bool authenticate(Uint8List token, String sourceAddress) =>
      RnsCrypto.constantTimeEquals(token, peeringToken(sourceAddress));
}
