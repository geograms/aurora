/*
 * rns_autostart — make the Reticulum node always-on.
 *
 * The node must run automatically with no manual step: folder sharing,
 * folder discovery by key, and file transfer all depend on it. This wires the
 * serve source + persistent store paths exactly like POST /api/rns/start and
 * then connects to a public Reticulum testnet TCP bootstrap as a client.
 *
 * It is idempotent (a no-op when the node is already up/starting) and honours
 * the rnsAutoStart preference so the user can opt out. The bootstrap host/port
 * are configurable (PreferencesService.rnsBootstrapHost/Port); the default is a
 * live public testnet hub.
 */
import 'dart:async';

import '../../profile/profile_service.dart';
import '../../profile/storage_paths.dart';
import '../../wapp/android_foreground_service.dart';
import '../files/media_file_source.dart';
import '../log_service.dart';
import '../preferences_service.dart';
import '../../util/media_archive.dart';
import 'rns_service.dart';

/// Start the Reticulum node if it isn't already running, connecting to the
/// configured public testnet bootstrap as a TCP client. Safe to call repeatedly.
Future<void> ensureRnsAutostart() async {
  final rns = RnsService.instance;
  if (rns.isUp || rns.isStarting) return;

  // Await the singleton: at boot time the sync accessor may still be null
  // (PreferencesService is fully initialized later in main()).
  final prefs = await PreferencesService.instance();
  if (!prefs.rnsAutoStart) return; // user opted out

  // Serve the media we already hold (received files, imports, disk-folder
  // bytes are added later by the DiskFolderManager into the composite source).
  final ws = wappsDataStorage(prefs);
  final arch = MediaArchive.forStorage(ws);
  rns.fileServeSource = MediaFileSource(arch);

  // Persist the social relay/index DB + folder key-store / disk-folder registry
  // / subscriptions under the shared wapp-data root.
  rns.relayStorePath = ws.getAbsolutePath('social.sqlite3');
  rns.folderStorePath = ws.getAbsolutePath('folders.json');
  rns.diskFoldersPath = ws.getAbsolutePath('disk_folders.json');
  rns.subscriptionsPath = ws.getAbsolutePath('folder_subscriptions.json');
  rns.serveStatsPath = ws.getAbsolutePath('serve_stats.sqlite3');
  rns.identityPath = ws.getAbsolutePath('rns_identity.key');
  rns.followsPath = ws.getAbsolutePath('host_follows.json');
  rns.diskIndexPath = ws.getAbsolutePath('disk_index.sqlite3');

  // Announce our callsign so peers/repeaters can show a human name (plaintext
  // presence beacon, same as the manual start path).
  final cs = (ProfileService.instance.activeProfile?.callsign ?? '').trim();
  final name = cs.isNotEmpty ? cs : 'aurora';

  // Try each configured bootstrap hub in turn until one answers with real
  // Reticulum traffic (rns.start validates the link before returning true). The
  // first attempt also builds the local services once; the rest just reconnect.
  for (final entry in prefs.rnsBootstrapServers) {
    final hp = _parseHostPort(entry);
    if (hp == null) continue;
    if (rns.isUp) break;
    LogService.instance.add('RNS autostart: trying ${hp.$1}:${hp.$2}');
    final ok = await rns.start(
      mode: 'tcpclient',
      host: hp.$1,
      port: hp.$2,
      announceName: name,
    );
    if (ok || rns.isUp) {
      // Keep the process alive while the node is up so it goes on sharing /
      // routing with the screen off or the app backgrounded (the holder is
      // ref-counted, so it coexists with the background-wapp service).
      await AndroidForegroundService.instance.hold('reticulum');
      return;
    }
  }
  LogService.instance.add(
      'RNS autostart: no bootstrap reachable yet (local folders still work)');
}

/// Parse "host:port" (port optional → 4242). Returns null for blank entries.
(String, int)? _parseHostPort(String entry) {
  final s = entry.trim();
  if (s.isEmpty) return null;
  final i = s.lastIndexOf(':');
  if (i <= 0 || i == s.length - 1) return (s, 4242);
  final host = s.substring(0, i).trim();
  final port = int.tryParse(s.substring(i + 1).trim()) ?? 4242;
  if (host.isEmpty) return null;
  return (host, port);
}

Timer? _retryTimer;

/// Kick off the always-on node in the background and keep retrying until it is
/// up. Returns immediately so it never blocks boot on the bootstrap TCP connect
/// (which can take seconds or fail when offline). Idempotent.
void startRnsAutostart() {
  final prefs = PreferencesService.instanceSync;
  if (prefs != null && !prefs.rnsAutoStart) return;
  // Defer the first attempt so the UI paints first. Node startup does real
  // synchronous work on this isolate (identity, store open, indexing owned
  // disk folders); running it during boot froze the splash for a long time on
  // devices with shared folders. A few seconds' delay lets the launcher render
  // before any of that begins; the node still comes up on its own shortly after.
  Timer(const Duration(seconds: 4), () {
    final p = PreferencesService.instanceSync;
    if (p != null && !p.rnsAutoStart) return;
    unawaited(_attempt());
  });
  _retryTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
    final p = PreferencesService.instanceSync;
    if (p != null && !p.rnsAutoStart) return;
    if (RnsService.instance.isUp || RnsService.instance.isStarting) return;
    unawaited(_attempt());
  });
}

bool _attempting = false;

Future<void> _attempt() async {
  // The attempt loops over several hubs (each up to ~18s); guard against a
  // retry-timer tick starting a second loop while one is already running.
  if (_attempting) return;
  _attempting = true;
  try {
    await ensureRnsAutostart();
  } catch (e) {
    LogService.instance.add('RNS autostart: $e');
  } finally {
    _attempting = false;
  }
}
