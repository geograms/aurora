/*
 * Content-addressed file manifest + chunking for the Reticulum file layer.
 *
 * A file is identified globally by the sha256 of its whole bytes (the same id
 * used by MediaArchive and the file:<sha256> media refs). To transfer it from
 * many sources and verify each piece independently, it is split into fixed-size
 * chunks and described by a small manifest: the whole-file hash, the chunk size,
 * the total size, and the sha256 of every chunk.
 *
 * A receiver fetches the manifest first, then pulls chunks (from one or many
 * providers), verifying each chunk against manifest.chunkHashes[i] as it lands
 * and finally verifying the assembled bytes' sha256 == the requested file id.
 * That final check binds an untrusted manifest to the requested content: a forged
 * manifest cannot make the assembled file hash to the id the caller asked for.
 *
 * One RNS Resource is a single segment (<= 74 parts * 464B ~= 34 KB), so the
 * chunk size is chosen to fit one Resource, and for now a file's manifest must
 * also fit one Resource (~1000 chunks, ~32 MB files). Larger files will need a
 * chunked/Merkle manifest — a later extension.
 */
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Chunk payload size. Chosen so one chunk plus the Resource stream overhead fits
/// a single RNS Resource segment (69 parts at 464B, under the 74-part cap).
const int kFileChunkSize = 32000;

const List<int> _magic = [0x46, 0x4d, 0x46, 0x31]; // 'FMF1'
const int _headerLen = 4 + 1 + 4 + 8 + 4 + 32; // magic+ver+chunkSize+size+n+hash
const int _hashLen = 32;

/// Describes a file as a whole-file hash plus the hash of each chunk.
class FileManifest {
  final Uint8List fileHash; // sha256 of the whole file (32B) = the file id
  final int size; // total byte length
  final int chunkSize; // bytes per chunk (last chunk may be shorter)
  final List<Uint8List> chunkHashes; // sha256 of each chunk (32B each)

  FileManifest({
    required this.fileHash,
    required this.size,
    required this.chunkSize,
    required this.chunkHashes,
  });

  int get chunkCount => chunkHashes.length;

  /// Byte length of chunk [i] (the last chunk may be short).
  int chunkLength(int i) {
    if (i < 0 || i >= chunkCount) return 0;
    if (i < chunkCount - 1) return chunkSize;
    final rem = size - (chunkSize * (chunkCount - 1));
    return rem;
  }

  /// Build a manifest by hashing [file] and each of its chunks.
  static FileManifest ofBytes(Uint8List file, {int chunkSize = kFileChunkSize}) {
    final fileHash =
        Uint8List.fromList(crypto.sha256.convert(file).bytes);
    final hashes = <Uint8List>[];
    if (file.isEmpty) {
      // Zero-chunk manifest; assembled bytes are empty.
    } else {
      for (var off = 0; off < file.length; off += chunkSize) {
        final end = off + chunkSize < file.length ? off + chunkSize : file.length;
        final chunk = Uint8List.sublistView(file, off, end);
        hashes.add(Uint8List.fromList(crypto.sha256.convert(chunk).bytes));
      }
    }
    return FileManifest(
      fileHash: fileHash,
      size: file.length,
      chunkSize: chunkSize,
      chunkHashes: hashes,
    );
  }

  /// Serialize: magic(4) ver(1) chunkSize(4 BE) size(8 BE) nChunks(4 BE)
  /// fileHash(32) then nChunks * chunkHash(32).
  Uint8List encode() {
    final out = Uint8List(_headerLen + chunkHashes.length * _hashLen);
    final bd = ByteData.sublistView(out);
    out.setRange(0, 4, _magic);
    bd.setUint8(4, 1); // version
    bd.setUint32(5, chunkSize, Endian.big);
    bd.setUint64(9, size, Endian.big);
    bd.setUint32(17, chunkHashes.length, Endian.big);
    out.setRange(21, 21 + _hashLen, fileHash);
    var off = _headerLen;
    for (final h in chunkHashes) {
      out.setRange(off, off + _hashLen, h);
      off += _hashLen;
    }
    return out;
  }

  /// Parse a manifest; returns null on a malformed/short/over-large blob.
  static FileManifest? decode(Uint8List b) {
    if (b.length < _headerLen) return null;
    for (var i = 0; i < 4; i++) {
      if (b[i] != _magic[i]) return null;
    }
    final bd = ByteData.sublistView(b);
    if (bd.getUint8(4) != 1) return null;
    final chunkSize = bd.getUint32(5, Endian.big);
    final size = bd.getUint64(9, Endian.big);
    final n = bd.getUint32(17, Endian.big);
    if (chunkSize <= 0 || n < 0) return null;
    if (b.length != _headerLen + n * _hashLen) return null;
    final fileHash = Uint8List.fromList(b.sublist(21, 21 + _hashLen));
    final hashes = <Uint8List>[];
    var off = _headerLen;
    for (var i = 0; i < n; i++) {
      hashes.add(Uint8List.fromList(b.sublist(off, off + _hashLen)));
      off += _hashLen;
    }
    // Consistency: declared size must agree with the chunk count + chunk size.
    if (n > 0) {
      final minSize = chunkSize * (n - 1) + 1;
      final maxSize = chunkSize * n;
      if (size < minSize || size > maxSize) return null;
    } else if (size != 0) {
      return null;
    }
    return FileManifest(
      fileHash: fileHash,
      size: size,
      chunkSize: chunkSize,
      chunkHashes: hashes,
    );
  }
}
