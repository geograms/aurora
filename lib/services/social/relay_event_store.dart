/*
 * RelayEventStore — a NOSTR event database with full-text search, the storage
 * core of Aurora's distributed relay/indexer (see plan: distributed NOSTR-like
 * relay over Reticulum).
 *
 * Everything in the social network is a signed NOSTR event ([NostrEvent],
 * NIP-01, BIP-340 Schnorr). This store ingests events (verifying id + signature),
 * deduplicates by id, honours NIP-01 replaceable semantics, and answers:
 *   - NIP-01 filter queries (ids / authors / kinds / #tag / since / until / limit)
 *   - NIP-50 full-text SEARCH over post content + indexed tag values (file names,
 *     topics) via SQLite FTS5 — this is the "global text search" + "file search"
 *   - derived streams: feedForFollows, firehose, recentByTopic, popular
 *   - profile / follow lookups (latest kind-0 / kind-3 per author)
 *
 * Backed by SQLite (sqlite3, same rationale + open/WAL pattern as
 * media_archive.dart). Headless-safe: takes a plain DB path (':memory:' for
 * tests) — the rns_service wiring resolves the real path via ProfileStorage.
 * No Flutter imports, so it runs under `dart run` for tool tests.
 */
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../../util/nostr_event.dart';

/// A NIP-01 subscription filter. All present conditions are AND-ed; within a
/// list condition the members are OR-ed. [tags] keys are single-letter tag
/// names ('e', 'p', 't', 'x', ...) mapped to the accepted values.
class NostrFilter {
  final List<String>? ids;
  final List<String>? authors;
  final List<int>? kinds;
  final Map<String, List<String>>? tags;
  final int? since; // unix seconds, inclusive
  final int? until; // unix seconds, inclusive
  final int? limit;
  final String? search; // NIP-50 full-text query

  const NostrFilter({
    this.ids,
    this.authors,
    this.kinds,
    this.tags,
    this.since,
    this.until,
    this.limit,
    this.search,
  });

  Map<String, dynamic> toJson() => {
        if (ids != null) 'ids': ids,
        if (authors != null) 'authors': authors,
        if (kinds != null) 'kinds': kinds,
        if (tags != null)
          for (final e in tags!.entries) '#${e.key}': e.value,
        if (since != null) 'since': since,
        if (until != null) 'until': until,
        if (limit != null) 'limit': limit,
        if (search != null) 'search': search,
      };

  /// Parse a NIP-01 filter object (as sent over the wire). Tag conditions are
  /// the keys beginning with '#'.
  factory NostrFilter.fromJson(Map<String, dynamic> j) {
    Map<String, List<String>>? tags;
    for (final entry in j.entries) {
      if (entry.key.startsWith('#') && entry.key.length >= 2) {
        (tags ??= {})[entry.key.substring(1)] =
            (entry.value as List).map((e) => e.toString()).toList();
      }
    }
    List<T>? lst<T>(String k) =>
        j[k] == null ? null : (j[k] as List).cast<T>();
    return NostrFilter(
      ids: lst<String>('ids'),
      authors: lst<String>('authors'),
      kinds: lst<int>('kinds'),
      tags: tags,
      since: j['since'] as int?,
      until: j['until'] as int?,
      limit: j['limit'] as int?,
      search: j['search'] as String?,
    );
  }
}

class RelayEventStore {
  RelayEventStore._(this._db);

  final Database _db;

  /// Open (or create) a relay event store at [path]. Use ':memory:' for tests.
  /// Throws if SQLite cannot be opened — callers running on web should not call
  /// this (sqlite3 needs dart:ffi).
  factory RelayEventStore.open(String path) {
    if (path != ':memory:') {
      final parent = File(path).parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
    }
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA synchronous = NORMAL;');
    db.execute('PRAGMA foreign_keys = ON;');
    _migrate(db);
    return RelayEventStore._(db);
  }

  static void _migrate(Database db) {
    // Canonical events. `raw` holds the verbatim NIP-01 JSON so we can return
    // byte-faithful events; the columns are the query surface.
    db.execute('''
      CREATE TABLE IF NOT EXISTS events(
        id          TEXT PRIMARY KEY,
        pubkey      TEXT NOT NULL,
        created_at  INTEGER NOT NULL,
        kind        INTEGER NOT NULL,
        content     TEXT NOT NULL,
        raw         TEXT NOT NULL,
        deleted     INTEGER NOT NULL DEFAULT 0
      );
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_ev_author ON events(pubkey);');
    db.execute('CREATE INDEX IF NOT EXISTS idx_ev_kind ON events(kind);');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_ev_kind_ts ON events(kind, created_at);');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_ev_author_kind ON events(pubkey, kind);');

    // One row per (event, tag-name, value) for #tag filters and reaction joins.
    db.execute('''
      CREATE TABLE IF NOT EXISTS tags(
        event_id TEXT NOT NULL,
        name     TEXT NOT NULL,
        value    TEXT NOT NULL,
        FOREIGN KEY(event_id) REFERENCES events(id) ON DELETE CASCADE
      );
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_tag_nv ON tags(name, value);');
    db.execute('CREATE INDEX IF NOT EXISTS idx_tag_ev ON tags(event_id);');

    // Full-text index: post content + a `meta` column holding searchable tag
    // values (file names, topics, etc.). event_id is carried UNINDEXED so we can
    // map matches back and delete on replace.
    db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
        content, meta, event_id UNINDEXED, tokenize = 'unicode61'
      );
    ''');

    // Store-and-forward propagation mailbox (used by store_forward.dart, slice
    // 4). Created here so the relay DB has one schema. dest is the recipient's
    // LXMF delivery dest hash (hex); blob is the packed LXMF message.
    db.execute('''
      CREATE TABLE IF NOT EXISTS sf_inbox(
        msg_id      TEXT PRIMARY KEY,
        dest        TEXT NOT NULL,
        blob        BLOB NOT NULL,
        received_at INTEGER NOT NULL,
        expires_at  INTEGER NOT NULL
      );
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_sf_dest ON sf_inbox(dest);');
    db.execute('CREATE INDEX IF NOT EXISTS idx_sf_exp ON sf_inbox(expires_at);');

    // Store-and-forward hosting columns (added later; ALTER on existing DBs).
    // received_at = when WE accepted the event (drives retention + monthly caps,
    // distinct from the author's created_at). tier = 0 self / 1 followed /
    // 2 stranger, for tier-aware quota + eviction.
    final cols = {
      for (final r in db.select('PRAGMA table_info(events)'))
        r['name'] as String
    };
    if (!cols.contains('received_at')) {
      db.execute('ALTER TABLE events ADD COLUMN received_at INTEGER NOT NULL DEFAULT 0;');
    }
    if (!cols.contains('tier')) {
      db.execute('ALTER TABLE events ADD COLUMN tier INTEGER NOT NULL DEFAULT 2;');
    }
    db.execute('CREATE INDEX IF NOT EXISTS idx_ev_tier ON events(tier, received_at);');
  }

  // ── Ingest ────────────────────────────────────────────────────────────────

  /// Ingest a NOSTR event. Verifies the event id and Schnorr signature, dedups
  /// by id, and applies NIP-01 replaceable/deletion semantics.
  /// Returns true if the event was stored (new or replacing an older one),
  /// false if rejected (bad sig) or superseded/duplicate. [tier] (0 self /
  /// 1 followed / 2 stranger) and [receivedAtMs] are recorded for the hosting
  /// quota/eviction; they default to stranger / now when not supplied (e.g. our
  /// own local publishes pass tier 0).
  bool put(NostrEvent e, {int tier = 2, int? receivedAtMs}) {
    _pendingTier = tier;
    _pendingReceivedSec =
        (receivedAtMs ?? DateTime.now().millisecondsSinceEpoch) ~/ 1000;
    final id = e.id;
    final sig = e.sig;
    if (id == null || sig == null || id.isEmpty || sig.isEmpty) return false;
    if (!e.verify()) return false; // recomputes id + checks Schnorr

    // Duplicate?
    final dup = _db.select('SELECT 1 FROM events WHERE id = ? LIMIT 1', [id]);
    if (dup.isNotEmpty) {
      // A deletion (kind 5) may still need to act even on a re-seen event.
      if (e.kind == NostrEventKind.deletion) _applyDeletion(e);
      return false;
    }

    // Replaceable handling: keep only the newest per replacement key.
    final repl = _replacementKey(e);
    if (repl != null) {
      final existing = _db.select(
        'SELECT id, created_at FROM events WHERE pubkey = ? AND kind = ? '
        '${repl.dTag != null ? "AND id IN (SELECT event_id FROM tags WHERE name='d' AND value = ?) " : ""}'
        'ORDER BY created_at DESC LIMIT 1',
        [
          e.pubkey,
          e.kind,
          if (repl.dTag != null) repl.dTag!,
        ],
      );
      if (existing.isNotEmpty) {
        final prevTs = existing.first['created_at'] as int;
        // NIP-01: keep the newest; ties broken by lexically-lower id.
        if (e.createdAt < prevTs ||
            (e.createdAt == prevTs &&
                id.compareTo(existing.first['id'] as String) >= 0)) {
          return false; // incoming is older or not preferred — drop it
        }
        _deleteById(existing.first['id'] as String);
      }
    }

    _insert(e);
    if (e.kind == NostrEventKind.deletion) _applyDeletion(e);
    return true;
  }

  // Hosting metadata for the next _insert (set by put()).
  int _pendingTier = 2;
  int _pendingReceivedSec = 0;

  void _insert(NostrEvent e) {
    _db.execute('BEGIN');
    try {
      _db.execute(
        'INSERT INTO events(id, pubkey, created_at, kind, content, raw, received_at, tier) '
        'VALUES(?,?,?,?,?,?,?,?)',
        [e.id, e.pubkey, e.createdAt, e.kind, e.content, jsonEncode(e.toJson()),
         _pendingReceivedSec, _pendingTier],
      );
      final metaParts = <String>[];
      for (final t in e.tags) {
        if (t.length < 2) continue;
        _db.execute('INSERT INTO tags(event_id, name, value) VALUES(?,?,?)',
            [e.id, t[0], t[1]]);
        // Make tag values (file names, topics, mime, etc.) full-text searchable.
        for (final v in t.skip(1)) {
          if (v.isNotEmpty) metaParts.add(v);
        }
      }
      _db.execute(
        'INSERT INTO events_fts(content, meta, event_id) VALUES(?,?,?)',
        [e.content, metaParts.join(' '), e.id],
      );
      _db.execute('COMMIT');
    } catch (err) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _deleteById(String id) {
    // tags cascade via FK; events_fts is contentless-external so delete by hand.
    _db.execute('DELETE FROM events_fts WHERE event_id = ?', [id]);
    _db.execute('DELETE FROM events WHERE id = ?', [id]);
  }

  /// NIP-09: a kind-5 event deletes the events it references (#e) that belong to
  /// the same author. We tombstone rather than hard-delete so a replay of the
  /// deleted event won't resurrect it.
  void _applyDeletion(NostrEvent del) {
    for (final t in del.tags) {
      if (t.length >= 2 && t[0] == 'e') {
        _db.execute(
          'UPDATE events SET deleted = 1 WHERE id = ? AND pubkey = ?',
          [t[1], del.pubkey],
        );
        _db.execute('DELETE FROM events_fts WHERE event_id = ?', [t[1]]);
      }
    }
  }

  _ReplKey? _replacementKey(NostrEvent e) {
    final k = e.kind;
    final replaceable =
        k == NostrEventKind.setMetadata || // 0
            k == NostrEventKind.contacts || // 3
            (k >= 10000 && k < 20000); // NIP-01 replaceable range
    final paramReplaceable = k >= 30000 && k < 40000; // NIP-33
    if (replaceable) return const _ReplKey(null);
    if (paramReplaceable) {
      String d = '';
      for (final t in e.tags) {
        if (t.length >= 2 && t[0] == 'd') {
          d = t[1];
          break;
        }
      }
      return _ReplKey(d);
    }
    return null;
  }

  // ── Queries ─────────────────────────────────────────────────────────────

  /// Run a NIP-01 filter. If [filter.search] is set, FTS-rank within the filter.
  List<NostrEvent> query(NostrFilter filter) {
    if (filter.search != null && filter.search!.trim().isNotEmpty) {
      return _search(filter);
    }
    final where = <String>['e.deleted = 0'];
    final params = <Object?>[];
    _applyFilter(filter, where, params);
    final limit = filter.limit ?? 500;
    final sql = 'SELECT e.raw FROM events e'
        '${_tagJoin(filter)} '
        'WHERE ${where.join(' AND ')} '
        'ORDER BY e.created_at DESC, e.id ASC LIMIT ?';
    params.add(limit);
    return _rows(_db.select(sql, params));
  }

  /// NIP-50 full-text search joined with the rest of the filter.
  List<NostrEvent> _search(NostrFilter filter) {
    final where = <String>['e.deleted = 0', 'events_fts MATCH ?'];
    final params = <Object?>[_ftsQuery(filter.search!)];
    _applyFilter(filter, where, params);
    final limit = filter.limit ?? 200;
    // bm25() rank ascending = best first; tie-break by recency.
    final sql = 'SELECT e.raw FROM events_fts '
        'JOIN events e ON e.id = events_fts.event_id'
        '${_tagJoin(filter)} '
        'WHERE ${where.join(' AND ')} '
        'ORDER BY bm25(events_fts), e.created_at DESC LIMIT ?';
    params.add(limit);
    return _rows(_db.select(sql, params));
  }

  /// Public NIP-50 search helper.
  List<NostrEvent> search(String text,
          {List<int>? kinds, int limit = 50}) =>
      query(NostrFilter(search: text, kinds: kinds, limit: limit));

  void _applyFilter(
      NostrFilter f, List<String> where, List<Object?> params) {
    if (f.ids != null && f.ids!.isNotEmpty) {
      where.add('e.id IN (${_marks(f.ids!.length)})');
      params.addAll(f.ids!);
    }
    if (f.authors != null && f.authors!.isNotEmpty) {
      where.add('e.pubkey IN (${_marks(f.authors!.length)})');
      params.addAll(f.authors!);
    }
    if (f.kinds != null && f.kinds!.isNotEmpty) {
      where.add('e.kind IN (${_marks(f.kinds!.length)})');
      params.addAll(f.kinds!);
    }
    if (f.since != null) {
      where.add('e.created_at >= ?');
      params.add(f.since);
    }
    if (f.until != null) {
      where.add('e.created_at <= ?');
      params.add(f.until);
    }
    // Tag conditions: one EXISTS per tag-name, value OR-ed within.
    if (f.tags != null) {
      for (final entry in f.tags!.entries) {
        if (entry.value.isEmpty) continue;
        where.add('EXISTS (SELECT 1 FROM tags t WHERE t.event_id = e.id '
            'AND t.name = ? AND t.value IN (${_marks(entry.value.length)}))');
        params.add(entry.key);
        params.addAll(entry.value);
      }
    }
  }

  // Tag join is expressed via EXISTS subqueries in _applyFilter; no extra JOIN
  // needed, kept as a hook for future query-plan tuning.
  String _tagJoin(NostrFilter f) => '';

  // ── Derived streams ───────────────────────────────────────────────────────

  /// Posts (kind 1 by default) authored by anyone in [follows], newest first.
  List<NostrEvent> feedForFollows(List<String> follows,
      {List<int> kinds = const [NostrEventKind.textNote],
      int? since,
      int limit = 100}) {
    if (follows.isEmpty) return const [];
    return query(NostrFilter(
        authors: follows, kinds: kinds, since: since, limit: limit));
  }

  /// Everything (default kind-1 posts), newest first — the firehose.
  List<NostrEvent> firehose(
          {List<int> kinds = const [NostrEventKind.textNote],
          int limit = 100}) =>
      query(NostrFilter(kinds: kinds, limit: limit));

  /// Most recent posts carrying topic tag `t == topic`, newest first.
  List<NostrEvent> recentByTopic(String topic,
          {List<int> kinds = const [NostrEventKind.textNote],
          int limit = 100}) =>
      query(NostrFilter(
          kinds: kinds,
          tags: {
            't': [topic]
          },
          limit: limit));

  /// Popular posts: kind-1 events ranked by how many reactions (kind 7) and
  /// reposts (kind 6) reference them via an #e tag, within [window].
  List<PopularPost> popular(
      {Duration window = const Duration(days: 2), int limit = 20}) {
    final cutoff =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000) - window.inSeconds;
    final rows = _db.select('''
      SELECT e.raw AS raw, COUNT(*) AS score
      FROM tags t
      JOIN events r ON r.id = t.event_id
                   AND r.kind IN (${NostrEventKind.reaction}, ${NostrEventKind.repost})
                   AND r.deleted = 0 AND r.created_at >= ?
      JOIN events e ON e.id = t.value
                   AND e.kind = ${NostrEventKind.textNote} AND e.deleted = 0
      WHERE t.name = 'e'
      GROUP BY t.value
      ORDER BY score DESC, e.created_at DESC
      LIMIT ?
    ''', [cutoff, limit]);
    return [
      for (final r in rows)
        PopularPost(_fromRaw(r['raw'] as String)!, r['score'] as int)
    ];
  }

  // ── Profile / follows lookups ───────────────────────────────────────────

  /// Latest kind-0 profile/metadata event for [pubkey], or null.
  NostrEvent? profileOf(String pubkey) {
    final r = _db.select(
      'SELECT raw FROM events WHERE pubkey = ? AND kind = 0 AND deleted = 0 '
      'ORDER BY created_at DESC LIMIT 1',
      [pubkey],
    );
    return r.isEmpty ? null : _fromRaw(r.first['raw'] as String);
  }

  /// The pubkeys [pubkey] follows, from their latest kind-3 contacts event.
  List<String> followsOf(String pubkey) {
    final r = _db.select(
      'SELECT id FROM events WHERE pubkey = ? AND kind = 3 AND deleted = 0 '
      'ORDER BY created_at DESC LIMIT 1',
      [pubkey],
    );
    if (r.isEmpty) return const [];
    final p = _db.select(
        "SELECT value FROM tags WHERE event_id = ? AND name = 'p'",
        [r.first['id']]);
    return [for (final row in p) row['value'] as String];
  }

  // ── Stats / maintenance ─────────────────────────────────────────────────

  int count([NostrFilter? filter]) {
    if (filter == null) {
      final r = _db.select('SELECT COUNT(*) c FROM events WHERE deleted = 0');
      return r.first['c'] as int;
    }
    final where = <String>['e.deleted = 0'];
    final params = <Object?>[];
    _applyFilter(filter, where, params);
    final r = _db.select(
        'SELECT COUNT(*) c FROM events e WHERE ${where.join(' AND ')}', params);
    return r.first['c'] as int;
  }

  /// Delete events older than [maxAge] (keeps profiles/contacts which are small
  /// and replaceable). Returns the number removed.
  int prune({Duration maxAge = const Duration(days: 90)}) {
    final cutoff =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000) - maxAge.inSeconds;
    final old = _db.select(
      'SELECT id FROM events WHERE created_at < ? AND kind NOT IN (0,3)',
      [cutoff],
    );
    for (final r in old) {
      _deleteById(r['id'] as String);
    }
    return old.length;
  }

  // ── Store-and-forward hosting: tier usage + tier-aware retention ───────────

  /// Current hosting usage for the quota policy: count of stranger NOTES (kind 1)
  /// received in the current calendar month, total bytes (raw size) of stranger
  /// content, and total bytes of all hosted content. Bytes approximate by the
  /// stored raw JSON length (text is small; media bytes live in the archive).
  ({int strangerNotesThisMonth, int strangerBytes, int totalBytes}) hostUsage(
      {int? nowMs}) {
    final now =
        DateTime.fromMillisecondsSinceEpoch(nowMs ?? DateTime.now().millisecondsSinceEpoch);
    final monthStart =
        DateTime(now.year, now.month).millisecondsSinceEpoch ~/ 1000;
    final n = _db.select(
      'SELECT COUNT(*) c FROM events WHERE deleted=0 AND tier=2 AND kind=1 '
      'AND received_at >= ?',
      [monthStart],
    ).first['c'] as int;
    final sb = _db.select(
      'SELECT COALESCE(SUM(LENGTH(raw)),0) b FROM events WHERE deleted=0 AND tier=2',
    ).first['b'] as int;
    final tb = _db.select(
      'SELECT COALESCE(SUM(LENGTH(raw)),0) b FROM events WHERE deleted=0',
    ).first['b'] as int;
    return (strangerNotesThisMonth: n, strangerBytes: sb, totalBytes: tb);
  }

  /// Tier-aware retention sweep for hosted text events: delete stranger events
  /// (tier 2) whose received_at is older than [strangerMaxAge]. Never deletes our
  /// own (tier 0) or followed (tier 1) text, and always keeps profiles/contacts.
  /// Returns the number removed. (Storage-pressure eviction of media is handled
  /// in the archive; text is tiny so age-based pruning suffices here.)
  int pruneHosted({required Duration strangerMaxAge, int? nowMs}) {
    final cutoff =
        ((nowMs ?? DateTime.now().millisecondsSinceEpoch) ~/ 1000) -
            strangerMaxAge.inSeconds;
    final old = _db.select(
      'SELECT id FROM events WHERE tier=2 AND received_at < ? AND kind NOT IN (0,3)',
      [cutoff],
    );
    for (final r in old) {
      _deleteById(r['id'] as String);
    }
    return old.length;
  }

  // ── Store-and-forward mailbox (LXMF propagation) ──────────────────────────

  /// Queue a packed message [blob] for offline recipient [dest] (its LXMF
  /// delivery dest hash, hex). Dedups on [msgId]. Default TTL 30 days. Returns
  /// true if newly stored.
  bool sfDeposit({
    required String msgId,
    required String dest,
    required Uint8List blob,
    Duration ttl = const Duration(days: 30),
    int? nowMs,
  }) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final exists =
        _db.select('SELECT 1 FROM sf_inbox WHERE msg_id = ? LIMIT 1', [msgId]);
    if (exists.isNotEmpty) return false;
    _db.execute(
      'INSERT INTO sf_inbox(msg_id, dest, blob, received_at, expires_at) '
      'VALUES(?,?,?,?,?)',
      [msgId, dest, blob, now, now + ttl.inMilliseconds],
    );
    return true;
  }

  /// Undelivered, unexpired messages queued for [dest], oldest first.
  List<SfItem> sfPending(String dest, {int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final rows = _db.select(
      'SELECT msg_id, blob FROM sf_inbox WHERE dest = ? AND expires_at > ? '
      'ORDER BY received_at ASC',
      [dest, now],
    );
    return [
      for (final r in rows)
        SfItem(r['msg_id'] as String, r['blob'] as Uint8List)
    ];
  }

  void sfDelete(String msgId) =>
      _db.execute('DELETE FROM sf_inbox WHERE msg_id = ?', [msgId]);

  int sfCount([String? dest]) {
    final r = dest == null
        ? _db.select('SELECT COUNT(*) c FROM sf_inbox')
        : _db.select('SELECT COUNT(*) c FROM sf_inbox WHERE dest = ?', [dest]);
    return r.first['c'] as int;
  }

  /// Drop expired mailbox entries; returns how many were removed.
  int sfPrune({int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final old =
        _db.select('SELECT COUNT(*) c FROM sf_inbox WHERE expires_at <= ?', [now]);
    _db.execute('DELETE FROM sf_inbox WHERE expires_at <= ?', [now]);
    return old.first['c'] as int;
  }

  /// Distinct recipient dests that currently have queued mail (for flush-on-
  /// announce decisions).
  Set<String> sfDests({int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final rows =
        _db.select('SELECT DISTINCT dest FROM sf_inbox WHERE expires_at > ?', [now]);
    return {for (final r in rows) r['dest'] as String};
  }

  void close() => _db.dispose();

  // ── helpers ───────────────────────────────────────────────────────────────

  List<NostrEvent> _rows(ResultSet rs) =>
      [for (final r in rs) _fromRaw(r['raw'] as String)!];

  NostrEvent? _fromRaw(String raw) {
    try {
      return NostrEvent.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static String _marks(int n) => List.filled(n, '?').join(',');

  /// Turn free user text into a safe FTS5 MATCH expression: split on
  /// non-word characters, quote each term, AND them with a prefix wildcard on
  /// the last term for as-you-type feel. Avoids FTS5 syntax injection.
  static String _ftsQuery(String text) {
    final terms = text
        .toLowerCase()
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((t) => t.isNotEmpty)
        .toList();
    if (terms.isEmpty) return '""';
    final quoted = [for (final t in terms) '"${t.replaceAll('"', '')}"'];
    quoted[quoted.length - 1] = '${quoted.last}*';
    return quoted.join(' ');
  }
}

class _ReplKey {
  final String? dTag; // null = plain replaceable; non-null = NIP-33 'd' value
  const _ReplKey(this.dTag);
}

class PopularPost {
  final NostrEvent event;
  final int score; // number of reactions + reposts in the window
  const PopularPost(this.event, this.score);
}

/// One queued store-and-forward message.
class SfItem {
  final String msgId;
  final Uint8List blob;
  const SfItem(this.msgId, this.blob);
}

/// File-metadata kind (NIP-94-style): a published, searchable record of a file
/// addressed by sha256, so "file search" is just an event search. Tags:
///   ['x', <sha256-hex>], ['m', <mime>], ['size', <bytes>], ['name', <filename>],
///   ['t', <topic>]...  ; content = free-text description.
const int kKindFileMetadata = 1063;
