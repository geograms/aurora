// Validate BitTorrent metadata fetch over the internet with dtorrent_task_v2
// 0.5.4 using the library's canonical pattern: MetadataDownloader + an external
// TorrentAnnounceTracker fed by findPublicTrackers() (continuous peer supply).
//   dart run tool/bt_internet_check.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:logging/logging.dart';

const ihHex = '58846860f0a766f8a42b0bb214d8c713fdf1b167'; // debian-13.5.0 netinst

Future<void> main() async {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) {
    final m = r.message;
    if (m.contains('progress') ||
        m.contains('omplete') ||
        m.contains('size') ||
        m.contains('Metadata')) {
      print('  [${r.loggerName}] $m');
    }
  });

  final metadata = MetadataDownloader(ihHex);
  final ml = metadata.createListener();
  metadata.startDownload();
  final tracker = TorrentAnnounceTracker(metadata);
  final tl = tracker.createListener();
  var done = false;

  ml.on<MetaDataDownloadProgress>(
      (e) => print('metadata progress: ${e.progress.toStringAsFixed(1)}%'));
  ml.on<MetaDataDownloadComplete>((e) {
    done = true;
    print('>>> SUCCESS: METADATA RECEIVED (${e.data.length} bytes) from public '
        'internet peers — metadata fetch works with 0.5.4 + findPublicTrackers.');
  });

  final ihBuf = Uint8List.fromList(hexString2Buffer(ihHex)!);
  tl.on<AnnouncePeerEventEvent>((event) {
    if (event.event == null) return;
    for (final p in event.event!.peers) {
      metadata.addNewPeerAddress(p, PeerSource.tracker);
    }
  });
  tracker.runTracker(
      Uri.parse('http://bttracker.debian.org:6969/announce'), ihBuf);
  findPublicTrackers().listen((urls) {
    for (final u in urls) {
      tracker.runTracker(u, ihBuf);
    }
  });

  for (var i = 1; i <= 36 && !done; i++) {
    await Future.delayed(const Duration(seconds: 5));
    if (!done) print('t=${i * 5}s  waiting for metadata...');
  }
  if (!done) print('>>> FAILED: metadata not received.');
  exit(0);
}
