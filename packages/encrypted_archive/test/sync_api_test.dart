/// Tests for the synchronous archive API (WASM HAL callback support).
///
/// The sync paths use pointycastle AES-GCM and a hand-rolled HKDF; these
/// tests pin byte-compatibility with the async paths (package:cryptography).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:encrypted_archive/encrypted_archive.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String archivePath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ear_sync_test_');
    archivePath = '${tempDir.path}/test.ear';
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('KeyDerivation sync/async parity', () {
    test('deriveFileKeySync matches async deriveFileKey', () async {
      final kd = KeyDerivation(const ArchiveOptions());
      final masterKey = Uint8List.fromList(List.generate(32, (i) => i * 7 % 256));

      for (final fileId in [1, 42, 999999]) {
        final asyncKey = await kd.deriveFileKey(masterKey, fileId);
        final asyncBytes = await asyncKey.extractBytes();
        final syncBytes = kd.deriveFileKeySync(masterKey, fileId);
        expect(syncBytes, equals(asyncBytes), reason: 'fileId=$fileId');
      }
    });

    test('hkdfSha256 matches package:cryptography Hkdf with salt', () async {
      final ikm = Uint8List.fromList(List.generate(64, (i) => 255 - i));
      final salt = Uint8List.fromList(List.generate(16, (i) => i));
      final info = Uint8List.fromList(utf8.encode('aurora-profile-kek-v1'));

      final algorithm = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      final asyncKey = await algorithm.deriveKey(
        secretKey: SecretKey(ikm),
        nonce: salt,
        info: info,
      );
      final asyncBytes = await asyncKey.extractBytes();

      final syncBytes = KeyDerivation.hkdfSha256(ikm, salt, info, 32);
      expect(syncBytes, equals(asyncBytes));
    });

    test('encryptSync/decryptSync round-trip and async cross-compat', () async {
      final kd = KeyDerivation(const ArchiveOptions());
      final keyBytes = Uint8List.fromList(List.generate(32, (i) => i));
      final nonce = Uint8List.fromList(List.generate(12, (i) => i + 100));
      final plaintext = Uint8List.fromList(utf8.encode('hello sync world 🔒'));

      // sync encrypt == async encrypt (GCM is deterministic given key+nonce)
      final syncEnc = kd.encryptSync(plaintext, keyBytes, nonce);
      final asyncEnc = await kd.encrypt(plaintext, SecretKey(keyBytes), nonce);
      expect(syncEnc.ciphertext, equals(asyncEnc.ciphertext));
      expect(syncEnc.authTag, equals(asyncEnc.authTag));

      // async decrypt of sync ciphertext
      final asyncDec = await kd.decrypt(
        syncEnc.ciphertext,
        syncEnc.authTag,
        SecretKey(keyBytes),
        nonce,
      );
      expect(asyncDec, equals(plaintext));

      // sync decrypt of async ciphertext
      final syncDec = kd.decryptSync(
        asyncEnc.ciphertext,
        asyncEnc.authTag,
        keyBytes,
        nonce,
      );
      expect(syncDec, equals(plaintext));
    });

    test('decryptSync rejects tampered ciphertext', () {
      final kd = KeyDerivation(const ArchiveOptions());
      final keyBytes = Uint8List.fromList(List.generate(32, (i) => i));
      final nonce = Uint8List.fromList(List.generate(12, (i) => i));
      final enc = kd.encryptSync(
        Uint8List.fromList(utf8.encode('payload')),
        keyBytes,
        nonce,
      );
      enc.ciphertext[0] ^= 0xFF;
      expect(
        () => kd.decryptSync(enc.ciphertext, enc.authTag, keyBytes, nonce),
        throwsA(isA<ArchiveCryptoException>()),
      );
    });
  });

  group('EncryptedArchive sync API', () {
    test('sync write, sync read round-trip', () async {
      final archive = await EncryptedArchive.create(archivePath, 'pw');
      final content = utf8.encode('sync data ✅');

      archive.addBytesSync('dir/file.txt', content);
      expect(archive.existsSync('dir/file.txt'), isTrue);
      expect(archive.readFileBytesSync('dir/file.txt'), equals(content));

      await archive.close();
    });

    test('sync write read back by async API and vice versa', () async {
      final archive = await EncryptedArchive.create(archivePath, 'pw');

      archive.addBytesSync('from-sync.txt', utf8.encode('written sync'));
      await archive.addBytes('from-async.txt', utf8.encode('written async'));

      expect(
        await archive.readFileBytes('from-sync.txt'),
        equals(utf8.encode('written sync')),
      );
      expect(
        archive.readFileBytesSync('from-async.txt'),
        equals(utf8.encode('written async')),
      );

      await archive.close();
    });

    test('sync data persists across close/reopen', () async {
      var archive = await EncryptedArchive.create(archivePath, 'pw');
      archive.addBytesSync('keep.txt', utf8.encode('persist me'));
      await archive.close();

      archive = await EncryptedArchive.open(archivePath, 'pw');
      expect(archive.readFileBytesSync('keep.txt'), equals(utf8.encode('persist me')));
      await archive.close();
    });

    test('writeBytesSync overwrites existing entry', () async {
      final archive = await EncryptedArchive.create(archivePath, 'pw');

      archive.writeBytesSync('f.txt', utf8.encode('v1'));
      archive.writeBytesSync('f.txt', utf8.encode('version two'));
      expect(archive.readFileBytesSync('f.txt'), equals(utf8.encode('version two')));

      final live = archive.listFilesSync().where((e) => e.path == 'f.txt');
      expect(live.length, equals(1));

      await archive.close();
    });

    test('zero-byte file', () async {
      final archive = await EncryptedArchive.create(archivePath, 'pw');
      archive.addBytesSync('empty.bin', const []);
      expect(archive.readFileBytesSync('empty.bin'), isEmpty);
      await archive.close();
    });

    test('multi-chunk file (chunkSize smaller than content)', () async {
      final archive = await EncryptedArchive.create(
        archivePath,
        'pw',
        options: const ArchiveOptions(chunkSize: 1024),
      );
      final big = Uint8List.fromList(
        List.generate(10 * 1024 + 37, (i) => i % 251),
      );
      archive.addBytesSync('big.bin', big);
      expect(archive.readFileBytesSync('big.bin'), equals(big));
      // async reader agrees
      expect(await archive.readFileBytes('big.bin'), equals(big));
      await archive.close();
    });

    test('deleteSync removes entry', () async {
      final archive = await EncryptedArchive.create(archivePath, 'pw');
      archive.addBytesSync('gone.txt', utf8.encode('x'));
      archive.deleteSync('gone.txt');
      expect(archive.existsSync('gone.txt'), isFalse);
      expect(
        () => archive.readFileBytesSync('gone.txt'),
        throwsA(isA<EntryNotFoundException>()),
      );
      await archive.close();
    });

    test('getEntrySync + listFilesSync', () async {
      final archive = await EncryptedArchive.create(archivePath, 'pw');
      archive.addDirectorySync('sub');
      archive.addBytesSync('sub/a.txt', utf8.encode('aaa'));
      archive.addBytesSync('top.txt', utf8.encode('t'));

      final entry = archive.getEntrySync('sub/a.txt');
      expect(entry.size, equals(3));
      expect(entry.isFile, isTrue);

      final subEntries = archive.listFilesSync(prefix: 'sub/');
      expect(subEntries.map((e) => e.path), contains('sub/a.txt'));

      await archive.close();
    });

    test('emoji password with sync API', () async {
      const password = '🔑🐻‍❄️ pass™ 🚀';
      var archive = await EncryptedArchive.create(archivePath, password);
      archive.addBytesSync('e.txt', utf8.encode('emoji-locked'));
      await archive.close();

      // wrong password fails
      await expectLater(
        EncryptedArchive.open(archivePath, '🔑 wrong'),
        throwsA(isA<ArchiveAuthenticationException>()),
      );

      archive = await EncryptedArchive.open(archivePath, password);
      expect(archive.readFileBytesSync('e.txt'), equals(utf8.encode('emoji-locked')));
      await archive.close();
    });

    test('sync write rejected while async write holds the lock', () async {
      final archive = await EncryptedArchive.create(archivePath, 'pw');

      // A slow stream keeps the async write lock held across awaits.
      final slow = () async* {
        yield utf8.encode('part1');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        yield utf8.encode('part2');
      }();
      final pending = archive.addFile('slow.txt', slow);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(
        () => archive.addBytesSync('quick.txt', utf8.encode('q')),
        throwsA(isA<ArchiveIOException>()),
      );

      await pending;
      // After the async write completes, sync writes work again.
      archive.addBytesSync('quick.txt', utf8.encode('q'));
      expect(archive.readFileBytesSync('quick.txt'), equals(utf8.encode('q')));
      await archive.close();
    });
  });
}
