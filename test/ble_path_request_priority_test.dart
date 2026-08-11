// The Bluetooth advert channel is for the room, not for the directory.
//
// A node that has been on the internet holds hundreds of destinations and asks
// the network about all of them. On a hub uplink that costs nothing; on the
// advert channel it IS the medium, so path requests are deliberately trickled
// at six a minute. The trickle was applied to every request equally — including
// the one a person was waiting on.
//
// Measured on a phone with Bluetooth as its only interface, ten minutes after a
// cold start: 9,600 path requests held back, among them the peer standing in the
// same room, so a message to that peer could not even be addressed. The request
// that a queued message depends on now jumps the trickle; the sweep still waits.

import 'dart:typed_data';

import 'package:aurora/connections/bluetooth/ble_rns_radio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum/reticulum.dart' show RnsCrypto, RnsDestination;

/// RNS path-request frame: header(2) | pathRequestDest(16) | wanted(16) | …
Uint8List pathRequest(int wantedByte) {
  final f = Uint8List(2 + 16 + 16 + 16);
  f[0] = 0x00; // HEADER_1, packet type DATA
  f[1] = 0x00;
  // The well-known path-request destination, derived the same way the
  // transport derives it — never hard-coded, or the test drifts from the wire.
  final dest = RnsCrypto.truncatedHash(
      RnsDestination.nameHash('rnstransport', const ['path', 'request']));
  f.setRange(2, 18, dest);
  for (var i = 18; i < 34; i++) {
    f[i] = wantedByte; // the destination being asked about
  }
  return f;
}

Uint8List wantedHash(int b) => Uint8List.fromList(List.filled(16, b));

void main() {
  group('path requests over Bluetooth', () {
    test('the sweep is trickled: most requests are held back', () {
      final radio = Ble5ChunkedRnsRadio();
      var allowed = 0;
      for (var i = 0; i < 40; i++) {
        if (radio.debugAllowPathRequest(pathRequest(i % 200))) allowed++;
      }
      expect(allowed, lessThan(10),
          reason: 'six a minute is the budget for resolving a directory');
      expect(radio.pathRequestsDropped, greaterThan(25));
    });

    test('a destination somebody is waiting on always gets through', () {
      final radio = Ble5ChunkedRnsRadio();
      // Burn the budget on the sweep first.
      for (var i = 0; i < 40; i++) {
        radio.debugAllowPathRequest(pathRequest(i % 200));
      }
      radio.wantPathTo(wantedHash(0xAB)); // a queued message needs this peer
      for (var i = 0; i < 20; i++) {
        expect(radio.debugAllowPathRequest(pathRequest(0xAB)), isTrue,
            reason: 'the request a person is waiting on is not swept away');
      }
    });

    test('wanting one peer does not open the gate for the rest', () {
      final radio = Ble5ChunkedRnsRadio();
      radio.wantPathTo(wantedHash(0xAB));
      for (var i = 0; i < 40; i++) {
        radio.debugAllowPathRequest(pathRequest(0x11));
      }
      expect(radio.pathRequestsDropped, greaterThan(25));
      expect(radio.debugAllowPathRequest(pathRequest(0xAB)), isTrue);
    });

    test('anything that is not a path request is never throttled', () {
      final radio = Ble5ChunkedRnsRadio();
      final announce = Uint8List(180)..[0] = 0x01; // announce packet type
      for (var i = 0; i < 50; i++) {
        expect(radio.debugAllowPathRequest(announce), isTrue);
      }
      expect(radio.pathRequestsDropped, 0);
    });
  });
}
