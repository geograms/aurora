// Headless test for slice 3: capacity->role mapping, relay announcement
// encode/decode, interest coverage, and the directory's indexer ranking + TTL.
//
//   dart run tool/social_relay_role_test.dart
import 'dart:io';

import 'package:aurora/services/files/capacity_policy.dart';
import 'package:aurora/services/files/dht/provider_record.dart'
    show kCapHomeFiber, kCapHomeWifi;
import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/social/relay_role.dart';

int _pass = 0, _fail = 0;
void check(String name, bool ok) {
  if (ok) {
    _pass++;
    stdout.writeln('  ok   $name');
  } else {
    _fail++;
    stdout.writeln('  FAIL $name');
  }
}

CapacityProfile _prof(NetKind net, bool charging) =>
    policyFor(net, charging, serveOnCellular: false, quotaMb: 1024);

Future<void> main() async {
  // 1) Capacity -> role mapping.
  final homeWifi = _prof(NetKind.wifi, true); // unlimited, kCapHomeWifi
  final fiber = _prof(NetKind.ethernet, true); // unlimited, kCapHomeFiber
  final wifiBattery = _prof(NetKind.wifi, false); // limited
  final cellular = _prof(NetKind.cellular, false); // limited / no serve

  final aWifi = RelayAnnouncement.forCapacity(homeWifi, InterestSet());
  final aFiber = RelayAnnouncement.forCapacity(fiber, InterestSet());
  final aBatt = RelayAnnouncement.forCapacity(wifiBattery, InterestSet());
  final aCell = RelayAnnouncement.forCapacity(cellular, InterestSet());

  check('charger+wifi => indexer', aWifi.role == RelayRole.indexer);
  check('indexer advertises search+firehose+store-forward',
      aWifi.has(RelayCap.search) && aWifi.has(RelayCap.firehose) && aWifi.has(RelayCap.storeForward));
  check('home wifi indexer is NOT a wide archive', !aWifi.wide && aWifi.capacity == kCapHomeWifi);
  check('ethernet+charger => wide archive', aFiber.has(RelayCap.archive) && aFiber.wide && aFiber.capacity == kCapHomeFiber);
  check('wifi on battery => leaf', aBatt.role == RelayRole.leaf && aBatt.caps == 0);
  check('cellular => leaf', aCell.role == RelayRole.leaf);

  // 2) Interest set drives announced topics/authors (non-wide indexer).
  final interests = InterestSet()
    ..addTopic('Reticulum')
    ..addTopic('solar')
    ..addAuthor('deadbeefcafef00d1234');
  final aInterest = RelayAnnouncement.forCapacity(homeWifi, interests);
  check('topics announced lowercased', aInterest.topics.contains('reticulum'));
  check('author prefix announced (8 hex)', aInterest.authorPrefixes.contains('deadbeef'));

  // 3) Announcement encode/decode round-trip.
  final round = RelayAnnouncement.decode(aInterest.encode());
  check('round-trip decodes', round != null);
  check('round-trip role', round!.role == RelayRole.indexer);
  check('round-trip caps', round.caps == aInterest.caps);
  check('round-trip topics', round.topics.contains('solar'));
  check('non-relay appData decodes to null', RelayAnnouncement.decode(null) == null);

  // 4) wouldHold / coverage.
  check('non-wide holds matching topic', round.wouldHold(topics: ['solar']));
  check('non-wide holds matching author prefix', round.wouldHold(author: 'deadbeefcafef00d1234'));
  check('non-wide rejects unknown topic+author', !round.wouldHold(topics: ['coffee'], author: 'ffffffffffff'));
  check('wide archive holds anything', aFiber.wouldHold(topics: ['anything'], author: 'ab'));

  // 5) Directory ranking.
  var t = 1_000_000;
  final dir = RelayDirectory(entryTtl: const Duration(minutes: 30), clock: () => t);

  final idLeaf = await RnsIdentity.generate();
  final idGeneric = await RnsIdentity.generate(); // indexer, no matching interest
  final idTopic = await RnsIdentity.generate(); // indexer covering 'solar'
  final idArchive = await RnsIdentity.generate(); // wide archive (fiber)

  dir.observe(idLeaf, aBatt.encode(), hops: 1); // leaf — must be ignored
  dir.observe(idGeneric,
      RelayAnnouncement.forCapacity(homeWifi, InterestSet()).encode(),
      hops: 1);
  dir.observe(
      idTopic,
      RelayAnnouncement.forCapacity(homeWifi, InterestSet()..addTopic('solar'))
          .encode(),
      hops: 3);
  dir.observe(idArchive, aFiber.encode(), hops: 2);

  check('directory ignores leaf in indexers()', dir.indexers().length == 3);
  check('bestIndexer for solar = the topic-covering indexer',
      dir.bestIndexer(topic: 'solar')?.idHex == _hx(idTopic.hash));
  check('bestIndexer for unknown topic = wide archive',
      dir.bestIndexer(topic: 'quantum')?.idHex == _hx(idArchive.hash));

  // 6) TTL expiry via injected clock.
  t += const Duration(minutes: 31).inMilliseconds;
  check('entries expire after TTL', dir.indexers().isEmpty);

  // 7) RoleManager fires onChanged when capacity crosses leaf<->indexer.
  RelayAnnouncement? fired;
  final mgr = RelayRoleManager(initial: cellular, onChanged: (a) => fired = a);
  check('manager starts as leaf', mgr.current.role == RelayRole.leaf);
  mgr.applyCapacity(homeWifi);
  check('promotion to indexer fires onChanged', fired != null && fired!.role == RelayRole.indexer);
  fired = null;
  mgr.applyCapacity(homeWifi);
  check('no-op capacity does not refire', fired == null);
  mgr.applyCapacity(cellular);
  check('demotion to leaf fires onChanged', fired != null && fired!.role == RelayRole.leaf);

  stdout.writeln('\n$_pass passed, $_fail failed');
  exit(_fail == 0 ? 0 : 1);
}

String _hx(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
