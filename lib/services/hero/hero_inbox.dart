import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../log_service.dart';
import 'hero_item.dart';
import 'hero_source.dart';

/// Where wapps' hero cards live.
///
/// A wapp publishes with `hal_msg_send({"type":"hero.publish", …})`; both the
/// foreground page and the headless background manager funnel into [publish].
/// Headless matters: a blog wapp does its work with nobody watching, and its
/// card must be waiting on the hero when the user next looks — hence the items
/// are persisted, not just held in memory.
///
/// Nothing here trusts the publisher. A wapp is third-party code, and every
/// field it can set that could let it dominate the carousel is clamped on the
/// way in — see [_parseItem].
class HeroInbox {
  HeroInbox._();
  static final HeroInbox instance = HeroInbox._();

  /// wappId -> itemId -> item. Bounded on both axes.
  final Map<String, Map<String, HeroItem>> _byWapp = {};

  static const int _maxItemsPerWapp = 20;
  static const int _maxWapps = 8;
  static const int _maxTitle = 80;
  static const int _maxSummary = 160;
  static const int _maxThumbBytes = 64 * 1024;
  static const Duration _defaultTtl = Duration(hours: 24);
  static const Duration _maxTtl = Duration(days: 7);

  /// One publish per second per wapp. A wapp that calls this on every tick
  /// (they tick every 5s by default, but a buggy one could hammer it) must not
  /// be able to churn the file or the feed.
  static const Duration _minPublishGap = Duration(seconds: 1);
  final Map<String, DateTime> _lastPublish = {};

  String? _path;
  Timer? _saveDebounce;
  bool _loaded = false;

  /// Bumped whenever the contents change, so the feed can refresh on a headless
  /// publish instead of waiting up to five minutes for its next tick.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// [path] is `hero_inbox.json` under the shared wapp-data root.
  void bind(String path) {
    if (_path == path && _loaded) return;
    _path = path;
    _load();
  }

  /// Handle one `hero.*` message from [wappId]. Returns true if it was ours.
  bool handleMessage(String wappId, Map<String, dynamic> msg) {
    switch ((msg['type'] ?? '').toString()) {
      case 'hero.publish':
        final items = msg['items'];
        if (items is! List) return true;
        _publish(wappId, items, replace: msg['replace'] != false);
        return true;
      case 'hero.remove':
        final id = (msg['id'] ?? '').toString();
        if (id.isNotEmpty) {
          _byWapp[wappId]?.remove('$wappId:$id');
          _changed();
        }
        return true;
      case 'hero.clear':
        if (_byWapp.remove(wappId) != null) _changed();
        return true;
    }
    return false;
  }

  void _publish(String wappId, List<dynamic> raw, {required bool replace}) {
    final now = DateTime.now();
    final last = _lastPublish[wappId];
    if (last != null && now.difference(last) < _minPublishGap) {
      return; // rate-limited; the wapp will get another turn in a second
    }
    _lastPublish[wappId] = now;

    if (!_byWapp.containsKey(wappId) && _byWapp.length >= _maxWapps) {
      LogService.instance
          .add('hero: inbox full, ignoring items from $wappId');
      return;
    }

    final parsed = <String, HeroItem>{};
    for (final r in raw) {
      if (r is! Map) continue;
      final item = _parseItem(wappId, r.cast<String, dynamic>(), now);
      if (item == null) continue;
      parsed[item.id] = item;
      if (parsed.length >= _maxItemsPerWapp) break;
    }
    if (parsed.isEmpty && !replace) return;

    final slot = replace
        ? (_byWapp[wappId] = <String, HeroItem>{})
        : (_byWapp[wappId] ??= <String, HeroItem>{});
    slot.addAll(parsed);

    // Merge mode can overflow the cap: drop the oldest.
    if (slot.length > _maxItemsPerWapp) {
      final ordered = slot.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      slot
        ..clear()
        ..addEntries(
            ordered.take(_maxItemsPerWapp).map((e) => MapEntry(e.id, e)));
    }
    _changed();
  }

  HeroItem? _parseItem(String wappId, Map<String, dynamic> j, DateTime now) {
    final rawId = (j['id'] ?? '').toString().trim();
    if (rawId.isEmpty || rawId.length > 64) return null;
    final title = _clip((j['title'] ?? '').toString().trim(), _maxTitle);
    if (title.isEmpty) return null;

    // A wapp that claims to be from the future would sit at the top of the hero
    // forever — the ranker decays by age, and a future age doesn't decay. Clamp
    // to a sane window in both directions.
    final createdSec = (j['created_at'] as num?)?.toInt() ?? 0;
    var created = createdSec > 0
        ? DateTime.fromMillisecondsSinceEpoch(createdSec * 1000)
        : now;
    final floor = now.subtract(const Duration(days: 30));
    final ceiling = now.add(const Duration(minutes: 5));
    if (created.isBefore(floor)) created = floor;
    if (created.isAfter(ceiling)) created = now;

    var ttl = Duration(seconds: (j['ttl'] as num?)?.toInt() ?? _defaultTtl.inSeconds);
    if (ttl <= Duration.zero || ttl > _maxTtl) ttl = _maxTtl;
    // TTL runs from NOW, not from created_at: it says how long to keep showing
    // the card, not how old the thing itself may be. Measured from created_at, a
    // wapp surfacing last year's blog post would have its card expire the
    // instant it was published.
    final expires = now.add(ttl);

    return HeroItem(
      id: '$wappId:$rawId',
      sourceId: wappId,
      intent: (j['intent'] ?? '').toString().trim().toLowerCase().isEmpty
          ? null
          : (j['intent'] as String).trim().toLowerCase(),
      title: title,
      summary: _clip((j['summary'] ?? '').toString().trim(), _maxSummary),
      imageUrl: _nonEmpty(j['image']),
      thumbnail: _thumb(j['thumb']),
      createdAt: created,
      expiresAt: expires,
      // A wapp must not be able to write the post's text into the author
      // chip — that is what made the launcher show a headline where the
      // person's name belongs.
      authorName: _authorOf(
          j, title, (j['summary'] ?? '').toString()),
      priority: ((j['priority'] as num?)?.toInt() ?? 0).clamp(0, 2),
      deepLink: _nonEmpty(j['view']),
      payload: j['payload'] is Map
          ? (j['payload'] as Map).cast<String, dynamic>()
          : null,
    );
  }

  /// The publishing wapp's `author`, unless it is really the post's own text.
  static String _authorOf(
      Map<String, dynamic> j, String title, String summary) {
    final name = (_nonEmpty(j['author']) ?? '').trim();
    if (name.isEmpty) return '';
    return HeroItem.looksLikePostText(name, title, summary) ? '' : name;
  }

  static String? _nonEmpty(dynamic v) {
    final s = (v ?? '').toString().trim();
    return s.isEmpty ? null : s;
  }

  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max - 1)}…';

  static Uint8List? _thumb(dynamic v) {
    final s = (v ?? '').toString();
    if (s.isEmpty) return null;
    try {
      var raw = s;
      while (raw.length % 4 != 0) {
        raw += '=';
      }
      final bytes = base64Url.decode(raw);
      if (bytes.length > _maxThumbBytes) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Live items, oldest expiry pruned. The wapp source reads this.
  List<HeroItem> items() {
    final now = DateTime.now();
    final out = <HeroItem>[];
    var pruned = false;
    for (final slot in _byWapp.values) {
      slot.removeWhere((_, i) {
        final dead = i.expired(now);
        if (dead) pruned = true;
        return dead;
      });
      out.addAll(slot.values);
    }
    if (pruned) _scheduleSave();
    return out;
  }

  /// Drop everything published by a wapp that is no longer installed — its
  /// cards would open nothing.
  void forget(String wappId) {
    if (_byWapp.remove(wappId) != null) _changed();
  }

  void _changed() {
    revision.value++;
    _scheduleSave();
  }

  // ── Persistence ───────────────────────────────────────────────────────────
  //
  // Debounced: a wapp publishing a batch of ten items must cost one file write,
  // not ten. Small file (items are clamped), so this stays off the profiler.

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 2), _save);
  }

  void _save() {
    final path = _path;
    if (path == null) return;
    try {
      final json = <String, dynamic>{};
      for (final e in _byWapp.entries) {
        json[e.key] = [for (final i in e.value.values) _toJson(i)];
      }
      File(path).writeAsStringSync(jsonEncode(json));
    } catch (e) {
      LogService.instance.add('hero: inbox save failed: $e');
    }
  }

  void _load() {
    final path = _path;
    if (path == null) return;
    _loaded = true;
    try {
      final f = File(path);
      if (!f.existsSync()) return;
      final json = jsonDecode(f.readAsStringSync());
      if (json is! Map) return;
      final now = DateTime.now();
      for (final e in json.entries) {
        final wappId = e.key.toString();
        final list = e.value;
        if (list is! List) continue;
        final slot = <String, HeroItem>{};
        for (final r in list) {
          if (r is! Map) continue;
          final i = _fromJson(r.cast<String, dynamic>());
          if (i == null || i.expired(now)) continue;
          slot[i.id] = i;
        }
        if (slot.isNotEmpty) _byWapp[wappId] = slot;
      }
      if (_byWapp.isNotEmpty) revision.value++;
    } catch (e) {
      LogService.instance.add('hero: inbox load failed: $e');
    }
  }

  Map<String, dynamic> _toJson(HeroItem i) => {
        'id': i.id,
        'source': i.sourceId,
        'intent': i.intent,
        'title': i.title,
        'summary': i.summary,
        'image': i.imageUrl,
        'thumb': i.thumbnail == null ? null : base64Url.encode(i.thumbnail!),
        'created_at': i.createdAt.millisecondsSinceEpoch,
        'expires_at': i.expiresAt?.millisecondsSinceEpoch,
        'author': i.authorName,
        'priority': i.priority,
        'view': i.deepLink,
        'payload': i.payload,
      };

  HeroItem? _fromJson(Map<String, dynamic> j) {
    final id = (j['id'] ?? '').toString();
    final source = (j['source'] ?? '').toString();
    final title = (j['title'] ?? '').toString();
    if (id.isEmpty || source.isEmpty || title.isEmpty) return null;
    final createdMs = (j['created_at'] as num?)?.toInt() ?? 0;
    final expiresMs = (j['expires_at'] as num?)?.toInt();
    return HeroItem(
      id: id,
      sourceId: source,
      intent: _nonEmpty(j['intent']),
      title: title,
      summary: (j['summary'] ?? '').toString(),
      imageUrl: _nonEmpty(j['image']),
      thumbnail: _thumb(j['thumb']),
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdMs),
      expiresAt: expiresMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expiresMs),
      authorName: _authorOf(
          j, title, (j['summary'] ?? '').toString()),
      priority: ((j['priority'] as num?)?.toInt() ?? 0).clamp(0, 2),
      deepLink: _nonEmpty(j['view']),
      payload: j['payload'] is Map
          ? (j['payload'] as Map).cast<String, dynamic>()
          : null,
    );
  }

  /// Tests only — the singleton would otherwise leak state between cases.
  @visibleForTesting
  void resetForTest() {
    _byWapp.clear();
    _lastPublish.clear();
    _saveDebounce?.cancel();
    _path = null;
    _loaded = false;
  }
}

/// Feeds whatever the wapps published into the hero.
class WappHeroSource implements HeroSource {
  @override
  String get id => 'wapp';

  @override
  Future<List<HeroItem>> candidates() async => HeroInbox.instance.items();
}
