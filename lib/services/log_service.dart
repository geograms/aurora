/*
 * In-memory ring buffer of recent log lines, so the remote-control API
 * (RemoteApiService) can expose them over /api/log. main() pipes Flutter's
 * debugPrint through [add] at startup, so anything the app prints is captured.
 *
 * Pure Dart (no dart:io) — safe to import on web.
 */

/// Build marker — BUMP THIS EVERY BUILD so we can prove from /api/status or
/// /api/log which binary is actually running on the device (a stale reinstall
/// would still report the old tag). Surfaced in RemoteApiService /api/status
/// and logged at startup in main().
const String kAuroraBuildTag = 'bletx-20260605i';

/// Process-wide recent-log buffer.
class LogService {
  LogService._();
  static final LogService instance = LogService._();

  static const int _max = 2000;
  final List<String> _lines = <String>[];

  /// Append one line (timestamped). Oldest lines are dropped past [_max].
  void add(String line) {
    _lines.add('${DateTime.now().toIso8601String()}  $line');
    if (_lines.length > _max) {
      _lines.removeRange(0, _lines.length - _max);
    }
  }

  /// The most recent [n] lines (all of them when n <= 0 or n >= length).
  List<String> tail(int n) {
    if (n <= 0 || n >= _lines.length) return List<String>.of(_lines);
    return _lines.sublist(_lines.length - n);
  }

  int get length => _lines.length;
}
