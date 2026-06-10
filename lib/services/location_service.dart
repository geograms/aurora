// Device location capability — conditional export (same pattern as
// platform/platform.dart and update_native.dart). Web gets the no-op stub;
// every dart:io target (Android/Linux/Windows/macOS) gets the real
// geolocator-backed implementation.
//
// Backs the synchronous hal_sensor_gps_lat/lon HAL: the service fetches the
// device position asynchronously and CACHES it; the HAL reads the cache (in
// fixed-point degrees × 1e7) without blocking. Coordinates are null until a
// fix arrives (or stay null where there's no GPS / permission), so callers
// fall back to their configured position.
export 'location_service_stub.dart'
    if (dart.library.io) 'location_service_io.dart';
