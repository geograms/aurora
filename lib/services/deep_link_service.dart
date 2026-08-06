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
import '../wapp/wapp_open.dart';
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
    // geogram://open?wapp=<folder>&convo=<id> — a tapped Android notification.
    // Same opener as the in-app notification center, so both taps land on the
    // same screen: the wapp, on the conversation when one is named.
    if (lower.startsWith('geogram://open')) {
      final uri = Uri.tryParse(url);
      if (uri == null) return;
      await openWappByFolder(
        uri.queryParameters['wapp'] ?? '',
        convo: uri.queryParameters['convo'],
        navigator: rootNavigatorKey.currentState,
      );
      return;
    }
    final target = await _wappForLink(url);
    if (target == null) {
      LogService.instance
          .add('DeepLink: no installed wapp claims $url');
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
        wappDir: target.dir,
        title: target.title,
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

  /// The installed wapp that claims this link, or null.
  ///
  /// A wapp declares what it opens in its own manifest, the same way it
  /// declares file handlers and view intents:
  ///
  ///     "provides": { "links": ["/circle/", "geogram://circle"] }
  ///
  /// The core matches and routes; it does not know that circles exist. Naming
  /// a wapp here would put one application's routing table inside the core,
  /// and the next feature would add a second (docs/architecture.md §3).
  Future<_LinkTarget?> _wappForLink(String url) async {
    final lower = url.toLowerCase();
    final installed = installedAppsStorage();
    if (!await installed.directoryExists('')) return null;
    for (final e in await installed.listDirectory('')) {
      if (!e.isDirectory) continue;
      try {
        final pkg = wappPackageStorage(installed.getAbsolutePath(e.path));
        final m = await pkg.readJson('manifest.json');
        if (m == null) continue;
        final provides = m['provides'];
        final links = (provides is Map) ? provides['links'] : null;
        if (links is! List) continue;
        for (final raw in links) {
          final pat = raw.toString().trim().toLowerCase();
          if (pat.isEmpty || !lower.contains(pat)) continue;
          final title = (m['title'] ?? m['name'] ?? e.name).toString();
          return _LinkTarget(pkg.basePath, title);
        }
      } catch (_) {}
    }
    // Fallback for wapps installed before they declared `provides.links`:
    // match the link's own subject word against the wapp's identity —
    // "geogram://circle/…" -> a wapp called circles. Derived from the URL, so
    // the core still names no application (docs/architecture.md §3). Drops out
    // once installed copies carry the declaration.
    final subject = _linkSubject(lower);
    if (subject.isEmpty) return null;
    for (final e in await installed.listDirectory('')) {
      if (!e.isDirectory) continue;
      try {
        final pkg = wappPackageStorage(installed.getAbsolutePath(e.path));
        final m = await pkg.readJson('manifest.json');
        if (m == null) continue;
        final hay = '${m['id'] ?? ''} ${m['name'] ?? ''} ${m['title'] ?? ''} '
                '${e.name}'
            .toLowerCase();
        if (!hay.contains(subject)) continue;
        final title = (m['title'] ?? m['name'] ?? e.name).toString();
        return _LinkTarget(pkg.basePath, title);
      } catch (_) {}
    }
    return null;
  }
}

/// The word a geogram link is about: the first path segment after the scheme
/// or host ("geogram://circle/ab12" and "https://x.y/circle/ab12" -> "circle").
String _linkSubject(String lowerUrl) {
  final u = Uri.tryParse(lowerUrl);
  if (u == null) return '';
  final segs = [
    if (u.host.isNotEmpty && u.scheme == 'geogram') u.host,
    ...u.pathSegments,
  ].where((s) => s.isNotEmpty).toList();
  return segs.isEmpty ? '' : segs.first;
}

/// An installed wapp that claims a link, and the title to show while it opens.
class _LinkTarget {
  const _LinkTarget(this.dir, this.title);
  final String dir;
  final String title;
}
