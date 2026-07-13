import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;

import '../../util/nostr_crypto.dart';
import '../log_service.dart';
import '../reticulum/rns_service.dart';
import '../social/note_text.dart';
import 'followed_media_cache.dart';
import 'hero_item.dart';
import 'hero_source.dart';

/// NOSTR's contribution to the hero.
///
/// Stays a **host** source rather than something the social wapp publishes: the
/// wapp is a pure UI driver with no storage, and every piece of NOSTR state
/// (events, engagement tallies, profiles, the follow set) already lives here.
/// Routing the feed back out through WASM JSON would buy nothing.
///
/// Reads the live NOSTR hub (`NostrClient`, on its own isolate), which is what
/// actually keeps talking to relays, plus — once you follow people — the local
/// mirror in the relay store, so a quiet timeline is backfilled with your
/// follows' older posts instead of going blank.
class NostrHeroSource implements HeroSource {
  @override
  String get id => kHeroSourceNostr;

  static const int _bufferCap = 40;


  // Newest-first buffers, keyed by event id so a redelivered event is one row.
  final Map<String, HeroItem> _followsBuf = {};
  final Map<String, HeroItem> _discoBuf = {};

  /// Live kind-1 as the relays push it, through the quality gate. Discovery
  /// only carries posts that have already collected reactions, so on a fresh
  /// device with nobody followed it can take many minutes to say anything —
  /// which is exactly the empty hero people saw. The firehose answers in
  /// seconds; the ranker still decides what is worth a slot.
  final Map<String, HeroItem> _fireBuf = {};

  String? _followsSub;
  String? _discoSub;
  String? _fireSub;
  String _followsKey = '';
  String _rung = '';

  /// Open (or re-open) the standing subscriptions.
  ///
  /// The engine isolate is spawned asynchronously, so every `nostr*` call
  /// returns null until it is up; both subscriptions are therefore retried on
  /// each refresh until they take. The follows subscription is torn down and
  /// rebuilt whenever the follow set changes, so it never leaks a stale filter —
  /// a leaked NOSTR sub keeps re-querying the relays and paying a signature
  /// verify per event forever (docs/performance.md §3.5).
  void _ensureSubscriptions(List<String> follows) {
    final rns = RnsService.instance;
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
        jsonEncode({'kinds': [1], 'authors': follows, 'limit': _bufferCap}),
      );
    }
    _discoSub ??= rns.nostrDiscovery();
    _fireSub ??= rns.nostrFirehose();
  }

  /// Drain one subscription and fold the NEW events into [buf].
  ///
  /// The expensive part — JSON field extraction, token-stripping regexes and the
  /// base64 thumbnail decode — runs on a background isolate via [compute], as a
  /// BATCH. Never per event: a per-item isolate spawn on a hot path is what
  /// froze the app once already (docs/performance.md §3.1).
  Future<void> _drainInto(String? subId, Map<String, HeroItem> buf) async {
    if (subId == null) return;
    final raws = RnsService.instance.nostrDrain(subId, max: 100);
    if (raws.isNotEmpty) {
      final fresh = [
        for (final j in raws)
          if (!buf.containsKey('$kHeroSourceNostr:${(j['id'] ?? '')}')) j,
      ];
      if (fresh.isNotEmpty) {
        for (final item in await compute(parseHeroBatch, fresh)) {
          buf[item.id] = item;
        }
      }
    }
    if (buf.length <= _bufferCap) return;
    final ordered = buf.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    buf
      ..clear()
      ..addEntries(ordered.take(_bufferCap).map((e) => MapEntry(e.id, e)));
  }

  @override
  Future<List<HeroItem>> candidates() async {
    final rns = RnsService.instance;
    try {
      final follows = rns.follows.asSet.toList()..sort();
      _ensureSubscriptions(follows);
      await _drainInto(_followsSub, _followsBuf);
      await _drainInto(_discoSub, _discoBuf);
      await _drainInto(_fireSub, _fireBuf);

      // Followed: the hero is theirs alone. The ranker enforces that too, but
      // there is no reason to hand it strangers' posts it will only discard.
      if (follows.isNotEmpty) {
        final items = {
          for (final i in _followsBuf.values) i.id: i,
          // Backfill from what we mirrored: a quiet timeline shows their older
          // posts, never a stranger's.
          for (final i in _mirrorBackfill(follows)) i.id: i,
        }.values.toList();
        _noteRung('follows', items.length);
        FollowedMediaCache.instance.ingest(items);
        return _hydrate(items);
      }

      // Nobody followed. Merge everything the device can see, from BOTH
      // transports, and let the ranker choose:
      //   discovery — the internet relays' most-engaged posts (slow to warm:
      //               a post must collect reactions before it qualifies)
      //   firehose  — live kind-1 off the same relays, quality-gated
      //   mesh      — what Reticulum itself relayed to us
      // Discovery alone is what left a new phone staring at an empty banner
      // for minutes: on a fresh install nothing has any likes yet.
      final merged = <String, HeroItem>{};
      for (final i in _discoBuf.values) {
        merged[i.id] = i;
      }
      for (final i in _fireBuf.values) {
        merged.putIfAbsent(i.id, () => i);
      }
      final store = rns.relayStore;
      if (store != null) {
        for (final e in store.firehose(limit: 10)) {
          final item = parseHeroCore(
            id: e.id ?? '',
            pubkey: e.pubkey,
            content: e.content,
            createdAtSec: e.createdAt,
          );
          merged.putIfAbsent(item.id, () => item);
        }
      }
      if (merged.isEmpty) {
        // An empty hero is now SAID, with the numbers that explain it: which
        // buffers were dry, and what the relays' firehose gate did with what
        // it saw. Guessing at this cost a whole build cycle.
        LogService.instance.add(
          'hero: empty (disco=${_discoBuf.length} fire=${_fireBuf.length} '
          'subs=[d:$_discoSub f:$_fireSub] gate=${rns.nostrFirehoseStats})',
        );
        return const [];
      }
      _noteRung(
        'merged(disco=${_discoBuf.length} fire=${_fireBuf.length})',
        merged.length,
      );
      return _hydrate(merged.values.toList());
    } catch (_) {
      return const [];
    }
  }

  /// Followed authors' posts we already hold locally. This is the payoff of the
  /// mirror: the hero has something to show the moment the app opens, before a
  /// single relay has answered, and it never has to reach for a stranger's post
  /// to fill a slot.
  List<HeroItem> _mirrorBackfill(List<String> follows) {
    final store = RnsService.instance.relayStore;
    if (store == null) return const [];
    try {
      return [
        for (final e in store.feedForFollows(follows, limit: _bufferCap))
          parseHeroCore(
            id: e.id ?? '',
            pubkey: e.pubkey,
            content: e.content,
            createdAtSec: e.createdAt,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Log which rung is on screen, once per transition, so an unexpectedly
  /// spammy carousel is traceable to its source.
  void _noteRung(String rung, int size) {
    if (_rung == rung) return;
    _rung = rung;
    LogService.instance.add('hero: source=$rung ($size buffered)');
  }

  /// Main-isolate finishing pass: fill in what only this isolate knows — the
  /// cached kind-0 profile (name/pic) and the engine's like/reply tallies.
  ///
  /// Called for the items we are about to SHOW, never per drained event:
  /// `nostrProfile()` subscribes to the author's kind-0 as a side effect, so
  /// calling it in a loop asks the engine to re-fetch profiles that are never
  /// coming (docs/performance.md §4.2 — "a cosmetic value never deserves a hot
  /// loop").
  List<HeroItem> _hydrate(List<HeroItem> items) {
    final rns = RnsService.instance;
    final ids = [
      for (final i in items)
        if (i.rawEventId.length == 64) i.rawEventId,
    ];
    if (ids.isNotEmpty) rns.nostrTrackStats(ids);
    return [for (final i in items) _hydrateOne(i, rns)];
  }

  HeroItem _hydrateOne(HeroItem i, RnsService rns) {
    final s = i.rawEventId.length == 64
        ? rns.nostrStats(i.rawEventId)
        : (likes: 0, replies: 0, mine: false);
    final pk = i.authorPubkey ?? '';
    final profile = pk.isEmpty
        ? const <String, String>{}
        : rns.nostrProfile(pk);
    final claimed = (profile['name'] ?? '').trim();
    // A kind-0 "name" that is really the note's own text is not a name: keep
    // the short npub instead (HeroItem.looksLikePostText).
    final name = claimed.isNotEmpty &&
            !HeroItem.looksLikePostText(claimed, i.title, i.summary)
        ? claimed
        : i.authorName;
    final pic = (profile['pic'] ?? '').isNotEmpty ? profile['pic'] : i.authorPic;
    // Unchanged items keep their identity, so the carousel doesn't rebuild (and
    // re-decode their images) for nothing.
    if (s.likes == i.likes &&
        s.replies == i.replies &&
        name == i.authorName &&
        pic == i.authorPic) {
      return i;
    }
    return i.copyWith(
      authorName: name,
      authorPic: pic,
      likes: s.likes,
      replies: s.replies,
    );
  }
}

extension on HeroItem {
  /// The bare NOSTR event id, without the `nostr:` source prefix.
  String get rawEventId {
    final at = id.indexOf(':');
    return at < 0 ? id : id.substring(at + 1);
  }
}

// ── Pure parsing (runs on a background isolate via compute) ──────────────────
//
// Everything below touches no service singleton, so a batch of drained events
// can be turned into HeroItems off the UI thread. Author name/pic and the
// like/reply counts are main-isolate state and get filled in by _hydrate.

/// compute() entry point: parse a batch of drained NIP-01 event JSON maps.
List<HeroItem> parseHeroBatch(List<Map<String, dynamic>> raws) {
  final out = <HeroItem>[];
  for (final j in raws) {
    final id = (j['id'] ?? '').toString();
    final pubkey = (j['pubkey'] ?? '').toString();
    if (id.isEmpty || pubkey.isEmpty) continue;
    out.add(parseHeroCore(
      id: id,
      pubkey: pubkey,
      content: (j['content'] ?? '').toString(),
      createdAtSec: (j['created_at'] as int?) ?? 0,
    ));
  }
  return out;
}

/// Build an item from raw event fields — token-stripping, the title/summary
/// split and the inline-thumbnail decode. The author name falls back to a short
/// npub until the profile cache supplies the real one.
HeroItem parseHeroCore({
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
  return HeroItem(
    id: '$kHeroSourceNostr:$id',
    sourceId: kHeroSourceNostr,
    intent: 'social',
    title: title.isEmpty ? 'New post' : title,
    summary: _truncate(rest.trim(), 120),
    thumbnail: _thumbnail(content),
    createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtSec * 1000),
    imageUrl: firstNoteImageUrl(content),
    authorPubkey: pubkey,
    authorName: _shortAuthor(pubkey),
    deepLink: 'post:$id',
    payload: {'id': id, 'pubkey': pubkey, 'content': content, 'created_at': createdAtSec},
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
