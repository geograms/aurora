/*
 * LIVE integration: the NIP-05 rung of the email→npub ladder against a real,
 * long-stable address (fiatjaf.com's root `_` name). Auto-skips when the
 * network is unreachable, so CI without internet stays green.
 *
 * What it proves: HTTPS fetch → nostr.json parse → resolver result in the
 * hal_relay_resolve_recv shape, npub in the wapp's base64url form. The kind-0
 * cross-check and mesh/store rungs need a running node — validated on device.
 */
import 'dart:convert';
import 'dart:io';

import 'package:aurora/services/social/email_resolve_service.dart';
import 'package:flutter_test/flutter_test.dart';

Future<bool> _online() async {
  try {
    final s = await Socket.connect('fiatjaf.com', 443,
        timeout: const Duration(seconds: 5));
    await s.close();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  test('live NIP-05: _@fiatjaf.com resolves to the known pubkey', () async {
    if (!await _online()) {
      markTestSkipped('fiatjaf.com unreachable — live NIP-05 check skipped');
      return;
    }
    final r = await EmailResolveService.instance.resolve('_@fiatjaf.com');
    expect(r, isNotNull, reason: 'a live, valid NIP-05 address must resolve');
    expect(r!['callsign'], '_@fiatjaf.com');
    // fiatjaf's long-published key, in the wapp's base64url no-pad pk form.
    const hex =
        '3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d';
    final b64 = base64Url
        .encode([
          for (var i = 0; i < 64; i += 2)
            int.parse(hex.substring(i, i + 2), radix: 16)
        ])
        .replaceAll('=', '');
    expect(r['npub'], b64);
    expect(r.containsKey('kind0_match'), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
