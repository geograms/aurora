import 'dart:async';

import '../platform/platform.dart' as platform;
import '../profile/profile_db.dart';
import '../profile/profile_encryption.dart';
import '../profile/profile_service.dart';
import '../services/log_service.dart';
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
    // would immediately open profile databases and throw. Device-key
    // profiles (the default) unlock silently right here — UI and headless
    // boot alike. Only a password-locked profile stays stopped; the unlock
    // page calls this again after the user types the password.
    final active = ProfileService.instance.activeProfile;
    if (active != null &&
        ProfileKeyring.instance.isEncryptedProfile(active.id) &&
        !ProfileKeyring.instance.isUnlocked(active.id)) {
      final silent = await ProfileEncryption.canUnlockSilently(active.id) &&
          await ProfileEncryption.tryUnlockCached(active.id);
      if (!silent) {
        LogService.instance.add(
            'permissions: profile ${active.id} locked — gated services wait');
        return;
      }
    }
    LogService.instance.add('permissions: granted — starting gated services');

    // Reticulum: brings up the BLE5 interface (scan + advertise).
    startRnsAutostart();

    // Background wapps: Chat scans/advertises over BLE, reads GPS, and runs
    // under a foreground-service notification.
    //
    // Only once the user actually HAS a profile. A device where setup was
    // abandoned half-way (app closed on the welcome/callsign screen) would
    // otherwise autostart engines against a profile that does not exist yet —
    // and on a device where the wasm engine is unusable that turned into a
    // crash loop the user could never escape, because the crash arrived before
    // they could finish setup. Setup first, wapps after.
    if (ProfileService.instance.activeProfile == null) {
      // NOT latched: on a fresh device this runs from the permission intro,
      // which comes BEFORE profile creation. Latching here left that whole
      // session with no wapps — and since Bluetooth only exists because the
      // chat wapp starts it, the device was silently invisible to every peer
      // until the app was restarted.
      LogService.instance
          .add('permissions: no profile yet — wapps wait for setup to finish');
      return;
    }
    _started = true;
    unawaited(BackgroundWappManager.instance.startAutostart());
  }
}
