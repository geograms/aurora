// Exercises the EXACT TorrentService.fetch() code path on real data:
//   MetadataDownloader (BEP-9 over the internet)
//     -> bencode.encode({'info': bencode.decode(metadata)})
//     -> TorrentParser.parseBytes(...)            (0.5.4 API)
//     -> TorrentTask.newTask(model, dir) + start  (peer download path)
// Proves the migrated fetch() wiring works without needing the archive.
//   dart run tool/bt_fetch_path_check.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';

const ihHex = '58846860f0a766f8a42b0bb214d8c713fdf1b167'; // debian-13.5.0 netinst

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('btfetch');
  final metadata = MetadataDownloader(ihHex);
  final ml = metadata.createListener();
  final tracker = TorrentAnnounceTracker(metadata);
  final tl = tracker.createListener();
  final ihBuf = Uint8List.fromList(hexString2Buffer(ihHex)!);
  var done = false;

  tl.on<AnnouncePeerEventEvent>((e) {
    for (final p in e.event?.peers ?? const []) {
      metadata.addNewPeerAddress(p, PeerSource.tracker);
    }
  });

  ml.on<MetaDataDownloadComplete>((e) async {
    // ---- this is exactly what fetch() does ----
    final wrapped = <int>[]
      ..addAll('d4:info'.codeUnits)
      ..addAll(e.data)
      ..add(0x65); // 'e'
    final model = TorrentParser.parseBytes(Uint8List.fromList(wrapped));
    print('parsed model: name="${model.name}" length=${model.length} '
        'pieces=${model.pieces?.length} infohash=${model.infoHash}');
    if (model.infoHash != ihHex) {
      print('>>> FAILED: parsed infohash does not match');
      exit(1);
    }
    final task = TorrentTask.newTask(model, dir.path);
    await task.start();
    for (final t in const [
      'http://bttracker.debian.org:6969/announce',
      'udp://tracker.opentrackr.org:1337/announce',
      'udp://open.demonii.com:1337/announce',
    ]) {
      try {
        task.startAnnounceUrl(Uri.parse(t), model.infoHashBuffer);
      } catch (_) {}
    }
    for (var i = 1; i <= 12; i++) {
      await Future.delayed(const Duration(seconds: 5));
      final dl = task.downloaded ?? 0;
      print('t=${i * 5}s peers=${task.connectedPeersNumber} downloaded=$dl');
      if (dl > 1024 * 1024) {
        print('>>> SUCCESS: full fetch() path works — metadata fetched, '
            'parsed via TorrentParser.parseBytes, and ${(dl / 1048576).toStringAsFixed(1)} MB '
            'downloaded from peers.');
        done = true;
        break;
      }
    }
    exit(done ? 0 : 1);
  });

  // Register listeners (above) BEFORE startDownload, exactly like fetch() does,
  // so a cache-hit emit isn't missed.
  await metadata.startDownload();
  tracker.runTracker(
      Uri.parse('http://bttracker.debian.org:6969/announce'), ihBuf);
  findPublicTrackers().listen((urls) {
    for (final u in urls) {
      tracker.runTracker(u, ihBuf);
    }
  });

  await Future.delayed(const Duration(seconds: 150));
  print('>>> FAILED: timed out');
  exit(1);
}
