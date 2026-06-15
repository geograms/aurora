// Phase 0 GATE: reseed -> pick a live NTCP2 router -> full Noise XK handshake
// -> data phase -> send an I2NP DatabaseLookup -> receive a DatabaseStore or
// DatabaseSearchReply. Proves the pure-Dart NTCP2 stack interoperates with the
// real I2P network.
//   dart run tool/i2p_ntcp2_test.dart
import 'package:aurora/services/i2p/i2p_i2np.dart';
import 'package:aurora/services/i2p/i2p_ntcp2.dart';
import 'package:aurora/services/i2p/i2p_reseed.dart';
import 'package:aurora/services/i2p/i2p_router.dart';
import 'package:aurora/services/i2p/i2p_structures.dart';

Future<void> main() async {
  print('=== I2P NTCP2 handshake gate ===');
  final blobs = await reseed(log: print);
  if (blobs.isEmpty) {
    print('>>> FAILED: reseed returned nothing');
    return;
  }

  // Need full inbound-reachable NTCP2 routers: host, port, static key s, IV i.
  final candidates = <RouterInfo>[];
  for (final raw in blobs) {
    final ri = parseRouterInfo(raw);
    if (ri == null) continue;
    final a = ri.ntcp2;
    if (a == null) continue;
    if (a.host == null || a.port == null) continue;
    if (a.staticKey?.length != 32) continue;
    if (a.iv?.length != 16) continue;
    candidates.add(ri);
  }
  print('reseed: ${blobs.length} blobs, ${candidates.length} reachable NTCP2 routers');
  if (candidates.isEmpty) {
    print('>>> FAILED: no reachable NTCP2 routers to dial');
    return;
  }

  print('generating our router identity...');
  final us = await OurRouter.generate();
  print('our router hash: ${_hx(us.identityHash).substring(0, 16)}... '
      'RI=${us.routerInfo.length}b');

  var tried = 0;
  for (final bob in candidates) {
    if (tried >= 8) break;
    tried++;
    final a = bob.ntcp2!;
    print('\n--- attempt $tried: ${a.host}:${a.port} '
        'caps=${bob.options['caps']} ---');
    final s = Ntcp2Session(bob, us, log: print);
    try {
      await s.handshake();
    } catch (e) {
      print('handshake failed: $e');
      s.close();
      continue;
    }
    try {
      // Look up the router's own hash: it should answer with a DatabaseStore
      // (its own RI) or a DatabaseSearchReply with closer floodfills.
      final lookup = buildDatabaseLookup(bob.identityHash, us.identityHash);
      await s.sendI2np(I2npType.databaseLookup, lookup);
      print('sent DatabaseLookup for ${_hx(bob.identityHash).substring(0, 16)}...');
      final reply = await s.awaitI2npReply(const Duration(seconds: 20));
      if (reply != null) {
        print('\n>>> SUCCESS: live I2NP reply over pure-Dart NTCP2:');
        print('    ${reply.summary}');
        s.close();
        return;
      }
      print('no I2NP reply before timeout');
    } catch (e) {
      print('data phase error: $e');
    }
    s.close();
  }
  print('\n>>> FAILED: handshake/lookup did not complete against any router');
}

String _hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
