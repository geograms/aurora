// RNS-over-BLE broadcast semantics (no hardware): proves the group-efficiency
// goal — a single connectionless broadcast reaches all N in-range nodes, so a
// group announce/message is aired ONCE instead of N point-to-point sends.
//
//   dart run tool/reticulum_ble_sim_test.dart
import 'dart:typed_data';

import 'package:aurora/services/reticulum/rns_announce.dart';
import 'package:aurora/services/reticulum/rns_ble_interface.dart';
import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/reticulum/rns_transport.dart';

/// A shared broadcast medium: every aired frame is delivered to all OTHER radios
/// (as a real BLE advertisement is heard by every scanner in range).
class _Bus {
  final List<_MemRadio> radios = [];
  int airCount = 0;
  void air(_MemRadio from, Uint8List frame) {
    airCount++;
    for (final r in radios) {
      if (!identical(r, from)) r.deliver(frame);
    }
  }
}

class _MemRadio implements RnsBleRadio {
  final _Bus bus;
  void Function(Uint8List)? _handler;
  _MemRadio(this.bus) {
    bus.radios.add(this);
  }
  @override
  int get broadcastCap => 300;
  @override
  void broadcast(Uint8List frame) => bus.air(this, frame);
  @override
  bool unicast(Uint8List frame) {
    bus.air(this, frame);
    return true;
  }
  @override
  void onReceive(void Function(Uint8List) handler) => _handler = handler;
  void deliver(Uint8List frame) => _handler?.call(frame);
}

class _Node {
  final RnsIdentity id;
  final RnsTransport transport;
  final RnsBleInterface iface;
  _Node(this.id, this.transport, this.iface);
}

var _pass = 0, _fail = 0;
void check(String name, bool ok, [String extra = '']) {
  if (ok) {
    _pass++;
    print('  ok   $name');
  } else {
    _fail++;
    print('  FAIL $name${extra.isNotEmpty ? "  ($extra)" : ""}');
  }
}

Future<void> main() async {
  const n = 5;
  final bus = _Bus();
  final nodes = <_Node>[];
  for (var i = 0; i < n; i++) {
    final id = await RnsIdentity.generate();
    final transport = RnsTransport();
    final radio = _MemRadio(bus);
    final iface = RnsBleInterface(
      radio: radio,
      onPacket: (raw) {
        final p = RnsPacket.parse(raw);
        if (p != null) transport.ingest(p, 'ble');
      },
    );
    nodes.add(_Node(id, transport, iface));
  }

  // Node 0 announces a "group" destination once over the broadcast medium.
  final sender = nodes[0];
  final ann = await RnsAnnounceBuilder.build(
      sender.id, 'aurora', ['groupchat'],
      appData: Uint8List.fromList('hello group'.codeUnits));
  final announceHash =
      RnsDestination.hash(sender.id, 'aurora', ['groupchat']);
  print('Sender ${sender.id.hexHash} airing one announce '
      'for dest ${_hx(announceHash)} to $n-node group');
  sender.iface.send(ann.pack());

  // Let the async signature validations settle.
  await Future<void>.delayed(const Duration(milliseconds: 200));

  // Exactly one transmission hit the air...
  check('single broadcast transmission', bus.airCount == 1,
      'airCount=${bus.airCount}');
  check('sender counted one broadcast', sender.iface.broadcastCount == 1);

  // ...yet every other node received and validated it.
  var receivers = 0;
  for (var i = 1; i < n; i++) {
    if (nodes[i].transport.hasPath(announceHash)) receivers++;
  }
  check('all ${n - 1} peers learned the group dest from ONE send',
      receivers == n - 1, 'receivers=$receivers');

  print('\nEfficiency: 1 broadcast reached ${n - 1} peers '
      '(GATT-only would need ${n - 1} separate sends).');
  print('$_pass passed, $_fail failed');
  if (_fail == 0) {
    print('>>> SUCCESS: broadcast delivers a group message once to all peers.');
  } else {
    print('>>> FAILED');
  }
}

String _hx(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
