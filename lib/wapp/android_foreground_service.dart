/*
 * Android foreground-service bridge.
 *
 * Keeps the app process alive (with a persistent notification) while one or
 * more wapps run in the background, so BLE/APRS-IS receive keeps working with
 * the screen off / app backgrounded. The native service also drives a periodic
 * heartbeat via the method channel ('onTick'), because Dart Timers are
 * throttled in the background while a native Handler is not — see
 * BackgroundWappManager.tickAllFromNative.
 *
 * No-op on every non-Android platform (desktop keeps the process alive anyway).
 */

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart';

import 'background_wapp_manager.dart';

class AndroidForegroundService {
  AndroidForegroundService._() {
    if (_supported) _channel.setMethodCallHandler(_onCall);
  }
  static final AndroidForegroundService instance = AndroidForegroundService._();

  static const _channel = MethodChannel('com.geogram.aurora/bg_service');
  bool _running = false;

  // Ref-counted holders. The native foreground service is started when the
  // first holder appears and stopped only when the last one is released, so
  // several subsystems (background wapps, the Reticulum node) can each keep the
  // process alive independently without stomping on each other.
  final Set<String> _holders = {};
  String? _wappLabel; // label contributed by the 'wapps' holder

  bool get _supported => !kIsWeb && Platform.isAndroid;
  bool get isRunning => _running;

  /// Set by the wapp page that currently owns media playback; the native
  /// MediaSession routes lock-screen / notification button presses here.
  void Function(String action)? onMediaAction;

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'onTick') {
      // Native heartbeat — advance every live background engine.
      BackgroundWappManager.instance.tickAllFromNative();
    } else if (call.method == 'media.action') {
      final action = (call.arguments is Map)
          ? (call.arguments['action']?.toString() ?? '')
          : call.arguments?.toString() ?? '';
      if (action.isNotEmpty) onMediaAction?.call(action);
    }
    return null;
  }

  /// Push the current media-session state to the native MediaSession so the
  /// lock-screen / notification panel shows it with transport controls.
  Future<void> mediaUpdate(Map<String, dynamic> info) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('media.update', info);
    } catch (e) {
      debugPrint('AndroidForegroundService: media.update failed: $e');
    }
  }

  /// Tear down the media notification/session (playback stopped).
  Future<void> mediaStop() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('media.stop');
    } catch (e) {
      debugPrint('AndroidForegroundService: media.stop failed: $e');
    }
  }

  String _composeLabel() {
    final parts = <String>[];
    if (_holders.contains('reticulum')) parts.add('Reticulum node');
    if (_wappLabel != null && _wappLabel!.isNotEmpty) parts.add(_wappLabel!);
    return parts.isEmpty
        ? 'Running in background'
        : '${parts.join(', ')} running in background';
  }

  Future<void> _sync() async {
    if (!_supported) return;
    try {
      if (_holders.isNotEmpty) {
        // 'start' both starts the service and updates the notification text.
        await _channel.invokeMethod('start', {'text': _composeLabel()});
        _running = true;
      } else if (_running) {
        await _channel.invokeMethod('stop');
        _running = false;
      }
    } catch (e) {
      debugPrint('AndroidForegroundService: sync failed: $e');
    }
  }

  /// Add a named holder; starts the service if it wasn't running.
  Future<void> hold(String reason) async {
    _holders.add(reason);
    await _sync();
  }

  /// Release a named holder; stops the service when no holders remain.
  Future<void> release(String reason) async {
    _holders.remove(reason);
    await _sync();
  }

  /// Background-wapp holder: start (or refresh the label of) the service for the
  /// given running wapps. Releasing happens via [stop].
  Future<void> start(List<String> wappNames) async {
    _wappLabel = wappNames.isEmpty ? null : wappNames.join(', ');
    await hold('wapps');
  }

  /// Release the background-wapp holder (the service stays up if e.g. the
  /// Reticulum node still holds it).
  Future<void> stop() async {
    _wappLabel = null;
    await release('wapps');
  }

  /// Post a heads-up Android notification for a message/event. No-op off Android.
  Future<void> notify({
    required int id,
    required String title,
    String? body,
  }) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('notify', {
        'id': id,
        'title': title,
        if (body != null) 'body': body,
      });
    } catch (e) {
      debugPrint('AndroidForegroundService: notify failed: $e');
    }
  }

}
