/*
 * mesh_store — the street-mesh store-and-forward archive (docs/mesh.md §6).
 *
 * Every custody node archives the 1:1 messages it carries. SQLite (WAL) for
 * the same reason as media_archive.dart: atomic writes, a crash can't shred
 * the file, one corrupt row never costs the store.
 *
 *   mesh_store    — parked/carried messages, keyed by their am: receipt id
 *                   (or a content-hash pseudo-key 'c:<fnv>' when a frame has
 *                   no am). state 0 = in-transit (we still owe delivery),
 *                   state 1 = archive (custody handed over / e2e-acked).
 *   received_ams  — ids WE received recently; source of the beacon
 *                   have-digest bloom and the inbound duplicate check.
 *   bulk_handover — 7-day records of bulk files we passed downstream
 *                   (dup suppression after the .part is deleted).
 *
 * Quota: 7 days OR the message quota (default 100 MB), whichever first —
 * sweep drops expired rows, then archives oldest-first, then in-transit
 * lowest-urgency-oldest-first ([MeshUrgency]).
 */
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../../profile/profile_db.dart';

import 'mesh_beacon.dart';
import 'mesh_bloom.dart';
import 'mesh_session.dart';
import 'mesh_table.dart';

/// How much a carried message is worth keeping when the store is full.
///
/// The four levels are XPRS `urg:` (docs/XPRS.md §13.5), so a level stated on
/// the wire maps straight onto the eviction order with nothing to translate.
/// This replaced a two-level `prio 0/1` that meant the same thing at half the
/// resolution and could only ever be *inferred* by the carrier.
///
/// It is ordered lowest-first: [MeshStore.sweep] evicts `ORDER BY urg, ts`.
enum MeshUrgency {
  low,
  normal,
  high,
  urgent;

  /// Parse an XPRS `urg:` value. Anything unrecognised is [normal] — an
  /// unknown word is skipped everywhere else in XPRS, and silently dropping a
  /// message because its urgency did not parse would be worse than carrying it.
  static MeshUrgency fromWire(String? v) => switch (v?.trim().toLowerCase()) {
        'low' => MeshUrgency.low,
        'high' => MeshUrgency.high,
        'urgent' => MeshUrgency.urgent,
        _ => MeshUrgency.normal,
      };

  /// The highest level this may be raised to. A sender states what it wants;
  /// the carrier decides what it is allowed to have.
  MeshUrgency cappedAt(MeshUrgency cap) => index <= cap.index ? this : cap;
}

class MeshStoreCounts {
  final int inTransit;
  final int archived;
  final int bytes;
  final int receivedAms;
  const MeshStoreCounts(this.inTransit, this.archived, this.bytes, this.receivedAms);
}

class MeshStore {
  MeshStore._();
  static final MeshStore instance = MeshStore._();

  Database? _db;
  int quotaBytes = 100 * 1024 * 1024;
  static const int retentionS = 7 * 24 * 3600;
  // received_ams window feeding the bloom (~24 h keeps the filter sparse).
  static const int receivedWindowS = 24 * 3600;

  bool get ready => _db != null;

  /// Open (and migrate) the store. Safe to call again for a new path when the
  /// active profile changes.
  void init(String path) {
    close();
    try {
      Directory(File(path).parent.path).createSync(recursive: true);
      final db = openProfileDb(path);
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('''
        CREATE TABLE IF NOT EXISTS mesh_store(
          am TEXT PRIMARY KEY,
          target TEXT NOT NULL,
          sender TEXT NOT NULL,
          wire BLOB NOT NULL,
          ts INTEGER NOT NULL,
          size INTEGER NOT NULL,
          urg INTEGER NOT NULL DEFAULT 1,
          state INTEGER NOT NULL DEFAULT 0
        )''');
      _migratePrioToUrg(db);
      db.execute(
          'CREATE INDEX IF NOT EXISTS idx_store_target ON mesh_store(target, state)');
      db.execute('''
        CREATE TABLE IF NOT EXISTS received_ams(
          am TEXT PRIMARY KEY,
          ts INTEGER NOT NULL
        )''');
      db.execute('''
        CREATE TABLE IF NOT EXISTS bulk_handover(
          sha TEXT NOT NULL,
          target TEXT NOT NULL,
          peer TEXT NOT NULL,
          ts INTEGER NOT NULL,
          PRIMARY KEY (sha, target)
        )''');
      // v2: drop the pre-park-gate backlog of undeliverable street mail
      // (it drove nonstop phone-to-phone dial loops).
      final v = db.select('PRAGMA user_version').first.columnAt(0) as int;
      if (v < 2) {
        db.execute('DELETE FROM mesh_store');
        db.execute('PRAGMA user_version = 2');
      }
      _db = db;
    } catch (e) {
      _db = null;
      // Storage failure degrades to no custody, never to a crash.
      // ignore: avoid_print
      print('MeshStore: open failed: $e');
    }
  }

  void close() {
    _db?.dispose();
    _db = null;
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Content pseudo-key for frames without an am token.
  static String contentKey(Uint8List wire) {
    var h = 0x811c9dc5;
    for (final x in wire) {
      h ^= x;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return 'c:${h.toRadixString(16)}';
  }

  /// Park a 1:1 frame for custody. [am] may be '' (content-keyed). Returns
  /// true when newly stored (false = dup / already archived / no store).
  /// A custody MSG frame must fit one ATT write (509B minus 17B header).
  static const int maxWire = 480;

  bool offer({
    required String target,
    required String sender,
    required Uint8List wire,
    String am = '',
    MeshUrgency urg = MeshUrgency.normal,
    bool inTransit = true,
  }) {
    final db = _db;
    if (db == null || wire.length > maxWire) return false;
    final key = am.isNotEmpty ? am : contentKey(wire);
    // A frame whose am we've already seen delivered is not worth carrying.
    if (am.isNotEmpty && wasReceived(am)) return false;
    // A stranger's mail is carried, but never at the cost of our own: past this
    // many rows in transit we stop accepting the lowest level. Anything the
    // carrier itself cares about is above [MeshUrgency.low] and still gets in,
    // and the sweep sheds the bottom first — see [sweep].
    if (urg == MeshUrgency.low && countPending() >= inTransitMax) return false;
    final dup = db.select('SELECT 1 FROM mesh_store WHERE am = ?', [key]);
    if (dup.isNotEmpty) return false;
    db.execute(
      'INSERT INTO mesh_store(am,target,sender,wire,ts,size,urg,state) '
      'VALUES(?,?,?,?,?,?,?,?)',
      [
        key,
        target.toUpperCase(),
        sender.toUpperCase(),
        wire,
        _now(),
        wire.length,
        urg.index,
        inTransit ? 0 : 1,
      ],
    );
    return true;
  }

  /// Carry forward a store written before urgency replaced `prio 0/1`.
  ///
  /// The old column only ever held 0 (a stranger's mail) or 1 (ours, or a
  /// target inside the mesh horizon), so it maps onto the bottom two levels
  /// exactly and the eviction order across the upgrade does not change.
  static void _migratePrioToUrg(Database db) {
    final cols = db
        .select('PRAGMA table_info(mesh_store)')
        .map((r) => r['name'] as String)
        .toSet();
    if (!cols.contains('prio')) return;
    if (!cols.contains('urg')) {
      db.execute(
          'ALTER TABLE mesh_store ADD COLUMN urg INTEGER NOT NULL DEFAULT 1');
    }
    db.execute('UPDATE mesh_store SET urg = CASE WHEN prio > 0 THEN ? ELSE ? END',
        [MeshUrgency.normal.index, MeshUrgency.low.index]);
  }

  /// End-to-end receipt / peer have-bloom hit: the target has [am] — drop
  /// every copy. Returns rows purged.
  int purgeAm(String am) {
    final db = _db;
    if (db == null || am.isEmpty) return 0;
    db.execute('DELETE FROM mesh_store WHERE am = ?', [am]);
    return db.updatedRows;
  }

  /// Custody handed to a peer (MSG_ACK / duplicate) — archive our copy.
  /// Rows in transit for OTHER people that this device will carry.
  ///
  /// A custodian holds mail for anyone — that is the whole point of a street
  /// mesh — but a device that never meets those targets would otherwise fill its
  /// disk with mail it can never deliver. Past this many, a stranger's frame is
  /// refused at the door; the user's own mail is never refused.
  static const int inTransitMax = 4000; // ~1.9 MB of wire at maxWire

  /// Rows still owed delivery.
  int countPending() {
    final db = _db;
    if (db == null) return 0;
    final r = db.select('SELECT COUNT(*) c FROM mesh_store WHERE state = 0');
    return (r.first['c'] as int?) ?? 0;
  }

  /// Take an archived row back into transit.
  ///
  /// A row we handed to somebody else is archived, not deleted — it is the
  /// receipt that we no longer owe delivery. But a peer may hand the same
  /// message BACK to us (its own route pointed at us), and answering "duplicate"
  /// then made the other side archive its copy too: two archived rows, nobody
  /// carrying it, and the message quietly gone. Re-arming is the honest answer:
  /// we accepted custody again, so we owe delivery again.
  ///
  /// Returns false when there is no such row, or when it is still in transit
  /// (we already owe it — that IS a duplicate).
  bool reArm(String key) {
    final db = _db;
    if (db == null) return false;
    final rows =
        db.select('SELECT state FROM mesh_store WHERE am = ?', [key]);
    if (rows.isEmpty) return false;
    if ((rows.first['state'] as int? ?? 0) == 0) return false;
    db.execute('UPDATE mesh_store SET state = 0, ts = ? WHERE am = ?',
        [_now(), key]);
    return true;
  }

  void markArchived(String key) {
    _db?.execute('UPDATE mesh_store SET state = 1 WHERE am = ?', [key]);
  }

  /// In-transit messages this session should hand to [peer]: frames FOR the
  /// peer itself, frames whose route's next hop is the peer, and — mule
  /// custody — frames WE originated whose target is nowhere in the mesh
  /// horizon (the peer carries them; custody/TTL/receipts cover a mule
  /// that never meets the target).
  List<MeshPendingMsg> pendingFor(String peer, MeshTable? table,
      {int max = 32, String selfCallsign = ''}) {
    final db = _db;
    if (db == null) return const [];
    final p = peer.toUpperCase();
    final self = selfCallsign.toUpperCase();
    final rows = db.select(
        'SELECT am,target,sender,wire,ts FROM mesh_store WHERE state = 0 '
        'ORDER BY ts LIMIT 256');
    final out = <MeshPendingMsg>[];
    for (final r in rows) {
      final target = r['target'] as String;
      var give = target == p;
      if (!give && table != null) {
        // DIRECT BEATS RELAYED. A neighbour we can hear is the shortest path
        // there is, and handing its mail to somebody else instead is how a
        // message went round in a circle: the relay's own route pointed back at
        // us, our store already held the row, the offer came back "duplicate",
        // and both copies ended up archived with nobody owing delivery. Only
        // route through a third party when the target itself is out of reach.
        final targetIsNeighbour = table.neighbors.keys
            .any((n) => n.toUpperCase() == target.toUpperCase());
        final hex = meshHashHex(meshHash(target));
        final route = table.routes[hex];
        if (route != null) {
          give = !targetIsNeighbour && route.viaCallsign.toUpperCase() == p;
        } else if (self.isNotEmpty &&
            (r['sender'] as String) == self &&
            !table.neighbors.keys
                .any((n) => n.toUpperCase() == target.toUpperCase())) {
          give = true; // own mail, unreachable target: mule it
        }
      }
      if (!give) continue;
      final key = r['am'] as String;
      out.add(MeshPendingMsg(
        am: key.startsWith('c:') ? '' : key,
        key: key,
        wire: Uint8List.fromList(r['wire'] as List<int>),
        ts: r['ts'] as int,
      ));
      if (out.length >= max) break;
    }
    return out;
  }

  /// Distinct targets of in-transit frames WE originated (custodian path).
  List<String> ownPendingTargets(String selfCallsign) {
    final db = _db;
    if (db == null || selfCallsign.isEmpty) return const [];
    final rows = db.select(
        'SELECT DISTINCT target FROM mesh_store WHERE state = 0 AND sender = ?',
        [selfCallsign.toUpperCase()]);
    return [for (final r in rows) r['target'] as String];
  }

  /// Count of frames we still owe delivery for (beacon pending trailer).
  int pendingCount() {
    final db = _db;
    if (db == null) return 0;
    final r = db.select('SELECT COUNT(*) c FROM mesh_store WHERE state = 0');
    return r.first['c'] as int;
  }

  // --- received side ---------------------------------------------------------

  /// Record an am WE received (feeds the have-bloom + duplicate check).
  void recordReceivedAm(String am) {
    if (am.isEmpty) return;
    _db?.execute(
        'INSERT OR REPLACE INTO received_ams(am, ts) VALUES(?, ?)',
        [am, _now()]);
  }

  bool wasReceived(String am) {
    final db = _db;
    if (db == null || am.isEmpty) return false;
    return db.select('SELECT 1 FROM received_ams WHERE am = ?', [am]).isNotEmpty;
  }

  /// The beacon have-digest: bloom over ams received in the last ~24 h.
  Uint8List buildHaveBloom() {
    final db = _db;
    if (db == null) return Uint8List(0);
    final rows = db.select(
        'SELECT am FROM received_ams WHERE ts > ?', [_now() - receivedWindowS]);
    if (rows.isEmpty) return Uint8List(0);
    return meshBloomBuild(rows.map((r) => r['am'] as String));
  }

  /// A neighbor's beacon bloom landed: purge every parked message the bloom
  /// claims its owner already has... only when that neighbor IS the target
  /// (a bloom is a statement about its owner, not the street). Returns purged.
  int applyPeerBloom(String owner, Uint8List bloom) {
    final db = _db;
    if (db == null || bloom.length < kMeshBloomBytes) return 0;
    final rows = db.select(
        'SELECT am FROM mesh_store WHERE target = ?', [owner.toUpperCase()]);
    var purged = 0;
    for (final r in rows) {
      final key = r['am'] as String;
      if (key.startsWith('c:')) continue;
      if (meshBloomHas(bloom, key)) {
        db.execute('DELETE FROM mesh_store WHERE am = ?', [key]);
        purged++;
      }
    }
    return purged;
  }

  // --- bulk handover records ---------------------------------------------------

  void recordBulkHandover(String shaHex, String target, String peer) {
    _db?.execute(
        'INSERT OR REPLACE INTO bulk_handover(sha,target,peer,ts) VALUES(?,?,?,?)',
        [shaHex, target.toUpperCase(), peer.toUpperCase(), _now()]);
  }

  bool bulkHandedOver(String shaHex, String target) {
    final db = _db;
    if (db == null) return false;
    return db.select(
        'SELECT 1 FROM bulk_handover WHERE sha = ? AND target = ?',
        [shaHex, target.toUpperCase()]).isNotEmpty;
  }

  // --- housekeeping --------------------------------------------------------------

  /// 7-day TTL + quota eviction (archives first, then oldest in-transit).
  void sweep() {
    final db = _db;
    if (db == null) return;
    final now = _now();
    db.execute('DELETE FROM mesh_store WHERE ts < ?', [now - retentionS]);
    db.execute(
        'DELETE FROM received_ams WHERE ts < ?', [now - receivedWindowS * 2]);
    db.execute('DELETE FROM bulk_handover WHERE ts < ?', [now - retentionS]);
    var total = (db.select('SELECT COALESCE(SUM(size),0) s FROM mesh_store')
        .first['s'] as int);
    if (total <= quotaBytes) return;
    for (final phase in ['state = 1', 'state = 0']) {
      while (total > quotaBytes) {
        final r = db.select(
            'SELECT am, size FROM mesh_store WHERE $phase '
            'ORDER BY urg, ts LIMIT 1');
        if (r.isEmpty) break;
        db.execute('DELETE FROM mesh_store WHERE am = ?', [r.first['am']]);
        total -= r.first['size'] as int;
      }
    }
  }

  MeshStoreCounts counts() {
    final db = _db;
    if (db == null) return const MeshStoreCounts(0, 0, 0, 0);
    final t = db.select(
        'SELECT COALESCE(SUM(CASE WHEN state=0 THEN 1 ELSE 0 END),0) i, '
        'COALESCE(SUM(CASE WHEN state=1 THEN 1 ELSE 0 END),0) a, '
        'COALESCE(SUM(size),0) s FROM mesh_store').first;
    final r = db.select('SELECT COUNT(*) c FROM received_ams').first;
    return MeshStoreCounts(
        t['i'] as int, t['a'] as int, t['s'] as int, r['c'] as int);
  }
}
