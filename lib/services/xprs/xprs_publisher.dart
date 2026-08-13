/// Publishing an XPRS packet on every bearer this device has.
///
/// The one place that answers "which transports, right now" — a wapp hands the
/// core CONTENT (`hal_xprs_status`) and this service decides where it travels
/// (docs/architecture.md rule 1: transports are core; a wapp never chooses a
/// radio). Today that is BLE5 extended advertising and a Reticulum broadcast;
/// LoRa holds a visible slot that activates the day the radio exists.
///
/// `scope:` (docs/XPRS.md section 13.11) gates reach: a `local` packet stays
/// on the short-range bearers, a country scope is not gatewayed by a node
/// that cannot place itself, and the default — global — goes everywhere
/// active, which is geogram's stated behaviour.
///
/// Long content splits into section 6.6 parts (at most nine, split only at
/// spaces, same `ts:` throughout) and the signature covers the REASSEMBLED
/// packet, riding the last part (sections 9.1.1 and 25.5). No profile key →
/// transmit unsigned, which the spec permits and the log states.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../connections/bluetooth/ble5_bus.dart';
import '../../connections/lora/lora_connection.dart';
import '../../connections/connection.dart';
import '../../profile/profile_service.dart';
import '../log_service.dart';
import '../reticulum/rns_service.dart';
import 'xprs_packet.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart';

/// One way bytes can leave this device.
///
/// Deliberately tiny: the publisher asks two questions — are you on, and did
/// you take it — and applies the scope rules itself so every future bearer
/// (LoRa, a KISS TNC, WiFi Aware) inherits them by construction.
abstract class XprsBearer {
  String get name;

  /// Whether a `scope:local` packet may use this bearer (section 13.11.1:
  /// local names the short-range bearers, not a distance).
  bool get shortRange;

  Future<bool> get active;

  /// Transmit one wire. [part] distinguishes the parts of a split packet so
  /// an advert-style bearer can rotate them under distinct keys.
  Future<bool> send(String wire, {required int part});
}

class _Ble5Bearer implements XprsBearer {
  @override
  String get name => 'ble5';
  @override
  bool get shortRange => true;
  @override
  Future<bool> get active => Ble5Bus.instance.supported();
  @override
  Future<bool> send(String wire, {required int part}) =>
      Ble5Bus.instance.advertiseFrame(
        'xprs-status:$part',
        Ble5Subtype.xprs,
        Uint8List.fromList(utf8.encode(wire)),
        // Long enough to span a receiver's duty-cycled scan burst — the same
        // rationale hal_ble_advertise documents for its 120 s.
        ttl: const Duration(seconds: 120),
      );
}

class _ReticulumBearer implements XprsBearer {
  @override
  String get name => 'reticulum';
  @override
  bool get shortRange => false;
  @override
  Future<bool> get active async => RnsService.instance.isUp;
  @override
  Future<bool> send(String wire, {required int part}) =>
      RnsService.instance.wappBroadcast(
          'xprs', Uint8List.fromList(utf8.encode(wire)));
}

class _LoraBearer implements XprsBearer {
  // The slot the user asked to see: when a LoRa radio ships, its connection
  // reports available and statuses start riding it with no publisher change.
  final LoraConnection _lora = LoraConnection();
  @override
  String get name => 'lora';
  @override
  bool get shortRange => true;
  @override
  Future<bool> get active async =>
      _lora.status == ConnectionStatus.available;
  @override
  Future<bool> send(String wire, {required int part}) async => false;
}

class XprsPublisher {
  XprsPublisher._();
  static final XprsPublisher instance = XprsPublisher._();

  /// Replaceable for tests; order is presentation only (every active bearer
  /// is used).
  List<XprsBearer> bearers = [_Ble5Bearer(), _ReticulumBearer(), _LoraBearer()];

  int published = 0;
  int refused = 0;

  /// Publish a `t:status` (section 27). Returns per-bearer outcomes:
  /// 'sent' | 'refused' | 'inactive' | 'scope' — empty map when nothing
  /// could be published at all (no profile, empty text).
  Future<Map<String, String>> publishStatus(String text,
      {String? mood, String? scope}) async {
    final body = text.trim();
    final call =
        (ProfileService.instance.activeProfile?.callsign ?? '').trim();
    if (body.isEmpty || call.isEmpty) {
      refused++;
      LogService.instance.add(
          'XPRS: status not published — ${body.isEmpty ? "empty" : "no profile callsign yet"}');
      return const {};
    }

    final now = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${now.year}-${two(now.month)}-${two(now.day)}_'
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';

    var head = 't:status f:${call.toUpperCase()} ts:$ts';
    if (mood != null && mood.trim().isNotEmpty) {
      head += ' mood:${mood.trim().toLowerCase()}';
    }
    if (scope != null && scope.trim().isNotEmpty) {
      head += ' scope:${scope.trim()}';
    }

    final wires = _wires(head, body);
    if (wires.isEmpty) {
      refused++;
      return const {};
    }

    final p0 = XprsPacket.parse(wires.first);
    final local = p0 != null && xprsScope(p0).scope != XprsScope.global;

    final report = <String, String>{};
    for (final b in bearers) {
      if (local && !b.shortRange) {
        // A local packet never leaves the short-range bearers (13.11.1), and
        // a node that cannot place itself does not gateway a country scope
        // (13.11.3) — both land here.
        report[b.name] = 'scope';
        continue;
      }
      if (!await b.active) {
        report[b.name] = 'inactive';
        continue;
      }
      var ok = true;
      for (var i = 0; i < wires.length; i++) {
        ok = await b.send(wires[i], part: i + 1) && ok;
      }
      report[b.name] = ok ? 'sent' : 'refused';
    }

    published++;
    LogService.instance.add('XPRS: status (${wires.length} part'
        '${wires.length == 1 ? "" : "s"}) — ${report.entries.map((e) => "${e.key}:${e.value}").join(", ")}');
    return report;
  }

  /// Test seam: exactly the wires [publishStatus] would air for [head] and
  /// [body], with [signingKey] standing in for the profile key (a unit test
  /// has no profile).
  List<String> debugWires(String head, String body, {BigInt? signingKey}) =>
      _wires(head, body, signingKey: signingKey);

  /// The wires to air: one signed packet when it fits, else section 6.6
  /// parts with the reassembled packet's signature on the last (9.1.1).
  List<String> _wires(String head, String body, {BigInt? signingKey}) {
    final d = signingKey ?? xprsProfileScalar();

    XprsPacket? make(String m) => XprsPacket.parse('$head m:$m');

    // The unsplit packet, signed, when it fits.
    final whole = make(body);
    if (whole == null) return const [];
    final signedWhole = d != null ? xprsSign(whole, d) : whole;
    if (signedWhole.fits) return [signedWhole.encode()];

    // Split at spaces only (6.6). Every part reserves room for `n:i/9` AND
    // the signature, so whichever part ends up last still fits after the
    // sig is attached — a uniform budget beats a two-pass fit.
    final probe = make('')!.with_('n', '9/9').with_('sig', 'x' * 60);
    final capacity = XprsPacket.maxBytes - probe.byteLength;
    if (capacity <= 0) return const [];

    final chunks = <String>[];
    var current = StringBuffer();
    for (final word in body.split(' ')) {
      var w = word;
      // A word longer than a whole part (a monster URL) has no space to
      // split at; hard-cut it rather than lose everything after it.
      while (utf8.encode(w).length > capacity) {
        chunks.add(w.substring(0, capacity));
        w = w.substring(capacity);
      }
      final trial = current.isEmpty ? w : '$current $w';
      if (utf8.encode(trial).length > capacity) {
        if (current.isNotEmpty) chunks.add(current.toString());
        current = StringBuffer(w);
      } else {
        current = StringBuffer(trial);
      }
    }
    if (current.isNotEmpty) chunks.add(current.toString());

    if (chunks.length > 9) {
      // Nine parts is the format's ceiling (6.6); content past it is a
      // document, and a status is not one. Cut and say so.
      LogService.instance.add(
          'XPRS: status longer than nine parts — cut at part 9');
      chunks.removeRange(9, chunks.length);
    }

    // The signature covers the REASSEMBLED packet: joined m:, no n:.
    final joined = make(chunks.join(' '))!;
    final sig = d != null ? xprsSign(joined, d)['sig'] : null;

    final n = chunks.length;
    final out = <String>[];
    for (var i = 0; i < n; i++) {
      var part = make(chunks[i])!.with_('n', '${i + 1}/$n');
      if (i == n - 1 && sig != null) part = part.with_('sig', sig);
      out.add(part.encode());
    }
    return out;
  }
}
