/*
 * NostrAllPoller — a CURATED Social "All" feed built with one-shot poll-and-close
 * requests on the MAIN isolate (the nostr-engine isolate freezes reopening a
 * WebSocket, so it cannot own this).
 *
 * The feed is NOT a raw firehose. A raw firehose of the newest posts is useless
 * because seconds-old posts have no likes yet — the feed looks dead. Instead this
 * finds what is actually POPULAR and shows a short, ranked list:
 *
 *   phase 1 — sample recent reactions/reposts (kinds 6,7) and a little fresh
 *             content (kind 1). The reactions point at whatever posts people are
 *             actually engaging with, of any age.
 *   phase 2 — fetch those popular posts by id, plus replies to them.
 *   phase 3 — fetch kind-0 profiles for the authors so names/avatars show
 *             instead of hex keys.
 *   then    — DISCONNECT; verify + gate + score off-thread; keep the top ~20 by
 *             real engagement (likes×3 + replies×4 + reposts×2, with a freshness
 *             nudge); write them, their reactions and their replies into the feed
 *             archive; hand the profiles to the host cache.
 *
 * Off-grid rules: never assume permanent internet or that a busy relay keeps our
 * socket; open briefly, take what is needed, disconnect. Runs every 10 minutes
 * while Social is open, on open, and on pull-to-refresh.
 */
import 'dart:async';
import 'dart:convert';

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
  NostrAllPoller({
    required this.archive,
    required this.onChanged,
    required this.onProfiles,
    required this.onActivity,
  });

  /// The Social "All" archive the feed renders from (dedups by event id).
  final ActivityArchive archive;

  /// Bumped when new curated posts or engagement were written.
  final void Function() onChanged;

  /// Fresh kind-0 profiles: {64-hex pubkey: {name, pic}} for the host to cache so
  /// author names/avatars render instead of hex keys.
  final void Function(Map<String, Map<String, String>>) onProfiles;

  /// Latest engagement time per curated post id (ms) — the newest reaction/reply
  /// timestamp. Lets the feed mark an old post that just gathered activity as
  /// "(updated)" so its high position is explained.
  final void Function(Map<String, int>) onActivity;

  /// True while a poll is in flight — the UI shows "Getting fresh posts…".
  final ValueNotifier<bool> polling = ValueNotifier<bool>(false);

  Timer? _timer;
  bool _busy = false;

  // ── Tuning ────────────────────────────────────────────────────────────────
  /// ~20 curated posts per cycle, as requested.
  static const int _keepPerCycle = 22;

  /// Refresh cadence while Social is open.
  static const Duration _cadence = Duration(minutes: 10);

  /// Reactions/reposts sample window — wide enough that genuinely popular posts
  /// (which take time to gather likes) are found.
  static const int _reactWindowSec = 120 * 60; // 2h
  static const int _reactLimit = 500; // per relay

  /// A little fresh content so brand-new-but-already-liked posts can appear.
  static const int _freshWindowSec = 20 * 60;
  static const int _freshLimit = 150;

  /// How many popular post ids to actually fetch + rank.
  static const int _topPopular = 80;

  static const Duration _collect1 = Duration(seconds: 8); // react + fresh
  static const Duration _collect2 = Duration(seconds: 6); // posts + replies
  static const Duration _collect3 = Duration(seconds: 5); // profiles

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

  /// One curated poll. Concurrency-safe: a poll in flight wins.
  Future<int> pollOnce() async {
    if (_busy) return 0;
    _busy = true;
    polling.value = true;
    final clients = <NostrWsClient>[];

    // Collected, routed by subscription id.
    final reactions = <NostrEvent>[]; // kind 6/7 (sub 'r')
    final fresh = <String, NostrEvent>{}; // kind 1 fresh (sub 'f')
    final popular = <String, NostrEvent>{}; // kind 1 by id (sub 'p')
    final replies = <NostrEvent>[]; // kind 1 #e (sub 'e')
    final profiles = <String, NostrEvent>{}; // kind 0 (sub 'k'), by pubkey

    try {
      final relays = _relays();
      if (relays.isEmpty) return 0;
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      for (final uri in relays) {
        final c = NostrWsClient(uri);
        c.onEvent = (sub, ev) {
          switch (sub) {
            case 'r':
              reactions.add(ev);
            case 'f':
              final id = ev.id;
              if (id != null) fresh[id] = ev;
            case 'p':
              final id = ev.id;
              if (id != null) popular[id] = ev;
            case 'e':
              replies.add(ev);
            case 'k':
              profiles[ev.pubkey] = ev; // newest wins within a poll
          }
        };
        clients.add(c);
        unawaited(
          c.connect().then((_) {
            c.subscribe('r', [
              NostrFilter(
                kinds: const [6, 7],
                since: nowSec - _reactWindowSec,
                limit: _reactLimit,
              ),
            ]);
            c.subscribe('f', [
              NostrFilter(
                kinds: const [1],
                since: nowSec - _freshWindowSec,
                limit: _freshLimit,
              ),
            ]);
          }).catchError((_) {}),
        );
      }
      await Future<void>.delayed(_collect1);

      // Tally reactions/reposts to find the popular posts.
      final likers = <String, Set<String>>{};
      final reposters = <String, Set<String>>{};
      final lastActivity = <String, int>{}; // post id -> newest engagement ms
      void touch(String id, int createdSec) {
        final ms = createdSec * 1000;
        if (ms > (lastActivity[id] ?? 0)) lastActivity[id] = ms;
      }

      for (final ev in reactions) {
        final target = _lastETag(ev);
        if (target == null) continue;
        if (ev.kind == 7) {
          if (ev.content.trim() == '-') continue; // downvote
          (likers[target] ??= <String>{}).add(ev.pubkey);
          touch(target, ev.createdAt);
        } else if (ev.kind == 6) {
          (reposters[target] ??= <String>{}).add(ev.pubkey);
          touch(target, ev.createdAt);
        }
      }
      // Most-liked post ids (also include fresh ids so fresh-but-liked show).
      final popIds =
          (likers.keys.toList()
            ..sort(
              (a, b) => (likers[b]?.length ?? 0).compareTo(likers[a]?.length ?? 0),
            ))
              .take(_topPopular)
              .toList();

      // Phase 2: fetch the popular posts + replies. Phase 3: profiles for every
      // author we might show (fresh authors are known now; popular authors are
      // fetched here and their profiles asked in phase 3).
      if (popIds.isNotEmpty) {
        for (final c in clients) {
          try {
            c.subscribe('p', [NostrFilter(ids: popIds)]);
            c.subscribe('e', [
              NostrFilter(kinds: const [1], tags: {'e': popIds}, limit: 400),
            ]);
          } catch (_) {}
        }
        await Future<void>.delayed(_collect2);
      }

      // Author set for profiles: fresh + popular.
      final authors = <String>{
        for (final e in fresh.values) e.pubkey,
        for (final e in popular.values) e.pubkey,
      };
      if (authors.isNotEmpty) {
        final list = authors.take(150).toList();
        for (final c in clients) {
          try {
            c.subscribe('k', [
              NostrFilter(kinds: const [0], authors: list, limit: list.length),
            ]);
          } catch (_) {}
        }
        await Future<void>.delayed(_collect3);
      }

      // ── Build ────────────────────────────────────────────────────────────
      final muted = RnsService.instance.mutedCallsigns
          .map((c) => c.toLowerCase())
          .toList();

      // Reply counts per post id (distinct reply ids).
      final replyIds = <String, Set<String>>{};
      final replyRows = <Map<String, dynamic>>[];
      for (final ev in replies) {
        final target = _lastETag(ev);
        final id = ev.id;
        if (target == null || id == null) continue;
        if (!popIds.contains(target)) continue;
        (replyIds[target] ??= <String>{}).add(id);
        touch(target, ev.createdAt);
        final row = _replyRow(ev, target);
        if (row != null) replyRows.add(row);
      }

      // Engagement summary for scoring.
      final engagement = <String, Map<String, int>>{};
      for (final id in {...fresh.keys, ...popular.keys}) {
        engagement[id] = {
          'likes': likers[id]?.length ?? 0,
          'replies': replyIds[id]?.length ?? 0,
          'reposts': reposters[id]?.length ?? 0,
        };
      }

      final candidates = <Map<String, dynamic>>[
        for (final e in fresh.values) e.toJson(),
        for (final e in popular.values) e.toJson(),
      ];

      var kept = <Map<String, dynamic>>[];
      if (candidates.isNotEmpty) {
        kept = await compute(_verifyGateScore, {
          'events': candidates,
          'engagement': engagement,
          'muted': muted,
          'keep': _keepPerCycle,
          'nowSec': nowSec,
        });
      }

      // Persist curated posts, their likes and their replies.
      final keptIds = <String>{};
      for (final row in kept) {
        archive.add(row);
        final mid = (row['mid'] ?? '').toString();
        keptIds.add(mid);
        for (final liker in likers[mid] ?? const <String>{}) {
          archive.setReaction(mid, liker.toLowerCase(), true, false);
        }
      }
      for (final r in replyRows) {
        if (keptIds.contains((r['parent'] ?? '').toString())) archive.add(r);
      }

      // Report last-activity for the curated posts, so the feed can mark an old
      // post that just gathered engagement as "(updated)".
      if (keptIds.isNotEmpty) {
        final act = <String, int>{
          for (final id in keptIds)
            if (lastActivity[id] != null) id: lastActivity[id]!,
        };
        if (act.isNotEmpty) onActivity(act);
      }

      // Hand profiles to the host cache (names instead of hex).
      if (profiles.isNotEmpty) {
        final out = <String, Map<String, String>>{};
        for (final ev in profiles.values) {
          final p = _parseProfile(ev.content);
          if (p != null) out[ev.pubkey.toLowerCase()] = p;
        }
        if (out.isNotEmpty) onProfiles(out);
      }

      if (kept.isNotEmpty || replyRows.isNotEmpty || profiles.isNotEmpty) {
        onChanged();
      }
      LogService.instance.add(
        'all-poll: ${reactions.length} reactions, ${fresh.length} fresh, '
        '${popular.length} popular, ${kept.length} curated, '
        '${profiles.length} profiles',
      );
    } catch (e) {
      LogService.instance.add('all-poll: FAILED $e');
    } finally {
      for (final c in clients) {
        for (final s in const ['r', 'f', 'p', 'e', 'k']) {
          try {
            c.unsubscribe(s);
          } catch (_) {}
        }
        unawaited(c.close());
      }
      _busy = false;
      polling.value = false;
    }
    return 0;
  }

  /// Publish a pre-signed event (e.g. a like) via short-lived main-isolate
  /// sockets — the same open/send/close discipline as polling, and the only path
  /// that actually reaches relays (the engine's sockets freeze). Best-effort.
  Future<void> publishEvent(NostrEvent ev) async {
    final relays = _relays();
    if (relays.isEmpty) return;
    final clients = <NostrWsClient>[];
    try {
      for (final uri in relays) {
        final c = NostrWsClient(uri);
        clients.add(c);
        unawaited(
          c.connect().then((_) => c.publish(ev)).catchError((_) => false),
        );
      }
      await Future<void>.delayed(const Duration(seconds: 5));
    } finally {
      for (final c in clients) {
        unawaited(c.close());
      }
    }
    LogService.instance.add('all-poll: published kind-${ev.kind}');
  }

  /// The last 'e' tag of an event (NIP-25: the reacted-to event id).
  String? _lastETag(NostrEvent ev) {
    String? id;
    for (final t in ev.tags) {
      if (t.isNotEmpty && t[0] == 'e' && t.length > 1) id = t[1];
    }
    return id;
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

  /// Extract {name, pic} from a kind-0 content JSON, if any.
  Map<String, String>? _parseProfile(String content) {
    try {
      final m = jsonDecodeSafe(content);
      if (m == null) return null;
      final name = (m['display_name'] ?? m['displayName'] ?? m['name'] ?? '')
          .toString()
          .trim();
      final pic = (m['picture'] ?? '').toString().trim();
      if (name.isEmpty && pic.isEmpty) return null;
      return {if (name.isNotEmpty) 'name': name, if (pic.isNotEmpty) 'pic': pic};
    } catch (_) {
      return null;
    }
  }

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

Map<String, dynamic>? jsonDecodeSafe(String s) {
  try {
    final v = jsonDecode(s);
    return v is Map ? v.map((k, val) => MapEntry(k.toString(), val)) : null;
  } catch (_) {
    return null;
  }
}

/// Verify signatures, gate spam, score by real engagement, keep the top N.
/// Runs in a `compute` isolate. Input:
/// `{events, engagement:{id:{likes,replies,reposts}}, muted, keep, nowSec}`.
List<Map<String, dynamic>> _verifyGateScore(Map<String, dynamic> arg) {
  final events = (arg['events'] as List).cast<Map<String, dynamic>>();
  final engagement = (arg['engagement'] as Map).map(
    (k, v) => MapEntry(k.toString(), (v as Map).map((a, b) => MapEntry(a.toString(), (b as num).toInt()))),
  );
  final muted = (arg['muted'] as List).map((e) => e.toString()).toSet();
  final keep = (arg['keep'] as num).toInt();
  final nowSec = (arg['nowSec'] as num).toInt();

  final seen = <String>{};
  final scored = <({Map<String, dynamic> row, double s})>[];
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
    if (contentVerdict(content) is! FeedKeep) continue;
    if (_looksMachineJunk(content)) continue;
    final pub = ev.pubkey.toLowerCase();
    if (pub.isEmpty) continue;
    if (muted.contains(pub) ||
        (pub.length >= 12 && muted.contains(pub.substring(0, 12)))) {
      continue;
    }
    final id = ev.id ?? '';
    if (id.isEmpty || !seen.add(id)) continue;
    if (!ev.verify()) continue;

    final eng = engagement[id] ?? const {};
    final likes = eng['likes'] ?? 0;
    final replies = eng['replies'] ?? 0;
    final reposts = eng['reposts'] ?? 0;
    final ageMin = (nowSec - ev.createdAt) / 60.0;
    // Engagement dominates; freshness only nudges among similar posts.
    final score =
        likes * 3.0 + replies * 4.0 + reposts * 2.0 + (ageMin < 60 ? 3 : 0);

    var parent = '';
    for (final t in ev.tags) {
      if (t.isNotEmpty && t[0] == 'e' && t.length > 1) {
        parent = t[1];
        break;
      }
    }
    if (parent.isNotEmpty) continue; // roots only in the curated list
    final dt = DateTime.fromMillisecondsSinceEpoch(ev.createdAt * 1000);
    final hhmm =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    scored.add((
      row: <String, dynamic>{
        'dir': 'in',
        'from': pub.length >= 12 ? pub.substring(0, 12) : pub,
        'author': pub,
        'text': content,
        'mid': id,
        'parent': '',
        'pop': likes >= 2 ? 1 : 0,
        'source': 'firehose',
        't': ev.createdAt * 1000,
        'time': hhmm,
      },
      s: score,
    ));
  }
  scored.sort((a, b) => b.s.compareTo(a.s)); // most engaging first
  return [for (final e in scored.take(keep)) e.row];
}

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
