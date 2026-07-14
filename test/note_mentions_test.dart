/// A mention is a person, not 63 characters of bech32.
///
/// The old formatter only matched a `nostr:`-prefixed token, so a BARE `npub1…`
/// — which is what most clients write — was decoded nowhere, and the launcher
/// hero showed the raw key. And it substituted a name into a String, throwing
/// the key away, so nothing downstream could open a profile.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum/reticulum.dart' show NostrCrypto;

import 'package:aurora/services/social/note_text.dart';

void main() {
  final kp = NostrCrypto.generateKeyPair();
  final npub = NostrCrypto.encodeNpub(kp.publicKeyHex);

  test('a BARE npub is a mention — this is the one that was invisible', () {
    final m = parseNoteMentions('hey $npub look at this');
    expect(m, hasLength(1));
    expect(m.single.pubkeyHex, kp.publicKeyHex);
    expect(m.single.isPerson, isTrue);
  });

  test('a nostr:-prefixed npub is the same mention', () {
    final m = parseNoteMentions('hey nostr:$npub');
    expect(m, hasLength(1));
    expect(m.single.pubkeyHex, kp.publicKeyHex);
  });

  test('a mention inside a URL is left alone', () {
    // Re-labelling half of somebody's link is worse than not decoding at all.
    final m = parseNoteMentions('see https://njump.me/$npub for more');
    expect(m, isEmpty);
  });

  test('a resolved mention reads as a name', () {
    final out = formatNoteMentions('ping $npub thanks', (_) => 'Alice');
    expect(out, 'ping @Alice thanks');
    expect(out.contains('npub1'), isFalse);
  });

  test('an unresolved mention is SHORT — never the whole key', () {
    final out = formatNoteMentions('ping $npub', (_) => null);
    expect(out.contains(npub), isFalse,
        reason: 'the 63-char key is exactly what the user complained about');
    expect(out.length, lessThan('ping '.length + 20));
    expect(out.startsWith('ping @npub1'), isTrue);
  });

  test('a LONG nprofile (relay hints) decodes — the 90-char bech32 limit is not ours',
      () {
    // Straight off the wire: an nprofile carrying relay hints, ~250 chars. The
    // bech32 package defaults to the spec's 90-char address limit, so this threw,
    // decoded to nothing, and the reader was shown the raw key.
    const long =
        'nostr:nprofile1qqsx6zytv5aphll89zumzlju0t70cxxctac9qtl2eq6qq5jwk65dt6gpz4mhxue69uhhyetvv9ujuerpd46hxtnfduhszxnhwden5te0wfjkccte9ekkjmnfvf5hguewvdshx6p0qyg8wumn8ghj7mn0wd68ytnddakj7r7sjwc';
    final m = parseNoteMentions(long);
    expect(m, hasLength(1), reason: 'a long nprofile is still a mention');
    expect(m.single.type, 'nprofile');
    expect(m.single.pubkeyHex, hasLength(64));

    final out = formatNoteMentions(long, (_) => 'Alice');
    expect(out, '@Alice');
  });

  test('text with no mention comes back untouched', () {
    const s = 'just a normal post, nothing to see';
    expect(formatNoteMentions(s, (_) => 'Alice'), s);
    expect(parseNoteMentions(s), isEmpty);
  });
}
