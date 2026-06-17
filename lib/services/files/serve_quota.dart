/*
 * ServeQuota — the serving-side budget + anti-abuse guard for the file layer.
 *
 * A node decides how much of its uplink it is willing to spend serving others.
 * Three guards, in order of strength:
 *   1. servingAllowed — a hard off switch (e.g. set false on cellular when the
 *      user opted out of serving on metered data).
 *   2. a GLOBAL daily byte budget (default 1 GB/day) — the hard backstop that
 *      holds even against identity/link rotation.
 *   3. a PER-REQUESTER daily byte budget — so one peer can't drain the whole
 *      budget, plus a manifest refetch window so a peer can't restart the same
 *      full download over and over within a short window (chunks are gated only
 *      by the byte budgets, so a normal chunked download is never blocked).
 *
 * Requester identity over an anonymous link is weak (linkId), so the per-
 * requester guard is best-effort; the global budget is the real protection.
 */
import 'dart:typed_data';

class ServeQuota {
  bool enabled; // false = no limiting at all
  bool servingAllowed; // false = decline everything (e.g. on cellular)
  int dailyBudgetBytes; // global cap per day
  int perRequesterBytes; // per-requester cap per day
  Duration manifestRefetchWindow; // refuse repeated full re-downloads

  int _day = 0;
  int _globalToday = 0;
  final Map<String, int> _perReqToday = {};
  final Map<String, int> _lastManifestMs = {}; // 'requester|shaHex' -> ms

  ServeQuota({
    this.enabled = true,
    this.servingAllowed = true,
    this.dailyBudgetBytes = 1 << 30, // 1 GB
    this.perRequesterBytes = 256 << 20, // 256 MB
    this.manifestRefetchWindow = const Duration(minutes: 10),
  });

  int get bytesServedToday => _globalToday;
  int get remainingToday =>
      (dailyBudgetBytes - _globalToday).clamp(0, dailyBudgetBytes);

  /// Are we currently willing/able to serve at all (switch + budget not spent)?
  bool get available =>
      enabled ? (servingAllowed && remainingToday > 0) : true;

  /// May we serve [bytes] for [sha] to [requester] right now? [manifest] true for
  /// a GET_MANIFEST (subject to the refetch window).
  bool canServe(String requester, Uint8List sha, int bytes,
      {bool manifest = false}) {
    _rollDay();
    if (!enabled) return true;
    if (!servingAllowed) return false;
    if (_globalToday + bytes > dailyBudgetBytes) return false;
    if ((_perReqToday[requester] ?? 0) + bytes > perRequesterBytes) return false;
    if (manifest) {
      final last = _lastManifestMs['$requester|${_hex(sha)}'];
      if (last != null &&
          _now() - last < manifestRefetchWindow.inMilliseconds) {
        return false;
      }
    }
    return true;
  }

  /// Account for bytes actually committed to a requester.
  void record(String requester, Uint8List sha, int bytes,
      {bool manifest = false}) {
    _rollDay();
    if (!enabled) return;
    _globalToday += bytes;
    _perReqToday[requester] = (_perReqToday[requester] ?? 0) + bytes;
    if (manifest) _lastManifestMs['$requester|${_hex(sha)}'] = _now();
  }

  Map<String, dynamic> status() => {
        'enabled': enabled,
        'servingAllowed': servingAllowed,
        'dailyBudget': dailyBudgetBytes,
        'servedToday': _globalToday,
        'remaining': remainingToday,
        'requesters': _perReqToday.length,
      };

  void _rollDay() {
    final d = _now() ~/ 86400000;
    if (d != _day) {
      _day = d;
      _globalToday = 0;
      _perReqToday.clear();
      // Drop manifest marks older than the window (cheap opportunistic prune).
      final cutoff = _now() - manifestRefetchWindow.inMilliseconds;
      _lastManifestMs.removeWhere((_, ms) => ms < cutoff);
    }
  }

  int _now() => DateTime.now().millisecondsSinceEpoch;

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
