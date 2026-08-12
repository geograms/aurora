/*
 * xprs_monitor — what this device has heard on the air, kept so a person can
 * look at it.
 *
 * Passive and read-only. It decides nothing, transmits nothing and is on no
 * delivery path: the transport has already handled a packet by the time it
 * lands here. That is what keeps it on the right side of "transports are core"
 * — it observes, it does not route.
 *
 * Two things are exposed to a wapp (docs/XPRS.md section 10.6):
 *
 *   stations — who has been heard, over which bearer, how recently
 *   traffic  — the last few hundred packets, including the ones addressed to
 *              other people, which is most of what a mesh carries
 *
 * INTERNET TRAFFIC NEVER ENTERS THIS RING, and not by filtering it out later.
 * The bearer is recorded where the packet arrives, only radio and local
 * bearers call [offer], and [kBearers] refuses anything else. A packet that
 * came over a hub cannot be in here to be leaked by a caller who forgot.
 */
import 'dart:convert';

import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_vocab.dart';

/// Bearers a sighting may claim.
///
/// Deliberately a subset of the XPRS `link:` vocabulary: `internet` is absent,
/// because this is the record of what arrived over the air or over a local
/// network, and an entry claiming otherwise would make the whole view a lie.
const Set<String> kBearers = {'ble', 'lan', 'lora', 'wifi', 'vhf', 'uhf', 'hf'};

/// One packet, as heard.
class XprsSighting {
  final int tsMs;
  final String bearer;
  final int rssi;
  final String from;
  final String to;
  final String type;
  final String id;

  /// Whether `d:` named us. False for the traffic that is merely passing.
  final bool mine;
  final String wire;

  const XprsSighting({
    required this.tsMs,
    required this.bearer,
    required this.rssi,
    required this.from,
    required this.to,
    required this.type,
    required this.id,
    required this.mine,
    required this.wire,
  });

  Map<String, dynamic> toJson() => {
        'ts': tsMs ~/ 1000,
        'bearer': bearer,
        'rssi': rssi,
        'from': from,
        'to': to,
        'type': type,
        'id': id,
        'mine': mine,
        'wire': wire,
      };
}

/// A station we have heard, and the most recent thing it told us.
class XprsStation {
  XprsStation(this.callsign, this.bearer, this.firstMs)
      : lastMs = firstMs,
        packets = 0;

  final String callsign;
  String bearer;
  int firstMs;
  int lastMs;
  int packets;
  int rssi = 0;

  /// From the sender's last beacon (sections 10.6.4 and 10.6.5), when it sent
  /// one. Null means it has not said, which is different from zero.
  int? peers;
  int? mail;

  /// The sender's stability account (section 10.5), verbatim `qty` text like
  /// `26h` / `38day`. A claim, not a measurement — shown as said.
  String? uptime;
  String? lifetime;
}

class XprsMonitor {
  XprsMonitor._();
  static final XprsMonitor instance = XprsMonitor._();

  /// How many sightings are kept. A few hundred is a couple of minutes of a
  /// busy street, which is what a person looking at a live trace wants; the
  /// point of this view is what is happening now.
  static const int ringMax = 200;

  /// A station stops being listed after this long without a packet. Longer
  /// than the slowest beacon interval (5 minutes at the saturated politeness
  /// tier) so a quiet-but-present station does not flicker out.
  static const Duration staleAfter = Duration(minutes: 11);

  final List<XprsSighting> _ring = [];
  final Map<String, XprsStation> _stations = {};

  /// Bumped whenever something changed, so a wapp can skip a redraw. Same
  /// trick `MeshService.revision` uses.
  int revision = 0;

  List<XprsSighting> get ring => List.unmodifiable(_ring);
  Map<String, XprsStation> get stations => Map.unmodifiable(_stations);

  /// Record a packet that arrived over [bearer].
  ///
  /// Silently ignores a bearer outside [kBearers] — including `internet`. A
  /// caller that gets this wrong loses the sighting rather than putting a
  /// misleading one in front of somebody.
  void offer(
    XprsPacket p, {
    required String bearer,
    required String selfCallsign,
    int rssi = 0,
    int? nowMs,
  }) {
    if (!kBearers.contains(bearer)) return;
    final from = (p['f'] ?? '').trim().toUpperCase();
    if (from.isEmpty) return;
    final self = selfCallsign.trim().toUpperCase();
    if (from == self) return; // our own packet, heard back

    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final to = (p['d'] ?? '').trim().toUpperCase();

    _ring.add(XprsSighting(
      tsMs: now,
      bearer: bearer,
      rssi: rssi,
      from: from,
      to: to,
      type: p.type,
      id: xprsIdentifier(p),
      mine: to.isNotEmpty && to == self,
      wire: p.encode(),
    ));
    if (_ring.length > ringMax) _ring.removeRange(0, _ring.length - ringMax);

    final st = _stations.putIfAbsent(from, () => XprsStation(from, bearer, now));
    st.bearer = bearer;
    st.lastMs = now;
    st.rssi = rssi;
    st.packets++;
    // A beacon says how many it can reach and whether it is holding mail; an
    // ordinary message says neither, and must not erase what the beacon said.
    final peers = xprsPeers(p);
    if (peers != null) st.peers = peers;
    if (p.has('mail')) st.mail = xprsMail(p);
    if (p.has('uptime')) st.uptime = p['uptime'];
    if (p.has('lifetime')) st.lifetime = p['lifetime'];

    revision++;
  }

  /// Drop stations that have gone quiet. Called before rendering.
  void sweep({int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final before = _stations.length;
    _stations.removeWhere((_, s) => now - s.lastMs > staleAfter.inMilliseconds);
    if (_stations.length != before) revision++;
  }

  void clear() {
    _ring.clear();
    _stations.clear();
    revision++;
  }

  /// The stations, shaped as people-widget sections so the wapp renders them
  /// without parsing — the same contract `hal_mesh_devices` uses.
  String stationsJson({int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    sweep(nowMs: now);
    final list = _stations.values.toList()
      ..sort((a, b) => b.lastMs.compareTo(a.lastMs));

    final items = list.map((s) {
      final tags = <String>[
        _ago(now - s.lastMs),
        s.bearer.toUpperCase(),
        if (s.peers != null) 'peers ${s.peers}',
        if (s.mail != null && s.mail! > 0) 'mail ${s.mail}',
        if (s.uptime != null) 'up ${s.uptime}',
        if (s.lifetime != null) 'life ${s.lifetime}',
      ];
      final sub = StringBuffer(s.bearer.toUpperCase());
      if (s.rssi != 0) sub.write(' - ${s.rssi} dBm');
      sub.write(' - ${s.packets} packet${s.packets == 1 ? "" : "s"}');
      return {
        'id': s.callsign,
        'title': s.callsign,
        'subtitle': sub.toString(),
        'tags': tags,
      };
    }).toList();

    return jsonEncode([
      {'title': 'Heard over the air (${items.length})', 'items': items}
    ]);
  }

  /// The ring, oldest first, as the wapp's traffic log.
  String trafficJson() => jsonEncode(_ring.map((s) => s.toJson()).toList());

  /// Counters for `/api/status`, so this is checkable without a wapp.
  Map<String, dynamic> statusJson() => {
        'revision': revision,
        'stations': _stations.length,
        'sightings': _ring.length,
        'bearers': {
          for (final b in kBearers)
            if (_stations.values.any((s) => s.bearer == b))
              b: _stations.values.where((s) => s.bearer == b).length,
        },
      };

  static String _ago(int ms) {
    final s = ms ~/ 1000;
    if (s < 60) return 'seen ${s}s ago';
    if (s < 3600) return 'seen ${s ~/ 60}m ago';
    return 'seen ${s ~/ 3600}h ago';
  }
}
