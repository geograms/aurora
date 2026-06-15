// Phase 0: reseed from the live I2P network and parse RouterInfos, reporting how
// many usable NTCP2 routers (host, port, static key s, IV i) we found.
//   dart run tool/i2p_reseed_test.dart
import 'package:aurora/services/i2p/i2p_reseed.dart';
import 'package:aurora/services/i2p/i2p_structures.dart';

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main() async {
  final ris = await reseed(log: print);
  if (ris.isEmpty) {
    print('>>> FAILED: no routerInfos from any reseed server');
    return;
  }
  var parsed = 0, ntcp2 = 0;
  final samples = <RouterInfo>[];
  for (final raw in ris) {
    final ri = parseRouterInfo(raw);
    if (ri == null) continue;
    parsed++;
    final a = ri.ntcp2;
    if (a != null && a.port != null && (a.staticKey?.length == 32)) {
      ntcp2++;
      if (samples.length < 5) samples.add(ri);
    }
  }
  print('\nreseed: ${ris.length} blobs, $parsed parsed, $ntcp2 usable NTCP2 routers');
  for (final ri in samples) {
    final a = ri.ntcp2!;
    print('  router ${hx(ri.identityHash).substring(0, 16)}... '
        '${a.host}:${a.port} s=${a.staticKey!.length}B i=${a.iv?.length}B '
        'v=${a.options['v']} caps=${a.options['caps']}');
  }
  if (ntcp2 > 0) {
    print('>>> SUCCESS: reseeded and parsed live RouterInfos; have NTCP2 targets.');
  } else {
    print('>>> PARTIAL: reseed worked but no usable NTCP2 routers parsed.');
  }
}
