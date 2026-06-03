/*
 * FunctionalityBroker — host-side router for functionality.request /
 * functionality.response messages. Implements the "one wapp can provide
 * multiple functionalities" rule and the "user preferences pick the
 * default provider" rule.
 *
 * Flow:
 *   1. Caller wapp emits `{"type":"widget.request", "widget": "<id>",
 *      "req_id": "<opaque>", "args": {...}}` via hal_msg_send.
 *      (wire names kept as `widget.*` for backward compat with
 *      existing wapp binaries.)
 *   2. wapp_page.dart `_drainOutbox` forwards it to
 *      [FunctionalityBroker.handleRequest] with the caller's engineId.
 *   3. Broker looks up providers in [FunctionalityRegistry], picks one
 *      via user preference (or first registered), spins up a HEADLESS
 *      [WappEngine] for that provider's wasm, injects the request,
 *      and drives `module_handle_event` synchronously.
 *   4. The provider's outbox is scanned for a `widget.response`
 *      matching `req_id`. The engine is then disposed.
 *   5. The matched response is delivered to the caller engine via
 *      [WappEngine.lookup] + sendMessage + handleEvent so the
 *      caller's `module_handle_event` runs immediately.
 */

import 'dart:convert';

import '../launcher/launcher.dart' show WappManifest;
import '../models/monitored_task.dart';
import '../wapp/wapp_engine.dart';
import 'preferences_service.dart';
import 'storage_paths.dart' show wappPackageStorage;
import 'functionality_registry.dart';
import 'task_monitor_service.dart';

class FunctionalityBroker {
  FunctionalityBroker._();
  static final FunctionalityBroker instance = FunctionalityBroker._();

  /// Wall-clock budget for a single headless provider call. A provider
  /// that exceeds this is reported to the task monitor (which surfaces
  /// it as an error) so a slow/runaway provider is visible. Note: a
  /// synchronous infinite loop inside the WASM cannot be preempted from
  /// the host isolate — this is a watchdog/visibility measure, and the
  /// engine is always disposed in `finally`.
  static const Duration providerBudget = Duration(seconds: 2);

  /// Main entry point called from `wapp_page.dart` when a caller
  /// wapp emits a `widget.request` message.
  Future<void> handleRequest({
    required String callerEngineId,
    required String functionalityId,
    required String reqId,
    required Map<String, dynamic> args,
  }) async {
    if (functionalityId.isEmpty || reqId.isEmpty) {
      _deliverError(callerEngineId, reqId,
          'widget.request missing widget/req_id');
      return;
    }

    final providers =
        FunctionalityRegistry.instance.providersFor(functionalityId);
    if (providers.isEmpty) {
      _deliverError(callerEngineId, reqId,
          'no provider registered for "$functionalityId"');
      return;
    }

    final provider = await _resolveProvider(functionalityId, providers);
    if (provider == null) {
      _deliverError(callerEngineId, reqId,
          'no provider selected for "$functionalityId"');
      return;
    }

    final pkg = wappPackageStorage(provider.dirPath);
    final wasmBytes = await pkg.readBytes('app.wasm');
    if (wasmBytes == null) {
      _deliverError(callerEngineId, reqId,
          'provider "${provider.id}" has no app.wasm');
      return;
    }

    // Register the headless call with the task monitor so broker work
    // is visible alongside every other task and a slow provider can be
    // spotted. Unregistered in `finally` so the registry stays clean.
    final monitor = TaskMonitorService.instance;
    final taskId = 'broker.$reqId';
    monitor.register(MonitoredTask(
      id: taskId,
      name: 'provider ${provider.id}',
      description: 'Headless call: $functionalityId',
      serviceName: 'broker',
      priority: TaskPriority.low,
      type: TaskType.oneshot,
    ));
    monitor.reportStart(taskId);
    final sw = Stopwatch()..start();

    final headless = WappEngine();
    try {
      await headless.load(wasmBytes);
      headless.init();

      final request = <String, dynamic>{
        'type': 'widget.request',
        'widget': functionalityId,
        'req_id': reqId,
        'reply_to': callerEngineId,
        'args': args,
      };
      headless.sendMessage(jsonEncode(request));
      headless.handleEvent();

      final response = _findResponse(headless.drainOutbox(), reqId);
      if (response == null) {
        monitor.reportSuccess(taskId);
        _deliverError(callerEngineId, reqId,
            'provider "${provider.id}" did not emit widget.response');
        return;
      }

      sw.stop();
      if (sw.elapsed > providerBudget) {
        // Over budget — surface as a monitor failure (fires ErrorEvent)
        // but still deliver the (late) response we got.
        monitor.reportFailure(
          taskId,
          'provider "${provider.id}" exceeded ${providerBudget.inMilliseconds}ms '
          '(took ${sw.elapsedMilliseconds}ms) for "$functionalityId"',
        );
      } else {
        monitor.reportSuccess(taskId);
      }

      _deliverResponse(callerEngineId, reqId,
          result: response['result'] as Map<String, dynamic>?,
          providerWappId: provider.id);
    } catch (e) {
      monitor.reportFailure(taskId, e);
      _deliverError(
          callerEngineId, reqId, 'provider "${provider.id}" threw: $e');
    } finally {
      headless.dispose();
      monitor.unregister(taskId);
    }
  }

  Future<WappManifest?> _resolveProvider(
    String functionalityId,
    List<WappManifest> providers,
  ) async {
    if (providers.isEmpty) return null;
    if (providers.length == 1) return providers.first;

    final prefs = await PreferencesService.instance();
    final preferredId = prefs.getPreferredProvider(functionalityId);
    if (preferredId != null) {
      for (final p in providers) {
        if (p.id == preferredId) return p;
      }
    }
    return providers.first;
  }

  Map<String, dynamic>? _findResponse(List<String> outbox, String reqId) {
    for (final raw in outbox) {
      try {
        final msg = jsonDecode(raw);
        if (msg is! Map<String, dynamic>) continue;
        if (msg['type'] != 'widget.response') continue;
        if (msg['req_id'] != reqId) continue;
        return msg;
      } catch (_) {}
    }
    return null;
  }

  void _deliverResponse(
    String callerEngineId,
    String reqId, {
    required Map<String, dynamic>? result,
    required String providerWappId,
  }) {
    _sendToCaller(callerEngineId, {
      'type': 'widget.response',
      'req_id': reqId,
      'widget_provider': providerWappId,
      if (result != null) 'result': result,
    });
  }

  void _deliverError(
      String callerEngineId, String reqId, String message) {
    _sendToCaller(callerEngineId, {
      'type': 'widget.response',
      'req_id': reqId,
      'error': message,
    });
  }

  void _sendToCaller(String callerEngineId, Map<String, dynamic> payload) {
    final engine = WappEngine.lookup(callerEngineId);
    if (engine == null) return;
    engine.sendMessage(jsonEncode(payload));
    engine.handleEvent();
  }
}
