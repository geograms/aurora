import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';

import 'package:aurora/util/aprx_sign.dart';

void main() {
  test('verify a signature captured off APRS-IS from the device', () {
    // Captured on APRS-IS:
    //   X10EGL>...::BLN0TEST :Signedhi99
    //   X10EGL>...::BLN1TEST :~LOo5...Zey;U
    // Reassembled body = "Signedhi99 ~<60-char sig>".
    const fromCall = 'X10EGL';
    const core = 'Signedhi99';
    const sig = 'LOo5<U-B#v?WWO-68fU!w1[%97b#,0/7<72G!17q0P3uahDG_OGfs<?Zey;U';
    // The device's published pubkey (NOSTR beacon base64url).
    const pubB64 = 'flH3-_InWKh9SjUYCetLr5rBgozalyqyTiJA1fH4kHI';

    expect(sig.length, 60);
    final sigBytes = AprxSign.b85decode(sig);
    expect(sigBytes, isNotNull);
    expect(sigBytes!.length, 48);

    final pad = (4 - pubB64.length % 4) % 4;
    final pub = base64Url.decode(pubB64 + ('=' * pad));
    expect(pub.length, 32);

    final canon = '$fromCall|$core';
    final m = Uint8List.fromList(sha256.convert(utf8.encode(canon)).bytes);

    // Genuine message verifies.
    expect(AprxSign.verify(m, sigBytes, pub), isTrue);

    // Any tamper to the text breaks it.
    final m2 = Uint8List.fromList(
        sha256.convert(utf8.encode('$fromCall|${core}x')).bytes);
    expect(AprxSign.verify(m2, sigBytes, pub), isFalse);
  });
}
