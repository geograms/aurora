/*
 * Battery-optimization (Doze) exemption — Android only.
 *
 * An always-on station needs the foreground service (and with it the APRS-IS
 * connection + Blossom/BitTorrent seed servers) to survive deep sleep. On
 * aggressive OEMs the OS kills an un-exempted backgrounded app despite the
 * foreground service, so we ask the user to whitelist us. Verified on a TANK
 * rugged phone: exempt + WiFi-lock → the app stays alive and LAN-reachable
 * while asleep; un-exempt → it gets killed in deep sleep.
 *
 * Talks to MainActivity over the existing updates method channel.
 */
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class BatteryOptimization {
  static const _channel = MethodChannel('com.geogram.aurora/updates');

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// True if we're exempt from battery optimization (or not on Android).
  static Future<bool> isExempt() async {
    if (!_android) return true;
    try {
      return await _channel
              .invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          true;
    } catch (_) {
      return true;
    }
  }

  /// Show the system "ignore battery optimizations" prompt if we're not already
  /// exempt. No-op off Android or when already exempt. Needs the Activity, so
  /// call it from the foreground (e.g. the launcher).
  static Future<void> requestExemption() async {
    if (!_android) return;
    try {
      if (await isExempt()) return;
      await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }
}
