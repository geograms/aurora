// Splitting a Reticulum packet across BLE adverts and putting it back.
//
// The BLE5 radio can only broadcast, so a packet over the controller's advert
// ceiling had no path at all and was dropped — logged for hours as
// "dropped 239B packet: exceeds broadcast cap and no point-to-point path" on a
// device whose only link was Bluetooth. Announces are exactly the packets that
// go over, and an announce that never leaves is a device nobody can find.
import 'dart:typed_data';

import 'package:aurora/connections/bluetooth/rns_chunk.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List packet(int n, {int seed = 0}) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) (i * 7 + seed) & 0xFF]);

void main() {
  test('a packet survives the round trip', () {
    final p = packet(239); // the size from the bug report
    final parts = rnsChunkSplit(p, 100, 3);
    expect(parts.length, 3); // 97 bytes of payload per fragment
    expect(parts.every((f) => f.length <= 100), isTrue);

    final asm = RnsChunkAssembler();
    Uint8List? whole;
    for (final f in parts) {
      whole = asm.accept('aa:bb', f) ?? whole;
    }
    expect(whole, isNotNull);
    expect(whole, equals(p));
  });

  test('nothing is emitted until the last fragment arrives', () {
    final p = packet(500);
    final parts = rnsChunkSplit(p, 120, 1);
    final asm = RnsChunkAssembler();
    for (var i = 0; i < parts.length - 1; i++) {
      expect(asm.accept('aa:bb', parts[i]), isNull);
    }
    expect(asm.accept('aa:bb', parts.last), equals(p));
    expect(asm.pending, 0); // completed sets are released
  });

  test('fragments may arrive in any order', () {
    final p = packet(400, seed: 9);
    final parts = rnsChunkSplit(p, 90, 42).reversed.toList();
    final asm = RnsChunkAssembler();
    Uint8List? whole;
    for (final f in parts) {
      whole = asm.accept('aa:bb', f) ?? whole;
    }
    expect(whole, equals(p));
  });

  // Two devices in range can be mid-packet with the same id at the same time.
  // Merging their fragments would produce garbage that only fails RNS's own
  // integrity check — silently, and only under load.
  test('a single-fragment packet still works', () {
    final p = packet(50);
    final parts = rnsChunkSplit(p, 200, 0);
    expect(parts.length, 1);
    expect(RnsChunkAssembler().accept('aa:bb', parts.single), equals(p));
  });

  test('a packet too large to fragment is refused, not truncated', () {
    final huge = packet(64 * 1024);
    expect(rnsChunkSplit(huge, 100, 0), isEmpty);
    expect(rnsChunkSplit(packet(100), 2, 0), isEmpty); // no room for payload
  });

  test('an abandoned half of a packet is dropped, not kept forever', () {
    var clock = DateTime(2026, 8, 4, 12);
    final asm = RnsChunkAssembler(now: () => clock);
    final parts = rnsChunkSplit(packet(300), 110, 5);
    expect(asm.accept('aa:bb', parts.first), isNull);
    expect(asm.pending, 1);

    clock = clock.add(kRnsChunkTtl * 2);
    // The next fragment of anything sweeps the stale set…
    asm.accept('cc:dd', rnsChunkSplit(packet(50), 110, 6).single);
    expect(asm.pending, 0);
  });

  test('malformed fragments are ignored', () {
    final asm = RnsChunkAssembler();
    expect(asm.accept('aa:bb', Uint8List.fromList([1, 2, 3])), isNull); // header only
    expect(asm.accept('aa:bb', Uint8List.fromList([1, 5, 3, 9])), isNull); // idx >= total
    expect(asm.accept('aa:bb', Uint8List.fromList([1, 0, 0, 9])), isNull); // total 0
    expect(asm.pending, 0);
  });

  // A fragment costs 3 bytes of framing; anything more would eat the payload
  // room these adverts are short of in the first place.
  test('framing overhead stays at four bytes', () {
    final parts = rnsChunkSplit(packet(200), 104, 1);
    expect(parts.first.length, 104);
    expect(parts.first.length - kRnsChunkHeader, 100);
  });

  // Android rotates the BLE random MAC mid-packet, so the advertiser address
  // cannot identify a sender. The sender id travels IN the frame; reassembly
  // must work even when every fragment arrives from a different address.
  test('fragments reassemble across a rotating advertiser address', () {
    final p = packet(600);
    final parts = rnsChunkSplit(p, 120, 3, senderId: 0x5A);
    final asm = RnsChunkAssembler();
    Uint8List? whole;
    for (var i = 0; i < parts.length; i++) {
      whole = asm.accept('aa:bb:cc:dd:ee:0$i', parts[i]) ?? whole; // new MAC each time
    }
    expect(whole, equals(p));
  });

  test('two senders with the same msgId stay separate', () {
    final a = packet(300, seed: 1);
    final b = packet(300, seed: 2);
    final pa = rnsChunkSplit(a, 110, 7, senderId: 0x11);
    final pb = rnsChunkSplit(b, 110, 7, senderId: 0x22);
    final asm = RnsChunkAssembler();
    Uint8List? gotA, gotB;
    for (var i = 0; i < pa.length; i++) {
      gotA = asm.accept('same:mac', pa[i]) ?? gotA; // same address, both senders
      gotB = asm.accept('same:mac', pb[i]) ?? gotB;
    }
    expect(gotA, equals(a));
    expect(gotB, equals(b));
  });

  test('an abandoned set is counted, not just forgotten', () {
    var clock = DateTime(2026, 8, 4, 12);
    final asm = RnsChunkAssembler(now: () => clock);
    asm.accept('aa', rnsChunkSplit(packet(300), 110, 5, senderId: 1).first);
    expect(asm.abandoned, 0);
    clock = clock.add(kRnsChunkTtl * 2);
    asm.accept('bb', rnsChunkSplit(packet(50), 110, 6, senderId: 2).single);
    expect(asm.abandoned, 1);
  });
}
