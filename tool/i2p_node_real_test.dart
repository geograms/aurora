// Phase 3 real-network validation: a single I2pNode on the live public I2P
// network. Reseeds, dials a real floodfill, builds an inbound tunnel through a
// real router, publishes its LeaseSet2, then looks its own LeaseSet back up
// from the floodfill. Proves the node interoperates on the real net.
//   dart run tool/i2p_node_real_test.dart
import 'package:aurora/services/i2p/i2p_node.dart';

Future<void> main() async {
  final n = I2pNode(netId: 2, log: (m) => print(m));
  final ok = await n.start();
  if (!ok) {
    print('>>> FAILED: node did not come up on the live network');
    return;
  }
  print('node b32 = ${n.b32}');
  print('looking up our own LeaseSet from the floodfill...');
  final lease = await n.lookupLease(n.destHash);
  if (lease != null) {
    print('>>> SUCCESS: built a real-network tunnel and our LeaseSet2 is '
        'retrievable (lease tunnelId=${lease.tunnelId})');
  } else {
    print('>>> PARTIAL: tunnel+publish ok but self-lookup did not return the LeaseSet');
  }
  n.close();
}
