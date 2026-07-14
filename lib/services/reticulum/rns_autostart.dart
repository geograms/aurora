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
import '../blossom_server.dart';
import '../files/media_file_source.dart';
import '../hero/followed_media_cache.dart';
import '../hero/hero_inbox.dart';
import '../log_service.dart';
import '../preferences_service.dart';
import '../../util/media_archive.dart';
import 'rns_service.dart';

/// Start the Reticulum node if it isn't already running, connecting to the
/// configured public testnet bootstrap as a TCP client. Safe to call repeatedly.
Future<void> ensureRnsAutostart() async {
  final rns = RnsService.instance;
  if (rns.isStarting) return;

  // Await the singleton: at boot time the sync accessor may still be null
  // (PreferencesService is fully initialized later in main()).
  final prefs = await PreferencesService.instance();
  if (!prefs.rnsAutoStart) return; // user opted out

  final servers = prefs.rnsBootstrapServers;

  // 1) Bring the node up via the FIRST reachable hub (this also builds the local
  //    services once). Skipped when already up — then we only top up the mesh.
  if (!rns.isUp) {
    // Serve the media we already hold (received files, imports; disk-folder
    // bytes are added later by the DiskFolderManager into the composite source).
    final ws = wappsDataStorage(prefs);
    final arch = MediaArchive.forDirectory(ws.getAbsolutePath(''));
    rns.fileServeSource = MediaFileSource(arch);

    // Serve our hosted blobs over Blossom (GET /<sha256>). This used to start
    // only from inside hal_media_infohash — i.e. only on a device that had
    // *shared* something — so a device that merely followed people cached their
    // media and then served it to nobody. start() is idempotent.
    if (prefs.hostEnabled) {
      unawaited(BlossomServer.instance.start(arch));
    }

    // The launcher hero: where wapps' published cards are kept across restarts,
    // and which followed-media URLs we have already fetched (or failed to).
    HeroInbox.instance.bind(ws.getAbsolutePath('hero_inbox.json'));
    FollowedMediaCache.instance.bind(ws.getAbsolutePath('hero_media.json'));

    // Persist the social relay/index DB + folder key-store / disk-folder
    // registry / subscriptions under the shared wapp-data root.
    rns.relayStorePath = ws.getAbsolutePath('social.sqlite3');
    rns.callPeersPath = ws.getAbsolutePath('call_peers.json');
    rns.partialStoreDir = ws.getAbsolutePath('partials'); // resumable downloads
    rns.folderStorePath = ws.getAbsolutePath('folders.json');
    rns.diskFoldersPath = ws.getAbsolutePath('disk_folders.json');
    rns.subscriptionsPath = ws.getAbsolutePath('folder_subscriptions.json');
    // Where a downloaded file is materialised so the OS can open it (the bytes
    // themselves live content-addressed in the archive; a viewer needs a path).
    rns.folderExportDir = ws.getAbsolutePath('opened');
    rns.serveStatsPath = ws.getAbsolutePath('serve_stats.sqlite3');
    rns.identityPath = ws.getAbsolutePath('rns_identity.key');
    rns.blossomLoad(); // the user's media servers, not just the shipped ones
    rns.followsPath = ws.getAbsolutePath('host_follows.json');
    rns.diskIndexPath = ws.getAbsolutePath('disk_index.sqlite3');

    // Persistent observed-node cache lives in the reticulum wapp's per-profile
    // data folder (user-specific data the reticulum wapp surfaces). The store
    // creates the directory if the wapp hasn't written there yet.
    rns.observedStorePath =
        wappDataStorageFor(prefs, 'reticulum').getAbsolutePath('observed.sqlite3');

    // Announce our callsign so peers/repeaters can show a human name (plaintext
    // presence beacon, same as the manual start path).
    final cs = (ProfileService.instance.activeProfile?.callsign ?? '').trim();
    final name = cs.isNotEmpty ? cs : 'aurora';

    for (final entry in servers) {
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
        // routing with the screen off or backgrounded (ref-counted holder, so
        // it coexists with the background-wapp service).
        await AndroidForegroundService.instance.hold('reticulum');
        break;
      }
    }
    if (!rns.isUp) {
      LogService.instance.add(
          'RNS autostart: no bootstrap reachable yet (local folders still work)');
      return;
    }
  }

  // 2) Mesh: connect to EVERY other configured hub we don't already hold an
  //    uplink to. Different community hubs don't reliably bridge announces to
  //    each other, so two devices that each reach a different subset would never
  //    meet on a single first-wins hub. Holding all reachable hubs at once means
  //    they share at least one. Idempotent — already-connected hubs are skipped,
  //    and dropped ones are re-added on the next tick. Best-effort per hub.
  for (final entry in servers) {
    final hp = _parseHostPort(entry);
    if (hp == null) continue;
    if (rns.connectedHubs.contains('${hp.$1}:${hp.$2}')) continue;
    await rns.connectUplink(hp.$1, hp.$2);
  }
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
  // Reconnect immediately when the hub uplink drops (socket closed or the
  // device's network changed and the watchdog noticed the silence) instead of
  // waiting for the next periodic tick. RnsService has already torn the dead
  // uplink down and set isUp=false, so ensureRnsAutostart re-dials the hub list
  // from the current network. Idempotent via the _attempting guard.
  RnsService.instance.onLinkDown = () {
    final p = PreferencesService.instanceSync;
    if (p != null && !p.rnsAutoStart) return;
    LogService.instance.add('RNS autostart: uplink dropped — reconnecting now');
    unawaited(_attempt());
  };
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
  // Periodic tick: brings the node up if it's down, AND tops up the hub mesh
  // (re-adds any uplink that dropped, or hubs that were unreachable earlier).
  // ensureRnsAutostart is idempotent, so this is safe to run while up.
  _retryTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
    final p = PreferencesService.instanceSync;
    if (p != null && !p.rnsAutoStart) return;
    if (RnsService.instance.isStarting) return;
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
