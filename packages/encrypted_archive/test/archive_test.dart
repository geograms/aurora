import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_archive/encrypted_archive.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String archivePath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('encrypted_archive_test_');
    archivePath = '${tempDir.path}/test.ear';
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('EncryptedArchive', () {
    test('create and open archive', () async {
      final password = 'test-password-123';

      // Create archive
      final archive = await EncryptedArchive.create(
        archivePath,
        password,
        description: 'Test archive',
      );
      expect(archive.isClosed, isFalse);
      await archive.close();

      // Reopen archive
      final reopened = await EncryptedArchive.open(archivePath, password);
      expect(reopened.isClosed, isFalse);
      await reopened.close();
    });

    test('wrong password throws ArchiveAuthenticationException', () async {
      final password = 'correct-password';
      final wrongPassword = 'wrong-password';

      // Create archive
      final archive = await EncryptedArchive.create(archivePath, password);
      await archive.close();

      // Try to open with wrong password
      expect(
        () => EncryptedArchive.open(archivePath, wrongPassword),
        throwsA(isA<ArchiveAuthenticationException>()),
      );
    });

    test('add and read file bytes', () async {
      final password = 'test-password';
      final content = utf8.encode('Hello, encrypted world!');

      // Create archive and add file
      final archive = await EncryptedArchive.create(archivePath, password);
      await archive.addBytes('test/hello.txt', content);

      // Read back
      final readContent = await archive.readFileBytes('test/hello.txt');
      expect(readContent, equals(content));

      await archive.close();
    });

    test('add and read file persists across close/reopen', () async {
      final password = 'test-password';
      final content = utf8.encode('Persistent data');

      // Create and add
      var archive = await EncryptedArchive.create(archivePath, password);
      await archive.addBytes('data.bin', content);
      await archive.close();

      // Reopen and read
      archive = await EncryptedArchive.open(archivePath, password);
      final readContent = await archive.readFileBytes('data.bin');
      expect(readContent, equals(content));
      await archive.close();
    });

    test('list files', () async {
      final password = 'test-password';

      final archive = await EncryptedArchive.create(archivePath, password);
      await archive.addBytes('file1.txt', utf8.encode('content1'));
      await archive.addBytes('subdir/file2.txt', utf8.encode('content2'));
      await archive.addDirectory('emptydir');

      final files = await archive.listFiles();
      expect(files.length, equals(3));

      final paths = files.map((e) => e.path).toSet();
      expect(paths, contains('file1.txt'));
      expect(paths, contains('subdir/file2.txt'));
      expect(paths, contains('emptydir'));

      await archive.close();
    });

    test('delete file', () async {
      final password = 'test-password';

      final archive = await EncryptedArchive.create(archivePath, password);
      await archive.addBytes('to-delete.txt', utf8.encode('delete me'));

      expect(await archive.exists('to-delete.txt'), isTrue);
      await archive.delete('to-delete.txt');
      expect(await archive.exists('to-delete.txt'), isFalse);

      await archive.close();
    });

    test('rename file', () async {
      final password = 'test-password';
      final content = utf8.encode('rename test');

      final archive = await EncryptedArchive.create(archivePath, password);
      await archive.addBytes('old-name.txt', content);
      await archive.rename('old-name.txt', 'new-name.txt');

      expect(await archive.exists('old-name.txt'), isFalse);
      expect(await archive.exists('new-name.txt'), isTrue);

      final readContent = await archive.readFileBytes('new-name.txt');
      expect(readContent, equals(content));

      await archive.close();
    });

    test('entry not found throws EntryNotFoundException', () async {
      final password = 'test-password';

      final archive = await EncryptedArchive.create(archivePath, password);

      await expectLater(
        archive.readFileBytes('nonexistent.txt'),
        throwsA(isA<EntryNotFoundException>()),
      );

      await archive.close();
    });

    test('change password', () async {
      final oldPassword = 'old-password';
      final newPassword = 'new-password';
      final content = utf8.encode('secret data');

      // Create with old password
      var archive = await EncryptedArchive.create(archivePath, oldPassword);
      await archive.addBytes('secret.txt', content);
      await archive.changePassword(oldPassword, newPassword);
      await archive.close();

      // Old password should fail
      expect(
        () => EncryptedArchive.open(archivePath, oldPassword),
        throwsA(isA<ArchiveAuthenticationException>()),
      );

      // New password should work
      archive = await EncryptedArchive.open(archivePath, newPassword);
      final readContent = await archive.readFileBytes('secret.txt');
      expect(readContent, equals(content));
      await archive.close();
    });

    test('get stats', () async {
      final password = 'test-password';

      final archive = await EncryptedArchive.create(archivePath, password);
      await archive.addBytes('file1.txt', utf8.encode('content1'));
      await archive.addBytes('file2.txt', utf8.encode('content2'));

      final stats = await archive.getStats();
      expect(stats.totalFiles, equals(2));
      expect(stats.totalSize, greaterThan(0));

      await archive.close();
    });

    test('vacuum removes deleted entries', () async {
      final password = 'test-password';

      final archive = await EncryptedArchive.create(archivePath, password);
      await archive.addBytes('file1.txt', utf8.encode('content1'));
      await archive.addBytes('file2.txt', utf8.encode('content2'));
      await archive.delete('file1.txt');

      final vacuumed = await archive.vacuum();
      expect(vacuumed, equals(1));

      await archive.close();
    });
  });

  group('KeyDerivation', () {
    test('constant time equals', () {
      final a = [1, 2, 3, 4];
      final b = [1, 2, 3, 4];
      final c = [1, 2, 3, 5];

      expect(
        KeyDerivation.constantTimeEquals(
          a.toUint8List(),
          b.toUint8List(),
        ),
        isTrue,
      );
      expect(
        KeyDerivation.constantTimeEquals(
          a.toUint8List(),
          c.toUint8List(),
        ),
        isFalse,
      );
    });
  });

  group('StreamChunker', () {
    test('chunk stream', () async {
      final data = List.generate(100, (i) => i);
      final stream = Stream.value(data);

      final chunks = await StreamChunker.chunkStream(stream, 30).toList();

      expect(chunks.length, equals(4)); // 30 + 30 + 30 + 10
      expect(chunks[0].length, equals(30));
      expect(chunks[1].length, equals(30));
      expect(chunks[2].length, equals(30));
      expect(chunks[3].length, equals(10));
    });

    test('chunk bytes', () {
      final data = List.generate(100, (i) => i).toUint8List();
      final chunks = StreamChunker.chunkBytes(data, 30);

      expect(chunks.length, equals(4));
    });
  });

  group('Compression', () {
    test('gzip roundtrip', () {
      final data = List.generate(1000, (i) => i % 256).toUint8List();

      final compressed = Compression.compress(data, CompressionType.gzip);
      final decompressed = Compression.decompress(compressed, CompressionType.gzip);

      expect(decompressed, equals(data));
    });

    test('detect compressed data', () {
      // GZIP signature
      final gzipData = [0x1F, 0x8B, 0x08, 0x00].toUint8List();
      expect(Compression.isLikelyCompressed(gzipData), isTrue);

      // Plain text
      final plainData = utf8.encode('Hello world').toUint8List();
      expect(Compression.isLikelyCompressed(plainData), isFalse);
    });
  });
}

extension on List<int> {
  Uint8List toUint8List() => Uint8List.fromList(this);
}
