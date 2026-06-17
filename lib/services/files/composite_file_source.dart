/*
 * CompositeFileSource — serve bytes from several sources, first hit wins. Lets a
 * node serve content-addressed bytes from the sqlite archive AND from any number
 * of on-disk owner folders (DiskFolderSource) under one FileSource, so disk
 * folders never need to be copied into the archive.
 */
import 'dart:typed_data';

import 'file_transfer.dart' show FileSource;

class CompositeFileSource implements FileSource {
  final List<FileSource> _sources;
  CompositeFileSource(this._sources);

  /// Add/remove sources at runtime (e.g. as owner disk folders are registered).
  void add(FileSource s) => _sources.add(s);
  void remove(FileSource s) => _sources.remove(s);

  @override
  Uint8List? read(Uint8List fileHash) {
    for (final s in _sources) {
      final b = s.read(fileHash);
      if (b != null) return b;
    }
    return null;
  }
}
