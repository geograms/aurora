import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aurora/profile/profile_crypto.dart';

void main() {
  // A fixed test identity (not a real key).
  const nsec =
      'nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5';

  group('ProfileCrypto', () {
    test('create → unlock round-trip preserves nsec and data keys', () async {
      const password = 'correct horse 🔋 staple';
      final secrets = await ProfileCrypto.createProfileSecrets(password, nsec);

      final unlocked = await ProfileCrypto.unlock(
        password,
        secrets.nsecEnvelope,
        secrets.keyslot,
      );

      expect(unlocked.nsec, equals(nsec));
      expect(unlocked.earPassword, equals(secrets.keys.earPassword));
      expect(
        unlocked.dbKeyHex('data/mesh.sqlite3'),
        equals(secrets.keys.dbKeyHex('data/mesh.sqlite3')),
      );
      // Distinct DBs get distinct keys.
      expect(
        unlocked.dbKeyHex('data/mesh.sqlite3'),
        isNot(equals(unlocked.dbKeyHex('data/media.sqlite3'))),
      );
    });

    test('wrong password throws WrongProfilePassword', () async {
      final secrets =
          await ProfileCrypto.createProfileSecrets('right ✅', nsec);

      await expectLater(
        ProfileCrypto.unlock('wrong ❌', secrets.nsecEnvelope, secrets.keyslot),
        throwsA(isA<WrongProfilePassword>()),
      );
    });

    test('NFC normalization: composed and decomposed forms unlock equally',
        () async {
      // 'café🔑' with composed é (U+00E9) vs decomposed e + U+0301.
      const composed = 'caf\u00E9\u{1F511}';
      const decomposed = 'cafe\u0301\u{1F511}';
      expect(composed == decomposed, isFalse); // different code points…

      final secrets =
          await ProfileCrypto.createProfileSecrets(composed, nsec);
      final unlocked = await ProfileCrypto.unlock(
        decomposed, // …but same key after NFC
        secrets.nsecEnvelope,
        secrets.keyslot,
      );
      expect(unlocked.nsec, equals(nsec));
    });

    test('ZWJ emoji sequence password round-trips', () async {
      // Polar bear (bear + ZWJ + snowflake) + skin-toned wave.
      const password = '🐻‍❄️👋🏽 secret';
      final secrets =
          await ProfileCrypto.createProfileSecrets(password, nsec);
      final unlocked = await ProfileCrypto.unlock(
        password,
        secrets.nsecEnvelope,
        secrets.keyslot,
      );
      expect(unlocked.nsec, equals(nsec));
    });

    test('keyslot and envelope JSON round-trip', () async {
      final secrets =
          await ProfileCrypto.createProfileSecrets('json 🔁', nsec);

      final keyslot = ProfileKeyslot.fromJson(
        jsonDecode(jsonEncode(secrets.keyslot.toJson()))
            as Map<String, dynamic>,
      );
      final envelope = NsecEnvelope.fromJson(
        jsonDecode(jsonEncode(secrets.nsecEnvelope.toJson()))
            as Map<String, dynamic>,
      );

      final unlocked = await ProfileCrypto.unlock('json 🔁', envelope, keyslot);
      expect(unlocked.nsec, equals(nsec));
    });

    test('password change: new works, old fails, PMK (data keys) unchanged',
        () async {
      final secrets =
          await ProfileCrypto.createProfileSecrets('old pass', nsec);
      final earBefore = secrets.keys.earPassword;
      final dbBefore = secrets.keys.dbKeyHex('data/media.sqlite3');

      final changed = await ProfileCrypto.changePassword(
        'old pass',
        'new pass 🎉',
        secrets.nsecEnvelope,
        secrets.keyslot,
      );

      final unlocked = await ProfileCrypto.unlock(
        'new pass 🎉',
        changed.nsecEnvelope,
        changed.keyslot,
      );
      expect(unlocked.earPassword, equals(earBefore));
      expect(unlocked.dbKeyHex('data/media.sqlite3'), equals(dbBefore));

      await expectLater(
        ProfileCrypto.unlock(
            'old pass', changed.nsecEnvelope, changed.keyslot),
        throwsA(isA<WrongProfilePassword>()),
      );
    });

    test('change password with wrong old password fails', () async {
      final secrets =
          await ProfileCrypto.createProfileSecrets('old pass', nsec);
      await expectLater(
        ProfileCrypto.changePassword(
          'not the old pass',
          'new pass',
          secrets.nsecEnvelope,
          secrets.keyslot,
        ),
        throwsA(isA<WrongProfilePassword>()),
      );
    });

    test('nsec is mixed in: keyslot from another identity refuses to open',
        () async {
      const otherNsec =
          'nsec1w7p0nsc7full96psqy5xnzeus4dl0z9cdvxg0dh9k75g0jfzyv2q08cwuz';
      const password = 'same password on both';

      final a = await ProfileCrypto.createProfileSecrets(password, nsec);
      final b = await ProfileCrypto.createProfileSecrets(password, otherNsec);

      // Envelope from A (decrypts fine with the password) + keyslot from B:
      // stage-2 KEK mixes A's nsec, so B's PMK wrap must not open.
      await expectLater(
        ProfileCrypto.unlock(password, a.nsecEnvelope, b.keyslot),
        throwsA(isA<ProfileKeyslotCorrupt>()),
      );
    });

    test('remember-key cache round-trip', () async {
      final secrets =
          await ProfileCrypto.createProfileSecrets('cache me 🧠', nsec);
      final restored =
          UnlockedProfileKeys.fromCacheJson(secrets.keys.toCacheJson());

      expect(restored.nsec, equals(nsec));
      expect(restored.earPassword, equals(secrets.keys.earPassword));
      expect(
        restored.dbKeyHex('data/social.sqlite3'),
        equals(secrets.keys.dbKeyHex('data/social.sqlite3')),
      );
    });

    test('dispose zeroes the master key and blocks further use', () async {
      final secrets =
          await ProfileCrypto.createProfileSecrets('bye 👋', nsec);
      secrets.keys.dispose();
      expect(() => secrets.keys.earPassword, throwsStateError);
      expect(() => secrets.keys.dbKey('data/x.sqlite3'), throwsStateError);
    });
  });
}
