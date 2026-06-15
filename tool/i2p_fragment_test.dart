// Unit test for the gateway-side fragmenter (outbound preprocessing): fragment
// an I2NP message into cleartext tunnel cells and confirm the reassembler (our
// inbound-endpoint code, proven byte-for-byte vs i2pd) reconstructs it exactly —
// in order, out of order, single- and multi-cell, LOCAL and TUNNEL delivery.
//   dart run tool/i2p_fragment_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/i2p/i2p_tunnel_data.dart';

var _pass = 0, _fail = 0;
void ok(bool c, String m) {
  if (c) {
    _pass++;
    print('  ok   $m');
  } else {
    _fail++;
    print('  FAIL $m');
  }
}

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

// A plausible I2NP message: 16-byte standard header (type, msgId@1..4, ...) + body.
Uint8List i2np(int len, int msgId, int seed) {
  final m = Uint8List(len);
  m[0] = 20; // type Data
  m[1] = (msgId >> 24) & 0xff;
  m[2] = (msgId >> 16) & 0xff;
  m[3] = (msgId >> 8) & 0xff;
  m[4] = msgId & 0xff;
  for (var i = 5; i < len; i++) {
    m[i] = (i * seed + 11) & 0xff;
  }
  return m;
}

List<Uint8List> reassembleAll(List<Uint8List> cells) {
  final r = TunnelReassembler();
  final out = <Uint8List>[];
  for (final c in cells) {
    out.addAll(r.addCell(c));
  }
  return out;
}

void roundtrip(String label, Uint8List msg, {int dt = 0, Uint8List? toHash, int toTunnel = 0}) {
  final cells = fragmentForTunnel(
      message: msg, deliveryType: dt, toHash: toHash, toTunnel: toTunnel);
  // in order
  final got = reassembleAll(cells);
  ok(got.length == 1 && hex(got[0]) == hex(msg),
      '$label in-order (${cells.length} cell(s))');
  // out of order (reversed)
  if (cells.length > 1) {
    final got2 = reassembleAll(cells.reversed.toList());
    ok(got2.length == 1 && hex(got2[0]) == hex(msg), '$label reversed');
  }
}

Future<void> main() async {
  print('fragmenter roundtrip:');
  roundtrip('LOCAL small', i2np(120, 0x11111111, 7));
  roundtrip('LOCAL ~1 cell edge', i2np(990, 0x22222222, 3));
  roundtrip('LOCAL multi (5000)', i2np(5000, 0x33333333, 5));
  roundtrip('LOCAL large (33000)', i2np(33000, 0x44444444, 9));

  final gw = Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + 1) & 0xff));
  roundtrip('TUNNEL small', i2np(200, 0x55555555, 2), dt: 1, toHash: gw, toTunnel: 0x0a0b0c0d);
  roundtrip('TUNNEL multi (4000)', i2np(4000, 0x66666666, 4), dt: 1, toHash: gw, toTunnel: 0x0a0b0c0d);

  // verify the first cell's delivery instructions decode as TUNNEL to (gw, tunnel)
  final cells = fragmentForTunnel(
      message: i2np(4000, 0x77777777, 6), deliveryType: 1, toHash: gw, toTunnel: 0x0a0b0c0d);
  final frs = parseCellFragments(cells.first);
  ok(frs.isNotEmpty && !frs.first.followOn && frs.first.deliveryType == 1 && frs.first.fragmented,
      'first fragment is TUNNEL + fragmented');

  print('\n$_pass passed, $_fail failed');
  if (_fail == 0) print('>>> SUCCESS: outbound fragmenter roundtrips through the reassembler');
  exit(_fail == 0 ? 0 : 1);
}
