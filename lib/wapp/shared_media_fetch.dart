/*
 * Shared-media auto-fetch — incoming-chat side of APRX media references.
 *
 * A share message carries only two short, location-independent tokens:
 *   - `file:<sha256>.<ext>`  the content hash (what the file is + verification)
 *   - `ih:<40hex>`           the BitTorrent infohash (which swarm to join)
 * No IP addresses ever go on the air — they're radio-length-wasteful and
 * meaningless off the LAN.
 *
 * Resolution order for a referenced file we don't hold (decentralized first):
 *   1. local cache    — archive.has() (skipped here, nothing to do)
 *   R. Reticulum      — R1 direct-from-sender by callsign, then R2 the file DHT
 *      (content-addressed, no central index; works across different networks
 *      via a shared hub that only RELAYS transport — it never indexes content)
 *   2. LAN Blossom    — KNOWN local Blossom servers (cached; never scanned here)
 *   2.5 I2P           — content-routed swarm across NATs, no server
 *   4. BitTorrent     — join the swarm via the infohash (DHT + trackers)
 *
 * There is deliberately NO public-Blossom tier: we never depend on a third-party
 * central content host. On success the file is RE-SEEDED (a signed DHT provider
 * record is published) so every device that downloads becomes a holder others
 * can fetch from over Reticulum — the swarm grows with each download.
 *
 * Runs from the foreground page, the headless background manager, AND the chat
 * render path, so media arrives whatever screen the user is on. The in-flight
 * set + archive.has() + TorrentService's in-flight guard make repeats harmless.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../profile/profile_service.dart';
import '../profile/storage_paths.dart';
import '../services/blossom_server.dart';
import '../services/i2p/i2p_service.dart';
import '../services/log_service.dart';
import '../services/preferences_service.dart';
import '../services/reticulum/rns_service.dart';
import '../services/torrent_service.dart';
import '../util/media_archive.dart';
import '../util/media_ref.dart';
import '../util/nostr_crypto.dart';
import 'geoui/widgets/media_view.dart' show sharedMediaArchive;

final RegExp _ihRe = RegExp(r'\bih:([0-9a-fA-F]{40})\b');
// Size hint a sender puts on the wire next to the file: token ("sz:<bytes>") so
// receivers can show the size and skip auto-downloading large files.
final RegExp _szRe = RegExp(r'\bsz:(\d+)\b');

/// The referenced file's size in bytes from a message's `sz:` token, or null.
int? mediaSizeHint(String text) =>
    int.tryParse(_szRe.firstMatch(text)?.group(1) ?? '');
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
  final refs = MediaRef.findAll(text);
  if (refs.isEmpty) return;
  final archive = sharedMediaArchive();
  if (archive == null) return;
  if (dir == 'out') {
    // Our own message: if we host the referenced file on disk (a shared folder)
    // but it isn't in the media archive, copy it in so it renders locally too.
    for (final ref in refs) {
      if (archive.has(ref.sha256)) continue;
      final sha = _sha256Bytes(ref.sha256);
      if (sha == null) continue;
      final bytes = RnsService.instance.localFileBytes(sha);
      if (bytes != null && bytes.isNotEmpty) archive.putBytes(bytes, ref.ext);
    }
    return;
  }
  _learnPeerDest(text, from); // populate the I2P roster from dest: tokens
  final ih = _ihRe.firstMatch(text)?.group(1)?.toLowerCase();
  final prefs = PreferencesService.instanceSync;
  // Don't auto-download files larger than the user's threshold (default 10 MB);
  // those wait for an explicit tap (MediaThumbnail shows size + a download chip).
  final size = mediaSizeHint(text);
  final maxMb = prefs?.mediaAutoMaxMb ?? 10;
  if (size != null && maxMb > 0 && size > maxMb * 1024 * 1024) return;
  if (maxMb == 0) return; // auto-download disabled — always require a tap
  for (final ref in refs) {
    if (archive.has(ref.sha256) || _inFlight.contains(ref.sha256)) continue;
    _inFlight.add(ref.sha256);
    if (ih != null) archive.addSource(ref.sha256, 'infohash', ih);
    if (prefs != null) {
      TorrentService.instance
          .configure(archive, wappsDataStorage(prefs).getAbsolutePath('share'));
    }
    _resolve(ref, ih, archive, fromCallsign: from).then((ok) {
      if (ok) {
        // Re-seed: now that we hold the verified bytes, advertise ourselves as a
        // provider in the DHT so any other chat participant can fetch this file
        // from us over Reticulum. This is what makes every downloader a seeder —
        // the swarm of holders grows with each download, with no central server.
        _reseed(ref, archive);
      } else {
        // Clear the in-flight mark on failure so a later render/arrival retries
        // (e.g. once the Files wapp's next LAN scan finds a server that has it).
        _inFlight.remove(ref.sha256);
      }
    });
  }
}

/// Resolve one media ref we don't hold. Tier 1 (local cache) was already
/// checked by the caller; here: tier 2 = known LAN Blossom servers (no scan —
/// the Files wapp keeps that list fresh), tier 3 = the BitTorrent swarm.
Future<bool> _resolve(MediaRef ref, String? ih, MediaArchive archive,
    {String? fromCallsign}) async {
  // Tier R: Reticulum DHT — content-addressed fetch over RNS by sha256. This is
  // the path that works when the two stations are on DIFFERENT networks: both
  // reach the same public hub, the holder advertises the sha (shared folders +
  // archived media auto-publish), and the bytes are verified against the hash on
  // arrival. Tried first because it needs no server, no LAN, and no router config.
  final shaBytes = _sha256Bytes(ref.sha256);
  if (shaBytes != null && RnsService.instance.isUp) {
    // The single content-addressed RNS path: direct-from-sender (when we know the
    // callsign), else DHT multi-source; verifies sha256, archives, and re-seeds.
    // Shared with folders/updates/the wapp store (RnsService.fetchContentAddressed).
    final bytes = await RnsService.instance.fetchContentAddressed(
      shaBytes,
      ext: ref.ext,
      fromCallsign: fromCallsign,
      timeout: const Duration(seconds: 180),
    );
    if (bytes != null && bytes.isNotEmpty) {
      LogService.instance
          .add('SharedMedia: ${ref.sha256Hex} fetched over Reticulum');
      return true;
    }
  }
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
  // (No public Blossom tier: we never depend on third-party central servers for
  // content. Cross-NAT reachability comes from the Reticulum hub relay above —
  // a transport relay, not a content index — so discovery stays decentralized.)
  // Tier 4: BitTorrent swarm (works when a peer is reachable, e.g. one side has
  // an open port or both are on cone NATs).
  if (ih == null) return false;
  LogService.instance.add('SharedMedia: ${ref.sha256Hex} via swarm ih:$ih');
  final token = await TorrentService.instance
      .fetch(ih, expectedSha256: ref.sha256, ext: ref.ext);
  return token != null;
}

/// Re-seed a file we just downloaded: once the verified bytes are in our
/// content-addressed archive, publish a signed DHT provider record so other
/// participants discover us as a holder and can fetch it over Reticulum. Only
/// publishes when the bytes are actually servable from our archive (so we never
/// advertise something we can't deliver).
void _reseed(MediaRef ref, MediaArchive archive) {
  final shaBytes = _sha256Bytes(ref.sha256);
  if (shaBytes == null) return;
  if (!RnsService.instance.isUp) return;
  if (!archive.has(ref.sha256Hex)) return;   // serve path reads from the archive
  unawaited(RnsService.instance.dhtPublish(shaBytes));
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
  final ok = await _resolve(ref, ihNorm, archive, fromCallsign: fromCallsign);
  if (ok) _reseed(ref, archive);   // become a seeder once we hold the bytes
  return ok;
}

/// Archive a picked file's [bytes] (with extension [ext]) into the shared media
/// archive, advertise its sha256 on Reticulum so receivers on other networks
/// can fetch it (we become the seeder), and return the `file:<sha>.<ext>` token
/// to embed in a chat message. Null if storage isn't ready.
Future<String?> attachMediaFile(Uint8List bytes, String ext, {String? name}) async {
  final archive = sharedMediaArchive();
  if (archive == null) return null;
  final token = archive.putBytes(bytes, ext, name: name);
  final ref = MediaRef.parse(token);
  if (ref != null) {
    final sha = _sha256Bytes(ref.sha256);
    if (sha != null && RnsService.instance.isUp) {
      unawaited(RnsService.instance.dhtPublish(sha));
    }
  }
  LogService.instance.add('SharedMedia: attached $token (advertised on RNS)');
  // Carry the size on the wire ("sz:<bytes>") so the receiver can show it and
  // decide whether to auto-download.
  return '$token sz:${bytes.length}';
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
    // Reticulum: advertise this sha on the DHT so receivers on other networks
    // can pull it over RNS (the file node serves it from the archive). Shared
    // disk-folder files already auto-advertise; this covers archived/inline media.
    final shaBytes = _sha256Bytes(ref.sha256);
    if (shaBytes != null && RnsService.instance.isUp) {
      final holders = await RnsService.instance.dhtPublish(shaBytes);
      LogService.instance
          .add('SharedMedia: advertised ${ref.sha256Hex} on Reticulum ($holders)');
    }
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
