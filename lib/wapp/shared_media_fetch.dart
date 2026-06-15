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
import 'dart:convert';
import 'dart:typed_data';

import '../profile/profile_service.dart';
import '../profile/storage_paths.dart';
import '../services/blossom_server.dart';
import '../services/i2p/i2p_service.dart';
import '../services/log_service.dart';
import '../services/preferences_service.dart';
import '../services/torrent_service.dart';
import '../util/media_archive.dart';
import '../util/media_ref.dart';
import '../util/nostr_crypto.dart';
import 'geoui/widgets/media_view.dart' show sharedMediaArchive;

final RegExp _ihRe = RegExp(r'\bih:([0-9a-fA-F]{40})\b');
// A peer's I2P destination, carried in messages/beacons as `dest:<b32>.b32.i2p`.
// Learning these populates the I2P roster used for content discovery.
final RegExp _destRe = RegExp(r'\bdest:([a-z2-7]{52})\.b32\.i2p\b');
final Set<String> _inFlight = {};

/// Learn a peer's I2P destination from an incoming message carrying a
/// `dest:<b32>` token, so we can fetch from / route discovery through it.
void _learnPeerDest(String text, String? from) {
  if (from == null || from.isEmpty) return;
  final m = _destRe.firstMatch(text);
  if (m != null) I2pService.instance.registerB32(from, '${m.group(1)}.b32.i2p');
}

/// Inspect one incoming chat message [text] (with direction [dir]); for each
/// media token we don't already hold, resolve it (LAN Blossom → swarm). No-op
/// for our own messages or messages without media.
void maybeFetchSharedMedia(String text, String dir, {String? from}) {
  if (dir == 'out') return; // our own send — we already have it
  _learnPeerDest(text, from); // populate the I2P roster from dest: tokens
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
    _resolve(ref, ih, archive, fromCallsign: from).then((ok) {
      // Clear the in-flight mark on failure so a later render/arrival retries
      // (e.g. once the Files wapp's next LAN scan finds a server that has it).
      if (!ok) _inFlight.remove(ref.sha256);
    });
  }
}

/// Resolve one media ref we don't hold. Tier 1 (local cache) was already
/// checked by the caller; here: tier 2 = known LAN Blossom servers (no scan —
/// the Files wapp keeps that list fresh), tier 3 = the BitTorrent swarm.
Future<bool> _resolve(MediaRef ref, String? ih, MediaArchive archive,
    {String? fromCallsign}) async {
  // Tier 2: known LAN Blossom servers (cheap, no scan).
  final lan =
      await BlossomServer.fetchFromKnown(ref.sha256Hex, ref.ext, archive);
  if (lan != null) {
    LogService.instance.add('SharedMedia: ${ref.sha256Hex} fetched from LAN');
    return true;
  }
  // Tier 2.5: I2P — decentralized device-to-device across NATs, no server, no
  // router config. Files over ~64 KiB are split into pieces and pulled from
  // EVERY device that has them in parallel (BitTorrent-style swarm over I2P),
  // re-shared piece-by-piece as they arrive. First try the sharer's destination
  // (if known from the beacon, seeding the swarm with it); otherwise DISCOVER
  // any providers of this sha256 across the network (content routing — no need
  // to know who holds it) and swarm-download from all of them.
  if (I2pService.instance.isUp) {
    final sha = _sha256Bytes(ref.sha256);
    if (sha != null) {
      if (fromCallsign != null &&
          I2pService.instance.destinationFor(fromCallsign) != null &&
          await I2pService.instance.fetchFrom(fromCallsign, sha, ref.ext)) {
        LogService.instance
            .add('SharedMedia: ${ref.sha256Hex} fetched over I2P from $fromCallsign');
        return true;
      }
      if (await I2pService.instance.discover(sha, ref.ext)) {
        LogService.instance
            .add('SharedMedia: ${ref.sha256Hex} discovered + fetched over I2P');
        return true;
      }
    }
  }
  // Tier 3: public Blossom servers (internet, content-addressed). This is the
  // reachable path when both stations are behind NAT — direct BitTorrent peer
  // connections are impossible across symmetric/CGNAT, but an outbound HTTPS GET
  // from a public host always works.
  final pub =
      await BlossomServer.fetchFromPublic(ref.sha256Hex, ref.ext, archive);
  if (pub != null) {
    LogService.instance
        .add('SharedMedia: ${ref.sha256Hex} fetched from public Blossom');
    return true;
  }
  // Tier 4: BitTorrent swarm (works when a peer is reachable, e.g. one side has
  // an open port or both are on cone NATs).
  if (ih == null) return false;
  LogService.instance.add('SharedMedia: ${ref.sha256Hex} via swarm ih:$ih');
  final token = await TorrentService.instance
      .fetch(ih, expectedSha256: ref.sha256, ext: ref.ext);
  return token != null;
}

/// Resolve a single media reference by [sha256] (b64u-43 or 64-hex) + [ext],
/// running the full tiered resolution (cache → LAN Blossom → public Blossom →
/// BitTorrent). Optional [ih] enables the swarm tier. Returns true if the bytes
/// are in the archive afterwards. Used by the headless RemoteApi and the chat
/// render path.
/// Decode a MediaRef sha256 (43-char unpadded base64url) to 32 raw bytes.
Uint8List? _sha256Bytes(String b64u) {
  try {
    final b = base64Url.decode('$b64u=');
    return b.length == 32 ? b : null;
  } catch (_) {
    return null;
  }
}

Future<bool> resolveSharedMedia(String sha256, String ext,
    {String? ih, String? fromCallsign}) async {
  final archive = sharedMediaArchive();
  if (archive == null) return false;
  final b64u = sha256.length == 64 ? MediaRef.hexToB64u(sha256) : sha256;
  if (b64u == null) return false;
  final ref = MediaRef.parse('file:$b64u.$ext');
  if (ref == null) return false;
  if (archive.has(ref.sha256)) return true;
  final ihNorm = ih?.toLowerCase();
  if (ihNorm != null) archive.addSource(ref.sha256, 'infohash', ihNorm);
  final prefs = PreferencesService.instanceSync;
  if (prefs != null) {
    TorrentService.instance
        .configure(archive, wappsDataStorage(prefs).getAbsolutePath('share'));
  }
  return _resolve(ref, ihNorm, archive, fromCallsign: fromCallsign);
}

/// Publish the bytes behind every media token in an OUTGOING message [text] to
/// the public Blossom servers, so receivers on other networks can fetch them
/// over the internet (the reachable, no-router-config path). No-op for incoming
/// messages or when we don't hold the bytes / have no signing key.
Future<void> maybePublishSharedMedia(String text, String dir) async {
  if (dir != 'out') return;
  final refs = MediaRef.findAll(text);
  if (refs.isEmpty) return;
  final archive = sharedMediaArchive();
  if (archive == null) return;
  final profile = ProfileService.instance.activeProfile;
  if (profile == null) return;
  String privHex;
  try {
    privHex = NostrCrypto.decodeNsec(profile.nsec);
  } catch (_) {
    return;
  }
  for (final ref in refs) {
    final data = archive.get(ref.sha256);
    if (data == null) continue;
    final n = await BlossomServer.publishToPublic(data, privHex, ext: ref.ext);
    LogService.instance
        .add('SharedMedia: published ${ref.sha256Hex} to $n public server(s)');
    // Announce over I2P so other devices can discover we hold this file by hash
    // (content routing). The I2P node serves it from the archive via onGet.
    if (I2pService.instance.isUp) {
      final sha = _sha256Bytes(ref.sha256);
      if (sha != null) await I2pService.instance.announce(sha);
    }
  }
}
