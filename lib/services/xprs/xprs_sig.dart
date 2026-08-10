/// Signing and verifying an XPRS packet.
///
/// `docs/XPRS.md` section 9.1: `sig:` covers the whole packet with the `sig:`
/// and `via:` fields removed, so position is not significant and a verifier
/// reconstructs the signed text by deletion.
///
/// That is the same canonical form the identifier is derived from (section 5),
/// which is not a coincidence: both have to survive relaying, and relaying only
/// ever touches `via:`.
///
/// The crypto is [AprxSign], unchanged. Its 48-byte short-Schnorr signature
/// encodes to exactly 60 base85 characters, which is what the XPRS `base85`
/// value type is (section 4.3) — so this file is a shim over a primitive that
/// already shipped, not a new implementation.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../util/aprx_sign.dart';
import '../../util/nostr_crypto.dart';
import 'xprs_id.dart';
import 'xprs_packet.dart';

/// How a receiver should present the authorship of a packet (section 9.1).
enum XprsSigState {
  /// Signature present, valid, and the signer's key is known.
  verified,

  /// Signature present and invalid. The only state that is evidence of a lie.
  forged,

  /// Signature present but the signer's key is not held, so it cannot be checked.
  unverified,

  /// No signature. Common and legitimate: sensors and small stations do not sign.
  unsigned,
}

/// The canonical text a signature covers: the packet without `sig:` or `via:`.
///
/// Public because a verifier has to reconstruct it, and because disagreeing
/// about it is the kind of bug that only surfaces between two independent
/// implementations — by which time both are deployed.
String xprsSignedText(XprsPacket p) => p.without(kIdExcluded).encode();

/// The digest actually passed to the curve: sha256 of [xprsSignedText].
Uint8List xprsSignedDigest(XprsPacket p) =>
    NostrCrypto.sha256Bytes(Uint8List.fromList(utf8.encode(xprsSignedText(p))));

/// Sign [p] with the private scalar [d], returning the packet with `sig:` set.
///
/// `sig:` is inserted before `m:` when the packet has one, because `m:` must
/// stay last (section 4) — [XprsPacket.with_] already does that.
XprsPacket xprsSign(XprsPacket p, BigInt d) =>
    p.with_('sig', AprxSign.b85encode(AprxSign.sign(xprsSignedDigest(p), d)));

/// Check the `sig:` on [p] against [pubXonly], the signer's 32-byte x-only key.
///
/// Pass a null key for a signer whose key is not held: the result is
/// [XprsSigState.unverified] rather than a guess.
XprsSigState xprsVerify(XprsPacket p, Uint8List? pubXonly) {
  final s = p['sig'];
  if (s == null) return XprsSigState.unsigned;
  if (pubXonly == null) return XprsSigState.unverified;

  final sig = AprxSign.b85decode(s);
  if (sig == null || sig.length != 48) return XprsSigState.forged;

  return AprxSign.verify(xprsSignedDigest(p), sig, pubXonly)
      ? XprsSigState.verified
      : XprsSigState.forged;
}
