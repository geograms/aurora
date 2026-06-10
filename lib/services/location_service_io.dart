// geolocator-backed device location for the hal_sensor_gps_* HAL.
//
// Fetches the current position once (and then follows updates) on first use,
// caching the latest lat/lon. The HAL reads the cache synchronously as
// fixed-point degrees × 1e7. Any failure (no GPS, denied permission, no
// platform plugin — e.g. desktop Linux) leaves the cache null so callers fall
// back to their configured position.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:geolocator/geolocator.dart';

class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  double? _lat;
  double? _lon;
  bool _started = false;
  StreamSubscription<Position>? _sub;

  /// Latest fix as fixed-point degrees × 1e7 (fits int32 for ±90/±180), or
  /// null when there is no fix.
  int? get latE7 => _lat == null ? null : (_lat! * 1e7).round();
  int? get lonE7 => _lon == null ? null : (_lon! * 1e7).round();

  /// Kick off permission + position acquisition once. Fire-and-forget — the
  /// synchronous HAL just reads whatever is cached so far.
  void ensureStarted() {
    if (_started) return;
    _started = true;
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }
      try {
        _set(await Geolocator.getCurrentPosition());
      } catch (_) {
        // No immediate fix — the stream below may still deliver one.
      }
      _sub = Geolocator.getPositionStream().listen(_set, onError: (_) {});
    } catch (e) {
      // No location plugin on this platform (desktop Linux has none) or some
      // other failure — leave coords null so callers fall back.
      debugPrint('LocationService: unavailable: $e');
    }
  }

  void _set(Position p) {
    _lat = p.latitude;
    _lon = p.longitude;
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
