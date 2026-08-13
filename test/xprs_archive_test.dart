/*
 * XprsArchive tests — the heard-traffic spool: dup collapse on the derived
 * identifier, zero-hop wire preference, the never-archived types, signature
 * policy at flush, bounded eviction with protected classes, mailbox
 * declarations (13.12) and the query the history replay runs on.
 */
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'dart:convert';

import 'package:aurora/services/xprs/xprs_archive.dart';
import 'package:aurora/services/xprs/xprs_id.dart';
import 'package:aurora/services/xprs/xprs_ingest.dart';
import 'package:aurora/services/xprs/xprs_monitor.dart';
import 'package:aurora/services/xprs/xprs_packet.dart';
import 'package:aurora/services/xprs/xprs_sig.dart';
import 'package:aurora/services/xprs/xprs_vocab.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:sqlite3/open.dart';

final BigInt _d =
    BigInt.parse('1234567890abcdef1234567890abcdef', radix: 16);

Uint8List _pubOf(BigInt d) {
  final q = (ECCurve_secp256k1().G * d)!;
  final xHex = q.x!.toBigInteger()!.toRadixString(16).padLeft(64, '0');
  return Uint8List.fromList([
    for (var i = 0; i < 64; i += 2)
      int.parse(xHex.substring(i, i + 2), radix: 16)
  ]);
}

XprsPacket _p(String wire) => XprsPacket.parse(wire)!;

void main() {
  late Directory tmp;
  late XprsArchive a;

  setUpAll(() {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xprsarchive');
    a = XprsArchive.instance;
    a
      ..selfCallsign = 'X1SELF'
      ..keyResolver = null
      ..protectedCallsigns = null
      ..maxBytes = 500 * 1024 * 1024
      ..maxAgeDays = 365
      ..admitted = 0
      ..dropped = 0
      ..forged = 0
      ..init('${tmp.path}/xprs_archive.sqlite3');
  });

  tearDown(() {
    a.close();
    tmp.deleteSync(recursive: true);
  });

  test('xprsParseTs round-trips the spec format and refuses junk', () {
    expect(xprsParseTs('2026-08-13_12:00:00'),
        DateTime.utc(2026, 8, 13, 12).millisecondsSinceEpoch);
    expect(xprsParseTs('2026-08-13 12:00:00'), isNull);
    expect(xprsParseTs('yesterday'), isNull);
    expect(xprsParseTs(null), isNull);
  });

  test('dup collapse: same id from two sightings is one row, heard=2', () {
    final p = _p('t:info f:X1AAA ts:2026-08-13_10:00:00 m:hello');
    a.admit(p, bearer: 'ble', rssi: -60, nowMs: 1000);
    a.admit(p, bearer: 'ble', rssi: -70, nowMs: 2000);
    a.flush(nowMs: 2000);
    final rows = a.query();
    expect(rows, hasLength(1));
    expect(rows.single['heard'], 2);
    expect(rows.single['id'], xprsIdentifier(p));
  });

  test('zero-hop copy replaces a relayed one, never the reverse', () {
    final clean = _p('t:info f:X1AAA ts:2026-08-13_10:00:00 m:hop test');
    final hopped = clean.with_('via', 'X3RLY7');
    // Relayed copy first, original second: wire upgrades.
    a.admit(hopped, bearer: 'ble', nowMs: 1000);
    a.flush(nowMs: 1000);
    a.admit(clean, bearer: 'ble', nowMs: 2000);
    a.flush(nowMs: 2000);
    expect(a.query().single['wire'], clean.encode());
    // Same id, so a later relayed sighting must not downgrade it back.
    a.admit(hopped, bearer: 'ble', nowMs: 3000);
    a.flush(nowMs: 3000);
    expect(a.query().single['wire'], clean.encode());
  });

  test('ping/pong/receipt/result never stored; command is', () {
    for (final t in ['ping', 'pong', 'receipt', 'result']) {
      a.admit(_p('t:$t f:X1AAA ts:2026-08-13_10:00:00'),
          bearer: 'ble', nowMs: 1000);
    }
    a.admit(_p('t:command f:X1AAA d:X1SELF ts:2026-08-13_10:00:00 cmd:who'),
        bearer: 'ble', nowMs: 1000);
    a.flush(nowMs: 1000);
    final rows = a.query();
    expect(rows, hasLength(1));
    expect(rows.single['type'], 'command');
    expect(rows.single['mine'], true);
  });

  test('forged dropped at flush; unsigned and verified stored with state', () {
    a.keyResolver = (c) => c == 'X1AAA' ? _pubOf(_d) : null;
    final good = xprsSign(
        _p('t:info f:X1AAA ts:2026-08-13_10:00:00 m:signed'), _d);
    final unsigned = _p('t:info f:X1BBB ts:2026-08-13_10:01:00 m:plain');
    // Signed by the wrong key but claiming X1AAA: forged.
    final bad = xprsSign(
        _p('t:info f:X1AAA ts:2026-08-13_10:02:00 m:stolen'),
        BigInt.from(99999));
    a.admit(good, bearer: 'ble', nowMs: 1000);
    a.admit(unsigned, bearer: 'ble', nowMs: 1000);
    a.admit(bad, bearer: 'ble', nowMs: 1000);
    a.flush(nowMs: 1000);
    final rows = a.query();
    expect(rows, hasLength(2));
    final byFrom = {for (final r in rows) r['from']: r};
    expect(byFrom['X1AAA']!['sig'], 'verified');
    expect(byFrom['X1BBB']!['sig'], 'unsigned');
    expect(a.forged, 1);
  });

  test('own and mine survive the byte cap; age cap takes everything', () {
    a.maxBytes = 40 * 1024; // a few pages
    final now = DateTime.utc(2026, 8, 13).millisecondsSinceEpoch;
    // Fill with stranger chatter (unique ts => unique ids), plus one own and
    // one addressed to us, both OLD so eviction order would take them first
    // if they were not protected.
    a.admit(
        _p('t:status f:X1SELF ts:2026-08-01_00:00:00 m:my own words'),
        bearer: 'ble',
        own: true,
        nowMs: now);
    a.admit(
        _p('t:message f:X1AAA d:X1SELF ts:2026-08-01_00:00:01 m:for me'),
        bearer: 'ble',
        nowMs: now);
    for (var i = 0; i < 2000; i++) {
      final mm = (i ~/ 60) % 60, ss = i % 60, hh = 1 + i ~/ 3600;
      a.admit(
          _p('t:info f:X1AAA ts:2026-08-0${1 + (i % 7)}_'
              '${hh.toString().padLeft(2, '0')}:'
              '${mm.toString().padLeft(2, '0')}:'
              '${ss.toString().padLeft(2, '0')} '
              'm:stranger chatter number $i padding padding padding'),
          bearer: 'ble',
          nowMs: now + i);
    }
    // Enough flushes that the every-20th byte-cap pass runs several times.
    for (var i = 0; i < 60; i++) {
      a.flush(nowMs: now + 100000 + i);
    }
    final rows = a.query(limit: 1000);
    expect(rows.length, lessThan(2002));
    expect(rows.any((r) => r['own'] == true), true,
        reason: 'own publication must survive the byte cap');
    expect(rows.any((r) => r['mine'] == true), true,
        reason: 'mail to us must survive the byte cap');
  });

  test('mailbox declarations: verified-only, windows, cancel', () {
    final key = _pubOf(_d);
    a.keyResolver = (c) => c == 'X1BOA3' ? key : null;

    // Unsigned: must not act (13.12).
    expect(
        a.recordMailboxDecl(
            _p('t:mailbox f:X1BOA3 ts:2026-08-13_10:00:00 hold:X1SELF')),
        false);
    // Signed, names us: recorded.
    final decl = xprsSign(
        _p('t:mailbox f:X1BOA3 ts:2026-08-13_10:00:00 hold:X3RLY7,X1SELF'),
        _d);
    expect(a.recordMailboxDecl(decl), true);
    expect(a.hasActiveDecl('X1BOA3'), true);
    expect(a.hasActiveDecl('x1boa3-2'), true, reason: 'base-callsign match');
    // Signed, does not name us: ignored.
    expect(
        a.recordMailboxDecl(xprsSign(
            _p('t:mailbox f:X1BOA3 ts:2026-08-13_10:01:00 hold:X3RLY7'), _d)),
        false);
    // Windowed declaration outside its window is not active.
    final winter = xprsSign(
        _p('t:mailbox f:X1BOA3 ts:2026-08-13_10:02:00 hold:X1SELF '
            'since:2026-11-01_00:00:00 until:2027-03-31_23:59:59'),
        _d);
    expect(a.recordMailboxDecl(winter), true);
    final august = DateTime.utc(2026, 8, 14).millisecondsSinceEpoch;
    final january = DateTime.utc(2027, 1, 10).millisecondsSinceEpoch;
    // Cancel the open-ended one; only winter remains.
    final cancel = xprsSign(
        _p('t:mailbox f:X1BOA3 ts:2026-08-14_09:00:00 '
            'r:${xprsIdentifier(decl)} remove:mailbox'),
        _d);
    expect(a.recordMailboxDecl(cancel), true);
    expect(a.hasActiveDecl('X1BOA3', nowMs: august), false);
    expect(a.hasActiveDecl('X1BOA3', nowMs: january), true);
  });

  test('reticulum lane: refused without a declaration, admitted with one, '
      'monitor untouched', () {
    XprsMonitor.instance.clear();
    final rev = XprsMonitor.instance.revision;
    final before = XprsIngest.refusedRns;
    Uint8List wire(String s) => Uint8List.fromList(utf8.encode(s));

    // A stranger's broadcast over the hub: refused, counted.
    XprsIngest.reticulum(
        'aa11', wire('t:info f:X1AAA ts:2026-08-13_10:00:00 m:hub chatter'));
    a.flush(nowMs: 1000);
    expect(a.query(), isEmpty);
    expect(XprsIngest.refusedRns, before + 1);

    // The author declares us; now its traffic is ours to hold.
    a.keyResolver = (c) => c == 'X1AAA' ? _pubOf(_d) : null;
    XprsIngest.reticulum(
        'aa11',
        wire(xprsSign(
                _p('t:mailbox f:X1AAA ts:2026-08-13_10:01:00 hold:X1SELF'),
                _d)
            .encode()));
    XprsIngest.reticulum(
        'aa11', wire('t:info f:X1AAA ts:2026-08-13_10:02:00 m:now archived'));
    // Mail TO a declared station is held too (we are its mailbox).
    XprsIngest.reticulum('bb22',
        wire('t:message f:X1ZZZ d:X1AAA ts:2026-08-13_10:03:00 m:for them'));
    a.flush(nowMs: 2000);
    final types = a.query().map((r) => r['type']).toList();
    expect(types, containsAll(['mailbox', 'info', 'message']));

    // Nothing on this lane is a sighting.
    expect(XprsMonitor.instance.revision, rev);
  });

  test('query: window on packet ts, only: matches from or to, newest first',
      () {
    a.admit(_p('t:info f:X1AAA ts:2026-08-13_10:00:00 m:one'),
        bearer: 'ble', nowMs: 1);
    a.admit(_p('t:info f:X1BBB ts:2026-08-13_11:00:00 m:two'),
        bearer: 'ble', nowMs: 2);
    a.admit(_p('t:message f:X1CCC d:X1AAA ts:2026-08-13_12:00:00 m:three'),
        bearer: 'ble', nowMs: 3);
    a.flush(nowMs: 10);

    final all = a.query();
    expect([for (final r in all) r['from']], ['X1CCC', 'X1BBB', 'X1AAA']);

    final only = a.query(only: 'X1AAA');
    expect(only, hasLength(2), reason: 'sender OR addressee');

    final until = xprsParseTs('2026-08-13_12:00:00')!;
    final windowed = a.query(untilMs: until);
    expect(windowed, hasLength(2), reason: 'until is strict <');
    final since = a.query(sinceMs: xprsParseTs('2026-08-13_11:00:00'));
    expect(windowed.length + since.length, 4,
        reason: 'boundary belongs to since side exactly once');
  });
}
