/*
 * ServeStats — how often this device served each file to others, over time.
 *
 * Disk-folder files are served straight from disk (never copied into the media
 * archive), so the archive's `downloads` counter never sees them. This store
 * records a serve for ANY sha256 the node hands out, bucketed by day so the
 * history stays bounded (one row per file per day) while still answering
 * "how many times" and "how often over time" (last 24h / 7d / 30d).
 *
 * Path-injectable (':memory:' for tests). Synchronous; headless.
 */
import 'package:sqlite3/sqlite3.dart';

class FolderServeStats {
  final int totalServes; // all-time serves across the folder's files
  final int last24h;
  final int last7d;
  final int last30d;
  final int days; // distinct days with at least one serve
  final List<MapEntry<String, int>> top; // sha -> serves, descending

  const FolderServeStats({
    this.totalServes = 0,
    this.last24h = 0,
    this.last7d = 0,
    this.last30d = 0,
    this.days = 0,
    this.top = const [],
  });
}

class ServeStats {
  final Database _db;
  ServeStats._(this._db);

  static const int _msPerDay = 86400000;

  factory ServeStats.open(String path) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA synchronous = NORMAL;');
    db.execute('''
      CREATE TABLE IF NOT EXISTS serve_daily(
        sha TEXT NOT NULL,
        day INTEGER NOT NULL,
        n   INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (sha, day)
      );
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS serve_day ON serve_daily(day);');
    return ServeStats._(db);
  }

  int _today(int nowMs) => nowMs ~/ _msPerDay;

  /// Record one serve of [sha] (hex) at [nowMs] (defaults handled by caller).
  void record(String sha, int nowMs) {
    if (sha.isEmpty) return;
    try {
      _db.execute(
        'INSERT INTO serve_daily(sha, day, n) VALUES(?,?,1) '
        'ON CONFLICT(sha, day) DO UPDATE SET n = n + 1',
        [sha, _today(nowMs)],
      );
    } catch (_) {}
  }

  /// All-time serves of a single file.
  int countFor(String sha) {
    if (sha.isEmpty) return 0;
    try {
      final r = _db.select('SELECT SUM(n) AS s FROM serve_daily WHERE sha=?', [sha]);
      return (r.isEmpty ? null : r.first['s'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Aggregate stats across a set of files (the folder's current shas), as of
  /// [nowMs]. Windows are whole-day buckets (today, last 7, last 30).
  FolderServeStats forShas(List<String> shas, int nowMs, {int topN = 5}) {
    final uniq = <String>{for (final s in shas) if (s.isNotEmpty) s}.toList();
    if (uniq.isEmpty) return const FolderServeStats();
    final today = _today(nowMs);
    var total = 0, d1 = 0, d7 = 0, d30 = 0;
    final daySet = <int>{};
    final perSha = <String, int>{};
    // Chunk the IN(...) list to stay well under SQLite's variable limit.
    const chunk = 400;
    try {
      for (var i = 0; i < uniq.length; i += chunk) {
        final part = uniq.sublist(i, (i + chunk).clamp(0, uniq.length));
        final ph = List.filled(part.length, '?').join(',');
        final rows = _db.select(
            'SELECT sha, day, n FROM serve_daily WHERE sha IN ($ph)', part);
        for (final r in rows) {
          final sha = r['sha'] as String;
          final day = r['day'] as int;
          final n = r['n'] as int;
          total += n;
          perSha[sha] = (perSha[sha] ?? 0) + n;
          daySet.add(day);
          if (day >= today) d1 += n;
          if (day >= today - 6) d7 += n;
          if (day >= today - 29) d30 += n;
        }
      }
    } catch (_) {
      return const FolderServeStats();
    }
    final top = perSha.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return FolderServeStats(
      totalServes: total,
      last24h: d1,
      last7d: d7,
      last30d: d30,
      days: daySet.length,
      top: top.length > topN ? top.sublist(0, topN) : top,
    );
  }

  void close() {
    try {
      _db.dispose();
    } catch (_) {}
  }
}
