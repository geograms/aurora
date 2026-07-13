/*
 * Fingerprint / face unlock for an encrypted profile.
 *
 * The profile's secret lives in the OS keychain (device_key_store.dart), so
 * the biometric prompt is not what decrypts the data — it is what decides
 * whether THIS person may have it. That is the same bargain every phone app
 * with a keychain makes, and it is what lets a profile be encrypted by
 * default without a password step at onboarding.
 *
 * No biometric hardware enrolled (or a desktop): the gate is open — the key
 * cache alone unlocks, exactly as before. A user who wants a real secret
 * they carry in their head adds a password in the profile page.
 */

import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../services/log_service.dart';

class BiometricGate {
  BiometricGate._();
  static final BiometricGate instance = BiometricGate._();

  final LocalAuthentication _auth = LocalAuthentication();

  /// Whether this device can actually ask (hardware + at least one
  /// enrolled fingerprint/face).
  Future<bool> get available async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      final enrolled = await _auth.getAvailableBiometrics();
      return enrolled.isNotEmpty;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Ask. Returns true when the user proved themselves, false when they
  /// cancelled or failed. When the device cannot ask at all this returns
  /// true — there is nothing to gate with, and refusing would lock the
  /// user out of their own profile.
  Future<bool> authenticate({String reason = 'Unlock your profile'}) async {
    if (!await available) return true;
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // Device PIN/pattern is an acceptable fallback: the point is "is this
        // the phone's owner", not "is this a fingerprint".
        biometricOnly: false,
        // The OS backgrounds the app while it shows the prompt; retry rather
        // than failing the unlock.
        persistAcrossBackgrounding: true,
      );
    } on PlatformException catch (e) {
      LogService.instance.add('biometric: ${e.code} ${e.message ?? ''}');
      // A device that suddenly cannot prompt must not brick the profile.
      return false;
    } catch (_) {
      return false;
    }
  }
}
