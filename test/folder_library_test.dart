/*
 * The download library: real directories on disk, organized in subfolders, with
 * the content-addressed index served straight from those files.
 *
 * Locks the tree the wapp navigates: a downloaded (keyless) torrent materializes
 * as a real dir under the root; an organizing subfolder is a plain dir; moving a
 * torrent relocates its directory and keeps its identity; and a torrent that
 * lives OUTSIDE the root still shows (ungrouped) so nothing is hidden.
 */

import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/folders/disk_folder.dart';
import 'package:aurora/services/folders/disk_folder_manager.dart';
import 'package:aurora/services/folders/folder_keystore.dart';
import 'package:aurora/services/folders/folder_service.dart';
import 'package:aurora/services/folders/folder_state.dart';
import 'package:aurora/util/nostr_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late Directory root;
  late DiskFolderManager mgr;
  late List<NostrEvent> published;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('folder_library');
    root = Directory('${tmp.path}/root');
    published = [];
    final keystore = FolderKeystore.open(':memory:');
    final folders = FolderService(
      keystore: keystore,
      publish: (ev) async {
        published.add(ev);
        return true;
      },
      query: (_) async => published,
      adminPrivHex: () => null,
    );
    mgr = DiskFolderManager(
      folders: folders,
      localState: (folderId) async => reduceFolder(folderId, null, const []),
      publishFolderProvider: (_) async {},
      publishFileProvider: (_) async {},
      registerSource: (_) {},
      registryPath: ':memory:',
    );
    mgr.defaultDownloadRoot = root.path;
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  List<String> dirNames(Map<String, dynamic> level) => [
        for (final d in (level['dirs'] as List)) (d as Map)['name'] as String,
      ];
  List<Map> torrents(Map<String, dynamic> level) =>
      (level['torrents'] as List).cast<Map>();

  test('a downloaded torrent materializes as a real dir and lists at root',
      () async {
    final id = 'a' * 64;
    final dir = await mgr.addDownloaded(id, 'Big Buck Bunny');
    expect(dir, isNotNull);
    expect(Directory(dir!).existsSync(), isTrue);
    expect(File('$dir/.torrent.json').existsSync(), isTrue);

    await mgr.writeDownloadedFile(id, 'movie.bin', Uint8List.fromList([1, 2, 3]));
    expect(File('$dir/movie.bin').readAsBytesSync(), [1, 2, 3]);

    final root0 = mgr.libraryLevel('');
    final t = torrents(root0);
    expect(t.length, 1);
    expect(t.first['folderId'], id);
    expect(t.first['name'], 'Big Buck Bunny');
    expect(t.first['owned'], isFalse);
    expect(dirNames(root0), isEmpty); // the torrent dir is not an org folder
  });

  test('subfolders organize the tree and moving a torrent relocates it',
      () async {
    final id = 'b' * 64;
    await mgr.addDownloaded(id, 'Sintel');
    expect(await mgr.createSubfolder('Movies'), isTrue);

    var root0 = mgr.libraryLevel('');
    expect(dirNames(root0), ['Movies']);
    expect(torrents(root0).length, 1); // Sintel still at root

    expect(await mgr.moveTorrent(id, 'Movies'), isTrue);

    root0 = mgr.libraryLevel('');
    expect(torrents(root0), isEmpty); // no longer at root
    final movies = mgr.libraryLevel('Movies');
    expect(torrents(movies).length, 1);
    expect(torrents(movies).first['folderId'], id);
    expect(Directory('${root.path}/Movies/Sintel').existsSync(), isTrue);
  });

  test('re-adopting an existing root picks up torrents already inside it',
      () async {
    // Simulate a previous install: a keyless torrent dir already on disk.
    final id = 'c' * 64;
    final d = Directory('${root.path}/Old/Downloaded Thing')
      ..createSync(recursive: true);
    File('${d.path}/.torrent.json')
        .writeAsStringSync('{"folderId":"$id","name":"Downloaded Thing"}');

    await mgr.adoptRoot();

    final old = mgr.libraryLevel('Old');
    expect(torrents(old).length, 1);
    expect(torrents(old).first['folderId'], id);
  });

  test('a torrent outside the root still shows (ungrouped) at the root level',
      () async {
    // An owned folder the user made somewhere else entirely.
    final outside = Directory('${tmp.path}/elsewhere/my-share')
      ..createSync(recursive: true);
    final fid = await mgr.addFromDisk(outside.path);
    expect(fid, isNotEmpty);

    final root0 = mgr.libraryLevel('');
    final ids = [for (final t in torrents(root0)) t['folderId']];
    expect(ids, contains(fid));
    expect(torrents(root0).firstWhere((t) => t['folderId'] == fid)['owned'],
        isTrue);
  });

  test('a hostile name is sanitized and can never escape the root', () async {
    // '..' segments are dropped, not honoured: this creates <root>/etc, never
    // an ancestor of the root.
    expect(await mgr.createSubfolder('../../etc'), isTrue);
    expect(Directory('${root.path}/etc').existsSync(), isTrue);
    expect(Directory('${tmp.path}/etc').existsSync(), isFalse); // no escape

    final id = 'd' * 64;
    final dir = await mgr.addDownloaded(id, '../../../pwned');
    expect(dir, isNotNull);
    expect(dir!.startsWith(root.path), isTrue);
    // Every '/' in the name was replaced, so there is no '/../' traversal — the
    // torrent dir is a single segment directly under the root.
    expect(dir.contains('/..'), isFalse);
    expect(Directory(dir).parent.path, root.path);
  });
}
