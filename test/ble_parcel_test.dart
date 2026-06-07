import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:aurora/connections/bluetooth/ble_parcel.dart';

// Reassemble the way a receiver does: parcel 0 is the header, the rest data.
Uint8List? roundTrip(BLEOutgoingMessage msg) {
  final parcels = msg.toParcels();
  final header = BLEParcel.fromBytesAsHeader(parcels.first.toBytes())!;
  final incoming = BLEIncomingMessage(
    msgId: header.msgId,
    totalParcels: header.totalParcels,
    expectedChecksum: header.checksum,
    flags: header.flags,
    sourceDeviceId: 'peer',
  );
  incoming.addParcel(header);
  for (final p in parcels.skip(1)) {
    incoming.addParcel(BLEParcel.fromBytesAsData(p.toBytes())!);
  }
  expect(incoming.isComplete, isTrue);
  return incoming.assemble();
}

void main() {
  group('BLE parcel protocol (copied from geogram)', () {
    test('single-parcel message round-trips (typical APRS frame)', () {
      final payload = Uint8List.fromList(utf8.encode('CT1ABC\x1fX3WWAJ\x1fhello over a GATT parcel'));
      final out = roundTrip(BLEOutgoingMessage(payload: payload, targetDeviceId: 'peer'));
      expect(out, payload);
    });

    test('multi-parcel message reassembles in order', () {
      final payload = Uint8List.fromList(List.generate(900, (i) => i % 256));
      final msg = BLEOutgoingMessage(payload: payload, targetDeviceId: 'peer');
      expect(msg.toParcels().length, greaterThan(1));
      expect(roundTrip(msg), payload);
    });

    test('out-of-order data parcels still reassemble', () {
      final payload = Uint8List.fromList(List.generate(800, (i) => (i * 7) % 256));
      final parcels = BLEOutgoingMessage(payload: payload, targetDeviceId: 'peer').toParcels();
      final header = BLEParcel.fromBytesAsHeader(parcels.first.toBytes())!;
      final inc = BLEIncomingMessage(
        msgId: header.msgId,
        totalParcels: header.totalParcels,
        expectedChecksum: header.checksum,
        sourceDeviceId: 'peer',
      );
      // add data parcels reversed, header last
      for (final p in parcels.skip(1).toList().reversed) {
        inc.addParcel(BLEParcel.fromBytesAsData(p.toBytes())!);
      }
      expect(inc.isComplete, isFalse);
      inc.addParcel(header);
      expect(inc.isComplete, isTrue);
      expect(inc.assemble(), payload);
    });

    test('corrupted parcel fails the CRC check', () {
      final payload = Uint8List.fromList(utf8.encode('integrity matters here'));
      final parcels = BLEOutgoingMessage(payload: payload, targetDeviceId: 'peer').toParcels();
      final header = BLEParcel.fromBytesAsHeader(parcels.first.toBytes())!;
      final inc = BLEIncomingMessage(
        msgId: header.msgId,
        totalParcels: header.totalParcels,
        expectedChecksum: header.checksum,
        sourceDeviceId: 'peer',
      );
      // flip a byte in the header payload
      final bad = Uint8List.fromList(header.data)..[0] ^= 0xFF;
      inc.addParcel(BLEParcel(msgId: header.msgId, parcelNum: 0, data: bad));
      expect(inc.assemble(), isNull); // checksum mismatch
    });

    test('compression round-trips when beneficial', () {
      // Highly compressible payload above the threshold.
      final payload = Uint8List.fromList(List.filled(2000, 65));
      final msg = BLEOutgoingMessage(
        payload: payload,
        targetDeviceId: 'peer',
        peerSupportsCompression: true,
      );
      final parcels = msg.toParcels();
      final header = BLEParcel.fromBytesAsHeader(parcels.first.toBytes())!;
      expect(header.isCompressed, isTrue); // deflate was used
      expect(roundTrip(msg), payload); // decompresses back to the original
    });

    test('missing-parcel tracking', () {
      final payload = Uint8List.fromList(List.generate(900, (i) => i % 256));
      final parcels = BLEOutgoingMessage(payload: payload, targetDeviceId: 'peer').toParcels();
      final header = BLEParcel.fromBytesAsHeader(parcels.first.toBytes())!;
      final inc = BLEIncomingMessage(
        msgId: header.msgId,
        totalParcels: header.totalParcels,
        expectedChecksum: header.checksum,
        sourceDeviceId: 'peer',
      );
      inc.addParcel(header); // only the header so far
      expect(inc.missingParcels, [for (var i = 1; i < header.totalParcels; i++) i]);
    });

    test('receipt JSON round-trips', () {
      final r = BLEReceipt.missing('AB', [2, 5, 7]);
      final parsed = BLEReceipt.fromJson(
          jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
      expect(parsed.status, BLEReceiptStatus.missing);
      expect(parsed.msgId, 'AB');
      expect(parsed.missingParcels, [2, 5, 7]);
    });
  });
}
