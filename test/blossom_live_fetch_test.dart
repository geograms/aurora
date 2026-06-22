// Live integration check: fetch a file from an EXTERNAL Blossom origin via the
// production code path (MediaArchive.getSources -> BlossomServer.fetchFrom),
// exactly as hal_media_fetch does. Requires a Blossom origin reachable at
// $BLOSSOM_ORIGIN (default http://127.0.0.1:3460) serving the fixture file at
// /<sha256-hex>. Skips cleanly when the origin isn't up, so CI stays green.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:aurora/profile/profile_storage_io.dart';
import 'package:aurora/services/blossom_server.dart';
import 'package:aurora/util/media_archive.dart';

void main() {
  setUpAll(() {
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
  });

  test('fetch a referenced file from a remote host via a recorded source',
      () async {
    const origin =
        String.fromEnvironment('BLOSSOM_ORIGIN', defaultValue: 'http://127.0.0.1:3460');
    const hex = String.fromEnvironment('BLOSSOM_HEX',
        defaultValue:
            '01f12c427893e0a13a97c0e2d0b866b2f0914fe77cfe9913d9622faaf6624508');

    // Is the origin reachable? If not, skip (don't fail offline CI).
    final probe = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    bool up = false;
    try {
      final r = await (await probe.getUrl(Uri.parse('$origin/$hex'))).close();
      up = r.statusCode == 200;
      await r.drain<void>();
    } catch (_) {
      up = false;
    } finally {
      probe.close(force: true);
    }
    if (!up) {
      markTestSkipped('No Blossom origin at $origin — start blossom_origin.py');
      return;
    }

    final dir = Directory.systemTemp.createTempSync('blossomlive_');
    final archive = MediaArchive.forDirectory(dir.path);
    try {
      // A "phone outside the network" starts with only the announced source.
      archive.addSource(hex, 'blossom', origin);
      expect(archive.has(hex), isFalse);

      // The exact resolution hal_media_fetch performs:
      String? token;
      for (final (kind, value) in archive.getSources(hex)) {
        if (kind == 'blossom') {
          token = await BlossomServer.fetchFrom(value, hex, 'png', archive);
          if (token != null) break;
        }
      }

      expect(token, isNotNull, reason: 'fetch should succeed from $origin');
      expect(archive.has(hex), isTrue, reason: 'bytes now archived locally');
      final data = archive.get(hex)!;
      expect(data.length, greaterThan(0));
      // Now this station can itself provide the file (downloader -> provider).
      expect(MediaArchive.forDirectory(dir.path).has(hex),
          isTrue);
    } finally {
      archive.close();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });
}
