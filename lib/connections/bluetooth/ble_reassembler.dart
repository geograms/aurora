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
//   PRIMARY (0x50): [0x3E,0x50, srcTag, msgId, idx, total, flags, payload…]
//                   flags bit0 = this chunk also has a 0x51 continuation
//   CONT    (0x51): [0x3E,0x51, srcTag, msgId, idx, payload…] (extra bytes, idx)
//   NACK    (0x52): [0x3E,0x52, srcTag, msgId, total, bmStart, bitmap…]
// (the bytes above are the manufacturer data with the 2-byte company id already
// stripped, i.e. what the scan API hands us). A receiver groups chunks by
// (source, msgId), reassembles when every chunk is present, delivers once, and
// dedups by (source,msgId) so the many repeats from the rotation/flood are not
// re-delivered. App-agnostic transport framing — no message semantics here.
//
// Reliability: the broadcast channel is one-way (advertising), so a receiver
// that catches only some chunks of a multi-chunk message cannot otherwise
// recover the rest — Android scanners batch their scans, so a single burst sees
// only a subset. The NACK (0x52) frame is the return channel: a receiver with a
// stalled partial advertises a NACK listing the chunk indices it is still
// missing (as a bitmap), keyed by the sender's [srcTag] and the [msgId]. The
// sender hears its own srcTag, re-airs exactly those chunks, and the partial
// completes. This is selective-repeat ARQ over connectionless advertising.
//
// [srcTag] is an opaque 1-byte sender discriminator (low byte of a hash of the
// sender's stable identity) so that, with several senders broadcasting at once,
// only the intended sender re-airs in response to a NACK.

const int kBleBcastPrimary = 0x50; // 'P'
const int kBleBcastCont = 0x51; // 'Q'
const int kBleBcastNack = 0x52; // 'R' — receiver→sender resend request

/// Largest payload sent over the connectionless broadcast transport; above this
/// the size router uses GATT point-to-point instead. Shared with the ESP32
/// (BCAST_MAX in ble_hello.c).
const int kBleBcastMax = 300;

/// Primary-chunk header length: [marker, subtype, srcTag, msgId, idx, total, flags].
const int kBleBcastPrimaryHdr = 7;

/// Continuation-chunk header length: [marker, subtype, srcTag, msgId, idx].
const int kBleBcastContHdr = 5;

/// NACK header length: [marker, subtype, srcTag, msgId, total, bmStart].
const int kBleBcastNackHdr = 6;

/// Drop incomplete multi-chunk partials with no new chunk within this window.
/// Android receivers scan in sparse bursts (tens of seconds to ~2 min apart), so
/// the two chunks of a small message can be caught in DIFFERENT bursts — the
/// partial must survive across those gaps or multi-chunk messages never
/// reassemble (single-chunk beacons complete instantly and were the only thing
/// getting through). Sized to span the sender's on-air time (~120 s), within the
/// dedup window so a completed message still delivers once.
const Duration kBleBcastWindow = Duration(seconds: 120);

/// Suppress re-delivery of a (source,msgId) for this long after completion.
/// Must exceed a sender's longest chunk air time (the ESP32 keeps an important
/// message — ?MAIL reply / 1:1 mail — on air up to BCH_TTL_MSG=120s so a phone
/// whose BLE stack scans only sporadically still collects every chunk); without
/// this, the same re-aired message would be delivered repeatedly.
const Duration kBleBcastDedup = Duration(seconds: 130);

/// A receiver's request for a sender to re-air missing chunks of one message.
class NackRequest {
  final int srcTag;
  final int msgId;
  final int total;
  final List<int> missing;
  const NackRequest(this.srcTag, this.msgId, this.total, this.missing);
}

class _BcastPartial {
  final int total;
  final List<Uint8List?> primary; // per-chunk primary payload (header stripped)
  final List<Uint8List?> cont; // per-chunk continuation payload (or null)
  final List<bool> expectsCont; // chunk advertised a continuation
  int? srcTag; // sender discriminator, captured from the first primary chunk
  int msgId = 0; // the 1-byte message id these chunks belong to
  int nackCount = 0; // resend requests already emitted for this partial
  DateTime? lastNackAt; // when the last NACK was emitted (for backoff)
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

  /// Chunk indices still missing (primary not seen, or an expected continuation
  /// not seen). What a NACK asks the sender to re-air.
  List<int> missingIndices() {
    final out = <int>[];
    for (var i = 0; i < total; i++) {
      if (primary[i] == null || (expectsCont[i] && cont[i] == null)) out.add(i);
    }
    return out;
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
      d.length >= 5 &&
      d[0] == kBleMarker &&
      (d[1] == kBleBcastPrimary || d[1] == kBleBcastCont);

  /// True for a 0x52 resend-request frame. A NACK must NOT be treated as a data
  /// chunk by [isChunk] / [ingest].
  static bool isNack(Uint8List d) =>
      d.length >= kBleBcastNackHdr &&
      d[0] == kBleMarker &&
      d[1] == kBleBcastNack;

  /// Parse a 0x52 frame into a request, or null if malformed. The bitmap is
  /// LSB-first: bit k set ⇒ chunk index (bmStart + k) is missing.
  static NackRequest? parseNack(Uint8List d) {
    if (!isNack(d)) return null;
    final srcTag = d[2];
    final msgId = d[3];
    final total = d[4];
    final bmStart = d[5];
    final missing = <int>[];
    for (var b = kBleBcastNackHdr; b < d.length; b++) {
      final byte = d[b];
      for (var bit = 0; bit < 8; bit++) {
        if (byte & (1 << bit) != 0) {
          final idx = bmStart + (b - kBleBcastNackHdr) * 8 + bit;
          if (idx < total) missing.add(idx);
        }
      }
    }
    if (missing.isEmpty) return null;
    return NackRequest(srcTag, msgId, total, missing);
  }

  /// Build a 0x52 frame requesting [missing] chunk indices of message [msgId]
  /// from sender [srcTag]. Returns null if nothing is missing. bmStart is the
  /// lowest missing index so the bitmap stays compact for high indices.
  static Uint8List? buildNack(
      int srcTag, int msgId, int total, List<int> missing) {
    if (missing.isEmpty) return null;
    final bmStart = missing.reduce((a, b) => a < b ? a : b);
    final maxIdx = missing.reduce((a, b) => a > b ? a : b);
    final bytes = (maxIdx - bmStart) ~/ 8 + 1;
    final out = Uint8List(kBleBcastNackHdr + bytes);
    out[0] = kBleMarker;
    out[1] = kBleBcastNack;
    out[2] = srcTag & 0xFF;
    out[3] = msgId & 0xFF;
    out[4] = total & 0xFF;
    out[5] = bmStart & 0xFF;
    for (final idx in missing) {
      final off = idx - bmStart;
      out[kBleBcastNackHdr + off ~/ 8] |= 1 << (off % 8);
    }
    return out;
  }

  /// Feed one broadcast-chunk manufacturer-data entry. Returns the full payload
  /// exactly once when the message completes (and is not a duplicate), else null.
  Uint8List? ingest(String from, Uint8List data) {
    if (!isChunk(data)) return null;
    final sub = data[1];
    final srcTag = data[2];
    final msgId = data[3];
    final key = '$from|$msgId';

    final seenAt = _seen[key];
    if (seenAt != null && DateTime.now().difference(seenAt) < kBleBcastDedup) {
      return null; // already delivered this message
    }

    if (sub == kBleBcastPrimary) {
      if (data.length < kBleBcastPrimaryHdr) return null;
      final idx = data[4];
      final total = data[5];
      final flags = data[6];
      if (total == 0 || idx >= total) return null;
      final p = _partials.putIfAbsent(key, () => _BcastPartial(total));
      if (p.total != total) return null; // inconsistent header — ignore
      p.srcTag = srcTag;
      p.msgId = msgId;
      p.primary[idx] = Uint8List.fromList(data.sublist(kBleBcastPrimaryHdr));
      p.expectsCont[idx] = (flags & 0x01) != 0;
      p.updated = DateTime.now();
    } else {
      if (data.length < kBleBcastContHdr) return null;
      final idx = data[4];
      final p = _partials[key];
      if (p == null || idx >= p.total) return null; // continuation before primary
      p.srcTag ??= srcTag;
      p.msgId = msgId;
      p.cont[idx] = Uint8List.fromList(data.sublist(kBleBcastContHdr));
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

  /// Incomplete partials that warrant a resend request now: idle for at least
  /// [idle], under the [maxRetries] cap, and past a growing backoff since the
  /// last NACK. The caller emits each NACK and then calls [markNacked].
  List<NackRequest> partialsNeedingNack(
      {required Duration idle, required int maxRetries}) {
    final now = DateTime.now();
    final out = <NackRequest>[];
    _partials.forEach((_, p) {
      if (p.srcTag == null) return; // never saw a primary → can't address sender
      if (p.complete) return;
      if (now.difference(p.updated) < idle) return; // still receiving
      if (p.nackCount >= maxRetries) return;
      final last = p.lastNackAt;
      // Backoff grows with each retry: idle, 2×idle, 3×idle, …
      if (last != null && now.difference(last) < idle * (p.nackCount + 1)) {
        return;
      }
      final missing = p.missingIndices();
      if (missing.isEmpty) return;
      out.add(NackRequest(p.srcTag!, p.msgId, p.total, missing));
    });
    return out;
  }

  /// Record that a NACK was emitted for partials of sender [srcTag] / [msgId].
  void markNacked(int srcTag, int msgId) {
    final now = DateTime.now();
    _partials.forEach((_, p) {
      if (p.srcTag == srcTag && p.msgId == msgId) {
        p.nackCount++;
        p.lastNackAt = now;
      }
    });
  }

  /// Drop stale partials and expired dedup entries. Call periodically.
  void sweep() {
    final now = DateTime.now();
    _partials.removeWhere((_, p) => now.difference(p.updated) > kBleBcastWindow);
    _seen.removeWhere((_, t) => now.difference(t) > kBleBcastDedup);
  }
}
