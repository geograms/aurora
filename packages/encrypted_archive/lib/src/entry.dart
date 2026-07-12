/// Archive entry data model.
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'options.dart';

/// Represents a file, directory, or symlink in the archive.
@immutable
class ArchiveEntry {
  /// Internal database ID.
  final int id;

  /// Path within the archive (forward-slash separated).
  final String path;

  /// Type of entry (file, directory, symlink).
  final ArchiveEntryType type;

  /// Uncompressed size in bytes (0 for directories).
  final int size;

  /// Compressed/encrypted size in bytes.
  final int storedSize;

  /// When the entry was created.
  final DateTime createdAt;

  /// When the entry was last modified.
  final DateTime modifiedAt;

  /// SHA-256 hash of uncompressed content (files only).
  final Uint8List? contentHash;

  /// Number of chunks storing this file's data.
  final int chunkCount;

  /// POSIX file permissions (optional).
  final int? permissions;

  /// Symlink target path (symlinks only).
  final String? symlinkTarget;

  /// Custom metadata key-value pairs.
  final Map<String, String>? metadata;

  const ArchiveEntry({
    required this.id,
    required this.path,
    required this.type,
    required this.size,
    required this.storedSize,
    required this.createdAt,
    required this.modifiedAt,
    this.contentHash,
    required this.chunkCount,
    this.permissions,
    this.symlinkTarget,
    this.metadata,
  });

  /// File name (last path component).
  String get name => p.basename(path);

  /// Parent directory path.
  String get parentPath {
    final parent = p.dirname(path);
    return parent == '.' ? '' : parent;
  }

  /// File extension (including dot), or empty string.
  String get extension => p.extension(path);

  /// Compression ratio (stored/original), or 1.0 if no compression.
  double get compressionRatio {
    if (size == 0) return 1.0;
    return storedSize / size;
  }

  /// Bytes saved by compression.
  int get spaceSaved => size > storedSize ? size - storedSize : 0;

  /// Whether this is a regular file.
  bool get isFile => type == ArchiveEntryType.file;

  /// Whether this is a directory.
  bool get isDirectory => type == ArchiveEntryType.directory;

  /// Whether this is a symbolic link.
  bool get isSymlink => type == ArchiveEntryType.symlink;

  /// Human-readable size string.
  String get sizeString => _formatBytes(size);

  /// Human-readable stored size string.
  String get storedSizeString => _formatBytes(storedSize);

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// Create from database row.
  factory ArchiveEntry.fromRow(Map<String, dynamic> row) {
    return ArchiveEntry(
      id: row['id'] as int,
      path: row['path'] as String,
      type: ArchiveEntryType.values[row['type'] as int],
      size: row['size'] as int,
      storedSize: row['stored_size'] as int,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      modifiedAt:
          DateTime.fromMillisecondsSinceEpoch(row['modified_at'] as int),
      contentHash: row['content_hash'] as Uint8List?,
      chunkCount: row['chunk_count'] as int,
      permissions: row['permissions'] as int?,
      symlinkTarget: row['symlink_target'] as String?,
      metadata: row['metadata_json'] != null
          ? _parseMetadata(row['metadata_json'] as String)
          : null,
    );
  }

  static Map<String, String>? _parseMetadata(String json) {
    // Simple JSON parsing for metadata
    if (json.isEmpty || json == '{}') return null;
    try {
      // Remove braces and parse key-value pairs
      final content = json.substring(1, json.length - 1);
      if (content.isEmpty) return null;

      final result = <String, String>{};
      // Simple regex-based parsing for {"key":"value",...} format
      final pattern = RegExp(r'"([^"]+)"\s*:\s*"([^"]*)"');
      for (final match in pattern.allMatches(content)) {
        result[match.group(1)!] = match.group(2)!;
      }
      return result.isEmpty ? null : result;
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArchiveEntry &&
          id == other.id &&
          path == other.path &&
          type == other.type;

  @override
  int get hashCode => Object.hash(id, path, type);

  @override
  String toString() {
    final typeStr = switch (type) {
      ArchiveEntryType.file => 'F',
      ArchiveEntryType.directory => 'D',
      ArchiveEntryType.symlink => 'L',
    };
    return 'ArchiveEntry[$typeStr]($path, $sizeString)';
  }
}

/// Statistics about the archive.
@immutable
class ArchiveStats {
  /// Total number of active files.
  final int totalFiles;

  /// Total number of directories.
  final int totalDirectories;

  /// Sum of uncompressed file sizes.
  final int totalSize;

  /// Sum of stored (compressed/encrypted) sizes.
  final int totalStoredSize;

  /// Total number of chunks.
  final int totalChunks;

  /// Bytes saved by deduplication.
  final int dedupSavings;

  /// When the archive was last vacuumed.
  final DateTime? lastVacuumAt;

  /// When integrity was last verified.
  final DateTime? lastIntegrityCheckAt;

  const ArchiveStats({
    required this.totalFiles,
    required this.totalDirectories,
    required this.totalSize,
    required this.totalStoredSize,
    required this.totalChunks,
    required this.dedupSavings,
    this.lastVacuumAt,
    this.lastIntegrityCheckAt,
  });

  /// Total entries (files + directories).
  int get totalEntries => totalFiles + totalDirectories;

  /// Overall compression ratio.
  double get compressionRatio {
    if (totalSize == 0) return 1.0;
    return totalStoredSize / totalSize;
  }

  /// Total bytes saved by compression and deduplication.
  int get totalSavings {
    final compressionSaved = totalSize > totalStoredSize
        ? totalSize - totalStoredSize
        : 0;
    return compressionSaved + dedupSavings;
  }

  /// Percentage of space saved.
  double get savingsPercent {
    if (totalSize == 0) return 0;
    return (totalSavings / totalSize) * 100;
  }

  /// Create from database row.
  factory ArchiveStats.fromRow(Map<String, dynamic> row, int dirCount) {
    return ArchiveStats(
      totalFiles: row['total_files'] as int? ?? 0,
      totalDirectories: dirCount,
      totalSize: row['total_size'] as int? ?? 0,
      totalStoredSize: row['total_stored_size'] as int? ?? 0,
      totalChunks: row['total_chunks'] as int? ?? 0,
      dedupSavings: row['dedup_savings'] as int? ?? 0,
      lastVacuumAt: row['last_vacuum_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['last_vacuum_at'] as int)
          : null,
      lastIntegrityCheckAt: row['last_integrity_check_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              row['last_integrity_check_at'] as int)
          : null,
    );
  }

  /// Create empty stats.
  factory ArchiveStats.empty() {
    return const ArchiveStats(
      totalFiles: 0,
      totalDirectories: 0,
      totalSize: 0,
      totalStoredSize: 0,
      totalChunks: 0,
      dedupSavings: 0,
    );
  }

  @override
  String toString() {
    return 'ArchiveStats('
        'files: $totalFiles, '
        'dirs: $totalDirectories, '
        'size: ${_formatBytes(totalSize)}, '
        'stored: ${_formatBytes(totalStoredSize)}, '
        'savings: ${savingsPercent.toStringAsFixed(1)}%)';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
