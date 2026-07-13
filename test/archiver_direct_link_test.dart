/// The link IS the policy (docs/NOSTR.md, the Archiver).
///
/// A peer that reached us over the LAN, over Bluetooth or over LoRa has no route
/// to anywhere else: refuse it and its data is simply gone. So those links get
/// in on the strength of the link alone — which makes the mapping from
/// "interface it arrived on" to "kind of peer" a security decision, not a
/// cosmetic one. An interface we do not recognise must read as THE INTERNET,
/// because the direct-link exception is generous and must never be granted by
/// accident.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum/src/services/social/archiver_policy.dart';
import 'package:reticulum/src/services/social/retention_tier.dart';

import 'package:aurora/services/social/archiver_service.dart';

void main() {
  test('a direct link is recognised for what it is', () {
    expect(ArchiverService.arrivedOver('lan'), ArrivedOver.lan);
    expect(ArchiverService.arrivedOver('udp:192.168.1.20'), ArrivedOver.lan);
    expect(ArchiverService.arrivedOver('ble5'), ArrivedOver.bluetooth);
    expect(ArchiverService.arrivedOver('bluetooth'), ArrivedOver.bluetooth);
    expect(ArchiverService.arrivedOver('lora'), ArrivedOver.radio);
    expect(ArchiverService.arrivedOver('serial0'), ArrivedOver.radio);
    expect(ArchiverService.arrivedOver('wfd'), ArrivedOver.wifiDirect);
  });

  test('anything we do not recognise is the internet — the safe reading', () {
    expect(ArchiverService.arrivedOver(null), ArrivedOver.internet);
    expect(ArchiverService.arrivedOver(''), ArrivedOver.internet);
    expect(ArchiverService.arrivedOver('tcp:rns.beleth.net:4242'),
        ArrivedOver.internet);
    expect(ArchiverService.arrivedOver('some-future-transport'),
        ArrivedOver.internet,
        reason: 'a transport we have never heard of must not inherit the '
            'direct-link exception');
  });

  test('a hub is never mistaken for a neighbour', () {
    const policy = ArchiverPolicy(
      quotaBytes: 1 << 30,
      keepFollowedAuthors: false,
      acceptFrom: {ArrivedOver.lan, ArrivedOver.bluetooth, ArrivedOver.radio},
    );

    ArchiveVerdict ask(String? iface) => admitToArchive(
          policy: policy,
          tier: Tier.stranger,
          bytes: 1024,
          usedBytes: 0,
          via: ArchiverService.arrivedOver(iface),
        );

    expect(ask('lan').accept, isTrue);
    expect(ask('lora').accept, isTrue);
    expect(ask('tcp:hub.example:4242').accept, isFalse,
        reason: 'a stranger who came in over a hub has somewhere else to go');
  });
}
