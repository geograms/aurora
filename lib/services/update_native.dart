// Platform abstraction for the Update Center's native operations — conditional
// export, same pattern as platform/platform.dart. Web gets the no-op stub; every
// dart:io target (Android/Linux/Windows/macOS) gets the real implementation.
export 'update_native_stub.dart'
    if (dart.library.io) 'update_native_io.dart';
