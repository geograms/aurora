/*
 * Persistent index of files served straight from disk (owner disk folders),
 * keyed by content hash. The bytes live on disk (never copied into the blob
 * archive); this is the durable, queryable inventory of what we serve from
 * there: sha256 -> {path, size, mtime, folderId, name}.
 *
 * Complements the two content stores: text notes in the relay event store
 * (social.sqlite3), binary blobs in the content-addressed archive (media), and
 * on-disk file hashes/metadata here (disk_index.sqlite3). Survives restarts so a
 * re-scan is incremental and the host has a content-addressable view of disk
 * files without re-hashing everything each launch.
 */
import 'package:sqlite3/sqlite3.dart';

class DiskIndexEntry {
  final String sha; // sha256 hex (64)
  final String path; // absolute path on disk
  final int size;
  final int mtimeMs;
  final String folderId;
  final String name; // logical name (relative path)
  const DiskIndexEntry(
      this.sha, this.path, this.size, this.mtimeMs, this.folderId, this.name);
}

class DiskIndex {
  final Database _db;
  DiskIndex._(this._db);

  static DiskIndex open(String path) {
    final db = sqlite3.open(path);
    db.execute('''
      CREATE TABLE IF NOT EXISTS disk_files(
        sha       TEXT NOT NULL,
        path      TEXT NOT NULL PRIMARY KEY,
        size      INTEGER NOT NULL,
        mtime     INTEGER NOT NULL,
        folder_id TEXT NOT NULL,
        name      TEXT NOT NULL
      );
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_disk_sha ON disk_files(sha);');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_disk_folder ON disk_files(folder_id);');
    return DiskIndex._(db);
  }

  /// Replace the indexed set for [folderId] with [entries] (a fresh scan). Keyed
  /// by path so a moved/renamed file updates cleanly.
  void replaceFolder(String folderId, List<DiskIndexEntry> entries) {
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM disk_files WHERE folder_id = ?', [folderId]);
      final stmt = _db.prepare(
          'INSERT OR REPLACE INTO disk_files(sha,path,size,mtime,folder_id,name) '
          'VALUES(?,?,?,?,?,?)');
      for (final e in entries) {
        stmt.execute([e.sha, e.path, e.size, e.mtimeMs, e.folderId, e.name]);
      }
      stmt.dispose();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
    }
  }

  /// The absolute path for a content hash (any folder), or null.
  String? pathForSha(String shaHex) {
    final r = _db.select(
        'SELECT path FROM disk_files WHERE sha = ? LIMIT 1', [shaHex]);
    return r.isEmpty ? null : r.first['path'] as String;
  }

  bool hasSha(String shaHex) =>
      _db.select('SELECT 1 FROM disk_files WHERE sha = ? LIMIT 1', [shaHex])
          .isNotEmpty;

  int get count =>
      _db.select('SELECT COUNT(*) c FROM disk_files').first['c'] as int;

  int totalBytes() =>
      _db.select('SELECT COALESCE(SUM(size),0) b FROM disk_files').first['b']
          as int;

  void close() => _db.dispose();
}
