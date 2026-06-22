/*
 * Deep links — Android only (for now).
 *
 * Tapping a https://geogram.radio/circle/<key> link (or the geogram://circle/<key>
 * fallback) opens Aurora straight on the circles wapp's "apply to join" flow.
 * MainActivity captures the launch URI and pushes later ones over the
 * `com.geogram.aurora/links` method channel; we resolve the circles wapp and
 * push its WappPage with an `apply_url` initial command carrying the full link.
 *
 * The wapp parses the circle id back out of the URL (full key, authoritative) so
 * a brand-new applicant can join a circle they've never seen. The short code in
 * the path is human shorthand only and needs a directory to resolve — the link
 * always carries the full key.
 */
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../launcher/launcher.dart' show rootNavigatorKey;
import '../profile/storage_paths.dart';
import '../wapp/wapp_page.dart';
import 'log_service.dart';

class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  static const _channel = MethodChannel('com.geogram.aurora/links');

  bool _started = false;

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Wire the channel and process the link this session was launched with.
  /// Safe to call once after the navigator is live.
  Future<void> start() async {
    if (_started || !_supported) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onLink') {
        final link = call.arguments as String?;
        if (link != null) await _handle(link);
      }
      return null;
    });
    try {
      final initial = await _channel.invokeMethod<String>('getInitialLink');
      if (initial != null && initial.isNotEmpty) await _handle(initial);
    } catch (_) {}
  }

  Future<void> _handle(String url) async {
    LogService.instance.add('DeepLink: $url');
    final lower = url.toLowerCase();
    // Only circle links are handled today.
    if (!lower.contains('/circle/') && !lower.startsWith('geogram://circle')) {
      return;
    }
    final dir = await _circlesWappDir();
    if (dir == null) {
      LogService.instance.add('DeepLink: circles wapp not installed');
      return;
    }
    final nav = rootNavigatorKey.currentState;
    if (nav == null) {
      LogService.instance.add('DeepLink: no navigator');
      return;
    }
    final cmd = jsonEncodeCommand(url);
    await nav.push(MaterialPageRoute(
      builder: (_) => WappPage(
        wappDir: dir,
        title: 'Circles',
        initialCommand: cmd,
      ),
    ));
  }

  /// JSON the circles wapp understands: an `apply_url` command carrying the
  /// full link, from which it extracts the circle id and starts the join flow.
  static String jsonEncodeCommand(String url) =>
      '{"command":"apply_url","code":${_jsonString(url)}}';

  static String _jsonString(String s) {
    final b = StringBuffer('"');
    for (final r in s.runes) {
      switch (r) {
        case 0x22:
          b.write('\\"');
        case 0x5C:
          b.write('\\\\');
        case 0x0A:
          b.write('\\n');
        case 0x0D:
          b.write('\\r');
        case 0x09:
          b.write('\\t');
        default:
          if (r < 0x20) {
            b.write('\\u${r.toRadixString(16).padLeft(4, '0')}');
          } else {
            b.writeCharCode(r);
          }
      }
    }
    b.write('"');
    return b.toString();
  }

  /// Locate the installed circles wapp package directory, or null.
  Future<String?> _circlesWappDir() async {
    final installed = installedAppsStorage();
    if (!await installed.directoryExists('')) return null;
    for (final e in await installed.listDirectory('')) {
      if (!e.isDirectory) continue;
      try {
        final pkg = wappPackageStorage(installed.getAbsolutePath(e.path));
        final m = await pkg.readJson('manifest.json');
        if (m == null) continue;
        final id = (m['id'] ?? '').toString();
        final name = (m['name'] ?? '').toString();
        if (id == 'tools.geogram.circles' ||
            name == 'circles' ||
            e.name == 'circles') {
          return pkg.basePath;
        }
      } catch (_) {}
    }
    return null;
  }
}
