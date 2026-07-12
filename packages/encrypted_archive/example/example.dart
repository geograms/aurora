import 'dart:convert';
import 'dart:io';

import 'package:encrypted_archive/encrypted_archive.dart';

Future<void> main() async {
  final archivePath = 'example.ear';
  final password = 'secure-password-123';

  // Clean up any existing archive
  final archiveFile = File(archivePath);
  if (await archiveFile.exists()) {
    await archiveFile.delete();
  }

  print('Creating encrypted archive...');

  // Create a new archive
  final archive = await EncryptedArchive.create(
    archivePath,
    password,
    options: ArchiveOptions.defaultOptions,
    description: 'Example encrypted archive',
  );

  try {
    // Add some files
    print('Adding files...');

    await archive.addBytes(
      'config.json',
      utf8.encode('{"version": "1.0.0", "name": "Example"}'),
    );

    await archive.addBytes(
      'data/users.json',
      utf8.encode('[{"id": 1, "name": "Alice"}, {"id": 2, "name": "Bob"}]'),
    );

    await archive.addDirectory('data/cache');

    // Create a larger file to demonstrate chunking
    final largeData = List.generate(1024 * 1024, (i) => i % 256);
    await archive.addBytes(
      'data/large-file.bin',
      largeData,
      metadata: {'type': 'binary', 'generated': 'true'},
    );

    // List files
    print('\nArchive contents:');
    final entries = await archive.listFiles();
    for (final entry in entries) {
      final typeIcon = entry.isDirectory ? '/' : '';
      print('  ${entry.path}$typeIcon (${entry.sizeString})');
    }

    // Get statistics
    final stats = await archive.getStats();
    print('\nStatistics:');
    print('  Files: ${stats.totalFiles}');
    print('  Directories: ${stats.totalDirectories}');
    print('  Total size: ${stats.totalSize} bytes');
    print('  Stored size: ${stats.totalStoredSize} bytes');
    print('  Compression ratio: ${(stats.compressionRatio * 100).toStringAsFixed(1)}%');

    // Read a file back
    print('\nReading config.json:');
    final configBytes = await archive.readFileBytes('config.json');
    print('  ${utf8.decode(configBytes)}');

    // Delete a file
    print('\nDeleting data/cache...');
    await archive.delete('data/cache');

    // Verify integrity
    print('\nVerifying integrity...');
    final errors = await archive.verifyIntegrity();
    if (errors.isEmpty) {
      print('  No integrity errors found!');
    } else {
      for (final error in errors) {
        print('  ERROR: $error');
      }
    }

    // Close archive
    await archive.close();

    // Reopen with password
    print('\nReopening archive...');
    final archive2 = await EncryptedArchive.open(archivePath, password);

    // Verify files are still there
    final entries2 = await archive2.listFiles();
    print('Files after reopen: ${entries2.length}');

    // Try wrong password
    print('\nTrying wrong password...');
    try {
      await EncryptedArchive.open(archivePath, 'wrong-password');
      print('  ERROR: Should have thrown!');
    } on ArchiveAuthenticationException {
      print('  Correctly rejected wrong password');
    }

    await archive2.close();

    print('\nExample completed successfully!');
  } finally {
    // Clean up
    if (await archiveFile.exists()) {
      await archiveFile.delete();
    }
  }
}
