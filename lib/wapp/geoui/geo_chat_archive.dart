// Generic, app-agnostic persistence for geo-tagged chat messages (the
// "geochat" chat_view field). Mirrors the role of ConversationStore, but for
// the live geo-chat feed: every Live message that carries a position is stored
// so it survives restarts, and can be queried back by a centre + radius so a
// wapp can show the older messages for a chosen region.
//
// Backed by SQLite (same as wapp_social_store.dart) — chosen over a flat
// append-log specifically for durability: writes are atomic/WAL-journalled, an
// app crash mid-write can't shred the file, and a single corrupt row never
// costs the whole archive (vs. a line-log where one bad line + a rewrite-prune
// risks the lot). Range queries use an indexed lat/lon bounding-box prefilter
// plus an exact haversine check, so they stay fast as the table grows.
//
// No domain knowledge here (no APRS/callsign/beacon semantics): a wapp decides
// what to archive (it sends only messages with lat/lon) and when to query a
// region; this just stores rows and answers haversine range queries.
//
// Native only — SQLite needs dart:ffi. Every call is a no-op on web (kIsWeb),
// matching wapp_social_store.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:sqlite3/sqlite3.dart';

import '../../profile/profile_db.dart';

import '../../profile/profile_storage.dart';

class GeoChatArchive {
  GeoChatArchive._(this._dbPath);

  /// One archive per wapp data dir (shared between the foreground page and the
  /// background engine so both write to the same database).
  static final Map<String, GeoChatArchive> _instances = {};
  static GeoChatArchive forStorage(ProfileStorage dataDir) =>
      _instances.putIfAbsent(dataDir.basePath,
          () => GeoChatArchive._(dataDir.getAbsolutePath(_fileName)));

  static const String _fileName = 'geochat.sqlite3';

  final String _dbPath;
  Database? _db;
  bool _failed = false; // a fatal open error → operate degraded, never wipe

  // Keep the archive bounded (pruned with atomic DELETEs, no rewrite).
  static const int _maxAgeMs = 60 * 24 * 60 * 60 * 1000; // 60 days
  static const int _maxRows = 50000;
  bool _prunedThisSession = false;

  // Short-window content dedup (handles multi-hop/iGate repeats and the brief
  // overlap if a foreground page and a background engine both observe one msg).
  final Map<String, int> _recent = {};
  static const int _dedupWindowMs = 120000; // 2 min

  // ── DB lifecycle ────────────────────────────────────────────────────────

  Database? _ensureDb() {
    if (kIsWeb || _failed) return null;
    final existing = _db;
    if (existing != null) return existing;
    try {
      // sqlite3.open creates the file but not parent dirs.
      final parent = File(_dbPath).parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      final db = openProfileDb(_dbPath);
      db.execute('PRAGMA journal_mode = WAL;'); // crash-safe, concurrent reads
      db.execute('PRAGMA synchronous = NORMAL;');
      db.execute('''
        CREATE TABLE IF NOT EXISTS geochat(
          id   INTEGER PRIMARY KEY AUTOINCREMENT,
          t    INTEGER NOT NULL,
          dir  TEXT,
          from_call TEXT,
          text TEXT,
          kind TEXT,
          via  TEXT,
          meta TEXT,
          lat  REAL NOT NULL,
          lon  REAL NOT NULL
        );
      ''');
      db.execute('CREATE INDEX IF NOT EXISTS idx_geochat_t ON geochat(t);');
      db.execute(
          'CREATE INDEX IF NOT EXISTS idx_geochat_latlon ON geochat(lat, lon);');
      _db = db;
      return db;
    } catch (e) {
      // Don't destroy a possibly-recoverable file — just disable for the
      // session so the live feed keeps working.
      _failed = true;
      debugPrint('GeoChatArchive: open failed for $_dbPath: $e');
      return null;
    }
  }

  // ── Append ────────────────────────────────────────────────────────────

  /// Archive one geochat message map (as sent in `ui.chat.append`). Stores it
  /// only when it is geo-tagged (has lat & lon) and is a Live chat line (text
  /// begins with the ">>" marker the geochat field uses for Live vs beacons).
  /// Transient position beacons are intentionally not archived.
  void add(Map raw) {
    final text = (raw['text'] ?? '').toString();
    if (!text.trimLeft().startsWith('>>')) return; // Live messages only
    final lat = (raw['lat'] as num?)?.toDouble();
    final lon = (raw['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return; // need a position to bind to
    if (lat == 0 && lon == 0) return;

    final db = _ensureDb();
    if (db == null) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final from = (raw['from'] ?? '').toString();
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

    try {
      db.execute(
        'INSERT INTO geochat(t,dir,from_call,text,kind,via,meta,lat,lon) '
        'VALUES(?,?,?,?,?,?,?,?,?)',
        [
          now,
          (raw['dir'] ?? 'in').toString(),
          from,
          text,
          (raw['kind'] ?? 'msg').toString(),
          (raw['via'] ?? '').toString(),
          (raw['meta'] ?? '').toString(),
          lat,
          lon,
        ],
      );
    } catch (e) {
      debugPrint('GeoChatArchive: insert failed: $e');
      return;
    }
    _pruneOnce(db);
  }

  // ── Query ─────────────────────────────────────────────────────────────

  /// Archived messages within [radiusKm] of (lat,lon), newest [limit], in
  /// oldest→newest order so a caller can replay them straight into a feed.
  /// [sinceMs] (epoch ms) optionally bounds how far back to look.
  ///
  /// Uses an indexed lat/lon bounding-box prefilter, then an exact haversine
  /// check on the candidates.
  List<Map<String, dynamic>> query({
    required double lat,
    required double lon,
    required double radiusKm,
    int limit = 200,
    int? sinceMs,
  }) {
    final db = _ensureDb();
    if (db == null) return const [];

    // Bounding box around the centre (a small over-fetch the haversine trims).
    final dLat = radiusKm / 111.32;
    final cosLat = math.cos(_rad(lat)).abs();
    final dLon = radiusKm / (111.32 * (cosLat < 1e-6 ? 1e-6 : cosLat));
    final since = sinceMs ?? 0;

    ResultSet rows;
    try {
      rows = db.select(
        'SELECT t,dir,from_call,text,kind,via,meta,lat,lon FROM geochat '
        'WHERE t >= ? AND lat BETWEEN ? AND ? AND lon BETWEEN ? AND ? '
        'ORDER BY t ASC',
        [since, lat - dLat, lat + dLat, lon - dLon, lon + dLon],
      );
    } catch (e) {
      debugPrint('GeoChatArchive: query failed: $e');
      return const [];
    }

    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      final mlat = (r['lat'] as num).toDouble();
      final mlon = (r['lon'] as num).toDouble();
      if (_haversineKm(lat, lon, mlat, mlon) > radiusKm) continue;
      final m = <String, dynamic>{
        't': r['t'],
        'dir': r['dir'] ?? 'in',
        'from': r['from_call'] ?? '',
        'text': r['text'] ?? '',
        'kind': r['kind'] ?? 'msg',
        'lat': mlat,
        'lon': mlon,
      };
      final via = (r['via'] ?? '').toString();
      if (via.isNotEmpty) m['via'] = via;
      final meta = (r['meta'] ?? '').toString();
      if (meta.isNotEmpty) m['meta'] = meta;
      out.add(m);
    }
    // rows are already oldest-first; keep the newest `limit`.
    if (out.length > limit) return out.sublist(out.length - limit);
    return out;
  }

  // ── Prune ─────────────────────────────────────────────────────────────

  /// One prune per session: drop rows older than [_maxAgeMs] and cap the row
  /// count at [_maxRows]. Both are atomic DELETEs — no risky file rewrite.
  void _pruneOnce(Database db) {
    if (_prunedThisSession) return;
    _prunedThisSession = true;
    try {
      final cutoff = DateTime.now().millisecondsSinceEpoch - _maxAgeMs;
      db.execute('DELETE FROM geochat WHERE t < ?', [cutoff]);
      db.execute(
        'DELETE FROM geochat WHERE id NOT IN '
        '(SELECT id FROM geochat ORDER BY t DESC LIMIT ?)',
        [_maxRows],
      );
    } catch (e) {
      debugPrint('GeoChatArchive: prune failed: $e');
    }
  }

  /// Close the database (tests / teardown).
  void close() {
    try {
      _db?.dispose();
    } catch (_) {}
    _db = null;
  }

  // ── Geo ───────────────────────────────────────────────────────────────

  static double _haversineKm(
      double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0; // km
    final dLat = _rad(lat2 - lat1);
    final dLon = _rad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(lat1)) *
            math.cos(_rad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _rad(double deg) => deg * math.pi / 180.0;
}
