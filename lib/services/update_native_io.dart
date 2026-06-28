// Native (dart:io) implementation of the Update Center operations: download an
// artifact to disk with progress, and apply it per platform —
//   Android: launch the system package installer (MethodChannel -> FileProvider)
//   Windows: run the Inno Setup installer silently, then quit
//   Linux:   extract the tar.gz, stage an apply-update.sh that swaps the binary
//            + data/lib after we exit, then restart
// Mirrors geogram's flow. Selected on every dart:io target via update_native.dart.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'update_models.dart';

class UpdateNative {
  static const _channel = MethodChannel('com.geogram.aurora/updates');

  static bool get supported => true;

  static Future<String?> supportDir() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/updates');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir.path;
    } catch (e) {
      debugPrint('UpdateNative.supportDir failed: $e');
      return null;
    }
  }

  /// Stream-download [url] to the support dir as [filename], reporting bytes.
  /// Returns the saved path, or null on failure.
  static Future<String?> download(
    String url,
    String filename,
    void Function(int received, int total) onProgress,
  ) async {
    final dir = await supportDir();
    if (dir == null) return null;
    final dest = '$dir/$filename';
    final client = http.Client();
    IOSink? sink;
    try {
      final req = http.Request('GET', Uri.parse(url))
        ..headers['User-Agent'] = 'geogram-aurora-updater';
      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        debugPrint('UpdateNative.download HTTP ${resp.statusCode}');
        return null;
      }
      final total = resp.contentLength ?? 0;
      final file = File(dest);
      sink = file.openWrite();
      var received = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      return dest;
    } catch (e) {
      debugPrint('UpdateNative.download failed: $e');
      try {
        await sink?.close();
      } catch (_) {}
      return null;
    } finally {
      client.close();
    }
  }

  /// Write already-fetched [bytes] (a binary pulled over Reticulum) to the
  /// support dir as [filename], reporting progress, and return the saved path.
  /// The Reticulum transfer streams the whole content into memory first (a
  /// Resource), so this is a single write; we still report 0%->100% for the UI.
  static Future<String?> writeBytes(
    String filename,
    Uint8List bytes,
    void Function(int received, int total) onProgress,
  ) async {
    final dir = await supportDir();
    if (dir == null) return null;
    final dest = '$dir/$filename';
    try {
      onProgress(0, bytes.length);
      await File(dest).writeAsBytes(bytes, flush: true);
      onProgress(bytes.length, bytes.length);
      return dest;
    } catch (e) {
      debugPrint('UpdateNative.writeBytes failed: $e');
      return null;
    }
  }

  /// The device's supported ABIs in preference order (Android Build.SUPPORTED_ABIS),
  /// used to pick the matching per-ABI split APK. Empty on non-Android / on error.
  static Future<List<String>> supportedAbis() async {
    if (!Platform.isAndroid) return const [];
    try {
      final abis = await _channel.invokeMethod<List<dynamic>>('getSupportedAbis');
      return abis?.map((e) => e.toString()).toList() ?? const [];
    } catch (_) {
      return const [];
    }
  }

  static Future<bool> canInstall() async {
    if (!Platform.isAndroid) return true;
    try {
      return (await _channel.invokeMethod<bool>('canInstallPackages')) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openInstallSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openInstallPermissionSettings');
    } catch (_) {}
  }

  static Future<void> apply(UpdatePlatform platform, String path) async {
    switch (platform) {
      case UpdatePlatform.android:
        await _channel.invokeMethod('installApk', {'filePath': path});
        return;
      case UpdatePlatform.windows:
        await _applyWindows(path);
        return;
      case UpdatePlatform.linux:
        await _applyLinux(path);
        return;
      default:
        return;
    }
  }

  static Future<void> _applyWindows(String setupPath) async {
    if (setupPath.toLowerCase().endsWith('.exe')) {
      // Inno Setup installer: close the running app, replace, restart.
      await Process.start(
        setupPath,
        ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'],
        mode: ProcessStartMode.detached,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      exit(0);
    }
  }

  static Future<void> _applyLinux(String tarGzPath) async {
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final stage = Directory('$appDir/.aurora-update');
    if (await stage.exists()) await stage.delete(recursive: true);
    await stage.create(recursive: true);

    // Extract tar.gz (top-level: aurora, data/, lib/).
    final bytes = await File(tarGzPath).readAsBytes();
    final tar = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
    for (final f in tar) {
      final outPath = '${stage.path}/${f.name}';
      if (f.isFile) {
        final of = File(outPath);
        await of.create(recursive: true);
        await of.writeAsBytes(f.content as List<int>);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }

    // Stage the apply script: wait for us to exit, swap files, restart.
    final script = File('${stage.path}/apply-update.sh');
    await script.writeAsString('''#!/usr/bin/env bash
set -e
APPDIR="\$1"; STAGE="\$2"; PID="\$3"
for i in \$(seq 1 60); do kill -0 "\$PID" 2>/dev/null || break; sleep 0.5; done
cp -f "\$STAGE/aurora" "\$APPDIR/aurora" 2>/dev/null || true
[ -d "\$STAGE/data" ] && cp -rf "\$STAGE/data" "\$APPDIR/" || true
[ -d "\$STAGE/lib" ] && cp -rf "\$STAGE/lib" "\$APPDIR/" || true
chmod +x "\$APPDIR/aurora" 2>/dev/null || true
rm -rf "\$STAGE"
nohup "\$APPDIR/aurora" >/dev/null 2>&1 &
''');
    await Process.run('chmod', ['+x', script.path]);
    await Process.start(
      'bash',
      [script.path, appDir, stage.path, '$pid'],
      mode: ProcessStartMode.detached,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(0);
  }

  // Android download foreground service (keeps the download alive when
  // backgrounded + shows a progress notification). No-ops on other platforms.
  static void serviceStart(String text) {
    if (!Platform.isAndroid) return;
    _channel.invokeMethod('startDownloadService', {'text': text}).catchError(
        (_) => null);
  }

  static void serviceProgress(int percent, String status) {
    if (!Platform.isAndroid) return;
    _channel.invokeMethod('updateDownloadProgress',
        {'progress': percent, 'status': status}).catchError((_) => null);
  }

  static void serviceStop() {
    if (!Platform.isAndroid) return;
    _channel.invokeMethod('stopDownloadService').catchError((_) => null);
  }
}
