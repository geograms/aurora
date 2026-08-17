/*
 * xprs_archive — the spool of what this station has heard.
 *
 * docs/XPRS.md section 31.3 leaves retention to the station, section 24 names
 * the role (`serve:history` "keeps a spool of what it has heard, and re-airs
 * it on cmd:history"), and until now no station kept one: the monitor's ring
 * forgets after 200 packets and a restart forgets everything. This is the
 * missing disk. Bounded — the caps are ours to pick and to change — and on by
 * default, because a spool nobody keeps is a network nobody can catch up on.
 *
 * Duplicates collapse on the derived identifier (section 25.2.1), so hearing
 * the same packet from three digipeaters costs one row. The wire is stored
 * exactly as heard — a replay re-airs original packets, unchanged — except
 * that a copy with fewer `via:` hops replaces one with more, because the
 * zero-hop copy is the closest thing to what the author transmitted.
 *
 * The hot path writes nothing: admit() appends to RAM and returns. A 20 s
 * timer flushes in one transaction, verifies signatures off the hot path,
 * and prunes in bounded batches (the ActivityArchive discipline). Nothing
 * here blocks the UI isolate for longer than one small indexed transaction.
 *
 * Also holds the `t:mailbox` declarations (section 13.12) that decide which
 * Reticulum-borne traffic may enter at all — see XprsIngest for the rule.
 */
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../../profile/profile_db.dart';
import '../log_service.dart';
import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart';

/// Packet types that are never spooled.
///
/// `ping`/`pong` — section 36.1: a stale one answers a question nobody is
/// still asking. `receipt`/`result` — control traffic whose whole value is
/// consumed the moment it is heard; store-and-forward never carries them and
/// a history page re-airing day-old receipts wastes the page. `command` IS
/// kept: section 36.1 calls a command to a sleeping station mail.
const Set<String> kXprsNeverArchived = {'ping', 'pong', 'receipt', 'result'};

class _Pending {
  _Pending(this.p, this.bearer, this.rssi, this.own, this.nowMs);
  final XprsPacket p;
  final String bearer;
  final int rssi;
  final bool own;
  final int nowMs;
}

class XprsArchive {
  XprsArchive._();
  static final XprsArchive instance = XprsArchive._();

  Database? _db;
  bool get ready => _db != null;

  /// Caps. Prefs-backed by the owner (MeshService reads them at init and on
  /// change); the defaults are a judgement, not a specification (§31.3).
  int maxBytes = 500 * 1024 * 1024;
  int maxAgeDays = 365;

  /// The signer's x-only key for a callsign, or null when not held. Injected
  /// (RnsService.pubkeyForCallsign in production) so tests need no node.
  Uint8List? Function(String baseCallsign)? keyResolver;

  /// Callsigns whose packets the byte cap never evicts — the xprs wapp's
  /// favourites can be wired in later without a schema change. Null = none.
  Set<String> Function()? protectedCallsigns;

  /// Counters for /api and for honest logs.
  int admitted = 0, dropped = 0, forged = 0;

  /// Told, at flush, what each packet's signature turned out to be — including
  /// the forged ones this drops. Set by the owner so the air view can badge a
  /// station without doing the curve work a second time.
  void Function(String callsign, XprsSigState state)? onVerdict;

  final List<_Pending> _pending = [];
  static const int _pendingMax = 512;
  static const int _flushEarlyAt = 64;
  Timer? _flushTimer;
  bool _prunedThisSession = false;
  int _flushesSinceCap = 0;

  /// Open (and migrate) the spool. Safe to call again on profile switch.
  void init(String path) {
    close();
    try {
      Directory(File(path).parent.path).createSync(recursive: true);
      final db = openProfileDb(path);
      // INCREMENTAL auto-vacuum must precede table creation, or deletes never
      // shrink the file and the byte cap caps nothing.
      db.execute('PRAGMA auto_vacuum = INCREMENTAL;');
      db.execute('PRAGMA journal_mode = WAL;');
      db.execute('PRAGMA synchronous = NORMAL;');
      db.execute('''
        CREATE TABLE IF NOT EXISTS packets(
          id     TEXT PRIMARY KEY,
          ts     INTEGER NOT NULL,
          pts    INTEGER NOT NULL,
          type   TEXT NOT NULL,
          fromc  TEXT NOT NULL,
          toc    TEXT NOT NULL DEFAULT '',
          bearer TEXT NOT NULL,
          rssi   INTEGER NOT NULL DEFAULT 0,
          mine   INTEGER NOT NULL DEFAULT 0,
          own    INTEGER NOT NULL DEFAULT 0,
          sig    INTEGER NOT NULL DEFAULT 3,
          viac   INTEGER NOT NULL DEFAULT 0,
          heard  INTEGER NOT NULL DEFAULT 1,
          last   INTEGER NOT NULL,
          wire   TEXT NOT NULL
        )''');
      db.execute('CREATE INDEX IF NOT EXISTS idx_pk_pts ON packets(pts)');
      db.execute(
          'CREATE INDEX IF NOT EXISTS idx_pk_from ON packets(fromc, pts)');
      db.execute('CREATE INDEX IF NOT EXISTS idx_pk_to ON packets(toc, pts)');
      db.execute('''
        CREATE TABLE IF NOT EXISTS mailbox_decl(
          id    TEXT PRIMARY KEY,
          fromc TEXT NOT NULL,
          pos   INTEGER NOT NULL DEFAULT 0,
          since INTEGER,
          until INTEGER,
          ts    INTEGER NOT NULL,
          wire  TEXT NOT NULL
        )''');
      db.execute(
          'CREATE INDEX IF NOT EXISTS idx_decl_from ON mailbox_decl(fromc)');
      _db = db;
      _prunedThisSession = false;
      _flushTimer?.cancel();
      _flushTimer =
          Timer.periodic(const Duration(seconds: 20), (_) => flush());
    } catch (e) {
      _db = null;
      // A broken disk degrades to no archive, never to a crash.
      LogService.instance.add('XPRS archive: open failed: $e');
    }
  }

  void close() {
    flush();
    _flushTimer?.cancel();
    _flushTimer = null;
    _db?.dispose();
    _db = null;
  }

  static String _base(String c) => c.trim().toUpperCase().split('-').first;

  /// Record a heard packet. O(1): RAM append, nothing else — this sits on the
  /// radio receive path. [own] marks our own publication at transmit time.
  void admit(
    XprsPacket p, {
    required String bearer,
    int rssi = 0,
    bool own = false,
    int? nowMs,
  }) {
    if (_db == null) return;
    if (kXprsNeverArchived.contains(p.type)) return;
    if ((p['f'] ?? '').trim().isEmpty) return;
    if (_pending.length >= _pendingMax) {
      _pending.removeAt(0);
      dropped++;
    }
    _pending.add(_Pending(
        p, bearer, rssi, own, nowMs ?? DateTime.now().millisecondsSinceEpoch));
    if (_pending.length >= _flushEarlyAt) flush();
  }

  /// Write the pending batch, verify signatures, prune. Public so tests and
  /// close() can force it; otherwise the 20 s timer calls it.
  void flush({int? nowMs}) {
    final db = _db;
    if (db == null || _pending.isEmpty) {
      if (db != null) _prune(db, nowMs: nowMs);
      return;
    }
    final batch = List.of(_pending);
    _pending.clear();
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    try {
      db.execute('BEGIN');
      final ins = db.prepare('''
        INSERT INTO packets(id,ts,pts,type,fromc,toc,bearer,rssi,mine,own,
                            sig,viac,heard,last,wire)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,1,?,?)
        ON CONFLICT(id) DO UPDATE SET
          heard = heard + 1,
          last  = excluded.last,
          rssi  = excluded.rssi,
          mine  = MAX(mine, excluded.mine),
          own   = MAX(own, excluded.own),
          wire  = CASE WHEN excluded.viac < viac
                       THEN excluded.wire ELSE wire END,
          viac  = MIN(viac, excluded.viac)''');
      try {
        for (final e in batch) {
          final p = e.p;
          // Signature state, off the hot path. A forged packet is somebody
          // else's words under a callsign, and a spool that replays it later
          // repeats the lie — dropped, same policy as the courier.
          var sig = XprsSigState.unsigned;
          if (p.has('sig')) {
            sig = xprsVerify(p, keyResolver?.call(_base(p['f'] ?? '')));
          }
          // Report before acting on it: a forged packet is dropped from the
          // spool, and if the verdict went with it nothing would ever be able
          // to say that a callsign had been used to sign something it could
          // not have signed.
          try {
            onVerdict?.call(_base(p['f'] ?? ''), sig);
          } catch (_) {
            // A view that throws must not cost the spool its flush.
          }
          if (sig == XprsSigState.forged) {
            forged++;
            continue;
          }
          final fromc = _base(p['f'] ?? '');
          final toc = _base(p['d'] ?? '');
          ins.execute([
            xprsIdentifier(p),
            e.nowMs,
            xprsParseTs(p['ts']) ?? e.nowMs,
            p.type,
            fromc,
            (p['d'] ?? '').trim().isEmpty ? '' : toc,
            e.bearer,
            e.rssi,
            (!e.own && toc.isNotEmpty && toc == _selfBase) ? 1 : 0,
            e.own ? 1 : 0,
            sig.index,
            xprsVia(p).length,
            e.nowMs,
            p.encode(),
          ]);
          admitted++;
        }
      } finally {
        ins.dispose();
      }
      db.execute('COMMIT');
    } catch (e) {
      try {
        db.execute('ROLLBACK');
      } catch (_) {}
      LogService.instance.add('XPRS archive: flush failed: $e');
    }
    _prune(db, nowMs: now);
  }

  /// Our base callsign, set by the owner at init/profile switch so `mine` can
  /// be computed at flush time without asking a service from inside sqlite.
  String selfCallsign = '';
  String get _selfBase => _base(selfCallsign);

  void _prune(Database db, {int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    // Age, once per session — a year-old packet is a year old whoever wrote
    // it, so nothing is protected from this pass. Expired declarations go in
    // the same breath.
    if (!_prunedThisSession) {
      _prunedThisSession = true;
      try {
        db.execute('DELETE FROM packets WHERE pts < ?',
            [now - maxAgeDays * 86400000]);
        db.execute(
            'DELETE FROM mailbox_decl WHERE until IS NOT NULL AND until < ?',
            [now]);
      } catch (e) {
        LogService.instance.add('XPRS archive: age prune failed: $e');
      }
    }
    // Byte cap, every 20th flush (~7 min of dense traffic). One bounded
    // batch that converges over successive flushes rather than looping.
    if (++_flushesSinceCap < 20) return;
    _flushesSinceCap = 0;
    try {
      final bytes = _dataBytes(db);
      if (bytes <= maxBytes) return;
      final prot = protectedCallsigns?.call() ?? const <String>{};
      final protSql = prot.isEmpty
          ? ''
          : ' AND fromc NOT IN (${List.filled(prot.length, '?').join(',')})';
      final protList = prot.toList();
      final rows = db
          .select('SELECT COUNT(*) c FROM packets WHERE own=0 AND mine=0'
              '$protSql', protList)
          .first['c'] as int;
      if (rows == 0) return;
      final avg = (bytes / rows).clamp(64, 1 << 20);
      var drop = ((bytes - maxBytes) / avg).ceil() + 500;
      if (drop > 20000) drop = 20000;
      db.execute(
          'DELETE FROM packets WHERE id IN '
          '(SELECT id FROM packets WHERE own=0 AND mine=0$protSql '
          'ORDER BY pts ASC LIMIT ?)',
          [...protList, drop]);
      db.execute('PRAGMA incremental_vacuum;');
    } catch (e) {
      LogService.instance.add('XPRS archive: cap prune failed: $e');
    }
  }

  int _dataBytes(Database db) {
    try {
      final pc =
          (db.select('PRAGMA page_count').first.values.first as num).toInt();
      final ps =
          (db.select('PRAGMA page_size').first.values.first as num).toInt();
      return pc * ps;
    } catch (_) {
      return 0;
    }
  }

  // ── mailbox declarations (section 13.12) ─────────────────────────────────

  /// Act on a `t:mailbox` packet. Only a VERIFIED one is acted on — §13.12:
  /// "a receiver that cannot verify one must not act on it"; forging one is
  /// how an attacker collects somebody's mail. Returns true when the
  /// declaration (or cancellation) named us and was recorded.
  bool recordMailboxDecl(XprsPacket p, {int? nowMs}) {
    final db = _db;
    if (db == null || p.type != 'mailbox') return false;
    final fromc = _base(p['f'] ?? '');
    if (fromc.isEmpty) return false;
    final state = xprsVerify(p, keyResolver?.call(fromc));
    if (state != XprsSigState.verified) return false;

    if ((p['remove'] ?? '') == 'mailbox') {
      final r = (p['r'] ?? '').trim();
      if (r.isEmpty) return false;
      db.execute(
          'DELETE FROM mailbox_decl WHERE id=? AND fromc=?', [r, fromc]);
      return true;
    }
    final hold = (p['hold'] ?? '')
        .split(',')
        .map(_base)
        .where((c) => c.isNotEmpty)
        .toList();
    final pos = hold.indexOf(_selfBase);
    if (pos < 0) return false;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    db.execute(
        'INSERT OR REPLACE INTO mailbox_decl(id,fromc,pos,since,until,ts,wire) '
        'VALUES(?,?,?,?,?,?,?)',
        [
          xprsIdentifier(p),
          fromc,
          pos,
          xprsParseTs(p['since']),
          xprsParseTs(p['until']),
          xprsParseTs(p['ts']) ?? now,
          p.encode(),
        ]);
    return true;
  }

  /// Whether [baseCallsign] currently has an active declaration naming us —
  /// the admission ticket for its Reticulum-borne traffic (§36.3).
  bool hasActiveDecl(String baseCallsign, {int? nowMs}) {
    final db = _db;
    if (db == null) return false;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return db.select(
        'SELECT 1 FROM mailbox_decl WHERE fromc=? '
        'AND (since IS NULL OR since<=?) AND (until IS NULL OR until>=?) '
        'LIMIT 1',
        [_base(baseCallsign), now, now]).isNotEmpty;
  }

  int get declCount {
    final db = _db;
    if (db == null) return 0;
    return db.select('SELECT COUNT(*) c FROM mailbox_decl').first['c'] as int;
  }

  // ── reading the spool ─────────────────────────────────────────────────────

  /// Archived packets, newest first by the packet's own timestamp — the order
  /// a `cmd:history` replay airs them in (§25.2.1). [only] matches sender or
  /// addressee. One row past [limit] is never returned; the responder asks
  /// for limit+1 itself to learn whether more exists.
  List<Map<String, dynamic>> query({
    int? sinceMs,
    int? untilMs,
    String? only,
    int limit = 200,
  }) {
    final db = _db;
    if (db == null) return const [];
    final where = StringBuffer('1=1');
    final args = <Object?>[];
    if (sinceMs != null) {
      where.write(' AND pts >= ?');
      args.add(sinceMs);
    }
    if (untilMs != null) {
      where.write(' AND pts < ?');
      args.add(untilMs);
    }
    if (only != null && only.trim().isNotEmpty) {
      final c = _base(only);
      where.write(' AND (fromc=? OR toc=?)');
      args
        ..add(c)
        ..add(c);
    }
    args.add(limit.clamp(1, 1000));
    final rows = db.select(
        'SELECT id,ts,pts,type,fromc,toc,bearer,rssi,mine,own,sig,heard,wire '
        'FROM packets WHERE $where ORDER BY pts DESC LIMIT ?',
        args);
    return [
      for (final r in rows)
        {
          'id': r['id'],
          'ts': (r['pts'] as int) ~/ 1000,
          'heardTs': (r['ts'] as int) ~/ 1000,
          'bearer': r['bearer'],
          'rssi': r['rssi'],
          'from': r['fromc'],
          'to': r['toc'],
          'type': r['type'],
          'mine': (r['mine'] as int) != 0,
          'own': (r['own'] as int) != 0,
          'sig': XprsSigState.values[(r['sig'] as int)].name,
          'heard': r['heard'],
          'wire': r['wire'],
        }
    ];
  }

  /// Counters for /api/status-style checks.
  Map<String, dynamic> statusJson() {
    final db = _db;
    final rows = db == null
        ? 0
        : db.select('SELECT COUNT(*) c FROM packets').first['c'] as int;
    return {
      'ready': ready,
      'rows': rows,
      'bytes': db == null ? 0 : _dataBytes(db),
      'declarations': declCount,
      'pending': _pending.length,
      'admitted': admitted,
      'forged': forged,
      'dropped': dropped,
    };
  }
}
