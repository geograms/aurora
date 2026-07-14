// Multi-writer (collab / synced) folder: locks that once the master keyset
// authorizes a member's key, that member's addFile ops merge into the same
// reduced state as the owner's — the basis for a folder synced across many
// members and across one account's several devices. Also checks share-type
// stamping and that an unauthorized author's ops are still dropped.
//
//   flutter test test/folder_collab_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:aurora/services/folders/folder_event.dart';
import 'package:aurora/services/folders/folder_state.dart';
import 'package:aurora/util/nostr_crypto.dart';
import 'package:aurora/util/nostr_event.dart';

void main() {
  String sha(String c) => c * 64; // 64-hex content hash

  test('collab folder: owner + member both write; state converges', () {
    final master = NostrCrypto.generateKeyPair(); // the folder (owner) key
    final member = NostrCrypto.generateKeyPair(); // a second writer / device
    final folderId = master.publicKeyHex;
    const t0 = 1700000000;

    // Owner authorizes the member in the master-signed keyset (what a collab
    // folder does at creation for its own account key, and per granted member).
    final keyset = buildKeyset(
      master.privateKeyHex,
      [AdminEntry(member.publicKeyHex, FolderRole.contributor, t0)],
      createdAt: t0,
    );

    // Both parties add files, signing with their OWN keys.
    final ops = <NostrEvent>[
      buildOp(master.privateKeyHex, folderId,
          opAddFile(sha('a'), name: 'owner.txt'),
          createdAt: t0 + 1),
      buildOp(member.privateKeyHex, folderId,
          opAddFile(sha('b'), name: 'member.txt'),
          createdAt: t0 + 2),
    ];

    final state = reduceFolder(folderId, keyset, ops);
    final names = state.fileList.map((f) => f.name).toList()..sort();
    expect(names, ['member.txt', 'owner.txt'],
        reason: 'both authorized writers converge into one state');
  });

  test('member edits BEFORE being granted are rejected (forward-only auth)', () {
    final master = NostrCrypto.generateKeyPair();
    final member = NostrCrypto.generateKeyPair();
    final folderId = master.publicKeyHex;
    const t0 = 1700000000;

    // Member granted at t0+10, but signs an op at t0+1 (before authorization).
    final keyset = buildKeyset(
      master.privateKeyHex,
      [AdminEntry(member.publicKeyHex, FolderRole.contributor, t0 + 10)],
      createdAt: t0,
    );
    final ops = <NostrEvent>[
      buildOp(member.privateKeyHex, folderId,
          opAddFile(sha('b'), name: 'early.txt'),
          createdAt: t0 + 1), // too early
      buildOp(member.privateKeyHex, folderId,
          opAddFile(sha('c'), name: 'ok.txt'),
          createdAt: t0 + 11), // after grant
    ];
    final state = reduceFolder(folderId, keyset, ops);
    final names = state.fileList.map((f) => f.name).toList();
    expect(names, ['ok.txt'],
        reason: 'only the op authorized at its timestamp is applied');
  });

  test('a stranger key (never in the keyset) cannot write', () {
    final master = NostrCrypto.generateKeyPair();
    final stranger = NostrCrypto.generateKeyPair();
    final folderId = master.publicKeyHex;
    const t0 = 1700000000;
    final keyset = buildKeyset(master.privateKeyHex, const [], createdAt: t0);
    final ops = <NostrEvent>[
      buildOp(stranger.privateKeyHex, folderId,
          opAddFile(sha('z'), name: 'forged.txt'),
          createdAt: t0 + 1),
    ];
    expect(reduceFolder(folderId, keyset, ops).fileList, isEmpty);
  });

  test('shareType stamped by setMeta reduces onto the state', () {
    final master = NostrCrypto.generateKeyPair();
    final folderId = master.publicKeyHex;
    const t0 = 1700000000;
    final ops = <NostrEvent>[
      buildOp(master.privateKeyHex, folderId,
          opSetMeta(name: 'Team', shareType: FolderShareType.collab),
          createdAt: t0),
    ];
    final state = reduceFolder(folderId, null, ops);
    expect(state.shareType, FolderShareType.collab);
    expect(state.toJson()['shareType'], FolderShareType.collab);
  });

  test('the listing (title/cat/adult) reduces onto the state', () {
    // This is what a stranger reads from the nfolder link BEFORE downloading a
    // byte: it is the whole reason the listing is mirrored into the op-log.
    final master = NostrCrypto.generateKeyPair();
    final folderId = master.publicKeyHex;
    const t0 = 1700000000;
    final ops = <NostrEvent>[
      buildOp(
          master.privateKeyHex,
          folderId,
          opSetMeta(
              name: 'bbb',
              title: 'Big Buck Bunny',
              desc: 'A large rabbit deals with three bullies.',
              cat: 'film',
              tags: '1080p, animation',
              adult: false),
          createdAt: t0),
    ];
    final state = reduceFolder(folderId, null, ops);
    expect(state.title, 'Big Buck Bunny');
    expect(state.cat, 'film');
    expect(state.tags, '1080p, animation');
    expect(state.adult, isFalse);
    expect(state.toJson()['cat'], 'film');
    expect(state.toJson().containsKey('adult'), isFalse); // false is not emitted
  });

  test('an OLD client\'s setMeta does not wipe the listing', () {
    // The reducer only touches keys the payload carries. A client that predates
    // the listing renames the folder and would otherwise silently erase its
    // title, category and +18 flag — publishing an adult film as an untagged
    // "other" to everyone who syncs after it.
    final master = NostrCrypto.generateKeyPair();
    final folderId = master.publicKeyHex;
    const t0 = 1700000000;
    final ops = <NostrEvent>[
      buildOp(master.privateKeyHex, folderId,
          opSetMeta(title: 'Some Film', cat: 'film', adult: true),
          createdAt: t0),
      // An older client: it knows only `name`.
      buildOp(master.privateKeyHex, folderId, {'op': 'setMeta', 'name': 'renamed'},
          createdAt: t0 + 10),
    ];
    final state = reduceFolder(folderId, null, ops);
    expect(state.name, 'renamed');
    expect(state.title, 'Some Film');
    expect(state.cat, 'film');
    expect(state.adult, isTrue);
  });
}
