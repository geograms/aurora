/// Configuration options for encrypted archives.
library;

import 'package:meta/meta.dart';

/// Type of archive entry.
enum ArchiveEntryType {
  /// Regular file.
  file,

  /// Directory.
  directory,

  /// Symbolic link.
  symlink,
}

/// Compression algorithm.
enum CompressionType {
  /// No compression.
  none(0),

  /// Gzip compression.
  gzip(1),

  /// LZ4 compression (fast).
  lz4(2),

  /// Zstandard compression (balanced).
  zstd(3);

  /// Database storage value.
  final int value;

  const CompressionType(this.value);

  /// Create from database value.
  static CompressionType fromValue(int value) {
    return CompressionType.values.firstWhere(
      (t) => t.value == value,
      orElse: () => CompressionType.none,
    );
  }
}

/// Preset chunk sizes for different use cases.
enum ChunkSizePreset {
  /// 1 MB - Good for many small files.
  small(1024 * 1024),

  /// 16 MB - Default, balanced.
  medium(16 * 1024 * 1024),

  /// 64 MB - Good for large files.
  large(64 * 1024 * 1024),

  /// 256 MB - Maximum, for very large files.
  xlarge(256 * 1024 * 1024);

  /// Size in bytes.
  final int bytes;

  const ChunkSizePreset(this.bytes);
}

/// Archive configuration options.
@immutable
class ArchiveOptions {
  /// Maximum size of each chunk in bytes.
  /// Larger chunks = better compression, more memory usage.
  /// Default: 16 MB.
  final int chunkSize;

  /// Compression algorithm to use.
  /// Default: none.
  final CompressionType compression;

  /// Compression level (1-9, algorithm-dependent).
  /// Default: 3.
  final int compressionLevel;

  /// Enable content-addressed deduplication.
  /// Saves space when same data appears multiple times.
  /// Default: false.
  final bool enableDeduplication;

  /// Enable SQLite WAL (Write-Ahead Logging) mode.
  /// Better concurrent read performance.
  /// Default: true.
  final bool enableWAL;

  /// SQLite page size in bytes.
  /// Larger pages better for BLOBs.
  /// Default: 32768 (32 KB).
  final int pageSize;

  /// SQLite cache size.
  /// Negative value = KB, positive = pages.
  /// Default: -64000 (64 MB).
  final int cacheSize;

  /// SQLite memory-mapped I/O size.
  /// 0 = disabled.
  /// Default: 0.
  final int mmapSize;

  /// Argon2id time cost (iterations).
  /// Higher = slower but more secure.
  /// Default: 3.
  final int argon2TimeCost;

  /// Argon2id memory cost in KB.
  /// Higher = more memory, more secure.
  /// Default: 65536 (64 MB).
  final int argon2MemoryCost;

  /// Argon2id parallelism (threads).
  /// Default: 1.
  final int argon2Parallelism;

  /// Create custom archive options.
  const ArchiveOptions({
    this.chunkSize = 16 * 1024 * 1024,
    this.compression = CompressionType.none,
    this.compressionLevel = 3,
    this.enableDeduplication = false,
    this.enableWAL = true,
    this.pageSize = 32768,
    this.cacheSize = -64000,
    this.mmapSize = 0,
    this.argon2TimeCost = 3,
    this.argon2MemoryCost = 65536,
    this.argon2Parallelism = 1,
  });

  /// Default options - balanced for typical use.
  static const defaultOptions = ArchiveOptions();

  /// Optimized for large files (video, backups).
  static const largeFileOptions = ArchiveOptions(
    chunkSize: 64 * 1024 * 1024,
    compression: CompressionType.zstd,
    compressionLevel: 3,
    pageSize: 65536,
    cacheSize: -128000,
  );

  /// Optimized for many small files (documents, configs).
  static const manySmallFilesOptions = ArchiveOptions(
    chunkSize: 1024 * 1024,
    compression: CompressionType.gzip,
    compressionLevel: 6,
    enableDeduplication: true,
  );

  /// High security settings (slower).
  static const highSecurityOptions = ArchiveOptions(
    argon2TimeCost: 6,
    argon2MemoryCost: 131072,
    argon2Parallelism: 2,
  );

  /// Create a copy with some values changed.
  ArchiveOptions copyWith({
    int? chunkSize,
    CompressionType? compression,
    int? compressionLevel,
    bool? enableDeduplication,
    bool? enableWAL,
    int? pageSize,
    int? cacheSize,
    int? mmapSize,
    int? argon2TimeCost,
    int? argon2MemoryCost,
    int? argon2Parallelism,
  }) {
    return ArchiveOptions(
      chunkSize: chunkSize ?? this.chunkSize,
      compression: compression ?? this.compression,
      compressionLevel: compressionLevel ?? this.compressionLevel,
      enableDeduplication: enableDeduplication ?? this.enableDeduplication,
      enableWAL: enableWAL ?? this.enableWAL,
      pageSize: pageSize ?? this.pageSize,
      cacheSize: cacheSize ?? this.cacheSize,
      mmapSize: mmapSize ?? this.mmapSize,
      argon2TimeCost: argon2TimeCost ?? this.argon2TimeCost,
      argon2MemoryCost: argon2MemoryCost ?? this.argon2MemoryCost,
      argon2Parallelism: argon2Parallelism ?? this.argon2Parallelism,
    );
  }

  /// Convert to JSON for storage.
  Map<String, dynamic> toJson() => {
        'chunkSize': chunkSize,
        'compression': compression.value,
        'compressionLevel': compressionLevel,
        'enableDeduplication': enableDeduplication,
        'enableWAL': enableWAL,
        'pageSize': pageSize,
        'cacheSize': cacheSize,
        'mmapSize': mmapSize,
        'argon2TimeCost': argon2TimeCost,
        'argon2MemoryCost': argon2MemoryCost,
        'argon2Parallelism': argon2Parallelism,
      };

  /// Create from JSON.
  factory ArchiveOptions.fromJson(Map<String, dynamic> json) {
    return ArchiveOptions(
      chunkSize: json['chunkSize'] as int? ?? 16 * 1024 * 1024,
      compression: CompressionType.fromValue(json['compression'] as int? ?? 0),
      compressionLevel: json['compressionLevel'] as int? ?? 3,
      enableDeduplication: json['enableDeduplication'] as bool? ?? false,
      enableWAL: json['enableWAL'] as bool? ?? true,
      pageSize: json['pageSize'] as int? ?? 32768,
      cacheSize: json['cacheSize'] as int? ?? -64000,
      mmapSize: json['mmapSize'] as int? ?? 0,
      argon2TimeCost: json['argon2TimeCost'] as int? ?? 3,
      argon2MemoryCost: json['argon2MemoryCost'] as int? ?? 65536,
      argon2Parallelism: json['argon2Parallelism'] as int? ?? 1,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArchiveOptions &&
          chunkSize == other.chunkSize &&
          compression == other.compression &&
          compressionLevel == other.compressionLevel &&
          enableDeduplication == other.enableDeduplication &&
          enableWAL == other.enableWAL &&
          pageSize == other.pageSize &&
          cacheSize == other.cacheSize &&
          mmapSize == other.mmapSize &&
          argon2TimeCost == other.argon2TimeCost &&
          argon2MemoryCost == other.argon2MemoryCost &&
          argon2Parallelism == other.argon2Parallelism;

  @override
  int get hashCode => Object.hash(
        chunkSize,
        compression,
        compressionLevel,
        enableDeduplication,
        enableWAL,
        pageSize,
        cacheSize,
        mmapSize,
        argon2TimeCost,
        argon2MemoryCost,
        argon2Parallelism,
      );
}
