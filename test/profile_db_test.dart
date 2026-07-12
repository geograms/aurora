/// Tests for the central profile database opener (Phase 2 of
/// docs/plan-encrypted-storage.md).
///
/// The path-mapping and plain-profile paths always run. The SQLCipher
/// (keyed) paths need a real SQLCipher library in the test VM; point
/// SQLCIPHER_TEST_LIB at one (e.g. built from the same amalgamation the
/// sqlcipher_flutter_libs plugin pins) — without it those tests are
/// skipped and the encrypted path must be verified in the running app.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:aurora/profile/profile_crypto.dart';
import 'package:aurora/profile/profile_db.dart';

const _nsec =
    'nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5';

String? _resolveSqlCipherLib() {
  final env = Platform.environment['SQLCIPHER_TEST_LIB'];
  if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
  for (final candidate in [
    '/usr/lib/x86_64-linux-gnu/libsqlcipher.so.0',
    '/usr/local/lib/libsqlcipher.so',
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

void main() {
  final cipherLib = _resolveSqlCipherLib();
  final hasCipher = cipherLib != null;

  setUpAll(() {
    if (Platform.isLinux) {
      // Test VM has no flutter-bundled library; use SQLCipher when
      // available so the keyed paths run, else the plain system lib.
      final lib = cipherLib ?? 'libsqlite3.so.0';
      open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open(lib));
    }
  });

  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('profile_db_test_');
    profileDbRootOverride = tempRoot.path;
  });

  tearDown(() {
    profileDbRootOverride = null;
    ProfileKeyring.instance.lockAll();
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  String profileDir(String id) => '${tempRoot.path}/devices/$id';

  group('locateProfileDb', () {
    test('maps devices/<id>/... paths', () {
      final loc =
          locateProfileDb('${tempRoot.path}/devices/X1ABCD/data/mesh.sqlite3');
      expect(loc, isNotNull);
      expect(loc!.profileId, equals('X1ABCD'));
      expect(loc.relPath, equals('data/mesh.sqlite3'));
    });

    test('maps nested wapp paths', () {
      final loc = locateProfileDb(
          '${tempRoot.path}/devices/X1ABCD/wapps/social/social.sqlite3');
      expect(loc!.relPath, equals('wapps/social/social.sqlite3'));
    });

    test('null for paths outside the storage root', () {
      expect(locateProfileDb('/somewhere/else/db.sqlite3'), isNull);
      expect(locateProfileDb('${tempRoot.path}/profiles.json'), isNull);
      expect(locateProfileDb(':memory:'), isNull);
    });

    test('null for the profile dir itself', () {
      expect(locateProfileDb('${tempRoot.path}/devices/X1ABCD'), isNull);
      expect(locateProfileDb('${tempRoot.path}/devices/X1ABCD/'), isNull);
    });
  });

  group('plain profiles', () {
    test('openProfileDb behaves like sqlite3.open (no keyslot)', () {
      final dir = Directory('${profileDir('PLAIN1')}/data')
        ..createSync(recursive: true);
      final path = '${dir.path}/test.sqlite3';

      final db = openProfileDb(path);
      db.execute('CREATE TABLE t(v TEXT);');
      db.execute("INSERT INTO t VALUES ('hello');");
      db.dispose();

      // File is plain SQLite: header magic visible.
      final header = File(path).openSync().readSync(16);
      expect(String.fromCharCodes(header.sublist(0, 15)),
          equals('SQLite format 3'));

      final again = openProfileDb(path);
      expect(again.select('SELECT v FROM t').first['v'], equals('hello'));
      again.dispose();
    });
  });

  group('encrypted profiles', () {
    late ProfileSecrets secrets;

    Future<void> enableEncryption(String profileId) async {
      secrets = await ProfileCrypto.createProfileSecrets('pw 🐘', _nsec);
      final dir = Directory(profileDir(profileId))..createSync(recursive: true);
      File('${dir.path}/$keyslotFileName')
          .writeAsStringSync('{"version":1}'); // presence marks encrypted
      ProfileKeyring.instance.putKeys(profileId, secrets.keys);
    }

    test('locked profile throws ProfileLockedException', () async {
      await enableEncryption('ENC1');
      ProfileKeyring.instance.lock('ENC1');

      expect(
        () => openProfileDb('${profileDir('ENC1')}/data/x.sqlite3'),
        throwsA(isA<ProfileLockedException>()),
      );
    });

    test('keyed round-trip: write, reopen, read; file is not plain SQLite',
        () async {
      await enableEncryption('ENC2');
      final path = '${profileDir('ENC2')}/data/enc.sqlite3';
      Directory('${profileDir('ENC2')}/data').createSync(recursive: true);

      final db = openProfileDb(path);
      db.execute('CREATE TABLE t(v TEXT);');
      db.execute("INSERT INTO t VALUES ('secret payload');");
      db.dispose();

      // Encrypted file must NOT carry the plain SQLite header.
      final header = File(path).openSync().readSync(16);
      expect(String.fromCharCodes(header.sublist(0, 15)),
          isNot(equals('SQLite format 3')));

      final again = openProfileDb(path);
      expect(again.select('SELECT v FROM t').first['v'],
          equals('secret payload'));
      again.dispose();
    }, skip: hasCipher ? false : 'no SQLCipher library in test VM');

    test('wrong profile keys fail to open the database', () async {
      await enableEncryption('ENC3');
      final path = '${profileDir('ENC3')}/data/enc.sqlite3';
      Directory('${profileDir('ENC3')}/data').createSync(recursive: true);

      final db = openProfileDb(path);
      db.execute('CREATE TABLE t(v TEXT);');
      db.dispose();

      // Swap in keys derived from a different identity.
      final other = await ProfileCrypto.createProfileSecrets(
        'pw 🐘',
        'nsec1w7p0nsc7full96psqy5xnzeus4dl0z9cdvxg0dh9k75g0jfzyv2q08cwuz',
      );
      ProfileKeyring.instance.putKeys('ENC3', other.keys);

      expect(
        () => openProfileDb(path),
        throwsA(isA<SqliteException>()),
      );
    }, skip: hasCipher ? false : 'no SQLCipher library in test VM');

    test('sibling databases get distinct keys but both open', () async {
      await enableEncryption('ENC4');
      Directory('${profileDir('ENC4')}/data').createSync(recursive: true);
      final a = '${profileDir('ENC4')}/data/a.sqlite3';
      final b = '${profileDir('ENC4')}/data/b.sqlite3';

      for (final path in [a, b]) {
        final db = openProfileDb(path);
        db.execute('CREATE TABLE t(v TEXT);');
        db.execute("INSERT INTO t VALUES ('$path');");
        db.dispose();
      }
      for (final path in [a, b]) {
        final db = openProfileDb(path);
        expect(db.select('SELECT v FROM t').first['v'], equals(path));
        db.dispose();
      }
      expect(secrets.keys.dbKeyHex('data/a.sqlite3'),
          isNot(equals(secrets.keys.dbKeyHex('data/b.sqlite3'))));
    }, skip: hasCipher ? false : 'no SQLCipher library in test VM');
  });
}
