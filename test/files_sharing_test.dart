import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:aurora/profile/profile_storage_io.dart';
import 'package:aurora/services/blossom_server.dart';
import 'package:aurora/services/torrent_service.dart';
import 'package:aurora/util/media_archive.dart';
import 'package:aurora/util/media_ref.dart';

void main() {
  setUpAll(() {
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
  });

  final temps = <Directory>[];
  (MediaArchive, Directory) freshArchive() {
    final dir = Directory.systemTemp.createTempSync('filesshare_test_');
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

  group('digest encodings', () {
    test('b64u <-> hex round-trips', () {
      final (a, _) = freshArchive();
      final token = a.putBytes(bytes('hex me'), 'png');
      final ref = MediaRef.parse(token)!;
      final hex = ref.sha256Hex;
      expect(hex.length, 64);
      expect(MediaRef.hexToB64u(hex), ref.sha256);
      expect(MediaRef.b64uToHex(ref.sha256), hex);
      // The archive accepts the hex form directly.
      expect(a.get(hex), bytes('hex me'));
      a.close();
    });
  });

  group('sources index', () {
    test('addSource / getSources round-trip with kinds', () {
      final (a, _) = freshArchive();
      final token = a.putBytes(bytes('sourced'), 'png');
      a.addSource(token, 'blossom', 'http://10.0.0.2:3457');
      a.addSource(token, 'infohash', 'a' * 40);
      a.addSource(token, 'blossom', 'http://10.0.0.2:3457'); // dedup
      expect(a.getSources(token), hasLength(2));
      expect(a.getSources(token, kind: 'blossom'),
          [('blossom', 'http://10.0.0.2:3457')]);
      a.close();
    });
  });

  group('BlossomServer', () {
    test('GET/HEAD serve archived blobs; unknown is 404', () async {
      final (a, _) = freshArchive();
      final token = a.putBytes(bytes('blossom payload'), 'png');
      final hex = MediaRef.parse(token)!.sha256Hex;
      final srv = BlossomServer.instance;
      expect(await srv.start(a, port: 0), isTrue);
      final port = srv.port;
      final client = HttpClient();
      try {
        // GET with and without the extension suffix.
        for (final path in ['/$hex', '/$hex.png']) {
          final res = await (await client
                  .getUrl(Uri.parse('http://127.0.0.1:$port$path')))
              .close();
          expect(res.statusCode, 200, reason: path);
          final body = await res.fold<List<int>>([], (b, c) => b..addAll(c));
          expect(utf8.decode(body), 'blossom payload');
          expect(res.headers.contentType?.mimeType, 'image/png');
        }
        // HEAD: headers only.
        final head = await (await client.openUrl(
                'HEAD', Uri.parse('http://127.0.0.1:$port/$hex')))
            .close();
        expect(head.statusCode, 200);
        expect(head.headers.value('content-length'), '15');
        // Unknown hash → 404.
        final miss = await (await client.getUrl(
                Uri.parse('http://127.0.0.1:$port/${'0' * 64}')))
            .close();
        expect(miss.statusCode, 404);
      } finally {
        client.close(force: true);
        await srv.stop();
        a.close();
      }
    });

    test('PUT /upload stores when enabled, 403 when disabled', () async {
      final (a, _) = freshArchive();
      final srv = BlossomServer.instance;
      expect(await srv.start(a, port: 0), isTrue);
      final port = srv.port;
      final client = HttpClient();
      try {
        srv.uploadsEnabled = false;
        var req = await client
            .putUrl(Uri.parse('http://127.0.0.1:$port/upload'));
        req.add(bytes('uploaded content'));
        expect((await req.close()).statusCode, 403);

        srv.uploadsEnabled = true;
        req = await client.putUrl(Uri.parse('http://127.0.0.1:$port/upload'));
        req.headers.contentType = ContentType('image', 'png');
        req.add(bytes('uploaded content'));
        final res = await req.close();
        expect(res.statusCode, 200);
        final body = utf8.decode(
            await res.fold<List<int>>([], (b, c) => b..addAll(c)));
        final desc = jsonDecode(body) as Map<String, dynamic>;
        expect(desc['size'], 16);
        expect(a.get(desc['sha256'] as String), bytes('uploaded content'));
      } finally {
        srv.uploadsEnabled = false;
        client.close(force: true);
        await srv.stop();
        a.close();
      }
    });

    test('fetchFrom pulls a blob from a peer server and verifies it',
        () async {
      final (provider, _) = freshArchive();
      final (fetcher, _) = freshArchive();
      final token = provider.putBytes(bytes('shared between stations'), 'pdf');
      final ref = MediaRef.parse(token)!;
      final srv = BlossomServer.instance;
      expect(await srv.start(provider, port: 0), isTrue);
      try {
        expect(fetcher.has(ref.sha256), isFalse);
        final got = await BlossomServer.fetchFrom(
            'http://127.0.0.1:${srv.port}', ref.sha256Hex, 'pdf', fetcher);
        expect(got, token);
        expect(fetcher.get(ref.sha256), bytes('shared between stations'));
      } finally {
        await srv.stop();
        provider.close();
        fetcher.close();
      }
    });
  });

  group('TorrentService determinism', () {
    test('piece length formula is stable and clamped', () {
      expect(TorrentService.pieceLengthFor(0), 16384);
      expect(TorrentService.pieceLengthFor(10), 16384);
      expect(TorrentService.pieceLengthFor(16384 * 1024), 16384);
      expect(TorrentService.pieceLengthFor(1 << 30), 1 << 20);
      expect(TorrentService.pieceLengthFor(1 << 40), 4 * 1024 * 1024);
    });

    test('two stations derive the same infohash for the same bytes',
        () async {
      final (a1, d1) = freshArchive();
      final (a2, d2) = freshArchive();
      final data = bytes('identical content on two devices ' * 100);
      final t1 = a1.putBytes(data, 'png');
      final t2 = a2.putBytes(data, 'png');
      expect(t1, t2);
      final s1 = TorrentService.instance..configure(a1, '${d1.path}/share');
      final m1 = await s1.buildTorrent(t1);
      final s2 = TorrentService.instance..configure(a2, '${d2.path}/share');
      final m2 = await s2.buildTorrent(t2);
      expect(m1, isNotNull);
      expect(m2, isNotNull);
      expect(m1!.infoHash, m2!.infoHash);
      expect(m1.name, '${MediaRef.parse(t1)!.sha256Hex}.png');
      a1.close();
      a2.close();
    });

    test('different bytes give different infohashes', () async {
      final (a, d) = freshArchive();
      final t1 = a.putBytes(bytes('content A'), 'bin');
      final t2 = a.putBytes(bytes('content B'), 'bin');
      final s = TorrentService.instance..configure(a, '${d.path}/share');
      final m1 = await s.buildTorrent(t1);
      final m2 = await s.buildTorrent(t2);
      expect(m1!.infoHash, isNot(m2!.infoHash));
      a.close();
    });

    test('magnet link carries the infohash, name and well-known trackers',
        () async {
      final (a, d) = freshArchive();
      final token = a.putBytes(bytes('share me over the internet'), 'png');
      final s = TorrentService.instance..configure(a, '${d.path}/share');
      final magnet = await s.magnetOf(token);
      final ih = await s.infohashOf(token);
      expect(magnet, isNotNull);
      expect(magnet, contains('xt=urn:btih:$ih'));
      expect(magnet, contains('tracker.opentrackr.org'));
      // Round-trips back to the same infohash a fetcher would join.
      expect(TorrentService.infohashFromMagnet(magnet!), ih);
      a.close();
    });
  });
}
