// Web stub for the native update operations. The Update Center is disabled on
// web (no filesystem / no installer), so these are all no-ops. The io
// implementation lives in update_native_io.dart and is selected via
// update_native.dart's conditional export.

import 'package:flutter/foundation.dart';

import 'update_models.dart';

class UpdateNative {
  static bool get supported => false;

  static Future<String?> supportDir() async => null;

  static Future<String?> download(
    String url,
    String filename,
    void Function(int received, int total) onProgress,
  ) async =>
      null;

  static Future<String?> writeBytes(
    String filename,
    Uint8List bytes,
    void Function(int received, int total) onProgress,
  ) async =>
      null;

  static Future<List<String>> supportedAbis() async => const [];

  static Future<bool> canInstall() async => false;
  static Future<void> openInstallSettings() async {}

  static Future<void> apply(UpdatePlatform platform, String path) async {}

  static void serviceStart(String text) {}
  static void serviceProgress(int percent, String status) {}
  static void serviceStop() {}
}
