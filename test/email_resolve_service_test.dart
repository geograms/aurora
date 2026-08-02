/*
 * EmailResolveService — the pure parts of the email→npub ladder.
 *
 * The address grammar and the nostr.json parser are the two places a hostile
 * or merely weird input reaches first, before any network or store is
 * touched, so they get exhaustive coverage. The networked ladder itself is
 * validated live (docs/plan-mail-bridge.md, cross-device).
 */
import 'package:aurora/services/social/email_resolve_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('splitEmail', () {
    test('accepts a plain address', () {
      expect(EmailResolveService.splitEmail('alice@acme.com'),
          ('alice', 'acme.com'));
    });

    test('accepts the NIP-05 root name and full local charset', () {
      expect(EmailResolveService.splitEmail('_@acme.com'), ('_', 'acme.com'));
      expect(EmailResolveService.splitEmail('a.b-c_9@sub.acme.co'),
          ('a.b-c_9', 'sub.acme.co'));
    });

    test('splits on the LAST @ (npub1…@gateway forms keep working)', () {
      expect(EmailResolveService.splitEmail('weird@local@acme.com'), isNull,
          reason: 'local part with @ fails the charset — not silently mangled');
    });

    test('rejects malformed shapes', () {
      for (final bad in [
        'alice',
        '@acme.com',
        'alice@',
        'alice@localhost', // no dot — not a routable NIP-05 domain
        'al ice@acme.com',
        'alice@ac me.com',
        'alice@[2001:db8::1]', // literal form is a later phase, not NIP-05
      ]) {
        expect(EmailResolveService.splitEmail(bad), isNull, reason: bad);
      }
    });
  });

  group('parseNip05Json', () {
    const pub =
        'b0635d6a9851d3aed0cd6c495b282167acf761729078d975fc341b22650b07b9';

    test('extracts the pubkey for the requested name', () {
      final r = EmailResolveService.parseNip05Json(
          '{"names":{"alice":"$pub"}}', 'alice');
      expect(r, isNotNull);
      expect(r!.$1, pub);
      expect(r.$2, isEmpty);
    });

    test('extracts relay hints keyed by the resolved pubkey', () {
      final r = EmailResolveService.parseNip05Json(
        '{"names":{"alice":"$pub"},'
        '"relays":{"$pub":["wss://relay.acme.com","wss://nos.lol"]}}',
        'alice',
      );
      expect(r!.$2, ['wss://relay.acme.com', 'wss://nos.lol']);
    });

    test('uppercase hex is normalized, npub-encoded keys are rejected', () {
      final up = EmailResolveService.parseNip05Json(
          '{"names":{"alice":"${pub.toUpperCase()}"}}', 'alice');
      expect(up!.$1, pub, reason: 'NIP-05 says hex, case-insensitively');
      expect(
          EmailResolveService.parseNip05Json(
              '{"names":{"alice":"npub1xyz"}}', 'alice'),
          isNull,
          reason: 'NIP-05 forbids npub encoding in nostr.json');
    });

    test('missing name, wrong shapes, garbage → null (never a throw)', () {
      for (final body in [
        '{"names":{"bob":"$pub"}}',
        '{"names":[]}',
        '{}',
        '[]',
        'not json at all',
        '{"names":{"alice":"deadbeef"}}', // short hex
      ]) {
        expect(EmailResolveService.parseNip05Json(body, 'alice'), isNull,
            reason: body);
      }
    });
  });

  test('an invalid address resolves to null without touching any service', () async {
    expect(await EmailResolveService.instance.resolve('not-an-email'), isNull);
    expect(await EmailResolveService.instance.resolve('a@b@'), isNull);
  });
}
