// Phase 4 (2-hop): validate the multi-layer inbound tunnel-data crypto without
// the network. Simulate a 2-hop inbound tunnel: the gateway (hop1) encrypts,
// then hop2 encrypts; the endpoint decrypts both layers in order (hop2, hop1)
// and must recover the original plaintext region.
//   dart run tool/i2p_2hop_crypto_test.dart
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_crypto.dart';
import 'package:aurora/services/i2p/i2p_tunnel_data.dart';

String hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

TunnelLayer randLayer(int seed) {
  Uint8List k(int s) =>
      I2pCrypto.sha256(Uint8List.fromList('layer$s'.codeUnits));
  return TunnelLayer(k(seed), k(seed + 100));
}

void main() {
  var pass = 0, fail = 0;
  void check(String n, bool ok) {
    ok ? pass++ : fail++;
    print('  ${ok ? "ok  " : "FAIL"} $n');
  }

  final hop1 = randLayer(1); // gateway
  final hop2 = randLayer(2); // endpoint-adjacent

  // Original plaintext region (16-byte IV + 1008-byte data).
  final region = Uint8List.fromList(
      List.generate(1024, (i) => (i * 31 + 7) & 0xff));

  // As the message travels gateway -> hop2 -> endpoint, each hop ENCRYPTS.
  final afterHop1 = hop1.encrypt(region);
  final onWire = hop2.encrypt(afterHop1);

  // Endpoint decrypts in m_Hops order (endpoint-adjacent first): hop2, then hop1.
  final recovered = decryptLayers([hop2, hop1], onWire);
  check('2-layer roundtrip recovers region', hx(recovered) == hx(region));

  // 1-hop still works (single layer).
  final one = hop1.encrypt(region);
  final back1 = decryptLayers([hop1], one);
  check('1-layer roundtrip', hx(back1) == hx(region));

  // Wrong decrypt order fails (sanity).
  final wrong = decryptLayers([hop1, hop2], onWire);
  check('wrong order does NOT recover', hx(wrong) != hx(region));

  print('\n$pass passed, $fail failed');
  print(fail == 0
      ? '>>> SUCCESS: multi-hop inbound tunnel-data layering is correct'
      : '>>> FAILED');
}
