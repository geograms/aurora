/*
 * BackgroundService — shared template for recurring background work.
 *
 * Every periodic service (wapp tick loops, autostarted/boot services, …)
 * should run through this so it is uniformly:
 *   - visible in the TaskMonitor (the "tasks" wapp) with a stable id/name,
 *   - assigned a priority (so the governor can shed low-priority load),
 *   - CPU-measured per tick (lastDuration / totalCpuMs / cpuBudgetEma), and
 *   - pause-aware: the monitor's governor auto-pauses a runaway tick so one
 *     misbehaving service can't starve the UI or other services.
 *
 * Threading: set [runsInIsolate] for pure-compute services and offload the
 * heavy work inside [onTick] via [runOffThread] (Isolate.run) so it runs on
 * its own thread and never blocks the UI isolate. Services that must touch
 * main-isolate plugins (e.g. BLE) keep it false and rely on the governor.
 */

import 'dart:async';
import 'dart:isolate';

import '../models/monitored_task.dart';
import 'task_monitor_service.dart';

abstract class BackgroundService {
  BackgroundService({
    required this.id,
    required this.name,
    required this.interval,
    this.serviceName = 'services',
    this.priority = TaskPriority.normal,
    this.runsInIsolate = false,
    this.description,
  });

  /// Stable id (also the TaskMonitor key).
  final String id;
  final String name;
  final String serviceName;
  final TaskPriority priority;
  final Duration interval;

  /// Registers as [TaskType.isolate] and signals that [onTick] offloads its
  /// heavy work onto a worker isolate (see [runOffThread]).
  final bool runsInIsolate;
  final String? description;

  Timer? _timer;
  bool _started = false;
  bool get isRunning => _started;

  /// The periodic work. Override in subclasses.
  Future<void> onTick();

  /// One-time setup before the first tick (e.g. module_init).
  Future<void> onStart() async {}

  /// Cleanup after the loop stops (e.g. dispose the engine).
  Future<void> onStop() async {}

  Future<void> start() async {
    if (_started) return;
    _started = true;
    TaskMonitorService.instance.register(MonitoredTask(
      id: id,
      name: name,
      description: description ?? 'Background service: $name',
      serviceName: serviceName,
      priority: priority,
      type: runsInIsolate ? TaskType.isolate : TaskType.periodic,
      interval: interval,
    ));
    try {
      await onStart();
    } catch (e) {
      TaskMonitorService.instance.reportFailure(id, e);
    }
    _timer = Timer.periodic(interval, (_) => _runTick());
  }

  /// Run one tick now (used by the timer and by external heartbeats such as
  /// the Android foreground service, whose native cadence keeps ticks going
  /// when the Dart timer is throttled in the background).
  Future<void> tickNow() => _runTick();

  Future<void> _runTick() async {
    if (!_started) return;
    final mon = TaskMonitorService.instance;
    // Honour governor / manual pause: skip the body, keep the loop alive.
    if (mon.getTask(id)?.status == TaskStatus.paused) return;
    mon.reportStart(id);
    try {
      await onTick();
      mon.reportSuccess(id);
    } catch (e) {
      mon.reportFailure(id, e);
    }
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _timer?.cancel();
    _timer = null;
    try {
      await onStop();
    } catch (_) {}
    TaskMonitorService.instance.unregister(id);
  }

  /// Run a self-contained [computation] on its own worker isolate so heavy CPU
  /// work never janks the UI isolate. The computation (and its captured data)
  /// must be sendable — keep it pure (no plugin/BLE access). The awaited
  /// wall-clock is what the monitor records for the tick.
  static Future<T> runOffThread<T>(Future<T> Function() computation) =>
      Isolate.run(computation);
}
