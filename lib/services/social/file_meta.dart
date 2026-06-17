/*
 * FileMeta — bridges a kind-1063 file-metadata event (the "file search" result)
 * to the actual bytes via the content-addressed file layer (slice 5).
 *
 * A file is published as a NOSTR event (kKindFileMetadata) whose tags carry the
 * sha256 and descriptive metadata; the FTS index makes it searchable by name /
 * description / topic. Once a user picks a search hit, [FileMetaResolver.fetch]
 * pulls the bytes by sha256 through FileTransferNode.resolveAndFetch (DHT lookup
 * + multi-source, integrity-verified). So "search a file" and "get a file" are
 * the same content id flowing through two existing subsystems.
 */
import 'dart:typed_data';

import '../files/file_node.dart';
import '../../util/nostr_event.dart';
import 'relay_event_store.dart' show kKindFileMetadata;

/// Tag names on a file-metadata event (NIP-94-style).
const String kFileTagSha = 'x'; // sha256 (hex, 64 chars)
const String kFileTagMime = 'm';
const String kFileTagName = 'name';
const String kFileTagSize = 'size';

class FileRef {
  final Uint8List sha256; // 32 bytes
  final String? mime;
  final String? name;
  final int? size;
  const FileRef(this.sha256, {this.mime, this.name, this.size});
}

class FileMetaResolver {
  final FileTransferNode files;
  FileMetaResolver(this.files);

  /// Parse the file reference from a kind-1063 event, or null if absent/invalid.
  static FileRef? refOf(NostrEvent e) {
    if (e.kind != kKindFileMetadata) return null;
    String? sha, mime, name, size;
    for (final t in e.tags) {
      if (t.length < 2) continue;
      switch (t[0]) {
        case kFileTagSha:
          sha = t[1];
          break;
        case kFileTagMime:
          mime = t[1];
          break;
        case kFileTagName:
          name = t[1];
          break;
        case kFileTagSize:
          size = t[1];
          break;
      }
    }
    final bytes = _unhex(sha);
    if (bytes == null || bytes.length != 32) return null;
    return FileRef(bytes, mime: mime, name: name, size: size == null ? null : int.tryParse(size));
  }

  /// Fetch the bytes referenced by a file-metadata event (DHT resolve + fetch),
  /// or null if it isn't a file event or the content can't be found/verified.
  Future<Uint8List?> fetch(NostrEvent e,
      {Duration timeout = const Duration(seconds: 60)}) async {
    final ref = refOf(e);
    if (ref == null) return null;
    return files.resolveAndFetch(ref.sha256, timeout: timeout);
  }

  static Uint8List? _unhex(String? h) {
    if (h == null || h.isEmpty || h.length.isOdd) return null;
    final out = Uint8List(h.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final b = int.tryParse(h.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) return null;
      out[i] = b;
    }
    return out;
  }
}
