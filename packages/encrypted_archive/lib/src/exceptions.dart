/// Exception types for the encrypted_archive package.
library;

/// Base exception for all archive-related errors.
sealed class ArchiveException implements Exception {
  /// Human-readable error message.
  final String message;

  /// Optional underlying cause.
  final Object? cause;

  const ArchiveException(this.message, [this.cause]);

  @override
  String toString() {
    if (cause != null) {
      return '$runtimeType: $message (caused by: $cause)';
    }
    return '$runtimeType: $message';
  }
}

/// Thrown when an archive cannot be opened.
class ArchiveOpenException extends ArchiveException {
  /// Path to the archive file.
  final String path;

  const ArchiveOpenException(this.path, super.message, [super.cause]);

  @override
  String toString() => 'ArchiveOpenException: $message (path: $path)';
}

/// Thrown when archive data is corrupted or invalid.
class ArchiveCorruptedException extends ArchiveException {
  /// Description of what was corrupted.
  final String? detail;

  const ArchiveCorruptedException(String message, {this.detail, Object? cause})
      : super(message, cause);

  @override
  String toString() {
    final detailStr = detail != null ? ' ($detail)' : '';
    return 'ArchiveCorruptedException: $message$detailStr';
  }
}

/// Thrown when a cryptographic operation fails.
class ArchiveCryptoException extends ArchiveException {
  const ArchiveCryptoException(super.message, [super.cause]);
}

/// Thrown when password verification fails.
class ArchiveAuthenticationException extends ArchiveException {
  const ArchiveAuthenticationException([String message = 'Invalid password'])
      : super(message);
}

/// Thrown when a requested entry is not found in the archive.
class EntryNotFoundException extends ArchiveException {
  /// Path that was not found.
  final String path;

  const EntryNotFoundException(this.path)
      : super('Entry not found: $path');

  @override
  String toString() => 'EntryNotFoundException: $path';
}

/// Thrown when attempting to create an entry that already exists.
class EntryExistsException extends ArchiveException {
  /// Path that already exists.
  final String path;

  const EntryExistsException(this.path)
      : super('Entry already exists: $path');

  @override
  String toString() => 'EntryExistsException: $path';
}

/// Thrown when an I/O operation fails.
class ArchiveIOException extends ArchiveException {
  /// Path involved in the operation.
  final String? path;

  const ArchiveIOException(String message, {this.path, Object? cause})
      : super(message, cause);

  @override
  String toString() {
    final pathStr = path != null ? ' (path: $path)' : '';
    return 'ArchiveIOException: $message$pathStr';
  }
}

/// Thrown when an operation is attempted on a closed archive.
class ArchiveClosedException extends ArchiveException {
  const ArchiveClosedException()
      : super('Archive is closed');
}

/// Thrown when an operation is cancelled.
class OperationCancelledException extends ArchiveException {
  const OperationCancelledException([String message = 'Operation cancelled'])
      : super(message);
}

/// Thrown when integrity verification fails.
class IntegrityException extends ArchiveException {
  /// List of integrity errors found.
  final List<IntegrityError> errors;

  const IntegrityException(this.errors)
      : super('Archive integrity check failed');

  @override
  String toString() =>
      'IntegrityException: ${errors.length} error(s) found';
}

/// Describes a single integrity error.
class IntegrityError {
  /// Path of the affected entry, if applicable.
  final String? path;

  /// Chunk sequence number, if applicable.
  final int? chunkSequence;

  /// Type of error.
  final IntegrityErrorType type;

  /// Human-readable description.
  final String description;

  const IntegrityError({
    this.path,
    this.chunkSequence,
    required this.type,
    required this.description,
  });

  @override
  String toString() {
    final location = path != null
        ? (chunkSequence != null ? '$path[chunk $chunkSequence]' : path)
        : 'archive';
    return 'IntegrityError($type): $description at $location';
  }
}

/// Types of integrity errors.
enum IntegrityErrorType {
  /// Authentication tag verification failed.
  authenticationFailed,

  /// Content hash doesn't match stored hash.
  hashMismatch,

  /// Chunk is missing or out of sequence.
  missingChunk,

  /// File metadata is inconsistent.
  metadataCorrupted,

  /// Database structure is damaged.
  schemaCorrupted,

  /// Unexpected data format.
  invalidFormat,
}
