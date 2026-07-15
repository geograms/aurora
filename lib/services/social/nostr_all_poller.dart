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
 * Flow, each poll: connect every relay → REQ kind-1 since the last window →
 * collect for a few seconds → DISCONNECT all → verify + gate off-thread → write
 * the survivors into the feed archive. Runs on a timer while Social is open, on
 * open, and on pull-to-refresh.
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

  /// Bumped when new posts were written, so the feed rebuilds.
  final void Function() onChanged;

  Timer? _timer;
  bool _polling = false;

  /// Newest created_at (unix seconds) we have already written, so the next poll
  /// asks only for what is newer — a cheap window, not the whole backlog.
  int _newestSec = 0;

  /// How long a single poll holds its sockets open. Brief on purpose.
  static const Duration _collect = Duration(seconds: 7);

  /// How far back the FIRST poll of a session looks (later polls use [_newestSec]).
  static const Duration _coldWindow = Duration(minutes: 30);

  /// Cadence while Social is open. The relays get a fresh, short-lived client
  /// each time, never a lingering one.
  static const Duration _cadence = Duration(minutes: 3);

  bool get isPolling => _polling;

  void start() {
    stop();
    unawaited(pollOnce());
    _timer = Timer.periodic(_cadence, (_) => unawaited(pollOnce()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Fetch what is new, add it, disconnect. Concurrency-safe: a poll already in
  /// flight wins and a second caller is a no-op (returns 0).
  Future<int> pollOnce() async {
    if (_polling) return 0;
    _polling = true;
    final clients = <NostrWsClient>[];
    final collected = <String, NostrEvent>{};
    try {
      final relays = _relays();
      if (relays.isEmpty) return 0;
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final since = _newestSec > 0
          ? (_newestSec - 60) // small overlap for relay clock skew
          : (nowSec - _coldWindow.inSeconds);
      final filter = NostrFilter(kinds: const [1], since: since, limit: 300);

      for (final uri in relays) {
        final c = NostrWsClient(uri);
        c.onEvent = (sub, ev) {
          final id = ev.id;
          if (id != null) collected[id] = ev;
        };
        clients.add(c);
        // Fire the connect; don't await the handshake serially — the collect
        // window is the wait, and a relay that never answers must not hold up
        // the others. subscribe() replays once the socket is up.
        unawaited(
          c.connect().then((_) => c.subscribe('all', [filter])).catchError(
            (_) {},
          ),
        );
      }
      await Future<void>.delayed(_collect);
    } catch (e) {
      LogService.instance.add('all-poll: FAILED $e');
    } finally {
      // ALWAYS let the sockets go — the whole point. close() (not just
      // disconnect) marks the client done so it never tries to reconnect.
      for (final c in clients) {
        try {
          c.unsubscribe('all');
        } catch (_) {}
        unawaited(c.close());
      }
      _polling = false;
    }

    if (collected.isEmpty) {
      LogService.instance.add('all-poll: 0 events this window');
      return 0;
    }

    // Verify + gate off the UI thread. Pure Dart, no sockets — safe in a
    // throwaway isolate, and it keeps ~100ms-a-signature Schnorr off the frame.
    final raw = [for (final e in collected.values) e.toJson()];
    final muted = RnsService.instance.mutedCallsigns
        .map((c) => c.toLowerCase())
        .toList();
    List<Map<String, dynamic>> rows;
    try {
      rows = await compute(_verifyGateBuild, {'events': raw, 'muted': muted});
    } catch (e) {
      LogService.instance.add('all-poll: gate FAILED $e');
      return 0;
    }

    var added = 0;
    for (final row in rows) {
      archive.add(row);
      final sec = ((row['t'] as int?) ?? 0) ~/ 1000;
      if (sec > _newestSec) _newestSec = sec;
      added++;
    }
    if (added > 0) onChanged();
    LogService.instance.add(
      'all-poll: ${collected.length} fetched, $added kept '
      '(newest ${_newestSec == 0 ? "-" : "${nowAgeSec()}s"} ago)',
    );
    return added;
  }

  int nowAgeSec() =>
      _newestSec == 0 ? -1 : (DateTime.now().millisecondsSinceEpoch ~/ 1000) - _newestSec;

  /// Enabled wss relays the user configured, falling back to the well-known
  /// public set. Read via the host (never the possibly-frozen engine's sockets).
  List<String> _relays() {
    final list = <String>[];
    try {
      // Main-side cached copy of the relay list — safe even if the engine
      // isolate is wedged; never a proxy call that could hang on it.
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
/// signature, drop spam/muted, and build feed-archive rows. Input:
/// `{'events': [nip01 json...], 'muted': [lowercased pubkey prefixes]}`.
List<Map<String, dynamic>> _verifyGateBuild(Map<String, dynamic> arg) {
  final events = (arg['events'] as List).cast<Map<String, dynamic>>();
  final muted = (arg['muted'] as List).map((e) => e.toString()).toSet();

  // First pass: parse, gate, verify. Collect survivors so a second pass can
  // rank and de-flood across the whole batch (a single author firehosing
  // encoded junk otherwise buries every real post — the "sp_…drift.gits.net"
  // flood seen on-device).
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

  // Newest first, then cap per author so no single flooder dominates. A cap of
  // 2 keeps a prolific-but-real account visible without letting a bot take over.
  kept.sort((a, b) => b.ev.createdAt.compareTo(a.ev.createdAt));
  const perAuthorCap = 2;
  final perAuthor = <String, int>{};
  final out = <Map<String, dynamic>>[];
  for (final c in kept) {
    final n = (perAuthor[c.pub] ?? 0);
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
/// base32/base58-looking runs, or a bare `token.token.token.host` blob. These
/// are what one flooding account was pumping into the firehose. Keep it
/// conservative so real posts with a link or an address are not caught.
bool _looksMachineJunk(String content) {
  final s = content.trim();
  if (s.contains(' ')) {
    // Has whitespace → looks like prose unless it is almost all one giant token.
    final longest = s
        .split(RegExp(r'\s+'))
        .fold<int>(0, (m, w) => w.length > m ? w.length : m);
    return longest >= 60 && longest > s.length * 0.6;
  }
  // No spaces at all: a single token. Junk if it is long and high-entropy
  // (lots of uppercase+digits), e.g. "sp_….UVY5CWLHUCYNUD…drift.gits.net".
  if (s.length < 40) return false;
  final alnum = RegExp(r'[A-Za-z0-9]').allMatches(s).length;
  final upperDigit = RegExp(r'[A-Z0-9]').allMatches(s).length;
  return alnum > 0 && upperDigit >= alnum * 0.5;
}
