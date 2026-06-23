/*
 * ObservedStore — a small, persistent on-disk cache of the Reticulum nodes this
 * device has observed (heard announce). Backs RnsService's in-memory registry so
 * "first seen by you" survives restarts, and so the amount of devices / how many
 * are geogram-related can be answered with a fast indexed query instead of only
 * the live (capped, swept) working set.
 *
 * Generic RNS infrastructure — carries no app-specific knowledge. The DB path is
 * chosen by the wiring layer (rns_autostart points it at the reticulum wapp's
 * per-profile data folder).
 */
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../log_service.dart';

class ObservedStore {
  ObservedStore(this.path);
  final String path;
  Database? _db;

  bool get isOpen => _db != null;

  /// Open (and create/migrate) the database. Returns true on success.
  bool open() {
    if (_db != null) return true;
    try {
      // sqlite3.open creates the file but not parent dirs.
      final parent = File(path).parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      final db = sqlite3.open(path);
      db.execute('PRAGMA journal_mode = WAL;');
      db.execute('PRAGMA synchronous = NORMAL;');
      db.execute('''
        CREATE TABLE IF NOT EXISTS nodes(
          id         TEXT PRIMARY KEY,
          pubkey     TEXT,
          callsign   TEXT,
          services   TEXT,
          geogram    INTEGER NOT NULL DEFAULT 0,
          hops       INTEGER NOT NULL DEFAULT 0,
          via        TEXT,
          uptime     INTEGER NOT NULL DEFAULT 0,
          first_seen INTEGER NOT NULL,
          last_seen  INTEGER NOT NULL
        );
      ''');
      // Migration: add the uptime column to a pre-existing DB (older schema).
      final cols = {
        for (final r in db.select('PRAGMA table_info(nodes)')) r['name'] as String
      };
      if (!cols.contains('uptime')) {
        db.execute('ALTER TABLE nodes ADD COLUMN uptime INTEGER NOT NULL DEFAULT 0;');
      }
      db.execute('CREATE INDEX IF NOT EXISTS idx_nodes_geo ON nodes(geogram);');
      db.execute('CREATE INDEX IF NOT EXISTS idx_nodes_last ON nodes(last_seen);');
      _db = db;
      return true;
    } catch (e) {
      LogService.instance.add('ObservedStore: open failed: $e');
      return false;
    }
  }

  /// The persisted first_seen for every known node id (so a node that drops out
  /// of the live registry and reappears keeps its true first-seen time).
  Map<String, int> loadFirstSeen() {
    final db = _db;
    if (db == null) return {};
    final out = <String, int>{};
    try {
      for (final r in db.select('SELECT id, first_seen FROM nodes')) {
        out[r['id'] as String] = r['first_seen'] as int;
      }
    } catch (e) {
      LogService.instance.add('ObservedStore: loadFirstSeen failed: $e');
    }
    return out;
  }

  /// Upsert a batch of node rows in one transaction. [rows] entries carry:
  /// id, pubkey, callsign, services (csv), geogram (0/1), hops, via,
  /// firstSeen, lastSeen. first_seen is preserved across updates.
  void upsertMany(Iterable<Map<String, Object?>> rows) {
    final db = _db;
    if (db == null) return;
    PreparedStatement? stmt;
    try {
      db.execute('BEGIN');
      stmt = db.prepare('''
        INSERT INTO nodes(id,pubkey,callsign,services,geogram,hops,via,uptime,first_seen,last_seen)
        VALUES(?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          pubkey=excluded.pubkey,
          callsign=COALESCE(NULLIF(excluded.callsign,''), nodes.callsign),
          services=excluded.services,
          geogram=MAX(nodes.geogram, excluded.geogram),
          hops=excluded.hops,
          via=excluded.via,
          uptime=CASE WHEN excluded.uptime>0 THEN excluded.uptime ELSE nodes.uptime END,
          last_seen=excluded.last_seen
      ''');
      for (final r in rows) {
        stmt.execute([
          r['id'],
          r['pubkey'] ?? '',
          r['callsign'] ?? '',
          r['services'] ?? '',
          r['geogram'] ?? 0,
          r['hops'] ?? 0,
          r['via'] ?? '',
          r['uptime'] ?? 0,
          r['firstSeen'] ?? 0,
          r['lastSeen'] ?? 0,
        ]);
      }
      db.execute('COMMIT');
    } catch (e) {
      try {
        db.execute('ROLLBACK');
      } catch (_) {}
      LogService.instance.add('ObservedStore: upsert failed: $e');
    } finally {
      stmt?.dispose();
    }
  }

  /// The best-known geogram peers to warm-start discovery from: those running
  /// geogram software with a usable public key, ranked by advertised uptime
  /// (stable nodes — likely indexers — first) then recency. Each row carries
  /// {id, pubkey, services, uptime, lastSeen}. Used on boot to seed the DHT
  /// routing table + relay directory and path-request/ping the steadiest peers
  /// first, instead of waiting minutes for live announces to converge.
  List<Map<String, Object?>> topGeogramPeers({int limit = 64}) {
    final db = _db;
    if (db == null) return const [];
    try {
      final rows = db.select('''
        SELECT id, pubkey, services, uptime, last_seen
        FROM nodes
        WHERE geogram=1 AND pubkey IS NOT NULL AND pubkey<>''
        ORDER BY uptime DESC, last_seen DESC
        LIMIT ?
      ''', [limit]);
      return [
        for (final r in rows)
          {
            'id': r['id'],
            'pubkey': r['pubkey'],
            'services': r['services'],
            'uptime': r['uptime'],
            'lastSeen': r['last_seen'],
          }
      ];
    } catch (e) {
      LogService.instance.add('ObservedStore: topGeogramPeers failed: $e');
      return const [];
    }
  }

  /// Summary counts over everything ever persisted: total nodes, how many are
  /// geogram software, the earliest first-seen, and recent activity.
  Map<String, dynamic> stats() {
    final db = _db;
    if (db == null) {
      return {'total': 0, 'geogram': 0, 'oldest': 0, 'seen24h': 0};
    }
    try {
      int scalar(String sql, [List<Object?> p = const []]) {
        final r = db.select(sql, p);
        final v = r.isEmpty ? 0 : r.first['v'];
        return v is int ? v : 0;
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      return {
        'total': scalar('SELECT count(*) AS v FROM nodes'),
        'geogram': scalar('SELECT count(*) AS v FROM nodes WHERE geogram=1'),
        'oldest': scalar('SELECT COALESCE(min(first_seen),0) AS v FROM nodes'),
        'seen24h': scalar(
            'SELECT count(*) AS v FROM nodes WHERE last_seen > ?',
            [now - 86400000]),
      };
    } catch (e) {
      LogService.instance.add('ObservedStore: stats failed: $e');
      return {'total': 0, 'geogram': 0, 'oldest': 0, 'seen24h': 0};
    }
  }

  void close() {
    try {
      _db?.dispose();
    } catch (_) {}
    _db = null;
  }
}
