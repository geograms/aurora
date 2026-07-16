/*
 * NomadnetPoller — the Social "Nomadnet" feed: fresh NOSTR publications pulled
 * from the RETICULUM mesh (indexers + callsign peers across the hubs) AND this
 * device's own local relay store. UNCURATED — just signature-verified,
 * newest-first.
 *
 * All I/O is main-isolate RNS Links via RnsService (NO WebSocket, so none of the
 * engine-isolate socket freeze applies). Runs ONLY while the Nomadnet tab is
 * being viewed (start/stop driven by the tab selection) to save battery. Because
 * it is started/stopped repeatedly, a `_disposed` guard prevents an in-flight
 * poll from writing to a disposed archive or calling back after teardown.
 */
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:reticulum/reticulum.dart' show NostrEvent;

import '../log_service.dart';
import '../reticulum/rns_service.dart';
import '../../wapp/geoui/activity_archive.dart';

class NomadnetPoller {
  NomadnetPoller({
    required this.archive,
    required this.onChanged,
    required this.onProfiles,
  });

  /// The Nomadnet archive (its OWN sqlite: social_nomadnet.sqlite3).
  final ActivityArchive archive;

  /// Bumped when new posts were written.
  final void Function() onChanged;

  /// Fresh kind-0 profiles {pubkeyHex: {name, pic}} for the host cache.
  final void Function(Map<String, Map<String, String>>) onProfiles;

  Timer? _timer;
  bool _busy = false;
  bool _disposed = false;
  final Set<String> _knownAuthors = {};

  /// Reticulum queries are slow (~40s worst case, run in parallel), so poll
  /// gently while the tab is open. The main path is now the push trigger
  /// (RnsService.onNomadnetInbound) — this pull is the incremental backstop.
  static const Duration _cadence = Duration(seconds: 90);

  void start() {
    if (_disposed) return;
    stop();
    // Announce ourselves so a peer adds us to its indexer directory within
    // seconds (both directions of fan-out + our REQ pull), then pull now.
    RnsService.instance.announceRelayNow();
    unawaited(pollOnce());
    _timer = Timer.periodic(_cadence, (_) => unawaited(pollOnce()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _disposed = true;
    stop();
  }

  Future<int> pollOnce() async {
    if (_busy || _disposed) return 0;
    _busy = true;
    try {
      // Per-target incremental pull: each indexer is asked only for what is new
      // since our last contact with it (persisted cursor in RnsService).
      final events = await RnsService.instance.nomadnetPull();
      if (_disposed) return 0;
      if (events.isEmpty) return 0;

      // Verify signatures + split kind-1 posts vs kind-6/7 reactions off the UI
      // thread (secp256k1 is heavy).
      final result = await compute(_verifyPull, events);
      if (_disposed) return 0;
      final rows =
          (result['rows'] as List).cast<Map<String, dynamic>>();
      final reactions =
          (result['reactions'] as List).cast<Map<String, dynamic>>();
      final self = RnsService.instance.nostrSelfHex()?.toLowerCase();

      var added = 0;
      final newAuthors = <String>[];
      archive.transact(() {
        for (final row in rows) {
          archive.add(row);
          added++;
          final author = (row['author'] ?? '').toString();
          if (author.isNotEmpty && _knownAuthors.add(author)) {
            newAuthors.add(author);
          }
        }
        // Apply reactions so like counts propagate over the mesh with the posts.
        for (final rx in reactions) {
          final mid = (rx['mid'] ?? '').toString();
          final liker = (rx['liker'] ?? '').toString();
          if (mid.isEmpty || liker.isEmpty) continue;
          archive.setReaction(
            mid,
            liker,
            rx['like'] == true,
            self != null && liker == self,
          );
        }
      });
      if ((added > 0 || reactions.isNotEmpty) && !_disposed) onChanged();

      // Resolve names/avatars for authors we have not seen before.
      var gotProfiles = 0;
      if (newAuthors.isNotEmpty && !_disposed) {
        try {
          final profs = await RnsService.instance.nomadnetProfiles(
            newAuthors.take(60).toList(),
          );
          if (_disposed) return added;
          final out = <String, Map<String, String>>{};
          for (final j in profs) {
            final pub = (j['pubkey'] ?? '').toString().toLowerCase();
            final p = _parseProfile((j['content'] ?? '').toString());
            if (pub.isNotEmpty && p != null) out[pub] = p;
          }
          gotProfiles = out.length;
          if (out.isNotEmpty && !_disposed) onProfiles(out);
        } catch (_) {}
      }

      LogService.instance.add(
        'nomadnet-poll: kept $added post(s), ${reactions.length} reaction(s), '
        'profiles $gotProfiles',
      );
      return added;
    } catch (e) {
      LogService.instance.add('nomadnet-poll: FAILED $e');
      return 0;
    } finally {
      _busy = false;
    }
  }

  /// Apply a single event pushed to us by a peer indexer (RnsService.
  /// onNomadnetInbound) — the live push path. Runs on the main isolate; the
  /// event is already signature-verified by the relay before storage.
  void ingestPushed(Map<String, dynamic> json) {
    if (_disposed) return;
    try {
      final ev = NostrEvent.fromJson(json);
      final self = RnsService.instance.nostrSelfHex()?.toLowerCase();
      if (ev.kind == 1) {
        if (ev.content.trim().isEmpty || (ev.id ?? '').isEmpty) return;
        archive.add(nomadnetRow(ev));
        onChanged();
      } else if (ev.kind == 7 || ev.kind == 6) {
        final r = _reactionOf(ev);
        if (r == null) return;
        final liker = (r['liker'] ?? '').toString();
        archive.setReaction(
          (r['mid'] ?? '').toString(),
          liker,
          r['like'] == true,
          self != null && liker == self,
        );
        onChanged();
      }
    } catch (_) {}
  }

  Map<String, String>? _parseProfile(String content) {
    try {
      final v = jsonDecode(content);
      if (v is! Map) return null;
      final name = (v['display_name'] ?? v['displayName'] ?? v['name'] ?? '')
          .toString()
          .trim();
      final pic = (v['picture'] ?? '').toString().trim();
      if (name.isEmpty && pic.isEmpty) return null;
      return {if (name.isNotEmpty) 'name': name, if (pic.isNotEmpty) 'pic': pic};
    } catch (_) {
      return null;
    }
  }
}

/// compute() isolate: verify signatures, split kind-1 posts (→ archive rows)
/// from kind-6/7 reactions (→ {mid, liker, like}). NO curation. Returns
/// `{'rows': [...], 'reactions': [...]}`.
Map<String, dynamic> _verifyPull(List<Map<String, dynamic>> events) {
  final rows = <Map<String, dynamic>>[];
  final reactions = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final j in events) {
    final NostrEvent ev;
    try {
      ev = NostrEvent.fromJson(j);
    } catch (_) {
      continue;
    }
    final id = ev.id ?? '';
    if (id.isEmpty || !seen.add(id)) continue;
    if (!ev.verify()) continue; // forged → drop
    if (ev.kind == 1) {
      if (ev.content.trim().isEmpty) continue;
      rows.add(nomadnetRow(ev));
    } else if (ev.kind == 7 || ev.kind == 6) {
      final r = _reactionOf(ev);
      if (r != null) reactions.add(r);
    }
  }
  return {'rows': rows, 'reactions': reactions};
}

/// Extract {mid (the liked post id, from the #e tag), liker (pubkey), like}
/// from a kind-7 reaction or kind-6 repost, or null if it has no target.
Map<String, dynamic>? _reactionOf(NostrEvent ev) {
  String mid = '';
  for (final t in ev.tags) {
    if (t.length >= 2 && t[0] == 'e') {
      mid = t[1];
      break;
    }
  }
  if (mid.isEmpty) return null;
  final c = ev.content.trim();
  // kind-6 repost, or kind-7 positive ('+'/'❤️'/emoji) counts as a like; '-' is
  // a downvote.
  final like = ev.kind == 6 || c != '-';
  return {'mid': mid, 'liker': ev.pubkey.toLowerCase(), 'like': like};
}

/// Build a Nomadnet archive row from a kind-1 event. Shared by the poll path
/// (after signature verification) and the instant local-echo of our OWN just-
/// published note (no verify needed — we just signed it), so the author sees
/// their post the moment it lands in the relay store, with the REAL event id as
/// `mid` so the later poll dedups against it instead of duplicating.
Map<String, dynamic> nomadnetRow(NostrEvent ev) {
  final pub = ev.pubkey.toLowerCase();
  // Reply parent: aurora uses a 'parent' tag; standard NOSTR uses 'e'.
  var parent = '';
  for (final t in ev.tags) {
    if (t.length >= 2 && t[0] == 'parent') {
      parent = t[1];
      break;
    }
  }
  if (parent.isEmpty) {
    for (final t in ev.tags) {
      if (t.length >= 2 && t[0] == 'e') {
        parent = t[1];
        break;
      }
    }
  }
  final created = ev.createdAt;
  final dt = DateTime.fromMillisecondsSinceEpoch(created * 1000);
  final hhmm =
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  return <String, dynamic>{
    'dir': 'in',
    'from': pub.length >= 12 ? pub.substring(0, 12) : pub,
    'author': pub,
    'text': ev.content.trim(),
    'mid': ev.id ?? '',
    'parent': parent,
    'pop': 0,
    'source': 'nomadnet',
    't': created * 1000,
    'time': hhmm,
  };
}

/// Build a Nomadnet row from raw event JSON (our own freshly-signed kind-1),
/// or null if it is not a usable kind-1 note. Used by the publish→archive echo.
Map<String, dynamic>? nomadnetRowFromJson(Map<String, dynamic> json) {
  try {
    final ev = NostrEvent.fromJson(json);
    if (ev.kind != 1) return null;
    if (ev.content.trim().isEmpty) return null;
    if ((ev.id ?? '').isEmpty) return null;
    return nomadnetRow(ev);
  } catch (_) {
    return null;
  }
}
