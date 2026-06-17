// Headless test for RelayEventStore (slice 1 of the distributed NOSTR relay).
// Authors real Schnorr-signed NOSTR events and exercises ingest/verify, dedup,
// replaceable semantics, NIP-01 filters, FTS5 search, follow feeds, popularity,
// and topic streams — all in an in-memory SQLite DB.
//
//   dart run tool/social_relay_store_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/social/relay_event_store.dart';
import 'package:aurora/util/nostr_crypto.dart';
import 'package:aurora/util/nostr_event.dart';

import 'sqlite_loader.dart';

int _now = 1_700_000_000; // fixed base so created_at is deterministic

NostrEvent _ev(
  NostrKeyPair kp, {
  required int kind,
  String content = '',
  List<List<String>> tags = const [],
  int? at,
}) {
  final e = NostrEvent(
    pubkey: kp.publicKeyHex,
    createdAt: at ?? _now++,
    kind: kind,
    tags: tags,
    content: content,
  );
  e.sign(kp.privateKeyHex);
  return e;
}

int _passed = 0, _failed = 0;
void check(String name, bool ok) {
  if (ok) {
    _passed++;
    stdout.writeln('  ok   $name');
  } else {
    _failed++;
    stdout.writeln('  FAIL $name');
  }
}

void main() {
  ensureSqlite();
  final store = RelayEventStore.open(':memory:');
  final alice = NostrCrypto.generateKeyPair();
  final bob = NostrCrypto.generateKeyPair();
  final carol = NostrCrypto.generateKeyPair();

  // 1) Valid event accepted; tampered (bad-sig) event rejected.
  final post1 = _ev(alice,
      kind: NostrEventKind.textNote,
      content: 'Reticulum mesh networking is the future of offline comms',
      tags: [
        ['t', 'reticulum']
      ]);
  check('valid event ingested', store.put(post1) == true);
  check('duplicate rejected', store.put(post1) == false);

  final forged = _ev(bob, kind: NostrEventKind.textNote, content: 'hi');
  // Corrupt the signature so verify() fails.
  final sig = forged.sig!;
  forged.sig = '${sig.substring(0, sig.length - 1)}${sig.endsWith('0') ? '1' : '0'}';
  check('bad-signature event rejected', store.put(forged) == false);

  // 2) Replaceable kind-0 profile keeps the latest.
  check('profile v1', store.put(_ev(alice, kind: 0, content: '{"name":"alice","about":"ham radio"}', at: 1000)) == true);
  check('older profile dropped', store.put(_ev(alice, kind: 0, content: '{"name":"old"}', at: 500)) == false);
  check('newer profile replaces', store.put(_ev(alice, kind: 0, content: '{"name":"alice2","about":"meshnet"}', at: 2000)) == true);
  final prof = store.profileOf(alice.publicKeyHex);
  check('profileOf returns latest', prof != null && prof.content.contains('alice2'));
  check('only one profile stored', store.count(NostrFilter(authors: [alice.publicKeyHex], kinds: [0])) == 1);

  // 3) More posts across authors + topics.
  final post2 = _ev(bob,
      kind: NostrEventKind.textNote,
      content: 'Building a solar powered node this weekend',
      tags: [
        ['t', 'solar'],
        ['t', 'reticulum']
      ]);
  final post3 = _ev(carol,
      kind: NostrEventKind.textNote,
      content: 'Coffee and code',
      tags: [
        ['t', 'coffee']
      ]);
  store.put(post2);
  store.put(post3);

  // 4) NIP-01 filters.
  check('filter by author', store.query(NostrFilter(authors: [bob.publicKeyHex], kinds: [1])).length == 1);
  check('filter by kind=1 count', store.query(const NostrFilter(kinds: [1])).length == 3);
  check('filter by #t=reticulum', store.query(const NostrFilter(kinds: [1], tags: {'t': ['reticulum']})).length == 2);
  check('filter since excludes', store.query(NostrFilter(kinds: [1], since: post2.createdAt)).every((e) => e.createdAt >= post2.createdAt));

  // 5) FTS5 full-text search.
  final s1 = store.search('mesh', kinds: [1]);
  check('search "mesh" finds post1', s1.any((e) => e.id == post1.id));
  final s2 = store.search('solar');
  check('search "solar" finds post2', s2.length == 1 && s2.first.content.contains('solar'));
  final s3 = store.search('reticulum');
  check('search "reticulum" finds post1 (content+tag)', s3.any((e) => e.id == post1.id));

  // 6) File-metadata event (kind 1063) is searchable by name -> "file search".
  final fileMeta = _ev(alice, kind: kKindFileMetadata, content: 'Field manual for the T-Dongle iGate', tags: [
    ['x', 'a' * 64],
    ['m', 'application/pdf'],
    ['name', 'tdongle_igate_manual.pdf'],
    ['t', 'docs'],
  ]);
  store.put(fileMeta);
  final fs = store.search('manual', kinds: [kKindFileMetadata]);
  check('file search by content word', fs.any((e) => e.id == fileMeta.id));
  final fs2 = store.search('tdongle');
  check('file search by filename', fs2.any((e) => e.id == fileMeta.id));
  final byHash = store.query(NostrFilter(kinds: [kKindFileMetadata], tags: {'x': ['a' * 64]}));
  check('file lookup by sha256 #x', byHash.length == 1);

  // 7) Follows + feed.
  final follows = _ev(alice, kind: 3, tags: [
    ['p', bob.publicKeyHex],
  ]);
  store.put(follows);
  check('followsOf alice = [bob]', store.followsOf(alice.publicKeyHex).contains(bob.publicKeyHex));
  final feed = store.feedForFollows(store.followsOf(alice.publicKeyHex));
  check('feed has bob post', feed.any((e) => e.id == post2.id));
  check('feed excludes carol (not followed)', !feed.any((e) => e.id == post3.id));

  // 8) Popularity: reactions on post3 make it rank top.
  for (final liker in [alice, bob, carol]) {
    store.put(_ev(liker, kind: NostrEventKind.reaction, content: '+', tags: [
      ['e', post3.id!]
    ]));
  }
  store.put(_ev(alice, kind: NostrEventKind.reaction, content: '+', tags: [
    ['e', post1.id!]
  ]));
  final pop = store.popular(window: const Duration(days: 3650));
  check('popular ranks post3 first', pop.isNotEmpty && pop.first.event.id == post3.id);
  check('popular score post3 = 3', pop.first.score == 3);

  // 9) recentByTopic ordering (newest first).
  final t1 = _ev(bob, kind: 1, content: 'older reticulum note', tags: [['t', 'reticulum']], at: 10);
  final t2 = _ev(bob, kind: 1, content: 'newer reticulum note', tags: [['t', 'reticulum']], at: 2_000_000_000);
  store.put(t1);
  store.put(t2);
  final topic = store.recentByTopic('reticulum');
  check('recentByTopic newest first', topic.first.id == t2.id);

  // 10) firehose returns all kind-1.
  check('firehose >= 5 posts', store.firehose(limit: 1000).length >= 5);

  // 11) deletion (kind 5).
  store.put(_ev(carol, kind: NostrEventKind.deletion, tags: [['e', post3.id!]]));
  check('deleted post gone from queries', !store.query(const NostrFilter(kinds: [1])).any((e) => e.id == post3.id));

  // 12) store-and-forward mailbox CRUD + expiry.
  final blob = Uint8List.fromList(List.generate(50, (i) => i));
  check('sf deposit', store.sfDeposit(msgId: 'm1', dest: 'destA', blob: blob, nowMs: 1000));
  check('sf deposit dedup', !store.sfDeposit(msgId: 'm1', dest: 'destA', blob: blob, nowMs: 1000));
  store.sfDeposit(msgId: 'm2', dest: 'destA', blob: blob, nowMs: 1000);
  store.sfDeposit(msgId: 'm3', dest: 'destB', blob: blob, nowMs: 1000);
  check('sf pending for destA = 2', store.sfPending('destA', nowMs: 2000).length == 2);
  check('sf count destA = 2', store.sfCount('destA') == 2);
  check('sf dests = {destA,destB}', store.sfDests(nowMs: 2000).length == 2);
  store.sfDelete('m1');
  check('sf delete removes one', store.sfCount('destA') == 1);
  final pruned = store.sfPrune(nowMs: 1000 + const Duration(days: 31).inMilliseconds);
  check('sf prune drops expired', pruned == 2 && store.sfCount() == 0);

  store.close();
  stdout.writeln('\n$_passed passed, $_failed failed');
  exit(_failed == 0 ? 0 : 1);
}
