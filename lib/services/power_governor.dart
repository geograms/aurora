/*
 * PowerGovernor — pauses non-critical background tasks on low battery and
 * resumes them when power recovers, complementing the task monitor's CPU-budget
 * governor. Host-generic: it operates on the task monitor, not on any specific
 * service, so every BackgroundService (priority != critical) is throttled
 * uniformly via its onPause()/onResume() hooks.
 */
import 'dart:async';

import 'package:battery_plus/battery_plus.dart';

import 'log_service.dart';
import 'task_monitor_service.dart';

class PowerGovernor {
  PowerGovernor._();
  static final PowerGovernor instance = PowerGovernor._();

  final Battery _battery = Battery();
  StreamSubscription<BatteryState>? _sub;
  Timer? _poll;
  bool _throttled = false;
  bool _running = false;

  /// Pause non-critical tasks at or below this level while discharging.
  int lowThreshold = 20;
  /// Resume once charging or back at/above this level.
  int resumeThreshold = 30;

  Future<void> start() async {
    if (_running) return;
    _running = true;
    try {
      await _evaluate();
      // Charging state changes are event-driven; level is polled (no level stream).
      _sub = _battery.onBatteryStateChanged.listen((_) => _evaluate());
      _poll = Timer.periodic(const Duration(minutes: 2), (_) => _evaluate());
    } catch (e) {
      LogService.instance.add('PowerGovernor: unavailable ($e)');
    }
  }

  Future<void> _evaluate() async {
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      // A device with no battery (most desktops) reports state `unknown` and a
      // bogus 0% level — treat that as mains power, never throttle. Otherwise a
      // desktop would permanently pause its background tasks (e.g. the APRS
      // wapp's APRS-IS/Reticulum receive loop) at a phantom "0%".
      final powered = state == BatteryState.charging ||
          state == BatteryState.full ||
          state == BatteryState.unknown;
      if (!_throttled && !powered && level <= lowThreshold) {
        _throttled = true;
        final n = TaskMonitorService.instance.pauseAllNonCritical();
        LogService.instance
            .add('PowerGovernor: low battery $level%, paused $n background task(s)');
      } else if (_throttled && (powered || level >= resumeThreshold)) {
        _throttled = false;
        final n = TaskMonitorService.instance.resumeAll();
        LogService.instance
            .add('PowerGovernor: power ok $level%, resumed $n background task(s)');
      }
    } catch (_) {}
  }

  void stop() {
    _running = false;
    _sub?.cancel();
    _sub = null;
    _poll?.cancel();
    _poll = null;
  }
}
