/*
 * mesh_transfer_scheduler — decides when to dial whom (doc/mesh.md §6).
 *
 * A 10 s tick walks the work list and opens at most one GATT custody session
 * at a time:
 *
 *   1. We hold in-transit mail whose target (or route next-hop) is dialable
 *      → dial that peer and flush.
 *   2. A neighbor's beacon trailer advertises pending mail and we haven't
 *      visited it recently → dial in and let the symmetric session pull
 *      (this is how mail is fetched off server-only nodes like the ESP32).
 *
 * Politeness: per-peer exponential backoff (30 s → 5 min) after failed dials,
 * a quiet period after every clean session, and no dialing at all while any
 * session is live. The transports stay free for broadcast most of the time —
 * sessions are short bursts, resume handles the rest.
 */
import 'dart:async';

import '../log_service.dart';
import 'mesh_bulk_spool.dart';
import 'mesh_custody.dart';
import 'mesh_service.dart';
import 'mesh_store.dart';

class MeshTransferScheduler {
  MeshTransferScheduler._();
  static final MeshTransferScheduler instance = MeshTransferScheduler._();

  static const Duration _tick = Duration(seconds: 10);
  static const Duration _cleanQuiet = Duration(seconds: 60);
  static const Duration _pendingPeerQuiet = Duration(seconds: 45);
  static const Duration _backoffMin = Duration(seconds: 15);
  static const Duration _backoffMax = Duration(minutes: 2);

  Timer? _timer;
  final Map<String, DateTime> _nextTry = {};
  final Map<String, Duration> _backoff = {};
  final Map<String, DateTime> _pendingVisited = {};
  String? _dialing;
  DateTime _dialStarted = DateTime.fromMillisecondsSinceEpoch(0);

  void start() {
    _timer ??= Timer.periodic(_tick, (_) => _onTick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// A dialed session ended — feed the backoff.
  void dialResult(String peer, {required bool clean}) {
    final p = peer.toUpperCase();
    _dialing = null;
    if (clean) {
      _backoff.remove(p);
      _nextTry[p] = DateTime.now().add(_cleanQuiet);
    } else {
      final b = _backoff[p] ?? _backoffMin;
      _nextTry[p] = DateTime.now().add(b);
      _backoff[p] = b * 2 > _backoffMax ? _backoffMax : b * 2;
    }
  }

  DateTime? _starvedSince;

  void _onTick() {
    final mgr = MeshSessionManager.instance;
    final hooks = mgr.hooks;
    final dial = hooks.dial;
    final dialable = hooks.dialable?.call();
    if (dial == null || dialable == null || dialable.isEmpty) return;
    mgr.reapClosed(); // belt: sweep timer-closed sessions every tick
    if (mgr.anyActive) {
      // Starvation watchdog: a session that has been "active" for far past
      // the politeness cap is a zombie (stuck link, dead peer) — force the
      // client link down so the mesh gets its radio back.
      _starvedSince ??= DateTime.now();
      if (DateTime.now().difference(_starvedSince!) >
          const Duration(minutes: 3)) {
        _starvedSince = null;
        LogService.instance
            .add('Mesh: scheduler starved 3 min — forcing link drop');
        mgr.clientSession?.close(clean: false);
        mgr.servedSession?.close(clean: false);
        mgr.reapClosed();
        hooks.dropClientLink?.call();
      }
      return; // one session at a time — stay polite
    }
    _starvedSince = null;

    // A dial that never produced a session is a failed attempt. Auto
    // (background) connects wait at controller level — give them a long
    // window before aborting; every extra second is more ADV_IND chances.
    final d = _dialing;
    if (d != null) {
      if (DateTime.now().difference(_dialStarted) <
          const Duration(seconds: 110)) {
        return; // connect still in flight
      }
      hooks.dropClientLink?.call(); // cancel the pending background connect
      dialResult(d, clean: false);
    }

    final now = DateTime.now();
    bool blocked(String peer) {
      final t = _nextTry[peer.toUpperCase()];
      return t != null && now.isBefore(t);
    }

    final table = MeshService.instance.table;
    final store = MeshStore.instance;

    // 1) Mail or bulk we owe: dial the target itself, or its route next hop.
    final spool = MeshBulkSpool.instance;
    final havePendingMsgs = store.ready && store.pendingCount() > 0;
    final havePendingBulk = spool.ready && spool.pendingCount() > 0;
    if (havePendingMsgs || havePendingBulk) {
      for (final peer in dialable.keys) {
        if (blocked(peer)) continue;
        if (havePendingMsgs &&
            store.pendingFor(peer, table, max: 1).isNotEmpty) {
          _dialTo(peer, dial, 'flush mail');
          return;
        }
        if (havePendingBulk && spool.nextFor(peer, table) != null) {
          _dialTo(peer, dial, 'move bulk');
          return;
        }
      }
    }

    // 2) Neighbors advertising pending mail (pull — vital for server-only
    // nodes that cannot dial us).
    if (table != null) {
      for (final n in table.neighbors.values) {
        if (n.pendingMsgs == 0 && n.pendingBulk == 0) continue;
        final peer = n.callsign.toUpperCase();
        if (!dialable.containsKey(peer) || blocked(peer)) continue;
        final visited = _pendingVisited[peer];
        if (visited != null && now.difference(visited) < _pendingPeerQuiet) {
          continue;
        }
        _pendingVisited[peer] = now;
        _dialTo(peer, dial, 'peer advertises ${n.pendingMsgs} pending');
        return;
      }
    }
  }

  void _dialTo(String peer, bool Function(String) dial, String why) {
    LogService.instance.add('Mesh: dialing $peer ($why)');
    if (dial(peer)) {
      _dialing = peer.toUpperCase();
      _dialStarted = DateTime.now();
    } else {
      dialResult(peer, clean: false);
    }
  }
}
