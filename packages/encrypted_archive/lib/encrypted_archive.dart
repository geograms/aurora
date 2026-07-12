/// A high-performance encrypted archive format using SQLite for storage.
///
/// Supports streaming, incremental updates, and terabyte-scale archives
/// with per-chunk encryption and optional deduplication.
///
/// ## Usage
///
/// ```dart
/// import 'package:encrypted_archive/encrypted_archive.dart';
///
/// // Create a new archive
/// final archive = await EncryptedArchive.create(
///   'backup.ear',
///   'my-password',
///   options: ArchiveOptions.defaultOptions,
/// );
///
/// // Add files
/// await archive.addBytes('config.json', utf8.encode('{"key": "value"}'));
/// await archive.addFileFromDisk('documents/report.pdf', '/path/to/report.pdf');
///
/// // Read files
/// final content = await archive.readFileBytes('config.json');
///
/// // Close when done
/// await archive.close();
/// ```
///
/// ## Opening an existing archive
///
/// ```dart
/// final archive = await EncryptedArchive.open('backup.ear', 'my-password');
///
/// // List files
/// final entries = await archive.listFiles();
/// for (final entry in entries) {
///   print('${entry.path}: ${entry.sizeString}');
/// }
///
/// // Extract all files
/// await archive.extractAll('/output/directory');
///
/// await archive.close();
/// ```
library encrypted_archive;

export 'src/archive.dart' show EncryptedArchive;
export 'src/compression.dart' show Compression, StreamChunker;
export 'src/entry.dart' show ArchiveEntry, ArchiveStats;
export 'src/exceptions.dart';
export 'src/key_derivation.dart' show KeyDerivation, MasterKeyMaterial;
export 'src/options.dart'
    show ArchiveEntryType, ArchiveOptions, ChunkSizePreset, CompressionType;
export 'src/progress.dart'
    show CancellationToken, OperationProgress, ProgressCallback;
