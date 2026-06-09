/*
 * Update models — release feed shapes for the in-app Update Center.
 *
 * Mirrors geogram's update system but GitHub-only and trimmed to what Aurora
 * ships: a stable channel (GitHub "latest", pre-releases excluded) and a beta
 * channel (newest release, pre-releases included). Artifacts follow the
 * `aurora-*` naming the CI workflows produce.
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
