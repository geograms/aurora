/*
 * Shared-media auto-fetch — incoming-chat side of APRX media references.
 *
 * A share message carries only two short, location-independent tokens:
 *   - `file:<sha256>.<ext>`  the content hash (what the file is + verification)
 *   - `ih:<40hex>`           the BitTorrent infohash (which swarm to join)
 * No IP addresses ever go on the air — they're radio-length-wasteful and
 * meaningless off the LAN. A message-triggered fetch joins the BitTorrent swarm
 * via the infohash (DHT + trackers). Same-LAN discovery is handled separately by
 * a routine Blossom scanner (probes well-known ports on the local network and
 * queries each device's Blossom server) — NOT per message — so it isn't here.
 *
 * Runs from the foreground page, the headless background manager, AND the chat
 * render path, so media arrives whatever screen the user is on. The dedup set +
 * archive.has() + TorrentService's in-flight guard make repeat calls harmless.
 */
import '../profile/storage_paths.dart';
import '../services/log_service.dart';
import '../services/preferences_service.dart';
import '../services/torrent_service.dart';
import '../util/media_ref.dart';
import 'geoui/widgets/media_view.dart' show sharedMediaArchive;

final RegExp _ihRe = RegExp(r'\bih:([0-9a-fA-F]{40})\b');
final Set<String> _inFlight = {};

/// Inspect one incoming chat message [text] (with direction [dir]); for each
/// media token we don't already hold, join the BitTorrent swarm via the infohash
/// hint. No-op for our own messages, messages without media, or without an `ih:`.
void maybeFetchSharedMedia(String text, String dir) {
  if (dir == 'out') return; // our own send — we already have it
  final refs = MediaRef.findAll(text);
  if (refs.isEmpty) return;
  final ih = _ihRe.firstMatch(text)?.group(1)?.toLowerCase();
  if (ih == null) return; // no swarm hint → nothing to fetch from
  final archive = sharedMediaArchive();
  if (archive == null) return;
  final prefs = PreferencesService.instanceSync;
  for (final ref in refs) {
    if (archive.has(ref.sha256) || _inFlight.contains(ref.sha256)) continue;
    _inFlight.add(ref.sha256);
    archive.addSource(ref.sha256, 'infohash', ih);
    if (prefs != null) {
      TorrentService.instance
          .configure(archive, wappsDataStorage(prefs).getAbsolutePath('share'));
    }
    LogService.instance.add('SharedMedia: ${ref.sha256Hex} via swarm ih:$ih');
    TorrentService.instance
        .fetch(ih, expectedSha256: ref.sha256, ext: ref.ext)
        .then((token) {
      // Clear the in-flight mark on failure so a later attempt can retry.
      if (token == null) _inFlight.remove(ref.sha256);
    });
  }
}
