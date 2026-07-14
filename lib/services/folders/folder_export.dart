/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Materialise one file out of the content-addressed archive so the OS can open
 * it (a PDF in a reader, an APK in the installer, a photo in the gallery).
 *
 * The blob lives in a SQLite BLOB and can be tens or hundreds of MB. Reading it
 * through MediaArchive.get() would pull all of that through the isolate that
 * draws the UI, and the Dart profiler would show nothing at all because the time
 * is spent inside native sqlite (docs/performance.md §4.1, rule 10). So the read
 * and the write both happen on a WORKER isolate: one Isolate.run per user-
 * initiated open — never per item, never on a hot path (§3.1).
 */

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

import '../../profile/profile_db.dart' show engineSqliteLibrary;

/// Arguments for the worker (must be a plain, sendable value).
class _ExportJob {
  final String dbPath;
  final String key; // MediaArchive storage key (b64u), already normalised
  final String outPath;
  final String? sqliteLibrary; // see below — this is not optional on Android
  const _ExportJob(this.dbPath, this.key, this.outPath, this.sqliteLibrary);
}

/// Copy the blob for [storageKey] out of the media archive at [dbPath] into
/// [outPath], and return the path (null when the archive does not hold it).
///
/// Runs entirely off the calling isolate. Reuses an existing export when it is
/// already there and non-empty — a second tap on the same file must not rewrite
/// 300 MB.
Future<String?> exportArchiveFile({
  required String dbPath,
  required String storageKey,
  required String outPath,
}) async {
  final existing = File(outPath);
  if (existing.existsSync() && existing.lengthSync() > 0) return outPath;
  final job = _ExportJob(dbPath, storageKey, outPath, engineSqliteLibrary());
  return Isolate.run(() => _export(job));
}

String? _export(_ExportJob job) {
  Database? db;
  try {
    // The sqlite3 loader override is PER-ISOLATE. Without this the worker looks
    // for a plain libsqlite3.so that this app does not ship, the open throws,
    // and the export silently returns null — which is exactly how "Open" did
    // nothing on the phone while every other database in the app worked fine.
    final lib = job.sqliteLibrary;
    if (lib != null && lib.isNotEmpty) {
      DynamicLibrary openLib() => DynamicLibrary.open(lib);
      for (final os in sqlite_open.OperatingSystem.values) {
        sqlite_open.open.overrideFor(os, openLib);
      }
    }
    // Read-only is the right intent, but a WAL database needs to be able to
    // touch its -shm/-wal sidecars, and that open can fail. Fall back rather
    // than lose the file: we still only ever SELECT.
    try {
      db = sqlite3.open(job.dbPath, mode: OpenMode.readOnly);
    } catch (_) {
      db = sqlite3.open(job.dbPath);
    }
    final rows =
        db.select('SELECT data FROM media WHERE sha256=?', [job.key]);
    if (rows.isEmpty) return null;
    final bytes = rows.first['data'];
    if (bytes is! Uint8List || bytes.isEmpty) return null;

    final out = File(job.outPath);
    out.parent.createSync(recursive: true);
    // Write to a temp sibling and rename: a killed export must never leave a
    // half-written file behind that a later open would hand to the OS as if it
    // were whole.
    final tmp = File('${job.outPath}.part');
    tmp.writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(job.outPath);
    return job.outPath;
  } catch (_) {
    return null;
  } finally {
    db?.dispose();
  }
}
