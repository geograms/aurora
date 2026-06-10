import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:aurora/profile/profile_storage_io.dart';
import 'package:aurora/wapp/geoui/geo_chat_archive.dart';

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
  GeoChatArchive freshArchive() {
    final dir = Directory.systemTemp.createTempSync('geoarch_test_');
    temps.add(dir);
    return GeoChatArchive.forStorage(makeFilesystemStorage(dir.path));
  }

  tearDownAll(() {
    for (final d in temps) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Map<String, dynamic> msg(String from, String text, double? lat, double? lon) =>
      {
        'dir': 'in',
        'from': from,
        'text': text,
        'kind': 'msg',
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
      };

  test('archives only geo-tagged Live (">>") messages', () {
    final a = freshArchive();
    a.add(msg('AA', '>>hello near', 38.72, -9.13)); // kept
    a.add(msg('BB', 'plain position', 38.72, -9.13)); // no ">>" -> skipped
    a.add(msg('CC', '>>no coords', null, null)); // no lat/lon -> skipped
    a.add(msg('DD', '>>at null island', 0, 0)); // (0,0) -> skipped

    final r = a.query(lat: 38.72, lon: -9.13, radiusKm: 50);
    expect(r.length, 1);
    expect(r.first['from'], 'AA');
    expect(r.first['text'], '>>hello near'); // original text (marker preserved)
  });

  test('region query filters by radius and returns oldest-first', () {
    final a = freshArchive();
    a.add(msg('NEAR1', '>>m1', 38.72, -9.13));
    a.add(msg('NEAR2', '>>m2', 38.80, -9.20)); // ~10 km away
    a.add(msg('FAR', '>>far', 41.15, -8.61)); // Porto, ~270 km away

    final near = a.query(lat: 38.72, lon: -9.13, radiusKm: 50);
    expect(near.map((m) => m['from']), containsAll(['NEAR1', 'NEAR2']));
    expect(near.any((m) => m['from'] == 'FAR'), isFalse);

    final ts = near.map((m) => (m['t'] as num).toInt()).toList();
    final sorted = [...ts]..sort();
    expect(ts, sorted); // oldest-first

    final wide = a.query(lat: 38.72, lon: -9.13, radiusKm: 500);
    expect(wide.any((m) => m['from'] == 'FAR'), isTrue);
  });

  test('dedups identical (from,text) within the window', () {
    final a = freshArchive();
    a.add(msg('AA', '>>same', 38.72, -9.13));
    a.add(msg('AA', '>>same', 38.72, -9.13)); // duplicate -> ignored
    a.add(msg('AA', '>>different', 38.72, -9.13));
    final r = a.query(lat: 38.72, lon: -9.13, radiusKm: 50);
    expect(r.length, 2);
  });

  test('limit returns the newest N (oldest-first)', () {
    final a = freshArchive();
    for (var i = 0; i < 10; i++) {
      a.add(msg('S$i', '>>msg $i', 38.72, -9.13));
    }
    final r = a.query(lat: 38.72, lon: -9.13, radiusKm: 50, limit: 3);
    expect(r.length, 3);
    expect(r.map((m) => m['text']), ['>>msg 7', '>>msg 8', '>>msg 9']);
  });

  test('sinceMs bounds how far back results go', () {
    final a = freshArchive();
    a.add(msg('AA', '>>old-but-now', 38.72, -9.13));
    final future = DateTime.now().millisecondsSinceEpoch + 60000;
    final r = a.query(lat: 38.72, lon: -9.13, radiusKm: 50, sinceMs: future);
    expect(r, isEmpty);
  });

  test('data survives reopening the database (persistence)', () {
    final dir = Directory.systemTemp.createTempSync('geoarch_persist_');
    temps.add(dir);
    final a = GeoChatArchive.forStorage(makeFilesystemStorage(dir.path));
    a.add(msg('AA', '>>persisted', 38.72, -9.13));
    a.close();
    // Re-open a brand new archive over the same file (bypass the instance cache
    // by constructing against the same path through a new storage object).
    final b = GeoChatArchive.forStorage(makeFilesystemStorage(dir.path));
    final r = b.query(lat: 38.72, lon: -9.13, radiusKm: 50);
    expect(r.length, 1);
    expect(r.first['text'], '>>persisted');
  });
}
