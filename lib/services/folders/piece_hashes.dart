/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * The piece-hash list of a file (docs/torrents.md §8 step 2).
 *
 * A publisher cuts each file into pieces, hashes every piece, and publishes the
 * LIST as its own content-addressed blob — naming that blob's sha256 in the
 * signed addFile op. Two things follow, and they are the whole reason the swarm
 * can be trusted:
 *
 *   * the list is authenticated by the owner's signature (the op names it), so
 *     once a downloader has bytes that hash to `ph`, every piece hash in it is
 *     the publisher's word;
 *   * therefore ONE piece from ONE stranger is verifiable on its own, before the
 *     rest of the file exists. Without this, bytes from an unknown peer can only
 *     be checked after the last byte of the whole file — which is why a naive
 *     multi-peer fetch is unsafe, not merely slow.
 *
 * The list is just 32 bytes per piece (a 4 GB file → 4096 pieces → 128 KB), and
 * it is fetched like any other blob, from anyone.
 */

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// The piece hashes of [file], read in bounded chunks so a 4 GB file costs one
/// piece of memory rather than four gigabytes. Yields between pieces, so a big
/// hash never freezes the isolate it runs on.
Future<List<Uint8List>> pieceHashesOfFile(File file, int pieceSize) async {
  final out = <Uint8List>[];
  final raf = await file.open();
  try {
    var buf = BytesBuilder(copy: false);
    var inPiece = 0;
    var sinceYield = 0;
    const chunkSize = 1 << 16; // 64 KiB
    while (true) {
      final want = pieceSize - inPiece;
      final chunk = await raf.read(want < chunkSize ? want : chunkSize);
      if (chunk.isEmpty) break;
      buf.add(chunk);
      inPiece += chunk.length;
      if (inPiece >= pieceSize) {
        out.add(Uint8List.fromList(
            crypto.sha256.convert(buf.takeBytes()).bytes));
        buf = BytesBuilder(copy: false);
        inPiece = 0;
      }
      if (++sinceYield >= 64) {
        sinceYield = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (inPiece > 0) {
      out.add(
          Uint8List.fromList(crypto.sha256.convert(buf.takeBytes()).bytes));
    }
  } finally {
    await raf.close();
  }
  return out;
}

/// The piece hashes of bytes already in memory.
List<Uint8List> pieceHashesOfBytes(Uint8List bytes, int pieceSize) {
  final out = <Uint8List>[];
  for (var o = 0; o < bytes.length; o += pieceSize) {
    final end =
        (o + pieceSize > bytes.length) ? bytes.length : o + pieceSize;
    out.add(Uint8List.fromList(
        crypto.sha256.convert(Uint8List.sublistView(bytes, o, end)).bytes));
  }
  return out;
}

/// The hashes packed for publication: one 32-byte hash after another. This blob
/// is what `ph` names, and what a downloader verifies before believing a hash in
/// it.
Uint8List packPieceHashes(List<Uint8List> hashes) {
  final out = Uint8List(hashes.length * 32);
  for (var i = 0; i < hashes.length; i++) {
    out.setRange(i * 32, i * 32 + 32, hashes[i]);
  }
  return out;
}

/// The inverse. Returns null when [blob] is not a whole number of hashes — a
/// list we cannot read is a list we must not guess at.
List<Uint8List>? unpackPieceHashes(Uint8List blob) {
  if (blob.isEmpty || blob.length % 32 != 0) return null;
  return [
    for (var i = 0; i < blob.length; i += 32)
      Uint8List.fromList(Uint8List.sublistView(blob, i, i + 32)),
  ];
}
