/*
 * The listing mirror: data/meta.json -> the signed op-log.
 *
 * A human writes data/meta.json inside the shared folder. The sync must turn it
 * into ONE signed setMeta, so a stranger reading the nfolder link sees a title
 * and a category WITHOUT downloading anything. This locks that mirror end to end
 * on a real directory, and locks the two ways it can go wrong: publishing the
 * listing again and again on every rescan, and quietly dropping it.
 */

import 'dart:io';

import 'package:aurora/services/folders/disk_folder.dart';
import 'package:aurora/services/folders/disk_folder_manager.dart';
import 'package:aurora/services/folders/folder_event.dart';
import 'package:aurora/services/folders/folder_keystore.dart';
import 'package:aurora/services/folders/folder_meta.dart';
import 'package:aurora/services/folders/folder_service.dart';
import 'package:aurora/services/folders/folder_state.dart';
import 'package:aurora/util/nostr_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late List<NostrEvent> published;
  late DiskFolderManager mgr;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('listing_sync');
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
      // Reduce whatever has been published so far — the real thing does the same.
      localState: (folderId) async {
        final ks = published
            .where((e) => e.kind == kKindFolderKeyset && e.pubkey == folderId)
            .toList();
        final ops = published.where((e) => e.kind == kKindFolderOp).toList();
        return reduceFolder(folderId, ks.isEmpty ? null : ks.first, ops);
      },
      publishFolderProvider: (_) async {},
      publishFileProvider: (_) async {},
      registerSource: (_) {},
      registryPath: ':memory:',
    );
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  FolderState reduce(String folderId) {
    final ks = published
        .where((e) => e.kind == kKindFolderKeyset && e.pubkey == folderId)
        .toList();
    final ops = published.where((e) => e.kind == kKindFolderOp).toList();
    return reduceFolder(folderId, ks.isEmpty ? null : ks.first, ops);
  }

  void writeListing(String json) {
    final data = Directory('${tmp.path}/data')..createSync(recursive: true);
    File('${data.path}/meta.json').writeAsStringSync(json);
  }

  test('a hand-written data/meta.json becomes the signed listing', () async {
    File('${tmp.path}/movie.bin').writeAsBytesSync(List.filled(2048, 7));
    writeListing('''
    {
      "title": "Big Buck Bunny",
      "desc": "A large rabbit deals with three bullies.",
      "cat": "film",
      "tags": ["1080p", "animation"],
      "adult": false,
      "cover": "cover.png"
    }''');

    final folderId = await mgr.addFromDisk(tmp.path);
    expect(folderId, isNotEmpty);

    final state = reduce(folderId);
    // The listing rode the op-log — this is what a stranger reads first.
    expect(state.title, 'Big Buck Bunny');
    expect(state.cat, 'film');
    expect(state.tags, '1080p, animation');
    expect(state.adult, isFalse);

    // And data/ itself is published like any other file, so it TRAVELS.
    final names = state.files.values.map((f) => f.name).toSet();
    expect(names, contains('data/meta.json'));
    expect(names, contains('movie.bin'));
  });

  test('rescanning an unchanged listing does not republish it', () async {
    File('${tmp.path}/a.bin').writeAsBytesSync([1, 2, 3]);
    writeListing('{"title":"Thing","cat":"game"}');
    final folderId = await mgr.addFromDisk(tmp.path);

    final after = published.where((e) => e.content.contains('setMeta')).length;
    await mgr.sync(folderId);
    await mgr.sync(folderId);
    final now = published.where((e) => e.content.contains('setMeta')).length;

    // A setMeta per rescan would grow the op-log forever for no reason.
    expect(now, after, reason: 'the listing was republished with no change');
  });

  test('editing the listing on disk republishes it', () async {
    File('${tmp.path}/a.bin').writeAsBytesSync([1, 2, 3]);
    writeListing('{"title":"First","cat":"book"}');
    final folderId = await mgr.addFromDisk(tmp.path);
    expect(reduce(folderId).title, 'First');

    // The publisher opens meta.json in a text editor and fixes it.
    writeListing('{"title":"Second","cat":"manga","adult":true}');
    await mgr.sync(folderId);

    final state = reduce(folderId);
    expect(state.title, 'Second');
    expect(state.cat, 'manga');
    expect(state.adult, isTrue);
  });

  test('a folder with no listing publishes no setMeta and still works',
      () async {
    File('${tmp.path}/a.bin').writeAsBytesSync([9, 9, 9]);
    final folderId = await mgr.addFromDisk(tmp.path);
    final state = reduce(folderId);
    expect(state.title, isNull);
    expect(state.cat, isNull);
    expect(state.files.values.map((f) => f.name), contains('a.bin'));
  });

  test('a garbage meta.json does not take the sync down with it', () async {
    File('${tmp.path}/a.bin').writeAsBytesSync([1]);
    writeListing('{{{ not json at all');
    final folderId = await mgr.addFromDisk(tmp.path);
    // The files still published; the listing simply is not there.
    final state = reduce(folderId);
    expect(state.files.values.map((f) => f.name), contains('a.bin'));
    expect(state.title, isNull);
  });

  test('readMeta / writeMeta round-trip through the real directory', () async {
    File('${tmp.path}/a.bin').writeAsBytesSync([1]);
    final folderId = await mgr.addFromDisk(tmp.path);

    expect(mgr.readMeta(folderId).isEmpty, isTrue);
    final ok = await mgr.writeMeta(
        folderId,
        const FolderMeta(title: 'Written', cat: 'software'));
    expect(ok, isTrue);
    expect(File('${tmp.path}/data/meta.json').existsSync(), isTrue);
    expect(mgr.readMeta(folderId).title, 'Written');
    expect(mgr.readMeta(folderId).cat, 'software');
  });
}
