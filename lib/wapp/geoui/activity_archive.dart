// Persistence for the Activity feed (the unified stream of incoming group/DM
// posts that the APRS wapp sends via ui.chat.append on the "activity" field).
// Mirrors GeoChatArchive: one SQLite file per wapp data dir, shared by the
// foreground page AND the background engine, so a post received while the app is
// closed (background service) still shows up when the user opens the Activity
// tab. Time-ordered (no geo query). App-agnostic — just stores rows.
//
// Native only (SQLite via dart:ffi); every call is a no-op on web.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:sqlite3/sqlite3.dart';

import '../../profile/profile_storage.dart';

class ActivityArchive {
  ActivityArchive._(this._dbPath);

  static final Map<String, ActivityArchive> _instances = {};
  static ActivityArchive forStorage(ProfileStorage dataDir) =>
      _instances.putIfAbsent(dataDir.basePath,
          () => ActivityArchive._(dataDir.getAbsolutePath(_fileName)));

  static const String _fileName = 'activity.sqlite3';

  final String _dbPath;
  Database? _db;
  bool _failed = false;

  static const int _maxAgeMs = 60 * 24 * 60 * 60 * 1000; // 60 days
  static const int _maxRows = 200000; // firehose row ceiling
  static const int _maxBytes = 100 * 1024 * 1024; // firehose content ceiling
  bool _prunedThisSession = false;
  int _addsSincePrune = 0;

  /// Authors whose posts are never firehose-evicted — people the user follows
  /// or who follow the user (NOSTR web of trust). Injected by the host page;
  /// null means no exemptions (default APRS/chat behaviour is unchanged since
  /// its callsign authors never intersect this set).
  Set<String> Function()? protectedAuthors;

  // Short-window dedup (multi-hop/iGate repeats + fg/bg overlap) for mid-less
  // (APRS) posts.
  final Map<String, int> _recent = {};
  static const int _dedupWindowMs = 120000;

  // O(1) hot-path dedup for posts that carry a NOSTR event id (mid): the same
  // event from several relays is byte-identical, so we keep exactly one copy.
  final Set<String> _seenMids = {};

  Database? _ensureDb() {
    if (kIsWeb || _failed) return null;
    final existing = _db;
    if (existing != null) return existing;
    try {
      final parent = File(_dbPath).parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      final db = sqlite3.open(_dbPath);
      // INCREMENTAL auto-vacuum (must precede table creation) so firehose
      // deletes actually shrink the file, keeping it under the byte ceiling.
      db.execute('PRAGMA auto_vacuum = INCREMENTAL;');
      db.execute('PRAGMA journal_mode = WAL;');
      db.execute('PRAGMA synchronous = NORMAL;');
      db.execute('''
        CREATE TABLE IF NOT EXISTS activity(
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          t         INTEGER NOT NULL,
          dir       TEXT,
          from_call TEXT,
          text      TEXT,
          convo     TEXT,
          kind      TEXT,
          via       TEXT,
          meta      TEXT,
          lat       REAL,
          lon       REAL,
          time      TEXT
        );
      ''');
      db.execute('CREATE INDEX IF NOT EXISTS idx_activity_t ON activity(t);');
      // Per-post id (group-threading scheme) so Like/Reply attach to a post.
      final cols = {
        for (final r in db.select('PRAGMA table_info(activity)'))
          r['name'] as String
      };
      if (!cols.contains('mid')) {
        db.execute('ALTER TABLE activity ADD COLUMN mid TEXT;');
      }
      // Threaded replies: the post id (mid) this one replies to ("" = a root).
      if (!cols.contains('parent')) {
        db.execute('ALTER TABLE activity ADD COLUMN parent TEXT;');
      }
      // 1 = a "popular" post surfaced by the discovery feed (>=2 likes) — shown
      // in the All tab even after the transient like count is lost on restart.
      if (!cols.contains('pop')) {
        db.execute('ALTER TABLE activity ADD COLUMN pop INTEGER DEFAULT 0;');
      }
      db.execute('CREATE INDEX IF NOT EXISTS idx_activity_mid ON activity(mid);');
      db.execute(
          'CREATE INDEX IF NOT EXISTS idx_activity_parent ON activity(parent);');
      // A NOSTR event id (mid) is globally unique and byte-identical no matter
      // which relay served it, so a post must never be stored twice. Purge any
      // existing duplicate copies (keep the earliest row per mid), then enforce
      // it with a partial UNIQUE index — mid-less APRS rows are unaffected.
      try {
        db.execute("DELETE FROM activity WHERE mid IS NOT NULL AND mid != '' "
            "AND id NOT IN (SELECT MIN(id) FROM activity "
            "WHERE mid IS NOT NULL AND mid != '' GROUP BY mid);");
      } catch (_) {}
      db.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_activity_mid_uniq "
          "ON activity(mid) WHERE mid IS NOT NULL AND mid != '';");
      // Likes on a post id (mid). `mine` flags our own vote.
      db.execute('''
        CREATE TABLE IF NOT EXISTS activity_likes(
          mid   TEXT NOT NULL,
          liker TEXT NOT NULL,
          mine  INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(mid, liker)
        );
      ''');
      // Locally-saved (bookmarked) posts, by mid, with the post JSON to render.
      db.execute('''
        CREATE TABLE IF NOT EXISTS activity_saved(
          mid  TEXT PRIMARY KEY,
          t    INTEGER NOT NULL,
          json TEXT NOT NULL
        );
      ''');
      _db = db;
      return db;
    } catch (e) {
      _failed = true;
      debugPrint('ActivityArchive: open failed for $_dbPath: $e');
      return null;
    }
  }

  /// Archive one activity message map (as sent in ui.chat.append on "activity").
  void add(Map raw) {
    final text = (raw['text'] ?? '').toString();
    if (text.isEmpty) return;
    final db = _ensureDb();
    if (db == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final from = (raw['from'] ?? '').toString();
    final mid = (raw['mid'] ?? '').toString();
    if (mid.isNotEmpty) {
      // Dedup purely by event id: the same event served by several relays is
      // byte-identical, so keep one copy. Distinct events with the same text
      // (different mid) are NOT dropped.
      if (_seenMids.contains(mid)) return;
      _seenMids.add(mid);
      if (_seenMids.length > 20000) _seenMids.clear();
    } else {
      final key = '$from $text';
      final last = _recent[key];
      if (last != null && now - last < _dedupWindowMs) return;
      _recent[key] = now;
      if (_recent.length > 1024) {
        final entries = _recent.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value));
        for (var i = 0; i < entries.length ~/ 2; i++) {
          _recent.remove(entries[i].key);
        }
      }
    }
    try {
      db.execute(
        'INSERT OR IGNORE INTO activity(t,dir,from_call,text,convo,kind,via,meta,lat,lon,time,mid,parent,pop) '
        'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        [
          // Backfilled notes carry their real time so they sort correctly;
          // live posts default to now.
          (raw['t'] as num?)?.toInt() ?? now,
          (raw['dir'] ?? 'in').toString(),
          from,
          text,
          (raw['convo'] ?? '').toString(),
          (raw['kind'] ?? 'msg').toString(),
          (raw['via'] ?? '').toString(),
          (raw['meta'] ?? '').toString(),
          (raw['lat'] as num?)?.toDouble(),
          (raw['lon'] as num?)?.toDouble(),
          (raw['time'] ?? '').toString(),
          (raw['mid'] ?? '').toString(),
          (raw['parent'] ?? '').toString(),
          (raw['pop'] == 1 || raw['pop'] == '1' || raw['pop'] == true) ? 1 : 0,
        ],
      );
    } catch (e) {
      debugPrint('ActivityArchive: insert failed: $e');
      return;
    }
    _pruneOnce(db);
  }

  /// The most recent [limit] posts, oldest→newest (ready to render top→bottom).
  List<Map<String, dynamic>> recent({int limit = 300}) {
    final db = _ensureDb();
    if (db == null) return const [];
    ResultSet rows;
    try {
      rows = db.select(
        'SELECT t,dir,from_call,text,convo,kind,via,meta,lat,lon,time,mid,parent,pop '
        'FROM activity ORDER BY t DESC LIMIT ?',
        [limit],
      );
    } catch (e) {
      debugPrint('ActivityArchive: query failed: $e');
      return const [];
    }
    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      final m = <String, dynamic>{
        't': r['t'],
        'dir': r['dir'] ?? 'in',
        'from': r['from_call'] ?? '',
        'text': r['text'] ?? '',
        'kind': r['kind'] ?? 'msg',
        'mid': (r['mid'] ?? '').toString(),
        'parent': (r['parent'] ?? '').toString(),
        'time': (r['time'] ?? '').toString(),
        'pop': (r['pop'] as int?) ?? 0,
      };
      for (final f in const ['convo', 'via', 'meta']) {
        final v = (r[f] ?? '').toString();
        if (v.isNotEmpty) m[f] = v;
      }
      final lat = (r['lat'] as num?)?.toDouble();
      final lon = (r['lon'] as num?)?.toDouble();
      if (lat != null) m['lat'] = lat;
      if (lon != null) m['lon'] = lon;
      out.add(m);
    }
    return out.reversed.toList(); // oldest→newest
  }

  /// The direct replies to post [mid], oldest→newest (for the thread view).
  List<Map<String, dynamic>> repliesFor(String mid, {int limit = 300}) {
    final db = _ensureDb();
    if (db == null || mid.isEmpty) return const [];
    ResultSet rows;
    try {
      rows = db.select(
        'SELECT t,dir,from_call,text,convo,kind,via,meta,lat,lon,time,mid,parent,pop '
        'FROM activity WHERE parent = ? ORDER BY t ASC LIMIT ?',
        [mid, limit],
      );
    } catch (e) {
      debugPrint('ActivityArchive: repliesFor failed: $e');
      return const [];
    }
    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      final m = <String, dynamic>{
        't': r['t'],
        'dir': r['dir'] ?? 'in',
        'from': r['from_call'] ?? '',
        'text': r['text'] ?? '',
        'kind': r['kind'] ?? 'msg',
        'mid': (r['mid'] ?? '').toString(),
        'parent': (r['parent'] ?? '').toString(),
        'time': (r['time'] ?? '').toString(),
        'pop': (r['pop'] as int?) ?? 0,
      };
      for (final f in const ['convo', 'via', 'meta']) {
        final v = (r[f] ?? '').toString();
        if (v.isNotEmpty) m[f] = v;
      }
      final lat = (r['lat'] as num?)?.toDouble();
      final lon = (r['lon'] as num?)?.toDouble();
      if (lat != null) m['lat'] = lat;
      if (lon != null) m['lon'] = lon;
      out.add(m);
    }
    return out;
  }

  /// Every reply in the thread rooted at [rootMid] — direct replies and replies
  /// to those replies (BFS over parent links) — oldest→newest. Used for the
  /// thread view so each message is replyable and shows its own reply count.
  List<Map<String, dynamic>> threadReplies(String rootMid,
      {int maxDepth = 12, int limit = 500}) {
    if (rootMid.isEmpty) return const [];
    final out = <Map<String, dynamic>>[];
    final seen = <String>{rootMid};
    var frontier = <String>[rootMid];
    var depth = 0;
    while (frontier.isNotEmpty && depth < maxDepth && out.length < limit) {
      final next = <String>[];
      for (final pid in frontier) {
        for (final r in repliesFor(pid)) {
          final mid = (r['mid'] ?? '').toString();
          if (mid.isEmpty || seen.add(mid)) {
            out.add(r);
            if (mid.isNotEmpty) next.add(mid);
          }
        }
      }
      frontier = next;
      depth++;
    }
    out.sort((a, b) => (a['t'] as int? ?? 0).compareTo(b['t'] as int? ?? 0));
    return out;
  }

  /// The stored post with this [mid], in the same map shape [recent] emits, or
  /// null. Lets the host open a thread for a post it learned about elsewhere
  /// (e.g. the launcher hero card).
  Map<String, dynamic>? byMid(String mid) {
    final db = _ensureDb();
    if (db == null || mid.isEmpty) return null;
    ResultSet rows;
    try {
      rows = db.select(
        'SELECT t,dir,from_call,text,convo,kind,via,meta,lat,lon,time,mid,parent,pop '
        'FROM activity WHERE mid = ? LIMIT 1',
        [mid],
      );
    } catch (_) {
      return null;
    }
    if (rows.isEmpty) return null;
    final r = rows.first;
    final m = <String, dynamic>{
      't': r['t'],
      'dir': r['dir'] ?? 'in',
      'from': r['from_call'] ?? '',
      'text': r['text'] ?? '',
      'kind': r['kind'] ?? 'msg',
      'mid': (r['mid'] ?? '').toString(),
      'parent': (r['parent'] ?? '').toString(),
      'time': (r['time'] ?? '').toString(),
      'pop': (r['pop'] as int?) ?? 0,
    };
    for (final f in const ['convo', 'via', 'meta']) {
      final v = (r[f] ?? '').toString();
      if (v.isNotEmpty) m[f] = v;
    }
    final lat = (r['lat'] as num?)?.toDouble();
    final lon = (r['lon'] as num?)?.toDouble();
    if (lat != null) m['lat'] = lat;
    if (lon != null) m['lon'] = lon;
    return m;
  }

  /// Whether a post with this [mid] is already stored (content-hash dedup, used
  /// to avoid re-inserting backfilled notes we already have).
  bool hasMid(String mid) {
    final db = _ensureDb();
    if (db == null || mid.isEmpty) return false;
    try {
      return db
          .select('SELECT 1 FROM activity WHERE mid = ? LIMIT 1', [mid])
          .isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Whether this exact (from, text) post is already stored — robust dedup for
  /// backfill (old rows may lack a `mid`, so we match on content directly).
  bool hasContent(String from, String text) {
    final db = _ensureDb();
    if (db == null || text.isEmpty) return false;
    try {
      return db.select(
          'SELECT 1 FROM activity WHERE from_call = ? AND text = ? LIMIT 1',
          [from, text]).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Number of direct replies to post [mid].
  int replyCount(String mid) {
    final db = _ensureDb();
    if (db == null || mid.isEmpty) return 0;
    try {
      return db.select('SELECT COUNT(*) c FROM activity WHERE parent = ?',
          [mid]).first['c'] as int;
    } catch (_) {
      return 0;
    }
  }

  /// Posts authored by [callsign], oldest→newest (for a profile page).
  List<Map<String, dynamic>> byAuthor(String callsign, {int limit = 200}) {
    final db = _ensureDb();
    if (db == null || callsign.isEmpty) return const [];
    ResultSet rows;
    try {
      rows = db.select(
        'SELECT t,dir,from_call,text,convo,kind,via,meta,lat,lon,time,mid,parent,pop '
        'FROM activity WHERE from_call = ? ORDER BY t DESC LIMIT ?',
        [callsign, limit],
      );
    } catch (e) {
      debugPrint('ActivityArchive: byAuthor failed: $e');
      return const [];
    }
    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      final m = <String, dynamic>{
        't': r['t'],
        'dir': r['dir'] ?? 'in',
        'from': r['from_call'] ?? '',
        'text': r['text'] ?? '',
        'kind': r['kind'] ?? 'msg',
        'mid': (r['mid'] ?? '').toString(),
        'parent': (r['parent'] ?? '').toString(),
        'time': (r['time'] ?? '').toString(),
        'pop': (r['pop'] as int?) ?? 0,
      };
      for (final f in const ['convo', 'via', 'meta']) {
        final v = (r[f] ?? '').toString();
        if (v.isNotEmpty) m[f] = v;
      }
      out.add(m);
    }
    return out.reversed.toList();
  }

  // ── Likes ────────────────────────────────────────────────────────────────

  /// Record (or retract) a like on post [mid] by [liker]. [mine] flags our vote.
  void setReaction(String mid, String liker, bool like, bool mine) {
    final db = _ensureDb();
    if (db == null || mid.isEmpty || liker.isEmpty) return;
    try {
      if (like) {
        db.execute(
            'INSERT OR REPLACE INTO activity_likes(mid,liker,mine) VALUES(?,?,?)',
            [mid, liker, mine ? 1 : 0]);
      } else {
        db.execute('DELETE FROM activity_likes WHERE mid=? AND liker=?',
            [mid, liker]);
      }
    } catch (_) {}
  }

  /// Like count + whether WE liked, for post [mid].
  ({int count, bool mine}) likeInfo(String mid) {
    final db = _ensureDb();
    if (db == null || mid.isEmpty) return (count: 0, mine: false);
    try {
      final c = db.select('SELECT COUNT(*) c, MAX(mine) m FROM activity_likes WHERE mid=?',
          [mid]).first;
      return (count: (c['c'] as int?) ?? 0, mine: ((c['m'] as int?) ?? 0) == 1);
    } catch (_) {
      return (count: 0, mine: false);
    }
  }

  // ── Saved (bookmarks) ──────────────────────────────────────────────────────

  bool isSaved(String mid) {
    final db = _ensureDb();
    if (db == null || mid.isEmpty) return false;
    try {
      return db.select('SELECT 1 FROM activity_saved WHERE mid=?', [mid])
          .isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Toggle saving [post] (a post map carrying a `mid`). Returns the new state.
  bool toggleSaved(Map<String, dynamic> post) {
    final db = _ensureDb();
    final mid = (post['mid'] ?? '').toString();
    if (db == null || mid.isEmpty) return false;
    try {
      if (isSaved(mid)) {
        db.execute('DELETE FROM activity_saved WHERE mid=?', [mid]);
        return false;
      }
      db.execute('INSERT OR REPLACE INTO activity_saved(mid,t,json) VALUES(?,?,?)',
          [mid, DateTime.now().millisecondsSinceEpoch, jsonEncode(post)]);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Saved posts, newest first.
  List<Map<String, dynamic>> savedPosts({int limit = 300}) {
    final db = _ensureDb();
    if (db == null) return const [];
    try {
      final rows = db.select(
          'SELECT json FROM activity_saved ORDER BY t DESC LIMIT ?', [limit]);
      return [
        for (final r in rows)
          (jsonDecode(r['json'] as String) as Map).cast<String, dynamic>()
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Epoch-ms of the first post we ever archived from [callsign], or null.
  int? firstSeenMs(String callsign) {
    final db = _ensureDb();
    if (db == null || callsign.isEmpty) return null;
    try {
      final r = db.select(
          'SELECT MIN(t) m FROM activity WHERE from_call = ?', [callsign]);
      final v = r.isEmpty ? null : r.first['m'];
      return v is int ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// Number of posts archived from [callsign].
  int postCount(String callsign) {
    final db = _ensureDb();
    if (db == null || callsign.isEmpty) return 0;
    try {
      return db.select('SELECT COUNT(*) c FROM activity WHERE from_call = ?',
          [callsign]).first['c'] as int;
    } catch (_) {
      return 0;
    }
  }

  void _pruneOnce(Database db) {
    // Protected (followed / follower) authors are never firehose-evicted.
    final prot = protectedAuthors?.call() ?? const <String>{};
    final protList = prot.toList();
    final notProt = prot.isEmpty
        ? ''
        : ' AND from_call NOT IN (${List.filled(prot.length, '?').join(',')})';

    // Age prune (60 days) runs once per session; protected rows are kept.
    if (!_prunedThisSession) {
      _prunedThisSession = true;
      try {
        final cutoff = DateTime.now().millisecondsSinceEpoch - _maxAgeMs;
        db.execute(
            'DELETE FROM activity WHERE t < ?$notProt', [cutoff, ...protList]);
      } catch (e) {
        debugPrint('ActivityArchive: age-prune failed: $e');
      }
    }

    // Row + byte caps run periodically — a firehose floods within one session,
    // so a once-per-session prune is not enough. This MUST stay cheap: it runs
    // on the add() hot path (the engine thread), so it does O(1) DELETEs and
    // converges over successive calls rather than looping-until-under.
    if (++_addsSincePrune < 400) return;
    _addsSincePrune = 0;
    try {
      // Row cap: keep the newest _maxRows unprotected rows.
      db.execute(
        'DELETE FROM activity WHERE id NOT IN '
        '(SELECT id FROM activity ORDER BY t DESC LIMIT ?)$notProt',
        [_maxRows, ...protList],
      );
      // Byte cap: one bounded batch. Estimate how many oldest unprotected rows
      // to drop from the average row size, capped at 20k so this stays cheap;
      // if we are still over next time, the next prune trims more.
      final bytes = _dataBytes(db);
      if (bytes > _maxBytes) {
        final rows = db
            .select('SELECT COUNT(*) c FROM activity WHERE 1=1$notProt', protList)
            .first['c'] as int;
        if (rows > 0) {
          final avg = (bytes / rows).clamp(64, 1 << 20);
          var drop = ((bytes - _maxBytes) / avg).ceil() + 500;
          if (drop > 20000) drop = 20000;
          db.execute(
            'DELETE FROM activity WHERE id IN '
            '(SELECT id FROM activity WHERE 1=1$notProt ORDER BY t ASC LIMIT ?)',
            [...protList, drop],
          );
          db.execute('PRAGMA incremental_vacuum;');
        }
      }
    } catch (e) {
      debugPrint('ActivityArchive: cap-prune failed: $e');
    }
  }

  /// On-disk database size (page_count × page_size) — O(1), so it is safe to
  /// call on the add() hot path. With INCREMENTAL auto-vacuum the freed pages
  /// return after a delete, so this tracks the real file the user cares about.
  int _dataBytes(Database db) {
    try {
      final pc = (db.select('PRAGMA page_count').first.values.first as num).toInt();
      final ps = (db.select('PRAGMA page_size').first.values.first as num).toInt();
      return pc * ps;
    } catch (_) {
      return 0;
    }
  }

  /// Wipe every archived post (the "Clear feed" action). Likes/saved rows are
  /// kept — a user's bookmarks shouldn't vanish with a feed clear.
  void clearAll() {
    final db = _ensureDb();
    if (db == null) return;
    try {
      db.execute('DELETE FROM activity;');
      db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
      db.execute('PRAGMA incremental_vacuum;');
      _recent.clear();
    } catch (e) {
      debugPrint('ActivityArchive: clear failed: $e');
    }
  }

  void close() {
    try {
      _db?.dispose();
    } catch (_) {}
    _db = null;
  }
}
