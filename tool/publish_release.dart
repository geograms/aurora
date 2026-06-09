// =============================================================================
// publish_release.dart — publish a built Aurora release to the geogram.radio
// update feed (the geograms/geogram-html GitHub Pages repo).
//
// The in-app updater (lib/services/update_service.dart) reads a self-hosted
// feed at https://geogram.radio/updates with two channel files:
//   updates/stable.json   — latest stable release
//   updates/beta.json     — latest release incl. pre-releases
// and per-version binaries under updates/v<version>/. This script copies the
// given artifacts into updates/v<version>/ and (re)writes the channel JSON so
// the app can find them — no github.com runtime dependency.
//
// Usage:
//   dart run tool/publish_release.dart \
//       --site <path-to-geogram-html-repo> \
//       --version <X.Y.Z[-beta.N]> \
//       [--notes <notes-file>] [--name "<title>"] [--date <ISO8601>] \
//       [--keep <N>] \
//       <artifact> [<artifact> ...]
//
// Channel is derived from the version: a pre-release (contains '-') publishes
// to beta.json only; a stable version publishes to BOTH stable.json and
// beta.json (so the beta channel always tracks the newest build).
//
// `--site` defaults to ../old/geogram-html relative to the repo root (the
// local checkout of geograms/geogram-html in this workspace).
//
// `--keep <N>` (default 5) prunes old updates/v<version>/ dirs to bound the
// size of the Pages repo: it keeps the N newest versions (by semver) PLUS
// whatever stable.json and beta.json currently point at, and deletes the rest.
// (We prune instead of Git LFS because GitHub Pages does not serve LFS-tracked
// files over the Pages URL — they would 404.)
//
// Asset URLs are written relative to the updates/ dir ("v<version>/<file>") so
// the feed works regardless of the host it is served from.
// =============================================================================

import 'dart:convert';
import 'dart:io';

void main(List<String> argv) {
  String? site;
  String? version;
  String? notesFile;
  String? name;
  String? date;
  var keep = 5;
  final artifacts = <String>[];

  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    switch (a) {
      case '--site':
        site = argv[++i];
      case '--version':
        version = argv[++i];
      case '--notes':
        notesFile = argv[++i];
      case '--name':
        name = argv[++i];
      case '--date':
        date = argv[++i];
      case '--keep':
        keep = int.tryParse(argv[++i]) ?? keep;
      default:
        artifacts.add(a);
    }
  }

  if (version == null || version.isEmpty) {
    stderr.writeln('error: --version <X.Y.Z[-beta.N]> is required');
    exit(2);
  }
  if (artifacts.isEmpty) {
    stderr.writeln('error: at least one artifact path is required');
    exit(2);
  }

  // Default site path: ../old/geogram-html relative to this repo's root.
  final repoRoot = Directory.current.path;
  site ??= '$repoRoot/../old/geogram-html';
  final updatesDir = Directory('$site/updates');
  final versionDir = Directory('${updatesDir.path}/v$version');
  versionDir.createSync(recursive: true);

  final v = version; // promoted non-null
  final isPre = v.contains('-');
  final assets = <Map<String, dynamic>>[];
  for (final path in artifacts) {
    final f = File(path);
    if (!f.existsSync()) {
      stderr.writeln('error: artifact not found: $path');
      exit(1);
    }
    final base = path.split('/').last;
    final dest = File('${versionDir.path}/$base');
    f.copySync(dest.path);
    assets.add({
      'name': base,
      'url': 'v$v/$base', // relative to updates/
      'size': dest.lengthSync(),
    });
    stdout.writeln('copied $base (${dest.lengthSync()} bytes)');
  }

  String? notes;
  if (notesFile != null && File(notesFile).existsSync()) {
    notes = File(notesFile).readAsStringSync().trim();
  }

  final feed = <String, dynamic>{
    'version': v,
    'tagName': 'v$v',
    'name': name ?? 'Geogram Aurora $v',
    'body': notes ?? '',
    'publishedAt': date ?? DateTime.now().toUtc().toIso8601String(),
    'prerelease': isPre,
    'assets': assets,
  };
  final json = const JsonEncoder.withIndent('  ').convert(feed);

  // Beta always tracks the newest build; stable only when not a pre-release.
  final targets = <String>['beta.json', if (!isPre) 'stable.json'];
  for (final t in targets) {
    final out = File('${updatesDir.path}/$t');
    out.writeAsStringSync('$json\n');
    stdout.writeln('wrote ${out.path}');
  }

  if (keep > 0) _prune(updatesDir, keep);

  stdout.writeln('done. Published v$v to ${updatesDir.path} '
      '(${isPre ? 'beta' : 'stable + beta'}).');
}

/// Keep the [keep] newest `updates/v<version>/` dirs (by semver) plus whatever
/// stable.json and beta.json currently reference; delete the rest.
void _prune(Directory updatesDir, int keep) {
  // Versions referenced by the channel files must never be pruned.
  final protected = <String>{};
  for (final ch in ['stable.json', 'beta.json']) {
    final f = File('${updatesDir.path}/$ch');
    if (!f.existsSync()) continue;
    try {
      final v = (jsonDecode(f.readAsStringSync()) as Map)['version'] as String?;
      if (v != null && v.isNotEmpty) protected.add(v);
    } catch (_) {}
  }

  final versionDirs = updatesDir
      .listSync()
      .whereType<Directory>()
      .map((d) => d.path.split(Platform.pathSeparator).last)
      .where((n) => n.startsWith('v'))
      .map((n) => n.substring(1))
      .toList()
    ..sort(_compareSemver);
  // Newest first.
  final ordered = versionDirs.reversed.toList();
  final kept = <String>{...protected};
  for (final v in ordered) {
    if (kept.length >= keep && !protected.contains(v)) break;
    kept.add(v);
  }
  // Anything not in `kept` gets removed.
  for (final v in ordered) {
    if (kept.contains(v)) continue;
    final dir = Directory('${updatesDir.path}/v$v');
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
      stdout.writeln('pruned old version v$v');
    }
  }
}

/// Ascending semver compare (pre-releases rank below their release).
int _compareSemver(String a, String b) {
  a = a.split('+').first;
  b = b.split('+').first;
  final ap = a.split('-'), bp = b.split('-');
  List<int> core(String s) =>
      s.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final ac = core(ap.first), bc = core(bp.first);
  for (var i = 0; i < 3; i++) {
    final x = i < ac.length ? ac[i] : 0;
    final y = i < bc.length ? bc[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  final aPre = ap.length > 1, bPre = bp.length > 1;
  if (aPre && !bPre) return -1;
  if (!aPre && bPre) return 1;
  if (!aPre && !bPre) return 0;
  return ap.sublist(1).join('-').compareTo(bp.sublist(1).join('-'));
}
