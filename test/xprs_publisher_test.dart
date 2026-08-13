// The status publisher against the spec: one signed packet when it fits,
// section 6.6 parts when it does not (same ts:, split at spaces, sig on the
// last part covering the REASSEMBLED packet), and scope: deciding which
// bearers may carry it. Bearers are fakes — this tests the policy, not radios.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:aurora/services/xprs/xprs_packet.dart';
import 'package:aurora/services/xprs/xprs_publisher.dart';
import 'package:aurora/services/xprs/xprs_sig.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';

class _FakeBearer implements XprsBearer {
  _FakeBearer(this.name, {required this.shortRange});
  final bool up = true;
  @override
  final String name;
  @override
  final bool shortRange;
  final List<String> sent = [];
  @override
  Future<bool> get active async => up;
  @override
  Future<bool> send(String wire, {required int part}) async {
    sent.add(wire);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // No active profile in a unit test: the publisher must refuse politely.
  test('no profile -> nothing published', () async {
    final ble = _FakeBearer('ble5', shortRange: true);
    XprsPublisher.instance.bearers = [ble];
    final r = await XprsPublisher.instance.publishStatus('hello out there');
    expect(r, isEmpty);
    expect(ble.sent, isEmpty);
  });

  // The wire-building policy is where the spec lives; test it through the
  // publisher's splitter via a synthetic head (no profile needed).
  test('splitter: parts share ts, split at spaces, sig on last, rejoin',
      () async {
    const head = 't:status f:X1TEST ts:2026-08-13_12:00:00';
    final words = List.generate(120, (i) => 'word$i').join(' ');
    final wires = XprsPublisher.instance.debugWires(head, words);
    expect(wires.length, greaterThan(1));
    expect(wires.length, lessThanOrEqualTo(9));

    final parts = [for (final w in wires) XprsPacket.parse(w)!];
    for (var i = 0; i < parts.length; i++) {
      expect(parts[i]['ts'], '2026-08-13_12:00:00');
      expect(parts[i]['n'], '${i + 1}/${parts.length}');
      expect(parts[i].fits, true, reason: 'part ${i + 1} must fit 250B');
      // Unsigned in a test (no profile key) — sig only ever on the last.
      if (i < parts.length - 1) expect(parts[i]['sig'], isNull);
    }
    // Reassembly (6.6): joined with single spaces = the original text.
    final joined = parts.map((p) => p['m']).join(' ');
    expect(joined, words);
  });

  test('short status is one packet', () {
    const head = 't:status f:X1TEST ts:2026-08-13_12:00:00';
    final wires = XprsPublisher.instance.debugWires(head, 'all quiet here');
    expect(wires, hasLength(1));
    final p = XprsPacket.parse(wires.single)!;
    expect(p.type, 'status');
    expect(p['m'], 'all quiet here');
    expect(p['n'], isNull);
  });

  test('signed when a key is provided: sig verifies over reassembled packet',
      () {
    const head = 't:status f:X1TEST ts:2026-08-13_12:00:00';
    final d = BigInt.parse('1234567890abcdef1234567890abcdef', radix: 16);
    final words = List.generate(80, (i) => 'w$i').join(' ');
    final wires =
        XprsPublisher.instance.debugWires(head, words, signingKey: d);
    final parts = [for (final w in wires) XprsPacket.parse(w)!];
    final sig = parts.last['sig'];
    expect(sig, isNotNull);
    expect(sig!.length, 60); // base85 of a 48-byte short-Schnorr

    // The signature must cover the REASSEMBLED packet (9.1.1): rebuild it,
    // attach the sig, and verify against the x-only public key of [d].
    final joined =
        XprsPacket.parse('$head m:${parts.map((p) => p['m']).join(' ')}')!
            .with_('sig', sig);
    final q = (ECCurve_secp256k1().G * d)!;
    final xHex = q.x!.toBigInteger()!.toRadixString(16).padLeft(64, '0');
    final pub = Uint8List.fromList([
      for (var i = 0; i < 64; i += 2)
        int.parse(xHex.substring(i, i + 2), radix: 16)
    ]);
    expect(xprsVerify(joined, pub), XprsSigState.verified);
    // And it must NOT verify as a signature over any single part.
    final lastAlone = parts.last;
    expect(xprsVerify(lastAlone, pub), isNot(XprsSigState.verified));
  });
}
