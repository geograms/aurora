// Headless test for the mutable-folder reducer (slice 1): authorization window,
// revocation keeping past edits, last-writer-wins, and rejection of unauthorized
// or tampered ops. Pure — no SQLite, no Flutter.
//
//   dart run tool/folder_model_test.dart
import 'dart:io';

import 'package:aurora/services/folders/folder_event.dart';
import 'package:aurora/services/folders/folder_state.dart';
import 'package:aurora/util/nostr_crypto.dart';

int _pass = 0, _fail = 0;
void check(String name, bool ok) {
  if (ok) {
    _pass++;
    stdout.writeln('  ok   $name');
  } else {
    _fail++;
    stdout.writeln('  FAIL $name');
  }
}

void main() {
  final master = NostrCrypto.generateKeyPair();
  final admin = NostrCrypto.generateKeyPair();
  final stranger = NostrCrypto.generateKeyPair();
  final folderId = master.publicKeyHex;
  const t0 = 1_700_000_000;

  final shaA = 'a' * 64, shaB = 'b' * 64, shaC = 'c' * 64, shaD = 'd' * 64;
  final other = NostrCrypto.generateKeyPair().publicKeyHex;

  // Key-set authorizing the admin from t0.
  final keyset = buildKeyset(
      master.privateKeyHex,
      [AdminEntry(admin.publicKeyHex, FolderRole.moderator, t0)],
      createdAt: t0);

  final ops = [
    buildOp(master.privateKeyHex, folderId, opSetMeta(name: 'Music', desc: 'mix'), createdAt: t0 + 1),
    buildOp(master.privateKeyHex, folderId, opAddFile(shaA, name: 'a.mp3'), createdAt: t0 + 2),
    buildOp(admin.privateKeyHex, folderId, opAddFile(shaB, name: 'b.mp3'), createdAt: t0 + 3),
    buildOp(stranger.privateKeyHex, folderId, opAddFile(shaC, name: 'c.mp3'), createdAt: t0 + 4),
    buildOp(master.privateKeyHex, folderId, opLink(other, name: 'Friend'), createdAt: t0 + 6),
  ];
  // A tampered master op (corrupt signature) must be dropped.
  final tampered = buildOp(master.privateKeyHex, folderId, opAddFile(shaD), createdAt: t0 + 5);
  final sig = tampered.sig!;
  tampered.sig = '${sig.substring(0, sig.length - 1)}${sig.endsWith('0') ? '1' : '0'}';
  ops.add(tampered);

  final st = reduceFolder(folderId, keyset, ops);

  check('folder name from setMeta', st.name == 'Music');
  check('folder desc from setMeta', st.desc == 'mix');
  check('master file present', st.files.containsKey(shaA));
  check('authorized admin file present', st.files.containsKey(shaB));
  check('unauthorized stranger file dropped', !st.files.containsKey(shaC));
  check('tampered op dropped', !st.files.containsKey(shaD));
  check('link present', st.links.containsKey(other));
  check('admins listed', st.admins.length == 1 && st.admins.first.pubkey == admin.publicKeyHex);

  // Last-writer-wins: a later setMeta and a rmFile override earlier ops.
  final ops2 = [
    ...ops,
    buildOp(master.privateKeyHex, folderId, opSetMeta(name: 'Albums'), createdAt: t0 + 7),
    buildOp(admin.privateKeyHex, folderId, opRmFile(shaA), createdAt: t0 + 8),
  ];
  final st2 = reduceFolder(folderId, keyset, ops2);
  check('last-writer-wins name', st2.name == 'Albums');
  check('admin removed master file', !st2.files.containsKey(shaA));

  // Revocation keeps past edits, drops future ones.
  final keysetRevoked = buildKeyset(
      master.privateKeyHex,
      [AdminEntry(admin.publicKeyHex, FolderRole.moderator, t0, t0 + 10)],
      createdAt: t0 + 20);
  final revOps = [
    buildOp(admin.privateKeyHex, folderId, opAddFile(shaB, name: 'before'), createdAt: t0 + 3),
    buildOp(admin.privateKeyHex, folderId, opAddFile(shaC, name: 'after'), createdAt: t0 + 15),
  ];
  final stRev = reduceFolder(folderId, keysetRevoked, revOps);
  check('pre-revocation admin edit kept', stRev.files.containsKey(shaB));
  check('post-revocation admin edit dropped', !stRev.files.containsKey(shaC));

  // A forged key-set (not signed by the master) authorizes nobody.
  final forged = buildKeyset(
      admin.privateKeyHex, // wrong signer
      [AdminEntry(admin.publicKeyHex, FolderRole.moderator, t0)],
      createdAt: t0);
  final stForged = reduceFolder(
      folderId, forged, [buildOp(admin.privateKeyHex, folderId, opAddFile(shaB), createdAt: t0 + 3)]);
  check('forged keyset authorizes nobody', !stForged.files.containsKey(shaB) && stForged.admins.isEmpty);

  // No key-set at all: only the master can write.
  final stNoKs = reduceFolder(folderId, null, [
    buildOp(master.privateKeyHex, folderId, opAddFile(shaA), createdAt: t0 + 2),
    buildOp(admin.privateKeyHex, folderId, opAddFile(shaB), createdAt: t0 + 3),
  ]);
  check('no keyset: master writes, others dropped',
      stNoKs.files.containsKey(shaA) && !stNoKs.files.containsKey(shaB));

  stdout.writeln('\n$_pass passed, $_fail failed');
  exit(_fail == 0 ? 0 : 1);
}
