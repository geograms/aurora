/*
 * Update models — release shapes for the in-app Update Center.
 *
 * Releases are published into signed Reticulum mutable folders (see
 * update_service.dart): each per-platform binary is a content-addressed folder
 * entry named `aurora-<version>-<platform>`. releasesFromFolder() turns a
 * browsed folder's entries into the ReleaseInfo/ReleaseAsset shapes below;
 * assetFor() then resolves the right artifact for the running platform exactly
 * as before. Pure Dart on purpose (no Flutter) so the adapter is testable and
 * reusable; the only platform-detection helper lives in update_platform.dart.
 */

enum UpdateChannel { stable, beta }

enum UpdatePlatform { android, linux, windows, macos, unknown }

/// One downloadable file attached to a release.
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

/// Known per-platform artifact suffixes, longest/most-specific first so the
/// version can be split off the filename unambiguously.
const List<String> _kArtifactSuffixes = [
  '-linux-x64.tar.gz',
  '-setup.exe',
  '.apk',
  '.tar.gz',
  '.zip',
  '.exe',
  '.dmg',
];

/// Extract the semver version from an `aurora-<version>-<platform>` artifact
/// name, or null when the name isn't a recognised aurora artifact. The version
/// may itself contain '-' (e.g. `1.0.3-beta.4`), which is exactly the channel
/// signal `isPrerelease` reads.
String? versionFromAssetName(String name) {
  const prefix = 'aurora-';
  if (!name.startsWith(prefix)) return null;
  var rest = name.substring(prefix.length);
  for (final suf in _kArtifactSuffixes) {
    if (rest.endsWith(suf) && rest.length > suf.length) {
      return rest.substring(0, rest.length - suf.length);
    }
  }
  return null;
}

/// Build the candidate releases from a browsed Reticulum update-folder state
/// (FolderState.toJson). Each `files` entry `{x: sha256hex, name, size}` becomes
/// a ReleaseAsset whose `url` holds the sha (the fetch handle); files are grouped
/// by the version parsed from their name into one ReleaseInfo each. The existing
/// `assetFor(platform)` (filename-based) and semver comparison then apply
/// unchanged — only the transport differs from the HTTP feed.
List<ReleaseInfo> releasesFromFolder(Map<String, dynamic> folderState) {
  final files = folderState['files'];
  if (files is! List) return const [];
  final byVersion = <String, List<ReleaseAsset>>{};
  for (final f in files) {
    if (f is! Map) continue;
    final sha = (f['x'] ?? '').toString();
    final name = (f['name'] ?? '').toString();
    if (sha.isEmpty || name.isEmpty) continue;
    final version = versionFromAssetName(name);
    if (version == null) continue;
    (byVersion[version] ??= []).add(ReleaseAsset(
      name: name,
      url: sha, // the sha is the content-addressed fetch handle
      size: (f['size'] as num?)?.toInt() ?? 0,
    ));
  }
  final out = <ReleaseInfo>[];
  byVersion.forEach((version, assets) {
    out.add(ReleaseInfo(
      version: version,
      tagName: 'v$version',
      isPrerelease: version.contains('-'),
      assets: assets,
    ));
  });
  return out;
}
