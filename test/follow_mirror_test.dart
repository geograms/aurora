/// The direct follow set is exactly the persisted kind-3 snapshot plus follows
/// made here, minus explicit unfollows. Legacy trust/storage state is excluded.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:aurora/services/social/direct_follow_resolver.dart';

String _key(String seed) => seed.padRight(64, '0').substring(0, 64);

void main() {
  final nostrNews = _key('a1');
  final alice = _key('b2');
  final bob = _key('c3');

  test('an account in the contact list shows up in Following', () {
    final out = resolveDirectFollows(
      contactSnapshot: [nostrNews, alice],
      localFollows: const [],
      explicitUnfollows: const [],
    );
    expect(out, {nostrNews, alice});
  });

  test('an unfollow STICKS, even though the relay still lists the account', () {
    // We do not rewrite the user's kind-3, so the relay keeps listing them.
    // Without the unfollowed set, the very next mirror hands them straight back.
    final out = resolveDirectFollows(
      contactSnapshot: [nostrNews, alice],
      localFollows: const [],
      explicitUnfollows: [nostrNews],
    );
    expect(out, {alice});
    expect(
      out,
      isNot(contains(nostrNews)),
      reason: 'this is the account the user kept unfollowing to no effect',
    );
  });

  test('an account dropped from the contact list leaves Following', () {
    final out = resolveDirectFollows(
      contactSnapshot: [alice], // bob is gone now
      localFollows: const [],
      explicitUnfollows: const [],
    );
    expect(out, {alice});
  });

  test('a loaded empty contact list contains no legacy authors', () {
    final out = resolveDirectFollows(
      contactSnapshot: const [],
      localFollows: const [],
      explicitUnfollows: const [],
    );
    expect(out, isEmpty);
  });

  test('an unfollow is honoured even with no contact list', () {
    final out = resolveDirectFollows(
      contactSnapshot: const [],
      localFollows: [alice, bob],
      explicitUnfollows: [bob],
    );
    expect(out, {
      alice,
    }, reason: "the user's own decision does not depend on the relays");
  });

  test('a follow made in the app survives a contact list that omits it', () {
    final out = resolveDirectFollows(
      contactSnapshot: [alice],
      localFollows: [bob], // followed here; their kind-3 has not caught up
      explicitUnfollows: const [],
    );
    expect(out, {alice, bob});
  });
}
