/*
 * WappFileAssociations — answers "which wapps can open this file?".
 *
 * Wapps declare handlers under `provides.file_handlers` in their
 * manifest (see [WappFileHandler]). Aurora's launcher already scans
 * every installed + built-in wapp and registers each manifest with the
 * [FunctionalityRegistry], so this service reads handlers straight from
 * `FunctionalityRegistry.allManifests` — no second folder scan.
 *
 * User-chosen defaults for ambiguous extensions are persisted in the
 * active profile via [activeProfileRoot] so "Always use this wapp"
 * survives restarts.
 */

import '../launcher/launcher.dart' show WappManifest;
import '../models/wapp_file_handler.dart';
import 'functionality_registry.dart';
import '../profile/storage_paths.dart';

/// One row of a lookup: a wapp plus the handler declaration that
/// matched.
class WappAssociation {
  /// Folder slug — the value [WappManifest.name] / the launcher uses to
  /// instantiate a [WappPage] via the manifest's dirPath.
  final WappManifest manifest;
  final WappFileHandler handler;

  WappAssociation({required this.manifest, required this.handler});

  /// Verb for the picker, falling back to the wapp's title.
  String get label =>
      handler.title.isNotEmpty ? handler.title : manifest.title;
}

class WappFileAssociations {
  WappFileAssociations._();
  static final WappFileAssociations instance = WappFileAssociations._();

  static const String _defaultsPath = 'wapp_associations.json';

  Map<String, String>? _defaultsCache;

  // ── Lookup ─────────────────────────────────────────────────────────

  /// Handlers matching [extension] and/or [mime], optionally filtered
  /// by [mode]. Ordered: exact-extension first, then MIME, then
  /// catch-all.
  List<WappAssociation> lookup({String? extension, String? mime, String? mode}) {
    final ext = extension?.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    final m = mime?.toLowerCase();

    final exact = <WappAssociation>[];
    final mimeMatches = <WappAssociation>[];
    final catchAll = <WappAssociation>[];

    for (final manifest in FunctionalityRegistry.instance.allManifests) {
      for (final h in manifest.fileHandlers) {
        if (mode != null && !h.supportsMode(mode)) continue;
        final hasExt = ext != null && ext.isNotEmpty && h.matchesExtension(ext);
        final hasMime = m != null && m.isNotEmpty && h.matchesMime(m);
        final isCatchAll = h.extensions.contains('*') ||
            h.mimeTypes.contains('*') ||
            h.mimeTypes.contains('*/*');
        if (!hasExt && !hasMime) continue;
        final assoc = WappAssociation(manifest: manifest, handler: h);
        if (hasExt && !isCatchAll) {
          exact.add(assoc);
        } else if (hasMime && !isCatchAll) {
          mimeMatches.add(assoc);
        } else {
          catchAll.add(assoc);
        }
      }
    }
    return [...exact, ...mimeMatches, ...catchAll];
  }

  /// Convenience: derive the extension from a filename/path.
  List<WappAssociation> lookupForFile(String path, {String? mime, String? mode}) {
    final dot = path.lastIndexOf('.');
    final slash = path.replaceAll('\\', '/').lastIndexOf('/');
    final ext = (dot > slash && dot >= 0) ? path.substring(dot + 1) : '';
    return lookup(extension: ext, mime: mime, mode: mode);
  }

  // ── User defaults ──────────────────────────────────────────────────

  /// The wapp the user previously chose for [extension], if it still
  /// has a matching handler installed.
  Future<WappAssociation?> defaultFor(String extension, {String? mode}) async {
    final defaults = await _loadDefaults();
    final ext = extension.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    final wappId = defaults[ext];
    if (wappId == null) return null;
    for (final manifest in FunctionalityRegistry.instance.allManifests) {
      if (manifest.id != wappId) continue;
      for (final h in manifest.fileHandlers) {
        if (h.matchesExtension(ext) && (mode == null || h.supportsMode(mode))) {
          return WappAssociation(manifest: manifest, handler: h);
        }
      }
    }
    // Stale default — drop it so the next picker is unbiased.
    defaults.remove(ext);
    await _saveDefaults();
    return null;
  }

  /// Persist (or, with an empty [wappId], clear) the default for an
  /// extension.
  Future<void> setDefaultFor(String extension, String wappId) async {
    final defaults = await _loadDefaults();
    final ext = extension.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    if (wappId.isEmpty) {
      defaults.remove(ext);
    } else {
      defaults[ext] = wappId;
    }
    await _saveDefaults();
  }

  // ── Internals ──────────────────────────────────────────────────────

  Future<Map<String, String>> _loadDefaults() async {
    final cached = _defaultsCache;
    if (cached != null) return cached;
    final result = <String, String>{};
    try {
      final json = await activeProfileRoot().readJson(_defaultsPath);
      json?.forEach((k, v) {
        if (v is String) result[k.toLowerCase()] = v;
      });
    } catch (_) {}
    _defaultsCache = result;
    return result;
  }

  Future<void> _saveDefaults() async {
    final defaults = _defaultsCache;
    if (defaults == null) return;
    try {
      await activeProfileRoot().writeJson(_defaultsPath, defaults);
    } catch (_) {}
  }
}
