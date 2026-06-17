import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:aurora/profile/profile_storage_io.dart';
import 'package:aurora/util/media_archive.dart';
import 'package:aurora/util/media_ref.dart';

void main() {
  // The app bundles SQLite via sqlite3_flutter_libs; the test VM only has the
  // versioned system lib, so point the loader at it.
  setUpAll(() {
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
  });

  final temps = <Directory>[];
  (MediaArchive, Directory) freshArchive() {
    final dir = Directory.systemTemp.createTempSync('mediaarch_test_');
    temps.add(dir);
    return (MediaArchive.forStorage(makeFilesystemStorage(dir.path)), dir);
  }

  tearDownAll(() {
    for (final d in temps) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Uint8List bytes(String s) => Uint8List.fromList(s.codeUnits);

  test('putBytes returns a valid wire token', () {
    final (a, _) = freshArchive();
    final token = a.putBytes(bytes('hello media'), 'png');
    final ref = MediaRef.parse(token);
    expect(ref, isNotNull);
    expect(ref!.ext, 'png');
    expect(ref.kind, MediaKind.image);
    a.close();
  });

  test('identical content dedups onto one row', () {
    final (a, _) = freshArchive();
    final t1 = a.putBytes(bytes('same'), 'jpg');
    final t2 = a.putBytes(bytes('same'), 'jpg');
    expect(t1, t2);
    expect(a.stats().count, 1);
    a.close();
  });

  test('different content gets different tokens', () {
    final (a, _) = freshArchive();
    final t1 = a.putBytes(bytes('one'), 'png');
    final t2 = a.putBytes(bytes('two'), 'png');
    expect(t1, isNot(t2));
    expect(a.stats().count, 2);
    a.close();
  });

  test('get round-trips the bytes; unknown token is null', () {
    final (a, _) = freshArchive();
    final data = bytes('round trip payload');
    final token = a.putBytes(data, 'pdf');
    expect(a.get(token), data);
    expect(
        a.get('file:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.png'), isNull);
    a.close();
  });

  test('extension is normalised (dot + case) and validated', () {
    final (a, _) = freshArchive();
    final token = a.putBytes(bytes('x'), '.JPG');
    expect(MediaRef.parse(token)!.ext, 'jpg');
    expect(() => a.putBytes(bytes('x'), 'no good'), throwsArgumentError);
    a.close();
  });

  test('metadata: stored on put, readable via getMeta, updatable', () {
    final (a, _) = freshArchive();
    final token = a.putBytes(bytes('with meta'), 'png',
        name: 'sunset.png', description: 'a sunset', tags: ['sky', 'dx']);
    final m = a.getMeta(token)!;
    expect(m.name, 'sunset.png');
    expect(m.description, 'a sunset');
    expect(m.tags, ['sky', 'dx']);
    expect(m.ext, 'png');
    expect(m.size, 'with meta'.length);
    expect(m.sha1, isNotNull);
    expect(m.tlsh, isNull); // reserved until a Dart TLSH impl exists
    expect(m.firstSeenMs, greaterThan(0));
    expect(m.hasScreenshot, isFalse);

    a.updateMeta(token, description: 'updated', tags: ['new']);
    final m2 = a.getMeta(token)!;
    expect(m2.description, 'updated');
    expect(m2.tags, ['new']);
    expect(m2.name, 'sunset.png'); // untouched
    a.close();
  });

  test('touch and re-put bump last_seen', () async {
    final (a, _) = freshArchive();
    final token = a.putBytes(bytes('ts'), 'txt');
    final first = a.getMeta(token)!.lastSeenMs;
    await Future<void>.delayed(const Duration(milliseconds: 15));
    a.touch(token);
    expect(a.getMeta(token)!.lastSeenMs, greaterThan(first));
    a.close();
  });

  test('screenshot round-trip', () {
    final (a, _) = freshArchive();
    final token = a.putBytes(bytes('shot'), 'mp4');
    expect(a.getScreenshot(token), isNull);
    final shot = bytes('PNGDATA');
    a.setScreenshot(token, shot);
    expect(a.getScreenshot(token), shot);
    expect(a.getMeta(token)!.hasScreenshot, isTrue);
    a.close();
  });

  test('has / delete', () {
    final (a, _) = freshArchive();
    final token = a.putBytes(bytes('temp'), 'zip');
    expect(a.has(token), isTrue);
    a.delete(token);
    expect(a.has(token), isFalse);
    expect(a.get(token), isNull);
    a.close();
  });

  test('get accepts a bare sha256 as well as the full token', () {
    final (a, _) = freshArchive();
    final token = a.putBytes(bytes('bare key'), 'png');
    final sha = MediaRef.parse(token)!.sha256;
    expect(a.get(sha), bytes('bare key'));
    a.close();
  });

  test('prune by count keeps the most recently accessed', () async {
    final (a, _) = freshArchive();
    final t1 = a.putBytes(bytes('old'), 'png');
    await Future<void>.delayed(const Duration(milliseconds: 15));
    final t2 = a.putBytes(bytes('new'), 'png');
    a.prune(maxCount: 1);
    expect(a.has(t1), isFalse);
    expect(a.has(t2), isTrue);
    a.close();
  });

  test('persists across close + reopen', () {
    final (a, dir) = freshArchive();
    final data = bytes('durable');
    final token =
        a.putBytes(data, 'png', name: 'keep.png', tags: ['persist']);
    a.setScreenshot(token, bytes('SHOT'));
    a.close();

    final b = MediaArchive.forStorage(makeFilesystemStorage(dir.path));
    expect(b.get(token), data);
    final m = b.getMeta(token)!;
    expect(m.name, 'keep.png');
    expect(m.tags, ['persist']);
    expect(b.getScreenshot(token), bytes('SHOT'));
    b.close();
  });

  test('stats reflect content', () {
    final (a, _) = freshArchive();
    a.putBytes(bytes('aaaa'), 'png');
    final t2 = a.putBytes(bytes('bb'), 'pdf');
    a.setScreenshot(t2, bytes('S'));
    final s = a.stats();
    expect(s.count, 2);
    expect(s.totalBytes, 6);
    expect(s.screenshotCount, 1);
    a.close();
  });

  // ── Files-wapp first-pass additions ───────────────────────────────────────

  test('FTS search by name / description / tag, and a miss', () {
    final (a, _) = freshArchive();
    final t1 = a.putBytes(bytes('fox content'), 'txt',
        name: 'fox notes', description: 'about a fox', tags: ['animals']);
    final t2 = a.putBytes(bytes('beethoven content'), 'mp3',
        name: 'beethoven 9th', tags: ['classical', 'music']);
    final s1 = MediaRef.parse(t1)!.sha256, s2 = MediaRef.parse(t2)!.sha256;
    expect(a.search('beethoven').map((m) => m.sha256), contains(s2));
    expect(a.search('fox').map((m) => m.sha256), contains(s1));
    expect(a.search('classical').map((m) => m.sha256), contains(s2));
    expect(a.search('zzzznomatch'), isEmpty);
    a.close();
  });

  test('lookupBySha exact lookup', () {
    final (a, _) = freshArchive();
    final t = a.putBytes(bytes('exact'), 'txt', name: 'exact file');
    expect(a.lookupBySha(t)?.name, 'exact file');
    final sha = MediaRef.parse(t)!.sha256;
    expect(a.lookupBySha(sha)?.name, 'exact file');
    a.close();
  });

  test('description clamped to 250 chars on put and update', () {
    final (a, _) = freshArchive();
    final t = a.putBytes(bytes('clamp'), 'txt', description: 'x' * 400);
    expect(a.getMeta(t)!.description!.length, 250);
    a.updateMeta(t, description: 'y' * 300);
    expect(a.getMeta(t)!.description!.length, 250);
    a.close();
  });

  test('folder / parent stored, searchable, and grouped', () {
    final (a, _) = freshArchive();
    final t1 = a.putBytes(bytes('track1'), 'mp3', name: 'ode to joy');
    final t2 = a.putBytes(bytes('track2'), 'mp3', name: 'scherzo');
    final t3 = a.putBytes(bytes('other'), 'txt', name: 'misc');
    a.updateMeta(t1, folder: 'Symphony No 9', parent: 'Beethoven');
    a.updateMeta(t2, folder: 'Symphony No 9', parent: 'Beethoven');

    final m1 = a.getMeta(t1)!;
    expect(m1.folder, 'Symphony No 9');
    expect(m1.parent, 'Beethoven');
    // searchable by folder/parent text
    expect(a.search('Beethoven').map((m) => m.sha256),
        contains(MediaRef.parse(t1)!.sha256));

    final album = a
        .folders()
        .where((f) => f.parent == 'Beethoven' && f.folder == 'Symphony No 9');
    expect(album, isNotEmpty);
    expect(album.first.count, 2);
    // uncategorized bucket holds t3
    expect(a.folders().any((f) => f.parent == '' && f.folder == ''), isTrue);
    expect(a.listByFolder('Beethoven', 'Symphony No 9').length, 2);
    expect(a.has(t3), isTrue);
    a.close();
  });

  test('download counter increments; defaults to 0; locally added is pinned', () {
    final (a, _) = freshArchive();
    final t = a.putBytes(bytes('dl'), 'bin');
    expect(a.getMeta(t)!.downloads, 0);
    expect(a.getMeta(t)!.pinned, isTrue);
    a.incrementDownloads(t);
    a.incrementDownloads(t);
    expect(a.getMeta(t)!.downloads, 2);
    a.close();
  });

  test('delete also removes the file from the FTS index', () {
    final (a, _) = freshArchive();
    final t = a.putBytes(bytes('bye'), 'txt', name: 'shopping list');
    expect(a.search('shopping'), isNotEmpty);
    a.delete(t);
    expect(a.search('shopping'), isEmpty);
    a.close();
  });

  test('new columns persist across reopen', () {
    final (a, dir) = freshArchive();
    final t = a.putBytes(bytes('persist cols'), 'mp3', name: 'song');
    a.updateMeta(t, folder: 'Album', parent: 'Artist');
    a.incrementDownloads(t);
    a.close();
    final b = MediaArchive.forStorage(makeFilesystemStorage(dir.path));
    final m = b.getMeta(t)!;
    expect(m.folder, 'Album');
    expect(m.parent, 'Artist');
    expect(m.downloads, 1);
    expect(b.search('Album').map((x) => x.sha256), contains(MediaRef.parse(t)!.sha256));
    b.close();
  });
}
