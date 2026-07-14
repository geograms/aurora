/*
 * DiskFolderSource — serve an owner's on-disk directory by content hash, WITHOUT
 * copying the files into the sqlite archive. Indexes a directory (sha256 -> path)
 * and serves bytes straight from disk. The folder's master key file and dotfiles
 * are excluded from the index so they are never published or served.
 *
 * Headless: dart:io + crypto only. Used by disk_folder_manager (owner sync) and
 * registered into the file node's serve source via CompositeFileSource.
 */
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../files/file_transfer.dart' show FileSource;

/// The hidden key file kept inside an owned folder (excluded from sharing).
const String kFolderKeyFile = '.folder.json';

class DiskFile {
  final String sha; // sha256 hex (64)
  final String name; // path relative to the folder root, '/'-separated
  final int size;
  final String path; // absolute path on disk
  final int mtimeMs; // file modified time (epoch ms)
  const DiskFile(this.sha, this.name, this.size, this.path,
      [this.mtimeMs = 0]);

  String get ext {
    final dot = name.lastIndexOf('.');
    final slash = name.lastIndexOf('/');
    return (dot > slash && dot >= 0) ? name.substring(dot + 1).toLowerCase() : 'bin';
  }
}

/// One cached hash result, keyed by absolute path. Lets a re-scan skip
/// re-hashing a file whose size and mtime are unchanged.
class _HashEntry {
  final int size;
  final int mtimeMs;
  final String sha;
  const _HashEntry(this.size, this.mtimeMs, this.sha);
}

/// Catches the single [crypto.Digest] emitted by a chunked sha256 conversion.
class _DigestCatcher implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

class DiskFolderSource implements FileSource {
  final String dirPath;
  final Map<String, String> _byHash = {}; // hex32 -> absolute path
  // Per-file hash cache so a re-scan only re-reads files that actually changed
  // (the sync timer rescans every 60s — without this it re-hashed everything).
  final Map<String, _HashEntry> _hashCache = {}; // abs path -> entry
  List<DiskFile> _files = const [];

  DiskFolderSource(this.dirPath);

  List<DiskFile> get files => _files;
  int get fileCount => _files.length;

  /// (Re)build the index from the directory contents. Returns the file list.
  List<DiskFile> scan() {
    final out = <DiskFile>[];
    _byHash.clear();
    final root = Directory(dirPath);
    if (!root.existsSync()) {
      _files = const [];
      return _files;
    }
    final base = root.absolute.path;
    final seen = <String>{};
    for (final e in root.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final abs = e.absolute.path;
      var rel = abs.startsWith(base) ? abs.substring(base.length) : abs;
      rel = rel.replaceAll('\\', '/');
      if (rel.startsWith('/')) rel = rel.substring(1);
      // Skip the key file and any dot-prefixed file or path segment.
      if (rel.isEmpty) continue;
      if (rel == kFolderKeyFile) continue;
      if (rel.split('/').any((s) => s.startsWith('.'))) continue;
      try {
        final stat = e.statSync();
        final size = stat.size;
        final mtime = stat.modified.millisecondsSinceEpoch;
        final cached = _hashCache[abs];
        final String sha;
        if (cached != null && cached.size == size && cached.mtimeMs == mtime) {
          sha = cached.sha; // unchanged — reuse, no re-read
        } else {
          sha = _hashFile(e); // streaming hash, bounded memory
          _hashCache[abs] = _HashEntry(size, mtime, sha);
        }
        seen.add(abs);
        _byHash[sha] = abs;
        out.add(DiskFile(sha, rel, size, abs, mtime));
      } catch (_) {
        // unreadable file — skip it
      }
    }
    // Drop cache entries for files that vanished.
    _hashCache.removeWhere((k, _) => !seen.contains(k));
    _files = out;
    return out;
  }

  /// sha256 of a file read in fixed-size chunks, so memory stays bounded
  /// regardless of file size (the old readAsBytesSync loaded the whole file —
  /// over a big shared tree that was the out-of-memory).
  static String _hashFile(File f) {
    final catcher = _DigestCatcher();
    final input = crypto.sha256.startChunkedConversion(catcher);
    final raf = f.openSync();
    try {
      const chunkSize = 1 << 16; // 64 KiB
      while (true) {
        final chunk = raf.readSync(chunkSize);
        if (chunk.isEmpty) break;
        input.add(chunk);
      }
    } finally {
      raf.closeSync();
    }
    input.close();
    return _hex(catcher.value!.bytes);
  }

  /// Like [_hashFile] but yields to the event loop periodically so hashing a
  /// large file never freezes the UI isolate.
  static Future<String> _hashFileAsync(File f) async {
    final catcher = _DigestCatcher();
    final input = crypto.sha256.startChunkedConversion(catcher);
    final raf = await f.open();
    try {
      const chunkSize = 1 << 16; // 64 KiB
      var sinceYield = 0;
      while (true) {
        final chunk = await raf.read(chunkSize);
        if (chunk.isEmpty) break;
        input.add(chunk);
        if (++sinceYield >= 64) {
          // ~4 MiB between yields
          sinceYield = 0;
          await Future<void>.delayed(Duration.zero);
        }
      }
    } finally {
      await raf.close();
    }
    input.close();
    return _hex(catcher.value!.bytes);
  }

  /// (Re)build the index asynchronously, yielding between files so a large
  /// shared folder is indexed in the background without freezing the UI. Same
  /// result as [scan]; used at startup and by the periodic owner sync.
  Future<List<DiskFile>> scanAsync() async {
    final out = <DiskFile>[];
    final byHash = <String, String>{};
    final root = Directory(dirPath);
    if (!root.existsSync()) {
      _byHash.clear();
      _files = const [];
      return _files;
    }
    final base = root.absolute.path;
    final seen = <String>{};
    var sinceYield = 0;
    for (final e in root.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final abs = e.absolute.path;
      var rel = abs.startsWith(base) ? abs.substring(base.length) : abs;
      rel = rel.replaceAll('\\', '/');
      if (rel.startsWith('/')) rel = rel.substring(1);
      if (rel.isEmpty) continue;
      if (rel == kFolderKeyFile) continue;
      if (rel.split('/').any((s) => s.startsWith('.'))) continue;
      try {
        final stat = e.statSync();
        final size = stat.size;
        final mtime = stat.modified.millisecondsSinceEpoch;
        final cached = _hashCache[abs];
        final String sha;
        if (cached != null && cached.size == size && cached.mtimeMs == mtime) {
          sha = cached.sha;
        } else {
          sha = await _hashFileAsync(e);
          _hashCache[abs] = _HashEntry(size, mtime, sha);
        }
        seen.add(abs);
        byHash[sha] = abs;
        out.add(DiskFile(sha, rel, size, abs, mtime));
      } catch (_) {}
      if (++sinceYield >= 16) {
        sinceYield = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }
    _hashCache.removeWhere((k, _) => !seen.contains(k));
    // Swap in the freshly-built index atomically.
    _byHash
      ..clear()
      ..addAll(byHash);
    _files = out;
    return out;
  }

  @override
  Uint8List? read(Uint8List fileHash) {
    final path = _byHash[_hex(fileHash)];
    if (path == null) return null;
    try {
      return File(path).readAsBytesSync();
    } catch (_) {
      return null;
    }
  }

  bool has(Uint8List fileHash) => _byHash.containsKey(_hex(fileHash));

  /// The file's real path on disk, when this folder is the one serving it.
  /// Opening a file with the OS needs a PATH, not bytes — [read] would pull the
  /// whole thing into memory to hand a viewer something it can open itself.
  String? pathOfHex(String shaHex) => _byHash[shaHex.toLowerCase()];

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
