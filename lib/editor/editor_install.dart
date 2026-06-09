/*
 * Installs the built-in wapp editor (App Creator) from bundled assets.
 *
 * The editor used to be seeded as a normal grid wapp from the sibling
 * geogram/wapps repo. It is now bundled under assets/editor/app-creator/ and
 * written to its own storage location (editorWappStorage(), at the aurora
 * root, outside any profile's installed `wapps/`) so it never shows in the
 * launcher grid and is reachable only through the per-wapp Edit action.
 *
 * Runs as a boot task. Idempotent: a `.editor_version` marker records the
 * installed manifest version; reinstall happens only when it differs (or is
 * missing), so a shipped editor update lands on the next launch.
 */

import 'dart:convert';

import 'package:flutter/services.dart';

import '../profile/storage_paths.dart';

/// Asset prefix the bundled editor package lives under. Stripped to get each
/// file's path relative to the editor storage root.
const _assetPrefix = 'assets/editor/app-creator/';

const _versionMarker = '.editor_version';

/// Ensure the bundled editor is installed and up to date. Cheap no-op when the
/// installed version already matches what's bundled.
Future<void> ensureEditorInstalled() async {
  final bundledVersion = await _bundledManifestVersion();

  final store = editorWappStorage();
  final installed = await store.readString(_versionMarker);
  // Reinstall when the marker is missing or stale. Guard on the manifest
  // actually being present too, so a half-written install self-heals.
  if (installed == bundledVersion &&
      await store.exists('manifest.json')) {
    return;
  }

  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final assets =
      manifest.listAssets().where((a) => a.startsWith(_assetPrefix));

  for (final asset in assets) {
    final rel = asset.substring(_assetPrefix.length);
    if (rel.isEmpty) continue;
    final data = await rootBundle.load(asset);
    await store.writeBytes(rel, data.buffer.asUint8List());
  }

  await store.writeString(_versionMarker, bundledVersion);
}

/// Read the bundled editor's manifest version. Falls back to a sentinel so a
/// missing/garbled manifest still forces a (re)install rather than skipping.
Future<String> _bundledManifestVersion() async {
  try {
    final raw = await rootBundle.loadString('${_assetPrefix}manifest.json');
    final decoded = json.decode(raw);
    if (decoded is Map && decoded['version'] is String) {
      return decoded['version'] as String;
    }
  } catch (_) {}
  return 'unknown';
}
