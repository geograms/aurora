// Proves a dtorrent SEEDER now serves BEP-9 metadata to a peer that joined by
// infohash alone — the device-to-device case where our app is the ONLY seeder
// (no public peers, no DHT, no trackers). Without the ut_metadata serving added
// to PeersManager this fetch can never complete.
//
// One process: start a seeder over a freshly-created unique file, then point a
// MetadataDownloader DIRECTLY at the seeder's LAN address and nothing else.
//   dart run tool/bt_serve_metadata_check.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;
import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:logging/logging.dart';

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
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((r) {
    final m = r.message;
    if (m.contains('onnect') ||
        m.contains('andshake') ||
        m.contains('ispose') ||
        m.contains('hoke') ||
        m.contains('nterest') ||
        m.contains('itfield') ||
        m.contains('Cannot create') ||
        m.contains('gnored') ||
        m.contains('HAVE')) {
      print('  [${r.loggerName}] ${m.length > 120 ? m.substring(0, 120) : m}');
    }
  });
  final lan = await _lanIp();
  if (lan == null) {
    print('>>> SKIP: no non-loopback LAN IPv4 found');
    exit(0);
  }
  print('LAN IP: ${lan.address}');

  // --- unique content so this infohash exists nowhere but here ---
  final dir = Directory.systemTemp.createTempSync('btseed');
  final file = File('${dir.path}/aurora-serve-test-$pid.bin');
  final bytes = Uint8List(2 * 1024 * 1024);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = ((i + pid) * 2654435761 >> 13) & 0xFF; // unique to this run
  }
  await file.writeAsBytes(bytes, flush: true);

  final model = await TorrentCreator.createTorrent(
      file.path, TorrentCreationOptions(pieceLength: 262144, creationDate: 0));
  final ih = model.infoHash;
  print('seed torrent: name="${model.name}" len=${model.length} '
      'pieces=${model.pieces?.length} infohash=$ih '
      'infoDictBytes=${model.infoDictBytes?.length}');

  // --- pre-write a COMPLETE state so the task seeds at 100% ---
  final pieces = model.pieces!.length;
  final bf = (pieces + 7) ~/ 8;
  final state = Uint8List(bf + 8)..fillRange(0, bf, 0xFF);
  await File('${dir.path}/$ih.bt.state').writeAsBytes(state, flush: true);

  final seeder = TorrentTask.newTask(model, dir.path);
  await seeder.start();
  // give the listener a moment to bind
  for (var i = 0; i < 20 && seeder.peerPort == null; i++) {
    await Future.delayed(const Duration(milliseconds: 100));
  }
  final port = seeder.peerPort;
  print('seeder listening on peer port: $port');
  if (port == null || port == 0) {
    print('>>> FAILED: seeder has no peer port');
    exit(1);
  }

  // --- fetcher: ONLY knows the seeder's address. No tracker, no DHT peers. ---
  var done = false;
  final metadata = MetadataDownloader(ih);
  final ml = metadata.createListener();
  ml.on<MetaDataDownloadProgress>(
      (e) => print('metadata progress: ${e.progress.toStringAsFixed(1)}%'));
  ml.on<MetaDataDownloadComplete>((e) async {
    final metaOk = sha1.convert(e.data).toString() == ih;
    print('metadata received (${e.data.length} bytes) from our seeder, hash '
        '${metaOk ? 'matches' : 'MISMATCH'}');
    if (!metaOk) {
      print('>>> FAILED: metadata hash mismatch');
      exit(1);
    }
    // Now the DATA: reconstruct the torrent exactly like TorrentService.fetch
    // and download the file from the SAME single seeder (no other peers).
    final wrapped = <int>[]
      ..addAll('d4:info'.codeUnits)
      ..addAll(e.data)
      ..add(0x65);
    final fmodel = TorrentParser.parseBytes(Uint8List.fromList(wrapped));
    final fdir = Directory.systemTemp.createTempSync('btfetch');
    final task = TorrentTask.newTask(fmodel, fdir.path);
    final tl = task.createListener();
    tl.on<TaskCompleted>((_) {
      final got = File('${fdir.path}/${fmodel.name}').readAsBytesSync();
      final ok = sha1.convert(got).toString() == sha1.convert(bytes).toString();
      print('>>> ${ok ? 'SUCCESS' : 'FAILED'}: full file (${got.length} B) '
          'downloaded device-to-device from a single seeder (metadata + data, '
          'no trackers/DHT/public peers), content ${ok ? 'matches' : 'MISMATCH'}.');
      done = true;
      exit(ok ? 0 : 1);
    });
    await task.start();
    task.addPeer(CompactAddress(lan, port), PeerSource.manual);
    print('seeder progress=${seeder.progress} '
        'seederComplete=${seeder.progress >= 1.0}');
    for (var i = 1; i <= 8 && !done; i++) {
      await Future.delayed(const Duration(seconds: 2));
      print('t=${i * 2}s data=${(task.progress * 100).toStringAsFixed(1)}% '
          'fpeers=${task.connectedPeersNumber} '
          'speers=${seeder.connectedPeersNumber} '
          'down=${(task.downloaded ?? 0)}');
    }
    if (!done) print('>>> FAILED: data download did not complete');
    exit(1);
  });
  await metadata.startDownload();
  // Point the downloader straight at the seeder — the whole point of the test.
  metadata.addNewPeerAddress(CompactAddress(lan, port), PeerSource.tracker);

  for (var i = 1; i <= 30 && !done; i++) {
    await Future.delayed(const Duration(seconds: 2));
    if (metadata.progress < 100) print('t=${i * 2}s meta waiting...');
  }
  if (!done) print('>>> FAILED: device-to-device transfer did not complete');
  exit(done ? 0 : 1);
}
