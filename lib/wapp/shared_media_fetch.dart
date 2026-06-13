/*
 * Shared-media auto-fetch — incoming-chat side of APRX media references.
 *
 * A share message carries only two short, location-independent tokens:
 *   - `file:<sha256>.<ext>`  the content hash (what the file is + verification)
 *   - `ih:<40hex>`           the BitTorrent infohash (which swarm to join)
 * No IP addresses ever go on the air — they're radio-length-wasteful and
 * meaningless off the LAN.
 *
 * Resolution order for a referenced file we don't hold (3 tiers):
 *   1. local cache  — archive.has() (skipped here, nothing to do)
 *   2. LAN Blossom  — KNOWN local Blossom servers (the Files wapp keeps this
 *      list fresh with a routine scan; here we only query the cached servers,
 *      never scan per message)
 *   3. BitTorrent   — join the swarm via the infohash (DHT + trackers)
 *
 * Runs from the foreground page, the headless background manager, AND the chat
 * render path, so media arrives whatever screen the user is on. The in-flight
 * set + archive.has() + TorrentService's in-flight guard make repeats harmless.
 */
import '../profile/storage_paths.dart';
import '../services/blossom_server.dart';
import '../services/log_service.dart';
import '../services/preferences_service.dart';
import '../services/torrent_service.dart';
import '../util/media_archive.dart';
import '../util/media_ref.dart';
import 'geoui/widgets/media_view.dart' show sharedMediaArchive;

final RegExp _ihRe = RegExp(r'\bih:([0-9a-fA-F]{40})\b');
final Set<String> _inFlight = {};

/// Inspect one incoming chat message [text] (with direction [dir]); for each
/// media token we don't already hold, resolve it (LAN Blossom → swarm). No-op
/// for our own messages or messages without media.
void maybeFetchSharedMedia(String text, String dir) {
  if (dir == 'out') return; // our own send — we already have it
  final refs = MediaRef.findAll(text);
  if (refs.isEmpty) return;
  final archive = sharedMediaArchive();
  if (archive == null) return;
  final ih = _ihRe.firstMatch(text)?.group(1)?.toLowerCase();
  final prefs = PreferencesService.instanceSync;
  for (final ref in refs) {
    if (archive.has(ref.sha256) || _inFlight.contains(ref.sha256)) continue;
    _inFlight.add(ref.sha256);
    if (ih != null) archive.addSource(ref.sha256, 'infohash', ih);
    if (prefs != null) {
      TorrentService.instance
          .configure(archive, wappsDataStorage(prefs).getAbsolutePath('share'));
    }
    _resolve(ref, ih, archive).then((ok) {
      // Clear the in-flight mark on failure so a later render/arrival retries
      // (e.g. once the Files wapp's next LAN scan finds a server that has it).
      if (!ok) _inFlight.remove(ref.sha256);
    });
  }
}

/// Resolve one media ref we don't hold. Tier 1 (local cache) was already
/// checked by the caller; here: tier 2 = known LAN Blossom servers (no scan —
/// the Files wapp keeps that list fresh), tier 3 = the BitTorrent swarm.
Future<bool> _resolve(MediaRef ref, String? ih, MediaArchive archive) async {
  final lan =
      await BlossomServer.fetchFromKnown(ref.sha256Hex, ref.ext, archive);
  if (lan != null) {
    LogService.instance.add('SharedMedia: ${ref.sha256Hex} fetched from LAN');
    return true;
  }
  if (ih == null) return false; // no swarm hint and not on the LAN
  LogService.instance.add('SharedMedia: ${ref.sha256Hex} via swarm ih:$ih');
  final token = await TorrentService.instance
      .fetch(ih, expectedSha256: ref.sha256, ext: ref.ext);
  return token != null;
}
