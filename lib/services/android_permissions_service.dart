/*
 * Android runtime permission requests, modelled on geogram's
 * BLEPermissionService. Aurora needs BLE (scan/connect/advertise) for
 * APRS-over-BLE, location (some devices gate BLE scanning on it), and
 * notifications. These are requested up front from the onboarding panel
 * (see PermissionsIntroPage) so the BLE transport works once a wapp turns
 * it on. No-op on non-Android platforms.
 */

import 'package:permission_handler/permission_handler.dart';

import '../platform/platform.dart' as platform;
import 'log_service.dart';

class AndroidPermissionsService {
  AndroidPermissionsService._();
  static final AndroidPermissionsService instance = AndroidPermissionsService._();

  /// Items shown in the intro panel. `request` marks the ones that trigger a
  /// runtime dialog; Internet is install-time (no runtime prompt) and listed
  /// for information only.
  static const List<({String title, String desc, bool request})> items = [
    (
      title: 'Bluetooth',
      desc: 'Exchange APRS messages directly with nearby devices',
      request: true,
    ),
    (
      title: 'Internet',
      desc: 'Connect to APRS-IS and the wapp store (granted automatically)',
      request: false,
    ),
  ];

  bool get _isAndroid => platform.platformName() == 'android';

  /// The BLE runtime permissions we actually request.
  static const List<Permission> _required = [
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.bluetoothAdvertise,
  ];

  /// True when every required runtime permission is already granted (no prompt
  /// shown). Off Android there are no runtime permissions, so always true.
  /// Used to decide whether the intro panel is needed at all.
  Future<bool> allGranted() async {
    if (!_isAndroid) return true;
    try {
      for (final p in _required) {
        if (!(await p.status).isGranted) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Request the runtime permissions Aurora needs (Android 12+ BLE: scan,
  /// connect, advertise). Safe to call repeatedly — already-granted ones
  /// resolve immediately. No-op off Android. (No device-location request:
  /// the manifest scans with neverForLocation and Aurora uses the map
  /// pinpoint, not GPS.)
  Future<void> requestAll() async {
    if (!_isAndroid) return;
    try {
      final result = await _required.request();
      result.forEach((perm, status) =>
          LogService.instance.add('Permission $perm: ${status.name}'));
    } catch (e) {
      LogService.instance.add('AndroidPermissions: request failed: $e');
    }
  }
}
