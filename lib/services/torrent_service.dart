/*
 * BitTorrent sharing for the media archive (Files wapp, DESIGN.md §6).
 *
 * Every archive entry can be seeded into the public BitTorrent swarm, and a
 * file referenced by an APRX token can be fetched from the swarm when its
 * infohash is known (learned from announcements — see MediaArchive.sources).
 *
 * Torrents are constructed DETERMINISTICALLY so that any station holding the
 * same bytes derives the SAME infohash with no coordination:
 *   - single file, name = "<sha256-hex>.<ext>"
 *   - piece length = clamp(2^ceil(log2(size/1024)), 16 KiB, 4 MiB)
 *   - no private/source keys (announce URLs live outside the info dict and
 *     do not affect the infohash)
 * The rules are normative in wapps/files/DESIGN.md §6.
 *
 * Built on the pure-Dart dtorrent stack (dtorrent_task_v2 + built-in DHT +
 * dtorrent_tracker). Seeding = starting a task over the already-complete
 * staged file; the task validates local pieces, announces, and serves peers.
 *
 * Downloads verify the PLAIN SHA-256 of the finished file against the
 * requested hash before the bytes enter the archive — a poisoned swarm can
 * waste bandwidth but cannot plant a wrong file under a token.
 */

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:b_encode_decode/b_encode_decode.dart' as bencode;
import 'package:dtorrent_parser/dtorrent_parser.dart';
import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:dtorrent_tracker/dtorrent_tracker.dart';

import '../util/media_archive.dart';
import '../util/media_ref.dart';
import 'log_service.dart';

/// One live torrent (seed or fetch) for the status UI.
class TorrentEntry {
  final String infoHash; // 40-char hex
  final String token; // APRX token ('' until a fetch completes)
  final bool seeding;
  final TorrentTask task;
  TorrentEntry(this.infoHash, this.token, this.seeding, this.task);
}

class TorrentService {
  TorrentService._();
  static final TorrentService instance = TorrentService._();

  /// Well-known open trackers to speed up peer discovery; the built-in DHT
  /// works without them. Outside the info dict → no effect on the infohash.
  static const List<String> defaultTrackers = [
    'udp://tracker.opentrackr.org:1337/announce',
    'udp://open.demonii.com:1337/announce',
    'udp://exodus.desync.com:6969/announce',
    'udp://tracker.torrent.eu.org:451/announce',
  ];

  final Map<String, TorrentEntry> _active = {}; // infohash → entry
  Directory? _shareDir;
  MediaArchive? _archive;
  bool get running => _active.isNotEmpty;

  List<TorrentEntry> get active => _active.values.toList(growable: false);

  /// Deterministic piece length (bytes) for a file of [size] bytes.
  static int pieceLengthFor(int size) {
    if (size <= 0) return 16384;
    final target = (size / 1024).ceil();
    var p = 16384; // 16 KiB floor
    while (p < target && p < 4 * 1024 * 1024) {
      p <<= 1;
    }
    return math.min(p, 4 * 1024 * 1024);
  }

  /// Bind the service to the archive + a staging dir path for seeded files.
  void configure(MediaArchive archive, String shareDirPath) {
    _archive = archive;
    _shareDir = Directory(shareDirPath);
  }

  /// Stage the bytes of [token] as `<sha256-hex>.<ext>` in the share dir
  /// (the deterministic torrent name) and return the file, or null.
  Future<File?> _stage(MediaRef ref) async {
    final archive = _archive;
    final dir = _shareDir;
    if (archive == null || dir == null) return null;
    final data = archive.get(ref.sha256);
    if (data == null) return null;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File('${dir.path}/${ref.sha256Hex}.${ref.ext}');
    if (!f.existsSync() || f.lengthSync() != data.length) {
      await f.writeAsBytes(data, flush: true);
    }
    return f;
  }

  /// Build the deterministic torrent model for a token the archive holds.
  /// Returns null when the bytes are missing.
  Future<Torrent?> buildTorrent(String token) async {
    final ref = MediaRef.parse(token);
    if (ref == null) return null;
    final f = await _stage(ref);
    if (f == null) return null;
    return TorrentCreator.createTorrent(
      f.path,
      TorrentCreationOptions(
        pieceLength: pieceLengthFor(f.lengthSync()),
        trackers: [for (final t in defaultTrackers) Uri.parse(t)],
        creationDate: 0, // outside the info dict; pinned for reproducibility
      ),
    );
  }

  /// The deterministic infohash (40-hex) for a token we hold, or null.
  /// This is what gets announced so others can fetch the file.
  Future<String?> infohashOf(String token) async =>
      (await buildTorrent(token))?.infoHash;

  /// Seed one archived token into the swarm. Idempotent. Returns the
  /// infohash, or null when the bytes are missing / setup failed.
  Future<String?> seed(String token) async {
    try {
      final model = await buildTorrent(token);
      final dir = _shareDir;
      if (model == null || dir == null) return null;
      final ih = model.infoHash;
      if (_active.containsKey(ih)) return ih;
      final task = TorrentTask.newTask(model, dir.path);
      _active[ih] = TorrentEntry(ih, token, true, task);
      await task.start();
      LogService.instance.add('Torrent: seeding $token ih:$ih');
      return ih;
    } catch (e) {
      LogService.instance.add('Torrent: seed failed: $e');
      return null;
    }
  }

  /// Seed every archive entry (bounded by [max]); used by "share my files".
  Future<int> seedAll({int max = 50}) async {
    final archive = _archive;
    if (archive == null) return 0;
    var n = 0;
    for (final meta in archive.list(limit: max)) {
      final token = 'file:${meta.sha256}.${meta.ext}';
      if (await seed(token) != null) n++;
    }
    return n;
  }

  /// Fetch a file from the swarm by [infoHash] (40-hex). When
  /// [expectedSha256] (b64u or hex) is given the finished bytes must match
  /// or they are discarded. On success the bytes are archived (the fetcher
  /// becomes a provider) and the wire token is returned.
  Future<String?> fetch(String infoHash,
      {String? expectedSha256,
      String ext = 'bin',
      Duration timeout = const Duration(minutes: 10)}) async {
    final archive = _archive;
    final dir = _shareDir;
    if (archive == null || dir == null) return null;
    final ih = infoHash.toLowerCase();
    if (_active.containsKey(ih)) return null; // already in flight

    final completer = Completer<String?>();
    final metadata = MetadataDownloader(ih);
    final metadataListener = metadata.createListener();
    final tracker = TorrentAnnounceTracker(metadata);
    final trackerListener = tracker.createListener();
    Timer? guard;

    Future<void> finish(String? result) async {
      guard?.cancel();
      metadataListener.dispose();
      trackerListener.dispose();
      try {
        tracker.stop(true);
      } catch (_) {}
      if (!completer.isCompleted) completer.complete(result);
    }

    metadataListener.on<MetaDataDownloadComplete>((event) async {
      try {
        // BEP-9 delivers the bare info dict; wrap it into a full torrent map
        // and round-trip through the bencode parser to get the model.
        final model = await Torrent.parseFromBytes(Uint8List.fromList(
            bencode.encode(
                {'info': bencode.decode(Uint8List.fromList(event.data))})));
        final task = TorrentTask.newTask(model, dir.path);
        _active[ih] = TorrentEntry(ih, '', false, task);
        final taskListener = task.createListener();
        taskListener.on<TaskCompleted>((_) async {
          taskListener.dispose();
          try {
            final f = File('${dir.path}/${model.name}');
            final data = await f.readAsBytes();
            // Extension: prefer the deterministic "<hex>.<ext>" name.
            final dot = model.name.lastIndexOf('.');
            final fext = dot > 0 ? model.name.substring(dot + 1) : ext;
            final token = archive.putBytes(data, fext);
            final got = MediaRef.parse(token)!;
            final want = expectedSha256 == null
                ? null
                : (expectedSha256.length == 64
                    ? MediaRef.hexToB64u(expectedSha256)
                    : expectedSha256);
            if (want != null && got.sha256 != want) {
              archive.delete(got.sha256);
              _active.remove(ih)?.task.stop();
              LogService.instance
                  .add('Torrent: $ih content mismatch — discarded');
              return finish(null);
            }
            // Keep the completed task running: downloader → seeder.
            _active[ih] = TorrentEntry(ih, token, true, task);
            LogService.instance.add('Torrent: fetched $token (now seeding)');
            return finish(token);
          } catch (e) {
            LogService.instance.add('Torrent: fetch finalise failed: $e');
            return finish(null);
          }
        });
        await task.start();
      } catch (e) {
        LogService.instance.add('Torrent: metadata parse failed: $e');
        return finish(null);
      }
    });

    guard = Timer(timeout, () {
      _active.remove(ih)?.task.stop();
      LogService.instance.add('Torrent: fetch $ih timed out');
      finish(null);
    });

    // Tracker-discovered peers feed the metadata downloader (its own DHT
    // searches in parallel).
    trackerListener.on<AnnouncePeerEventEvent>((event) {
      final peers = event.event?.peers;
      if (peers == null) return;
      for (final p in peers) {
        metadata.addNewPeerAddress(p, PeerSource.tracker);
      }
    });
    metadata.startDownload();
    final ihBuffer = Uint8List.fromList(hexString2Buffer(ih)!);
    tracker.runTrackers(
        [for (final t in defaultTrackers) Uri.parse(t)], ihBuffer);
    return completer.future;
  }

  /// Stop one torrent (by infohash) or everything.
  Future<void> stop([String? infoHash]) async {
    if (infoHash != null) {
      await _active.remove(infoHash.toLowerCase())?.task.stop();
      return;
    }
    final entries = _active.values.toList();
    _active.clear();
    for (final e in entries) {
      try {
        await e.task.stop();
      } catch (_) {}
    }
    LogService.instance.add('Torrent: stopped all');
  }

  /// Status snapshot for the Files wapp UI.
  List<Map<String, dynamic>> status() => [
        for (final e in _active.values)
          {
            'infohash': e.infoHash,
            'token': e.token,
            'seeding': e.seeding,
            'progress': (e.task.progress * 100).toStringAsFixed(0),
            'peers': e.task.connectedPeersNumber,
            'upspeed': e.task.uploadSpeed.toStringAsFixed(1),
          },
      ];
}
