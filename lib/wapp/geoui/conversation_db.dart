/*
 * Durable conversation history — one SQLCipher database per wapp.
 *
 * History used to be a single `messages/<field>.json` rewritten in full on
 * every message. On an encrypted profile that file lives inside `profile.ear`,
 * and three things then conspired to destroy it on Android: a restore that
 * failed (locked keyring, half-written file) was indistinguishable from "no
 * history", the next message wrote the resulting EMPTY store back over the
 * real data, and a truncate-in-place write could be cut in half by the process
 * kill that Android performs on any paused app. A phone lost every message it
 * had ever received, every single restart.
 *
 * A `.sqlite3` path is passthrough for the encrypted profile store, so this
 * file stays a real file that SQLCipher encrypts with the profile key (see
 * [openProfileDb]). Writes are per-row and transactional: nothing is ever
 * rewritten wholesale, a kill mid-write cannot truncate anything, and a failure
 * to READ can no longer cause a write.
 *
 * Open failures (locked profile, wrong key, corrupt file) deliberately THROW
 * rather than returning an empty database — the caller has to be able to tell
 * "there is nothing here" from "I could not look", because only one of those
 * two is safe to write into.
 */
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/common.dart';

import '../../profile/profile_db.dart';
import 'conversation_store.dart';

/// Per-thread message cap, mirroring [ConversationStore]'s in-memory cap.
const int kConvoMaxMessages = 500;

class ConversationDb {
  ConversationDb._(this._db);

  final CommonDatabase _db;
  bool _closed = false;

  /// Open (creating if needed) the conversation database at [absPath].
  ///
  /// Throws [ProfileLockedException] when the profile is locked and
  /// [SqliteException] when the file is corrupt or the key is wrong. Both are
  /// signals the caller MUST NOT treat as "empty".
  static ConversationDb open(String absPath) {
    // A wapp that has never stored anything has no data directory yet, and
    // sqlite reports that as a bare "unable to open database file".
    final slash = absPath.lastIndexOf('/');
    if (slash > 0) {
      final dir = Directory(absPath.substring(0, slash));
      if (!dir.existsSync()) dir.createSync(recursive: true);
    }
    final db = openProfileDb(absPath);
    final out = ConversationDb._(db);
    out._migrate();
    return out;
  }

  void _migrate() {
    _db.execute('PRAGMA journal_mode = WAL;');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS threads (
        field       TEXT NOT NULL,
        id          TEXT NOT NULL,
        meta        TEXT NOT NULL,
        activity_ts INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (field, id)
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        seq      INTEGER PRIMARY KEY AUTOINCREMENT,
        field    TEXT NOT NULL,
        convo_id TEXT NOT NULL,
        mid      TEXT NOT NULL DEFAULT '',
        ckey     TEXT NOT NULL DEFAULT '',
        body     TEXT NOT NULL
      );
    ''');
    _db.execute(
        'CREATE INDEX IF NOT EXISTS msg_thread ON messages(field, convo_id, seq);');
    // A message carrying a wapp-assigned id is unique — the same message
    // arriving over two transports must not become two bubbles.
    // Older databases predate the content-signature column. CREATE TABLE IF
    // NOT EXISTS silently leaves them alone, so add it explicitly — without
    // this the index below fails and the whole history goes memory-only.
    final cols = _db
        .select('PRAGMA table_info(messages)')
        .map((r) => (r['name'] ?? '').toString())
        .toSet();
    if (!cols.contains('ckey')) {
      _db.execute("ALTER TABLE messages ADD COLUMN ckey TEXT NOT NULL DEFAULT ''");
    }
    _db.execute('CREATE UNIQUE INDEX IF NOT EXISTS msg_mid '
        "ON messages(field, convo_id, mid) WHERE mid <> '';");
    // Same for the wapp's content signature: an engine restart re-reads the
    // host's durable LXMF inbox from the start and re-emits every message it
    // finds, so the SAME message arrives again with the same `key`. One bubble.
    _db.execute('CREATE UNIQUE INDEX IF NOT EXISTS msg_key '
        "ON messages(field, convo_id, ckey) WHERE ckey <> '';");
    _db.execute('''
      CREATE TABLE IF NOT EXISTS reactions (
        field TEXT NOT NULL,
        mid   TEXT NOT NULL,
        body  TEXT NOT NULL,
        PRIMARY KEY (field, mid)
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS statuses (
        field TEXT NOT NULL,
        rid   TEXT NOT NULL,
        state TEXT NOT NULL,
        PRIMARY KEY (field, rid)
      );
    ''');
  }

  // ── writes ────────────────────────────────────────────────────────────

  void upsertThread(String field, ConversationItem it) {
    if (_closed) return;
    final meta = Map<String, dynamic>.from(it.toJson())..remove('messages');
    _db.execute(
      'INSERT INTO threads(field, id, meta, activity_ts) VALUES(?,?,?,?) '
      'ON CONFLICT(field, id) DO UPDATE SET meta=excluded.meta, '
      'activity_ts=excluded.activity_ts',
      [field, it.id, jsonEncode(meta), it.activityTs],
    );
  }

  void addMessage(String field, String convoId, Map<String, dynamic> m) {
    if (_closed) return;
    final mid = (m['mid'] ?? '').toString();
    final ckey = (m['key'] ?? '').toString();
    _db.execute(
      'INSERT OR IGNORE INTO messages(field, convo_id, mid, ckey, body) '
      'VALUES(?,?,?,?,?)',
      [field, convoId, mid, ckey, jsonEncode(m)],
    );
    // Keep the on-disk tail the same length as the in-memory one.
    _db.execute(
      'DELETE FROM messages WHERE field=? AND convo_id=? AND seq NOT IN '
      '(SELECT seq FROM messages WHERE field=? AND convo_id=? '
      ' ORDER BY seq DESC LIMIT ?)',
      [field, convoId, field, convoId, kConvoMaxMessages],
    );
  }

  /// Give a stored message the id a vote named it by. A message sent before
  /// ids were derived has none, so its row can only be found by its exact
  /// stored body — and without adopting the id the tally would be lost on the
  /// next restart.
  void setMessageMid(String field, String convoId, String oldBody,
      String newBody, String mid) {
    if (_closed) return;
    _db.execute(
      'UPDATE messages SET mid=?, body=? WHERE field=? AND convo_id=? AND body=?',
      [mid, newBody, field, convoId, oldBody],
    );
  }

  /// Rewrite one message in place — used when a reaction tally or a delivery
  /// receipt mutates a bubble that is already stored.
  void updateMessage(String field, String convoId, Map<String, dynamic> m) {
    if (_closed) return;
    final mid = (m['mid'] ?? '').toString();
    final rid = (m['rid'] ?? '').toString();
    if (mid.isNotEmpty) {
      _db.execute(
        'UPDATE messages SET body=? WHERE field=? AND convo_id=? AND mid=?',
        [jsonEncode(m), field, convoId, mid],
      );
      return;
    }
    if (rid.isEmpty) return;
    // No mid: match on the rid carried inside the body (outgoing 1:1 receipts).
    final rows = _db.select(
      'SELECT seq, body FROM messages WHERE field=? AND convo_id=? '
      'ORDER BY seq DESC LIMIT ?',
      [field, convoId, kConvoMaxMessages],
    );
    for (final r in rows) {
      final body = _decodeBody(r['body']);
      if (body != null && (body['rid'] ?? '').toString() == rid) {
        _db.execute('UPDATE messages SET body=? WHERE seq=?',
            [jsonEncode(m), r['seq']]);
        return;
      }
    }
  }

  void removeThread(String field, String id) {
    if (_closed) return;
    _db.execute('DELETE FROM threads WHERE field=? AND id=?', [field, id]);
    _db.execute('DELETE FROM messages WHERE field=? AND convo_id=?',
        [field, id]);
  }

  void setReaction(String field, String mid, Map<String, dynamic> body) {
    if (_closed) return;
    _db.execute(
      'INSERT INTO reactions(field, mid, body) VALUES(?,?,?) '
      'ON CONFLICT(field, mid) DO UPDATE SET body=excluded.body',
      [field, mid, jsonEncode(body)],
    );
  }

  void setStatus(String field, String rid, String state) {
    if (_closed) return;
    _db.execute(
      'INSERT INTO statuses(field, rid, state) VALUES(?,?,?) '
      'ON CONFLICT(field, rid) DO UPDATE SET state=excluded.state',
      [field, rid, state],
    );
  }

  /// Clear one thread's messages, or (when [id] is null) the whole field.
  void clear(String field, [String? id]) {
    if (_closed) return;
    if (id == null) {
      _db.execute('DELETE FROM threads WHERE field=?', [field]);
      _db.execute('DELETE FROM messages WHERE field=?', [field]);
      _db.execute('DELETE FROM reactions WHERE field=?', [field]);
      _db.execute('DELETE FROM statuses WHERE field=?', [field]);
      return;
    }
    _db.execute('DELETE FROM messages WHERE field=? AND convo_id=?',
        [field, id]);
  }

  // ── reads ─────────────────────────────────────────────────────────────

  /// True when this field has ANY stored row — the test that decides whether a
  /// legacy JSON file still needs importing.
  bool hasField(String field) {
    final r = _db.select(
        'SELECT 1 FROM threads WHERE field=? LIMIT 1', [field]);
    if (r.isNotEmpty) return true;
    return _db
        .select('SELECT 1 FROM messages WHERE field=? LIMIT 1', [field])
        .isNotEmpty;
  }

  /// Delete thread rows that carry no messages and have never had activity.
  ///
  /// These are ghosts: a wapp upserting a row keyed by something it can never
  /// render (a bare callsign beside the real "lxmf:<dest>" thread) left a row
  /// the user could tap that always said "No messages yet". Real conversations
  /// have either messages or an activity stamp, so this cannot take one.
  int pruneGhosts() {
    _db.execute(
      "DELETE FROM threads WHERE activity_ts = 0 AND id NOT IN "
      '(SELECT DISTINCT convo_id FROM messages)',
    );
    return _db.select('SELECT changes() AS c').first['c'] as int;
  }

  /// Every field that has stored rows — the set of conversation stores to
  /// rebuild when a page opens.
  List<String> fields() {
    final out = <String>{};
    for (final r in _db.select('SELECT DISTINCT field FROM threads')) {
      out.add((r['field'] ?? '').toString());
    }
    for (final r in _db.select('SELECT DISTINCT field FROM messages')) {
      out.add((r['field'] ?? '').toString());
    }
    out.remove('');
    return out.toList();
  }

  /// Fill [store] with everything stored for [field].
  void loadInto(String field, ConversationStore store) {
    final threads = _db.select(
      'SELECT id, meta FROM threads WHERE field=? ORDER BY activity_ts DESC',
      [field],
    );
    for (final row in threads) {
      final meta = _decodeBody(row['meta']);
      if (meta == null) continue;
      meta['messages'] = <Map<String, dynamic>>[];
      final id = (row['id'] ?? '').toString();
      if (id.isEmpty) continue;
      store.items[id] = ConversationItem.fromJson(meta);
      if (!store.order.contains(id)) store.order.add(id);
    }
    final msgs = _db.select(
      'SELECT convo_id, body FROM messages WHERE field=? ORDER BY seq',
      [field],
    );
    for (final row in msgs) {
      final id = (row['convo_id'] ?? '').toString();
      final body = _decodeBody(row['body']);
      if (id.isEmpty || body == null) continue;
      final it = store.items.putIfAbsent(id, () {
        if (!store.order.contains(id)) store.order.add(id);
        return ConversationItem(id, title: id);
      });
      it.messages.add(body);
      if (it.messages.length > kConvoMaxMessages) {
        it.messages.removeRange(0, it.messages.length - kConvoMaxMessages);
      }
    }
    for (final row
        in _db.select('SELECT mid, body FROM reactions WHERE field=?', [field])) {
      final body = _decodeBody(row['body']);
      if (body != null) store.reactions[(row['mid'] ?? '').toString()] = body;
    }
    final statuses = <String, String>{};
    for (final row
        in _db.select('SELECT rid, state FROM statuses WHERE field=?', [field])) {
      statuses[(row['rid'] ?? '').toString()] = (row['state'] ?? '').toString();
    }
    store.restoreStatuses(statuses);
  }

  /// One-time import of a store built from a legacy `messages/<field>.json`.
  void importStore(String field, ConversationStore store) {
    for (final id in store.order) {
      final it = store.items[id];
      if (it == null) continue;
      upsertThread(field, it);
      for (final m in it.messages) {
        addMessage(field, id, Map<String, dynamic>.from(m));
      }
    }
    store.reactions.forEach((mid, body) => setReaction(field, mid, body));
    store.statusesSnapshot().forEach((rid, s) => setStatus(field, rid, s));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }

  static Map<String, dynamic>? _decodeBody(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final v = jsonDecode(raw);
      return v is Map ? v.map((k, vv) => MapEntry(k.toString(), vv)) : null;
    } catch (_) {
      return null; // one unreadable row must not lose the rest of the thread
    }
  }
}
