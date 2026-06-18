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
import 'dart:convert';
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
// Store-and-forward deposit: a peer asks a host to KEEP a blob it doesn't hold.
//   client -> host : 0x03 PUT_OFFER  sha(32) size(8 BE) extLen(1) ext pub(32) sig(64)
//   host -> client : 0x84 PUT_ACCEPT sha(32)            (send the bytes now)
//   host -> client : 0x82 PUT_REJECT reason(utf8)
//   client -> host : the blob as an RNS Resource (client = sender, host = receiver)
//   host -> client : 0x85 PUT_STORED sha(32)
// The compact auth proves a NOSTR identity authorizes hosting THIS sha: sig is a
// BIP-340 Schnorr signature by [pub] over sha256("blossom-deposit:"+shaHex), so
// the host can classify the depositor's retention tier and the sig can't be
// reused for a different blob.
const int kOpPutOffer = 0x03;
const int kOpPutReject = 0x82;
const int kOpPutAccept = 0x84;
const int kOpPutStored = 0x85;

/// The canonical message a depositor Schnorr-signs to authorize hosting [shaHex]
/// (returned as 64-char hex, ready for NostrCrypto.schnorrSign/Verify).
String depositAuthMessageHex(String shaHex) =>
    _hex(crypto.sha256.convert(utf8.encode('blossom-deposit:$shaHex')).bytes);

/// A host's decision on an inbound deposit offer.
class DepositVerdict {
  final bool ok;
  final String? reason; // set when !ok
  final int tier; // 0 self / 1 followed / 2 stranger
  final String originPubHex; // depositor's NOSTR pubkey
  final String ext; // file extension to store under
  const DepositVerdict.accept(this.tier, this.originPubHex, this.ext)
      : ok = true,
        reason = null;
  const DepositVerdict.reject(this.reason)
      : ok = false,
        tier = 2,
        originPubHex = '',
        ext = 'bin';
}

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
  /// Called once per download a peer starts (when we serve the manifest), with
  /// the 32-byte file hash — drives the per-file download metric.
  final void Function(Uint8List fileHash)? onServed;

  /// Store-and-forward deposit: decide on an inbound offer (verify the auth,
  /// classify tier, enforce quota) and, when accepted, persist the verified
  /// bytes. Null = this node does not accept deposits.
  final DepositVerdict Function(
      Uint8List sha, int size, String ext, String pubHex, String sigHex)?
      onDepositOffer;
  final void Function(
      Uint8List sha, Uint8List bytes, String originPubHex, int tier, String ext)?
      onDepositStore;

  RnsResourceSender? _sender; // current in-flight resource (serving)
  RnsResourceReceiver? _rx; // current in-flight resource (deposit receive)
  Uint8List? _depSha;
  int _depTier = 2;
  String _depOrigin = '';
  String _depExt = 'bin';

  FileServeSession(this.link, this.source,
      {this.quota,
      this.requesterId = '',
      this.onServed,
      this.onDepositOffer,
      this.onDepositStore});

  void _abortDeposit() {
    _rx = null;
    _depSha = null;
  }

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
      case RnsContext.resourceAdv:
        // Inbound deposit bytes: only when we accepted an offer.
        if (_depSha == null) return const [];
        final rx = RnsResourceReceiver(link);
        _rx = rx;
        if (!rx.ingestAdvertisement(link.decrypt(p))) {
          _abortDeposit();
          return [_putReject('bad advertisement')];
        }
        return [rx.buildRequest()];
      case RnsContext.resource:
        final rx = _rx;
        if (rx == null) return const [];
        final complete = rx.ingestPart(p.data);
        if (rx.error != null) {
          _abortDeposit();
          return [_putReject('resource error')];
        }
        if (!complete) return const [];
        final bytes = rx.payload!;
        final out = <RnsPacket>[];
        final prf = rx.proofPacket();
        if (prf != null) out.add(prf);
        final h = Uint8List.fromList(crypto.sha256.convert(bytes).bytes);
        if (_eq(h, _depSha!)) {
          onDepositStore?.call(_depSha!, bytes, _depOrigin, _depTier, _depExt);
          out.add(_putStored(_depSha!));
        } else {
          out.add(_putReject('hash mismatch'));
        }
        _abortDeposit();
        return out;
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
    if (op == kOpPutOffer && cmd.length >= 1 + 32 + 8 + 1) {
      // [0x03][sha32][size8][extLen1][ext][pub32][sig64]
      final sha = Uint8List.sublistView(cmd, 1, 33);
      final size = ByteData.sublistView(cmd, 33, 41).getUint64(0, Endian.big);
      final extLen = cmd[41];
      var o = 42;
      if (cmd.length < o + extLen + 32 + 64) return [_putReject('bad offer')];
      final ext = String.fromCharCodes(cmd.sublist(o, o + extLen));
      o += extLen;
      final pub = Uint8List.sublistView(cmd, o, o + 32);
      o += 32;
      final sig = Uint8List.sublistView(cmd, o, o + 64);
      final accept =
          onDepositOffer?.call(sha, size, ext, _hex(pub), _hex(sig));
      if (accept == null || !accept.ok) {
        return [_putReject(accept?.reason ?? 'deposits not accepted')];
      }
      _depSha = sha;
      _depTier = accept.tier;
      _depOrigin = accept.originPubHex;
      _depExt = accept.ext.isNotEmpty ? accept.ext : ext;
      return [_putAccept(sha)];
    }
    return const [];
  }

  RnsPacket _putAccept(Uint8List sha) {
    final b = BytesBuilder()
      ..addByte(kOpPutAccept)
      ..add(sha);
    return link.encrypt(b.toBytes(), context: RnsContext.none);
  }

  RnsPacket _putStored(Uint8List sha) {
    final b = BytesBuilder()
      ..addByte(kOpPutStored)
      ..add(sha);
    return link.encrypt(b.toBytes(), context: RnsContext.none);
  }

  RnsPacket _putReject(String reason) {
    final b = BytesBuilder()
      ..addByte(kOpPutReject)
      ..add(utf8.encode(reason));
    return link.encrypt(b.toBytes(), context: RnsContext.none);
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
      // A manifest serve marks the start of one download by another node.
      if (manifest) onServed?.call(fileHash);
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

// ── Deposit side (client asks a host to keep a blob) ─────────────────────────

enum FileDepositState { idle, offered, sending, done, failed }

/// Deposits one blob to a host over an active link: offer (with compact auth),
/// then on accept stream the bytes as an RNS Resource, then await PUT_STORED.
class FileDepositSession {
  final RnsLink link;
  final Uint8List sha; // sha256(bytes), 32B
  final Uint8List bytes;
  final String ext;
  final Uint8List pub; // depositor NOSTR pubkey, 32B (x-only)
  final Uint8List sig; // Schnorr sig over depositAuthMessageHex(shaHex), 64B

  FileDepositState state = FileDepositState.idle;
  String? error;
  RnsResourceSender? _sender;

  FileDepositSession(this.link, this.sha, this.bytes, this.ext, this.pub, this.sig);

  /// Begin: returns the PUT_OFFER packet to send.
  RnsPacket start() {
    state = FileDepositState.offered;
    final extB = ascii.encode(ext);
    final b = BytesBuilder()
      ..addByte(kOpPutOffer)
      ..add(sha);
    final sz = ByteData(8)..setUint64(0, bytes.length, Endian.big);
    b
      ..add(sz.buffer.asUint8List())
      ..addByte(extB.length)
      ..add(extB)
      ..add(pub)
      ..add(sig);
    return link.encrypt(b.toBytes(), context: RnsContext.none);
  }

  List<RnsPacket> onPacket(RnsPacket p) {
    if (state == FileDepositState.done || state == FileDepositState.failed) {
      return const [];
    }
    switch (p.context) {
      case RnsContext.none:
        final cmd = link.decrypt(p);
        if (cmd.isEmpty) return const [];
        if (cmd[0] == kOpPutAccept) {
          // Host accepted — stream the bytes as a Resource.
          try {
            final s = RnsResourceSender(link, bytes);
            s.prepare();
            _sender = s;
            state = FileDepositState.sending;
            return [s.advertisementPacket()];
          } catch (_) {
            return _fail('blob too large for one resource segment');
          }
        }
        if (cmd[0] == kOpPutReject) {
          return _fail(utf8.decode(cmd.sublist(1), allowMalformed: true));
        }
        if (cmd[0] == kOpPutStored) {
          state = FileDepositState.done;
          return const [];
        }
        return const [];
      case RnsContext.resourceReq:
        final s = _sender;
        if (s == null) return const [];
        return s.handleRequest(link.decrypt(p));
      case RnsContext.resourcePrf:
        _sender?.validateProof(link.decrypt(p));
        _sender = null;
        return const []; // success is confirmed by PUT_STORED
      default:
        return const [];
    }
  }

  List<RnsPacket> _fail(String why) {
    error = why;
    state = FileDepositState.failed;
    return const [];
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
