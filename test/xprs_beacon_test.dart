// The XPRS discovery beacon (docs/XPRS.md §10.6).
//
// The property worth protecting is honesty under truncation: a busy street will
// not fit in one advert, and a list that is silently cut is worse than no list,
// because a reader cannot tell "these three are all there is" from "these three
// of forty". `peers:` is what makes the difference visible.

import 'dart:convert';

import 'package:aurora/services/xprs/xprs_packet.dart';
import 'package:aurora/services/xprs/xprs_vocab.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two advert ceilings measured on real hardware (docs/ble5.md).
const int kOlderTablet = 184;
const int kTank2 = 296;

XprsPacket envelope(String self) =>
    XprsPacket.parse('t:observation f:$self link:ble peers:0 hears:x')!;

List<String> calls(int n) =>
    List.generate(n, (i) => 'X1${i.toString().padLeft(4, "0")}');

void main() {
  group('fitting neighbours into one advert', () {
    test('everything fits when there is room, and peers matches', () {
      final fit = xprsNeighbourFit(calls(3), envelope('X1A67X'), kTank2);
      expect(fit.hears.length, 3);
      expect(fit.peers, 3);
    });

    test('a long list is cut, and peers still tells the truth', () {
      final fit = xprsNeighbourFit(calls(60), envelope('X1A67X'), kOlderTablet);
      expect(fit.hears.length, lessThan(60));
      expect(fit.peers, 60,
          reason: 'peers is the total, not the number that fitted');
      expect(fit.hears.length, greaterThan(10),
          reason: 'the 184-byte budget should still carry a useful list');
    });

    test('what it produces actually fits the budget it was given', () {
      for (final budget in [kOlderTablet, kTank2, 250]) {
        final fit = xprsNeighbourFit(calls(60), envelope('X1A67X'), budget);
        final p = envelope('X1A67X')
            .with_('peers', '${fit.peers}')
            .with_('hears', fit.hears.join(','));
        expect(utf8.encode(p.encode()).length, lessThanOrEqualTo(budget),
            reason: 'budget $budget');
      }
    });

    test('the order given is the order kept, so the cut keeps the useful half',
        () {
      // Section 10.6.3: most relevant first, and the sender decides what
      // relevant means. The fitter must not reorder.
      final ranked = ['X3RLY7', 'X1RD89', 'X32DVA', 'CT1ABC-9'];
      final fit = xprsNeighbourFit(ranked, envelope('X1A67X'), kTank2);
      expect(fit.hears, ranked);
    });

    test('no neighbours is an empty list, not a broken packet', () {
      final fit = xprsNeighbourFit([], envelope('X1A67X'), kTank2);
      expect(fit.hears, isEmpty);
      expect(fit.peers, 0);
    });
  });

  group('reading a beacon', () {
    const wire =
        't:observation f:X1A67X link:ble peers:12 mail:3 hears:X1RD89,X32DVA,CT1ABC-9';

    test('the whole beacon parses and is small', () {
      final p = XprsPacket.parse(wire)!;
      expect(p.byteLength, 76);
      expect(p.fits, isTrue);
      expect(p.byteLength, lessThan(kOlderTablet),
          reason: 'must fit the smallest controller we have measured');
    });

    test('peers, mail and hears come off it', () {
      final p = XprsPacket.parse(wire)!;
      expect(xprsPeers(p), 12);
      expect(xprsMail(p), 3);
      expect(p['hears']!.split(','), ['X1RD89', 'X32DVA', 'CT1ABC-9']);
    });

    test('a truncated list is detectable', () {
      final p = XprsPacket.parse(wire)!;
      final listed = p['hears']!.split(',').length;
      expect(xprsPeers(p)! > listed, isTrue,
          reason: 'a client can say "3 of 12" instead of drawing 3 as all');
    });

    test('mail is absent when there is none, not zero', () {
      final p = XprsPacket.parse(
          't:observation f:X1A67X link:ble peers:2 hears:X1RD89,X32DVA')!;
      expect(xprsMail(p), isNull);
      expect(p.has('mail'), isFalse);
    });

    test('a beacon still needs its bearer named', () {
      // hears: is a per-bearer reading: heard over Bluetooth means in the room,
      // heard over LoRa means somewhere in ten kilometres.
      expect(
          xprsReadingIsScoped(
              XprsPacket.parse('t:observation f:X1A67X hears:X1RD89')!),
          isFalse);
      expect(xprsReadingIsScoped(XprsPacket.parse(wire)!), isTrue);
    });

    test('mail alone needs no bearer', () {
      // Mail held is a fact about the station, not about one radio.
      expect(
          xprsReadingIsScoped(
              XprsPacket.parse('t:observation f:X1A67X mail:3')!),
          isTrue);
    });
  });
}
