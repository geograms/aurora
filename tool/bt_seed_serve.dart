// Desktop seeder for the device-to-device test. Creates a unique file (or seeds
// the one you pass), builds the deterministic torrent, pre-writes a complete
// state so it seeds at 100%, announces to public trackers + DHT + UPnP, and
// STAYS ALIVE serving metadata (BEP-9) and data to any peer that joins by
// infohash — e.g. the phone fetching over its cellular network.
//   dart run tool/bt_seed_serve.dart [path/to/image]
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:logging/logging.dart';

const trackers = [
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://open.demonii.com:1337/announce',
  'udp://exodus.desync.com:6969/announce',
  'udp://tracker.torrent.eu.org:451/announce',
];

int _pieceLengthFor(int size) {
  if (size <= 0) return 16384;
  final target = (size / 1024).ceil();
  var p = 16384;
  while (p < target && p < 4 * 1024 * 1024) {
    p <<= 1;
  }
  return math.min(p, 4 * 1024 * 1024);
}

String _b64u(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Future<void> main(List<String> args) async {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) {
    final m = r.message;
    if (m.contains('orward') ||
        m.contains('External IP') ||
        m.contains('NAT') ||
        m.contains('pnp') ||
        m.contains('PnP') ||
        m.contains('mapping')) {
      print('  [nat] $m');
    }
  });
  final dir = Directory.systemTemp.createTempSync('btseedserve');
  late Uint8List data;
  String ext;
  if (args.isNotEmpty && File(args[0]).existsSync()) {
    data = await File(args[0]).readAsBytes();
    final dot = args[0].lastIndexOf('.');
    ext = dot > 0 ? args[0].substring(dot + 1) : 'bin';
  } else {
    // Minimal unique PNG-ish payload (content-addressing doesn't care if it's a
    // real image; the phone verifies sha256, not the pixels).
    // FIXED content (no pid) so the infohash is stable across seeder restarts.
    final b = Uint8List(64 * 1024);
    for (var i = 0; i < b.length; i++) {
      b[i] = (i * 2654435761 >> 11) & 0xFF;
    }
    // PNG magic so the ext is honest-ish
    b.setAll(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    data = b;
    ext = 'png';
  }

  final hashBytes = sha256.convert(data).bytes;
  final hex = hashBytes
      .map((x) => x.toRadixString(16).padLeft(2, '0'))
      .join();
  final b64u = _b64u(hashBytes);

  final f = File('${dir.path}/$hex.$ext');
  await f.writeAsBytes(data, flush: true);

  final model = await TorrentCreator.createTorrent(
    f.path,
    TorrentCreationOptions(
      pieceLength: _pieceLengthFor(data.length),
      trackers: [for (final t in trackers) Uri.parse(t)],
      creationDate: 0,
    ),
  );
  final ih = model.infoHash;

  // complete state -> seed at 100%
  final pieces = model.pieces!.length;
  final bf = (pieces + 7) ~/ 8;
  final state = Uint8List(bf + 8)..fillRange(0, bf, 0xFF);
  await File('${dir.path}/$ih.bt.state').writeAsBytes(state, flush: true);

  final task = TorrentTask.newTask(model, dir.path);
  await task.start();
  for (final t in trackers) {
    try {
      task.startAnnounceUrl(Uri.parse(t), model.infoHashBuffer);
    } catch (_) {}
  }

  print('=========================================================');
  print('SEEDING ${data.length} bytes as $hex.$ext');
  print('SHA256_HEX   = $hex');
  print('SHA256_B64U  = $b64u');
  print('EXT          = $ext');
  print('INFOHASH     = $ih');
  print('WIRE         = file:$b64u.$ext ih:$ih');
  print('peerPort     = ${task.peerPort}');
  print('=========================================================');

  var ticks = 0;
  Timer.periodic(const Duration(seconds: 10), (_) {
    ticks++;
    print('t=${ticks * 10}s peers=${task.connectedPeersNumber} '
        'seeders=${task.seederNumber} up=${task.uploadSpeed.toStringAsFixed(1)}');
  });
  // stay alive
  await Completer<void>().future;
}
