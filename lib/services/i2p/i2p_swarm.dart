/*
 * Swarm layer: BitTorrent-style collective download over the Aurora I2P node.
 *
 * Motivation: a single I2NP Data message is capped at 65535 bytes, so any file
 * over ~64 KiB cannot be moved as one datagram — it must be split into pieces.
 * Splitting also unlocks the real goal: a large file is pulled from MANY devices
 * in parallel and re-shared piece-by-piece, so a device that holds only part of
 * a file still helps seed it (like BitTorrent), instead of every download
 * hammering one device.
 *
 * We adopt the I2P BitTorrent design decisions that matter (peers identified by
 * their 32-byte destination hash — which the provider DHT already uses — and
 * PEX-style provider sharing) but ride on our own datagram transport rather than
 * the I2P streaming library, since only Aurora devices ever share Aurora content
 * (no need to interoperate with the global I2P torrent swarm).
 *
 * Manifest (deterministic from the file, content-addressed by the file's own
 * sha256 so any seeder produces the identical one):
 *   'AMT1'(4) fileSha(32) totalLen(8 BE) pieceLen(4 BE) pieceCount(4 BE)
 *   pieceCount * pieceSha256(32)
 *
 * Datagram payloads (first byte = opcode), each request carrying the requester's
 * reply leases so the responder can route the reply without a netDB lookup:
 *   GETMANIFEST 'M' fileSha(32) + leases
 *   DATMANIFEST 'N' fileSha(32) + len(4 BE) + manifest
 *   GETHAVE     'H' fileSha(32) + leases
 *   DATHAVE     'I' fileSha(32) + pieceCount(4 BE) + bitmap
 *   GETPIECE    'p' fileSha(32) + index(4 BE) + leases
 *   DATPIECE    'q' fileSha(32) + index(4 BE) + len(4 BE) + bytes
 */
import 'dart:io';
import 'dart:typed_data';

import 'i2p_crypto.dart';
import 'i2p_datagram.dart' show ReplyLease;

// Opcodes.
const opGetManifest = 0x4D; // 'M'
const opDatManifest = 0x4E; // 'N'
const opGetHave = 0x48; // 'H'
const opDatHave = 0x49; // 'I'
const opGetPiece = 0x70; // 'p'
const opDatPiece = 0x71; // 'q'

const _manifestMagic = 0x414D5431; // 'AMT1'
const _basePieceLen = 32 * 1024;
const _maxPieceLen = 60 * 1024; // keeps a piece datagram < the 64 KiB I2NP cap
const _maxPieces = 1800; // keeps the manifest itself inside one I2NP message

/// Deterministic piece length for a file of [totalLen] bytes. Small files use a
/// fixed 32 KiB piece; very large files widen the piece so the piece count (and
/// thus the manifest) stays within one I2NP message. Files beyond ~108 MB exceed
/// the v1 single-message-manifest budget (caller should fall back).
int pieceLenFor(int totalLen) {
  if (totalLen <= _maxPieces * _basePieceLen) return _basePieceLen;
  var pl = ((totalLen + _maxPieces - 1) ~/ _maxPieces);
  pl = (pl + 1023) & ~1023; // round up to 1 KiB
  if (pl > _maxPieceLen) pl = _maxPieceLen;
  return pl;
}

int pieceCountFor(int totalLen, int pieceLen) =>
    totalLen == 0 ? 0 : (totalLen + pieceLen - 1) ~/ pieceLen;

/// Whether a file of this size fits the v1 swarm (single-message manifest).
bool swarmSupported(int totalLen) =>
    pieceCountFor(totalLen, pieceLenFor(totalLen)) <= _maxPieces;

class TorrentManifest {
  final Uint8List fileSha; // 32
  final int totalLen;
  final int pieceLen;
  final List<Uint8List> pieceShas; // each 32

  TorrentManifest(this.fileSha, this.totalLen, this.pieceLen, this.pieceShas);

  int get pieceCount => pieceShas.length;
  int get bitmapBytes => (pieceCount + 7) >> 3;

  /// Byte length of piece [i] (the last piece may be short).
  int pieceSize(int i) {
    final start = i * pieceLen;
    final end = start + pieceLen;
    return (end <= totalLen) ? pieceLen : totalLen - start;
  }

  /// Build the manifest deterministically from the whole file bytes.
  static TorrentManifest fromBytes(Uint8List bytes) {
    final fileSha = I2pCrypto.sha256(bytes);
    final pieceLen = pieceLenFor(bytes.length);
    final count = pieceCountFor(bytes.length, pieceLen);
    final shas = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      final start = i * pieceLen;
      final end = (start + pieceLen <= bytes.length) ? start + pieceLen : bytes.length;
      shas.add(I2pCrypto.sha256(bytes.sublist(start, end)));
    }
    return TorrentManifest(fileSha, bytes.length, pieceLen, shas);
  }

  Uint8List encode() {
    final b = BytesBuilder();
    b.add(_be32(_manifestMagic));
    b.add(fileSha);
    b.add(_be64(totalLen));
    b.add(_be32(pieceLen));
    b.add(_be32(pieceCount));
    for (final s in pieceShas) {
      b.add(s);
    }
    return b.toBytes();
  }

  /// Parse + validate a manifest. Returns null if malformed or internally
  /// inconsistent (piece count / length must match the declared total).
  static TorrentManifest? decode(Uint8List m) {
    if (m.length < 4 + 32 + 8 + 4 + 4) return null;
    if (_rd32(m, 0) != _manifestMagic) return null;
    final fileSha = m.sublist(4, 36);
    final totalLen = _rd64(m, 36);
    final pieceLen = _rd32(m, 44);
    final count = _rd32(m, 48);
    if (pieceLen <= 0 || count < 0 || count > 100000) return null;
    if (m.length != 52 + count * 32) return null;
    if (pieceCountFor(totalLen, pieceLen) != count) return null;
    final shas = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      shas.add(m.sublist(52 + i * 32, 52 + (i + 1) * 32));
    }
    return TorrentManifest(fileSha, totalLen, pieceLen, shas);
  }
}

// ---- piece store (temp-file backed, survives within a session) ----

/// On-disk store for one in-progress (or freshly completed) swarm download,
/// backed by a single data file (opened read+write) plus an in-memory
/// present-bitmap. We can serve a verified piece to other peers the moment it
/// lands, so a device becomes a (partial) seed mid-download. The store is
/// per-session (a restart re-downloads); cross-restart resume is a later add.
class SwarmStore {
  final TorrentManifest manifest;
  final Directory dir;
  final RandomAccessFile _raf;
  final List<bool> _have;
  int _haveCount = 0;

  SwarmStore._(this.manifest, this.dir, this._raf, this._have);

  int get pieceCount => manifest.pieceCount;
  int get haveCount => _haveCount;
  bool get isComplete => _haveCount == manifest.pieceCount;
  bool hasPiece(int i) => i >= 0 && i < _have.length && _have[i];

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  // A RandomAccessFile permits only one pending async op at a time; parallel
  // piece writes/reads (swarm concurrency) must be serialized or Dart throws
  // "An async operation is currently pending".
  Future<void> _io = Future<void>.value();
  Future<T> _locked<T>(Future<T> Function() op) {
    final run = _io.then((_) => op());
    _io = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Create the store for [manifest] under [baseDir]. FileMode.write is O_RDWR
  /// (so we can both write downloaded pieces and read them back to serve);
  /// truncate() pre-allocates the file so pieces can be written at any offset.
  static Future<SwarmStore> open(TorrentManifest manifest, Directory baseDir) async {
    final dir = Directory('${baseDir.path}/aurora_swarm/${_hex(manifest.fileSha)}');
    await dir.create(recursive: true);
    final raf = await File('${dir.path}/data').open(mode: FileMode.write);
    if (manifest.totalLen > 0) await raf.truncate(manifest.totalLen);
    return SwarmStore._(
        manifest, dir, raf, List<bool>.filled(manifest.pieceCount, false));
  }

  /// Verify [bytes] against the manifest and persist piece [i]. Returns true if
  /// it verified and was stored (or was already present).
  Future<bool> writePiece(int i, Uint8List bytes) async {
    if (i < 0 || i >= manifest.pieceCount) return false;
    if (_have[i]) return true;
    if (bytes.length != manifest.pieceSize(i)) return false;
    if (_hex(I2pCrypto.sha256(bytes)) != _hex(manifest.pieceShas[i])) return false;
    await _locked(() async {
      await _raf.setPosition(i * manifest.pieceLen);
      await _raf.writeFrom(bytes);
      await _raf.flush();
    });
    _have[i] = true;
    _haveCount++;
    return true;
  }

  /// Read piece [i] if we have it, else null.
  Future<Uint8List?> readPiece(int i) async {
    if (!hasPiece(i)) return null;
    final sz = manifest.pieceSize(i);
    final buf = await _locked(() async {
      await _raf.setPosition(i * manifest.pieceLen);
      return _raf.read(sz);
    });
    return buf.length == sz ? Uint8List.fromList(buf) : null;
  }

  /// Present-bitmap (bit set = we have that piece), MSB-first within each byte.
  Uint8List bitmap() {
    final out = Uint8List(manifest.bitmapBytes);
    for (var i = 0; i < _have.length; i++) {
      if (_have[i]) out[i >> 3] |= (0x80 >> (i & 7));
    }
    return out;
  }

  /// Assemble the complete verified file (only when [isComplete]).
  Future<Uint8List?> assemble() async {
    if (!isComplete) return null;
    final buf = await _locked(() async {
      await _raf.setPosition(0);
      return _raf.read(manifest.totalLen);
    });
    final out = Uint8List.fromList(buf);
    if (_hex(I2pCrypto.sha256(out)) != _hex(manifest.fileSha)) return null;
    return out;
  }

  Future<void> close() async {
    try {
      await _io; // let any pending read/write finish first
      await _raf.close();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await close();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
}

// ---- bitmap helpers (for peer HAVE bitmaps) ----

bool bitmapHas(Uint8List bitmap, int i) {
  final byte = i >> 3;
  if (byte >= bitmap.length) return false;
  return (bitmap[byte] & (0x80 >> (i & 7))) != 0;
}

// ---- payload builders / parsers ----

Uint8List buildGetManifest(Uint8List fileSha, List<ReplyLease> leases) =>
    _reqWithLeases(opGetManifest, fileSha, leases);

Uint8List buildDatManifest(Uint8List fileSha, Uint8List manifest) {
  final b = BytesBuilder();
  b.addByte(opDatManifest);
  b.add(fileSha);
  b.add(_be32(manifest.length));
  b.add(manifest);
  return b.toBytes();
}

/// (fileSha, manifestBytes) or null.
(Uint8List, Uint8List)? parseDatManifest(Uint8List p) {
  if (p.length < 1 + 32 + 4 || p[0] != opDatManifest) return null;
  final fileSha = p.sublist(1, 33);
  final len = _rd32(p, 33);
  if (p.length < 37 + len) return null;
  return (fileSha, p.sublist(37, 37 + len));
}

Uint8List buildGetHave(Uint8List fileSha, List<ReplyLease> leases) =>
    _reqWithLeases(opGetHave, fileSha, leases);

Uint8List buildDatHave(Uint8List fileSha, int pieceCount, Uint8List bitmap) {
  final b = BytesBuilder();
  b.addByte(opDatHave);
  b.add(fileSha);
  b.add(_be32(pieceCount));
  b.add(bitmap);
  return b.toBytes();
}

/// (fileSha, pieceCount, bitmap) or null.
(Uint8List, int, Uint8List)? parseDatHave(Uint8List p) {
  if (p.length < 1 + 32 + 4 || p[0] != opDatHave) return null;
  final fileSha = p.sublist(1, 33);
  final count = _rd32(p, 33);
  return (fileSha, count, p.sublist(37));
}

Uint8List buildGetPiece(Uint8List fileSha, int index, List<ReplyLease> leases) {
  final b = BytesBuilder();
  b.addByte(opGetPiece);
  b.add(fileSha);
  b.add(_be32(index));
  _putLeases(b, leases);
  return b.toBytes();
}

/// (fileSha, index, replyLeases) or null.
(Uint8List, int, List<ReplyLease>)? parseGetPiece(Uint8List p) {
  if (p.length < 1 + 32 + 4 || p[0] != opGetPiece) return null;
  final fileSha = p.sublist(1, 33);
  final index = _rd32(p, 33);
  return (fileSha, index, _getLeases(p, 37));
}

Uint8List buildDatPiece(Uint8List fileSha, int index, Uint8List bytes) {
  final b = BytesBuilder();
  b.addByte(opDatPiece);
  b.add(fileSha);
  b.add(_be32(index));
  b.add(_be32(bytes.length));
  b.add(bytes);
  return b.toBytes();
}

/// (fileSha, index, bytes) or null.
(Uint8List, int, Uint8List)? parseDatPiece(Uint8List p) {
  if (p.length < 1 + 32 + 4 + 4 || p[0] != opDatPiece) return null;
  final fileSha = p.sublist(1, 33);
  final index = _rd32(p, 33);
  final len = _rd32(p, 37);
  if (p.length < 41 + len) return null;
  return (fileSha, index, p.sublist(41, 41 + len));
}

/// fileSha out of any GET* request ('M'/'H'/'p'); the requester reply leases are
/// after it (32 + leases), but only the fileSha is needed by parse* above.
(Uint8List, List<ReplyLease>)? parseFileShaReq(Uint8List p) {
  if (p.length < 33) return null;
  return (p.sublist(1, 33), _getLeases(p, 33));
}

Uint8List _reqWithLeases(int op, Uint8List fileSha, List<ReplyLease> leases) {
  final b = BytesBuilder();
  b.addByte(op);
  b.add(fileSha);
  _putLeases(b, leases);
  return b.toBytes();
}

// ---- reply-lease (de)serialisation (same wire form as i2p_datagram) ----

void _putLeases(BytesBuilder b, List<ReplyLease> leases) {
  b.addByte(leases.length);
  for (final l in leases) {
    b.add(l.gatewayHash);
    b.add(_be32(l.tunnelId));
  }
}

List<ReplyLease> _getLeases(Uint8List p, int off) {
  final out = <ReplyLease>[];
  if (off >= p.length) return out;
  final n = p[off];
  var o = off + 1;
  for (var i = 0; i < n && o + 36 <= p.length; i++) {
    out.add(ReplyLease(p.sublist(o, o + 32), _rd32(p, o + 32)));
    o += 36;
  }
  return out;
}

// ---- numeric helpers ----

Uint8List _be32(int v) => Uint8List.fromList(
    [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);

Uint8List _be64(int v) {
  final out = Uint8List(8);
  for (var i = 7; i >= 0; i--) {
    out[i] = (v >> (8 * (7 - i))) & 0xff;
  }
  return out;
}

int _rd32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int _rd64(Uint8List b, int o) {
  var v = 0;
  for (var i = 0; i < 8; i++) {
    v = (v << 8) | b[o + i];
  }
  return v;
}
