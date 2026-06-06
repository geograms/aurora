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

  bool get _supported => !kIsWeb && Platform.isAndroid;
  bool get isRunning => _running;

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'onTick') {
      // Native heartbeat — advance every live background engine.
      BackgroundWappManager.instance.tickAllFromNative();
    }
    return null;
  }

  /// Start (or update the notification text of) the foreground service.
  Future<void> start(List<String> wappNames) async {
    if (!_supported) return;
    final label = wappNames.isEmpty
        ? 'Running in background'
        : '${wappNames.join(', ')} running in background';
    try {
      await _channel.invokeMethod('start', {'text': label});
      _running = true;
    } catch (e) {
      debugPrint('AndroidForegroundService: start failed: $e');
    }
  }

  Future<void> stop() async {
    if (!_supported || !_running) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      debugPrint('AndroidForegroundService: stop failed: $e');
    }
    _running = false;
  }
}
