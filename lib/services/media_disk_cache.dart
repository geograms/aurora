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

  /// Cache-only lookup (no network). For locally generated derivatives — e.g.
  /// a video's poster frame stored under the synthetic key "<url>#poster".
  Future<Uint8List?> peek(String key) async {
    await _ensure();
    final h = _hash(key);
    final hot = _mem[h];
    if (hot != null) return hot;
    final dir = _dir;
    if (dir == null) return null;
    final f = File('${dir.path}/$h');
    if (!f.existsSync()) return null;
    try {
      final bytes = await f.readAsBytes();
      _remember(h, bytes);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Store locally produced bytes under [key] (same LRU/eviction as fetched
  /// media). Pairs with [peek].
  Future<void> putLocal(String key, Uint8List bytes) async {
    await _ensure();
    final h = _hash(key);
    final dir = _dir;
    if (dir != null) {
      try {
        await File('${dir.path}/$h').writeAsBytes(bytes, flush: false);
        unawaited(_evictIfNeeded());
      } catch (_) {}
    }
    _remember(h, bytes);
  }

  /// Probe a media URL's size (Content-Length) without downloading it. 0 if
  /// the server doesn't report it. Used to show "▶ 12.3 MB" before a video
  /// download. -1 when the URL is dead (4xx/5xx) — media hosts purge files
  /// (blossom servers 404 with a tiny text body whose content-length would
  /// otherwise read as "9 B video").
  Future<int> probeSize(String url) async {
    try {
      final head = await http
          .head(Uri.parse(url))
          .timeout(const Duration(seconds: 8));
      if (head.statusCode >= 400) return -1;
      return int.tryParse(head.headers['content-length'] ?? '') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Streaming download with progress — for big media (videos) where the caller
  /// wants a live "X MB / Y MB" bar. Uses the same on-disk cache as [fetch], but
  /// times out PER CHUNK (not on the whole body), so a large-but-progressing
  /// download isn't killed at 20s. [onProgress] is (received, total) bytes;
  /// total is 0 when the server didn't send Content-Length.
  Future<Uint8List?> fetchStreamed(
    String url, {
    int maxBytes = 200 * 1024 * 1024,
    void Function(int received, int total)? onProgress,
  }) async {
    await _ensure();
    final h = _hash(url);
    final hot = _mem[h];
    if (hot != null) {
      onProgress?.call(hot.length, hot.length);
      return hot;
    }
    final dir = _dir;
    if (dir != null) {
      final f = File('${dir.path}/$h');
      if (f.existsSync()) {
        try {
          final bytes = await f.readAsBytes();
          unawaited(f.setLastModified(DateTime.now()).catchError((_) {}));
          _remember(h, bytes);
          onProgress?.call(bytes.length, bytes.length);
          return bytes;
        } catch (_) {}
      }
    }
    final client = http.Client();
    try {
      final resp = await client
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return null;
      final total = resp.contentLength ?? 0;
      if (total > 0 && total > maxBytes) return null;
      onProgress?.call(0, total);
      final builder = BytesBuilder(copy: false);
      var received = 0;
      // Per-chunk timeout: a stalled connection aborts, a slow one keeps going.
      await for (final chunk
          in resp.stream.timeout(const Duration(seconds: 30))) {
        builder.add(chunk);
        received += chunk.length;
        if (received > maxBytes) return null; // over cap mid-stream
        onProgress?.call(received, total);
      }
      final bytes = builder.toBytes();
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
    } finally {
      client.close();
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
