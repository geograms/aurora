// Proves our pre-written-complete-state SEEDER actually serves DATA pieces to a
// fetcher — the other half of device-to-device (metadata is proven separately in
// bt_serve_metadata_check.dart). Single clean peer connection: the fetcher uses
// the full model directly (no metadata phase) and pulls the file from our seeder
// alone (no trackers, no DHT, no public peers).
//   dart run tool/bt_serve_data_check.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;
import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';

Future<InternetAddress?> _lanIp() async {
  for (final ni in await NetworkInterface.list(
      type: InternetAddressType.IPv4, includeLoopback: false)) {
    for (final a in ni.addresses) {
      if (!a.isLoopback && !a.isLinkLocal) return a;
    }
  }
  return null;
}

Future<void> main() async {
  final lan = await _lanIp();
  if (lan == null) {
    print('>>> SKIP: no non-loopback LAN IPv4 found');
    exit(0);
  }
  print('LAN IP: ${lan.address}');

  final sdir = Directory.systemTemp.createTempSync('btseed');
  final file = File('${sdir.path}/aurora-data-test-$pid.bin');
  final bytes = Uint8List(2 * 1024 * 1024);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = ((i + pid) * 2654435761 >> 13) & 0xFF;
  }
  await file.writeAsBytes(bytes, flush: true);
  final wantHash = sha1.convert(bytes).toString();

  final model = await TorrentCreator.createTorrent(
      file.path, TorrentCreationOptions(pieceLength: 262144, creationDate: 0));
  final ih = model.infoHash;
  print('seed: name="${model.name}" len=${model.length} '
      'pieces=${model.pieces?.length} ih=$ih');

  // pre-write COMPLETE state so the task seeds at 100%
  final pieces = model.pieces!.length;
  final bf = (pieces + 7) ~/ 8;
  final state = Uint8List(bf + 8)..fillRange(0, bf, 0xFF);
  await File('${sdir.path}/$ih.bt.state').writeAsBytes(state, flush: true);

  final seeder = TorrentTask.newTask(model, sdir.path);
  await seeder.start();
  for (var i = 0; i < 20 && (seeder.peerPort ?? 0) == 0; i++) {
    await Future.delayed(const Duration(milliseconds: 100));
  }
  final port = seeder.peerPort!;
  print('seeder port=$port progress=${seeder.progress}');

  // fetcher: fresh dir, full model, single connection straight to the seeder.
  var done = false;
  final fdir = Directory.systemTemp.createTempSync('btfetch');
  final task = TorrentTask.newTask(model, fdir.path);
  final tl = task.createListener();
  tl.on<TaskCompleted>((_) {
    final got = File('${fdir.path}/${model.name}').readAsBytesSync();
    final ok = sha1.convert(got).toString() == wantHash;
    print('>>> ${ok ? 'SUCCESS' : 'FAILED'}: file (${got.length} B) downloaded '
        'from our single complete-state seeder, content '
        '${ok ? 'matches' : 'MISMATCH'}. Seeder serves data.');
    done = true;
    exit(ok ? 0 : 1);
  });
  await task.start();
  task.addPeer(CompactAddress(lan, port), PeerSource.manual);

  for (var i = 1; i <= 15 && !done; i++) {
    await Future.delayed(const Duration(seconds: 2));
    print('t=${i * 2}s data=${(task.progress * 100).toStringAsFixed(1)}% '
        'fpeers=${task.connectedPeersNumber} speers=${seeder.connectedPeersNumber} '
        'down=${task.downloaded ?? 0}');
  }
  if (!done) print('>>> FAILED: seeder did not serve data');
  exit(done ? 0 : 1);
}
