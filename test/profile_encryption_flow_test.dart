/// End-to-end ProfileEncryption flow tests (Phase 4 of
/// docs/plan-encrypted-storage.md): enable → use → lock → unlock →
/// change password → disable, against a real ProfileService.
///
/// ProfileService persists to `$HOME/.local/share/aurora`, so this file
/// REFUSES to run unless AURORA_TEST_HOME=1 is set — run it with an
/// isolated HOME:
///
///   HOME=$(mktemp -d) AURORA_TEST_HOME=1 flutter test \
///     test/profile_encryption_flow_test.dart
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';

import 'package:aurora/profile/profile_crypto.dart';
import 'package:aurora/profile/profile_db.dart';
import 'package:aurora/profile/profile_encryption.dart';
import 'package:aurora/profile/profile_service.dart';

void main() {
  final isolated = Platform.environment['AURORA_TEST_HOME'] == '1';

  setUpAll(() {
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
  });

  test('full encryption lifecycle', () async {
    final service = ProfileService.instance;
    await service.load();
    final preview = service.generatePreview(nickname: 'Enc Test');
    // encrypt:false — this test drives enable() by hand; the default
    // (device-key mode at creation) is covered by the device-key test.
    await service.saveAndActivate(preview, encrypt: false);
    final id = preview.id;
    final plainNsec = preview.nsec;
    expect(plainNsec, isNotEmpty);

    final root = '${Platform.environment['HOME']}/.local/share/aurora';
    final profilesFile = File('$root/profiles.json');

    // Sanity: plaintext nsec on disk before enabling.
    expect(profilesFile.readAsStringSync(), contains(plainNsec));

    // Seed some plaintext data that must die on enable.
    final dataDir = Directory('$root/devices/$id/data/chat')
      ..createSync(recursive: true);
    File('${dataDir.path}/old.txt').writeAsStringSync('old plaintext');

    // ── enable ──
    await ProfileEncryption.enable(id, 'passw🔑rd');
    expect(File('$root/devices/$id/keyslot.json').existsSync(), isTrue);
    expect(Directory('$root/devices/$id/data').existsSync(), isFalse,
        reason: 'old data deleted');
    final persisted = profilesFile.readAsStringSync();
    expect(persisted.contains(plainNsec), isFalse,
        reason: 'plaintext nsec must not be persisted anymore');
    expect(persisted, contains('nsec_enc'));
    expect(ProfileEncryption.isUnlocked(id), isTrue);

    // In-memory profile still has the working nsec.
    expect(service.activeProfile!.nsec, equals(plainNsec));

    // Encrypted storage works and puts loose files in the archive.
    final storage = service.storageForProfile(id);
    expect(storage.isEncrypted, isTrue);
    await storage.writeString('data/chat/hello.json', '{"msg":"secret 🤫"}');
    expect(await storage.readString('data/chat/hello.json'),
        equals('{"msg":"secret 🤫"}'));
    expect(File('$root/devices/$id/data/chat/hello.json').existsSync(),
        isFalse);
    final earBytes =
        File('$root/devices/$id/profile.ear').readAsBytesSync();
    expect(utf8.decode(earBytes, allowMalformed: true).contains('secret'),
        isFalse);

    // ── lock / unlock ──
    await ProfileEncryption.lockNow(id);
    expect(ProfileEncryption.isUnlocked(id), isFalse);

    // Reload service state from disk the way a restart would.
    await expectLater(
      ProfileEncryption.unlock(id, 'wrong 🔓'),
      throwsA(isA<WrongProfilePassword>()),
    );
    await ProfileEncryption.unlock(id, 'passw🔑rd', remember: true);
    expect(ProfileEncryption.isUnlocked(id), isTrue);
    expect(await ProfileEncryption.hasCachedKeys(id), isTrue);
    expect(await service.storageForProfile(id).readString(
        'data/chat/hello.json'), equals('{"msg":"secret 🤫"}'));

    // ── cached unlock ──
    await ProfileEncryption.lockNow(id); // clears the cache too
    expect(await ProfileEncryption.hasCachedKeys(id), isFalse);
    await ProfileEncryption.unlock(id, 'passw🔑rd', remember: true);
    ProfileKeyring.instance.lock(id); // lock WITHOUT clearing the cache
    expect(await ProfileEncryption.tryUnlockCached(id), isTrue);
    expect(ProfileEncryption.isUnlocked(id), isTrue);

    // ── change password (data survives) ──
    await ProfileEncryption.changePassword(id, 'passw🔑rd', 'new🐘pass');
    ProfileKeyring.instance.lock(id);
    await ProfileEncryption.clearCachedKeys(id);
    await expectLater(
      ProfileEncryption.unlock(id, 'passw🔑rd'),
      throwsA(isA<WrongProfilePassword>()),
    );
    await ProfileEncryption.unlock(id, 'new🐘pass');
    expect(await service.storageForProfile(id).readString(
        'data/chat/hello.json'), equals('{"msg":"secret 🤫"}'));

    // ── disable ──
    await ProfileEncryption.disable(id, password: 'new🐘pass');
    expect(ProfileEncryption.isEncrypted(id), isFalse);
    expect(File('$root/devices/$id/keyslot.json').existsSync(), isFalse);
    expect(File('$root/devices/$id/profile.ear').existsSync(), isFalse);
    final restored = profilesFile.readAsStringSync();
    expect(restored, contains(plainNsec));
    expect(restored.contains('nsec_enc'), isFalse);
    expect(service.storageForProfile(id).isEncrypted, isFalse);
  }, skip: isolated ? false : 'set AURORA_TEST_HOME=1 with an isolated HOME');

  test('new profiles are encrypted by default (device-key mode)', () async {
    final service = ProfileService.instance;
    await service.load();
    final p = service.generatePreview(nickname: 'Default Enc');
    final nsec = p.nsec;
    await service.saveAndActivate(p); // encrypt: true is the default

    expect(ProfileEncryption.isEncrypted(p.id), isTrue);
    expect(ProfileEncryption.isUnlocked(p.id), isTrue);
    expect(await ProfileEncryption.usesDeviceKey(p.id), isTrue,
        reason: 'no password was typed — the device key holds the secret');
    expect(await ProfileEncryption.hasCachedKeys(p.id), isTrue);

    final root = '${Platform.environment['HOME']}/.local/share/aurora';
    final persisted = File('$root/profiles.json').readAsStringSync();
    expect(persisted.contains(nsec), isFalse,
        reason: 'nsec is encrypted at rest from the very first save');
    expect(persisted, contains('nsec_enc'));

    // Locking and coming back: the device key alone reopens it, no password.
    final storage = service.storageForProfile(p.id);
    await storage.writeString('data/x/note.txt', 'device key data');
    ProfileKeyring.instance.lock(p.id);
    expect(await ProfileEncryption.tryUnlockCached(p.id), isTrue);
    expect(await service.storageForProfile(p.id).readString('data/x/note.txt'),
        equals('device key data'));

    // Adding a password takes the device key away; the data survives.
    await ProfileEncryption.addPassword(p.id, 'now typed 🔑');
    expect(await ProfileEncryption.usesDeviceKey(p.id), isFalse);
    ProfileKeyring.instance.lock(p.id);
    await ProfileEncryption.clearCachedKeys(p.id);
    await expectLater(
      ProfileEncryption.unlock(p.id, 'wrong'),
      throwsA(isA<WrongProfilePassword>()),
    );
    await ProfileEncryption.unlock(p.id, 'now typed 🔑');
    expect(await service.storageForProfile(p.id).readString('data/x/note.txt'),
        equals('device key data'));

    // …and giving it back returns to fingerprint-only unlocking.
    await ProfileEncryption.removePassword(p.id, 'now typed 🔑');
    expect(await ProfileEncryption.usesDeviceKey(p.id), isTrue);
    ProfileKeyring.instance.lock(p.id);
    expect(await ProfileEncryption.tryUnlockCached(p.id), isTrue);
  }, skip: isolated ? false : 'set AURORA_TEST_HOME=1 with an isolated HOME');
}
