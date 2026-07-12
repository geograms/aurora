/// Database schema and migrations.
library;

import 'package:sqlite3/sqlite3.dart';

import 'options.dart';

/// Current schema version.
const int currentSchemaVersion = 1;

/// Magic string identifying archive format.
const String archiveMagic = 'EARCH01';

/// Configure SQLite pragmas for optimal performance.
void configurePragmas(Database db, ArchiveOptions options) {
  db.execute('PRAGMA page_size = ${options.pageSize};');
  db.execute('PRAGMA cache_size = ${options.cacheSize};');
  db.execute('PRAGMA temp_store = MEMORY;');
  db.execute('PRAGMA foreign_keys = ON;');

  if (options.enableWAL) {
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA synchronous = NORMAL;');
  } else {
    db.execute('PRAGMA journal_mode = DELETE;');
    db.execute('PRAGMA synchronous = FULL;');
  }

  if (options.mmapSize > 0) {
    db.execute('PRAGMA mmap_size = ${options.mmapSize};');
  }
}

/// Create all tables for a new archive.
void createSchema(Database db) {
  // Archive header (singleton)
  db.execute('''
    CREATE TABLE archive_header (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      magic TEXT NOT NULL,
      schema_version INTEGER NOT NULL,
      created_at INTEGER NOT NULL,
      salt BLOB NOT NULL,
      verification_hash BLOB NOT NULL,
      encrypted_master_key BLOB,
      options_json TEXT NOT NULL,
      description TEXT
    )
  ''');

  // Files table
  db.execute('''
    CREATE TABLE files (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      path TEXT NOT NULL,
      type INTEGER NOT NULL DEFAULT 0,
      size INTEGER NOT NULL DEFAULT 0,
      stored_size INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      modified_at INTEGER NOT NULL,
      content_hash BLOB,
      encryption_nonce BLOB,
      chunk_count INTEGER NOT NULL DEFAULT 0,
      permissions INTEGER,
      symlink_target TEXT,
      metadata_json TEXT,
      deleted INTEGER NOT NULL DEFAULT 0
    )
  ''');

  // Unique path index (only for non-deleted entries)
  db.execute('''
    CREATE UNIQUE INDEX idx_files_path ON files(path) WHERE deleted = 0
  ''');

  // Index for listing directories
  db.execute('''
    CREATE INDEX idx_files_deleted ON files(deleted)
  ''');

  // Chunks table
  db.execute('''
    CREATE TABLE chunks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      file_id INTEGER NOT NULL,
      sequence INTEGER NOT NULL,
      size_plain INTEGER NOT NULL,
      size_stored INTEGER NOT NULL,
      compression INTEGER NOT NULL DEFAULT 0,
      data BLOB NOT NULL,
      auth_tag BLOB NOT NULL,
      content_hash BLOB,
      FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE,
      UNIQUE (file_id, sequence)
    )
  ''');

  // Index for reading chunks in order
  db.execute('''
    CREATE INDEX idx_chunks_file_seq ON chunks(file_id, sequence)
  ''');

  // Deduplication references (optional feature)
  db.execute('''
    CREATE TABLE dedup_refs (
      content_hash BLOB PRIMARY KEY,
      chunk_id INTEGER NOT NULL,
      ref_count INTEGER NOT NULL DEFAULT 1,
      FOREIGN KEY (chunk_id) REFERENCES chunks(id)
    )
  ''');

  // Archive statistics (singleton)
  db.execute('''
    CREATE TABLE archive_stats (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      total_files INTEGER NOT NULL DEFAULT 0,
      total_size INTEGER NOT NULL DEFAULT 0,
      total_stored_size INTEGER NOT NULL DEFAULT 0,
      total_chunks INTEGER NOT NULL DEFAULT 0,
      dedup_savings INTEGER NOT NULL DEFAULT 0,
      last_vacuum_at INTEGER,
      last_integrity_check_at INTEGER
    )
  ''');

  // Initialize stats row
  db.execute('''
    INSERT INTO archive_stats (id, total_files, total_size, total_stored_size, total_chunks, dedup_savings)
    VALUES (1, 0, 0, 0, 0, 0)
  ''');

  // Triggers for automatic stats updates
  _createStatsTriggers(db);
}

/// Create triggers to maintain stats automatically.
void _createStatsTriggers(Database db) {
  // After inserting a file (not deleted)
  db.execute('''
    CREATE TRIGGER tr_files_insert AFTER INSERT ON files
    WHEN NEW.deleted = 0 AND NEW.type = 0
    BEGIN
      UPDATE archive_stats SET
        total_files = total_files + 1,
        total_size = total_size + NEW.size,
        total_stored_size = total_stored_size + NEW.stored_size;
    END
  ''');

  // After soft-deleting a file
  db.execute('''
    CREATE TRIGGER tr_files_softdelete AFTER UPDATE ON files
    WHEN OLD.deleted = 0 AND NEW.deleted = 1 AND NEW.type = 0
    BEGIN
      UPDATE archive_stats SET
        total_files = total_files - 1,
        total_size = total_size - OLD.size,
        total_stored_size = total_stored_size - OLD.stored_size;
    END
  ''');

  // After restoring a file
  db.execute('''
    CREATE TRIGGER tr_files_restore AFTER UPDATE ON files
    WHEN OLD.deleted = 1 AND NEW.deleted = 0 AND NEW.type = 0
    BEGIN
      UPDATE archive_stats SET
        total_files = total_files + 1,
        total_size = total_size + NEW.size,
        total_stored_size = total_stored_size + NEW.stored_size;
    END
  ''');

  // After updating a live file's sizes (files are inserted with size 0 and
  // get their real sizes via updateFileStats once all chunks are written)
  db.execute('''
    CREATE TRIGGER tr_files_resize AFTER UPDATE OF size, stored_size ON files
    WHEN OLD.deleted = 0 AND NEW.deleted = 0 AND NEW.type = 0
    BEGIN
      UPDATE archive_stats SET
        total_size = total_size - OLD.size + NEW.size,
        total_stored_size = total_stored_size - OLD.stored_size + NEW.stored_size;
    END
  ''');

  // After inserting a chunk
  db.execute('''
    CREATE TRIGGER tr_chunks_insert AFTER INSERT ON chunks
    BEGIN
      UPDATE archive_stats SET total_chunks = total_chunks + 1;
    END
  ''');

  // After deleting a chunk
  db.execute('''
    CREATE TRIGGER tr_chunks_delete AFTER DELETE ON chunks
    BEGIN
      UPDATE archive_stats SET total_chunks = total_chunks - 1;
    END
  ''');
}

/// SQL statements for common operations.
class ArchiveSQL {
  // Header operations
  static const insertHeader = '''
    INSERT INTO archive_header (id, magic, schema_version, created_at, salt, verification_hash, encrypted_master_key, options_json, description)
    VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?)
  ''';

  static const selectHeader = '''
    SELECT * FROM archive_header WHERE id = 1
  ''';

  static const updateHeaderPassword = '''
    UPDATE archive_header SET salt = ?, verification_hash = ?, encrypted_master_key = ? WHERE id = 1
  ''';

  // File operations
  static const insertFile = '''
    INSERT INTO files (path, type, size, stored_size, created_at, modified_at, content_hash, encryption_nonce, chunk_count, permissions, symlink_target, metadata_json)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ''';

  static const selectFileByPath = '''
    SELECT * FROM files WHERE path = ? AND deleted = 0
  ''';

  static const selectFileById = '''
    SELECT * FROM files WHERE id = ?
  ''';

  static const listFiles = '''
    SELECT * FROM files WHERE deleted = 0 ORDER BY path
  ''';

  static const listFilesWithPrefix = '''
    SELECT * FROM files WHERE path LIKE ? AND deleted = 0 ORDER BY path
  ''';

  static const listFilesIncludingDeleted = '''
    SELECT * FROM files ORDER BY path
  ''';

  static const softDeleteFile = '''
    UPDATE files SET deleted = 1 WHERE path = ? AND deleted = 0
  ''';

  static const hardDeleteFile = '''
    DELETE FROM files WHERE id = ?
  ''';

  static const renameFile = '''
    UPDATE files SET path = ?, modified_at = ? WHERE path = ? AND deleted = 0
  ''';

  static const updateFileStats = '''
    UPDATE files SET size = ?, stored_size = ?, chunk_count = ?, content_hash = ?, modified_at = ? WHERE id = ?
  ''';

  // Chunk operations
  static const insertChunk = '''
    INSERT INTO chunks (file_id, sequence, size_plain, size_stored, compression, data, auth_tag, content_hash)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  ''';

  static const selectChunks = '''
    SELECT * FROM chunks WHERE file_id = ? ORDER BY sequence
  ''';

  static const selectChunkBySequence = '''
    SELECT * FROM chunks WHERE file_id = ? AND sequence = ?
  ''';

  static const deleteChunksByFileId = '''
    DELETE FROM chunks WHERE file_id = ?
  ''';

  // Dedup operations
  static const selectDedupRef = '''
    SELECT * FROM dedup_refs WHERE content_hash = ?
  ''';

  static const insertDedupRef = '''
    INSERT INTO dedup_refs (content_hash, chunk_id, ref_count) VALUES (?, ?, 1)
  ''';

  static const incrementDedupRef = '''
    UPDATE dedup_refs SET ref_count = ref_count + 1 WHERE content_hash = ?
  ''';

  static const decrementDedupRef = '''
    UPDATE dedup_refs SET ref_count = ref_count - 1 WHERE content_hash = ?
  ''';

  static const deleteDedupRefIfZero = '''
    DELETE FROM dedup_refs WHERE content_hash = ? AND ref_count <= 0
  ''';

  // Stats operations
  static const selectStats = '''
    SELECT * FROM archive_stats WHERE id = 1
  ''';

  static const countDirectories = '''
    SELECT COUNT(*) as count FROM files WHERE type = 1 AND deleted = 0
  ''';

  static const updateDedupSavings = '''
    UPDATE archive_stats SET dedup_savings = ? WHERE id = 1
  ''';

  static const updateVacuumTime = '''
    UPDATE archive_stats SET last_vacuum_at = ? WHERE id = 1
  ''';

  static const updateIntegrityCheckTime = '''
    UPDATE archive_stats SET last_integrity_check_at = ? WHERE id = 1
  ''';

  // Vacuum operations
  static const selectDeletedFiles = '''
    SELECT id FROM files WHERE deleted = 1
  ''';

  static const hardDeleteAllDeleted = '''
    DELETE FROM files WHERE deleted = 1
  ''';
}
