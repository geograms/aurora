/*
 * Update models — release feed shapes for the in-app Update Center.
 *
 * The app pulls releases from a self-hosted feed at https://geogram.radio
 * (no github.com runtime dependency — app-store friendly): a stable channel
 * (updates/stable.json) and a beta channel (updates/beta.json). Each is a
 * single JSON object with version metadata + an `assets` array. Artifacts
 * follow the `aurora-*` naming the build pipeline produces.
 *
 * ReleaseInfo.fromGitHub is retained so a custom feed URL can still point at
 * the GitHub releases API if ever needed, but it is not used by default.
 */

import 'package:flutter/foundation.dart';

enum UpdateChannel { stable, beta }

enum UpdatePlatform { android, linux, windows, macos, unknown }

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

/// One downloadable file attached to a GitHub release.
class ReleaseAsset {
  final String name;
  final String url; // browser_download_url
  final int size;
  const ReleaseAsset({required this.name, required this.url, required this.size});
}

/// A parsed GitHub release.
class ReleaseInfo {
  final String version; // tag without leading 'v' (e.g. "1.2.3")
  final String tagName; // e.g. "v1.2.3"
  final String? name; // release title
  final String? body; // markdown notes
  final String? publishedAt; // ISO 8601
  final String? htmlUrl; // GitHub release page
  final bool isPrerelease;
  final List<ReleaseAsset> assets;

  const ReleaseInfo({
    required this.version,
    required this.tagName,
    required this.assets,
    this.name,
    this.body,
    this.publishedAt,
    this.htmlUrl,
    this.isPrerelease = false,
  });

  static String _stripV(String tag) =>
      tag.startsWith('v') ? tag.substring(1) : tag;

  factory ReleaseInfo.fromGitHub(Map<String, dynamic> json) {
    final tag = (json['tag_name'] as String?) ?? '';
    final assets = <ReleaseAsset>[];
    final rawAssets = json['assets'];
    if (rawAssets is List) {
      for (final a in rawAssets) {
        if (a is Map) {
          assets.add(ReleaseAsset(
            name: (a['name'] as String?) ?? '',
            url: (a['browser_download_url'] as String?) ?? '',
            size: (a['size'] as int?) ?? 0,
          ));
        }
      }
    }
    return ReleaseInfo(
      version: _stripV(tag),
      tagName: tag,
      name: json['name'] as String?,
      body: json['body'] as String?,
      publishedAt: json['published_at'] as String?,
      htmlUrl: json['html_url'] as String?,
      isPrerelease: (json['prerelease'] as bool?) ?? false,
      assets: assets,
    );
  }

  /// Parse a self-hosted geogram.radio feed object (updates/stable.json or
  /// updates/beta.json). Schema:
  ///   {
  ///     "version": "1.2.3", "tagName": "v1.2.3",
  ///     "name": "...", "body": "...notes...",
  ///     "publishedAt": "2026-06-09T12:00:00Z", "prerelease": false,
  ///     "assets": [ {"name": "aurora.apk", "url": "v1.2.3/aurora.apk",
  ///                  "size": 12345}, ... ]
  ///   }
  /// Asset `url`s may be relative — they are resolved against [baseUrl] (the
  /// directory the feed JSON was fetched from, e.g.
  /// "https://geogram.radio/updates"). Absolute http(s) urls pass through.
  /// Accepts snake_case keys too so a GitHub-shaped object also parses.
  factory ReleaseInfo.fromFeed(Map<String, dynamic> json, {String baseUrl = ''}) {
    final tag = (json['tagName'] as String?) ??
        (json['tag_name'] as String?) ??
        (json['version'] != null ? 'v${json['version']}' : '');
    final version = (json['version'] as String?) ?? _stripV(tag);

    String resolve(String url) {
      if (url.isEmpty) return url;
      final lower = url.toLowerCase();
      if (lower.startsWith('http://') || lower.startsWith('https://')) {
        return url;
      }
      if (baseUrl.isEmpty) return url;
      final b = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl;
      final rel = url.startsWith('/') ? url.substring(1) : url;
      return '$b/$rel';
    }

    final assets = <ReleaseAsset>[];
    final rawAssets = json['assets'];
    if (rawAssets is List) {
      for (final a in rawAssets) {
        if (a is Map) {
          final url = (a['url'] as String?) ??
              (a['browser_download_url'] as String?) ??
              '';
          assets.add(ReleaseAsset(
            name: (a['name'] as String?) ?? '',
            url: resolve(url),
            size: (a['size'] as num?)?.toInt() ?? 0,
          ));
        }
      }
    }
    return ReleaseInfo(
      version: _stripV(version),
      tagName: tag,
      name: json['name'] as String?,
      body: json['body'] as String?,
      publishedAt:
          (json['publishedAt'] as String?) ?? (json['published_at'] as String?),
      htmlUrl: (json['htmlUrl'] as String?) ?? (json['html_url'] as String?),
      isPrerelease: (json['prerelease'] as bool?) ??
          (json['isPrerelease'] as bool?) ??
          false,
      assets: assets,
    );
  }

  /// The asset to download for [platform], or null if this release has none.
  /// Prefers the canonical `aurora-*` names but falls back to extension match.
  ReleaseAsset? assetFor(UpdatePlatform platform) {
    bool ext(String s) => assets.any((a) => a.name.toLowerCase().endsWith(s));
    ReleaseAsset? pick(bool Function(String name) test) {
      for (final a in assets) {
        if (test(a.name.toLowerCase())) return a;
      }
      return null;
    }

    switch (platform) {
      case UpdatePlatform.android:
        // Prefer the release apk; never the debug one.
        return pick((n) => n.endsWith('.apk') && !n.contains('debug'));
      case UpdatePlatform.linux:
        return pick((n) => n.endsWith('linux-x64.tar.gz')) ??
            pick((n) => n.endsWith('.tar.gz'));
      case UpdatePlatform.windows:
        return pick((n) => n.endsWith('setup.exe')) ??
            pick((n) => n.endsWith('.exe')) ??
            (ext('.zip') ? pick((n) => n.endsWith('.zip')) : null);
      case UpdatePlatform.macos:
        return pick((n) => n.endsWith('.zip'));
      case UpdatePlatform.unknown:
        return null;
    }
  }
}
