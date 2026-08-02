/*
 * Platform abstraction — native (dart:io) implementation.
 *
 * Selected by `platform.dart` on every target that exposes
 * `dart.library.io`: Linux / macOS / Windows desktop, plus mobile.
 * Web picks up `platform_stubs.dart` instead. Keep the public API
 * of this file byte-identical to the stubs file so the conditional
 * import is a drop-in.
 */

import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel;

import 'platform_stubs.dart' show PlatformProcessResult;

export 'platform_stubs.dart' show PlatformProcessResult;

String currentLocale() {
  try {
    final os = Platform.localeName;
    if (os.isNotEmpty) return os;
  } catch (_) {}
  return 'en';
}

String? homeDir() {
  try {
    return Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'];
  } catch (_) {
    return null;
  }
}

Future<void> showSystemNotification({
  required String title,
  String? body,
  bool error = false,
  String? wapp,
  String? convo,
}) async {
  try {
    if (Platform.isLinux) {
      await Process.run('notify-send', [
        '--app-name=geogram',
        if (error) '--urgency=critical',
        title,
        if (body != null && body.isNotEmpty) body,
      ]);
    } else if (Platform.isMacOS) {
      final escaped = (body ?? '').replaceAll('"', '\\"');
      final titleEsc = title.replaceAll('"', '\\"');
      await Process.run('osascript', [
        '-e',
        'display notification "$escaped" with title "$titleEsc"',
      ]);
    } else if (Platform.isAndroid) {
      // Route to the native foreground-service bridge, which posts a heads-up
      // notification (works while backgrounded / headless from boot). Ids
      // cycle inside 9000..9099 — BgBridge.clearEvents sweeps exactly that
      // range, and the service (7001) / media (7002) ids stay clear of it.
      _androidNotifId = 9000 + ((_androidNotifId - 9000 + 1) % 100);
      await _bgChannel.invokeMethod('notify', {
        'id': _androidNotifId,
        'title': title,
        if (body != null && body.isNotEmpty) 'body': body,
        if (wapp != null && wapp.isNotEmpty) 'wapp': wapp,
        if (convo != null && convo.isNotEmpty) 'convo': convo,
      });
    }
    // Windows native balloon not implemented — use winrt toast later.
  } catch (_) {
    // Ignore — the in-app overlay is the source of truth anyway.
  }
}

/// Remove every event notification this app put in the OS shade. Called when
/// the user reads (or clears) the in-app notification center, so the shade —
/// and the launcher-icon dot it feeds — always agrees with what the user has
/// seen. Android only; desktop notifications are transient toasts already.
Future<void> clearSystemNotifications() async {
  try {
    if (Platform.isAndroid) {
      await _bgChannel.invokeMethod('notify_clear');
    }
  } catch (_) {}
}

// Native bridge for Android system notifications (shared with the foreground
// service). A rolling id so distinct events stack instead of replacing.
const MethodChannel _bgChannel = MethodChannel('com.geogram.aurora/bg_service');
int _androidNotifId = 9000;

bool get supportsSubprocesses => true;

Future<PlatformProcessResult> runSubprocess(
    String executable, List<String> arguments,
    {String? workingDirectory}) async {
  try {
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    return PlatformProcessResult(
      exitCode: result.exitCode,
      stdout: result.stdout?.toString() ?? '',
      stderr: result.stderr?.toString() ?? '',
    );
  } catch (e) {
    return PlatformProcessResult(exitCode: -1, stdout: '', stderr: '$e');
  }
}

String get pathSeparator => Platform.pathSeparator;

/// Canonical OS name used for wapp `platforms` advertisement matching:
/// one of linux/macos/windows/android/ios/fuchsia/unknown (web returns
/// 'web' from the stub).
String platformName() {
  if (Platform.isLinux) return 'linux';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  if (Platform.isFuchsia) return 'fuchsia';
  return 'unknown';
}

String currentDirectory() {
  try {
    return Directory.current.path;
  } catch (_) {
    return '';
  }
}

Future<List<int>?> readArbitraryFileBytes(String path) async {
  try {
    final f = File(path);
    if (!await f.exists()) return null;
    return await f.readAsBytes();
  } catch (_) {
    return null;
  }
}

List<int>? readArbitraryFileBytesSync(String path) {
  try {
    final f = File(path);
    if (!f.existsSync()) return null;
    return f.readAsBytesSync();
  } catch (_) {
    return null;
  }
}

bool arbitraryFileExistsSync(String path) {
  try {
    return File(path).existsSync();
  } catch (_) {
    return false;
  }
}

Future<void> openInFileManager(String path) async {
  try {
    if (Platform.isLinux) {
      await Process.run('xdg-open', [path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [path]);
    } else if (Platform.isWindows) {
      await Process.run('explorer', [path]);
    }
  } catch (_) {
    // Best-effort — caller has no way to recover anyway.
  }
}
