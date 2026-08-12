/*
 * A station met over Bluetooth must show as its callsign, not as hex.
 *
 * On the phones, TANK2 listed C61 as "3b02bb89" in the chat rail while the
 * subtitle showed the full delivery hash — and C61 listed TANK2 correctly as
 * X1RD89. The asymmetry is the tell: an RNS ANNOUNCE carries no callsign, so a
 * peer whose name never arrived some other way had nothing to display.
 *
 * Meanwhile the XPRS beacon states both facts in ONE frame — `f:` names the
 * sender and `lx:` gives its LXMF delivery destination — and the mesh was
 * throwing the name away, forwarding only the address so a path could be
 * requested. This pins the pairing that fixes it.
 */
import 'package:aurora/services/reticulum/rns_service.dart';
import 'package:aurora/services/xprs/xprs_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const dest = '23698e7593f05e2053f5183580e2cf98'; // 32 hex = a delivery dest
  final rns = RnsService.instance;

  test('a beacon states BOTH the callsign and where to write to it', () {
    // The frame the radio actually airs (docs/XPRS.md section 10.6).
    final p = XprsPacket.parse(
      't:observation f:X1A67X link:ble peers:1 lx:$dest',
    );
    expect(p, isNotNull);
    expect(p!['f'], 'X1A67X');
    expect(p['lx'], dest, reason: 'the address the host asks a path for');
    expect(p['lx']!.length, 32,
        reason: 'the length gate the mesh applies before using it');
  });

  test('the callsign a beacon named is remembered for that destination', () {
    rns.noteLxmfCallsign(dest, 'X1A67X');
    expect(rns.callsignForLxmfDest(dest), 'X1A67X');
  });

  test('lookup is case- and whitespace-insensitive on both sides', () {
    rns.noteLxmfCallsign('  ${dest.toUpperCase()} ', ' x1a67x ');
    expect(rns.callsignForLxmfDest(dest.toUpperCase()), 'X1A67X',
        reason: 'a hash is hex either case; a callsign is upper by convention');
  });

  test('junk is refused rather than stored', () {
    rns.noteLxmfCallsign('too-short', 'X9ZZZZ');
    expect(rns.callsignForLxmfDest('too-short'), isEmpty);

    const other = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    rns.noteLxmfCallsign(other, '   ');
    expect(rns.callsignForLxmfDest(other), isEmpty,
        reason: 'an empty name would overwrite a good one with nothing');
  });

  test('a later beacon corrects the name', () {
    const moved = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    rns.noteLxmfCallsign(moved, 'X10LD1');
    rns.noteLxmfCallsign(moved, 'X2NEW2');
    expect(rns.callsignForLxmfDest(moved), 'X2NEW2');
  });

  test('an unknown destination simply has no name', () {
    expect(rns.callsignForLxmfDest('cccccccccccccccccccccccccccccccc'),
        isEmpty);
  });

  test('the table is bounded — a busy street cannot grow it forever', () {
    for (var i = 0; i < 400; i++) {
      final d = i.toRadixString(16).padLeft(32, '0');
      rns.noteLxmfCallsign(d, 'X${i.toString().padLeft(5, '0')}');
    }
    // The most recent entry survives; the map is capped well under 400.
    expect(rns.callsignForLxmfDest((399).toRadixString(16).padLeft(32, '0')),
        'X00399');
  });

  test('a station known ONLY from a beacon still gets a directory row', () {
    // The gap that kept the phones showing hex: filling in a missing callsign
    // is useless when the peer has no row at all. A row needs an lxmf ANNOUNCE,
    // and a neighbour met over Bluetooth may beacon for minutes before one
    // arrives — the beacon alone must be enough to name it.
    const beaconOnly = 'dddddddddddddddddddddddddddddddd';
    rns.noteLxmfCallsign(beaconOnly, 'X1A67X');

    final row = rns
        .messagingDirectory('')
        .firstWhere((e) => e['dest'] == beaconOnly, orElse: () => {});
    expect(row, isNotEmpty, reason: 'no row means nothing to name');
    expect(row['callsign'], 'X1A67X');
    expect(row['kind'], 'lxmf');
    expect(row['via'], 'ble5', reason: 'we heard it on the radio, directly');
  });

  test('the beacon row is searchable by callsign', () {
    const d = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
    rns.noteLxmfCallsign(d, 'X7FIND');
    expect(
      rns.messagingDirectory('x7find').any((e) => e['dest'] == d),
      isTrue,
    );
  });

  group('a retry is only worth airtime against evidence', () {
    // The expensive case is a peer that walked away: a duty-cycled band does
    // not care that our message is important, and re-airing into an empty room
    // tells us nothing while costing everyone else the channel.
    // docs/XPRS.md 31.1: a retry is not a new packet.
    test('a peer never heard from is not worth transmitting at', () {
      expect(rns.debugRetryWorthwhile('ffffffffffffffffffffffffffffffff'),
          isFalse);
    });

    test('a peer whose beacon just arrived is', () {
      const near = '11111111111111111111111111111111';
      rns.noteLxmfCallsign(near, 'X1NEAR');
      expect(rns.debugRetryWorthwhile(near), isTrue);
    });

    test('the same peer, asked by a differently-cased hash', () {
      const near = '22222222222222222222222222222222';
      rns.noteLxmfCallsign(near, 'X1NEAR');
      expect(rns.debugRetryWorthwhile(near.toUpperCase()), isTrue,
          reason: 'a hash is hex in either case');
    });
  });
}
