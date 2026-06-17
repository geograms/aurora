// Content-addressed local media archive (APRX.md §16.5).
//
// Stores the raw bytes of files referenced by `file:<sha256>.<ext>` tokens
// (see media_ref.dart), keyed by the unpadded-base64url SHA-256 of the bytes
// — so identical content is stored exactly once no matter how many messages
// or wapps reference it. Alongside the data each entry keeps room for the
// metadata the archive is expected to grow into: when the entry was first and
// last accessed, the original file name, free-form tags, a TLSH fuzzy hash
// (reserved — no Dart implementation exists yet), the SHA-1, a reusable
// preview screenshot, and a description.
//
// Backed by SQLite (same rationale as geo_chat_archive.dart): WAL-journalled
// atomic writes, a crash can't shred the file, one corrupt row never costs
// the archive. The screenshot and metadata live in their own columns so list
// views / previews never have to read the (potentially large) data blob.
//
// How media bytes travel between stations is OUT OF SCOPE here — the archive
// only answers "do I have the bytes for this hash" locally.
//
// Native only — SQLite needs dart:ffi. Every call is a no-op on web (kIsWeb).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:sqlite3/sqlite3.dart';

import '../profile/profile_storage.dart';
import 'media_ref.dart';

/// Non-blob metadata of one archive entry (cheap to query for list views).
class MediaMeta {
  final String sha256;       // unpadded base64url, 43 chars
  final String? sha1;        // unpadded base64url, 27 chars
  final String? tlsh;        // reserved: fuzzy hash, null until implemented
  final String? name;        // original file name, when known
  final String ext;          // lowercase extension (no dot)
  final String? description;
  final List<String> tags;
  final int firstSeenMs;     // epoch ms of first insertion
  final int lastSeenMs;      // epoch ms of last access
  final int size;            // byte length of the data blob
  final bool hasScreenshot;
  final String? folder;      // virtual folder name (categorization)
  final String? parent;      // virtual parent-folder name
  final int downloads;       // times served to others (metric)
  final bool pinned;         // locally added/authored — never auto-evicted

  const MediaMeta({
    required this.sha256,
    required this.ext,
    required this.firstSeenMs,
    required this.lastSeenMs,
    required this.size,
    required this.hasScreenshot,
    this.sha1,
    this.tlsh,
    this.name,
    this.description,
    this.tags = const [],
    this.folder,
    this.parent,
    this.downloads = 0,
    this.pinned = true,
  });

  Map<String, dynamic> toJson() => {
        'sha256': sha256,
        if (sha1 != null) 'sha1': sha1,
        if (name != null) 'name': name,
        'ext': ext,
        if (description != null) 'description': description,
        'tags': tags,
        'firstSeen': firstSeenMs,
        'lastSeen': lastSeenMs,
        'size': size,
        'hasScreenshot': hasScreenshot,
        if (folder != null) 'folder': folder,
        if (parent != null) 'parent': parent,
        'downloads': downloads,
        'pinned': pinned,
      };
}

class MediaArchiveStats {
  final int count;
  final int totalBytes;
  final int screenshotCount;
  const MediaArchiveStats(this.count, this.totalBytes, this.screenshotCount);
}

/// One node in the virtual-folder tree (a distinct parent/folder grouping).
class MediaFolder {
  final String parent; // '' = top level
  final String folder; // '' = uncategorized within the parent
  final int count;
  const MediaFolder(this.parent, this.folder, this.count);

  Map<String, dynamic> toJson() =>
      {'parent': parent, 'folder': folder, 'count': count};
}

class MediaArchive {
  MediaArchive._(this._dbPath);

  /// One archive per data root. Pass the SHARED wapp-data root (the parent of
  /// the per-wapp dirs, e.g. `wappsDataStorage(prefs)`) so every wapp on the
  /// profile sees the same content-addressed store.
  static final Map<String, MediaArchive> _instances = {};
  static MediaArchive forStorage(ProfileStorage dataDir) =>
      _instances.putIfAbsent(dataDir.basePath,
          () => MediaArchive._(dataDir.getAbsolutePath(_fileName)));

  static const String _fileName = 'media.sqlite3';

  final String _dbPath;
  Database? _db;
  bool _failed = false; // a fatal open error → operate degraded, never wipe

  // ── DB lifecycle ────────────────────────────────────────────────────────

  Database? _ensureDb() {
    if (kIsWeb || _failed) return null;
    final existing = _db;
    if (existing != null) return existing;
    try {
      final parent = File(_dbPath).parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      final db = sqlite3.open(_dbPath);
      db.execute('PRAGMA journal_mode = WAL;');
      db.execute('PRAGMA synchronous = NORMAL;');
      db.execute('''
        CREATE TABLE IF NOT EXISTS media(
          sha256      TEXT PRIMARY KEY,
          sha1        TEXT,
          tlsh        TEXT,
          name        TEXT,
          ext         TEXT NOT NULL,
          description TEXT,
          tags        TEXT,
          first_seen  INTEGER NOT NULL,
          last_seen   INTEGER NOT NULL,
          size        INTEGER NOT NULL,
          screenshot  BLOB,
          data        BLOB NOT NULL
        );
      ''');
      db.execute('CREATE INDEX IF NOT EXISTS idx_media_ext ON media(ext);');
      db.execute(
          'CREATE INDEX IF NOT EXISTS idx_media_last ON media(last_seen);');
      // Where a hash can be obtained from (APRX §16 / Files wapp): announced
      // torrent infohashes, Blossom server base URLs, callsigns claiming the
      // file. Kept even for hashes we don't hold, so we can answer/relay.
      db.execute('''
        CREATE TABLE IF NOT EXISTS sources(
          sha256    TEXT NOT NULL,
          kind      TEXT NOT NULL,
          value     TEXT NOT NULL,
          last_seen INTEGER NOT NULL,
          PRIMARY KEY (sha256, kind, value)
        );
      ''');
      // Additive migrations (idempotent: ALTER throws if the column exists, so
      // each is wrapped). folder/parent drive virtual-folder navigation;
      // downloads is the times-served-to-others metric; pinned protects locally
      // added content from the storage-budget evictor (pass 2).
      for (final col in const [
        'folder TEXT',
        'parent TEXT',
        'downloads INTEGER NOT NULL DEFAULT 0',
        'pinned INTEGER NOT NULL DEFAULT 1',
      ]) {
        try {
          db.execute('ALTER TABLE media ADD COLUMN $col;');
        } catch (_) {/* column already present */}
      }
      db.execute(
          'CREATE INDEX IF NOT EXISTS idx_media_folder ON media(parent, folder);');
      // Full-text index for local search (works even when the RNS node is off).
      db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS media_fts USING fts5(
          name, description, tags, folder, parent, sha256 UNINDEXED,
          tokenize = 'unicode61'
        );
      ''');
      // Backfill the FTS index if it was just created on an existing archive.
      final ftsN =
          (db.select('SELECT COUNT(*) c FROM media_fts').first['c'] as int);
      final medN = (db.select('SELECT COUNT(*) c FROM media').first['c'] as int);
      if (ftsN == 0 && medN > 0) {
        for (final r in db.select('SELECT sha256 FROM media')) {
          _syncFts(db, r['sha256'] as String);
        }
      }
      _db = db;
      return db;
    } catch (e) {
      _failed = true;
      debugPrint('MediaArchive: open failed for $_dbPath: $e');
      return null;
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  static String _b64u(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  /// Accept a full `file:<hash>.<ext>` token, a bare 43-char base64url hash,
  /// or a 64-char hex digest (the Blossom/NOSTR form).
  static String? _keyOf(String tokenOrSha256) {
    final ref = MediaRef.parse(tokenOrSha256);
    if (ref != null) return ref.sha256;
    if (RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(tokenOrSha256)) {
      return tokenOrSha256;
    }
    if (tokenOrSha256.length == 64) {
      return MediaRef.hexToB64u(tokenOrSha256);
    }
    return null;
  }

  static String _normExt(String ext) {
    var e = ext.toLowerCase();
    if (e.startsWith('.')) e = e.substring(1);
    if (!RegExp(r'^[a-z0-9]{1,18}$').hasMatch(e)) {
      throw ArgumentError('invalid media extension: $ext');
    }
    return e;
  }

  /// Max chars for a file description (host-enforced).
  static const int kMaxDescription = 250;
  static String? _clampDesc(String? d) =>
      d == null ? null : (d.length > kMaxDescription ? d.substring(0, kMaxDescription) : d);

  /// Rebuild the FTS row for [key] from the current media row.
  void _syncFts(Database db, String key) {
    try {
      db.execute('DELETE FROM media_fts WHERE sha256=?', [key]);
      final rows = db.select(
          'SELECT name,description,tags,folder,parent FROM media WHERE sha256=?',
          [key]);
      if (rows.isEmpty) return;
      final r = rows.first;
      var tagsText = '';
      final rawTags = r['tags'];
      if (rawTags is String && rawTags.isNotEmpty) {
        try {
          tagsText = (jsonDecode(rawTags) as List).join(' ');
        } catch (_) {}
      }
      db.execute(
        'INSERT INTO media_fts(name,description,tags,folder,parent,sha256) '
        'VALUES(?,?,?,?,?,?)',
        [
          r['name'] ?? '',
          r['description'] ?? '',
          tagsText,
          r['folder'] ?? '',
          r['parent'] ?? '',
          key,
        ],
      );
    } catch (e) {
      debugPrint('MediaArchive: fts sync failed: $e');
    }
  }

  /// Turn free text into a safe FTS5 MATCH expression (prefix on the last term).
  static String? _ftsMatch(String text) {
    final terms = text
        .toLowerCase()
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((t) => t.isNotEmpty)
        .toList();
    if (terms.isEmpty) return null;
    final quoted = [for (final t in terms) '"${t.replaceAll('"', '')}"'];
    quoted[quoted.length - 1] = '${quoted.last}*';
    return quoted.join(' ');
  }

  // ── API ─────────────────────────────────────────────────────────────────

  /// Store [data]; returns the wire token `file:<sha256>.<ext>`. Identical
  /// content dedups onto the existing row (its last-accessed time is bumped;
  /// name/description/tags fill in only if they were empty).
  String putBytes(Uint8List data, String ext,
      {String? name, String? description, List<String>? tags}) {
    final e = _normExt(ext);
    final key = _b64u(crypto.sha256.convert(data).bytes);
    final token = 'file:$key.$e';
    final db = _ensureDb();
    if (db == null) return token;
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      final sha1b64 = _b64u(crypto.sha1.convert(data).bytes);
      db.execute(
        'INSERT OR IGNORE INTO media'
        '(sha256,sha1,tlsh,name,ext,description,tags,'
        ' first_seen,last_seen,size,screenshot,data) '
        'VALUES(?,?,NULL,?,?,?,?,?,?,?,NULL,?)',
        // TODO(tlsh): compute when a Dart TLSH implementation is available.
        [
          key,
          sha1b64,
          name,
          e,
          _clampDesc(description),
          tags == null ? null : jsonEncode(tags),
          now,
          now,
          data.length,
          data,
        ],
      );
      if (db.updatedRows == 0) {
        // Already archived: bump last_seen, backfill empty metadata.
        db.execute(
          'UPDATE media SET last_seen=?, '
          'name=COALESCE(name,?), description=COALESCE(description,?), '
          'tags=COALESCE(tags,?) WHERE sha256=?',
          [now, name, _clampDesc(description), tags == null ? null : jsonEncode(tags), key],
        );
      }
      _syncFts(db, key);
    } catch (e2) {
      debugPrint('MediaArchive: putBytes failed: $e2');
    }
    return token;
  }

  /// The raw bytes for a token or bare hash (null when absent). A hit counts
  /// as an access: last-accessed is bumped.
  Uint8List? get(String tokenOrSha256) {
    final key = _keyOf(tokenOrSha256);
    final db = _ensureDb();
    if (key == null || db == null) return null;
    try {
      final rows = db.select('SELECT data FROM media WHERE sha256=?', [key]);
      if (rows.isEmpty) return null;
      touch(key);
      return rows.first['data'] as Uint8List;
    } catch (e) {
      debugPrint('MediaArchive: get failed: $e');
      return null;
    }
  }

  /// Bump last-accessed without reading the blob (e.g. a token was seen
  /// on-air and the bytes are already here).
  void touch(String tokenOrSha256) {
    final key = _keyOf(tokenOrSha256);
    final db = _ensureDb();
    if (key == null || db == null) return;
    try {
      db.execute('UPDATE media SET last_seen=? WHERE sha256=?',
          [DateTime.now().millisecondsSinceEpoch, key]);
    } catch (e) {
      debugPrint('MediaArchive: touch failed: $e');
    }
  }

  /// True when the archive holds the bytes for this token / hash.
  bool has(String tokenOrSha256) {
    final key = _keyOf(tokenOrSha256);
    final db = _ensureDb();
    if (key == null || db == null) return false;
    try {
      return db
          .select('SELECT 1 FROM media WHERE sha256=?', [key]).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Metadata (everything but the blobs) — cheap for list views.
  MediaMeta? getMeta(String tokenOrSha256) {
    final key = _keyOf(tokenOrSha256);
    final db = _ensureDb();
    if (key == null || db == null) return null;
    try {
      final rows = db.select(
          'SELECT sha256,sha1,tlsh,name,ext,description,tags,first_seen,'
          'last_seen,size,folder,parent,downloads,pinned,'
          '(screenshot IS NOT NULL) AS has_shot '
          'FROM media WHERE sha256=?',
          [key]);
      if (rows.isEmpty) return null;
      final r = rows.first;
      List<String> tags = const [];
      final rawTags = r['tags'];
      if (rawTags is String && rawTags.isNotEmpty) {
        try {
          tags = (jsonDecode(rawTags) as List).map((t) => '$t').toList();
        } catch (_) {}
      }
      return MediaMeta(
        sha256: r['sha256'] as String,
        sha1: r['sha1'] as String?,
        tlsh: r['tlsh'] as String?,
        name: r['name'] as String?,
        ext: r['ext'] as String,
        description: r['description'] as String?,
        tags: tags,
        firstSeenMs: r['first_seen'] as int,
        lastSeenMs: r['last_seen'] as int,
        size: r['size'] as int,
        hasScreenshot: (r['has_shot'] as int) != 0,
        folder: r['folder'] as String?,
        parent: r['parent'] as String?,
        downloads: (r['downloads'] as int?) ?? 0,
        pinned: ((r['pinned'] as int?) ?? 1) != 0,
      );
    } catch (e) {
      debugPrint('MediaArchive: getMeta failed: $e');
      return null;
    }
  }

  /// Update mutable metadata; null arguments leave the column unchanged.
  /// [description] is clamped to [kMaxDescription] chars. [folder]/[parent]
  /// drive the virtual-folder navigation. The FTS index is kept in sync.
  void updateMeta(String tokenOrSha256,
      {String? name,
      String? description,
      List<String>? tags,
      String? folder,
      String? parent}) {
    final key = _keyOf(tokenOrSha256);
    final db = _ensureDb();
    if (key == null || db == null) return;
    try {
      db.execute(
        'UPDATE media SET name=COALESCE(?,name), '
        'description=COALESCE(?,description), tags=COALESCE(?,tags), '
        'folder=COALESCE(?,folder), parent=COALESCE(?,parent) '
        'WHERE sha256=?',
        [
          name,
          _clampDesc(description),
          tags == null ? null : jsonEncode(tags),
          folder,
          parent,
          key,
        ],
      );
      _syncFts(db, key);
    } catch (e) {
      debugPrint('MediaArchive: updateMeta failed: $e');
    }
  }

  /// Store (or replace) the reusable preview screenshot for an entry.
  void setScreenshot(String tokenOrSha256, Uint8List screenshot) {
    final key = _keyOf(tokenOrSha256);
    final db = _ensureDb();
    if (key == null || db == null) return;
    try {
      db.execute('UPDATE media SET screenshot=? WHERE sha256=?',
          [screenshot, key]);
    } catch (e) {
      debugPrint('MediaArchive: setScreenshot failed: $e');
    }
  }

  /// The preview screenshot bytes, or null when none was stored.
  Uint8List? getScreenshot(String tokenOrSha256) {
    final key = _keyOf(tokenOrSha256);
    final db = _ensureDb();
    if (key == null || db == null) return null;
    try {
      final rows =
          db.select('SELECT screenshot FROM media WHERE sha256=?', [key]);
      if (rows.isEmpty) return null;
      return rows.first['screenshot'] as Uint8List?;
    } catch (e) {
      debugPrint('MediaArchive: getScreenshot failed: $e');
      return null;
    }
  }

  /// Remove an entry (data + metadata). No-op when absent.
  void delete(String tokenOrSha256) {
    final key = _keyOf(tokenOrSha256);
    final db = _ensureDb();
    if (key == null || db == null) return;
    try {
      db.execute('DELETE FROM media WHERE sha256=?', [key]);
      db.execute('DELETE FROM media_fts WHERE sha256=?', [key]);
    } catch (e) {
      debugPrint('MediaArchive: delete failed: $e');
    }
  }

  /// Page through the archive's metadata, most recently accessed first
  /// (cheap: never touches the blobs).
  List<MediaMeta> list({int offset = 0, int limit = 100}) {
    final db = _ensureDb();
    if (db == null) return const [];
    try {
      final rows = db.select(
          'SELECT sha256 FROM media ORDER BY last_seen DESC LIMIT ? OFFSET ?',
          [limit, offset]);
      return [
        for (final r in rows) ?getMeta(r['sha256'] as String),
      ];
    } catch (e) {
      debugPrint('MediaArchive: list failed: $e');
      return const [];
    }
  }

  /// Full-text search over name/description/tags/folder/parent (local index).
  /// Best matches first (bm25), then most-recently accessed.
  List<MediaMeta> search(String query, {int limit = 50}) {
    final db = _ensureDb();
    if (db == null) return const [];
    final q = _ftsMatch(query);
    if (q == null) return const [];
    try {
      final rows = db.select(
        'SELECT m.sha256 FROM media_fts '
        'JOIN media m ON m.sha256 = media_fts.sha256 '
        'WHERE media_fts MATCH ? '
        'ORDER BY bm25(media_fts), m.last_seen DESC LIMIT ?',
        [q, limit],
      );
      return [for (final r in rows) ?getMeta(r['sha256'] as String)];
    } catch (e) {
      debugPrint('MediaArchive: search failed: $e');
      return const [];
    }
  }

  /// Exact lookup by a sha256 (token, base64url, or 64-char hex). Null if absent.
  MediaMeta? lookupBySha(String shaOrToken) => getMeta(shaOrToken);

  /// Increment the times-served-to-others counter for a file (the download
  /// metric). No-op when the file isn't held.
  void incrementDownloads(String tokenOrSha256) {
    final key = _keyOf(tokenOrSha256);
    final db = _ensureDb();
    if (key == null || db == null) return;
    try {
      db.execute(
          'UPDATE media SET downloads = downloads + 1 WHERE sha256=?', [key]);
    } catch (e) {
      debugPrint('MediaArchive: incrementDownloads failed: $e');
    }
  }

  /// The virtual-folder tree: one entry per distinct (parent, folder) with a
  /// file count, for navigation. Empty parent/folder means "uncategorized".
  List<MediaFolder> folders() {
    final db = _ensureDb();
    if (db == null) return const [];
    try {
      final rows = db.select(
        "SELECT COALESCE(parent,'') p, COALESCE(folder,'') f, COUNT(*) c "
        'FROM media GROUP BY p, f ORDER BY p, f',
      );
      return [
        for (final r in rows)
          MediaFolder(r['p'] as String, r['f'] as String, r['c'] as int)
      ];
    } catch (e) {
      debugPrint('MediaArchive: folders failed: $e');
      return const [];
    }
  }

  /// Files in a given virtual (parent, folder), most recently accessed first.
  /// Pass empty strings for the uncategorized bucket.
  List<MediaMeta> listByFolder(String parent, String folder,
      {int offset = 0, int limit = 200}) {
    final db = _ensureDb();
    if (db == null) return const [];
    try {
      final rows = db.select(
        "SELECT sha256 FROM media WHERE COALESCE(parent,'')=? "
        "AND COALESCE(folder,'')=? ORDER BY last_seen DESC LIMIT ? OFFSET ?",
        [parent, folder, limit, offset],
      );
      return [for (final r in rows) ?getMeta(r['sha256'] as String)];
    } catch (e) {
      debugPrint('MediaArchive: listByFolder failed: $e');
      return const [];
    }
  }

  // ── Sources: where a hash can be obtained from ─────────────────────────

  /// Record that [value] (an `infohash`, a `blossom` base URL, or a
  /// `callsign`) can provide [tokenOrSha256]. Idempotent; bumps last_seen.
  void addSource(String tokenOrSha256, String kind, String value) {
    final key = _keyOf(tokenOrSha256);
    final db = _ensureDb();
    if (key == null || db == null || value.isEmpty) return;
    try {
      db.execute(
        'INSERT INTO sources(sha256,kind,value,last_seen) VALUES(?,?,?,?) '
        'ON CONFLICT(sha256,kind,value) DO UPDATE SET last_seen=excluded.last_seen',
        [key, kind, value, DateTime.now().millisecondsSinceEpoch],
      );
    } catch (e) {
      debugPrint('MediaArchive: addSource failed: $e');
    }
  }

  /// Known providers for a hash, newest first. [kind] filters when given.
  List<(String kind, String value)> getSources(String tokenOrSha256,
      {String? kind}) {
    final key = _keyOf(tokenOrSha256);
    final db = _ensureDb();
    if (key == null || db == null) return const [];
    try {
      final rows = kind == null
          ? db.select(
              'SELECT kind,value FROM sources WHERE sha256=? '
              'ORDER BY last_seen DESC',
              [key])
          : db.select(
              'SELECT kind,value FROM sources WHERE sha256=? AND kind=? '
              'ORDER BY last_seen DESC',
              [key, kind]);
      return [
        for (final r in rows) (r['kind'] as String, r['value'] as String)
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Archive size summary (diagnostics / a future storage-settings page).
  MediaArchiveStats stats() {
    final db = _ensureDb();
    if (db == null) return const MediaArchiveStats(0, 0, 0);
    try {
      final r = db.select(
          'SELECT COUNT(*) AS n, COALESCE(SUM(size),0) AS b, '
          'SUM(screenshot IS NOT NULL) AS s FROM media').first;
      return MediaArchiveStats(
          r['n'] as int, r['b'] as int, (r['s'] as int?) ?? 0);
    } catch (_) {
      return const MediaArchiveStats(0, 0, 0);
    }
  }

  /// Bound the archive: drop entries last accessed more than [maxAgeMs] ago,
  /// then keep only the [maxCount] most recently accessed.
  void prune(
      {int maxAgeMs = 365 * 24 * 60 * 60 * 1000, int maxCount = 10000}) {
    final db = _ensureDb();
    if (db == null) return;
    try {
      final cutoff = DateTime.now().millisecondsSinceEpoch - maxAgeMs;
      db.execute('DELETE FROM media WHERE last_seen < ?', [cutoff]);
      db.execute(
        'DELETE FROM media WHERE sha256 NOT IN '
        '(SELECT sha256 FROM media ORDER BY last_seen DESC LIMIT ?)',
        [maxCount],
      );
    } catch (e) {
      debugPrint('MediaArchive: prune failed: $e');
    }
  }

  /// Close the database (tests / teardown).
  void close() {
    try {
      _db?.dispose();
    } catch (_) {}
    _db = null;
    _instances.removeWhere((_, v) => identical(v, this));
  }
}
