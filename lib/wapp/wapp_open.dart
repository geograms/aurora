/*
 * openWappByFolder — the ONE way to open an installed wapp from outside the
 * launcher grid, optionally landing straight on a conversation.
 *
 * Used by the in-app notification center (tap a row) and the Android
 * notification deep link (geogram://open?wapp=<folder>&convo=<id>), so both
 * taps behave identically by construction. The launcher grid keeps its own
 * richer path (dependency gate, launch counters); this is the lightweight
 * "just open it" door, same as the remote API's /api/launch.
 */

import 'dart:convert';

import 'package:flutter/material.dart';

import '../profile/storage_paths.dart';
import '../services/log_service.dart';
import 'wapp_page.dart';

/// Open the wapp installed at `wapps/<folder>` in the active profile.
/// [convo], when given, opens that conversation inside the wapp (mail: the
/// peer's pubkey; chat: the room/callsign id). Returns false when the wapp is
/// not installed or no navigator is available.
Future<bool> openWappByFolder(
  String folder, {
  String? convo,
  required NavigatorState? navigator,
}) async {
  if (folder.isEmpty || navigator == null) return false;
  final installed = installedAppsStorage();
  if (!await installed.directoryExists(folder)) {
    LogService.instance.add('wapp-open: "$folder" not installed');
    return false;
  }
  final dir = installed.getAbsolutePath(folder);
  var title = folder;
  try {
    final raw = await wappPackageStorage(dir).readString('manifest.json');
    if (raw != null) {
      final m = jsonDecode(raw);
      if (m is Map && (m['title'] ?? '').toString().isNotEmpty) {
        title = m['title'].toString();
      }
    }
  } catch (_) {}
  await navigator.push(MaterialPageRoute(
    builder: (_) => WappPage(
      wappDir: dir,
      title: title,
      initialConvo: (convo != null && convo.isNotEmpty) ? convo : null,
    ),
  ));
  return true;
}
