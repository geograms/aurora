/*
 * File transfer protocol over an established RNS Link.
 *
 * Two transport-agnostic session state machines drive one provider<->fetcher
 * link. They consume inbound RnsPackets (already routed to this link) and return
 * the RnsPackets to send back, so they can be wired to any interface (and unit-
 * tested in-process). Bulk bytes (the manifest, then each chunk) ride the RNS
 * Resource layer; small commands ride a link-encrypted DATA packet with
 * context=none.
 *
 * Wire commands (plaintext of a context-none link DATA):
 *   0x01 GET_MANIFEST  + fileHash(32)
 *   0x02 GET_CHUNK     + fileHash(32) + index(4 BE)
 *   0x81 NOT_FOUND     + fileHash(32)            (provider -> fetcher)
 *
 * A reply that carries bytes is sent as a Resource: GET_MANIFEST is answered with
 * the encoded FileManifest, GET_CHUNK with the raw chunk bytes. The fetcher pulls
 * chunks sequentially over one link; parallelism across providers is achieved by
 * running several FileFetchSessions (one per provider link) against a shared
 * chunk-assembly state — that orchestration lives a layer above this file.
 */
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../reticulum/rns_link.dart';
import '../reticulum/rns_packet.dart';
import '../reticulum/rns_resource.dart';
import '../reticulum/rns_resource_receiver.dart';
import 'file_manifest.dart';
import 'serve_quota.dart';

const int kOpGetManifest = 0x01;
const int kOpGetChunk = 0x02;
const int kOpNotFound = 0x81;

/// Where a serving node reads content it holds, by file id (sha256, 32B).
abstract class FileSource {
  /// Whole-file bytes for [fileHash], or null if this node does not hold it.
  Uint8List? read(Uint8List fileHash);
}

/// A [FileSource] that holds nothing (default for a node that only fetches).
class EmptyFileSource implements FileSource {
  const EmptyFileSource();
  @override
  Uint8List? read(Uint8List fileHash) => null;
}

/// An in-memory [FileSource] (tests, small caches). Keyed by lowercase hex.
class MemoryFileSource implements FileSource {
  final Map<String, Uint8List> _byHex = {};
  void add(Uint8List bytes) =>
      _byHex[_hex(crypto.sha256.convert(bytes).bytes)] = bytes;
  @override
  Uint8List? read(Uint8List fileHash) => _byHex[_hex(fileHash)];
}

// ── Provider side ──────────────────────────────────────────────────────────

/// Serves files to one connected fetcher over an active link. One Resource is in
/// flight at a time (the fetcher requests sequentially).
class FileServeSession {
  final RnsLink link;
  final FileSource source;
  final ServeQuota? quota; // optional serving budget / anti-abuse guard
  final String requesterId; // best-effort requester key (the link id)
  RnsResourceSender? _sender; // current in-flight resource

  FileServeSession(this.link, this.source, {this.quota, this.requesterId = ''});

  /// Process one inbound packet for this link; returns packets to send back.
  List<RnsPacket> onPacket(RnsPacket p) {
    switch (p.context) {
      case RnsContext.resourceReq:
        final s = _sender;
        if (s == null) return const [];
        return s.handleRequest(link.decrypt(p));
      case RnsContext.resourcePrf:
        _sender?.validateProof(link.decrypt(p));
        _sender = null;
        return const [];
      case RnsContext.none:
        return _onCommand(link.decrypt(p));
      default:
        return const [];
    }
  }

  List<RnsPacket> _onCommand(Uint8List cmd) {
    if (cmd.isEmpty) return const [];
    final op = cmd[0];
    if (op == kOpGetManifest && cmd.length >= 1 + 32) {
      final fileHash = Uint8List.sublistView(cmd, 1, 33);
      final bytes = source.read(fileHash);
      if (bytes == null) return [_notFound(fileHash)];
      final manifest = FileManifest.ofBytes(bytes).encode();
      if (!_allow(fileHash, manifest.length, manifest: true)) {
        return [_notFound(fileHash)];
      }
      return _serveResource(manifest, fileHash, manifest: true);
    }
    if (op == kOpGetChunk && cmd.length >= 1 + 32 + 4) {
      final fileHash = Uint8List.sublistView(cmd, 1, 33);
      final idx = ByteData.sublistView(cmd, 33, 37).getUint32(0, Endian.big);
      final bytes = source.read(fileHash);
      if (bytes == null) return [_notFound(fileHash)];
      final off = idx * kFileChunkSize;
      if (off >= bytes.length && bytes.isNotEmpty) return [_notFound(fileHash)];
      final end =
          off + kFileChunkSize < bytes.length ? off + kFileChunkSize : bytes.length;
      final chunk = Uint8List.fromList(bytes.sublist(off, end));
      if (!_allow(fileHash, chunk.length)) return [_notFound(fileHash)];
      return _serveResource(chunk, fileHash);
    }
    return const [];
  }

  // Quota gate: may we serve [bytes] for [fileHash] to this requester now?
  bool _allow(Uint8List fileHash, int bytes, {bool manifest = false}) {
    final q = quota;
    if (q == null) return true;
    return q.canServe(requesterId, fileHash, bytes, manifest: manifest);
  }

  List<RnsPacket> _serveResource(Uint8List payload, Uint8List fileHash,
      {bool manifest = false}) {
    try {
      final s = RnsResourceSender(link, payload);
      s.prepare();
      _sender = s;
      quota?.record(requesterId, fileHash, payload.length, manifest: manifest);
      return [s.advertisementPacket()];
    } catch (_) {
      // Payload too large for a single Resource segment (v1 limit) — decline.
      return [_notFound(fileHash)];
    }
  }

  RnsPacket _notFound(Uint8List fileHash) {
    final b = BytesBuilder()
      ..addByte(kOpNotFound)
      ..add(fileHash);
    return link.encrypt(b.toBytes(), context: RnsContext.none);
  }
}

// ── Fetcher side ───────────────────────────────────────────────────────────

enum FileFetchState { idle, manifest, chunks, done, failed }

/// Fetches one file (by id) from one provider over an active link. Pulls the
/// manifest, then each chunk sequentially, verifying every chunk against the
/// manifest and the assembled bytes against the requested id.
class FileFetchSession {
  final RnsLink link;
  final Uint8List wantHash; // requested file id (sha256, 32B)

  FileFetchState state = FileFetchState.idle;
  String? error;
  FileManifest? manifest;
  Uint8List? result; // assembled, verified file bytes

  RnsResourceReceiver? _rx; // in-flight resource
  int _expectIdx = -1; // -1 = manifest, else chunk index being fetched
  List<Uint8List?> _chunks = [];

  FileFetchSession(this.link, this.wantHash);

  /// Begin: returns the GET_MANIFEST packet to send.
  RnsPacket start() {
    state = FileFetchState.manifest;
    _expectIdx = -1;
    return _cmd(kOpGetManifest, wantHash);
  }

  /// Process one inbound packet; returns packets to send back. When [state]
  /// becomes done, [result] holds the verified file; on failed, [error] is set.
  List<RnsPacket> onPacket(RnsPacket p) {
    if (state == FileFetchState.done || state == FileFetchState.failed) {
      return const [];
    }
    switch (p.context) {
      case RnsContext.none:
        final cmd = link.decrypt(p);
        if (cmd.isNotEmpty && cmd[0] == kOpNotFound) {
          return _fail('provider does not have the file');
        }
        return const [];
      case RnsContext.resourceAdv:
        final rx = RnsResourceReceiver(link);
        _rx = rx;
        if (!rx.ingestAdvertisement(link.decrypt(p))) {
          return _fail('bad advertisement: ${rx.error}');
        }
        return [rx.buildRequest()];
      case RnsContext.resource:
        final rx = _rx;
        if (rx == null) return const [];
        final complete = rx.ingestPart(p.data);
        if (rx.error != null) return _fail('resource error: ${rx.error}');
        if (!complete) return const [];
        final out = <RnsPacket>[];
        final prf = rx.proofPacket();
        if (prf != null) out.add(prf);
        out.addAll(_onResourceComplete(rx.payload!));
        return out;
      default:
        return const [];
    }
  }

  List<RnsPacket> _onResourceComplete(Uint8List payload) {
    _rx = null;
    if (_expectIdx == -1) {
      // The manifest arrived.
      final m = FileManifest.decode(payload);
      if (m == null) return _fail('manifest decode failed');
      if (!_eq(m.fileHash, wantHash)) {
        return _fail('manifest file hash != requested id');
      }
      manifest = m;
      _chunks = List<Uint8List?>.filled(m.chunkCount, null);
      if (m.chunkCount == 0) return _finish(); // empty file
      state = FileFetchState.chunks;
      _expectIdx = 0;
      return [_chunkCmd(0)];
    }
    // A chunk arrived for _expectIdx.
    final m = manifest!;
    final idx = _expectIdx;
    final h = Uint8List.fromList(crypto.sha256.convert(payload).bytes);
    if (!_eq(h, m.chunkHashes[idx])) {
      return _fail('chunk $idx hash mismatch');
    }
    _chunks[idx] = payload;
    final next = idx + 1;
    if (next < m.chunkCount) {
      _expectIdx = next;
      return [_chunkCmd(next)];
    }
    return _finish();
  }

  List<RnsPacket> _finish() {
    final out = BytesBuilder();
    for (final c in _chunks) {
      if (c == null) return _fail('missing chunk at assembly');
      out.add(c);
    }
    final bytes = out.toBytes();
    final h = Uint8List.fromList(crypto.sha256.convert(bytes).bytes);
    if (!_eq(h, wantHash)) return _fail('assembled file hash != requested id');
    result = bytes;
    state = FileFetchState.done;
    return const [];
  }

  List<RnsPacket> _fail(String why) {
    error = why;
    state = FileFetchState.failed;
    return const [];
  }

  RnsPacket _chunkCmd(int idx) {
    final b = BytesBuilder()
      ..addByte(kOpGetChunk)
      ..add(wantHash);
    final n = ByteData(4)..setUint32(0, idx, Endian.big);
    b.add(n.buffer.asUint8List());
    return link.encrypt(b.toBytes(), context: RnsContext.none);
  }

  RnsPacket _cmd(int op, Uint8List arg) {
    final b = BytesBuilder()
      ..addByte(op)
      ..add(arg);
    return link.encrypt(b.toBytes(), context: RnsContext.none);
  }
}

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
