/// Deriving an XPRS packet's identifier.
///
/// `docs/XPRS.md` section 5: every packet has one, and it is never transmitted.
///
/// ```
/// id = first 6 hex characters of sha256(the packet, with sig: and via: removed)
/// ```
///
/// Two fields come out before hashing, and which two is the whole design. A
/// signature is applied after the packet exists, and `via:` is appended by every
/// relay that touches it — so leaving either in would give the same message a
/// different identity at every hop, and dedup, replies, reactions and history
/// replay all depend on it staying the same.
library;

import '../../util/nostr_crypto.dart';

import 'xprs_packet.dart';

/// Fields excluded from the hash: added or changed after authorship.
const Set<String> kIdExcluded = {'sig', 'via'};

/// The six-character identifier of [p].
String xprsIdentifier(XprsPacket p) =>
    NostrCrypto.sha256Hash(p.without(kIdExcluded).encode()).substring(0, 6);

/// The identifier of a packet still in wire form, or null if it does not parse.
String? xprsIdentifierOf(String wire) {
  final p = XprsPacket.parse(wire);
  return p == null ? null : xprsIdentifier(p);
}
