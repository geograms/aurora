/*
 * Android runtime permission requests, modelled on geogram's
 * BLEPermissionService. Aurora needs BLE (scan/connect/advertise) for the
 * street mesh + APRS-over-BLE, notifications for background message alerts,
 * and broad file access for the encrypted identity backup that survives an
 * uninstall (restore-on-reinstall).
 *
 * ALL of these are requested up front from the onboarding panel
 * (PermissionsIntroPage), which does not let the user proceed to profile
 * creation until every required permission is granted — nothing should
 * surface a late prompt after the profile exists. No-op on non-Android.
 */

import 'package:permission_handler/permission_handler.dart';

import '../platform/platform.dart' as platform;
import 'log_service.dart';

/// One onboarding permission the user must grant, with live status.
class AppPermission {
  final String key; // stable id
  final String title;
  final String desc;
  final String icon; // material icon name (resolved by the UI)
  final List<Permission> perms; // all must be granted for this item to be "on"
  final bool info; // true = install-time / informational (never a prompt)
  /// Special-access permissions (e.g. All-files) open a SYSTEM SETTINGS screen
  /// instead of an inline dialog; the panel re-checks status on app resume.
  final bool special;

  const AppPermission({
    required this.key,
    required this.title,
    required this.desc,
    required this.icon,
    this.perms = const [],
    this.info = false,
    this.special = false,
  });
}

class AndroidPermissionsService {
  AndroidPermissionsService._();
  static final AndroidPermissionsService instance =
      AndroidPermissionsService._();

  bool get _isAndroid => platform.platformName() == 'android';

  /// The onboarding permission list, in display order. Every non-[info] item
  /// must be granted before the user can leave the intro.
  static const List<AppPermission> items = [
    AppPermission(
      key: 'bluetooth',
      title: 'Bluetooth',
      desc: 'Discover nearby devices and exchange messages over the mesh',
      icon: 'bluetooth',
      perms: [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
      ],
    ),
    AppPermission(
      key: 'notifications',
      title: 'Notifications',
      desc: 'Alert you when a message arrives while the app is in the background',
      icon: 'notifications',
      perms: [Permission.notification],
    ),
    AppPermission(
      key: 'storage',
      title: 'Storage',
      desc: 'Keep an encrypted backup of your identity so it survives a '
          'reinstall, and share files',
      icon: 'folder',
      perms: [Permission.manageExternalStorage],
      special: true,
    ),
    AppPermission(
      key: 'internet',
      title: 'Internet',
      desc: 'Connect to the internet relays and the wapp store (automatic)',
      icon: 'wifi',
      info: true,
    ),
  ];

  /// Items that require an actual grant (excludes informational rows).
  List<AppPermission> get required => [for (final i in items) if (!i.info) i];

  /// Live grant status of one item (true when all its perms are granted).
  /// Informational items are always "granted". Always true off Android.
  Future<bool> isGranted(AppPermission item) async {
    if (!_isAndroid || item.info) return true;
    try {
      for (final p in item.perms) {
        if (!(await p.status).isGranted) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// True when a permission was denied with "don't ask again" — a plain
  /// request() then no-ops, so the panel must send the user to app settings.
  Future<bool> isPermanentlyDenied(AppPermission item) async {
    if (!_isAndroid || item.info) return false;
    try {
      for (final p in item.perms) {
        if ((await p.status).isPermanentlyDenied) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Request one item's permissions. Special-access items (All-files) open the
  /// system settings screen; the caller re-checks status on app resume.
  /// Returns the resulting granted state.
  Future<bool> requestItem(AppPermission item) async {
    if (!_isAndroid || item.info) return true;
    try {
      if (await isPermanentlyDenied(item)) {
        // A prior "don't ask again" — the only path left is app settings.
        await openAppSettings();
        return isGranted(item);
      }
      final result = await item.perms.request();
      result.forEach((perm, status) =>
          LogService.instance.add('Permission $perm: ${status.name}'));
      return isGranted(item);
    } catch (e) {
      LogService.instance.add('AndroidPermissions: ${item.key} request failed: $e');
      return false;
    }
  }

  /// True when every required item is granted. Off Android always true (no
  /// runtime permissions), so the onboarding panel is skipped there.
  Future<bool> allGranted() async {
    if (!_isAndroid) return true;
    for (final i in required) {
      if (!await isGranted(i)) return false;
    }
    return true;
  }

  /// Request every required permission in sequence (each shows its own system
  /// dialog / settings screen). Used by the intro panel's "Grant all" button.
  Future<void> requestAll() async {
    if (!_isAndroid) return;
    for (final i in required) {
      if (!await isGranted(i)) await requestItem(i);
    }
  }

  // ── Legacy helpers kept for existing callers (profile backup, disk folders).

  Future<bool> hasAllFilesAccess() async {
    if (!_isAndroid) return true;
    try {
      return (await Permission.manageExternalStorage.status).isGranted;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestAllFilesAccess() async {
    if (!_isAndroid) return true;
    try {
      final s = await Permission.manageExternalStorage.request();
      LogService.instance.add('Permission manageExternalStorage: ${s.name}');
      return s.isGranted;
    } catch (e) {
      LogService.instance
          .add('AndroidPermissions: all-files request failed: $e');
      return false;
    }
  }
}
