/*
 * openFolderOnDisk — reveal a real directory in the OS file manager so the user
 * can add/rename/delete files directly on disk (the owner workflow for shared
 * disk folders; changes are picked up by the periodic re-scan / Rescan).
 *
 * Android: a MethodChannel into MainActivity maps the path to a Documents-UI
 * directory URI and ACTION_VIEWs it. Desktop: xdg-open / open / explorer.
 */
import 'dart:io';

import 'package:flutter/services.dart';

const MethodChannel _ch = MethodChannel('com.geogram.aurora/updates');

/// Hand ONE file to whatever the system uses to view it: a photo to the gallery,
/// a PDF to a reader, an APK to the package installer, a video to a player.
///
/// Android goes through the same FileProvider the updater already uses (a raw
/// `file://` URI is refused since API 24), with the mime guessed from the
/// extension so the chooser is not empty. Desktop is xdg-open / open / start.
Future<bool> openFileWithSystem(String path) async {
  if (path.isEmpty || !File(path).existsSync()) return false;
  if (Platform.isAndroid) {
    try {
      return (await _ch.invokeMethod<bool>('openFile', {'path': path})) ?? false;
    } catch (_) {
      return false;
    }
  }
  try {
    final exe = Platform.isMacOS
        ? 'open'
        : Platform.isWindows
            ? 'explorer'
            : 'xdg-open';
    final r = await Process.run(exe, [path]);
    return Platform.isWindows || r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<bool> openFolderOnDisk(String path) async {
  if (path.isEmpty) return false;
  if (Platform.isAndroid) {
    try {
      return (await _ch.invokeMethod<bool>('openFolder', {'path': path})) ?? false;
    } catch (_) {
      return false;
    }
  }
  try {
    final exe = Platform.isMacOS
        ? 'open'
        : Platform.isWindows
            ? 'explorer'
            : 'xdg-open';
    final r = await Process.run(exe, [path]);
    // explorer.exe returns 1 even on success; treat a launch as success there.
    return Platform.isWindows || r.exitCode == 0;
  } catch (_) {
    return false;
  }
}
