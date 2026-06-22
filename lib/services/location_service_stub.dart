// Web / no-dart:io stub for LocationService — no device GPS available.
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  /// No-op; there is no platform location source here.
  void ensureStarted() {}

  /// Always unavailable.
  int? get latE7 => null;
  int? get lonE7 => null;

  /// No device GPS on web — always null.
  Future<({double lat, double lon})?> currentPosition() async => null;
}
