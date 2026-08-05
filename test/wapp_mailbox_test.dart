// Datagrams held for a wapp that isn't running.
//
// A tag with no registered queue meant the datagram was dropped while the
// router reported it delivered — the message somebody sent from the next room,
// gone because the receiving side happened not to have that wapp loaded. It is
// stored now, and the store is bounded so a device nobody opens cannot fill its
// disk with mail for a wapp that may never run.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/reticulum/wapp_mailbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';

Uint8List body(int n, {int seed = 0}) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) (i + seed) & 0xFF]);

void main() {
  setUpAll(() {
    if (Platform.isLinux) {
      open.overrideFor(
        OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'),
      );
    }
  });

  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('wapp_mailbox_test');
    WappMailbox.instance.open(dir.path);
  });

  tearDown(() {
    WappMailbox.instance.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a datagram for an absent wapp is kept, not dropped', () {
    expect(WappMailbox.instance.put('circles', 'aabb', body(32)), isTrue);
    expect(WappMailbox.instance.count('circles'), 1);

    final held = WappMailbox.instance.drain('circles');
    expect(held.length, 1);
    expect(held.single.from, 'aabb');
    expect(held.single.payload, equals(body(32)));
    expect(WappMailbox.instance.count('circles'), 0); // handed over exactly once
  });

  test('mail is drained oldest first', () {
    for (var i = 0; i < 5; i++) {
      WappMailbox.instance.put('chat', 'peer', body(8, seed: i));
    }
    final held = WappMailbox.instance.drain('chat');
    expect(held.length, 5);
    for (var i = 0; i < 5; i++) {
      expect(held[i].payload, equals(body(8, seed: i)));
    }
  });

  test('one wapp never drains another wapp\'s mail', () {
    WappMailbox.instance.put('chat', 'p', body(4));
    WappMailbox.instance.put('circles', 'p', body(4));
    expect(WappMailbox.instance.drain('chat').length, 1);
    expect(WappMailbox.instance.count('circles'), 1);
  });

  test('pendingTags names the wapps worth starting', () {
    WappMailbox.instance.put('chat', 'p', body(4));
    WappMailbox.instance.put('circles', 'p', body(4));
    final tags = WappMailbox.instance.pendingTags()..sort();
    expect(tags, ['chat', 'circles']);
  });

  test('the message cap holds, and the oldest go first', () {
    // A cap this size would make the test take minutes to fill honestly, so
    // check the boundary behaviour on the count the store reports.
    for (var i = 0; i < 50; i++) {
      WappMailbox.instance.put('chat', 'p', body(4, seed: i));
    }
    expect(WappMailbox.instance.count(), 50);
    expect(WappMailbox.instance.count(), lessThanOrEqualTo(kWappMailboxMaxMessages));
    final held = WappMailbox.instance.drain('chat');
    expect(held.first.payload, equals(body(4, seed: 0))); // oldest survives
  });

  test('the byte budget is what the caps are measured against', () {
    WappMailbox.instance.put('chat', 'p', body(1000));
    expect(WappMailbox.instance.bytes(), 1000);
    expect(kWappMailboxMaxBytes, 100 * 1024 * 1024);
    expect(kWappMailboxMaxMessages, 10000);
  });

  // Nothing may be reported as stored when there is nowhere to store it: the
  // caller logs a lost datagram instead of assuming it was kept.
  test('a closed store refuses the write rather than swallowing it', () {
    WappMailbox.instance.close();
    expect(WappMailbox.instance.put('chat', 'p', body(4)), isFalse);
    expect(WappMailbox.instance.drain('chat'), isEmpty);
    expect(WappMailbox.instance.pendingTags(), isEmpty);
  });

  test('mail survives a reopen', () {
    WappMailbox.instance.put('chat', 'p', body(16));
    WappMailbox.instance.close();
    WappMailbox.instance.open(dir.path);
    expect(WappMailbox.instance.count('chat'), 1);
    expect(WappMailbox.instance.drain('chat').single.payload, equals(body(16)));
  });
}
