// Persistent on-disk cache for remote media (NOSTR post images, etc.).
//
// Goals (per product ask):
//  - Don't re-download the same media every session.
//  - Cap the cache at ~1 GB with LRU eviction of the oldest files…
//  - …EXCEPT files the user "kept": pinned (saved/bookmarked) or from a post the
//    logged-in user interacted with (liked/replied). Those survive eviction.
//
// Files are keyed by sha256(url). LRU is the filesystem mtime, which we bump on
// every cache hit. The kept set is persisted so it survives restarts.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class MediaDiskCache {
  MediaDiskCache._();
  static final MediaDiskCache instance = MediaDiskCache._();

  static const int _cap = 1024 * 1024 * 1024; // 1 GB ceiling
  static const int _target = 900 * 1024 * 1024; // evict down to this (hysteresis)

  Directory? _dir;
  File? _keptFile;
  final Set<String> _kept = {}; // sha256 hex of URLs to never evict
  bool _initDone = false;
  Future<void>? _initing;
  final Map<String, Uint8List> _mem = {}; // tiny hot in-memory layer
  static const int _memMax = 40;

  Future<void> _ensure() {
    if (_initDone) return Future.value();
    return _initing ??= _init();
  }

  Future<void> _init() async {
    if (kIsWeb) {
      _initDone = true;
      return;
    }
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}/media_cache');
      if (!d.existsSync()) d.createSync(recursive: true);
      _dir = d;
      _keptFile = File('${d.path}/.kept');
      if (_keptFile!.existsSync()) {
        for (final l in _keptFile!.readAsLinesSync()) {
          final s = l.trim();
          if (s.isNotEmpty) _kept.add(s);
        }
      }
    } catch (_) {}
    _initDone = true;
  }

  String _hash(String url) => sha256.convert(utf8.encode(url)).toString();

  /// Fetch [url], using the disk cache. Returns null if it can't be fetched or
  /// exceeds [maxBytes] (the caller then shows a tap-to-download card).
  Future<Uint8List?> fetch(String url, {int maxBytes = 10 * 1024 * 1024}) async {
    await _ensure();
    final h = _hash(url);
    final hot = _mem[h];
    if (hot != null) return hot;
    final dir = _dir;
    if (dir != null) {
      final f = File('${dir.path}/$h');
      if (f.existsSync()) {
        try {
          final bytes = await f.readAsBytes();
          // Bump LRU (best-effort) + populate the hot layer.
          unawaited(f.setLastModified(DateTime.now()).catchError((_) {}));
          _remember(h, bytes);
          return bytes;
        } catch (_) {}
      }
    }
    // Not cached — size-gate then download.
    try {
      final head = await http
          .head(Uri.parse(url))
          .timeout(const Duration(seconds: 8));
      final len = int.tryParse(head.headers['content-length'] ?? '') ?? 0;
      if (len > maxBytes) return null;
    } catch (_) {
      // HEAD unsupported — proceed; we cap by the downloaded length below.
    }
    try {
      final resp =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return null;
      final bytes = resp.bodyBytes;
      if (bytes.length > maxBytes) return null;
      final dir2 = _dir;
      if (dir2 != null) {
        try {
          await File('${dir2.path}/$h').writeAsBytes(bytes, flush: false);
          unawaited(_evictIfNeeded());
        } catch (_) {}
      }
      _remember(h, bytes);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  void _remember(String h, Uint8List bytes) {
    if (bytes.length > 2 * 1024 * 1024) return; // don't hold big files in RAM
    _mem[h] = bytes;
    if (_mem.length > _memMax) _mem.remove(_mem.keys.first);
  }

  /// Mark [url]'s media as kept (pinned / interacted-with) — never evicted.
  Future<void> keep(String url) async {
    await _ensure();
    final h = _hash(url);
    if (!_kept.add(h)) return;
    try {
      await _keptFile?.writeAsString('${_kept.join('\n')}\n');
    } catch (_) {}
  }

  /// Bulk-keep every media url in a post the user interacted with.
  Future<void> keepAll(Iterable<String> urls) async {
    for (final u in urls) {
      await keep(u);
    }
  }

  bool _evicting = false;
  Future<void> _evictIfNeeded() async {
    if (_evicting) return;
    _evicting = true;
    try {
      final dir = _dir;
      if (dir == null) return;
      final files = <({File f, int size, DateTime at})>[];
      var total = 0;
      for (final e in dir.listSync()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (name.startsWith('.')) continue; // skip .kept
        try {
          final st = e.statSync();
          total += st.size;
          files.add((f: e, size: st.size, at: st.modified));
        } catch (_) {}
      }
      if (total <= _cap) return;
      // Oldest first; keep pinned/interacted regardless.
      files.sort((a, b) => a.at.compareTo(b.at));
      for (final e in files) {
        if (total <= _target) break;
        final h = e.f.uri.pathSegments.last;
        if (_kept.contains(h)) continue;
        try {
          e.f.deleteSync();
          total -= e.size;
        } catch (_) {}
      }
    } finally {
      _evicting = false;
    }
  }
}
