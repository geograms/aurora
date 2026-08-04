// Splitting one Reticulum packet across several BLE adverts, and putting it
// back together.
//
// A BLE 5 extended advert carries whatever THIS controller allows — often
// ~230 B, sometimes less — while an RNS announce with app_data runs to 250 B
// and more. The BLE5 radio is broadcast-only, so an over-cap packet had no path
// at all: it was counted, logged and dropped, which is why two devices with
// nothing but Bluetooth between them never heard each other's announces.
//
// Fragments ride their OWN advert subtype (Ble5Subtype.rnsChunk), so a fragment
// can never be mistaken for a whole packet, and never reaches the APRS
// reassembler — that one speaks different framing entirely.
//
// Wire format, per fragment:
//   [0] msgId   sender-chosen, wraps at 256 — groups fragments of one packet
//   [1] idx     0-based fragment index
//   [2] total   fragment count (1..255)
//   [3..] payload slice
//
// There is no retransmit: an announce is periodic by nature, so the next one
// repairs a loss. Incomplete sets are dropped after [kRnsChunkTtl] rather than
// held forever.
import 'dart:typed_data';

/// Bytes of framing each fragment costs.
const int kRnsChunkHeader = 3;

/// How long an incomplete fragment set is kept before it is abandoned.
const Duration kRnsChunkTtl = Duration(seconds: 20);

/// Most fragments one packet may be split into (255 is the wire limit; this is
/// the sanity bound — 32 fragments of ~230 B is already 7 kB, far past
/// anything that belongs on an advertising channel).
const int kRnsChunkMaxParts = 32;

/// Split [packet] into fragments that each fit [cap] bytes INCLUDING framing.
/// Returns an empty list when the packet cannot fit [kRnsChunkMaxParts]
/// fragments (the caller should then use a point-to-point path or drop).
List<Uint8List> rnsChunkSplit(Uint8List packet, int cap, int msgId) {
  final room = cap - kRnsChunkHeader;
  if (room < 1) return const [];
  final total = (packet.length + room - 1) ~/ room;
  if (total < 1 || total > kRnsChunkMaxParts) return const [];
  final out = <Uint8List>[];
  for (var i = 0; i < total; i++) {
    final start = i * room;
    final end = (start + room < packet.length) ? start + room : packet.length;
    final frag = Uint8List(kRnsChunkHeader + (end - start))
      ..[0] = msgId & 0xFF
      ..[1] = i
      ..[2] = total
      ..setRange(kRnsChunkHeader, kRnsChunkHeader + (end - start), packet,
          start);
    out.add(frag);
  }
  return out;
}

/// Collects fragments until a packet is whole.
///
/// Keyed by sender address AND msgId: two devices in range can be mid-packet at
/// the same time with the same id, and merging their fragments would produce
/// garbage that fails RNS's own integrity checks — silently, and only under
/// load, which is the worst way to find a bug.
class RnsChunkAssembler {
  RnsChunkAssembler({this.now = _wallClock});

  /// Injectable clock so the TTL is testable without waiting.
  final DateTime Function() now;
  static DateTime _wallClock() => DateTime.now();

  final Map<String, _Partial> _partials = {};

  /// Feed one inbound fragment. Returns the complete packet when [frag]
  /// finished it, else null. Non-fragment or malformed input returns null.
  Uint8List? accept(String from, Uint8List frag) {
    if (frag.length <= kRnsChunkHeader) return null;
    final msgId = frag[0];
    final idx = frag[1];
    final total = frag[2];
    if (total < 1 || total > kRnsChunkMaxParts || idx >= total) return null;
    _sweep();
    final key = '$from/$msgId/$total';
    final p = _partials.putIfAbsent(key, () => _Partial(total, now()));
    p.parts[idx] = Uint8List.sublistView(frag, kRnsChunkHeader);
    if (p.parts.length < total) return null;
    _partials.remove(key);
    final size = p.parts.values.fold<int>(0, (a, b) => a + b.length);
    final out = Uint8List(size);
    var off = 0;
    for (var i = 0; i < total; i++) {
      final part = p.parts[i]!;
      out.setRange(off, off + part.length, part);
      off += part.length;
    }
    return out;
  }

  /// Fragment sets still waiting for the rest (diagnostics).
  int get pending => _partials.length;

  void _sweep() {
    if (_partials.isEmpty) return;
    final cutoff = now().subtract(kRnsChunkTtl);
    _partials.removeWhere((_, p) => p.startedAt.isBefore(cutoff));
  }
}

class _Partial {
  _Partial(this.total, this.startedAt);
  final int total;
  final DateTime startedAt;
  final Map<int, Uint8List> parts = {};
}
