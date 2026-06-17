/*
 * RelayProtocol — wire framing for Aurora's NOSTR relay over Reticulum.
 *
 * NIP-01/45/50 semantics, but msgpack-framed (reuse lxmf_msgpack) and carried
 * over an RnsLink instead of a websocket. Each frame is a msgpack array whose
 * first element is the op code:
 *   EVENT    [1, eventMap]                  client -> relay: publish an event
 *   REQ      [2, subId, filterMap]          client -> relay: query/search
 *   COUNT    [3, subId, filterMap]          client -> relay: count matches
 *   STORED   [0x81, ok, reason]             relay -> client: EVENT result
 *   RESULT   [0x82, subId, [eventMap...], eose]  relay -> client: REQ result
 *   COUNTRES [0x83, subId, n]              relay -> client: COUNT result
 *
 * A REQ whose filter carries a `search` field is a NIP-50 full-text query; the
 * relay answers it the same way (RESULT). For slice 2 a REQ returns its whole
 * result set in one RESULT (eose=true) — long-lived subscriptions are a later
 * concern. Event maps are exactly NostrEvent.toJson() / .fromJson().
 */
import 'dart:typed_data';

import '../reticulum/lxmf/lxmf_msgpack.dart';
import '../../util/nostr_event.dart';
import 'relay_event_store.dart';

class RelayOp {
  static const int event = 0x01;
  static const int req = 0x02;
  static const int count = 0x03;
  static const int deposit = 0x04; // store-and-forward: queue a packed LXMF msg
  static const int stored = 0x81;
  static const int result = 0x82;
  static const int countRes = 0x83;
}

/// A decoded relay frame. Only the fields relevant to [op] are populated.
class RelayFrame {
  final int op;
  final String? subId;
  final NostrEvent? event;
  final NostrFilter? filter;
  final List<NostrEvent>? events;
  final bool eose;
  final bool ok;
  final String? reason;
  final int count;
  final String? dest; // DEPOSIT: recipient LXMF delivery dest hash (hex)
  final Uint8List? blob; // DEPOSIT: packed LXMF message

  const RelayFrame({
    required this.op,
    this.subId,
    this.event,
    this.filter,
    this.events,
    this.eose = false,
    this.ok = false,
    this.reason,
    this.count = 0,
    this.dest,
    this.blob,
  });
}

class RelayProtocol {
  // ── Encode ────────────────────────────────────────────────────────────────

  static Uint8List event(NostrEvent e) =>
      msgpackEncode([RelayOp.event, e.toJson()]);

  static Uint8List req(String subId, NostrFilter filter) =>
      msgpackEncode([RelayOp.req, subId, filter.toJson()]);

  static Uint8List count(String subId, NostrFilter filter) =>
      msgpackEncode([RelayOp.count, subId, filter.toJson()]);

  static Uint8List stored(bool ok, [String? reason]) =>
      msgpackEncode([RelayOp.stored, ok, reason]);

  static Uint8List result(String subId, List<NostrEvent> events, bool eose) =>
      msgpackEncode([
        RelayOp.result,
        subId,
        [for (final e in events) e.toJson()],
        eose,
      ]);

  static Uint8List countResult(String subId, int n) =>
      msgpackEncode([RelayOp.countRes, subId, n]);

  /// Store-and-forward: deposit [blob] (a packed LXMF message) for offline
  /// recipient [destHex] (its LXMF delivery dest hash).
  static Uint8List deposit(String destHex, Uint8List blob) =>
      msgpackEncode([RelayOp.deposit, destHex, blob]);

  // ── Decode ──────────────────────────────────────────────────────────────

  /// Decode a frame, or null if malformed.
  static RelayFrame? decode(Uint8List bytes) {
    final Object? raw;
    try {
      raw = msgpackDecode(bytes);
    } catch (_) {
      return null;
    }
    if (raw is! List || raw.isEmpty) return null;
    final op = raw[0];
    if (op is! int) return null;
    try {
      switch (op) {
        case RelayOp.event:
          return RelayFrame(op: op, event: _event(raw[1]));
        case RelayOp.deposit:
          return RelayFrame(
            op: op,
            dest: raw[1] as String,
            blob: raw[2] is Uint8List
                ? raw[2] as Uint8List
                : Uint8List.fromList((raw[2] as List).cast<int>()),
          );
        case RelayOp.req:
        case RelayOp.count:
          return RelayFrame(
            op: op,
            subId: raw[1] as String,
            filter: NostrFilter.fromJson(_map(raw[2])),
          );
        case RelayOp.stored:
          return RelayFrame(
            op: op,
            ok: raw[1] == true,
            reason: raw.length > 2 ? raw[2] as String? : null,
          );
        case RelayOp.result:
          final list = (raw[2] as List)
              .map((m) => _event(m))
              .whereType<NostrEvent>()
              .toList();
          return RelayFrame(
            op: op,
            subId: raw[1] as String,
            events: list,
            eose: raw.length > 3 ? raw[3] == true : true,
          );
        case RelayOp.countRes:
          return RelayFrame(
            op: op,
            subId: raw[1] as String,
            count: raw[2] as int,
          );
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  static NostrEvent? _event(Object? m) {
    if (m == null) return null;
    return NostrEvent.fromJson(_map(m));
  }

  /// Coerce a msgpack-decoded map (`Map<Object?,Object?>`) to `Map<String,dynamic>`.
  static Map<String, dynamic> _map(Object? m) {
    final src = m as Map;
    return {for (final e in src.entries) e.key.toString(): e.value};
  }
}
