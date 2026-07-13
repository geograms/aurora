/// Main encrypted archive implementation.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'compression.dart';
import 'sqlite_loader.dart';
import 'entry.dart';
import 'exceptions.dart';
import 'key_derivation.dart';
import 'options.dart';
import 'progress.dart';
import 'schema.dart';

/// A high-performance encrypted archive using SQLite for storage.
class EncryptedArchive {
  final String _path;
  final Database _db;
  final ArchiveOptions _options;
  final KeyDerivation _keyDerivation;
  final MasterKeyMaterial _keys;

  bool _closed = false;
  Completer<void>? _writeLock;

  EncryptedArchive._({
    required String path,
    required Database db,
    required ArchiveOptions options,
    required MasterKeyMaterial keys,
  })  : _path = path,
        _db = db,
        _options = options,
        _keyDerivation = KeyDerivation(options),
        _keys = keys;

  /// Execute an action with exclusive write access.
  /// Prevents concurrent transactions from causing SQLite errors.
  Future<T> _withWriteLock<T>(Future<T> Function() action) async {
    // Wait for any existing lock
    while (_writeLock != null) {
      await _writeLock!.future;
    }

    // Acquire lock
    _writeLock = Completer<void>();
    try {
      return await action();
    } finally {
      final lock = _writeLock;
      _writeLock = null;
      lock?.complete();
    }
  }

  /// Archive options.
  ArchiveOptions get options => _options;

  /// Whether the archive is closed.
  bool get isClosed => _closed;

  /// Path to the archive file.
  String get path => _path;

  /// Create a new encrypted archive.
  static Future<EncryptedArchive> create(
    String path,
    String password, {
    ArchiveOptions options = const ArchiveOptions(),
    String? description,
  }) async {
    // Check if file already exists
    if (await File(path).exists()) {
      throw ArchiveOpenException(path, 'Archive already exists');
    }

    // Create parent directory if needed
    final parent = File(path).parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }

    // Open database using platform-aware loader
    final db = SQLiteLoader.openDatabase(path);

    try {
      // Configure pragmas
      configurePragmas(db, options);

      // Create schema
      createSchema(db);

      // Generate salt and derive keys
      final salt = KeyDerivation.generateSalt();
      final keyDerivation = KeyDerivation(options);
      final keys = await keyDerivation.deriveFromPassword(password, salt);

      // Generate a random master key and encrypt it with the password-derived key
      final random = SecureRandom.fast;
      final masterKey = Uint8List(keySize);
      for (var i = 0; i < keySize; i++) {
        masterKey[i] = random.nextInt(256);
      }

      final encryptedMasterKey = await keyDerivation.encryptMasterKey(
        masterKey,
        keys.masterKey,
      );

      // Store header
      final now = DateTime.now().millisecondsSinceEpoch;
      db.execute(
        ArchiveSQL.insertHeader,
        [
          archiveMagic,
          currentSchemaVersion,
          now,
          salt,
          keys.verificationHash,
          encryptedMasterKey,
          jsonEncode(options.toJson()),
          description,
        ],
      );

      // Create actual keys using the stored master key
      final actualKeys = MasterKeyMaterial(
        masterKey: masterKey,
        metadataKey: keys.metadataKey,
        authKey: keys.authKey,
        verificationHash: keys.verificationHash,
      );

      // Dispose the password-derived keys (keep masterKey for encryption)
      keys.dispose();

      return EncryptedArchive._(
        path: path,
        db: db,
        options: options,
        keys: actualKeys,
      );
    } catch (e) {
      db.dispose();
      // Clean up failed creation
      try {
        await File(path).delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Open an existing encrypted archive.
  static Future<EncryptedArchive> open(
    String path,
    String password, {
    ArchiveOptions? optionsOverride,
  }) async {
    // Check if file exists
    if (!await File(path).exists()) {
      throw ArchiveOpenException(path, 'Archive not found');
    }

    // Open database using platform-aware loader
    final db = SQLiteLoader.openDatabase(path);

    try {
      // Read header
      final headerResult = db.select(ArchiveSQL.selectHeader);
      if (headerResult.isEmpty) {
        throw ArchiveCorruptedException('Missing archive header');
      }

      final header = headerResult.first;
      final magic = header['magic'] as String;
      if (magic != archiveMagic) {
        throw ArchiveCorruptedException('Invalid archive format: $magic');
      }

      final schemaVersion = header['schema_version'] as int;
      if (schemaVersion > currentSchemaVersion) {
        throw ArchiveCorruptedException(
          'Archive version $schemaVersion is newer than supported $currentSchemaVersion',
        );
      }

      // Parse options from archive
      final optionsJson = header['options_json'] as String;
      var options = ArchiveOptions.fromJson(
        jsonDecode(optionsJson) as Map<String, dynamic>,
      );

      // Apply overrides if provided
      if (optionsOverride != null) {
        options = optionsOverride;
      }

      // Configure pragmas
      configurePragmas(db, options);

      // Get salt and verification hash
      final salt = header['salt'] as Uint8List;
      final storedVerificationHash = header['verification_hash'] as Uint8List;
      final encryptedMasterKey = header['encrypted_master_key'] as Uint8List?;

      // Derive keys from password
      final keyDerivation = KeyDerivation(options);
      final derivedKeys = await keyDerivation.deriveFromPassword(password, salt);

      // Verify password
      if (!KeyDerivation.constantTimeEquals(
        derivedKeys.verificationHash,
        storedVerificationHash,
      )) {
        derivedKeys.dispose();
        throw const ArchiveAuthenticationException();
      }

      // Decrypt the master key if present
      MasterKeyMaterial actualKeys;
      if (encryptedMasterKey != null && encryptedMasterKey.isNotEmpty) {
        final masterKey = await keyDerivation.decryptMasterKey(
          encryptedMasterKey,
          derivedKeys.masterKey,
        );
        actualKeys = MasterKeyMaterial(
          masterKey: masterKey,
          metadataKey: derivedKeys.metadataKey,
          authKey: derivedKeys.authKey,
          verificationHash: derivedKeys.verificationHash,
        );
        derivedKeys.dispose();
      } else {
        actualKeys = derivedKeys;
      }

      return EncryptedArchive._(
        path: path,
        db: db,
        options: options,
        keys: actualKeys,
      );
    } catch (e) {
      db.dispose();
      rethrow;
    }
  }

  void _ensureOpen() {
    if (_closed) {
      throw const ArchiveClosedException();
    }
  }

  /// Add a file from a byte stream.
  Future<ArchiveEntry> addFile(
    String path,
    Stream<List<int>> content, {
    int? size,
    DateTime? createdAt,
    DateTime? modifiedAt,
    int? permissions,
    Map<String, String>? metadata,
    ProgressCallback? onProgress,
    CancellationToken? cancellation,
  }) async {
    return _withWriteLock(() async {
    _ensureOpen();
    final normalizedPath = _normalizePath(path);

    // Check if entry already exists
    if (await exists(normalizedPath)) {
      throw EntryExistsException(normalizedPath);
    }

    final now = DateTime.now();
    final created = createdAt ?? now;
    final modified = modifiedAt ?? now;
    final fileNonce = KeyDerivation.generateNonce();

    // Start transaction
    _db.execute('BEGIN TRANSACTION');

    try {
      // Insert file record to get ID
      _db.execute(
        ArchiveSQL.insertFile,
        [
          normalizedPath,
          ArchiveEntryType.file.index,
          0, // size (updated later)
          0, // stored_size (updated later)
          created.millisecondsSinceEpoch,
          modified.millisecondsSinceEpoch,
          null, // content_hash (updated later)
          fileNonce,
          0, // chunk_count (updated later)
          permissions,
          null, // symlink_target
          metadata != null ? jsonEncode(metadata) : null,
        ],
      );

      final fileId = _db.lastInsertRowId;
      final fileKey = await _keyDerivation.deriveFileKey(_keys.masterKey, fileId);

      // Set up progress tracking
      final tracker = ProgressTracker(
        callback: onProgress,
        cancellation: cancellation,
        totalBytes: size,
      );
      tracker.start();

      // Process chunks
      var sequence = 0;
      var totalSize = 0;
      var totalStoredSize = 0;
      final contentHasher = crypto.sha256.startChunkedConversion(
        _Sha256Sink(),
      );

      await for (final chunk in StreamChunker.chunkStream(
        content,
        _options.chunkSize,
      )) {
        tracker.checkCancelled();

        // Update content hash
        contentHasher.add(chunk);

        // Compress if enabled
        final compression = Compression.recommendCompression(
          chunk,
          _options.compression,
        );
        final compressed = Compression.compress(
          chunk,
          compression,
          level: _options.compressionLevel,
        );

        // Encrypt chunk
        final chunkNonce = _keyDerivation.createChunkNonce(fileNonce, sequence);
        final encrypted = await _keyDerivation.encrypt(
          compressed,
          fileKey,
          chunkNonce,
        );

        // Compute chunk content hash for dedup
        final chunkHash = KeyDerivation.sha256(chunk);

        // Store chunk
        _db.execute(
          ArchiveSQL.insertChunk,
          [
            fileId,
            sequence,
            chunk.length,
            encrypted.ciphertext.length,
            compression.value,
            encrypted.ciphertext,
            encrypted.authTag,
            chunkHash,
          ],
        );

        totalSize += chunk.length;
        totalStoredSize += encrypted.totalSize;
        sequence++;

        // Report progress
        if (!tracker.update(bytesAdded: chunk.length)) {
          throw const OperationCancelledException();
        }
      }

      // Get final content hash
      contentHasher.close();
      final contentHash = _lastSha256Hash;

      // Update file record with final stats
      _db.execute(
        ArchiveSQL.updateFileStats,
        [
          totalSize,
          totalStoredSize,
          sequence,
          contentHash,
          modified.millisecondsSinceEpoch,
          fileId,
        ],
      );

      _db.execute('COMMIT');

      // Report final progress
      tracker.update(forceReport: true);

      return await getEntry(normalizedPath);
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    });
  }

  /// Add a file from disk.
  Future<ArchiveEntry> addFileFromDisk(
    String archivePath,
    String diskPath, {
    ProgressCallback? onProgress,
    CancellationToken? cancellation,
  }) async {
    final file = File(diskPath);
    if (!await file.exists()) {
      throw ArchiveIOException('File not found', path: diskPath);
    }

    final stat = await file.stat();
    return addFile(
      archivePath,
      file.openRead(),
      size: stat.size,
      createdAt: stat.changed,
      modifiedAt: stat.modified,
      permissions: stat.mode,
      onProgress: onProgress,
      cancellation: cancellation,
    );
  }

  /// Add a file from bytes.
  Future<ArchiveEntry> addBytes(
    String path,
    List<int> bytes, {
    DateTime? createdAt,
    DateTime? modifiedAt,
    Map<String, String>? metadata,
  }) async {
    return addFile(
      path,
      Stream.value(bytes),
      size: bytes.length,
      createdAt: createdAt,
      modifiedAt: modifiedAt,
      metadata: metadata,
    );
  }

  /// Add a directory entry.
  Future<void> addDirectory(String path) async {
    _ensureOpen();
    final normalizedPath = _normalizePath(path);

    if (await exists(normalizedPath)) {
      return; // Directory already exists, ignore
    }

    final now = DateTime.now().millisecondsSinceEpoch;

    _db.execute(
      ArchiveSQL.insertFile,
      [
        normalizedPath,
        ArchiveEntryType.directory.index,
        0,
        0,
        now,
        now,
        null,
        null,
        0,
        null,
        null,
        null,
      ],
    );
  }

  /// Soft-delete an entry.
  Future<void> delete(String path) async {
    _ensureOpen();
    final normalizedPath = _normalizePath(path);

    _db.execute(ArchiveSQL.softDeleteFile, [normalizedPath]);

    final changes = _db.select('SELECT changes() as c');
    if (changes.first['c'] as int == 0) {
      throw EntryNotFoundException(normalizedPath);
    }
  }

  /// Rename or move an entry.
  Future<void> rename(String oldPath, String newPath) async {
    _ensureOpen();
    final normalizedOld = _normalizePath(oldPath);
    final normalizedNew = _normalizePath(newPath);

    if (await exists(normalizedNew)) {
      throw EntryExistsException(normalizedNew);
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(ArchiveSQL.renameFile, [normalizedNew, now, normalizedOld]);

    final changes = _db.select('SELECT changes() as c');
    if (changes.first['c'] as int == 0) {
      throw EntryNotFoundException(normalizedOld);
    }
  }

  /// Read file contents as a stream.
  Stream<Uint8List> readFile(
    String path, {
    ProgressCallback? onProgress,
    CancellationToken? cancellation,
  }) async* {
    _ensureOpen();
    final normalizedPath = _normalizePath(path);

    // Get file entry
    final entry = await getEntry(normalizedPath);
    if (!entry.isFile) {
      throw ArchiveIOException('Not a file', path: normalizedPath);
    }

    // Get file key
    final fileKey = await _keyDerivation.deriveFileKey(_keys.masterKey, entry.id);

    // Get file nonce
    final fileResult = _db.select(ArchiveSQL.selectFileById, [entry.id]);
    final fileNonce = fileResult.first['encryption_nonce'] as Uint8List;

    // Set up progress tracking
    final tracker = ProgressTracker(
      callback: onProgress,
      cancellation: cancellation,
      totalBytes: entry.size,
      totalItems: entry.chunkCount,
    );
    tracker.start();

    // Read and decrypt chunks
    final chunks = _db.select(ArchiveSQL.selectChunks, [entry.id]);

    for (final chunk in chunks) {
      tracker.checkCancelled();

      final sequence = chunk['sequence'] as int;
      final compression = CompressionType.fromValue(chunk['compression'] as int);
      final ciphertext = chunk['data'] as Uint8List;
      final authTag = chunk['auth_tag'] as Uint8List;

      // Decrypt
      final chunkNonce = _keyDerivation.createChunkNonce(fileNonce, sequence);
      final decrypted = await _keyDerivation.decrypt(
        ciphertext,
        authTag,
        fileKey,
        chunkNonce,
      );

      // Decompress
      final plaintext = Compression.decompress(decrypted, compression);

      yield plaintext;

      // Report progress
      if (!tracker.update(
        bytesAdded: plaintext.length,
        itemsAdded: 1,
      )) {
        throw const OperationCancelledException();
      }
    }

    tracker.update(forceReport: true);
  }

  /// Read entire file contents as bytes.
  Future<Uint8List> readFileBytes(String path) async {
    final chunks = <int>[];
    await for (final chunk in readFile(path)) {
      chunks.addAll(chunk);
    }
    return Uint8List.fromList(chunks);
  }

  /// Extract a file to disk.
  Future<void> extractFile(
    String archivePath,
    String diskPath, {
    ProgressCallback? onProgress,
    CancellationToken? cancellation,
  }) async {
    final file = File(diskPath);
    await file.parent.create(recursive: true);

    final sink = file.openWrite();
    try {
      await for (final chunk in readFile(
        archivePath,
        onProgress: onProgress,
        cancellation: cancellation,
      )) {
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
  }

  /// Extract all files to a directory.
  Future<void> extractAll(
    String outputDir, {
    String? prefix,
    ProgressCallback? onProgress,
    CancellationToken? cancellation,
  }) async {
    final entries = await listFiles(prefix: prefix);
    final files = entries.where((e) => e.isFile).toList();

    var processedBytes = 0;
    final totalBytes = files.fold<int>(0, (sum, e) => sum + e.size);

    for (var i = 0; i < files.length; i++) {
      cancellation?.throwIfCancelled();

      final entry = files[i];
      final diskPath = p.join(outputDir, entry.path);

      await extractFile(
        entry.path,
        diskPath,
        cancellation: cancellation,
      );

      processedBytes += entry.size;

      if (onProgress != null) {
        final progress = OperationProgress(
          bytesProcessed: processedBytes,
          totalBytes: totalBytes,
          itemsProcessed: i + 1,
          totalItems: files.length,
          currentOperation: entry.path,
        );
        if (!onProgress(progress)) {
          throw const OperationCancelledException();
        }
      }
    }
  }

  /// Check if an entry exists.
  Future<bool> exists(String path) async {
    _ensureOpen();
    final normalizedPath = _normalizePath(path);

    final result = _db.select(ArchiveSQL.selectFileByPath, [normalizedPath]);
    return result.isNotEmpty;
  }

  /// Get entry by path.
  Future<ArchiveEntry> getEntry(String path) async {
    _ensureOpen();
    final normalizedPath = _normalizePath(path);

    final result = _db.select(ArchiveSQL.selectFileByPath, [normalizedPath]);
    if (result.isEmpty) {
      throw EntryNotFoundException(normalizedPath);
    }

    return ArchiveEntry.fromRow(result.first);
  }

  /// List all files in the archive.
  Future<List<ArchiveEntry>> listFiles({
    String? prefix,
    bool includeDeleted = false,
  }) async {
    _ensureOpen();

    ResultSet result;
    if (prefix != null) {
      final normalizedPrefix = _normalizePath(prefix);
      result = _db.select(
        ArchiveSQL.listFilesWithPrefix,
        ['$normalizedPrefix%'],
      );
    } else if (includeDeleted) {
      result = _db.select(ArchiveSQL.listFilesIncludingDeleted);
    } else {
      result = _db.select(ArchiveSQL.listFiles);
    }

    return result.map((row) => ArchiveEntry.fromRow(row)).toList();
  }

  /// Get archive statistics.
  Future<ArchiveStats> getStats() async {
    _ensureOpen();

    final statsResult = _db.select(ArchiveSQL.selectStats);
    final dirCountResult = _db.select(ArchiveSQL.countDirectories);
    final dirCount = dirCountResult.first['count'] as int;

    if (statsResult.isEmpty) {
      return ArchiveStats.empty();
    }

    return ArchiveStats.fromRow(statsResult.first, dirCount);
  }

  /// Permanently delete soft-deleted entries and reclaim space.
  Future<int> vacuum({ProgressCallback? onProgress}) async {
    return _withWriteLock(() async {
    _ensureOpen();

    // Get deleted file IDs
    final deletedFiles = _db.select(ArchiveSQL.selectDeletedFiles);
    final count = deletedFiles.length;

    if (count == 0) {
      return 0;
    }

    // Delete chunks and files
    _db.execute('BEGIN TRANSACTION');
    try {
      for (var i = 0; i < deletedFiles.length; i++) {
        final fileId = deletedFiles[i]['id'] as int;
        _db.execute(ArchiveSQL.deleteChunksByFileId, [fileId]);
        _db.execute(ArchiveSQL.hardDeleteFile, [fileId]);

        if (onProgress != null) {
          final progress = OperationProgress(
            bytesProcessed: 0,
            itemsProcessed: i + 1,
            totalItems: count,
            currentOperation: 'Removing deleted entries',
          );
          if (!onProgress(progress)) {
            _db.execute('ROLLBACK');
            throw const OperationCancelledException();
          }
        }
      }

      // Update vacuum timestamp
      _db.execute(
        ArchiveSQL.updateVacuumTime,
        [DateTime.now().millisecondsSinceEpoch],
      );

      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }

    // Run SQLite vacuum to reclaim space
    _db.execute('VACUUM');

    return count;
    });
  }

  /// Verify archive integrity.
  Future<List<IntegrityError>> verifyIntegrity({
    ProgressCallback? onProgress,
    CancellationToken? cancellation,
  }) async {
    _ensureOpen();

    final errors = <IntegrityError>[];
    final files = await listFiles();

    for (var i = 0; i < files.length; i++) {
      cancellation?.throwIfCancelled();

      final entry = files[i];
      if (!entry.isFile) continue;

      try {
        // Read and verify each chunk
        final contentHasher = crypto.sha256.startChunkedConversion(
          _Sha256Sink(),
        );

        await for (final chunk in readFile(entry.path)) {
          contentHasher.add(chunk);
        }

        contentHasher.close();
        final computedHash = _lastSha256Hash;

        // Compare with stored hash
        if (entry.contentHash != null &&
            !KeyDerivation.constantTimeEquals(computedHash, entry.contentHash!)) {
          errors.add(IntegrityError(
            path: entry.path,
            type: IntegrityErrorType.hashMismatch,
            description: 'Content hash does not match stored hash',
          ));
        }
      } catch (e) {
        errors.add(IntegrityError(
          path: entry.path,
          type: IntegrityErrorType.authenticationFailed,
          description: 'Failed to decrypt: $e',
        ));
      }

      if (onProgress != null) {
        final progress = OperationProgress(
          bytesProcessed: 0,
          itemsProcessed: i + 1,
          totalItems: files.length,
          currentOperation: 'Verifying ${entry.name}',
        );
        if (!onProgress(progress)) {
          throw const OperationCancelledException();
        }
      }
    }

    // Update integrity check timestamp
    _db.execute(
      ArchiveSQL.updateIntegrityCheckTime,
      [DateTime.now().millisecondsSinceEpoch],
    );

    return errors;
  }

  /// Change the archive password.
  Future<void> changePassword(String oldPassword, String newPassword) async {
    _ensureOpen();

    // Read current header
    final headerResult = _db.select(ArchiveSQL.selectHeader);
    final header = headerResult.first;
    final oldSalt = header['salt'] as Uint8List;
    final storedVerificationHash = header['verification_hash'] as Uint8List;

    // Verify old password
    final oldKeyDerivation = KeyDerivation(_options);
    final oldKeys = await oldKeyDerivation.deriveFromPassword(oldPassword, oldSalt);

    if (!KeyDerivation.constantTimeEquals(
      oldKeys.verificationHash,
      storedVerificationHash,
    )) {
      oldKeys.dispose();
      throw const ArchiveAuthenticationException('Invalid old password');
    }

    // Generate new salt and derive new keys
    final newSalt = KeyDerivation.generateSalt();
    final newKeys = await _keyDerivation.deriveFromPassword(newPassword, newSalt);

    // Re-encrypt the master key with new password-derived key
    final encryptedMasterKey = await _keyDerivation.encryptMasterKey(
      _keys.masterKey,
      newKeys.masterKey,
    );

    // Update header
    _db.execute(
      ArchiveSQL.updateHeaderPassword,
      [newSalt, newKeys.verificationHash, encryptedMasterKey],
    );

    oldKeys.dispose();
    newKeys.dispose();
  }

  // ── Sync API ──────────────────────────────────────────────────────────
  //
  // Synchronous variants for callers that cannot await (e.g. WASM HAL file
  // callbacks). They use pointycastle AES-GCM and a sync HKDF that are
  // byte-compatible with the async paths. A sync write cannot interleave
  // with an in-flight async write (which holds a SQLite transaction across
  // awaits), so sync mutations throw if the async write lock is held.

  void _ensureNoAsyncWrite() {
    if (_writeLock != null) {
      throw const ArchiveIOException(
        'Archive busy: async write in progress; sync operation rejected',
      );
    }
  }

  /// Check if an entry exists (synchronous).
  bool existsSync(String path) {
    _ensureOpen();
    final result = _db.select(ArchiveSQL.selectFileByPath, [_normalizePath(path)]);
    return result.isNotEmpty;
  }

  /// Get entry by path (synchronous).
  ArchiveEntry getEntrySync(String path) {
    _ensureOpen();
    final normalizedPath = _normalizePath(path);
    final result = _db.select(ArchiveSQL.selectFileByPath, [normalizedPath]);
    if (result.isEmpty) {
      throw EntryNotFoundException(normalizedPath);
    }
    return ArchiveEntry.fromRow(result.first);
  }

  /// List files (synchronous).
  List<ArchiveEntry> listFilesSync({String? prefix, bool includeDeleted = false}) {
    _ensureOpen();
    ResultSet result;
    if (prefix != null) {
      result = _db.select(
        ArchiveSQL.listFilesWithPrefix,
        ['${_normalizePath(prefix)}%'],
      );
    } else if (includeDeleted) {
      result = _db.select(ArchiveSQL.listFilesIncludingDeleted);
    } else {
      result = _db.select(ArchiveSQL.listFiles);
    }
    return result.map((row) => ArchiveEntry.fromRow(row)).toList();
  }

  /// Read entire file contents as bytes (synchronous).
  Uint8List readFileBytesSync(String path) {
    _ensureOpen();
    final entry = getEntrySync(path);
    if (!entry.isFile) {
      throw ArchiveIOException('Not a file', path: entry.path);
    }

    final fileKey = _keyDerivation.deriveFileKeySync(_keys.masterKey, entry.id);
    final fileResult = _db.select(ArchiveSQL.selectFileById, [entry.id]);
    final fileNonce = fileResult.first['encryption_nonce'] as Uint8List;

    final chunks = _db.select(ArchiveSQL.selectChunks, [entry.id]);
    final out = BytesBuilder(copy: false);
    for (final chunk in chunks) {
      final sequence = chunk['sequence'] as int;
      final compression = CompressionType.fromValue(chunk['compression'] as int);
      final ciphertext = chunk['data'] as Uint8List;
      final authTag = chunk['auth_tag'] as Uint8List;

      final chunkNonce = _keyDerivation.createChunkNonce(fileNonce, sequence);
      final decrypted = KeyDerivation.decryptSync(
        ciphertext,
        authTag,
        fileKey,
        chunkNonce,
      );
      out.add(Compression.decompress(decrypted, compression));
    }
    return out.toBytes();
  }

  /// Add a file from bytes (synchronous). Throws if the entry exists;
  /// use [writeBytesSync] for overwrite semantics.
  ArchiveEntry addBytesSync(
    String path,
    List<int> bytes, {
    DateTime? createdAt,
    DateTime? modifiedAt,
    Map<String, String>? metadata,
  }) {
    _ensureOpen();
    _ensureNoAsyncWrite();
    final normalizedPath = _normalizePath(path);

    if (existsSync(normalizedPath)) {
      throw EntryExistsException(normalizedPath);
    }

    final now = DateTime.now();
    final created = createdAt ?? now;
    final modified = modifiedAt ?? now;
    final fileNonce = KeyDerivation.generateNonce();
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

    _db.execute('BEGIN TRANSACTION');
    try {
      _db.execute(
        ArchiveSQL.insertFile,
        [
          normalizedPath,
          ArchiveEntryType.file.index,
          0,
          0,
          created.millisecondsSinceEpoch,
          modified.millisecondsSinceEpoch,
          null,
          fileNonce,
          0,
          null,
          null,
          metadata != null ? jsonEncode(metadata) : null,
        ],
      );

      final fileId = _db.lastInsertRowId;
      final fileKey = _keyDerivation.deriveFileKeySync(_keys.masterKey, fileId);

      var sequence = 0;
      var totalSize = 0;
      var totalStoredSize = 0;
      for (var offset = 0; offset == 0 || offset < data.length; offset += _options.chunkSize) {
        final end = (offset + _options.chunkSize < data.length)
            ? offset + _options.chunkSize
            : data.length;
        final chunk = Uint8List.sublistView(data, offset, end);

        final compression = Compression.recommendCompression(
          chunk,
          _options.compression,
        );
        final compressed = Compression.compress(
          chunk,
          compression,
          level: _options.compressionLevel,
        );

        final chunkNonce = _keyDerivation.createChunkNonce(fileNonce, sequence);
        final encrypted = KeyDerivation.encryptSync(compressed, fileKey, chunkNonce);
        final chunkHash = KeyDerivation.sha256(chunk);

        _db.execute(
          ArchiveSQL.insertChunk,
          [
            fileId,
            sequence,
            chunk.length,
            encrypted.ciphertext.length,
            compression.value,
            encrypted.ciphertext,
            encrypted.authTag,
            chunkHash,
          ],
        );

        totalSize += chunk.length;
        totalStoredSize += encrypted.totalSize;
        sequence++;
        if (data.isEmpty) break; // zero-byte file: single empty chunk pass
      }

      final contentHash = KeyDerivation.sha256(data);
      _db.execute(
        ArchiveSQL.updateFileStats,
        [
          totalSize,
          totalStoredSize,
          sequence,
          contentHash,
          modified.millisecondsSinceEpoch,
          fileId,
        ],
      );

      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }

    return getEntrySync(normalizedPath);
  }

  /// Write bytes to [path], replacing any existing entry (synchronous).
  ArchiveEntry writeBytesSync(String path, List<int> bytes) {
    _ensureOpen();
    _ensureNoAsyncWrite();
    final normalizedPath = _normalizePath(path);
    if (existsSync(normalizedPath)) {
      deleteSync(normalizedPath);
    }
    return addBytesSync(normalizedPath, bytes);
  }

  /// Soft-delete an entry (synchronous).
  void deleteSync(String path) {
    _ensureOpen();
    _ensureNoAsyncWrite();
    final normalizedPath = _normalizePath(path);

    _db.execute(ArchiveSQL.softDeleteFile, [normalizedPath]);
    final changes = _db.select('SELECT changes() as c');
    if (changes.first['c'] as int == 0) {
      throw EntryNotFoundException(normalizedPath);
    }
  }

  /// Add a directory entry (synchronous).
  void addDirectorySync(String path) {
    _ensureOpen();
    _ensureNoAsyncWrite();
    final normalizedPath = _normalizePath(path);
    if (existsSync(normalizedPath)) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      ArchiveSQL.insertFile,
      [
        normalizedPath,
        ArchiveEntryType.directory.index,
        0,
        0,
        now,
        now,
        null,
        null,
        0,
        null,
        null,
        null,
      ],
    );
  }

  /// Close the archive and release resources.
  Future<void> close() async {
    if (_closed) return;

    _closed = true;
    _keys.dispose();
    _db.dispose();
  }

  /// Flush WAL to database file (checkpoint).
  /// Use PASSIVE mode for non-blocking checkpoint that won't interfere with ongoing operations.
  void checkpoint() {
    if (_closed) return;
    _db.execute('PRAGMA wal_checkpoint(PASSIVE);');
  }

  /// Normalize a path for storage.
  String _normalizePath(String path) {
    // Convert backslashes to forward slashes
    var normalized = path.replaceAll('\\', '/');

    // Remove leading slash
    if (normalized.startsWith('/')) {
      normalized = normalized.substring(1);
    }

    // Remove trailing slash
    if (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }

    // Collapse multiple slashes
    normalized = normalized.replaceAll(RegExp(r'/+'), '/');

    return normalized;
  }
}

// Helper for capturing SHA-256 hash result
Uint8List _lastSha256Hash = Uint8List(32);

class _Sha256Sink implements Sink<crypto.Digest> {
  @override
  void add(crypto.Digest data) {
    _lastSha256Hash = Uint8List.fromList(data.bytes);
  }

  @override
  void close() {}
}
