/*
 * mesh_bulk_spool — disk spool for the MSP bulk file lane (doc/mesh.md §6b).
 *
 * Two kinds of entry, both content-addressed by SHA-256:
 *
 *  - Origin entries ("archive"): the file lives in the shared MediaArchive
 *    (it was attached in chat and got a file:<sha>.<ext> token); the spool
 *    holds only a meta record saying "move it to <target>". Bytes are read
 *    straight out of the archive.
 *  - Relay/inbound entries: a growing <shaHex>.part file + <shaHex>.json
 *    meta. The .part length IS the resume offset — a transfer interrupted by
 *    a politeness cycle, link loss or app restart resumes exactly there.
 *
 * Custody: when the final target verifies the file (FILE_OK), it lands in
 * its MediaArchive and the chat bubble renders. An intermediate hop keeps
 * the completed .part only until IT hands the file downstream, then deletes
 * the payload and keeps a 7-day handover record (MeshStore.bulk_handover)
 * for dup suppression.
 *
 * Quota (default 200 MB, separate from the message store): forwarded-and-
 * done entries evict first, then the oldest stalled partials. Entries with
 * a live transfer are never evicted (guarded by [_activeSha]).
 */
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../../util/media_archive.dart';
import '../log_service.dart';
import 'mesh_beacon.dart';
import 'mesh_session.dart';
import 'mesh_store.dart';
import 'mesh_table.dart';

class MeshBulkSpool {
  MeshBulkSpool._();
  static final MeshBulkSpool instance = MeshBulkSpool._();

  String? _dir;
  MediaArchive? _archive;
  int quotaBytes = 200 * 1024 * 1024;
  static const int defaultTtlS = 7 * 24 * 3600;

  /// sha-hex of transfers currently in a live session (eviction guard).
  final Set<String> _activeSha = {};

  // One-blob read cache for the active outbound transfer (archive reads are
  // whole-BLOB; caching avoids re-reading sqlite for every chunk).
  String? _cacheSha;
  Uint8List? _cacheBytes;

  bool get ready => _dir != null;

  void init(String dir, MediaArchive archive) {
    _dir = dir;
    _archive = archive;
    Directory(dir).createSync(recursive: true);
  }

  void _log(String m) => LogService.instance.add('MeshBulk: $m');

  // --- sha helpers (MSP carries raw 32B; archive keys are b64url43) ---------

  static String shaHex(Uint8List sha) =>
      sha.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List hexSha(String hex) {
    final b = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      b[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return b;
  }

  static String shaB64u(Uint8List sha) =>
      base64Url.encode(sha).replaceAll('=', '');

  String _partPath(String hex) => '$_dir/$hex.part';
  String _metaPath(String hex) => '$_dir/$hex.json';

  Map<String, dynamic>? _meta(String hex) {
    try {
      final f = File(_metaPath(hex));
      if (!f.existsSync()) return null;
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  void _saveMeta(String hex, Map<String, dynamic> m) {
    File(_metaPath(hex)).writeAsStringSync(jsonEncode(m));
  }

  List<MapEntry<String, Map<String, dynamic>>> _metas() {
    final d = _dir;
    if (d == null) return const [];
    final out = <MapEntry<String, Map<String, dynamic>>>[];
    try {
      for (final f in Directory(d).listSync()) {
        if (f is! File || !f.path.endsWith('.json')) continue;
        final hex = f.path.split('/').last.replaceAll('.json', '');
        final m = _meta(hex);
        if (m != null) out.add(MapEntry(hex, m));
      }
    } catch (_) {}
    return out;
  }

  // --- outbound (chat attachment origin) ------------------------------------

  /// Queue a MediaArchive blob for mesh delivery to [target]. Called from the
  /// outbound air tap when a 1:1 we sent carries a file: token we host.
  bool enqueueFromArchive(String token, String target, String origin) {
    final a = _archive;
    if (!ready || a == null) return false;
    final data = a.get(token);
    if (data == null) return false;
    final sha = crypto.sha256.convert(data).bytes;
    final hex = shaHex(Uint8List.fromList(sha));
    final existing = _meta(hex);
    if (existing != null &&
        (existing['target'] as String?)?.toUpperCase() ==
            target.toUpperCase()) {
      return false; // already queued
    }
    final dot = token.lastIndexOf('.');
    _saveMeta(hex, {
      'sha': hex,
      'size': data.length,
      'ext': dot > 0 ? token.substring(dot + 1) : '',
      'name': token.substring(5, dot > 0 ? dot : token.length),
      'origin': origin.toUpperCase(),
      'target': target.toUpperCase(),
      'src': 'archive',
      'token': token,
      'state': 'ready',
      'ttlUntil': DateTime.now().millisecondsSinceEpoch ~/ 1000 + defaultTtlS,
      'createdMs': DateTime.now().millisecondsSinceEpoch,
    });
    _log('queued $token (${data.length}B) -> $target');
    return true;
  }

  // --- scheduler / session queries -------------------------------------------

  /// Next spooled file this session should move to [peer]: the target itself,
  /// or the route next hop, skipping files already handed over for their
  /// target and files that came FROM this peer.
  MeshBulkPending? nextFor(String peer, MeshTable? table) {
    final p = peer.toUpperCase();
    for (final e in _metas()) {
      final m = e.value;
      if (m['state'] != 'ready') continue;
      final target = (m['target'] as String? ?? '').toUpperCase();
      final origin = (m['origin'] as String? ?? '').toUpperCase();
      final from = (m['from'] as String? ?? '').toUpperCase();
      if (target.isEmpty || p == from || p == origin) continue;
      var give = target == p;
      if (!give && table != null) {
        final r = table.routes[meshHashHex(meshHash(target))];
        give = r != null && r.viaCallsign.toUpperCase() == p;
      }
      if (!give) continue;
      if (MeshStore.instance.bulkHandedOver(e.key, target)) continue;
      return MeshBulkPending(
        sha256: hexSha(e.key),
        size: (m['size'] as num).toInt(),
        ttlS: defaultTtlS,
        origin: origin,
        target: target,
        ext: m['ext'] as String? ?? '',
        name: m['name'] as String? ?? '',
      );
    }
    return null;
  }

  /// Files we still owe delivery for (beacon pending trailer).
  int pendingCount() =>
      _metas().where((e) => e.value['state'] == 'ready').length;

  // --- inbound (receiver / relay) --------------------------------------------

  /// Answer an inbound FILE_OFFER: resume offset from the .part on disk,
  /// accept-at-size when we already hold the full content.
  MeshBulkDecision offered(String peer, MspFileOffer o) {
    if (!ready) return const MeshBulkDecision.reject(MspFileReject.quota);
    final hex = shaHex(o.sha256);
    // Already in the media archive (we are the target and have it)?
    if (_archive?.has('file:${shaB64u(o.sha256)}.${o.ext}') ?? false) {
      return MeshBulkDecision.accept(o.size);
    }
    final m = _meta(hex);
    if (m != null && m['state'] == 'ready') {
      return MeshBulkDecision.accept(o.size); // complete relay copy on disk
    }
    // Quota check for the remainder.
    if (_usedBytes() + o.size > quotaBytes) {
      _log('offer ${o.name} rejected: quota');
      return const MeshBulkDecision.reject(MspFileReject.quota);
    }
    final part = File(_partPath(hex));
    final have = part.existsSync() ? part.lengthSync() : 0;
    if (m == null) {
      _saveMeta(hex, {
        'sha': hex,
        'size': o.size,
        'ext': o.ext,
        'name': o.name,
        'origin': o.origin.toUpperCase(),
        'target': o.target.toUpperCase(),
        'from': peer.toUpperCase(),
        'src': 'rx',
        'state': 'rx',
        'ttlUntil': DateTime.now().millisecondsSinceEpoch ~/ 1000 +
            (o.ttlS > 0 ? o.ttlS : defaultTtlS),
        'createdMs': DateTime.now().millisecondsSinceEpoch,
      });
    }
    _activeSha.add(hex);
    return MeshBulkDecision.accept(have > o.size ? o.size : have);
  }

  Uint8List readAt(Uint8List sha, int offset, int len) {
    final hex = shaHex(sha);
    try {
      final m = _meta(hex);
      if (m == null) return Uint8List(0);
      _activeSha.add(hex);
      if (m['src'] == 'archive') {
        if (_cacheSha != hex) {
          final bytes = _archive?.get(m['token'] as String? ?? '');
          if (bytes == null) return Uint8List(0);
          _cacheSha = hex;
          _cacheBytes = bytes;
        }
        final d = _cacheBytes!;
        if (offset >= d.length) return Uint8List(0);
        return Uint8List.sublistView(
            d, offset, (offset + len).clamp(0, d.length));
      }
      final raf = File(_partPath(hex)).openSync();
      try {
        raf.setPositionSync(offset);
        return raf.readSync(len);
      } finally {
        raf.closeSync();
      }
    } catch (e) {
      _log('read $hex@$offset failed: $e');
      return Uint8List(0);
    }
  }

  bool writeAt(Uint8List sha, int offset, Uint8List data) {
    final hex = shaHex(sha);
    try {
      final raf = File(_partPath(hex)).openSync(mode: FileMode.append);
      try {
        if (raf.lengthSync() != offset) {
          // Only contiguous appends are valid (the session resyncs on gaps).
          if (offset > raf.lengthSync()) return false;
          raf.truncateSync(offset); // overlap after resync: rewind
        }
        raf.setPositionSync(offset);
        raf.writeFromSync(data);
        return true;
      } finally {
        raf.closeSync();
      }
    } catch (e) {
      _log('write $hex@$offset failed: $e');
      return false;
    }
  }

  /// Full-file SHA-256 verify of the received .part.
  bool verify(Uint8List sha) {
    final hex = shaHex(sha);
    try {
      final f = File(_partPath(hex));
      if (!f.existsSync()) return false;
      final got = crypto.sha256.convert(f.readAsBytesSync()).bytes;
      final ok = shaHex(Uint8List.fromList(got)) == hex;
      if (!ok) {
        _log('verify FAILED for $hex — truncating for a clean retry');
        f.deleteSync(); // hash mismatch: partial is poison, start over
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// A verified inbound completed. Final target → MediaArchive (+ the chat
  /// bubble renders on next media poll); relay → state ready for forwarding.
  void completeInbound(Uint8List sha, {required String selfCallsign}) {
    final hex = shaHex(sha);
    _activeSha.remove(hex);
    final m = _meta(hex);
    if (m == null) return;
    final target = (m['target'] as String? ?? '').toUpperCase();
    if (target == selfCallsign.toUpperCase()) {
      try {
        final bytes = File(_partPath(hex)).readAsBytesSync();
        final token = _archive?.putBytes(bytes, m['ext'] as String? ?? 'bin',
            name: m['name'] as String?);
        _log('received ${m['name']} (${bytes.length}B) -> archive $token');
        File(_partPath(hex)).deleteSync();
        m['state'] = 'done';
        _saveMeta(hex, m);
      } catch (e) {
        _log('archive of $hex failed: $e');
      }
      return;
    }
    m['state'] = 'ready'; // we are a custodian now — forward when possible
    _saveMeta(hex, m);
    _log('holding ${m['name']} for $target (custody)');
  }

  /// Downstream FILE_OK — the next hop holds it now.
  void handedOver(Uint8List sha, String peer) {
    final hex = shaHex(sha);
    _activeSha.remove(hex);
    _cacheSha = null;
    _cacheBytes = null;
    final m = _meta(hex);
    if (m == null) return;
    final target = (m['target'] as String? ?? '').toUpperCase();
    MeshStore.instance.recordBulkHandover(hex, target, peer);
    if (m['src'] == 'archive') {
      m['state'] = 'done'; // origin keeps the blob in the archive anyway
      _saveMeta(hex, m);
    } else {
      // Intermediate hop: payload custody moved on — drop our copy.
      try {
        File(_partPath(hex)).deleteSync();
      } catch (_) {}
      try {
        File(_metaPath(hex)).deleteSync();
      } catch (_) {}
      _log('handed ${m['name']} to $peer — spool copy dropped');
    }
  }

  /// Transfer ended without custody moving (link drop / politeness cycle).
  void transferEnded(Uint8List sha) {
    final hex = shaHex(sha);
    _activeSha.remove(hex);
    if (_cacheSha == hex) {
      _cacheSha = null;
      _cacheBytes = null;
    }
  }

  // --- housekeeping -----------------------------------------------------------

  int _usedBytes() {
    final d = _dir;
    if (d == null) return 0;
    var total = 0;
    try {
      for (final f in Directory(d).listSync()) {
        if (f is File && f.path.endsWith('.part')) total += f.lengthSync();
      }
    } catch (_) {}
    return total;
  }

  /// TTL + quota sweep. Never touches entries with a live transfer.
  void sweep() {
    if (!ready) return;
    final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final entries = _metas();
    for (final e in entries) {
      final ttl = (e.value['ttlUntil'] as num?)?.toInt() ?? 0;
      final done = e.value['state'] == 'done';
      if (_activeSha.contains(e.key)) continue;
      if (ttl < nowS || done && e.value['src'] != 'archive') {
        try {
          File(_partPath(e.key)).deleteSync();
        } catch (_) {}
        if (ttl < nowS) {
          try {
            File(_metaPath(e.key)).deleteSync();
          } catch (_) {}
        }
      }
    }
    var used = _usedBytes();
    if (used <= quotaBytes) return;
    // Oldest stalled partials go first (ready relay copies are custody —
    // they only leave via handover or TTL unless quota forces it).
    final victims = _metas()
      ..sort((a, b) => ((a.value['createdMs'] as num?) ?? 0)
          .compareTo((b.value['createdMs'] as num?) ?? 0));
    for (final phase in ['rx', 'ready']) {
      for (final e in victims) {
        if (used <= quotaBytes) return;
        if (e.value['state'] != phase || _activeSha.contains(e.key)) continue;
        try {
          final f = File(_partPath(e.key));
          if (f.existsSync()) {
            used -= f.lengthSync();
            f.deleteSync();
          }
          File(_metaPath(e.key)).deleteSync();
          _log('quota evicted ${e.value['name']}');
        } catch (_) {}
      }
    }
  }

  /// Snapshot for the Bluetooth wapp transfers view.
  List<Map<String, dynamic>> transfersJson() {
    final out = <Map<String, dynamic>>[];
    for (final e in _metas()) {
      final m = e.value;
      final part = File(_partPath(e.key));
      final have = part.existsSync()
          ? part.lengthSync()
          : (m['src'] == 'archive' ? (m['size'] as num?)?.toInt() ?? 0 : 0);
      out.add({
        'sha': e.key.substring(0, 12),
        'name': m['name'],
        'target': m['target'],
        'origin': m['origin'],
        'size': m['size'],
        'have': have,
        'state': m['state'],
        'active': _activeSha.contains(e.key),
      });
    }
    return out;
  }
}
