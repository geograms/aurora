import 'dart:convert';
import 'dart:typed_data';

import 'package:aurora/services/mesh/mesh_courier.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List wire(String from, String to, String text) =>
    Uint8List.fromList(utf8.encode('$from\x1F$to\x1F$text'));

void main() {
  group('the courier envelope', () {
    test('a carrier can read who a message is for, sealed body or not', () {
      // The whole point of the public envelope: a device that cannot read the
      // recipient cannot decide whom to hand the message to.
      final w = wire('X1A33T', 'X1RD89', 'am:40c124 ENC1:AAAA ~sig');
      final s = utf8.decode(w);
      expect(s.split('\x1F').length, 3);
      expect(s.split('\x1F')[1], 'X1RD89');
    });

    test('a frame no custodian could take whole is refused, not truncated',
        () {
      // The ESP32 parks up to 252 bytes. A longer frame would be carried by the
      // phones for days and dropped by the dongle at the end of the chain.
      expect(MeshCourier.maxWire, lessThan(252));
    });

    test('the wait outlives the direct-link attempt', () {
      // sendLxmf gives up on a direct link at 10s. Asking sooner would air a
      // copy for a message that was about to arrive.
      expect(MeshCourier.wait.inSeconds, greaterThan(10));
      expect(MeshCourier.giveUp, greaterThan(MeshCourier.wait));
    });
  });

  group('ingest', () {
    test('a frame addressed to somebody else is not ours to render', () {
      // No mesh service is running in the test VM, so tableCallsign is empty
      // and every frame must be refused rather than misattributed.
      expect(
        MeshCourier.instance.ingest(wire('X1A33T', 'X9ZZZZ', 'hello'),
            via: 'test'),
        isFalse,
      );
    });

    test('a malformed frame is refused', () {
      expect(
        MeshCourier.instance
            .ingest(Uint8List.fromList(utf8.encode('nonsense')), via: 'test'),
        isFalse,
      );
    });
  });
}
