// Platform detection for the Update Center. Split out of update_models.dart so
// the release models / folder adapter stay pure Dart (no Flutter), while this
// one helper uses Flutter's target-platform detection.

import 'package:flutter/foundation.dart';

import 'update_models.dart';

UpdatePlatform currentUpdatePlatform() {
  if (kIsWeb) return UpdatePlatform.unknown;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return UpdatePlatform.android;
    case TargetPlatform.linux:
      return UpdatePlatform.linux;
    case TargetPlatform.windows:
      return UpdatePlatform.windows;
    case TargetPlatform.macOS:
      return UpdatePlatform.macos;
    default:
      return UpdatePlatform.unknown;
  }
}
