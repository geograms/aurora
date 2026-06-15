/*
 * Background wapp service manager.
 *
 * Runs a wapp's wasm engine headlessly — calling module_tick on the manifest
 * interval with no UI page attached — so a wapp the user marked "autostart"
 * keeps doing work (e.g. APRS staying on BLE/APRS-IS to receive + relay
 * messages) after its page is closed and from app boot.
 *
 * Each background wapp runs through the shared [BackgroundService] template, so
 * it shows up in the TaskMonitor (the "tasks" wapp) with a priority, is
 * CPU-measured per tick, and is auto-paused by the governor if it ever runs
 * away — it can't starve the UI or other wapps.
 *
 * Only ONE engine per wapp runs at a time. When a wapp's UI page opens it
 * calls [suspend] (the page takes over its own engine); when the page closes
 * it calls [resume] (we restart the background engine if autostart is on).
 *
 * On Android, true always-on (screen off / app backgrounded) additionally
 * needs the native foreground service — see AndroidForegroundService, started
 * from [_onRunningChanged] whenever at least one background wapp is live.
 */

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/monitored_task.dart';
import '../profile/storage_paths.dart';
import '../services/background_service.dart';
import 'geoui/geo_chat_archive.dart';
import 'shared_media_fetch.dart';
import '../services/notification_service.dart';
import '../services/wapp_unread_service.dart';
import '../services/preferences_service.dart';
import 'android_foreground_service.dart';
import 'wapp_engine.dart';

class BackgroundWappManager {
  BackgroundWappManager._();
  static final BackgroundWappManager instance = BackgroundWappManager._();

  // Keyed by wapp folder name (the same id WappPage uses for KV + task ids).
  final Map<String, _WappBackgroundService> _running = {};

  bool isRunning(String wappName) => _running.containsKey(wappName);
  List<String> get runningNames => _running.keys.toList(growable: false);

  /// Folder name from a package dir (mirrors WappPage._deriveWappName).
  static String folderName(String wappDir) {
    var last = wappDir.replaceAll('\\', '/').split('/').last;
    if (last.toLowerCase().endsWith('.wapp')) {
      last = last.substring(0, last.length - 5);
    }
    return last;
  }

  /// Start a wapp as a background service. No-op if already running.
  Future<void> start(String wappDir) async {
    final name = folderName(wappDir);
    if (_running.containsKey(name)) return;
    try {
      final pkg = wappPackageStorage(wappDir);
      final wasm = await pkg.readBytes('app.wasm');
      if (wasm == null) {
        debugPrint('BackgroundWapp: $name has no app.wasm');
        return;
      }
      final prefs = await PreferencesService.instance();
      final engine = WappEngine();
      engine.setStorage(wappDataStorageFor(prefs, name));
      await engine.load(wasm);
      final svc = _WappBackgroundService(name, wappDir, engine, prefs);
      _running[name] = svc;
      await svc.start(); // registers the monitor task, runs init, starts ticking
      debugPrint('BackgroundWapp: started $name (tick ${svc.interval.inMilliseconds}ms)');
      _onRunningChanged();
    } catch (e) {
      debugPrint('BackgroundWapp: failed to start $name: $e');
      _running.remove(name);
    }
  }

  /// Stop and dispose a background wapp (releases its BLE scan ref, sockets…).
  void stop(String wappName) {
    final svc = _running.remove(wappName);
    if (svc == null) return;
    unawaited(svc.stop());
    debugPrint('BackgroundWapp: stopped $wappName');
    _onRunningChanged();
  }

  /// A UI page for [wappName] is opening — drop the background engine so the
  /// page owns the only engine (avoids double BLE scan / double processing).
  void suspend(String wappName) => stop(wappName);

  /// A UI page for the wapp at [wappDir] closed — bring the background engine
  /// back if the user enabled autostart for it.
  Future<void> resume(String wappDir) async {
    final prefs = await PreferencesService.instance();
    if (prefs.getWappAutostart(folderName(wappDir))) await start(wappDir);
  }

  /// Start every installed wapp the user marked autostart. Called at boot.
  Future<void> startAutostart() async {
    final prefs = await PreferencesService.instance();
    await syncBootAutostart(prefs);
    final installed = installedAppsStorage();
    if (!await installed.directoryExists('')) return;
    for (final entry in await installed.listDirectory('')) {
      if (!entry.isDirectory) continue;
      if (!prefs.getWappAutostart(entry.name)) continue;
      await start(installed.getAbsolutePath(entry.path));
    }
  }

  /// Keep the BootReceiver's autoStartOnBoot flag in sync with whether the user
  /// has any autostart wapp configured. Written via shared_preferences (same
  /// store the native receiver reads). Call after toggling autostart.
  Future<void> syncBootAutostart([PreferencesService? prefs]) async {
    final p = prefs ?? await PreferencesService.instance();
    await p.setAutoStartOnBoot(p.autostartWappIds().isNotEmpty);
  }

  void _onRunningChanged() {
    // Android: keep the process alive + ticking with the screen off via a
    // native foreground service while any background wapp is live.
    if (_running.isEmpty) {
      AndroidForegroundService.instance.stop();
    } else {
      AndroidForegroundService.instance.start(_running.keys.toList());
    }
  }

  /// Native foreground-service heartbeat (Android): ticks every live engine.
  /// Dart Timers are throttled with the screen off, so the native service
  /// drives this on its own cadence.
  void tickAllFromNative() {
    for (final svc in _running.values) {
      unawaited(svc.tickNow());
    }
  }
}

/// One background wapp engine, run through the shared [BackgroundService]
/// template (TaskMonitor visibility + priority + per-tick CPU + governor).
/// Runs on the main isolate because the wapp HAL touches the shared BLE
/// service (a main-isolate plugin); the governor auto-pauses a runaway tick.
class _WappBackgroundService extends BackgroundService {
  _WappBackgroundService(String name, this.wappDir, this.engine, this.prefs)
      : super(
          id: 'wapp.bg.$name',
          name: name,
          serviceName: 'wapps',
          priority: TaskPriority.normal,
          interval: Duration(milliseconds: engine.tickIntervalMs),
          description: 'Background wapp: $name',
        );

  final String wappDir;
  final WappEngine engine;
  final PreferencesService prefs;

  /// Geo-chat archive for this wapp (shared with the foreground page via the
  /// data dir), so Live messages are persisted even while running headless.
  late final GeoChatArchive _geoArchive =
      GeoChatArchive.forStorage(wappDataStorageFor(prefs, name));

  @override
  Future<void> onStart() async {
    engine.init();
    _drain(); // handle the init outbox (e.g. APRS host.run_command:connect)
  }

  @override
  Future<void> onTick() async {
    engine.tick();
    _drain();
  }

  @override
  Future<void> onStop() async {
    try {
      engine.dispose();
    } catch (_) {}
  }

  /// Process the engine outbox the way the headless context cares about:
  /// re-run self-issued commands (with the user's saved settings), surface
  /// notifications, and ignore all UI-only messages.
  void _drain() {
    for (final raw in engine.drainOutbox()) {
      Map<String, dynamic> data;
      try {
        data = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final type = data['type'] as String? ?? '';
      if (type == 'host.run_command') {
        final cmd = data['command'] as String?;
        if (cmd != null && cmd.isNotEmpty) {
          engine.sendMessage(jsonEncode({'command': cmd, 'fields': _savedFields()}));
          engine.handleEvent();
        }
      } else if (type == 'ui.chat.append') {
        // No UI in the background, but still archive geo-tagged Live messages
        // so an always-on station keeps its history as messages happen.
        final msg = data['message'];
        if ((data['field'] as String? ?? 'messages') == 'geochat') {
          if (msg is Map) _geoArchive.add(msg);
        }
        // Auto-fetch shared media even with no UI: an incoming message carrying
        // a file: token + ih:/pa: hints joins the swarm so the bytes land in the
        // archive regardless of which screen (if any) is foreground.
        if (msg is Map) {
          final mtext = msg['text']?.toString() ?? '';
          final mdir = msg['dir']?.toString() ?? 'in';
          maybeFetchSharedMedia(mtext, mdir, from: msg['from']?.toString());
          // Outgoing shares: publish the bytes to public Blossom so stations on
          // other (NAT'd) networks can fetch them over the internet.
          maybePublishSharedMedia(mtext, mdir);
        }
      } else if (type == 'notify') {
        final levelStr = (data['level'] as String? ?? 'info').toLowerCase();
        final level = switch (levelStr) {
          'success' => NotificationLevel.success,
          'warning' || 'warn' => NotificationLevel.warning,
          'error' || 'err' => NotificationLevel.error,
          _ => NotificationLevel.info,
        };
        NotificationService.instance.show(GeogramNotification(
          level: level,
          title: data['title'] as String? ?? name,
          body: data['body'] as String?,
          source: 'wapp:$name',
          tag: data['tag'] as String?,
          scope: NotificationScope.both,
        ));
        // A background wapp can't render UI, so surface activity as an unread
        // count on its launcher tile (e.g. the APRS app icon). Cleared/reset to
        // the authoritative value when the user opens the wapp.
        WappUnreadService.instance.add(name, 1);
      }
      // ui.* and everything else: no UI in the background — ignore.
    }
  }

  /// The user's last-known settings for this wapp, so the headless engine runs
  /// with their server/radius/etc. instead of bare defaults.
  Map<String, dynamic> _savedFields() {
    final s = prefs.getWappFields(name);
    if (s == null || s.isEmpty) return const {};
    try {
      final m = jsonDecode(s);
      if (m is Map) return m.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {}
    return const {};
  }
}
