// Phase 4: run the I2pNode in a background ISOLATE via I2pWorker (so it can't
// starve the UI isolate). The worker serves content by sha256 with the bytes
// supplied from the MAIN isolate through the onGet bridge; a plain node fetches
// it. Local i2pd (netid 9).
//   dart run tool/i2p_worker_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_crypto.dart';
import 'package:aurora/services/i2p/i2p_node.dart';
import 'package:aurora/services/i2p/i2p_structures.dart';
import 'package:aurora/services/i2p/i2p_worker.dart';

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main() async {
  final riBytes = await File('/tmp/i2pd-data/router.info').readAsBytes();
  final ri = parseRouterInfo(riBytes)!;
  final iv = Uint8List.fromList(
      (await File('/tmp/i2pd-data/ntcp2.keys').readAsBytes()).sublist(64, 80));
  final content = Uint8List.fromList('served from a background isolate'.codeUnits);
  final sha = I2pCrypto.sha256(content);

  // Worker isolate serves content; the bytes come from THIS (main) isolate.
  final worker = I2pWorker(
    log: (m) => print('[worker] $m'),
    onGet: (s) async => hx(s) == hx(sha) ? content : null,
  );
  final b32 = await worker.start(I2pWorkerConfig(
      netId: 9, hostOverride: '127.0.0.1', portOverride: 27654, ivOverride: iv,
      peersRaw: [Uint8List.fromList(riBytes)]));
  if (b32 == null) {
    print('>>> FAILED: worker did not start');
    return;
  }
  final workerDest = i2pBase32Decode(b32)!;
  print('worker (isolate) up: $b32');

  // Plain node on the main isolate fetches from the worker.
  final fetcher = I2pNode(netId: 9, log: (m) => print('[fetch] $m'));
  await fetcher.start(peers: [ri], hostOverride: '127.0.0.1', portOverride: 27654, ivOverride: iv);
  await Future.delayed(const Duration(seconds: 2));

  print('fetching from the isolate-hosted node...');
  final got = await fetcher.fetch(workerDest, sha, timeout: const Duration(seconds: 25));
  final ok = got != null && hx(I2pCrypto.sha256(got)) == hx(sha);

  // Also exercise pause/resume across the isolate boundary.
  await worker.pause();
  await worker.resume();
  print('worker pause/resume across isolate: ok');

  print(ok
      ? '\n>>> SUCCESS: fetched ${got.length} bytes from a node running in a '
        'background isolate (onGet bridged to the main isolate)'
      : '\n>>> FAILED: got ${got?.length} bytes');
  fetcher.close();
  worker.stop();
}
