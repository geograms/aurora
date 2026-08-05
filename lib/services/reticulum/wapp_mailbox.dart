/*
 * WappMailbox — datagrams that arrive for a wapp that isn't running.
 *
 * A wapp registers a tag when its engine loads, and inbound datagrams for that
 * tag were queued in memory against it. Anything that arrived while the wapp was
 * not loaded — which, on a phone, is most of the time and after every restart —
 * hit a null queue and was dropped on the floor, while the router still reported
 * the message as handled. Over Bluetooth that is a message somebody sent from
 * the next room, gone.
 *
 * So inbound datagrams are written here first. They survive a restart, they wake
 * the wapp that owns them (see RnsService.onWappWanted), and they are handed
 * over when it registers.
 *
 * Bounded on purpose: a device nobody opens for a month must not fill its disk
 * with mail for a wapp that may never run. The oldest entries go once the store
 * passes [kWappMailboxMaxBytes] or [kWappMailboxMaxMessages] — and the trim is
 * COUNTED and logged, because silently discarding somebody's message while
 * claiming to be a store-and-forward node is the worst failure this file has.
 */
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../log_service.dart';

/// Disk budget for everything held for not-yet-running wapps.
const int kWappMailboxMaxBytes = 100 * 1024 * 1024; // 100 MB

/// Message budget, whichever cap is hit first.
const int kWappMailboxMaxMessages = 10000;

class WappMailboxEntry {
  WappMailboxEntry({
    required this.id,
    required this.tag,
    required this.from,
    required this.payload,
    required this.ts,
  });

  final int id;
  final String tag;
  final String from;
  final Uint8List payload;
  final int ts;

  /// The shape wappDrain hands to the engine.
  Map<String, dynamic> toDrainMap() => {
        'from': from,
        'payload': base64.encode(payload),
        'ts': ts,
      };
}

class WappMailbox {
  WappMailbox._();
  static final WappMailbox instance = WappMailbox._();

  Database? _db;
  String? _path;
  int _dropped = 0;

  /// Datagrams discarded to stay inside the caps (diagnostics).
  int get droppedCount => _dropped;

  /// Open (or reopen) the store under [dir]. Safe to call repeatedly.
  void open(String dir) {
    final path = '$dir/wapp_mailbox.sqlite3';
    if (_db != null && _path == path) return;
    close();
    try {
      Directory(dir).createSync(recursive: true);
      final db = sqlite3.open(path);
      db.execute('''
        CREATE TABLE IF NOT EXISTS mail (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          tag TEXT NOT NULL,
          src TEXT NOT NULL,
          payload BLOB NOT NULL,
          ts INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS mail_tag ON mail(tag, id);
      ''');
      _db = db;
      _path = path;
    } catch (e) {
      LogService.instance.add('wapp mailbox: cannot open $path: $e');
      _db = null;
      _path = null;
    }
  }

  void close() {
    try {
      _db?.dispose();
    } catch (_) {}
    _db = null;
    _path = null;
  }

  bool get isOpen => _db != null;

  /// Store one datagram for [tag]. Returns false when there is no store to
  /// write to — the caller then knows the datagram is genuinely lost and can
  /// say so, rather than assuming it was kept.
  bool put(String tag, String from, Uint8List payload) {
    final db = _db;
    if (db == null) return false;
    try {
      final stmt = db.prepare(
          'INSERT INTO mail (tag, src, payload, ts) VALUES (?, ?, ?, ?)');
      stmt.execute([
        tag,
        from,
        payload,
        DateTime.now().millisecondsSinceEpoch,
      ]);
      stmt.dispose();
      _trim();
      return true;
    } catch (e) {
      LogService.instance.add('wapp mailbox: put failed for "$tag": $e');
      return false;
    }
  }

  /// Take everything held for [tag], oldest first, and delete it. A drain that
  /// throws keeps the rows: better redelivered than lost.
  List<WappMailboxEntry> drain(String tag, {int limit = 2000}) {
    final db = _db;
    if (db == null) return const [];
    try {
      final rows = db.select(
          'SELECT id, src, payload, ts FROM mail WHERE tag = ? '
          'ORDER BY id ASC LIMIT ?',
          [tag, limit]);
      if (rows.isEmpty) return const [];
      final out = <WappMailboxEntry>[];
      for (final r in rows) {
        out.add(WappMailboxEntry(
          id: r['id'] as int,
          tag: tag,
          from: (r['src'] as String?) ?? '',
          payload: Uint8List.fromList(r['payload'] as List<int>),
          ts: (r['ts'] as int?) ?? 0,
        ));
      }
      final ids = out.map((e) => e.id).join(',');
      db.execute('DELETE FROM mail WHERE id IN ($ids)');
      return out;
    } catch (e) {
      LogService.instance.add('wapp mailbox: drain failed for "$tag": $e');
      return const [];
    }
  }

  /// Tags with mail waiting — the set of wapps worth starting.
  List<String> pendingTags() {
    final db = _db;
    if (db == null) return const [];
    try {
      final rows = db.select('SELECT DISTINCT tag FROM mail');
      return [for (final r in rows) r['tag'] as String];
    } catch (_) {
      return const [];
    }
  }

  int count([String? tag]) {
    final db = _db;
    if (db == null) return 0;
    try {
      final rows = tag == null
          ? db.select('SELECT COUNT(*) c FROM mail')
          : db.select('SELECT COUNT(*) c FROM mail WHERE tag = ?', [tag]);
      return (rows.first['c'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  int bytes() {
    final db = _db;
    if (db == null) return 0;
    try {
      final rows = db.select('SELECT COALESCE(SUM(LENGTH(payload)),0) b FROM mail');
      return (rows.first['b'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Enforce both caps, oldest first.
  void _trim() {
    final db = _db;
    if (db == null) return;
    try {
      var removed = 0;
      final n = count();
      if (n > kWappMailboxMaxMessages) {
        final excess = n - kWappMailboxMaxMessages;
        db.execute(
            'DELETE FROM mail WHERE id IN '
            '(SELECT id FROM mail ORDER BY id ASC LIMIT $excess)');
        removed += excess;
      }
      // Bytes: delete oldest until under budget. Done in blocks so a store full
      // of small messages doesn't run one statement per row.
      var guard = 0;
      while (bytes() > kWappMailboxMaxBytes && guard++ < 64) {
        final rows = db.select('SELECT COUNT(*) c FROM mail');
        final left = (rows.first['c'] as int?) ?? 0;
        if (left == 0) break;
        final block = (left ~/ 10).clamp(1, 512);
        db.execute('DELETE FROM mail WHERE id IN '
            '(SELECT id FROM mail ORDER BY id ASC LIMIT $block)');
        removed += block;
      }
      if (removed > 0) {
        _dropped += removed;
        LogService.instance.add(
            'wapp mailbox: dropped $removed old datagram(s) to stay under '
            '${kWappMailboxMaxBytes ~/ (1024 * 1024)}MB / '
            '$kWappMailboxMaxMessages messages ($_dropped total)');
      }
    } catch (e) {
      LogService.instance.add('wapp mailbox: trim failed: $e');
    }
  }
}
