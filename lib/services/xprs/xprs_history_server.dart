/*
 * xprs_history_server — answering `cmd:history` from the spool.
 *
 * docs/XPRS.md section 25.2: the station replies `code:202`, re-airs the
 * ORIGINAL packets unchanged, newest first, then `code:200` — or `code:206`
 * when that was one page and more exists, and the requester continues by
 * moving `until:` to the oldest `ts:` it received. `code:404` for a window
 * not held, without apology (31.3). `code:429` over budget, out loud (31.2).
 *
 * Airtime is the scarce thing (31.4): one replay in flight ever, one packet
 * every 1.5 s on a short-TTL advert slot so the replay never camps on the
 * presence beacons, and token buckets per requester (a station that declared
 * us, or whose key we hold, gets more than a stranger; another device of OURS
 * is unmetered — section 3.1). The replay bytes are byte-identical to what
 * was stored: no via:, no re-sign — an indexer passes on the author's packet,
 * and the signature that travels with it is the author's (36.2).
 *
 * Commands arrive through XprsIngest ([install] hooks its onCommand). A
 * command off the Reticulum lane is logged and not answered in v1 — the
 * reply lane there would be wappSendTo, a slot deliberately left open.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../connections/bluetooth/ble5_bus.dart';
import '../log_service.dart';
import '../preferences_service.dart';
import 'xprs_archive.dart';
import 'xprs_id.dart';
import 'xprs_ingest.dart';
import 'xprs_packet.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart';

class XprsHistoryServer {
  XprsHistoryServer._();
  static final XprsHistoryServer instance = XprsHistoryServer._();

  /// Packets per page: 12 re-aired wires ≈ 18 s of paced airtime, plus the
  /// probe row that decides 206-versus-200.
  static const int pageSize = 12;
  static const Duration interPacket = Duration(milliseconds: 1500);
  static const Duration answeredWindow = Duration(minutes: 10);

  /// Budgets (section 31.2): replays per hour. "Known" = an author that
  /// declared us as mailbox, or whose key we hold.
  static const int knownPerHour = 6;
  static const int strangerPerHour = 2;
  static const int globalPerHour = 12;

  /// Test seams. [txOverride] captures airings without a radio; [signingKey]
  /// stands in for the profile scalar.
  Future<bool> Function(String key, Uint8List bytes, Duration ttl)? txOverride;
  BigInt? Function() signingKey = xprsProfileScalar;

  int answered = 0, refused429 = 0, rnsIgnored = 0;

  final Map<String, int> _answeredIds = {};
  final Map<String, List<int>> _asksBy = {};
  final List<int> _asksGlobal = [];
  Timer? _chain;
  String? _chainFor;
  bool get replaying => _chain != null;

  /// Route heard commands here. Called once at mesh start.
  void install() {
    XprsIngest.onCommand = _onPacket;
  }

  void _onPacket(XprsPacket p,
      {required String selfBase, required String bearer}) {
    if (p.type != 'command' || (p['cmd'] ?? '') != 'history') return;
    if (_base(p['d'] ?? '') != selfBase) return;
    if (bearer == 'rns') {
      // No reply lane on the hub side yet; saying so beats silence in a log.
      rnsIgnored++;
      return;
    }
    if (!(PreferencesService.instanceSync?.xprsServeHistory ?? true)) return;
    final archive = XprsArchive.instance;
    if (!archive.ready) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final cmdId = xprsIdentifier(p);
    // The requester's advert re-airs the identical wire for its TTL and the
    // 0x58 path has no payload dedup: one answer per command, then quiet.
    _answeredIds.removeWhere(
        (_, t) => now - t > answeredWindow.inMilliseconds);
    if (_answeredIds.containsKey(cmdId)) return;
    _answeredIds[cmdId] = now;

    final from = _base(p['f'] ?? '');
    if (from.isEmpty) return;

    // A forged command deserves no airtime at all.
    if (p.has('sig')) {
      final state = xprsVerify(p, archive.keyResolver?.call(from));
      if (state == XprsSigState.forged) return;
    }

    // Flush so a window ending "now" sees what was heard seconds ago.
    archive.flush(nowMs: now);

    final selfIsAsking = from == selfBase;
    if (!selfIsAsking && !_budgetAllows(from, now)) {
      refused429++;
      LogService.instance
          .add('XPRS: history for $from refused — over budget (429)');
      _airControl(selfBase, from, cmdId, 429);
      return;
    }

    final sinceMs = xprsParseTs(p['since']);
    final untilMs = xprsParseTs(p['until']) ?? (now + 1);
    final rows = archive.query(
        sinceMs: sinceMs,
        untilMs: untilMs,
        only: p['only'],
        limit: pageSize + 1);
    answered++;

    if (rows.isEmpty) {
      // Logged because an unexpected 404 is the first thing a person
      // debugging a silent replay needs to see.
      LogService.instance
          .add('XPRS: history for $from — nothing held in that window (404)');
      _airControl(selfBase, from, cmdId, 404);
      return;
    }
    // A new ask from the requester whose replay is running supersedes it
    // (they narrowed the window; the old page is stale). Anyone else waits:
    // one replay in flight protects the channel (31.4).
    if (_chain != null) {
      if (_chainFor == from) {
        _chain?.cancel();
        _chain = null;
        _chainFor = null;
      } else {
        refused429++;
        _airControl(selfBase, from, cmdId, 429);
        return;
      }
    }
    if (!selfIsAsking) _recordAsk(from, now);

    final more = rows.length > pageSize;
    final page = [for (final r in rows.take(pageSize)) r['wire'] as String];
    _airControl(selfBase, from, cmdId, 202);
    var i = 0;
    _chainFor = from;
    _chain = Timer.periodic(interPacket, (t) {
      if (i < page.length) {
        // The stored wire, byte for byte — the author's packet, the author's
        // signature (25.2.1, 36.2).
        unawaited(_air('xprs-hist:$i', page[i], const Duration(seconds: 10)));
        i++;
        return;
      }
      t.cancel();
      _chain = null;
      _chainFor = null;
      _airControl(selfBase, from, cmdId, more ? 206 : 200);
    });
    LogService.instance.add('XPRS: history for $from — ${page.length} '
        'packet${page.length == 1 ? "" : "s"}${more ? ", more held" : ""}');
  }

  bool _budgetAllows(String from, int now) {
    void trim(List<int> l) => l.removeWhere((t) => now - t > 3600000);
    trim(_asksGlobal);
    final mine = _asksBy.putIfAbsent(from, () => []);
    trim(mine);
    if (_asksGlobal.length >= globalPerHour) return false;
    final known = XprsArchive.instance.hasActiveDecl(from, nowMs: now) ||
        XprsArchive.instance.keyResolver?.call(from) != null;
    return mine.length < (known ? knownPerHour : strangerPerHour);
  }

  void _recordAsk(String from, int now) {
    _asksGlobal.add(now);
    _asksBy.putIfAbsent(from, () => []).add(now);
  }

  void _airControl(String self, String to, String cmdId, int code) {
    final now = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${now.year}-${two(now.month)}-${two(now.day)}_'
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
    var p = XprsPacket.parse(
        't:result f:$self d:$to ts:$ts r:$cmdId code:$code');
    if (p == null) return;
    final d = signingKey();
    if (d != null) p = xprsSign(p, d);
    unawaited(
        _air('xprs-hist:c$code', p.encode(), const Duration(seconds: 30)));
  }

  Future<bool> _air(String key, String wire, Duration ttl) {
    final bytes = Uint8List.fromList(utf8.encode(wire));
    final tx = txOverride;
    if (tx != null) return tx(key, bytes, ttl);
    return Ble5Bus.instance
        .advertiseFrame(key, Ble5Subtype.xprs, bytes, ttl: ttl);
  }

  static String _base(String c) => c.trim().toUpperCase().split('-').first;

  /// Tests only: forget budgets, dedup and any running chain.
  void reset() {
    _answeredIds.clear();
    _asksBy.clear();
    _asksGlobal.clear();
    _chain?.cancel();
    _chain = null;
    _chainFor = null;
    answered = 0;
    refused429 = 0;
    rnsIgnored = 0;
  }
}
