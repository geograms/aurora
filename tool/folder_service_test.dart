// Headless test for FolderService (slice 2): create/edit/grant/revoke/browse a
// mutable folder against an in-memory RelayEventStore. Uses a manual clock so
// replaceable-keyset republishes and the revocation window are deterministic.
//
//   dart run tool/folder_service_test.dart
import 'dart:io';

import 'package:aurora/services/folders/folder_event.dart';
import 'package:aurora/services/folders/folder_keystore.dart';
import 'package:aurora/services/folders/folder_service.dart';
import 'package:aurora/services/social/relay_event_store.dart';
import 'package:aurora/util/nostr_crypto.dart';
import 'package:aurora/util/nostr_event.dart';

import 'sqlite_loader.dart';

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

Future<void> main() async {
  ensureSqlite();
  final store = RelayEventStore.open(':memory:');

  var clk = 1_700_000_000;
  void tick() => clk += 10;
  Future<bool> pub(NostrEvent e) async => store.put(e);
  Future<List<NostrEvent>> qry(NostrFilter f) async => store.query(f);

  final admin = NostrCrypto.generateKeyPair();
  final stranger = NostrCrypto.generateKeyPair();

  final owner = FolderService(
    keystore: FolderKeystore.open(':memory:'),
    publish: pub,
    query: qry,
    adminPrivHex: () => null,
    nowSec: () => clk,
  );
  final adminSvc = FolderService(
    keystore: FolderKeystore.open(':memory:'),
    publish: pub,
    query: qry,
    adminPrivHex: () => admin.privateKeyHex,
    nowSec: () => clk,
  );
  final strangerSvc = FolderService(
    keystore: FolderKeystore.open(':memory:'),
    publish: pub,
    query: qry,
    adminPrivHex: () => stranger.privateKeyHex,
    nowSec: () => clk,
  );

  final shaA = 'a' * 64, shaB = 'b' * 64, shaC = 'c' * 64, shaD = 'd' * 64, shaE = 'e' * 64;

  // Create + populate an owned folder.
  final fid = await owner.createFolder(name: 'Music', desc: 'mix');
  tick();
  check('folder owned after create', owner.ownedFolders().any((k) => k.folderId == fid));
  await owner.addFile(fid, shaA, name: 'a.mp3'); tick();
  await owner.addFile(fid, shaB, name: 'b.mp3'); tick();
  await owner.setMeta(fid, name: 'Albums'); tick();

  // A second owned folder, linked from the first (dynamic directory tree).
  final fid2 = await owner.createFolder(name: 'Friend folder'); tick();
  await owner.linkFolder(fid, fid2, name: 'Friend'); tick();

  var st = await owner.browse(fid);
  check('browse reflects latest name', st.name == 'Albums');
  check('browse has both files', st.files.containsKey(shaA) && st.files.containsKey(shaB));
  check('browse shows the link', st.links.containsKey(fid2));

  // Anyone can browse by id (mutable pointer found again on the network).
  final stByStranger = await strangerSvc.browse(fid);
  check('folder findable by id by anyone', stByStranger.name == 'Albums');

  // Before authorization, an admin/stranger edit is ignored.
  await adminSvc.addFile(fid, shaC, name: 'c-unauth'); tick();
  st = await owner.browse(fid);
  check('unauthorized admin edit ignored', !st.files.containsKey(shaC));

  // Owner authorizes the admin's npub; now their edits take effect.
  check('grant returns true', await owner.grantAdmin(fid, admin.publicKeyHex, role: FolderRole.moderator));
  tick();
  await adminSvc.addFile(fid, shaC, name: 'c by admin'); tick();
  st = await owner.browse(fid);
  check('authorized admin edit accepted', st.files.containsKey(shaC));
  check('admin listed in state', st.admins.any((a) => a.pubkey == admin.publicKeyHex));

  // A stranger (not in the keyset) still cannot edit.
  await strangerSvc.addFile(fid, shaD); tick();
  st = await owner.browse(fid);
  check('stranger still cannot edit', !st.files.containsKey(shaD));

  // Revoke the admin; later edits are dropped but earlier ones remain.
  check('revoke returns true', await owner.revokeAdmin(fid, admin.publicKeyHex));
  tick();
  await adminSvc.addFile(fid, shaE, name: 'e after revoke'); tick();
  st = await owner.browse(fid);
  check('post-revoke admin edit dropped', !st.files.containsKey(shaE));
  check('pre-revoke admin edit kept', st.files.containsKey(shaC));

  // Owner can still edit; remove a file.
  await owner.removeFile(fid, shaA); tick();
  st = await owner.browse(fid);
  check('owner removed a file', !st.files.containsKey(shaA));

  // Recursive browse builds the tree across linked folders.
  final tree = await owner.browseTree(fid, depth: 2);
  check('tree includes root and linked folder', tree.containsKey(fid) && tree.containsKey(fid2));

  store.close();
  stdout.writeln('\n$_pass passed, $_fail failed');
  exit(_fail == 0 ? 0 : 1);
}
