import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../wapp/geoui/widgets/media_view.dart' show sharedMediaArchive;
import '../log_service.dart';
import '../media_disk_cache.dart';
import '../reticulum/rns_service.dart';
import 'hero_item.dart';
import 'launcher_visibility.dart';

/// Keeps the pictures of the people you follow.
///
/// A followed author's post is text we mirror into the relay store and serve to
/// peers; its images are the other half of that promise. We pull them into the
/// content-addressed [MediaArchive] as *hosted* blobs at the `followed` tier,
/// which does two things at once: our own Blossom server can then serve them to
/// other devices (`GET /<sha256>`), and the hero renders them from disk instead
/// of re-fetching over the network on every launch.
///
/// The eviction rules are already written and already run hourly
/// (`planEviction`, host_retention_policy.dart): strangers go first, then
/// followed **media**, largest first — and text is never in that inventory at
/// all, so notes are structurally safe. All this class does is put the bytes in
/// front of them.
///
/// The budget below is not decoration. This writes multi-MB blobs into a sqlite
/// store that lives on the **main isolate**, so an unbounded ingest would show
/// up exactly as the pegged-core-inside-native-sqlite signature in
/// docs/performance.md §4.1.
class FollowedMediaCache {
  FollowedMediaCache._();
  static final FollowedMediaCache instance = FollowedMediaCache._();

  static const int _maxBlobBytes = 5 * 1024 * 1024;
  static const int _maxPerCycle = 4;
  static const int _maxConcurrent = 2;

  /// A URL that failed is remembered, not retried on every cycle for ever.
  /// "Cache the miss, not just the hit" (docs/performance.md §3.2): on a public
  /// network a dead image link is the *common* case, and a hit-only cache
  /// re-fetches it until the end of time.
  static const Duration _retryAfter = Duration(hours: 12);
  static const int _maxMisses = 5000;
  final Map<String, DateTime> _misses = {};

  final Set<String> _done = {};
  final Set<String> _inFlight = {};

  /// url -> the author who posted it. Needed because a blob from an account the
  /// user asked this device to KEEP is pinned in the archive (never evicted),
  /// while an ordinary followed author's picture is merely hosted.
  final Map<String, String> _authorOf = {};
  String? _path;

  void bind(String path) {
    if (_path == path) return;
    _path = path;
    _load();
  }

  /// Offer this refresh's items. Returns immediately; fetching happens in the
  /// background and lands in the archive for the *next* refresh to render.
  void ingest(List<HeroItem> items) {
    if (!_shouldCache()) return;

    final wanted = <String>[];
    final now = DateTime.now();
    for (final i in items) {
      final url = i.imageUrl;
      if (url == null || !url.startsWith('http')) continue; // already local
      if (_done.contains(url) || _inFlight.contains(url)) continue;
      final missedAt = _misses[url];
      if (missedAt != null && now.difference(missedAt) < _retryAfter) continue;
      final author = i.authorPubkey;
      if (author != null) _authorOf[url] = author;
      wanted.add(url);
      if (wanted.length >= _maxPerCycle) break;
    }
    if (wanted.isEmpty) return;

    for (final url in wanted.take(_maxConcurrent)) {
      unawaited(_fetch(url));
    }
    // The rest queue up behind the in-flight two, on the next cycle.
  }

  /// Only mirror media when we are actually acting as a host, and only while the
  /// user is looking at the launcher — this is discretionary, prefetched bytes,
  /// and a phone in a pocket has no reason to spend a cellular megabyte on it.
  bool _shouldCache() =>
      LauncherVisibility.instance.visible.value &&
      RnsService.instance.hostingActive;

  Future<void> _fetch(String url) async {
    _inFlight.add(url);
    try {
      final bytes =
          await MediaDiskCache.instance.fetch(url, maxBytes: _maxBlobBytes);
      if (bytes == null || bytes.isEmpty) {
        _miss(url);
        return;
      }
      final archive = sharedMediaArchive();
      if (archive == null) return;
      final author = _authorOf[url] ?? '';
      // An account the user explicitly keeps gets its media PINNED: hosted,
      // served, and exempt from the eviction sweep. That is the whole promise of
      // "keep data" — a device that quietly deleted it under pressure would be
      // worse than one that never offered.
      final pin = author.isNotEmpty && RnsService.instance.isKeepData(author);
      final token = archive.putHosted(
        bytes,
        _extOf(url),
        originPubHex: author,
        tier: 1, // Tier.followed
        pin: pin,
      );
      _done.add(url);
      _authorOf.remove(url);
      _save();
      LogService.instance.add(
          'hero: cached ${pin ? 'PINNED ' : ''}media ${bytes.length}B -> $token');
    } catch (e) {
      _miss(url);
    } finally {
      _inFlight.remove(url);
    }
  }

  void _miss(String url) {
    if (_misses.length >= _maxMisses) {
      // Bounded: drop the oldest quarter rather than grow forever.
      final ordered = _misses.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      for (final e in ordered.take(_maxMisses ~/ 4)) {
        _misses.remove(e.key);
      }
    }
    _misses[url] = DateTime.now();
    _save();
  }

  static String _extOf(String url) {
    final clean = url.split('?').first;
    final dot = clean.lastIndexOf('.');
    if (dot < 0 || dot == clean.length - 1) return 'jpg';
    final ext = clean.substring(dot + 1).toLowerCase();
    return ext.length <= 4 ? ext : 'jpg';
  }

  /// Where a hero item's local bytes live, once mirrored. The card resolves the
  /// `file:` token through the archive rather than the network.
  static bool isLocal(String? imageUrl) =>
      imageUrl != null && imageUrl.startsWith('file:');

  Timer? _saveDebounce;
  void _save() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 5), () {
      final path = _path;
      if (path == null) return;
      try {
        File(path).writeAsStringSync(jsonEncode({
          'done': _done.toList(),
          'misses': {
            for (final e in _misses.entries)
              e.key: e.value.millisecondsSinceEpoch,
          },
        }));
      } catch (_) {}
    });
  }

  void _load() {
    final path = _path;
    if (path == null) return;
    try {
      final f = File(path);
      if (!f.existsSync()) return;
      final j = jsonDecode(f.readAsStringSync());
      if (j is! Map) return;
      for (final u in (j['done'] as List? ?? const [])) {
        _done.add(u.toString());
      }
      final misses = j['misses'];
      if (misses is Map) {
        for (final e in misses.entries) {
          _misses[e.key.toString()] = DateTime.fromMillisecondsSinceEpoch(
              (e.value as num).toInt());
        }
      }
    } catch (_) {}
  }
}
