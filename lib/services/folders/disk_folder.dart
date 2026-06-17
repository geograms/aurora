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
  const DiskFile(this.sha, this.name, this.size, this.path);

  String get ext {
    final dot = name.lastIndexOf('.');
    final slash = name.lastIndexOf('/');
    return (dot > slash && dot >= 0) ? name.substring(dot + 1).toLowerCase() : 'bin';
  }
}

class DiskFolderSource implements FileSource {
  final String dirPath;
  final Map<String, String> _byHash = {}; // hex32 -> absolute path
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
        final bytes = e.readAsBytesSync();
        final sha = _hex(crypto.sha256.convert(bytes).bytes);
        _byHash[sha] = abs;
        out.add(DiskFile(sha, rel, bytes.length, abs));
      } catch (_) {
        // unreadable file — skip it
      }
    }
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

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
