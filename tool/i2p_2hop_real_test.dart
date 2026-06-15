// Phase 4 (2-hop): build a 2-HOP inbound tunnel on the LIVE network (gateway +
// one middle hop, hiding our router from the gateway), publish the LeaseSet2,
// and look it back up — confirming both hops accepted the build (multi-record
// build + reply de-layering) and the lease (gateway = hop1) is retrievable.
//   dart run tool/i2p_2hop_real_test.dart
import 'package:aurora/services/i2p/i2p_node.dart';

Future<void> main() async {
  final n = I2pNode(netId: 2, log: (m) => print(m));
  final ok = await n.start(hops: 2);
  if (!ok) {
    print('>>> FAILED: 2-hop node did not come up');
    return;
  }
  print('2-hop node up, b32=${n.b32}, gateways=${n.gatewayCount}');
  final lease = await n.lookupLease(n.destHash);
  if (lease != null) {
    print('>>> SUCCESS: 2-hop inbound tunnel built on the live network and its '
        'LeaseSet2 (gateway lease tunnelId=${lease.tunnelId}) is retrievable');
  } else {
    print('>>> PARTIAL: 2-hop tunnel built + published but self-lookup did not '
        'return the LeaseSet');
  }
  n.close();
}
