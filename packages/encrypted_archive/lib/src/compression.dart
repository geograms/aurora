/// Compression utilities for archive data.
library;

import 'dart:io';
import 'dart:typed_data';

import 'options.dart';

/// Compression and decompression utilities.
class Compression {
  /// Compress data using the specified algorithm.
  static Uint8List compress(
    Uint8List data,
    CompressionType type, {
    int level = 3,
  }) {
    switch (type) {
      case CompressionType.none:
        return data;

      case CompressionType.gzip:
        return _compressGzip(data, level);

      case CompressionType.lz4:
        // LZ4 not available in Dart stdlib, fall back to gzip
        return _compressGzip(data, level);

      case CompressionType.zstd:
        // Zstd not available in Dart stdlib, fall back to gzip
        return _compressGzip(data, level);
    }
  }

  /// Decompress data using the specified algorithm.
  static Uint8List decompress(Uint8List data, CompressionType type) {
    switch (type) {
      case CompressionType.none:
        return data;

      case CompressionType.gzip:
        return _decompressGzip(data);

      case CompressionType.lz4:
        // LZ4 not available, assume gzip fallback
        return _decompressGzip(data);

      case CompressionType.zstd:
        // Zstd not available, assume gzip fallback
        return _decompressGzip(data);
    }
  }

  static Uint8List _compressGzip(Uint8List data, int level) {
    // Clamp level to valid range
    level = level.clamp(1, 9);

    final codec = GZipCodec(level: level);
    return Uint8List.fromList(codec.encode(data));
  }

  static Uint8List _decompressGzip(Uint8List data) {
    final codec = GZipCodec();
    return Uint8List.fromList(codec.decode(data));
  }

  /// Estimate compression ratio for data.
  /// Returns a value between 0 and 1, lower is better compression.
  static double estimateCompressionRatio(Uint8List sample) {
    if (sample.isEmpty) return 1.0;

    // Count unique byte values and repetition patterns
    final uniqueBytes = <int>{};
    var repetitions = 0;
    var lastByte = -1;

    for (final byte in sample) {
      uniqueBytes.add(byte);
      if (byte == lastByte) {
        repetitions++;
      }
      lastByte = byte;
    }

    // Entropy-based estimate
    final uniqueRatio = uniqueBytes.length / 256;
    final repetitionRatio = repetitions / sample.length;

    // Lower unique ratio and higher repetition = better compression
    return (uniqueRatio * 0.7 + (1 - repetitionRatio) * 0.3).clamp(0.1, 1.0);
  }

  /// Check if data appears to already be compressed.
  /// Returns true if data starts with common compression signatures.
  static bool isLikelyCompressed(Uint8List data) {
    if (data.length < 4) return false;

    // Check for common compressed/binary signatures
    final signatures = [
      // GZIP
      [0x1F, 0x8B],
      // ZLIB
      [0x78, 0x01],
      [0x78, 0x5E],
      [0x78, 0x9C],
      [0x78, 0xDA],
      // ZSTD
      [0x28, 0xB5, 0x2F, 0xFD],
      // LZ4
      [0x04, 0x22, 0x4D, 0x18],
      // PNG
      [0x89, 0x50, 0x4E, 0x47],
      // JPEG
      [0xFF, 0xD8, 0xFF],
      // ZIP/JAR
      [0x50, 0x4B, 0x03, 0x04],
      // RAR
      [0x52, 0x61, 0x72, 0x21],
      // 7Z
      [0x37, 0x7A, 0xBC, 0xAF],
      // WEBP
      [0x52, 0x49, 0x46, 0x46],
    ];

    for (final sig in signatures) {
      if (data.length >= sig.length) {
        var match = true;
        for (var i = 0; i < sig.length; i++) {
          if (data[i] != sig[i]) {
            match = false;
            break;
          }
        }
        if (match) return true;
      }
    }

    return false;
  }

  /// Get the best compression type for data.
  static CompressionType recommendCompression(
    Uint8List sample,
    CompressionType preferred,
  ) {
    // Don't compress if already compressed
    if (isLikelyCompressed(sample)) {
      return CompressionType.none;
    }

    // Don't compress very small data (overhead not worth it)
    if (sample.length < 256) {
      return CompressionType.none;
    }

    // Check if compression would be effective
    final ratio = estimateCompressionRatio(sample);
    if (ratio > 0.95) {
      // High entropy, compression won't help much
      return CompressionType.none;
    }

    return preferred;
  }
}

/// Stream-based chunking utilities.
class StreamChunker {
  /// Split a stream into fixed-size chunks.
  static Stream<Uint8List> chunkStream(
    Stream<List<int>> source,
    int chunkSize,
  ) async* {
    final buffer = BytesBuilder(copy: false);

    await for (final data in source) {
      buffer.add(data);

      while (buffer.length >= chunkSize) {
        final bytes = buffer.takeBytes();
        yield Uint8List.sublistView(Uint8List.fromList(bytes), 0, chunkSize);

        if (bytes.length > chunkSize) {
          buffer.add(bytes.sublist(chunkSize));
        }
      }
    }

    // Emit remaining data
    if (buffer.isNotEmpty) {
      yield buffer.toBytes();
    }
  }

  /// Split bytes into fixed-size chunks.
  static List<Uint8List> chunkBytes(Uint8List data, int chunkSize) {
    final chunks = <Uint8List>[];
    var offset = 0;

    while (offset < data.length) {
      final end = (offset + chunkSize).clamp(0, data.length);
      chunks.add(Uint8List.sublistView(data, offset, end));
      offset = end;
    }

    return chunks;
  }
}
