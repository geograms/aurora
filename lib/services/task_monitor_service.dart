/*
 * TaskMonitorService — central registry for background tasks.
 *
 * Mirrors parent geogram's lib/services/task_monitor_service.dart so a
 * shared package can be extracted later. Pure Dart, no Flutter deps.
 *
 * The motivating problem: the previous geogram implementation had
 * threads/loops spawning ad-hoc, with no way to know what was running,
 * how much CPU it consumed, what order it started in, or how to pause
 * non-critical work on a constrained device. This service is the single
 * choke point for *every* background task: register on start, report
 * each execution, optionally pause/resume. UI and debug API read from
 * the same registry.
 */

import 'dart:async';

import 'package:reticulum/reticulum.dart' show RnsCrypto;

import '../models/monitored_task.dart';
import 'event_bus.dart';
import 'log_service.dart';
import 'reticulum/rns_service.dart';

/// Singleton registry. Access via `TaskMonitorService()` or
/// `TaskMonitorService.instance` — both return the same instance.
class TaskMonitorService {
  TaskMonitorService._();
  static final TaskMonitorService instance = TaskMonitorService._();
  factory TaskMonitorService() => instance;

  final Map<String, MonitoredTask> _tasks = {};

  // ── Governor configuration ─────────────────────────────────────────
  //
  // The governor watches periodic tasks (notably wapp tick loops) and
  // auto-pauses any non-critical one whose runs consistently consume
  // too much of their interval, so a single runaway wapp can't degrade
  // the whole launcher. Tunable at runtime (e.g. from the tasks wapp).

  /// Master switch. When false the governor never auto-pauses anything.
  bool governorEnabled = true;

  /// Fraction of a task's interval a single run may consume before that
  /// run counts as an "overrun". 0.8 = a tick may use up to 80% of its
  /// interval before being flagged.
  double overrunThreshold = 0.8;

  /// Consecutive overruns required before the governor pauses a task.
  /// Avoids reacting to a single slow tick (GC pause, cold cache).
  int overrunWindow = 3;

  // ── Main-isolate CPU attribution ───────────────────────────────────
  //
  // Every monitored task runs on the main isolate, so their combined CPU IS
  // the app's main-isolate load. A 60s summary of who burned it turns "the UI
  // feels heavy" into a ranked list — the evidence that decides what is worth
  // moving to a worker isolate (and proves it afterwards). Cheap: one log line
  // per minute, computed from counters the monitor already keeps.
  Timer? _cpuSummaryTimer;
  final Map<String, int> _cpuAtLastSummary = {};

  void startCpuSummary({Duration every = const Duration(seconds: 60)}) {
    _cpuSummaryTimer?.cancel();
    _cpuSummaryTimer = Timer.periodic(every, (_) => _logCpuSummary(every));
  }

  void _logCpuSummary(Duration window) {
    // Worker-isolate load. Monitored tasks only cover the MAIN isolate, but the
    // crypto worker and the NOSTR relay engine can each burn a core — invisible
    // to the UI (no stalls) and lethal to the battery. Attribute them by the
    // work they actually did.
    try {
      final crypto = RnsCrypto.drainCryptoStats();
      if (crypto.isNotEmpty) {
        final s =
            crypto.entries.map((e) => '${e.key}=${e.value}').join(' ');
        LogService.instance.add('perf: crypto-worker $s');
      }
      final ev = RnsService.instance.nostrEventStats;
      if (ev.isNotEmpty && ev.values.any((v) => v > 0)) {
        final s = ev.entries.map((e) => '${e.key}=${e.value}').join(' ');
        LogService.instance.add('perf: nostr-engine $s');
      }
      // Connectionless probes. `silent` is the number of inbound queries we
      // answered with NOTHING — each of which used to cost a full Curve25519
      // link handshake to say "I have nothing".
      final npd = RnsService.instance.drainNpdStats();
      if (npd.values.any((v) => v > 0)) {
        final s = npd.entries.map((e) => '${e.key}=${e.value}').join(' ');
        LogService.instance.add('perf: npd $s');
      }
      // The transport isolate's load is the raw announce flood it parses,
      // dedups, path-tables and (as a transport node) rebroadcasts — all of
      // which happen BEFORE any signature check, so a low verify count says
      // nothing about it.
      final rns = RnsService.instance;
      if (rns.isUp) {
        LogService.instance.add(
          'perf: rns-transport announces/s=${rns.announceRatePerSec.toStringAsFixed(1)} '
          'paths=${rns.pathCount} passive=${rns.passive}',
        );
      }
    } catch (_) {/* telemetry must never break the app */}

    final rows = <({String id, int ms, int runs})>[];
    var totalMs = 0;
    for (final t in _tasks.values) {
      final prev = _cpuAtLastSummary[t.id] ?? 0;
      final delta = t.totalCpuMs - prev;
      _cpuAtLastSummary[t.id] = t.totalCpuMs;
      if (delta <= 0) continue;
      totalMs += delta;
      rows.add((id: t.id, ms: delta, runs: t.runCount));
    }
    if (rows.isEmpty) return;
    rows.sort((a, b) => b.ms.compareTo(a.ms));
    final windowMs = window.inMilliseconds;
    final pct = (totalMs * 100 / windowMs).toStringAsFixed(1);
    final top = rows
        .take(5)
        .map((r) => '${r.id}=${r.ms}ms(${(r.ms * 100 / windowMs).toStringAsFixed(1)}%)')
        .join(' ');
    LogService.instance
        .add('perf: cpu tasks total ${totalMs}ms ($pct% of main) — $top');
  }

  final StreamController<TaskStateChangedEvent> _stateChanges =
      StreamController<TaskStateChangedEvent>.broadcast();

  /// Stream of task status transitions. UI components (debug page,
  /// status bar) subscribe to this for live updates.
  Stream<TaskStateChangedEvent> get stateChanges => _stateChanges.stream;

  // ── Register / unregister ──────────────────────────────────────────

  void register(MonitoredTask task) {
    _tasks[task.id] = task;
  }

  void unregister(String id) {
    _tasks.remove(id);
  }

  // ── Lifecycle reporting (call around each execution) ───────────────

  void reportStart(String id) {
    final task = _tasks[id];
    if (task == null) return;
    final old = task.status;
    task.status = TaskStatus.running;
    task.lastRunAt = DateTime.now();
    task.runCount++;
    _emit(id, old, TaskStatus.running);
  }

  void reportSuccess(String id) {
    final task = _tasks[id];
    if (task == null) return;
    final old = task.status;
    task.successCount++;
    if (task.lastRunAt != null) {
      task.lastDuration = DateTime.now().difference(task.lastRunAt!);
      task.totalCpuMs += task.lastDuration!.inMilliseconds;
    }
    task.lastError = null;
    // Attribution for UI stalls: every monitored task runs on the main
    // isolate, so a tick longer than ~3 frames is a felt touch freeze. Log the
    // culprit by name (rate-limited per task via the streak below).
    final costMs = task.lastDuration?.inMilliseconds ?? 0;
    if (costMs > 48 && task.type == TaskType.periodic) {
      LogService.instance.add('perf: ${task.id} tick took ${costMs}ms');
    }
    // Feed the governor with this run's cost. If the task has been
    // overrunning its budget, it gets auto-paused instead of going idle.
    final paused = _governorShouldPause(task);
    task.status = paused ? TaskStatus.paused : TaskStatus.idle;
    if (paused) task.autoPaused = true;
    _emit(id, old, task.status);
  }

  /// Update [task]'s CPU-budget EMA and overrun streak from its last
  /// run, and decide whether the governor should pause it now. Pure
  /// state update + decision; the caller flips the status.
  bool _governorShouldPause(MonitoredTask task) {
    if (!governorEnabled) return false;
    if (task.type != TaskType.periodic) return false;
    final interval = task.interval;
    final dur = task.lastDuration;
    if (interval == null || interval.inMicroseconds <= 0 || dur == null) {
      return false;
    }
    final ratio = dur.inMicroseconds / interval.inMicroseconds;
    // EMA, alpha 0.3 — smooths out single spikes while tracking trend.
    task.cpuBudgetEma =
        task.cpuBudgetEma == 0 ? ratio : (0.3 * ratio + 0.7 * task.cpuBudgetEma);
    task.overrunStreak = ratio > overrunThreshold ? task.overrunStreak + 1 : 0;
    return task.priority != TaskPriority.critical &&
        task.overrunStreak >= overrunWindow;
  }

  void reportFailure(String id, Object error) {
    final task = _tasks[id];
    if (task == null) return;
    final old = task.status;
    task.failCount++;
    if (task.lastRunAt != null) {
      task.lastDuration = DateTime.now().difference(task.lastRunAt!);
    }
    task.lastError = error.toString();
    task.status = TaskStatus.error;
    _emit(id, old, TaskStatus.error);
    EventBus().fire(ErrorEvent(
      source: 'TaskMonitor:$id',
      message: error.toString(),
      error: error,
    ));
  }

  // ── Queries ────────────────────────────────────────────────────────

  List<MonitoredTask> get tasks => List.unmodifiable(_tasks.values);

  MonitoredTask? getTask(String id) => _tasks[id];

  Map<String, List<MonitoredTask>> get tasksByService {
    final map = <String, List<MonitoredTask>>{};
    for (final t in _tasks.values) {
      (map[t.serviceName] ??= []).add(t);
    }
    return map;
  }

  Map<TaskPriority, List<MonitoredTask>> get tasksByPriority {
    final map = <TaskPriority, List<MonitoredTask>>{};
    for (final t in _tasks.values) {
      (map[t.priority] ??= []).add(t);
    }
    return map;
  }

  // ── Pause / resume ─────────────────────────────────────────────────

  /// Pause a non-critical task. Returns false for critical tasks or
  /// unknown ids. Note: pausing only flips the status flag — owners
  /// must check `task.status == TaskStatus.paused` before doing work.
  bool pause(String id) {
    final task = _tasks[id];
    if (task == null) return false;
    if (task.priority == TaskPriority.critical) return false;
    final old = task.status;
    task.status = TaskStatus.paused;
    task.autoPaused = false; // explicit user action, not the governor
    _emit(id, old, TaskStatus.paused);
    return true;
  }

  bool resume(String id) {
    final task = _tasks[id];
    if (task == null) return false;
    if (task.status != TaskStatus.paused) return false;
    final old = task.status;
    task.status = TaskStatus.idle;
    // Give the task a clean slate so the governor doesn't immediately
    // re-pause it on a single stale overrun sample.
    task.autoPaused = false;
    task.overrunStreak = 0;
    _emit(id, old, TaskStatus.idle);
    return true;
  }

  /// Reconfigure the governor at runtime (e.g. from the tasks wapp).
  /// Any null argument leaves that setting unchanged.
  void configureGovernor({bool? enabled, double? threshold, int? window}) {
    if (enabled != null) governorEnabled = enabled;
    if (threshold != null && threshold > 0) overrunThreshold = threshold;
    if (window != null && window > 0) overrunWindow = window;
  }

  /// Pause every non-critical task that isn't already paused. Returns
  /// the number of tasks affected. Used when the device reports memory
  /// or thermal pressure.
  int pauseAllNonCritical() {
    var count = 0;
    for (final t in _tasks.values) {
      if (t.priority != TaskPriority.critical &&
          t.status != TaskStatus.paused) {
        final old = t.status;
        t.status = TaskStatus.paused;
        _emit(t.id, old, TaskStatus.paused);
        count++;
      }
    }
    return count;
  }

  int resumeAll() {
    var count = 0;
    for (final t in _tasks.values) {
      if (t.status == TaskStatus.paused) {
        final old = t.status;
        t.status = TaskStatus.idle;
        _emit(t.id, old, TaskStatus.idle);
        count++;
      }
    }
    return count;
  }

  // ── Summary (debug API) ────────────────────────────────────────────

  Map<String, dynamic> toJson() {
    final list = _tasks.values.map((t) => t.toJson()).toList();
    return {
      'success': true,
      'total': list.length,
      'running': _tasks.values
          .where((t) => t.status == TaskStatus.running)
          .length,
      'idle': _tasks.values.where((t) => t.status == TaskStatus.idle).length,
      'paused': _tasks.values
          .where((t) => t.status == TaskStatus.paused)
          .length,
      'error': _tasks.values.where((t) => t.status == TaskStatus.error).length,
      'tasks': list,
    };
  }

  // ── Internal ───────────────────────────────────────────────────────

  void _emit(String id, TaskStatus oldStatus, TaskStatus newStatus) {
    if (oldStatus == newStatus) return;
    _stateChanges.add(TaskStateChangedEvent(
      taskId: id,
      oldStatus: oldStatus,
      newStatus: newStatus,
    ));
  }
}

// ── Template process method ─────────────────────────────────────────
//
// Wrap any one-shot startup step in this helper so it auto-registers
// with the task monitor and reports start/success/failure. This is the
// pattern from parent geogram's main.dart `_initService`. Wapps and
// startup code should NOT roll their own try/catch around init steps —
// always go through here so the monitor sees them.
//
// [bootStart] tags the resulting MonitoredTask with how it participates
// in the boot phase. The default is [BootStart.parallel] — pass
// [BootStart.sequential] for heavy work that must not compete with
// other boot tasks. The actual scheduling of sequential vs parallel
// tasks is done by [BootOrchestrator]; runMonitoredStartup itself
// always runs immediately when called.

Future<void> runMonitoredStartup(
  String id,
  String name,
  Future<void> Function() init, {
  TaskPriority priority = TaskPriority.normal,
  String description = '',
  BootStart bootStart = BootStart.parallel,
}) async {
  final monitor = TaskMonitorService.instance;
  final taskId = 'startup.$id';
  final task = MonitoredTask(
    id: taskId,
    name: name,
    description: description.isEmpty ? name : description,
    serviceName: 'startup',
    priority: priority,
    type: TaskType.oneshot,
    bootStart: bootStart,
  );
  monitor.register(task);
  monitor.reportStart(taskId);
  final stopwatch = Stopwatch()..start();
  try {
    await init();
    stopwatch.stop();
    task.initWallMs = stopwatch.elapsedMilliseconds;
    task.initCpuMs = stopwatch.elapsedMilliseconds;
    monitor.reportSuccess(taskId);
  } catch (e) {
    stopwatch.stop();
    monitor.reportFailure(taskId, e);
    rethrow;
  }
}

// ── BootOrchestrator ────────────────────────────────────────────────
//
// Two-phase boot sequencer. Code that needs to run during geogram
// startup should call [BootOrchestrator.instance.register] *before*
// `runApp`, then `main()` calls [runAll] exactly once. Sequential
// tasks run first, alone, in registration order. Parallel tasks run
// after, all at once.
//
// Each task is run through [runMonitoredStartup], so they end up in
// the task monitor with the right `bootStart` attribute and the boot
// time recorded as `initWallMs`. Failures from sequential tasks rethrow
// — a heavy boot task that fails halts the boot sequence so the user
// sees a clear error instead of partial state. Failures from parallel
// tasks are isolated (the rest still run) but still visible in the
// monitor.

class _BootEntry {
  final String id;
  final String name;
  final Future<void> Function() init;
  final BootStart mode;
  final TaskPriority priority;
  final String description;
  _BootEntry(this.id, this.name, this.init, this.mode, this.priority,
      this.description);
}

class BootOrchestrator {
  BootOrchestrator._();
  static final BootOrchestrator instance = BootOrchestrator._();

  final List<_BootEntry> _pending = [];

  /// Register a task to run during the geogram boot phase. Must be
  /// called before [runAll]. Order matters for [BootStart.sequential]
  /// — tasks run in registration order, so register the most critical
  /// dependency first.
  void register({
    required String id,
    required String name,
    required Future<void> Function() init,
    BootStart mode = BootStart.parallel,
    TaskPriority priority = TaskPriority.normal,
    String description = '',
  }) {
    _pending.add(_BootEntry(id, name, init, mode, priority, description));
  }

  /// Run every registered boot task. Sequentials first, in order, one
  /// at a time. Then all parallels concurrently. Idempotent — calling
  /// twice is a no-op the second time because the pending list is
  /// drained.
  Future<void> runAll() async {
    if (_pending.isEmpty) return;
    final entries = List<_BootEntry>.from(_pending);
    _pending.clear();

    final sequential =
        entries.where((e) => e.mode == BootStart.sequential).toList();
    final parallel =
        entries.where((e) => e.mode == BootStart.parallel).toList();

    // Sequentials run alone, in order. A failure halts the sequence so
    // dependent boot tasks don't run with a broken precondition.
    for (final entry in sequential) {
      await _runOne(entry);
    }

    // Parallels run concurrently. Each is independent — one failing
    // does not abort the others.
    if (parallel.isNotEmpty) {
      await Future.wait(parallel.map(_runOneSafe));
    }
  }

  Future<void> _runOne(_BootEntry e) {
    return runMonitoredStartup(
      e.id, e.name, e.init,
      priority: e.priority,
      description: e.description,
      bootStart: e.mode,
    );
  }

  Future<void> _runOneSafe(_BootEntry e) async {
    try {
      await _runOne(e);
    } catch (_) {
      // Swallowed — runMonitoredStartup already reported the failure
      // to TaskMonitorService and EventBus. Other parallel tasks must
      // still run.
    }
  }

  /// Number of tasks still waiting to be run. Test/debug helper.
  int get pendingCount => _pending.length;
}
