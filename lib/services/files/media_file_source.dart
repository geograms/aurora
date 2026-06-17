/*
 * FileSource backed by the content-addressed MediaArchive (media.sqlite3).
 *
 * Lets a serving node answer file-transfer requests with bytes it already holds
 * (received chat media, imported files, pinned content). The file-transfer
 * protocol (FileServeSession) reads whole-file bytes by sha256 through this; the
 * archive deduplicates and stores by the same sha256 id used in file:<sha256>
 * media refs, so "I received this image" automatically means "I can serve it".
 */
import 'dart:typed_data';

import '../../util/media_archive.dart';
import 'file_transfer.dart';

class MediaFileSource implements FileSource {
  final MediaArchive archive;
  MediaFileSource(this.archive);

  @override
  Uint8List? read(Uint8List fileHash) => archive.get(_hex(fileHash));

  /// Whether the archive holds [fileHash] (cheap, no blob read).
  bool has(Uint8List fileHash) => archive.has(_hex(fileHash));

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
