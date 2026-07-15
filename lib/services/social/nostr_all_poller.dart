/*
 * NostrAllPoller — the Social "All" firehose as a ONE-SHOT poll-and-close on the
 * MAIN isolate. This is how modern NOSTR clients work, and the model the app
 * must use off-grid.
 *
 * Hard rules (learned the hard way on real hardware):
 *   - Never assume permanent internet, and never assume a busy public relay will
 *     let our socket linger — they cut idle clients constantly.
 *   - So open a socket only as briefly as it takes to pull what is new, then
 *     DISCONNECT. No persistent firehose sockets.
 *
 * Why the main isolate: the nostr-engine isolate FREEZES whenever it tries to
 * (re)open a WebSocket on this hardware, so the moment the relays cut its
 * persistent sockets the whole feed died and could not recover. The main isolate
 * opens WebSockets reliably, so the poll lives here. Signature verification and
 * the spam gate run in a throwaway `compute` isolate (pure Dart, no sockets, so
 * none of the engine-isolate freeze applies).
 *
 * Each poll, on ONE set of short-lived sockets:
 *   phase 1 — REQ kind-1 since the last window; collect a few seconds; gate +
 *             verify off-thread; write survivors into the feed archive.
 *   phase 2 — REQ reactions/replies (#e) for the recently-shown posts; count
 *             them into the archive so likes/reply badges fill in and keep
 *             growing as fresh posts gather engagement.
 * Then DISCONNECT. Runs on a timer while Social is open, on open, and on
 * pull-to-refresh.
 */
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:reticulum/reticulum.dart'
    show
        NostrWsClient,
        NostrEvent,
        NostrFilter,
        FeedKeep,
        contentVerdict,
        kDefaultNostrRelays;

import '../log_service.dart';
import '../reticulum/rns_service.dart';
import '../../wapp/geoui/activity_archive.dart';

class NostrAllPoller {
  NostrAllPoller({required this.archive, required this.onChanged});

  /// The Social "All" archive the feed renders from. Survivors are written here;
  /// it dedups by event id, so re-fetching the same post is a no-op.
  final ActivityArchive archive;

  /// Bumped when new posts (or new engagement) were written, so the feed
  /// rebuilds.
  final void Function() onChanged;

  /// True while a poll is in flight — the UI shows "Getting fresh posts…".
  final ValueNotifier<bool> polling = ValueNotifier<bool>(false);

  Timer? _timer;
  bool _busy = false;

  /// Newest created_at (unix seconds) we have already written, so the next poll
  /// asks only for what is newer — a cheap window, not the whole backlog.
  int _newestSec = 0;

  /// How long phase 1 (posts) holds the sockets. Brief on purpose.
  static const Duration _collectPosts = Duration(seconds: 6);

  /// How long phase 2 (reactions/replies) holds them.
  static const Duration _collectStats = Duration(seconds: 4);

  /// How far back the FIRST poll of a session looks (later polls use [_newestSec]).
  static const Duration _coldWindow = Duration(minutes: 30);

  /// Cadence while Social is open. Fresh short-lived client each time.
  static const Duration _cadence = Duration(minutes: 3);

  /// Fetch engagement for at most this many recently-shown posts per poll (relay
  /// filters cannot be unbounded, and this is enough to keep the visible feed's
  /// badges current).
  static const int _statsFanout = 60;

  bool get isPolling => _busy;

  void start() {
    stop();
    unawaited(pollOnce());
    _timer = Timer.periodic(_cadence, (_) => unawaited(pollOnce()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    stop();
    polling.dispose();
  }

  /// Fetch what is new + refresh engagement, then disconnect. Concurrency-safe:
  /// a poll already in flight wins and a second caller is a no-op (returns 0).
  Future<int> pollOnce() async {
    if (_busy) return 0;
    _busy = true;
    polling.value = true;
    final clients = <NostrWsClient>[];
    final posts = <String, NostrEvent>{};
    final stats = <NostrEvent>[];
    try {
      final relays = _relays();
      if (relays.isEmpty) return 0;
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final since = _newestSec > 0
          ? (_newestSec - 60) // small overlap for relay clock skew
          : (nowSec - _coldWindow.inSeconds);

      // Route events by subscription id: 'p' = new posts, 's' = engagement.
      for (final uri in relays) {
        final c = NostrWsClient(uri);
        c.onEvent = (sub, ev) {
          if (sub == 'p') {
            final id = ev.id;
            if (id != null) posts[id] = ev;
          } else if (sub == 's') {
            stats.add(ev);
          }
        };
        clients.add(c);
        // Fire the connect; don't await the handshake serially — the collect
        // window is the wait, and a dead relay must not hold up the others.
        unawaited(
          c
              .connect()
              .then((_) => c.subscribe('p', [
                    NostrFilter(kinds: const [1], since: since, limit: 300),
                  ]))
              .catchError((_) {}),
        );
      }
      await Future<void>.delayed(_collectPosts);

      // Gate + verify the posts off-thread, then persist. Do this while the
      // sockets are still open so phase 2 can reuse them.
      final muted = RnsService.instance.mutedCallsigns
          .map((c) => c.toLowerCase())
          .toList();
      var added = 0;
      if (posts.isNotEmpty) {
        final raw = [for (final e in posts.values) e.toJson()];
        final rows = await compute(
          _verifyGateBuild,
          {'events': raw, 'muted': muted},
        );
        for (final row in rows) {
          archive.add(row);
          final sec = ((row['t'] as int?) ?? 0) ~/ 1000;
          if (sec > _newestSec) _newestSec = sec;
          added++;
        }
        if (added > 0) onChanged();
      }

      // Phase 2: refresh engagement for the posts on screen. Ask every relay for
      // reactions (7), reposts (6) and replies (1) that reference them.
      final ids = _recentPostIds();
      if (ids.isNotEmpty) {
        final statsFilter = NostrFilter(
          kinds: const [1, 6, 7],
          tags: {'e': ids},
          limit: 500,
        );
        for (final c in clients) {
          try {
            c.subscribe('s', [statsFilter]);
          } catch (_) {}
        }
        await Future<void>.delayed(_collectStats);
      }

      LogService.instance.add(
        'all-poll: ${posts.length} fetched, $added kept, '
        '${stats.length} engagement '
        '(newest ${_newestSec == 0 ? "-" : "${nowAgeSec()}s"} ago)',
      );
    } catch (e) {
      LogService.instance.add('all-poll: FAILED $e');
    } finally {
      // ALWAYS let the sockets go — the whole point. close() (not just
      // disconnect) marks the client done so it never tries to reconnect.
      for (final c in clients) {
        try {
          c.unsubscribe('p');
        } catch (_) {}
        try {
          c.unsubscribe('s');
        } catch (_) {}
        unawaited(c.close());
      }
      _busy = false;
      polling.value = false;
    }

    // Fold engagement into the archive (off the sockets, on main — cheap: no
    // crypto, just counting). Reaction verification is not worth ~100ms a
    // signature for a like badge on a stranger's post.
    if (stats.isNotEmpty) {
      final known = _recentPostIdSet();
      var changed = false;
      for (final ev in stats) {
        final target = _referencedEventId(ev, known);
        if (target == null) continue;
        if (ev.kind == 7) {
          // A reaction. '-' is a downvote; everything else counts as a like.
          final positive = ev.content.trim() != '-';
          if (positive) {
            archive.setReaction(target, ev.pubkey.toLowerCase(), true, false);
            changed = true;
          }
        } else if (ev.kind == 1) {
          // A reply — store it (parent set) so replyCount(target) sees it. It is
          // filtered out of the top-level All list (roots only) by the feed.
          final row = _replyRow(ev, target);
          if (row != null) {
            archive.add(row);
            changed = true;
          }
        }
        // kind 6 (repost) is collected but not yet surfaced as a badge.
      }
      if (changed) onChanged();
    }

    return 0;
  }

  int nowAgeSec() => _newestSec == 0
      ? -1
      : (DateTime.now().millisecondsSinceEpoch ~/ 1000) - _newestSec;

  /// The most-recent post ids currently in the feed, for the engagement query.
  List<String> _recentPostIds() {
    final out = <String>[];
    for (final r in archive.recent(limit: _statsFanout)) {
      final mid = (r['mid'] ?? '').toString();
      final parent = (r['parent'] ?? '').toString();
      if (mid.length == 64 && parent.isEmpty) out.add(mid); // roots only
    }
    return out;
  }

  Set<String> _recentPostIdSet() => _recentPostIds().toSet();

  /// The event id this reaction/reply is about, if it targets one of [known].
  /// For NIP-25 reactions the last 'e' tag is the reacted-to event; for replies
  /// any referenced 'e' that we know about is good enough for a count.
  String? _referencedEventId(NostrEvent ev, Set<String> known) {
    String? last;
    for (final t in ev.tags) {
      if (t.isNotEmpty && t[0] == 'e' && t.length > 1) {
        final id = t[1];
        if (known.contains(id)) last = id;
      }
    }
    return last;
  }

  Map<String, dynamic>? _replyRow(NostrEvent ev, String parent) {
    final content = ev.content.trim();
    if (content.isEmpty) return null;
    final id = ev.id ?? '';
    if (id.isEmpty) return null;
    final pub = ev.pubkey.toLowerCase();
    final created = ev.createdAt;
    final dt = DateTime.fromMillisecondsSinceEpoch(created * 1000);
    final hhmm =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return <String, dynamic>{
      'dir': 'in',
      'from': pub.length >= 12 ? pub.substring(0, 12) : pub,
      'author': pub,
      'text': content,
      'mid': id,
      'parent': parent,
      'pop': 0,
      'source': 'thread',
      't': created * 1000,
      'time': hhmm,
    };
  }

  /// Enabled wss relays the user configured, falling back to the well-known
  /// public set. Read via the host's main-side cache (never the possibly-frozen
  /// engine's sockets).
  List<String> _relays() {
    final list = <String>[];
    try {
      for (final r in RnsService.instance.nostrRelays()) {
        final uri = (r['uri'] ?? '').toString();
        final enabled = r['enabled'] != false;
        if (enabled && (uri.startsWith('wss://') || uri.startsWith('ws://'))) {
          list.add(uri);
        }
      }
    } catch (_) {}
    if (list.isEmpty) {
      list.addAll(kDefaultNostrRelays.where((u) => u.startsWith('ws')));
    }
    return list;
  }
}

/// Top-level so it can run in a `compute` isolate. Verify each event's Schnorr
/// signature, drop spam/muted/machine-junk, de-flood per author, and build feed
/// rows. Input: `{'events': [nip01 json...], 'muted': [lowercased pubkeys]}`.
List<Map<String, dynamic>> _verifyGateBuild(Map<String, dynamic> arg) {
  final events = (arg['events'] as List).cast<Map<String, dynamic>>();
  final muted = (arg['muted'] as List).map((e) => e.toString()).toSet();

  final kept = <_Cand>[];
  for (final j in events) {
    final NostrEvent ev;
    try {
      ev = NostrEvent.fromJson(j);
    } catch (_) {
      continue;
    }
    if (ev.kind != 1) continue;
    final content = ev.content.trim();
    if (content.isEmpty) continue;
    if (contentVerdict(content) is! FeedKeep) continue; // spam gate
    if (_looksMachineJunk(content)) continue; // encoded-blob flood
    final pub = ev.pubkey.toLowerCase();
    if (pub.isEmpty) continue;
    if (muted.contains(pub) ||
        (pub.length >= 12 && muted.contains(pub.substring(0, 12)))) {
      continue;
    }
    final id = ev.id ?? '';
    if (id.isEmpty) continue;
    if (!ev.verify()) continue; // forged signature → drop
    kept.add(_Cand(ev, content, pub, id));
  }

  // Newest first, then cap per author so no single flooder dominates.
  kept.sort((a, b) => b.ev.createdAt.compareTo(a.ev.createdAt));
  const perAuthorCap = 2;
  final perAuthor = <String, int>{};
  final out = <Map<String, dynamic>>[];
  for (final c in kept) {
    final n = perAuthor[c.pub] ?? 0;
    if (n >= perAuthorCap) continue;
    perAuthor[c.pub] = n + 1;
    var parent = '';
    for (final t in c.ev.tags) {
      if (t.isNotEmpty && t[0] == 'e' && t.length > 1) {
        parent = t[1];
        break;
      }
    }
    final created = c.ev.createdAt;
    final dt = DateTime.fromMillisecondsSinceEpoch(created * 1000);
    final hhmm =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    out.add(<String, dynamic>{
      'dir': 'in',
      'from': c.pub.length >= 12 ? c.pub.substring(0, 12) : c.pub,
      'author': c.pub,
      'text': c.content,
      'mid': c.id,
      'parent': parent,
      'pop': 0,
      'source': 'firehose',
      't': created * 1000,
      'time': hhmm,
    });
  }
  return out;
}

class _Cand {
  _Cand(this.ev, this.content, this.pub, this.id);
  final NostrEvent ev;
  final String content;
  final String pub;
  final String id;
}

/// A post that is really a machine payload, not prose — long unbroken
/// base32/base58-looking runs, or a bare `token.token.host` blob. Conservative
/// so real posts with a link or an address are not caught.
bool _looksMachineJunk(String content) {
  final s = content.trim();
  if (s.contains(' ')) {
    final longest = s
        .split(RegExp(r'\s+'))
        .fold<int>(0, (m, w) => w.length > m ? w.length : m);
    return longest >= 60 && longest > s.length * 0.6;
  }
  if (s.length < 40) return false;
  final alnum = RegExp(r'[A-Za-z0-9]').allMatches(s).length;
  final upperDigit = RegExp(r'[A-Z0-9]').allMatches(s).length;
  return alnum > 0 && upperDigit >= alnum * 0.5;
}
