import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:reticulum/reticulum.dart';
import 'package:reticulum/src/services/files/dht/pointer_sync.dart';
import 'package:reticulum/src/services/social/relay_role.dart';

import '../log_service.dart';
import '../preferences_service.dart';
import '../reticulum/rns_service.dart';

/// The Indexer↔Indexer sync scheduler (docs/NOSTR.md).
///
/// Indexers spread the map among themselves so the phones do not have to.
/// Indexer-to-indexer traffic is fast and wired; a phone's is neither. So:
///
/// **Battery-powered leaves are never sync partners.** They announce, they get
/// indexed, and they are left alone. That asymmetry is the whole reason the
/// Indexer role exists — without it, "everyone is a relay" means "everyone's
/// battery pays for everyone else's queries".
///
/// This device only *runs* the loop when it is itself an Indexer (plugged in,
/// on a real uplink — `RelayRoleManager` derives that from the hardware, not
/// from a wish), and it only *talks to* peers whose announce says they are
/// Indexers too.
///
/// ## Performance (docs/performance.md)
///
/// Everything here is network-bound and off the UI's critical path: one peer per
/// tick, one bounded batch per exchange, and the RNS link work already lives in
/// the transport isolate. The merge verifies each record — which is Ed25519 over
/// a 176-byte record, not secp256k1 over a note — and is bounded by the batch
/// size (64), so a round is a few milliseconds of crypto, not a firehose.
class PointerSyncService {
  PointerSyncService._();
  static final PointerSyncService instance = PointerSyncService._();

  /// A home-fibre indexer every few minutes; the interval is deliberately long
  /// because pointers refresh on a 30-minute republish cycle anyway. Syncing
  /// faster would buy nothing and cost everybody.
  static const Duration _tick = Duration(minutes: 4);

  /// Per exchange. A LoRa-attached indexer takes the same log in tiny bites over
  /// hours; the cursor is what makes that free.
  static const int _batch = 64;

  /// How many peers we keep cursors for. Bounded: a hostile swarm of announces
  /// must not turn this into a memory leak.
  static const int _maxPeers = 64;

  Timer? _timer;
  int _round = 0;
  final Map<String, SyncCursor> _cursors = {}; // peer id hex -> cursor
  bool _loaded = false;

  int get peersTracked => _cursors.length;

  RnsService get _rns => RnsService.instance;

  void start() {
    _load();
    _timer ??= Timer.periodic(_tick, (_) => unawaited(_syncOnce()));
    LogService.instance.add('sync: pointer sync armed');
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One exchange with one partner. Round-robins through the known indexers so a
  /// single slow peer cannot starve the rest.
  Future<void> _syncOnce() async {
    final relay = _rns.relayNode;
    final log = _rns.pointerLog;
    if (relay == null || log == null) return;

    // Only an Indexer syncs. A leaf has nothing to give and cannot afford to
    // give it.
    if (!_rns.isIndexer) return;

    final partners = _partners();
    if (partners.isEmpty) return;

    final peer = partners[_round++ % partners.length];
    final idHex = _hex(peer.identity.hash);
    final cursor = _cursors[idHex] ?? SyncCursor.none;

    final client = PointerSyncClient(
      onInsert: (rec) async => _rns.acceptSyncedPointer(rec),
      onRemove: (key, providerPub) =>
          _rns.dropSyncedPointer(key, providerPub),
    );

    try {
      final out = await relay.syncPointers(
        peer.identity,
        client,
        cursor: cursor,
        max: _batch,
      );
      if (out == null) return;

      if (out.wasReset) {
        // Their log was rebuilt (or our position aged out of it). Start over
        // from zero against their NEW epoch — the alternative is a hole in our
        // map that nobody would ever notice.
        _cursors[idHex] = SyncCursor(out.cursor.epoch, 0);
        _save();
        LogService.instance.add(
            'sync: ${idHex.substring(0, 8)} reset us — restarting from zero');
        return;
      }

      _cursors[idHex] = out.cursor;
      _trim();
      _save();

      if (out.applied > 0 || out.removed > 0 || out.rejected > 0) {
        LogService.instance.add(
          'sync: ${idHex.substring(0, 8)} +${out.applied} -${out.removed} '
          'bad=${out.rejected} seq=${out.cursor.seq}${out.more ? ' (more)' : ''}',
        );
      }

      // Still a backlog? Keep pulling from this peer on the next tick rather
      // than moving on — a half-synced map is worse than a stale one.
      if (out.more) _round--;
    } catch (e) {
      LogService.instance.add('sync: ${idHex.substring(0, 8)} failed: $e');
    }
  }

  /// Who is worth syncing with: other Indexers, freshest first. Never a leaf —
  /// a phone in somebody's pocket is not a database to be scraped.
  List<RelayEntry> _partners() {
    final all = _rns.relayDirectory.indexers();
    final out = [
      for (final e in all)
        if (e.announcement.has(RelayCap.search)) e
    ]..sort((a, b) => b.lastSeenMs.compareTo(a.lastSeenMs));
    return out.take(8).toList();
  }

  void _trim() {
    if (_cursors.length <= _maxPeers) return;
    final drop = _cursors.keys.take(_cursors.length - _maxPeers).toList();
    for (final k in drop) {
      _cursors.remove(k);
    }
  }

  // A cursor is eight bytes and a name, and it must survive a restart — that is
  // the entire reason it is a position and not a time.
  void _load() {
    if (_loaded) return;
    _loaded = true;
    final raw = PreferencesService.instanceSync?.pointerCursors ?? '';
    if (raw.isEmpty) return;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      m.forEach((k, v) {
        if (v is Map) _cursors[k] = SyncCursor.fromMap(v);
      });
    } catch (_) {
      // A corrupt cursor file costs one full re-sync, not a crash.
    }
  }

  void _save() {
    PreferencesService.instanceSync?.pointerCursors = jsonEncode({
      for (final e in _cursors.entries) e.key: e.value.toMap(),
    });
  }

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
