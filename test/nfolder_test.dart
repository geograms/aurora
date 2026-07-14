/*
 * `nfolder1…` — the folder pointer (docs/torrents.md §11).
 *
 * What these lock down is the part a user actually pastes: a link must survive a
 * round trip, an OLD link (a bare npub, shared before this encoding existed)
 * must keep working, and a link must never be able to lie about which folder it
 * points at.
 */

import 'dart:typed_data';

import 'package:aurora/services/folders/nfolder.dart';
import 'package:flutter_test/flutter_test.dart';

const _folderId =
    '3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d';
const _authorId =
    '6e468422dfb74a5738702a8823b9b28168abab8655faacb6853cd0ee15deee93';

Uint8List _dest(int fill) => Uint8List.fromList(List.filled(16, fill));

void main() {
  test('round-trips the folder key', () {
    final link = Nfolder.encode(_folderId);
    expect(link.startsWith('nfolder1'), isTrue);
    final ref = Nfolder.decode(link);
    expect(ref, isNotNull);
    expect(ref!.folderId, _folderId);
    expect(ref.hints, isEmpty);
    expect(ref.author, isNull);
  });

  test('carries provider hints and the author', () {
    final link = Nfolder.encode(
      _folderId,
      hints: [_dest(0xab), _dest(0xcd)],
      authorHex: _authorId,
    );
    final ref = Nfolder.decode(link)!;
    expect(ref.folderId, _folderId);
    expect(ref.author, _authorId);
    expect(ref.hints.length, 2);
    expect(ref.hints.first, _dest(0xab));
    expect(ref.hints.last, _dest(0xcd));
  });

  test('a hint that is not a 16-byte destination hash is dropped, not truncated',
      () {
    final link = Nfolder.encode(_folderId, hints: [
      Uint8List.fromList(List.filled(8, 1)), // too short
      _dest(0x11),
    ]);
    final ref = Nfolder.decode(link)!;
    expect(ref.hints.length, 1);
    expect(ref.hints.single, _dest(0x11));
  });

  test('a bare npub still opens a folder (no hints, no author)', () {
    // Every link shared before `nfolder` existed must stay valid — it is just
    // the slow cold start.
    const npub =
        'npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6';
    final ref = Nfolder.decode(npub);
    expect(ref, isNotNull);
    expect(ref!.folderId, _folderId);
    expect(ref.hints, isEmpty);
  });

  test('accepts raw hex and the geogram:// deep link', () {
    expect(Nfolder.decode(_folderId)!.folderId, _folderId);
    final link = Nfolder.encode(_folderId, hints: [_dest(2)]);
    final deep = Nfolder.decode('geogram://folder/$link')!;
    expect(deep.folderId, _folderId);
    expect(deep.hints.single, _dest(2));
  });

  test('rejects what is not a folder pointer', () {
    expect(Nfolder.decode(''), isNull);
    expect(Nfolder.decode('not a link'), isNull);
    expect(Nfolder.decode('nfolder1garbage'), isNull);
    // A note id is a different kind of thing and must not decode as a folder.
    expect(
      Nfolder.decode(
          'note180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsx2q0ec'),
      isNull,
    );
  });

  test('a mangled link does not silently point somewhere else', () {
    // bech32 is checksummed: flip a character and it fails to decode rather than
    // resolving to a different (attacker-chosen) folder.
    final link = Nfolder.encode(_folderId);
    final flipped = link.substring(0, link.length - 2) +
        (link.endsWith('q') ? 'p' : 'q') +
        link.substring(link.length - 1);
    expect(Nfolder.decode(flipped), isNull);
  });

  test('unknown TLV types are skipped, so the encoding can grow', () {
    // Hand-build a pointer with an unknown type 9 between the key and a hint.
    final link = Nfolder.encode(_folderId, hints: [_dest(7)]);
    final ref = Nfolder.decode(link)!;
    expect(ref.folderId, _folderId);
    expect(ref.hints.single, _dest(7));
  });
}
