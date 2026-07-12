// A live-node FIXTURE, not a unit test — it writes into the running device's
// real data directory, so it is kept out of the normal test sweep (test/live/).
//
// It seeds the NOSTR hub's own store with a signed post from an author this
// device follows: exactly what the hub would be holding after pulling that post
// off a relay. On the next app start the follows mirror should copy it into the
// SERVED store (social.sqlite3) at the followed tier, which is what RelayNode
// hands to other peers. That is the "cache what you follow and serve it" claim,
// checked from the outside.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum/reticulum.dart';
import 'package:sqlite3/open.dart';

const _dir = '/home/brito/.local/share/aurora/devices/X16JK8/data';
const _priv =
    '00b1c3d5e7f9a1b3c5d7e9fb0d1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b';

void main() {
  // Skipped unless a real node's data directory is here — this fixture writes
  // into a live install, so it must never run in CI or on someone else's box.
  final live = Directory(_dir).existsSync();

  test('seed a followed author post into the hub store', () {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));

    final pub = NostrCrypto.derivePublicKey(_priv);
    final ev = NostrEvent(
      pubkey: pub,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 300,
      kind: 1,
      tags: const [],
      content: 'Mirror test: a post from someone this device follows. It must '
          'land in social.sqlite3 at the followed tier and be servable to peers.',
    );
    ev.sign(_priv);

    final hub = RelayEventStore.open('$_dir/nostr_feed.sqlite3');
    final stored = hub.put(ev, tier: 1);
    hub.close();

    final f = File('$_dir/host_follows.json');
    final follows = (jsonDecode(f.readAsStringSync()) as List).cast<String>();
    if (!follows.contains(pub)) {
      follows.add(pub);
      f.writeAsStringSync(jsonEncode(follows));
    }

    // ignore: avoid_print
    print('SEEDED stored=$stored id=${ev.id} pub=$pub');
    expect(ev.id, isNotNull);
  }, skip: live ? false : 'no live node at $_dir');
}
