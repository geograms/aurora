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

import 'package:geolocator/geolocator.dart';
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

  /// Nice-to-have, not a blocker: offered here (so the prompt happens HERE and
  /// not later, mid-app) but the user can leave the intro without it.
  final bool optional;

  /// This item also needs the system-wide LOCATION SERVICES switch, not just
  /// its runtime permission. Granting the permission while the switch is off
  /// still leaves BLE scanning dead, so the item stays un-granted and its
  /// request opens the location settings screen.
  final bool needsLocationServices;

  const AppPermission({
    required this.key,
    required this.title,
    required this.desc,
    required this.icon,
    this.perms = const [],
    this.info = false,
    this.special = false,
    this.optional = false,
    this.needsLocationServices = false,
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
      key: 'nearby_wifi',
      title: 'Nearby WiFi devices',
      desc: 'Move large files between nearby devices over a direct WiFi link '
          '(much faster than Bluetooth)',
      icon: 'wifi',
      perms: [Permission.nearbyWifiDevices],
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
      key: 'location',
      title: 'Location',
      desc: 'Required by Android to find nearby devices over Bluetooth — with '
          'location switched off the system returns no scan results at all, so '
          'the app goes silently deaf. Also puts your position on the map.',
      icon: 'location',
      perms: [Permission.locationWhenInUse],
      // NOT optional, however much it looks like a privacy nicety: Android
      // withholds every BLE scan result while the location master switch is
      // off, whatever the app declares. A tablet in that state advertised,
      // scanned, and heard literally nothing for hours while reporting itself
      // healthy. The permission alone is not enough either — see
      // [locationServicesOn], which this item's status also requires.
      needsLocationServices: true,
    ),
    AppPermission(
      key: 'battery',
      title: 'Run in the background',
      desc: 'Let the app keep receiving messages when the screen is off — '
          'Android otherwise puts it to sleep',
      icon: 'battery',
      perms: [Permission.ignoreBatteryOptimizations],
      special: true,
      // Optional: it must not trap a user behind a disabled Continue. But it is
      // offered HERE so the prompt lands with the others instead of ambushing
      // the user right after they pick a callsign, which is what it used to do.
      optional: true,
    ),
    AppPermission(
      key: 'internet',
      title: 'Internet',
      desc: 'Connect to the internet relays and the wapp store (automatic)',
      icon: 'wifi',
      info: true,
    ),
  ];

  /// Items that BLOCK leaving the intro (excludes informational + optional rows).
  List<AppPermission> get required =>
      [for (final i in items) if (!i.info && !i.optional) i];

  /// Every item the user can actually grant — including the optional ones, so
  /// "Grant all" offers them too. Nothing here may be requested outside the
  /// intro; that is the whole contract of this screen.
  List<AppPermission> get grantable => [for (final i in items) if (!i.info) i];

  /// Live grant status of one item (true when all its perms are granted).
  /// Informational items are always "granted". Always true off Android.
  Future<bool> isGranted(AppPermission item) async {
    if (!_isAndroid || item.info) return true;
    try {
      for (final p in item.perms) {
        if (!(await p.status).isGranted) return false;
      }
      if (item.needsLocationServices && !await locationServicesOn()) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The system-wide location switch (Settings → Location), not the app's
  /// permission. Android returns ZERO BLE scan results while it is off, so this
  /// is a hard requirement for finding anyone over Bluetooth.
  Future<bool> locationServicesOn() async {
    if (!_isAndroid) return true;
    try {
      // HARD timeout. This is a platform-channel call, and PermissionGate.ready
      // consults it from a BOOT TASK that runs before runApp() — where the
      // plugin side is not necessarily answering yet. Without the timeout the
      // future never completed, boot never finished, and both devices sat on a
      // blank splash forever after a reboot. Never block the app on a probe.
      return await Geolocator.isLocationServiceEnabled()
          .timeout(const Duration(seconds: 2), onTimeout: () => true);
    } catch (_) {
      return true; // unknown: never block on a failed probe
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
      if (item.needsLocationServices && !await locationServicesOn()) {
        // The permission is granted but the master switch is off — only the
        // settings screen can fix that, and the panel re-checks on resume.
        LogService.instance.add(
            'permissions: location services are off — opening location settings');
        await Geolocator.openLocationSettings();
      }
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
    for (final i in grantable) {
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
