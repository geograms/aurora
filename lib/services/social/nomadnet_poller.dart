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
  int _lastSeenSec = 0;
  final Set<String> _knownAuthors = {};

  /// Reticulum queries are slow (~40s worst case, run in parallel), so poll
  /// gently while the tab is open.
  static const Duration _cadence = Duration(seconds: 90);
  static const int _coldWindowSec = 6 * 60 * 60; // first poll looks back 6h

  void start() {
    if (_disposed) return;
    stop();
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
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final since =
          _lastSeenSec > 0 ? _lastSeenSec - 60 : nowSec - _coldWindowSec;
      final events = await RnsService.instance.nomadnetFetch(since);
      if (_disposed) return 0;
      if (events.isEmpty) {
        LogService.instance.add('nomadnet-poll: 0 fetched (since ${nowSec - since}s)');
        return 0;
      }

      // Verify signatures + build rows off the UI thread (secp256k1 is heavy).
      final rows = await compute(_verifyBuild, events);
      if (_disposed) return 0;

      var added = 0;
      final newAuthors = <String>[];
      archive.transact(() {
        for (final row in rows) {
          archive.add(row);
          added++;
          final sec = ((row['t'] as int?) ?? 0) ~/ 1000;
          if (sec > _lastSeenSec) _lastSeenSec = sec;
          final author = (row['author'] ?? '').toString();
          if (author.isNotEmpty && _knownAuthors.add(author)) {
            newAuthors.add(author);
          }
        }
      });
      if (added > 0 && !_disposed) onChanged();

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
        'nomadnet-poll: fetched ${events.length}, kept $added, '
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

/// compute() isolate: verify signatures, drop non-kind-1/empty/forged, build
/// archive rows. NO curation — every valid kind-1 note is kept.
List<Map<String, dynamic>> _verifyBuild(List<Map<String, dynamic>> events) {
  final out = <Map<String, dynamic>>[];
  final seen = <String>{};
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
    final id = ev.id ?? '';
    if (id.isEmpty || !seen.add(id)) continue;
    if (!ev.verify()) continue; // forged → drop
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
    out.add(<String, dynamic>{
      'dir': 'in',
      'from': pub.length >= 12 ? pub.substring(0, 12) : pub,
      'author': pub,
      'text': content,
      'mid': id,
      'parent': parent,
      'pop': 0,
      'source': 'nomadnet',
      't': created * 1000,
      'time': hhmm,
    });
  }
  return out;
}
