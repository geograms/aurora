// Phase 0 debug: handshake + DatabaseLookup against a LOCAL i2pd whose
// router.info we read from disk. Pair with i2pd debug logs to see exactly how
// the reference router reacts to our pure-Dart NTCP2 frames.
//   dart run tool/i2p_local_test.dart /tmp/i2pd-data/router.info 127.0.0.1 27654
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_i2np.dart';
import 'package:aurora/services/i2p/i2p_ntcp2.dart';
import 'package:aurora/services/i2p/i2p_router.dart';
import 'package:aurora/services/i2p/i2p_structures.dart';

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty ? args[0] : '/tmp/i2pd-data/router.info';
  final host = args.length > 1 ? args[1] : '127.0.0.1';
  final port = args.length > 2 ? int.parse(args[2]) : 27654;

  final raw = await File(path).readAsBytes();
  final bob = parseRouterInfo(raw);
  if (bob == null) {
    print('>>> could not parse $path');
    return;
  }
  final a = bob.ntcp2;
  print('local router hash: ${_hx(bob.identityHash).substring(0, 16)}...');
  print('ntcp2 addr in file: ${a?.host}:${a?.port} '
      's=${a?.staticKey?.length}B i=${a?.iv?.length}B v=${a?.options['v']}');
  if (a == null || a.staticKey?.length != 32) {
    print('>>> local router has no usable NTCP2 static key');
    return;
  }

  // The IV 'i' is only published when reachable; for local testing read it from
  // ntcp2.keys (32 static pub + 32 static priv + 16 IV = 80 bytes).
  Uint8List? iv;
  final keysFile = File('${File(path).parent.path}/ntcp2.keys');
  if (keysFile.existsSync()) {
    final kb = await keysFile.readAsBytes();
    if (kb.length >= 80) iv = Uint8List.fromList(kb.sublist(64, 80));
    print('read IV from ntcp2.keys: ${iv != null}');
  }

  final netId = args.length > 3 ? int.parse(args[3]) : 2;
  final us = await OurRouter.generate(netId: netId);
  print('our router hash: ${_hx(us.identityHash).substring(0, 16)}... '
      'b64=${i2pBase64Encode(us.identityHash)} netId=$netId');

  final s = Ntcp2Session(bob, us,
      log: print,
      hostOverride: host,
      portOverride: port,
      ivOverride: iv,
      netId: netId);
  try {
    await s.handshake();
  } catch (e) {
    print('>>> handshake threw: $e');
    s.close();
    return;
  }
  final lookup = buildDatabaseLookup(bob.identityHash, us.identityHash);
  await s.sendI2np(I2npType.databaseLookup, lookup);
  print('sent DatabaseLookup for the local router');
  final reply = await s.awaitI2npReply(const Duration(seconds: 25));
  if (reply != null) {
    print('\n>>> SUCCESS: ${reply.summary}');
  } else {
    print('\n>>> no reply');
  }
  s.close();
}

String _hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
