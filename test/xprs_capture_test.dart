/*
 * A real signature captured off APRS-IS from a physical station.
 *
 * This used to assert that the signature VERIFIES, and it did -- it was the
 * only evidence in the tree that a device on the air, not a test fixture, had
 * produced something this code accepts end to end. It was signed under the
 * pre-rename tagged-hash domain strings, and those are gone: signing and
 * verifying now use `XPRS/nonce` and `XPRS/challenge` only, with no fallback,
 * so nothing produced before that cut verifies any more.
 *
 * The capture is kept rather than deleted, because the bytes are still evidence
 * and throwing them away would quietly erase the fact that the exchange ever
 * happened. What is checked here is everything about the capture that survives
 * the cut: the wire framing, the sizes, the base85 round trip, the shape of the
 * canonical text. The signature check itself is deliberately absent.
 *
 * TO MAKE THIS A REAL TEST AGAIN: capture a signed bulletin off APRS-IS from a
 * station running current firmware, replace the three constants below, and
 * restore the `verify` expectations. Until then this file documents a hole
 * rather than filling it.
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';

import 'package:aurora/util/xprs_crypto.dart';

void main() {
  // Captured on APRS-IS:
  //   X10EGL>...::BLN0TEST :Signedhi99
  //   X10EGL>...::BLN1TEST :~LOo5...Zey;U
  // Reassembled body = "Signedhi99 ~<60-char sig>".
  const fromCall = 'X10EGL';
  const core = 'Signedhi99';
  const sig = 'LOo5<U-B#v?WWO-68fU!w1[%97b#,0/7<72G!17q0P3uahDG_OGfs<?Zey;U';
  // The device's published pubkey (NOSTR beacon base64url).
  const pubB64 = 'flH3-_InWKh9SjUYCetLr5rBgozalyqyTiJA1fH4kHI';

  test('the captured wire still frames and decodes as a signature', () {
    expect(sig.length, 60, reason: '48 bytes of base85 is exactly 60 chars');

    final sigBytes = XprsCrypto.b85decode(sig);
    expect(sigBytes, isNotNull, reason: 'the alphabet must still accept it');
    expect(sigBytes!.length, 48);

    // Round-trips: the base85 alphabet has not drifted from the one the
    // station used, which is a real property and independent of the tags.
    expect(XprsCrypto.b85encode(sigBytes), sig);

    final pad = (4 - pubB64.length % 4) % 4;
    final pub = base64Url.decode(pubB64 + ('=' * pad));
    expect(pub.length, 32);
  });

  test('a pre-rename signature no longer verifies, by design', () {
    // Not a bug being tolerated -- the point of the hard cut. If this ever
    // starts passing as `isTrue`, a fallback to an older challenge string has
    // been reintroduced somewhere.
    final sigBytes = XprsCrypto.b85decode(sig)!;
    final pad = (4 - pubB64.length % 4) % 4;
    final pub = base64Url.decode(pubB64 + ('=' * pad));
    final m = Uint8List.fromList(
        sha256.convert(utf8.encode('$fromCall|$core')).bytes);

    expect(XprsCrypto.verify(m, sigBytes, pub), isFalse,
        reason: 'a pre-rename signature verified -- has the old challenge '
            'string come back?');
  });
}
