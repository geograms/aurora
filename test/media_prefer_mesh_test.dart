/// Reticulum first, the internet second (docs/NOSTR.md, road item 8d).
///
/// A Blossom URL is content-addressed: the sha256 in the path IS the identity
/// of the blob. That is what lets the mesh answer for it — and what makes the
/// HTTPS request so revealing, because asking for it tells a server your IP and
/// exactly what you are reading. So the first job is recognising which URLs the
/// mesh can serve at all.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:aurora/services/reticulum/rns_service.dart';

void main() {
  const sha =
      '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';

  test('a Blossom URL carries its sha256, so the mesh can serve it', () {
    expect(RnsService.shaFromMediaUrl('https://blossom.primal.net/$sha.jpg'),
        sha);
    expect(RnsService.shaFromMediaUrl('https://nostr.download/$sha'), sha);
    expect(RnsService.shaFromMediaUrl('https://x.test/$sha.png?after=1'), sha);
  });

  test('an ordinary image URL is not content-addressed — only the web has it',
      () {
    expect(RnsService.shaFromMediaUrl('https://site.test/photos/cat.jpg'),
        isNull);
    expect(RnsService.shaFromMediaUrl('https://site.test/${'z' * 64}.jpg'),
        isNull, reason: 'not hex, not a hash');
    expect(RnsService.shaFromMediaUrl('https://site.test/${sha.substring(0, 40)}.jpg'),
        isNull, reason: 'too short to be a sha256');
  });

  test('case does not decide privacy', () {
    expect(RnsService.shaFromMediaUrl('https://x.test/${sha.toUpperCase()}.JPG'),
        sha);
  });
}
