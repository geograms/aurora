/// Browse-before-carry, shaped for a wapp.
///
/// A wasm wapp cannot await a twelve-second dial inside a HAL call — the
/// engine would stall — so this broker turns [MeshSessionManager.browseCarried]
/// and [pullCarried] into a kick-off-and-poll surface: `browse` starts the
/// dial and returns at once, `status` is cheap and idempotent, `pull` rides
/// the same live session. One request at a time, because there is one radio.
///
/// The XPRS wapp's Carry tab is the consumer (`hal_mesh_carry`), and the
/// surface stays generic: callsigns, ids and envelope facts — no XPRS
/// vocabulary, no wapp-specific shapes.
library;

import 'dart:async';

import '../log_service.dart';
import 'mesh_custody.dart';
import 'mesh_session.dart';

class MeshCarryBroker {
  MeshCarryBroker._();
  static final MeshCarryBroker instance = MeshCarryBroker._();

  /// idle | busy | done | fail | pulling | pulled
  String _state = 'idle';
  String _station = '';
  List<MspMsgListEntry> _entries = const [];
  int _pulled = 0;

  /// Start browsing [station]'s custody store. A browse already in flight for
  /// the same station is left to finish; a new station replaces a FINISHED
  /// browse (busy ones are not interrupted — one radio, one session).
  Map<String, dynamic> browse(String station) {
    final want = station.trim().toUpperCase();
    if (want.isEmpty) return status();
    if (_state == 'busy' || _state == 'pulling') return status();
    _state = 'busy';
    _station = want;
    _entries = const [];
    _pulled = 0;
    unawaited(MeshSessionManager.instance.browseCarried(want).then((r) {
      if (_station != want || _state != 'busy') return; // superseded
      _entries = r ?? const [];
      _state = r == null ? 'fail' : 'done';
    }).catchError((Object e) {
      LogService.instance.add('Mesh: carry browse $want failed: $e');
      if (_station == want) _state = 'fail';
    }));
    return status();
  }

  /// Take custody of [ids] from [station]. The messages arrive over the
  /// ordinary custody lane into our own store; the peer archives on our acks.
  Map<String, dynamic> pull(String station, List<String> ids) {
    final want = station.trim().toUpperCase();
    if (want.isEmpty || ids.isEmpty) return status();
    if (_state == 'busy' || _state == 'pulling') return status();
    _state = 'pulling';
    _station = want;
    _pulled = 0;
    unawaited(MeshSessionManager.instance.pullCarried(want, ids).then((ok) {
      if (_station != want || _state != 'pulling') return;
      _pulled = ok ? ids.length : 0;
      _state = ok ? 'pulled' : 'fail';
      // The listing the wapp holds is stale now — what was pulled is ours.
      _entries = [
        for (final e in _entries)
          if (!ids.contains(e.am)) e,
      ];
    }).catchError((Object e) {
      LogService.instance.add('Mesh: carry pull $want failed: $e');
      if (_station == want) _state = 'fail';
    }));
    return status();
  }

  Map<String, dynamic> status() => {
        'state': _state,
        'station': _station,
        'pulled': _pulled,
        'entries': [
          for (final e in _entries)
            {
              'id': e.am,
              'target': e.target,
              'len': e.len,
              'age': e.ageS,
              'urg': e.urg,
            },
        ],
      };

  /// Back to the idle state (the wapp left the listing).
  Map<String, dynamic> reset() {
    if (_state != 'busy' && _state != 'pulling') {
      _state = 'idle';
      _station = '';
      _entries = const [];
      _pulled = 0;
    }
    return status();
  }
}
