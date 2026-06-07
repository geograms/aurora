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
