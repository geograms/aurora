/*
 * mesh_service — the BLE street-mesh node (docs/mesh.md, milestone M1).
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
import 'dart:typed_data';

import 'package:battery_plus/battery_plus.dart';

import '../../connections/bluetooth/ble5_bus.dart';
import '../../profile/profile_service.dart';
import '../../profile/storage_paths.dart';
import '../../util/media_archive.dart';
import '../log_service.dart';
import '../preferences_service.dart';
import '../xprs/xprs_archive.dart';
import '../xprs/xprs_history_server.dart';
import '../xprs/xprs_ingest.dart';
import '../xprs/xprs_packet.dart';
import '../xprs/xprs_vocab.dart';
import 'mesh_beacon.dart';
import 'mesh_custody.dart';
import 'mesh_bulk_spool.dart';
import 'mesh_store.dart';
import 'mesh_table.dart';

class MeshService {
  MeshService._();
  static final MeshService instance = MeshService._();

  // Politeness (docs/mesh.md §7): the beacon interval adapts to channel
  // load — quiet streets get chatty beacons, saturated streets get
  // presence-only whispers. _beaconInterval is the quiet-street floor.
  static const Duration _beaconInterval = Duration(seconds: 30);
  static const Duration _beaconTtl = Duration(seconds: 70);
  static const Duration _triggerDebounce = Duration(seconds: 4);

  final DateTime _startedAt = DateTime.now();
  final Battery _battery = Battery();

  // `lifetime:` (docs/XPRS.md section 10.5): cumulative service seconds saved
  // by every PREVIOUS run; the current figure is this plus the uptime. Loaded
  // once (a re-entrant start() must not fold the running uptime back into the
  // base, or the total double-counts), saved from the sweep timer.
  int _lifeBaseSec = -1;

  MeshTable? _table;
  bool _canAdvertise = false;
  bool _running = false;
  Timer? _beaconTimer;
  Timer? _sweepTimer;
  Timer? _triggerTimer;
  bool _powered = false;
  int _batteryPct = 100;
  int _beaconsSent = 0, _beaconsHeard = 0;

  // Channel-load meter: BLE5 frames heard in a sliding minute (fed by
  // BleService for every inbound frame, any subtype). Drives politeness.
  final List<DateTime> _heardStamps = [];

  /// Called by the transport for every inbound BLE5 frame.
  void noteChannelActivity() {
    final now = DateTime.now();
    _heardStamps.add(now);
    if (_heardStamps.length > 600) _heardStamps.removeRange(0, 100);
  }

  /// Frames/second heard over the last minute.
  double channelLoad() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 60));
    _heardStamps.removeWhere((t) => t.isBefore(cutoff));
    return _heardStamps.length / 60.0;
  }

  /// Politeness tier: 0 quiet, 1 busy, 2 saturated (docs/mesh.md §7).
  /// Powered nodes back off LAST (they are the useful chatter).
  int politenessTier() {
    final load = channelLoad();
    final saturated = _powered ? 5.0 : 3.0;
    final busy = _powered ? 2.0 : 1.0;
    if (load >= saturated) return 2;
    if (load >= busy) return 1;
    return 0;
  }

  /// Effective beacon interval for the current tier.
  Duration beaconIntervalNow() => switch (politenessTier()) {
        2 => const Duration(minutes: 5),
        1 => const Duration(seconds: 90),
        _ => _beaconInterval,
      };

  /// Battery dial policy: on low battery (and not charging) the node stops
  /// PULLING work for others; its own outbound mail still moves.
  bool dialBudgetLow() => !_powered && _batteryPct < 20;

  bool get isRunning => _running;

  /// Bump-on-change revision so UI layers can cheaply poll for updates.
  int revision = 0;

  /// Set by BleService: every beacon sighting also registers the sender's
  /// BLE address as dialable. Vital at fringe — the constantly-rotating
  /// extended beacon lands where a 200 ms legacy presence advert is missed,
  /// and a GATT connect needs only the address.
  void Function(String callsign, String addr)? onPeerSighting;

  /// The live table (null before start). M2 custody reads routes/neighbors.
  MeshTable? get table => _table;

  /// Our mesh identity ('' before the profile loads).
  String get tableCallsign => _table?.selfCallsign ?? '';

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
      // Only ever RAISE this on a repeat start: a later caller that knows less
      // (the BLE5 probe had not answered when it ran) must not mute a node that
      // is already transmitting.
      if (canAdvertise && !_canAdvertise) setCanAdvertise(true);
      return;
    }
    _table = MeshTable(cs);
    _canAdvertise = canAdvertise;
    _running = true;

    // The custody store lives beside the other cross-wapp state
    // (…/data/mesh.sqlite3) and re-opens when the profile changes.
    final prefs = PreferencesService.instanceSync;
    // The owner's standing answer on carrying for other people (default yes).
    if (prefs != null) {
      MeshStore.instance.carryForOthers = prefs.meshCarryForOthers;
    }
    if (prefs != null && _lifeBaseSec < 0) _lifeBaseSec = prefs.meshLifetimeSec;
    if (prefs != null) {
      try {
        MeshStore.instance
            .init(wappsDataStorage(prefs).getAbsolutePath('mesh.sqlite3'));
        MeshStore.instance.sweep();
        // The heard-traffic spool (docs/XPRS.md sections 24 and 31.3) lives
        // beside the custody store and re-opens with it on profile change.
        // Its key resolver is wired by RnsService, which owns the keys.
        XprsArchive.instance
          ..selfCallsign = cs
          ..maxBytes = prefs.xprsArchiveMaxMb * 1024 * 1024
          ..maxAgeDays = prefs.xprsArchiveMaxDays
          ..init(wappsDataStorage(prefs)
              .getAbsolutePath('xprs_archive.sqlite3'));
        XprsHistoryServer.instance.install();
        MeshBulkSpool.instance.init(
            wappsDataStorage(prefs).getAbsolutePath('mesh/bulk'),
            MediaArchive.forDirectory(
                wappsDataStorage(prefs).getAbsolutePath('')));
        MeshBulkSpool.instance.sweep();
      } catch (e) {
        LogService.instance.add('Mesh: store init failed: $e');
      }
    }

    Ble5Bus.instance.onFrame(Ble5Subtype.mesh, _onFrame);
    Ble5Bus.instance.onFrame(Ble5Subtype.xprs, _onXprsFrame);
    // Leaves listen too: extended SCANNING is a separate controller capability
    // from extended advertising, so a phone that can't beacon (e.g. C61) may
    // still hear the street. Idempotent; harmless where unsupported.
    // Bounded: these calls hop to the native BLE worker thread, and an await
    // that never returns leaves the mesh unstarted, silent, and with no log
    // line to say so. Timing out here still leaves the node running — the scan
    // is re-armed by the service watchdog anyway.
    try {
      await Ble5Bus.instance
          .startScan()
          .timeout(const Duration(seconds: 5), onTimeout: () {});
    } catch (_) {}

    _beaconTimer?.cancel();
    // Adaptive cadence: a fixed 10 s tick decides whether the politeness
    // interval has elapsed (the interval itself moves with channel load).
    var lastBeacon = DateTime.fromMillisecondsSinceEpoch(0);
    _beaconTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (DateTime.now().difference(lastBeacon) >= beaconIntervalNow()) {
        lastBeacon = DateTime.now();
        _sendBeacon();
      }
    });
    _sweepTimer?.cancel();
    var sweepTick = 0;
    _sweepTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (_table?.sweep() ?? false) revision++;
      if (++sweepTick % 10 == 0) {
        MeshStore.instance.sweep(); // TTL + quota
        MeshBulkSpool.instance.sweep();
      }
      // lifetime: accumulate service time every 15 min (section 10.5). A kill
      // loses at most that tail, same trade the dongle makes with its NVS.
      if (sweepTick % 15 == 0 && _lifeBaseSec >= 0) {
        PreferencesService.instanceSync?.meshLifetimeSec =
            _lifeBaseSec + DateTime.now().difference(_startedAt).inSeconds;
      }
    });

    // Track power state for the cond byte (desktops report `unknown` = mains).
    try {
      final st = await _battery.batteryState;
      _powered = st != BatteryState.discharging;
      _batteryPct = await _battery.batteryLevel;
      _battery.onBatteryStateChanged.listen((st) async {
        _powered = st != BatteryState.discharging;
        try {
          _batteryPct = await _battery.batteryLevel;
        } catch (_) {}
      });
    } catch (_) {
      _powered = true; // no battery API → assume powered (desktop)
    }

    try {
      await _sendBeacon().timeout(const Duration(seconds: 5), onTimeout: () {});
    } catch (_) {}
    LogService.instance.add(
        'Mesh: started as $cs (${_canAdvertise ? "relay-capable" : "scan-only leaf"})');
  }

  /// An XPRS frame on subtype `0x58` — a discovery beacon, or carried mail.
  ///
  /// Only the beacon is handled here. Mail addressed to us is already picked up
  /// by [MeshCustodyDelegate.onAirFrame] on the transport's inbound path, which
  /// is where custody decisions belong.
  void _onXprsFrame(Ble5Frame f) {
    final t = _table;
    if (t == null) return;
    final p = XprsPacket.parse(utf8.decode(f.data, allowMalformed: true));
    if (p == null) return;
    final from = (p['f'] ?? '').trim().toUpperCase();
    if (from.isEmpty || from == t.selfCallsign.toUpperCase()) return;

    // EVERY XPRS packet on this subtype goes through the funnel, whatever its
    // type — the monitor for whoever is watching the air, the archive for
    // whoever asks next month, the responder when it is a command for us.
    XprsIngest.heard(p,
        bearer: 'ble', selfCallsign: t.selfCallsign, rssi: f.rssi);

    // The rest of this is beacon handling, and only a beacon is a beacon.
    if (p.type != 'observation') return;
    _xprsBeaconsHeard++;
    // A reading without `link:` is unanswerable and discarded (section 10.6.1);
    // one about another bearer is not evidence about this radio.
    if (!xprsReadingIsScoped(p) || p['link'] != 'ble') return;

    final peers = xprsPeers(p);
    final heard = (p['hears'] ?? '')
        .split(',')
        .where((c) => c.isNotEmpty)
        .toList();
    LogService.instance.add(
        'Mesh: XPRS beacon from $from (${f.rssi} dBm) — '
        '${heard.length} of ${peers ?? heard.length} peers listed');
    // The sender is by definition directly heard, so this is a sighting like
    // any other: it registers the address for dialling.
    onPeerSighting?.call(from, f.addr);

    // `lx:` says where to write to this station (section 10.6). Hearing it is
    // not the same as being able to address it: that needs a Reticulum path,
    // which carries the peer's key and comes from an announce. So when we hold
    // no path, ask for one — ONCE, through the transport's per-destination
    // backoff, which turns this into a single question rather than a storm. The
    // peer answers with its announce and the next message goes direct instead of
    // being parked for store-and-carry.
    // The beacon states BOTH who is speaking and where to write to them, so it
    // is the one place that pairing is free and authoritative. Pass the callsign
    // along with the address: without it the host knows an LXMF destination it
    // cannot name, and every UI built on the directory falls back to showing
    // raw hex where a callsign belongs.
    final lx = p['lx'];
    if (lx != null && lx.length == 32) onPeerAddress?.call(lx, from);
  }

  /// A neighbour published its LXMF delivery address in a beacon and we hold no
  /// path to it. The owner turns this into a (throttled) path request, and
  /// records [callsign] as the name for [destHex].
  void Function(String destHex, String callsign)? onPeerAddress;

  /// This station's own LXMF delivery destination, for the beacon's `lx:`.
  /// Supplied by the owner — the mesh does not reach into Reticulum itself
  /// (docs/architecture.md: the transports own their own layer).
  String? Function()? ourLxmfDest;

  int _xprsBeaconsHeard = 0;

  /// XPRS discovery beacons heard from other stations.
  int get xprsBeaconsHeard => _xprsBeaconsHeard;

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
    if (f.addr.isNotEmpty) onPeerSighting?.call(b.callsign, f.addr);
    // M2: the beacon's have-bloom says what its owner already received —
    // purge any mail we're carrying FOR that owner that it claims to have.
    if (b.have.isNotEmpty) {
      final purged = MeshStore.instance.applyPeerBloom(b.callsign, b.have);
      if (purged > 0) {
        LogService.instance
            .add('Mesh: ${b.callsign} have-bloom purged $purged parked msg(s)');
      }
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

  /// Stop (or resume) claiming we can advertise. Called when the controller
  /// refuses our advertising set: a node that cannot transmit is a scan-only
  /// leaf, and saying otherwise is how a mute device reported itself healthy.
  void setCanAdvertise(bool can) {
    if (_canAdvertise == can) return;
    _canAdvertise = can;
    LogService.instance.add(
        'Mesh: now ${can ? "relay-capable" : "scan-only (radio refuses to advertise)"}');
  }

  int _beaconsFailed = 0;

  /// Beacons the radio refused to air. `beaconsSent` counts only the ones that
  /// actually went out.
  int get beaconsFailed => _beaconsFailed;

  /// Say we are here. ONE beacon goes out, and it is the XPRS one.
  ///
  /// The binary mesh beacon used to be aired alongside it, carrying a
  /// distance-vector digest and a have-bloom. It is gone from the air for two
  /// reasons.
  ///
  /// The radio is the first. It is not full duplex — one antenna, time-shared —
  /// so every millisecond spent advertising is a millisecond deaf, and a device
  /// that advertises continuously misses roughly half of what is said to it.
  /// The transmit window is now a few seconds a minute (Ble5.kt), and two
  /// beacons competing for that window halve the chance either is heard.
  ///
  /// The second is that an advert is the wrong carrier for that content anyway:
  /// the DV digest and the bloom are exchanged IN FULL over an MSP session,
  /// acknowledged, whenever two stations have something to move. A beacon's job
  /// is to say "I am here, this is my callsign, this is what I am holding" —
  /// enough for a peer to decide to open a link. That is exactly what the XPRS
  /// beacon says (docs/XPRS.md section 10.6).
  Future<void> _sendBeacon() async {
    await _sendXprsBeacon();
  }

  /// The discovery beacon, as XPRS (docs/XPRS.md section 10.6).
  ///
  /// ```
  /// t:observation f:X1A67X link:ble peers:12 hears:X1RD89,X32DVA,CT1ABC-9
  /// ```
  ///
  /// This is the half of discovery that is readable: who I am and who I can
  /// reach. It rides its own subtype (`0x58`, ASCII 'X') so nothing has to sniff
  /// a frame to know what it is, and so the chat wapp and the ESP32 — which
  /// speak neither — ignore it instead of trying to parse it.
  ///
  /// The binary beacon above keeps the DV digest and the have-bloom, and that is
  /// not a retreat: those two exist *because* they are compressed. A DV entry is
  /// 4 bytes here and about 10 characters as text, and the bloom is a flat 128
  /// bytes, so at this controller's ceiling text fits either the routing table
  /// or the bloom and never both.
  Future<void> _sendXprsBeacon() async {
    final t = _table;
    if (t == null || !_canAdvertise) return;
    final self = t.selfCallsign.trim();
    if (self.isEmpty) return;

    var envelope =
        XprsPacket.parse('t:observation f:$self link:ble peers:0 hears:x');
    if (envelope == null) return;

    // `mail:` is how this station says it is holding messages for other people
    // (section 10.6.5), and it is why carried mail no longer needs a broadcast
    // of its own: a neighbour that can reach a recipient opens a session, and
    // everybody else spends nothing. Omitted at zero — a field that is almost
    // always 0 is not worth transmitting.
    final held = MeshStore.instance.ready ? MeshStore.instance.pendingCount() : 0;
    if (held > 0) envelope = envelope.with_('mail', '$held');

    // `lx:` — WHERE TO WRITE TO US: this station's LXMF delivery destination.
    //
    // Knowing a callsign is on the air is not enough to address it. That needs a
    // Reticulum path, which is learned from an ANNOUNCE, and announces were
    // losing the advert channel to traffic: measured between two phones with no
    // internet, one heard its neighbour's beacon every few seconds and its
    // announce once in five minutes, so `/api/rns/route` for that peer stayed
    // null and every message fell back to store-and-carry.
    //
    // The beacon already says who is here; this says where to write. A hearer
    // that holds no path asks for one (a single throttled path request), and the
    // peer answers with the announce that carries its key. 36 bytes on a
    // 76-byte beacon, well inside the smallest measured advert ceiling (184).
    final lx = ourLxmfDest?.call();
    if (lx != null && lx.length == 32) envelope = envelope.with_('lx', lx);

    // `uptime:`/`lifetime:` — this station's stability account (section 10.5),
    // for whoever is choosing a relay or a mailbox. Added BEFORE the
    // neighbour fit below so their bytes count against the advert budget.
    final upSec = DateTime.now().difference(_startedAt).inSeconds;
    envelope = envelope.with_('uptime', xprsFmtDuration(upSec));
    if (_lifeBaseSec >= 0) {
      envelope =
          envelope.with_('lifetime', xprsFmtDuration(_lifeBaseSec + upSec));
    }

    // `serve:history` (section 24): this station keeps a spool and answers
    // cmd:history. The claim is "ask me", never a depth (31.3). Before the
    // neighbour fit, so its bytes count against the advert budget.
    if ((PreferencesService.instanceSync?.xprsServeHistory ?? true) &&
        XprsArchive.instance.ready) {
      envelope = envelope.with_('serve', 'history');
    }

    // Most relevant first, and this station's idea of relevant (section
    // 10.6.3): a powered, stationary relay outranks a passing phone that
    // happens to be loud right now, then how reliably we hear it, then signal.
    final now = DateTime.now();
    final ranked = t.neighbors.values.toList()
      ..sort((a, b) {
        final ap = a.cond.powered ? 1 : 0, bp = b.cond.powered ? 1 : 0;
        if (ap != bp) return bp - ap;
        final c = b.contactRatio.compareTo(a.contactRatio);
        if (c != 0) return c;
        return b.lastRssi.compareTo(a.lastRssi);
      });
    final fresh = ranked
        .where((n) => now.difference(n.lastHeard) < kNeighborTtl)
        .map((n) => n.callsign.toUpperCase())
        .toList();

    // `peers:` is the true total even when `hears:` is cut to fit. Without it a
    // short list cannot be told from a small mesh (section 10.6.4).
    final fit = xprsNeighbourFit(fresh, envelope, Ble5Bus.instance.maxPayload);
    var p = envelope.with_('peers', '${fit.peers}');
    p = fit.hears.isEmpty
        ? XprsPacket(p.fields.where((f) => f.key != 'hears').toList())
        : p.with_('hears', fit.hears.join(','));

    // No `busy:` or `txtime:` yet. Section 10.6 defines both over the last hour
    // and this node measures neither — `channelLoad` is a short sliding window
    // of adverts per second, which is a different quantity. Publishing it under
    // those names would be a wrong number rather than a missing one.
    try {
      final bytes = Uint8List.fromList(utf8.encode(p.encode()));
      final aired = await Ble5Bus.instance
          .advertiseFrame('xprs', Ble5Subtype.xprs, bytes, ttl: _beaconTtl);
      // HONOUR the answer. A refused frame is aired nowhere, and counting it
      // as sent is how a device ends up reporting a healthy beacon while
      // broadcasting into nothing — the same trap the binary beacon above
      // documents.
      if (aired) {
        _xprsBeaconsSent++;
      } else {
        _xprsBeaconsFailed++;
        if (_xprsBeaconsFailed == 1 || _xprsBeaconsFailed % 10 == 0) {
          LogService.instance.add(
              'Mesh: radio refused the XPRS beacon (${bytes.length}B, cap '
              '${Ble5Bus.instance.maxPayload}B, $_xprsBeaconsFailed so far)');
        }
      }
    } catch (e) {
      LogService.instance.add('Mesh: XPRS beacon tx failed: $e');
    }
  }

  int _xprsBeaconsSent = 0;
  int _xprsBeaconsFailed = 0;

  /// XPRS discovery beacons the radio accepted.
  int get xprsBeaconsSent => _xprsBeaconsSent;

  /// XPRS beacons the radio refused — aired nowhere.
  int get xprsBeaconsFailed => _xprsBeaconsFailed;

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
      'xprsBeaconsSent': _xprsBeaconsSent,
      'xprsBeaconsHeard': _xprsBeaconsHeard,
      'xprsBeaconsFailed': _xprsBeaconsFailed,
      'channelLoad': double.parse(channelLoad().toStringAsFixed(2)),
      'politeness': ['quiet', 'busy', 'saturated'][politenessTier()],
      'beaconIntervalS': beaconIntervalNow().inSeconds,
      'battery': _batteryPct,
      'revision': revision,
      // Custody counters: relaying asserted as a number, not grepped out of a
      // rolling log that holds twenty minutes on a busy device.
      ...MeshCustodyCounters.toJson(),
    });
  }

  // ── facade for the wapp layer ─────────────────────────────────────────────
  // lib/wapp must not reach into the mesh internals (docs/architecture.md §1):
  // that is how store-and-forward ended up inside a wapp. Everything the wapp
  // layer legitimately needs goes through these three, and the guard
  // (no-transport-in-wapp-layer) keeps it that way.

  /// Parked-mail counts, live transfers and quotas — what the mesh status HAL
  /// endpoint reports.
  Map<String, dynamic> storeStatus() {
    final c = MeshStore.instance.counts();
    return {
      'inTransit': c.inTransit,
      'archived': c.archived,
      'bytes': c.bytes,
      'receivedAms': c.receivedAms,
      'quotaBytes': MeshStore.instance.quotaBytes,
      'spoolPending': MeshBulkSpool.instance.pendingCount(),
      'spoolQuotaBytes': MeshBulkSpool.instance.quotaBytes,
      // Whether this device carries other people's mail (see setQuotaPref's
      // 'scfEnabled'). 1 by default.
      'enabled': MeshStore.instance.carryForOthers ? 1 : 0,
    };
  }

  /// What this device is holding for other people, newest first.
  List<Map<String, dynamic>> held({int limit = 200}) =>
      MeshStore.instance.heldJson(limit: limit);

  /// What ANOTHER station is carrying, as plain rows; null when it could not
  /// be reached (or does not serve listings).
  ///
  /// Browsing a neighbour's custody store means dialling it and running an MSP
  /// session — a transport act, and therefore this layer's job rather than the
  /// caller's. The rows come back as data, so a screen can render them without
  /// naming a session type: `{am, target, urg, len, ageS}`, the same shape the
  /// wapp-facing broker uses (mesh_carry_broker.dart).
  Future<List<Map<String, dynamic>>?> carriedBy(String callsign) async {
    final entries = await MeshSessionManager.instance.browseCarried(callsign);
    if (entries == null) return null;
    return [
      for (final e in entries)
        {
          'am': e.am,
          'target': e.target,
          'urg': e.urg,
          'len': e.len,
          'ageS': e.ageS,
        },
    ];
  }

  /// Take custody of [ids] from [callsign] — they transfer over the session
  /// and land in our own store. True when the request went out on a live one.
  Future<bool> takeCustody(String callsign, List<String> ids) =>
      MeshSessionManager.instance.pullCarried(callsign, ids);

  /// Bulk-lane transfers in flight.
  List<Map<String, dynamic>> transfers() =>
      MeshBulkSpool.instance.transfersJson();

  /// How much disk this device offers: `msgQuotaMb` for other people's mail,
  /// `bulkQuotaMb` for the file lane. Returns false on an unknown key.
  bool setQuotaPref(String key, int mb) {
    if (mb < 0) return false;
    switch (key) {
      case 'msgQuotaMb':
        MeshStore.instance.quotaBytes = mb * 1024 * 1024;
      case 'bulkQuotaMb':
        MeshBulkSpool.instance.quotaBytes = mb * 1024 * 1024;
      case 'scfEnabled':
        // Not a quota — a yes/no — but it rides the same one-int channel, so
        // the wapp needs no second HAL to ask for it. 0 = carry nothing for
        // anyone else; anything else = carry (the default).
        MeshStore.instance.carryForOthers = mb != 0;
        unawaited(PreferencesService.instanceSync
            ?.setMeshCarryForOthers(mb != 0) ?? Future<void>.value());
      default:
        return false;
    }
    return true;
  }

  /// A wapp echoed an outgoing 1:1 bubble. The core decides what that means for
  /// delivery (today: queue any attachment it references on the bulk lane).
  void noteConvoOutMessage(Map<String, dynamic> data) =>
      MeshCustodyDelegate.onConvoOutMessage(data);
}
