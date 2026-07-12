import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier, compute;

import '../util/nostr_crypto.dart';
import 'event_bus.dart';
import 'reticulum/rns_service.dart';
import 'log_service.dart';
import 'social/note_text.dart';

class NoveltyItem {
  final String id;
  final String authorPubkey;
  final String authorName;
  final String? authorPic;
  final String title;
  final String summary;
  final Uint8List? thumbnail;
  final DateTime createdAt;

  /// Reactions / replies this post has gathered, as tallied by the NOSTR
  /// engine. Drive the discovery ordering; 0 until stats arrive.
  final int likes;
  final int replies;

  /// First inline http image url in the post, if any — the hero card renders
  /// it as its background (falling back to [thumbnail], then a gradient).
  final String? imageUrl;

  /// The note's original content, tokens and all — handed to the social wapp
  /// on hero tap so the thread can render instantly without a re-download.
  final String rawText;

  const NoveltyItem({
    required this.id,
    required this.authorPubkey,
    required this.authorName,
    this.authorPic,
    required this.title,
    required this.summary,
    this.thumbnail,
    required this.createdAt,
    this.likes = 0,
    this.replies = 0,
    this.imageUrl,
    this.rawText = '',
  });

  bool get hasImage => imageUrl != null || thumbnail != null;

  /// Discovery rank: engagement first (replies weigh double — a conversation
  /// beats a drive-by like), and posts that bring a picture get a boost so the
  /// hero has real backgrounds to show.
  int get score => (likes + 2 * replies) * (hasImage ? 2 : 1) + (hasImage ? 2 : 0);
}

/// The launcher's hero carousel: what the people you follow just posted, or —
/// when you follow nobody, or they have been quiet — the posts the wider NOSTR
/// network liked most.
///
/// Reads the **live NOSTR hub** (`NostrClient`, running on its own isolate),
/// not the Reticulum relay store. The hub is what actually keeps talking to
/// public relays, so this is the only source that refreshes on its own. Two
/// standing subscriptions feed it:
///
///  * `kinds:[1], authors:<follows>` — fresh posts from people you follow.
///  * [RnsService.nostrDiscovery] — kind-1 posts that gathered >2 reactions.
///    Spam earns no reactions, so this rung is self-filtering; it is exactly
///    the "most liked" feed and it is ranked by like count.
///
/// A mesh-only node with no relay reachability still shows something: the last
/// rung falls back to the Reticulum relay store's firehose.
class NoveltiesService {
  NoveltiesService._();
  static final NoveltiesService instance = NoveltiesService._();

  static const int _bufferCap = 40;

  /// How long to wait for the like-ranked discovery feed before falling back to
  /// the unranked firehose. Discovery needs to see reactions accumulate, which
  /// takes a few refresh cycles on a cold start.
  static const int _firehoseGraceMs = 45 * 1000;
  int? _firstLoadMs;

  final ValueNotifier<List<NoveltyItem>> novelties =
      ValueNotifier<List<NoveltyItem>>(const []);

  // Newest-first buffers, keyed by event id so a redelivered event is one row.
  final Map<String, NoveltyItem> _followsBuf = {};
  final Map<String, NoveltyItem> _discoBuf = {};

  String? _followsSub;
  String? _discoSub;
  String _followsKey = '';
  int _refreshSerial = 0;

  /// Open (or re-open) the standing subscriptions.
  ///
  /// The engine isolate is spawned asynchronously, so every `nostr*` call
  /// returns null until it is up; both subscriptions are therefore retried on
  /// each refresh until they take. The follows subscription is torn down and
  /// rebuilt whenever the follow set changes, so it never leaks a stale filter.
  void _ensureSubscriptions() {
    final rns = RnsService.instance;
    final follows = rns.follows.asSet.toList()..sort();
    final key = follows.join(',');
    if (key != _followsKey) {
      _followsKey = key;
      _followsBuf.clear();
      final stale = _followsSub;
      if (stale != null) rns.nostrUnsubscribe(stale);
      _followsSub = null;
    }
    if (_followsSub == null && follows.isNotEmpty) {
      _followsSub = rns.nostrSubscribe(
        jsonEncode({
          'kinds': [1],
          'authors': follows,
          'limit': _bufferCap,
        }),
      );
    }
    _discoSub ??= rns.nostrDiscovery();
  }

  /// Drain one subscription and fold the NEW events into [buf].
  ///
  /// The expensive part — JSON field extraction, token-stripping regexes and
  /// the base64 thumbnail decode — runs on a background isolate via [compute],
  /// so a burst of forty posts never competes with a hero swipe for UI frames.
  /// Events already in the buffer are never re-parsed.
  Future<void> _drainInto(String? subId, Map<String, NoveltyItem> buf) async {
    if (subId == null) return;
    final raws = RnsService.instance.nostrDrain(subId, max: 100);
    if (raws.isNotEmpty) {
      final fresh = [
        for (final j in raws)
          if (!buf.containsKey((j['id'] ?? '').toString())) j,
      ];
      if (fresh.isNotEmpty) {
        for (final item in await compute(parseNoveltyBatch, fresh)) {
          buf[item.id] = item;
        }
      }
    }
    if (buf.length <= _bufferCap) return;
    // Bounded: drop the oldest beyond the cap.
    final ordered = buf.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    buf
      ..clear()
      ..addEntries(ordered.take(_bufferCap).map((e) => MapEntry(e.id, e)));
  }

  Future<List<NoveltyItem>> load({int limit = 10}) async {
    final rns = RnsService.instance;
    try {
      _ensureSubscriptions();
      await _drainInto(_followsSub, _followsBuf);
      await _drainInto(_discoSub, _discoBuf);

      // People you follow win, newest first — you asked to hear from them.
      if (_followsBuf.isNotEmpty) {
        _noteRung('follows', _followsBuf.length);
        final items = _followsBuf.values.toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return _hydrate(items.take(limit).toList());
      }

      // Otherwise the network's most-engaged posts: likes + replies (replies
      // weigh double), image posts boosted so the hero has backgrounds.
      if (_discoBuf.isNotEmpty) {
        _noteRung('discovery', _discoBuf.length);
        final items = _hydrate(_discoBuf.values.toList());
        items.sort((a, b) {
          final byScore = b.score.compareTo(a.score);
          return byScore != 0 ? byScore : b.createdAt.compareTo(a.createdAt);
        });
        return items.take(limit).toList();
      }

      // Nothing from the relays yet. The discovery subscription needs a few
      // seconds to gather reactions, and the unranked firehose is mostly spam —
      // so hold the empty state until that grace window closes rather than
      // flashing junk on every cold start.
      _firstLoadMs ??= DateTime.now().millisecondsSinceEpoch;
      final waited = DateTime.now().millisecondsSinceEpoch - _firstLoadMs!;
      if (waited < _firehoseGraceMs) return const [];

      // Still nothing: this node has no relay reachability. Show whatever the
      // Reticulum mesh itself has relayed to us. Rare path (mesh-only node),
      // and at most [limit] events — parsed inline.
      final store = rns.relayStore;
      if (store == null) return const [];
      _noteRung('firehose', limit);
      return _hydrate([
        for (final e in store.firehose(limit: limit))
          parseNoveltyCore(
            id: e.id ?? '',
            pubkey: e.pubkey,
            content: e.content,
            createdAtSec: e.createdAt,
          ),
      ]);
    } catch (_) {
      return const [];
    }
  }

  /// Log which rung of the fallback chain is on screen, once per transition, so
  /// an unexpectedly spammy carousel is traceable to its source.
  String _rung = '';
  void _noteRung(String rung, int size) {
    if (_rung == rung) return;
    _rung = rung;
    LogService.instance.add('novelties: source=$rung ($size buffered)');
  }

  /// Main-isolate finishing pass: fill in what only this isolate knows — the
  /// cached kind-0 profile (name/pic) and the engine's like/reply tallies.
  /// Both are O(1) map lookups; the copy happens only when something changed,
  /// so unchanged items keep their identity (and their decoded-image cache).
  List<NoveltyItem> _hydrate(List<NoveltyItem> items) {
    final rns = RnsService.instance;
    final ids = [
      for (final i in items)
        if (i.id.length == 64) i.id,
    ];
    if (ids.isNotEmpty) rns.nostrTrackStats(ids);
    return [for (final i in items) _hydrateOne(i, rns)];
  }

  NoveltyItem _hydrateOne(NoveltyItem i, RnsService rns) {
    final s = i.id.length == 64
        ? rns.nostrStats(i.id)
        : (likes: 0, replies: 0, mine: false);
    final profile = rns.nostrProfile(i.authorPubkey);
    final name = (profile['name'] ?? '').isNotEmpty
        ? profile['name']!
        : i.authorName;
    final pic = (profile['pic'] ?? '').isNotEmpty ? profile['pic'] : i.authorPic;
    if (s.likes == i.likes &&
        s.replies == i.replies &&
        name == i.authorName &&
        pic == i.authorPic) {
      return i;
    }
    return NoveltyItem(
      id: i.id,
      authorPubkey: i.authorPubkey,
      authorName: name,
      authorPic: pic,
      title: i.title,
      summary: i.summary,
      thumbnail: i.thumbnail,
      createdAt: i.createdAt,
      likes: s.likes,
      replies: s.replies,
      imageUrl: i.imageUrl,
      rawText: i.rawText,
    );
  }

  // What the UI last got, as a cheap change signature. Skipping the notifier
  // when nothing changed keeps the periodic refresh from rebuilding the
  // carousel mid-swipe for no reason.
  String _lastSignature = '';

  Future<void> refresh({int limit = 10}) async {
    final serial = ++_refreshSerial;
    final loaded = await load(limit: limit);
    if (serial != _refreshSerial) return;
    final signature = [
      for (final i in loaded) '${i.id}/${i.likes}/${i.replies}/${i.authorName}',
    ].join('|');
    if (signature == _lastSignature) return;
    _lastSignature = signature;
    novelties.value = List<NoveltyItem>.of(loaded);
  }

}

// ── Pure parsing (runs on a background isolate via compute) ────────────────
//
// Everything below touches no service singleton, so a batch of drained events
// can be turned into NoveltyItems off the UI thread. Author name/pic and the
// like/reply counts are main-isolate state and get filled in by [_hydrate].

/// compute() entry point: parse a batch of drained NIP-01 event JSON maps.
List<NoveltyItem> parseNoveltyBatch(List<Map<String, dynamic>> raws) {
  final out = <NoveltyItem>[];
  for (final j in raws) {
    final id = (j['id'] ?? '').toString();
    final pubkey = (j['pubkey'] ?? '').toString();
    if (id.isEmpty || pubkey.isEmpty) continue;
    out.add(
      parseNoveltyCore(
        id: id,
        pubkey: pubkey,
        content: (j['content'] ?? '').toString(),
        createdAtSec: (j['created_at'] as int?) ?? 0,
      ),
    );
  }
  return out;
}

/// Build an item from raw event fields — token-stripping, title/summary split
/// and the inline-thumbnail decode. Author name falls back to a short npub
/// until the profile cache supplies the real one.
NoveltyItem parseNoveltyCore({
  required String id,
  required String pubkey,
  required String content,
  required int createdAtSec,
}) {
  final body = stripNoteTokens(content);
  final lead = _leadSentence(body);
  final title = _truncate(lead, 60);
  // Summary = the rest of the note AFTER the full lead sentence — never a
  // substring of the (possibly truncated) title, which would cut mid-word.
  final rest = body.startsWith(lead) ? body.substring(lead.length) : '';
  final summary = _truncate(rest.trim(), 120);
  return NoveltyItem(
    id: id,
    authorPubkey: pubkey,
    authorName: _shortAuthor(pubkey),
    title: title.isEmpty ? 'New post' : title,
    summary: summary,
    thumbnail: _thumbnail(content),
    createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtSec * 1000),
    imageUrl: firstNoteImageUrl(content),
    rawText: content,
  );
}

String _shortAuthor(String pubkey) {
  try {
    return NostrCrypto.encodeNpub(pubkey).replaceRange(12, null, '...');
  } catch (_) {
    return pubkey.length > 12 ? '${pubkey.substring(0, 12)}...' : pubkey;
  }
}

/// First sentence (or line) of the note, untruncated — the title is cut from
/// this, and the summary starts where it ends.
String _leadSentence(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return '';
  final firstLine = trimmed.split('\n').first.trim();
  final sentence = firstLine.split(RegExp(r'(?<=[.!?])\s+')).first.trim();
  return sentence.isNotEmpty ? sentence : firstLine;
}

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max - 3)}...';

Uint8List? _thumbnail(String content) {
  final m = RegExp(r'\btn:([A-Za-z0-9_-]+=*)').firstMatch(content);
  if (m == null) return null;
  var raw = m.group(1)!;
  while (raw.length % 4 != 0) {
    raw += '=';
  }
  try {
    return base64Url.decode(raw);
  } catch (_) {
    return null;
  }
}

class NoveltiesRefresher {
  NoveltiesRefresher(this.refresh);
  final Future<void> Function() refresh;
  Timer? _timer;
  EventSubscription<AppStartedEvent>? _appStarted;

  void start() {
    _safeRefresh(); // fill the hero NOW — the user is looking at it
    // Then drain slowly. This never touches the network (the hub buffers events
    // between drains), but it is not free either: every drain re-ranks the
    // buffer and can spawn a `compute` isolate. Draining every 20s to display
    // posts the relays are now only polled for every 10 minutes was churn for
    // nothing. Opening the app refreshes it anyway (AppStartedEvent).
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _safeRefresh());
    _appStarted = EventBus().on<AppStartedEvent>((_) => _safeRefresh());
  }

  void stop() {
    _timer?.cancel();
    _appStarted?.cancel();
  }

  void _safeRefresh() {
    unawaited(refresh().catchError((_) {}));
  }
}
