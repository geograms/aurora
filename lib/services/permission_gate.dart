import 'dart:async';

import '../platform/platform.dart' as platform;
import '../profile/profile_db.dart';
import '../profile/profile_encryption.dart';
import '../profile/profile_service.dart';
import '../services/log_service.dart';
import '../services/notification_service.dart';
import '../services/reticulum/rns_autostart.dart';
import '../wapp/background_wapp_manager.dart';
import 'android_permissions_service.dart';

/// The gate between "the app has booted" and "the app may touch anything the
/// user has not consented to yet".
///
/// On Android, the OS throws its own permission dialog the moment you touch a
/// guarded API — BLE scan/advertise, GPS, a foreground-service notification.
/// The boot orchestrator runs BEFORE runApp(), so services started there fired
/// those dialogs at a user who had been told nothing, *before our own
/// permissions intro had even rendered*. Creating a profile then started the
/// same services and produced a second wave of prompts, this time after the
/// callsign screen. Both are the same bug: a service reaching for a permission
/// on its own schedule instead of ours.
///
/// So every service that can trigger a system prompt starts HERE, and only
/// once [ready] is true. The intro screen is then the single place a permission
/// dialog can come from, which is the whole point of having an intro screen.
///
/// Non-Android platforms have no runtime prompts, so the gate is always open.
class PermissionGate {
  PermissionGate._();

  static bool _started = false;

  static bool _lockedNotified = false;

  /// One system notification per locked boot, Android only: on desktop the
  /// unlock page is already on screen, but a headless engine has no UI at
  /// all — the notification is the only sign that messages are NOT being
  /// received until the user opens Aurora and unlocks.
  static void _notifyLockedOnce() {
    if (_lockedNotified) return;
    if (platform.platformName() != 'android') return;
    _lockedNotified = true;
    NotificationService.instance.show(GeogramNotification(
      level: NotificationLevel.warning,
      title: 'Aurora is locked',
      body: 'Open Aurora and unlock your profile to receive messages in '
          'the background.',
      source: 'host:encryption',
      scope: NotificationScope.system,
    ));
  }

  /// True when it is safe to start the permission-guarded services: always on
  /// desktop, and on Android only once every required permission is granted
  /// (which is exactly when the intro screen lets the user leave).
  static Future<bool> get ready async {
    if (platform.platformName() != 'android') return true;
    return AndroidPermissionsService.instance.allGranted();
  }

  /// Start everything that can raise an Android permission dialog. Idempotent —
  /// boot calls it when permissions are already granted (the returning user),
  /// and the intro screen calls it on completion (the new user). Whichever
  /// comes first wins; the second call is a no-op.
  static Future<void> startGatedServices() async {
    if (_started) return;
    // Encrypted profile that has not been unlocked yet: the gated services
    // would immediately open profile databases and throw. Try the
    // "keep unlocked on this device" cache first — that is what lets the
    // headless Android boot (BOOT_COMPLETED → BgService → main() with no
    // UI) come up with background message reception. No cache → stay
    // stopped; the unlock page calls this again after unlocking, and a
    // headless engine surfaces one system notification instead.
    final active = ProfileService.instance.activeProfile;
    if (active != null &&
        ProfileKeyring.instance.isEncryptedProfile(active.id) &&
        !ProfileKeyring.instance.isUnlocked(active.id)) {
      final silent = await ProfileEncryption.canUnlockSilently(active.id) &&
          await ProfileEncryption.tryUnlockCached(active.id);
      if (!silent) {
        LogService.instance.add(
            'permissions: profile ${active.id} locked — gated services wait');
        _notifyLockedOnce();
        return;
      }
    }
    _started = true;
    LogService.instance.add('permissions: granted — starting gated services');
    _lockedNotified = false;

    // Reticulum: brings up the BLE5 interface (scan + advertise).
    startRnsAutostart();

    // Background wapps: Chat scans/advertises over BLE, reads GPS, and runs
    // under a foreground-service notification.
    unawaited(BackgroundWappManager.instance.startAutostart());
  }
}
