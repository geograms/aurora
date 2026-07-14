/// The follow set is MIRRORED from the kind-3 contact list — and an absent
/// contact list is not an empty one.
///
/// Two bugs, opposite in sign, both real:
///
///   * The old merge was additive-only and persistent, so an account in the
///     relay's kind-3 (put there by whatever client made the account) could
///     never be removed: unfollow it, and the next rebuild folded it straight
///     back in. That is the "Nostr News" the user could not get rid of.
///   * My first fix mirrored unconditionally — and the kind-3 takes time to
///     arrive, so "not fetched yet" read as "follows nobody" and it WIPED the
///     persisted follow set. Following went empty on the device.
///
/// The rule these tests pin: additions are always safe; REMOVALS may only be
/// driven by a contact list we have actually seen, or by an explicit unfollow
/// (which is the user's decision and owes the relays nothing).
library;

import 'package:flutter_test/flutter_test.dart';

/// The resolution rule, extracted from RnsService._mergeMyFollows so it can be
/// tested without an isolate, a relay or a phone.
Set<String> resolveFollows({
  required List<String> contactList, // kind-3 from the relays ([] = unknown)
  required List<String> local, // followed inside geogram
  required List<String> unfollowed, // explicitly unfollowed here
  required Set<String> current, // what we hold today
}) {
  final haveContactList = contactList.isNotEmpty;
  final un = {for (final h in unfollowed) h.toLowerCase()};
  final desired = <String>{
    for (final h in [...contactList, ...local])
      if (h.length == 64) h.toLowerCase(),
  }..removeAll(un);

  final out = {...current, ...desired};
  if (haveContactList) {
    out.removeWhere((h) => !desired.contains(h));
  } else {
    out.removeAll(un);
  }
  return out;
}

String _key(String seed) => seed.padRight(64, '0').substring(0, 64);

void main() {
  final nostrNews = _key('a1');
  final alice = _key('b2');
  final bob = _key('c3');

  test('an account in the contact list shows up in Following', () {
    final out = resolveFollows(
      contactList: [nostrNews, alice],
      local: const [],
      unfollowed: const [],
      current: const {},
    );
    expect(out, {nostrNews, alice});
  });

  test('an unfollow STICKS, even though the relay still lists the account', () {
    // We do not rewrite the user's kind-3, so the relay keeps listing them.
    // Without the unfollowed set, the very next mirror hands them straight back.
    final out = resolveFollows(
      contactList: [nostrNews, alice],
      local: const [],
      unfollowed: [nostrNews],
      current: {nostrNews, alice},
    );
    expect(out, {alice});
    expect(out, isNot(contains(nostrNews)),
        reason: 'this is the account the user kept unfollowing to no effect');
  });

  test('an account dropped from the contact list leaves Following', () {
    final out = resolveFollows(
      contactList: [alice], // bob is gone now
      local: const [],
      unfollowed: const [],
      current: {alice, bob},
    );
    expect(out, {alice});
  });

  test('NO contact list yet must NEVER wipe the follows', () {
    // The destructive one: the kind-3 has not arrived (slow or hostile network).
    // Mirroring against nothing emptied a PERSISTED set and the Following tab
    // went blank on the device.
    final out = resolveFollows(
      contactList: const [], // unknown, NOT empty
      local: const [],
      unfollowed: const [],
      current: {alice, bob},
    );
    expect(out, {alice, bob},
        reason: 'an absent contact list is not an empty one');
  });

  test('an unfollow is honoured even with no contact list', () {
    final out = resolveFollows(
      contactList: const [],
      local: const [],
      unfollowed: [bob],
      current: {alice, bob},
    );
    expect(out, {alice},
        reason: "the user's own decision does not depend on the relays");
  });

  test('a follow made in the app survives a contact list that omits it', () {
    final out = resolveFollows(
      contactList: [alice],
      local: [bob], // followed here; their kind-3 has not caught up
      unfollowed: const [],
      current: const {},
    );
    expect(out, {alice, bob});
  });
}
