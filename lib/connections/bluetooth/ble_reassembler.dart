// Long-frame reassembly for APRS-over-BLE (generic transport framing — no app
// semantics). A compact frame that overflows one legacy advertisement carries
// its overflow in the active-scan response as manufacturer data prefixed with
// [0x3E '>' marker, 0x42 'B' continuation] + overflow bytes. This mirrors the
// ESP32 ble_hello / geogram_ble_aprs SCAN_RSP scheme so frames up to ~42 bytes
// work on every BLE platform.
//
// The advert and its scan response may surface together in one scan event
// (Android exposes both manufacturer entries) or one after another (BlueZ
// collapses duplicate company ids, so the scan response arrives as a separate
// property update). This class handles both: pure logic, no timers — the
// caller arms a short hold timer and calls [expire] when it fires.

import 'dart:typed_data';

/// Geogram marker byte ('>') prefixing presence/continuation manufacturer data.
/// A compact APRS frame has NO marker; a presence beacon has the marker with a
/// different second byte.
const int kBleMarker = 0x3E;

/// Continuation sub-type ('B'): manufacturer data is [0x3E, 0x42, overflow…].
const int kBleContSubtype = 0x42;

class BleReassembler {
  // Per-peer compact primary awaiting a continuation.
  final Map<String, Uint8List> _held = {};

  /// True while a primary for [from] is held waiting for its continuation.
  bool held(String from) => _held.containsKey(from);

  /// Feed the company-id manufacturer-data entries seen in one scan event from
  /// peer [from]. Returns the complete frames to deliver now (reassembled long
  /// frames, complete short frames, and any pass-through marked frames such as
  /// presence beacons). A compact primary with no continuation in this event is
  /// held (replacing — and emitting — any previously held one); an orphan
  /// continuation is dropped.
  List<Uint8List> ingest(String from, List<Uint8List> entries) {
    Uint8List? primary;
    Uint8List? cont;
    final out = <Uint8List>[];
    final others = <Uint8List>[];
    for (final d in entries) {
      if (d.isEmpty) continue;
      if (d.length >= 2 && d[0] == kBleMarker && d[1] == kBleContSubtype) {
        cont = d;
      } else if (d[0] != kBleMarker) {
        primary = d;
      } else {
        others.add(d);
      }
    }

    if (cont != null) {
      final head = primary ?? _held.remove(from);
      primary = null;
      if (head != null) out.add(_join(head, cont));
    }

    if (primary != null) {
      final old = _held.remove(from); // superseded — deliver it as a short frame
      if (old != null) out.add(old);
      _held[from] = primary;
    }

    out.addAll(others);
    return out;
  }

  /// The hold window elapsed with no continuation: deliver the held primary as
  /// a standalone (short) frame. Returns null if nothing was held.
  Uint8List? expire(String from) => _held.remove(from);

  static Uint8List _join(Uint8List head, Uint8List cont) {
    final overflow = cont.length - 2; // drop the [0x3E,0x42] header
    return Uint8List(head.length + overflow)
      ..setRange(0, head.length, head)
      ..setRange(head.length, head.length + overflow, cont, 2);
  }
}

// ── Broadcast-parcel reassembly (the <=300B connectionless transport) ──────
//
// A message is broadcast as N chunks; each chunk is one advertisement made of a
// primary field and (optionally) a scan-response continuation field, all under
// company id 0xFFFF and marker 0x3E:
//   PRIMARY (0x50): [0x3E,0x50, msgId, idx, total, flags, payload…]
//                   flags bit0 = this chunk also has a 0x51 continuation
//   CONT    (0x51): [0x3E,0x51, msgId, idx, payload…]   (extra bytes for chunk idx)
// (the bytes above are the manufacturer data with the 2-byte company id already
// stripped, i.e. what the scan API hands us). A receiver groups chunks by
// (source, msgId), reassembles when every chunk is present, delivers once, and
// dedups by (source,msgId) so the many repeats from the rotation/flood are not
// re-delivered. App-agnostic transport framing — no message semantics here.

const int kBleBcastPrimary = 0x50; // 'P'
const int kBleBcastCont = 0x51; // 'Q'

/// Largest payload sent over the connectionless broadcast transport; above this
/// the size router uses GATT point-to-point instead. Shared with the ESP32
/// (BCAST_MAX in ble_hello.c).
const int kBleBcastMax = 300;

/// Primary-chunk header length: [marker, subtype, msgId, idx, total, flags].
const int kBleBcastPrimaryHdr = 6;

/// Continuation-chunk header length: [marker, subtype, msgId, idx].
const int kBleBcastContHdr = 4;

/// Drop partials with no new chunk within this window. Must exceed the sender's
/// advert rotation interval so a partial survives across one full chunk cycle.
const Duration kBleBcastWindow = Duration(seconds: 5);

/// Suppress re-delivery of a (source,msgId) for this long after completion.
const Duration kBleBcastDedup = Duration(seconds: 30);

class _BcastPartial {
  final int total;
  final List<Uint8List?> primary; // per-chunk primary payload (header stripped)
  final List<Uint8List?> cont; // per-chunk continuation payload (or null)
  final List<bool> expectsCont; // chunk advertised a continuation
  DateTime updated;
  _BcastPartial(this.total)
      : primary = List<Uint8List?>.filled(total, null),
        cont = List<Uint8List?>.filled(total, null),
        expectsCont = List<bool>.filled(total, false),
        updated = DateTime.now();

  bool get complete {
    for (var i = 0; i < total; i++) {
      if (primary[i] == null) return false;
      if (expectsCont[i] && cont[i] == null) return false;
    }
    return true;
  }

  Uint8List assemble() {
    final b = BytesBuilder();
    for (var i = 0; i < total; i++) {
      b.add(primary[i]!);
      final c = cont[i];
      if (c != null) b.add(c);
    }
    return b.toBytes();
  }
}

class BleBroadcastReassembler {
  final Map<String, _BcastPartial> _partials = {};
  final Map<String, DateTime> _seen = {};

  static bool isChunk(Uint8List d) =>
      d.length >= 4 &&
      d[0] == kBleMarker &&
      (d[1] == kBleBcastPrimary || d[1] == kBleBcastCont);

  /// Feed one broadcast-chunk manufacturer-data entry. Returns the full payload
  /// exactly once when the message completes (and is not a duplicate), else null.
  Uint8List? ingest(String from, Uint8List data) {
    if (!isChunk(data)) return null;
    final sub = data[1];
    final msgId = data[2];
    final key = '$from|$msgId';

    final seenAt = _seen[key];
    if (seenAt != null && DateTime.now().difference(seenAt) < kBleBcastDedup) {
      return null; // already delivered this message
    }

    if (sub == kBleBcastPrimary) {
      if (data.length < 6) return null;
      final idx = data[3];
      final total = data[4];
      final flags = data[5];
      if (total == 0 || idx >= total) return null;
      final p = _partials.putIfAbsent(key, () => _BcastPartial(total));
      if (p.total != total) return null; // inconsistent header — ignore
      p.primary[idx] = Uint8List.fromList(data.sublist(6));
      p.expectsCont[idx] = (flags & 0x01) != 0;
      p.updated = DateTime.now();
    } else {
      final idx = data[3];
      final p = _partials[key];
      if (p == null || idx >= p.total) return null; // continuation before primary
      p.cont[idx] = Uint8List.fromList(data.sublist(4));
      p.updated = DateTime.now();
    }

    final p = _partials[key]!;
    if (p.complete) {
      _partials.remove(key);
      _seen[key] = DateTime.now();
      return p.assemble();
    }
    return null;
  }

  /// Drop stale partials and expired dedup entries. Call periodically.
  void sweep() {
    final now = DateTime.now();
    _partials.removeWhere((_, p) => now.difference(p.updated) > kBleBcastWindow);
    _seen.removeWhere((_, t) => now.difference(t) > kBleBcastDedup);
  }
}
