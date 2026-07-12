/// Progress reporting and cancellation support.
library;

import 'package:meta/meta.dart';

/// Reports progress of an archive operation.
@immutable
class OperationProgress {
  /// Number of bytes processed so far.
  final int bytesProcessed;

  /// Total bytes to process, if known.
  final int? totalBytes;

  /// Number of items (files/chunks) processed.
  final int itemsProcessed;

  /// Total items to process, if known.
  final int? totalItems;

  /// Description of current operation.
  final String? currentOperation;

  /// Estimated milliseconds remaining, if calculable.
  final int? estimatedMsRemaining;

  const OperationProgress({
    required this.bytesProcessed,
    this.totalBytes,
    this.itemsProcessed = 0,
    this.totalItems,
    this.currentOperation,
    this.estimatedMsRemaining,
  });

  /// Progress as a fraction (0.0 to 1.0), if total is known.
  double? get fraction {
    if (totalBytes != null && totalBytes! > 0) {
      return bytesProcessed / totalBytes!;
    }
    if (totalItems != null && totalItems! > 0) {
      return itemsProcessed / totalItems!;
    }
    return null;
  }

  /// Progress as a percentage (0 to 100), if total is known.
  int? get percent {
    final f = fraction;
    return f != null ? (f * 100).round() : null;
  }

  /// Human-readable progress string.
  String toDisplayString() {
    final parts = <String>[];

    // Percentage
    final pct = percent;
    if (pct != null) {
      parts.add('$pct%');
    }

    // Bytes
    parts.add(_formatBytes(bytesProcessed));
    if (totalBytes != null) {
      parts.add('of ${_formatBytes(totalBytes!)}');
    }

    // Items
    if (totalItems != null && totalItems! > 1) {
      parts.add('($itemsProcessed/$totalItems items)');
    }

    // Current operation
    if (currentOperation != null) {
      parts.add('- $currentOperation');
    }

    // ETA
    if (estimatedMsRemaining != null && estimatedMsRemaining! > 0) {
      parts.add('(${_formatDuration(estimatedMsRemaining!)} remaining)');
    }

    return parts.join(' ');
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String _formatDuration(int ms) {
    if (ms < 1000) return '${ms}ms';
    if (ms < 60000) return '${(ms / 1000).round()}s';
    final minutes = ms ~/ 60000;
    final seconds = (ms % 60000) ~/ 1000;
    if (minutes < 60) return '${minutes}m ${seconds}s';
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    return '${hours}h ${mins}m';
  }

  /// Create a copy with updated values.
  OperationProgress copyWith({
    int? bytesProcessed,
    int? totalBytes,
    int? itemsProcessed,
    int? totalItems,
    String? currentOperation,
    int? estimatedMsRemaining,
  }) {
    return OperationProgress(
      bytesProcessed: bytesProcessed ?? this.bytesProcessed,
      totalBytes: totalBytes ?? this.totalBytes,
      itemsProcessed: itemsProcessed ?? this.itemsProcessed,
      totalItems: totalItems ?? this.totalItems,
      currentOperation: currentOperation ?? this.currentOperation,
      estimatedMsRemaining: estimatedMsRemaining ?? this.estimatedMsRemaining,
    );
  }

  @override
  String toString() => 'OperationProgress(${toDisplayString()})';
}

/// Callback for reporting operation progress.
///
/// Return `true` to continue, `false` to request cancellation.
typedef ProgressCallback = bool Function(OperationProgress progress);

/// Token for cancelling long-running operations.
class CancellationToken {
  bool _cancelled = false;

  /// Whether cancellation has been requested.
  bool get isCancelled => _cancelled;

  /// Request cancellation of the operation.
  void cancel() {
    _cancelled = true;
  }

  /// Reset the token for reuse.
  void reset() {
    _cancelled = false;
  }

  /// Throws [OperationCancelledException] if cancelled.
  void throwIfCancelled() {
    if (_cancelled) {
      throw const _OperationCancelled();
    }
  }
}

/// Internal exception for cancellation (use OperationCancelledException from exceptions.dart).
class _OperationCancelled implements Exception {
  const _OperationCancelled();
}

/// Helper for tracking progress with rate limiting.
class ProgressTracker {
  final ProgressCallback? callback;
  final CancellationToken? cancellation;
  final int? totalBytes;
  final int? totalItems;
  final Duration reportInterval;

  int _bytesProcessed = 0;
  int _itemsProcessed = 0;
  String? _currentOperation;
  DateTime? _lastReport;
  DateTime? _startTime;

  ProgressTracker({
    this.callback,
    this.cancellation,
    this.totalBytes,
    this.totalItems,
    this.reportInterval = const Duration(milliseconds: 100),
  });

  /// Start tracking.
  void start() {
    _startTime = DateTime.now();
    _lastReport = _startTime;
  }

  /// Update progress and optionally report.
  ///
  /// Returns false if operation should be cancelled.
  bool update({
    int? bytesAdded,
    int? itemsAdded,
    String? currentOperation,
    bool forceReport = false,
  }) {
    // Check cancellation
    if (cancellation?.isCancelled ?? false) {
      return false;
    }

    // Update counters
    if (bytesAdded != null) _bytesProcessed += bytesAdded;
    if (itemsAdded != null) _itemsProcessed += itemsAdded;
    if (currentOperation != null) _currentOperation = currentOperation;

    // Rate limit reporting
    final now = DateTime.now();
    final shouldReport = forceReport ||
        callback != null &&
            (_lastReport == null ||
                now.difference(_lastReport!) >= reportInterval);

    if (shouldReport && callback != null) {
      _lastReport = now;

      // Calculate ETA
      int? eta;
      if (_startTime != null && totalBytes != null && _bytesProcessed > 0) {
        final elapsed = now.difference(_startTime!).inMilliseconds;
        final remaining = totalBytes! - _bytesProcessed;
        if (remaining > 0 && _bytesProcessed > 0) {
          eta = (elapsed * remaining / _bytesProcessed).round();
        }
      }

      final progress = OperationProgress(
        bytesProcessed: _bytesProcessed,
        totalBytes: totalBytes,
        itemsProcessed: _itemsProcessed,
        totalItems: totalItems,
        currentOperation: _currentOperation,
        estimatedMsRemaining: eta,
      );

      // Callback returns false to request cancellation
      if (!callback!(progress)) {
        return false;
      }
    }

    return true;
  }

  /// Check if cancelled, throw if so.
  void checkCancelled() {
    cancellation?.throwIfCancelled();
  }

  /// Get current bytes processed.
  int get bytesProcessed => _bytesProcessed;

  /// Get current items processed.
  int get itemsProcessed => _itemsProcessed;
}
