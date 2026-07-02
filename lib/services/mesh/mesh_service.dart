/*
 * mesh_service — the BLE street-mesh node (doc/mesh.md, milestone M1).
 *
 * Owns the mesh control plane: builds and airs this node's route beacon on
 * the shared BLE5 extended-advert bus (subtype 0x4D) and ingests neighbors'
 * beacons into the distance-vector table. M1 scope: see the street — no data
 * plane yet (custody transfer/SCF land in M2, politeness/scoring in M3).
 *
 * Beacon cadence: a fixed base interval, plus one early "triggered update"
 * (debounced) when the table reports a topology change, so 2-hop routes
 * converge in seconds instead of a full beacon period. Scan-only devices
 * (no extended advertising, e.g. C61) run everything except the transmit —
 * they are leaves: they see the street but the street can't route via them.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:battery_plus/battery_plus.dart';

import '../../connections/bluetooth/ble5_bus.dart';
import '../../profile/profile_service.dart';
import '../log_service.dart';
import 'mesh_beacon.dart';
import 'mesh_table.dart';

class MeshService {
  MeshService._();
  static final MeshService instance = MeshService._();

  static const Duration _beaconInterval = Duration(seconds: 30);
  static const Duration _beaconTtl = Duration(seconds: 70);
  static const Duration _triggerDebounce = Duration(seconds: 4);

  final DateTime _startedAt = DateTime.now();
  final Battery _battery = Battery();

  MeshTable? _table;
  bool _canAdvertise = false;
  bool _running = false;
  Timer? _beaconTimer;
  Timer? _sweepTimer;
  Timer? _triggerTimer;
  bool _powered = false;
  int _beaconsSent = 0, _beaconsHeard = 0;

  bool get isRunning => _running;

  /// Bump-on-change revision so UI layers can cheaply poll for updates.
  int revision = 0;

  /// Start the mesh node. Idempotent; safe to call again when the profile
  /// (callsign) changes — the table is rebuilt for the new identity.
  Timer? _startRetry;

  Future<void> start({required bool canAdvertise}) async {
    final cs = (ProfileService.instance.activeProfile?.callsign ?? '').trim();
    if (cs.isEmpty) {
      // BLE can come up before the profile finishes loading on slow devices —
      // a silent no-op here would leave the mesh dead for the whole session.
      _startRetry ??= Timer(const Duration(seconds: 10), () {
        _startRetry = null;
        // ignore: discarded_futures
        start(canAdvertise: canAdvertise);
      });
      return;
    }
    if (_running && _table?.selfCallsign == cs) {
      _canAdvertise = canAdvertise || _canAdvertise;
      return;
    }
    _table = MeshTable(cs);
    _canAdvertise = canAdvertise;
    _running = true;

    Ble5Bus.instance.onFrame(Ble5Subtype.mesh, _onFrame);
    // Leaves listen too: extended SCANNING is a separate controller capability
    // from extended advertising, so a phone that can't beacon (e.g. C61) may
    // still hear the street. Idempotent; harmless where unsupported.
    try {
      await Ble5Bus.instance.startScan();
    } catch (_) {}

    _beaconTimer?.cancel();
    _beaconTimer = Timer.periodic(_beaconInterval, (_) => _sendBeacon());
    _sweepTimer?.cancel();
    _sweepTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (_table?.sweep() ?? false) revision++;
    });

    // Track power state for the cond byte (desktops report `unknown` = mains).
    try {
      final st = await _battery.batteryState;
      _powered = st != BatteryState.discharging;
      _battery.onBatteryStateChanged.listen((st) {
        _powered = st != BatteryState.discharging;
      });
    } catch (_) {
      _powered = true; // no battery API → assume powered (desktop)
    }

    await _sendBeacon();
    LogService.instance.add(
        'Mesh: started as $cs (${_canAdvertise ? "relay-capable" : "scan-only leaf"})');
  }

  void _onFrame(Ble5Frame f) {
    final t = _table;
    if (t == null) return;
    final b = MeshBeacon.decode(f.data);
    if (b == null) return;
    _beaconsHeard++;
    final isNew = !t.neighbors.containsKey(b.callsign);
    final changed = t.ingest(b, rssi: f.rssi);
    if (isNew && t.neighbors.containsKey(b.callsign)) {
      LogService.instance.add(
          'Mesh: heard ${b.callsign} (${b.deviceClass.label}, ${f.rssi} dBm, reaches ${b.dv.length})');
    }
    revision++;
    if (changed && _canAdvertise) {
      // Triggered update: topology changed — beacon early (debounced) so the
      // street converges fast, without letting a beacon storm feed itself.
      _triggerTimer ??= Timer(_triggerDebounce, () {
        _triggerTimer = null;
        _sendBeacon();
      });
    }
  }

  MeshDeviceClass _deviceClass() {
    if (Platform.isAndroid || Platform.isIOS) return MeshDeviceClass.phone;
    return MeshDeviceClass.computer;
  }

  Future<void> _sendBeacon() async {
    final t = _table;
    if (t == null || !_canAdvertise) return;
    final beacon = MeshBeacon(
      callsign: t.selfCallsign,
      deviceClass: _deviceClass(),
      cond: MeshConditions(
        powered: _powered,
        uptimeBucket:
            MeshConditions.bucketForUptime(DateTime.now().difference(_startedAt)),
        mobility: MeshMobility.unknown,
        storageBucket: 3,
      ),
      dv: t.exportDv(),
    );
    // Fit THIS controller's advert ceiling (often ~247 B, not the 450 B spec
    // default) — an over-cap frame is rejected outright, so trim the DV digest
    // (freshest neighbors were exported first) until the beacon fits.
    var bytes = beacon.encode();
    final cap = Ble5Bus.instance.maxPayload;
    var dv = beacon.dv;
    while (bytes.length > cap && dv.isNotEmpty) {
      dv = dv.sublist(0, dv.length - 1);
      bytes = MeshBeacon(
              callsign: beacon.callsign,
              deviceClass: beacon.deviceClass,
              cond: beacon.cond,
              dv: dv)
          .encode();
    }
    try {
      await Ble5Bus.instance
          .advertiseFrame('mesh', Ble5Subtype.mesh, bytes, ttl: _beaconTtl);
      _beaconsSent++;
    } catch (e) {
      LogService.instance.add('Mesh: beacon tx failed: $e');
    }
  }

  /// Devices snapshot as `people`-widget sections (consumed verbatim by the
  /// Bluetooth wapp via ui.people.set, same pattern as hal_rns_nodes → graph).
  String peopleSectionsJson() {
    final t = _table;
    final now = DateTime.now();
    if (t == null) {
      return jsonEncode([
        {
          'title': 'Nearby',
          'items': [],
        }
      ]);
    }
    String ago(DateTime d) {
      final s = now.difference(d).inSeconds;
      if (s < 60) return '${s}s';
      if (s < 3600) return '${s ~/ 60}m';
      return '${s ~/ 3600}h';
    }

    final ns = t.neighbors.values.toList()
      ..sort((a, b) => b.lastHeard.compareTo(a.lastHeard));
    final neighborItems = [
      for (final n in ns)
        {
          // ASCII only: multibyte glyphs get mangled on the wapp round-trip.
          'id': n.callsign,
          'title': n.callsign,
          'subtitle':
              '${n.deviceClass.label} - ${n.bidirectional ? "link 2-way" : "link one-way"}'
              ' - ${n.lastRssi} dBm - heard ${ago(n.lastHeard)} ago'
              ' - contact ${(n.contactRatio * 100).round()}%',
          'tags': [
            'seen ${ago(n.lastHeard)} ago',
            n.deviceClass.label,
            if (n.cond.powered) 'powered',
            'up ${MeshConditions.uptimeLabels[n.cond.uptimeBucket]}',
            '1 hop',
            'reaches ${n.digest.length}',
          ],
          'buttons': [
            {'icon': 'mail', 'action': 'message', 'tip': 'Send message'}
          ],
        }
    ];

    final rs = t.routes.values.toList()..sort((a, b) => a.cost.compareTo(b.cost));
    final routeItems = [
      for (final r in rs)
        if (!t.neighbors.values.any((n) => meshHashHex(n.hash) == r.destHashHex))
          {
            'id': t.names[r.destHashHex] ?? r.destHashHex,
            'title': t.names[r.destHashHex] ?? '#${r.destHashHex}',
            'subtitle': 'via ${r.viaCallsign} - ${r.cost} hops',
            'tags': [
              'seen ${ago(r.updated)} ago',
              '${r.cost} hops',
              'via ${r.viaCallsign}'
            ],
            // Envelope only when the destination's callsign is known (a bare
            // routing hash can't address a conversation).
            if (t.names.containsKey(r.destHashHex))
              'buttons': [
                {'icon': 'mail', 'action': 'message', 'tip': 'Send message'}
              ],
          }
    ];

    // The people widget appends its own per-section counts to the tab titles.
    return jsonEncode([
      {'title': 'Nearby', 'items': neighborItems},
      {'title': 'Multi-hop', 'items': routeItems},
    ]);
  }

  /// Node status for the wapp header/log.
  String statusJson() {
    final t = _table;
    return jsonEncode({
      'running': _running,
      'callsign': t?.selfCallsign ?? '',
      'advertising': _canAdvertise,
      'class': _deviceClass().label,
      'powered': _powered,
      'uptime': DateTime.now().difference(_startedAt).inSeconds,
      'neighbors': t?.neighbors.length ?? 0,
      'routes': t?.routes.length ?? 0,
      'beaconsSent': _beaconsSent,
      'beaconsHeard': _beaconsHeard,
      'revision': revision,
    });
  }
}
