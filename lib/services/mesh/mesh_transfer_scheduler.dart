/*
 * mesh_transfer_scheduler — decides when to dial whom (docs/mesh.md §6).
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
import 'mesh_beacon.dart';
import 'mesh_custodian.dart';
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

  /// Last tick's decision, timestamped — the scheduler used to fail SILENT
  /// (five different gates, identical no-op outcome); now every tick leaves
  /// a trace and a changed decision is logged.
  String lastDecision = 'never ticked';
  DateTime lastDecisionAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastDialAttempt;

  void _decide(String d) {
    lastDecisionAt = DateTime.now();
    if (d != lastDecision) {
      lastDecision = d;
      LogService.instance.add('Mesh/sched: $d');
    }
  }

  Map<String, dynamic> statusJson() => {
        'decision': lastDecision,
        'at': lastDecisionAt.toIso8601String(),
        'dialing': _dialing,
        'backoff': {
          for (final e in _nextTry.entries)
            e.key: e.value.difference(DateTime.now()).inSeconds
        },
        'lastDialAttempt': _lastDialAttempt?.toIso8601String(),
      };

  /// Failsafe: visible work but no dial attempt for 5 min → the gate state
  /// is wrong somewhere; wipe it and start clean (self-healing beats
  /// perfect gate logic).
  void _failsafe(bool workVisible) {
    if (!workVisible) return;
    final last = _lastDialAttempt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 5)) {
      return;
    }
    if (last == null) {
      _lastDialAttempt = DateTime.now(); // arm the 5-min window
      return;
    }
    LogService.instance
        .add('Mesh/sched: FAILSAFE — work visible, no dial 5 min: reset gates');
    _nextTry.clear();
    _backoff.clear();
    _pendingVisited.clear();
    _dialing = null;
    _starvedSince = null;
    _lastDialAttempt = DateTime.now();
  }

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
    if (dial == null || dialable == null || dialable.isEmpty) {
      _decide('idle: no dialable peers');
      return;
    }
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
      _decide('busy: session active with '
          '${mgr.clientSession?.peerCallsign ?? mgr.servedSession?.peerCallsign ?? "?"}');
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
        _decide('waiting: connect to $d in flight');
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
      // 1b) Own-origin mail whose target is nowhere in the mesh horizon:
      // hand it to the best-scored custodian in reach (contact x stability,
      // docs/mesh.md §6) rather than holding it forever.
      if (table != null && havePendingMsgs) {
        for (final own in store.ownPendingTargets(
            MeshService.instance.tableCallsign)) {
          if (table.neighbors.keys
                  .any((n) => n.toUpperCase() == own.toUpperCase()) ||
              table.routes.containsKey(meshHashHex(meshHash(own)))) {
            continue; // reachable: paths 1/2 handle it
          }
          final custodian = meshPickCustodian(table, own);
          if (custodian == null) continue;
          final peer = custodian.toUpperCase();
          if (!dialable.containsKey(peer) || blocked(peer)) continue;
          _dialTo(peer, dial, 'custodian for unreachable $own');
          return;
        }
      }
    }

    // 2) Neighbors advertising pending mail (pull — vital for server-only
    // nodes that cannot dial us). Battery policy: a low, discharging phone
    // stops volunteering to pull for others; its own mail (path 1) still
    // moves.
    if (MeshService.instance.dialBudgetLow()) {
      _decide('idle: low battery — not pulling for others');
      return;
    }
    final advertisers = <String>[];
    if (table != null) {
      for (final n in table.neighbors.values) {
        if (n.pendingMsgs == 0 && n.pendingBulk == 0) continue;
        final peer = n.callsign.toUpperCase();
        advertisers.add(
            '$peer(m${n.pendingMsgs}/b${n.pendingBulk}'
            '${dialable.containsKey(peer) ? "" : ",undialable"}'
            '${blocked(peer) ? ",backoff" : ""})');
        if (!dialable.containsKey(peer) || blocked(peer)) continue;
        final visited = _pendingVisited[peer];
        if (visited != null && now.difference(visited) < _pendingPeerQuiet) {
          continue;
        }
        _pendingVisited[peer] = now;
        _dialTo(peer, dial, 'peer advertises ${n.pendingMsgs}m/${n.pendingBulk}b pending');
        return;
      }
    }
    final work = havePendingMsgs || havePendingBulk || advertisers.isNotEmpty;
    _decide(advertisers.isEmpty
        ? 'idle: no work (own pending: msgs=$havePendingMsgs bulk=$havePendingBulk)'
        : 'gated: advertisers ${advertisers.join(" ")}');
    _failsafe(work);
  }

  void _dialTo(String peer, bool Function(String) dial, String why) {
    _lastDialAttempt = DateTime.now();
    _decide('dialing $peer ($why)');
    LogService.instance.add('Mesh: dialing $peer ($why)');
    if (dial(peer)) {
      _dialing = peer.toUpperCase();
      _dialStarted = DateTime.now();
    } else {
      dialResult(peer, clean: false);
    }
  }
}
