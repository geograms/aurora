// Does the DOWNLOAD (peer wire) path work over the internet when metadata is
// already known? Loads a real .torrent (full metadata) → TorrentTask → start →
// announce → download pieces from public peers. Isolates "metadata fetch broken"
// from "peer download broken". Run: dart run tool/bt_download_check.dart <file.torrent>
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:logging/logging.dart';

const trackers = [
  'http://bttracker.debian.org:6969/announce',
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://open.demonii.com:1337/announce',
];

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty ? args[0] : '/tmp/deb.torrent';
  var shown = 0;
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) {
    if (shown++ < 40) print('  [${r.loggerName}] ${r.message}');
  });
  final dir = Directory.systemTemp.createTempSync('btdl');
  final model = await TorrentParser.parse(path);
  print('torrent: "${model.name}" ${model.length} bytes / '
      '${model.pieces.length} pieces / piece=${model.pieceLength}');
  final task = TorrentTask.newTask(model, dir.path);
  await task.start();
  for (final t in trackers) {
    try {
      task.startAnnounceUrl(Uri.parse(t), model.infoHashBuffer);
    } catch (_) {}
  }
  for (var i = 1; i <= 30; i++) {
    await Future.delayed(const Duration(seconds: 5));
    final dl = task.downloaded ?? 0;
    print('t=${i * 5}s  peers=${task.connectedPeersNumber}  '
        'down=${task.currentDownloadSpeed.toStringAsFixed(0)}B/s  '
        'downloaded=$dl');
    if (dl > 2 * 1024 * 1024) {
      print('>>> SUCCESS: downloaded ${(dl / 1048576).toStringAsFixed(1)} MB '
          'from public peers — the peer DOWNLOAD path works over the internet.');
      break;
    }
  }
  exit(0);
}
