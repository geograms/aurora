// Native shared BLE service (Android/iOS/macOS/Windows/Linux). Owns the single
// adapter via the bluetooth_low_energy package and shares it across all wapps.
//
// Scanning is reference-counted (runs while >=1 wapp wants it) and decoded
// frames are fanned out on a broadcast [inbound] stream. Advertising is a
// per-owner queue that a rotation timer broadcasts round-robin (each payload
// for a short slot) — so several wapps can transmit through one adapter.
//
// Note: peripheral (advertise) support varies by platform; on platforms where
// it is unavailable (e.g. Linux/BlueZ in this package) the service degrades to
// scan-only and [advertiseSupported] is false.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:ble_peripheral/ble_peripheral.dart' as bp;
import 'package:bluez/bluez.dart';
import 'package:dbus/dbus.dart' show DBusArray;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;

import '../../profile/profile_service.dart';
import '../../services/log_service.dart';
import '../../services/mesh/mesh_custody.dart';
import '../../services/mesh/mesh_transfer_scheduler.dart';
import '../../services/mesh/mesh_service.dart';
import '../../services/mesh/mesh_session.dart' show mspIsFrame;
import '../../services/preferences_service.dart';
import 'ble5_bus.dart';
import 'ble_gatt_client.dart';
import 'ble_gatt_server.dart';
import 'ble_parcel.dart';
import 'ble_queue_service.dart';
import 'ble_reassembler.dart';

/// APRS-over-BLE manufacturer id carried in advertisement manufacturer data.
/// Must match peer firmware (e.g. ESP32). 0xFFFF is the reserved test id.
const int kBleCompanyId = 0xFFFF;

/// Service UUID advertised alongside the manufacturer data (the 16-bit 0xFFE0
/// the ESP32 uses, in 128-bit form). Some Android controllers won't actually
/// emit an advertisement that carries ONLY manufacturer data, so a service
/// UUID must be present; peers still match on the manufacturer data, not this.
const String kBleServiceUuid = '0000ffe0-0000-1000-8000-00805f9b34fb';

/// How long to hold a primary advert waiting for its continuation when the two
/// arrive as separate scan events (BlueZ collapses duplicate company ids, so
/// the advert and its scan response surface one after another, not together).
const Duration kBleContWindow = Duration(milliseconds: 450);

class BleInboundFrame {
  final String from; // peer uuid
  final int rssi;
  final Uint8List data; // the manufacturer payload (e.g. an APRS TNC2 frame)
  BleInboundFrame(this.from, this.rssi, this.data);
}


class _Advert {
  final Object owner;
  final Uint8List payload;
  int expiresMs;
  // While > now (epoch ms) this advert is prioritised: the rotation airs only
  // boosted adverts, so a NACK-requested chunk is re-aired rapidly instead of
  // waiting its turn behind every other queued chunk. 0 = not boosted.
  int boostUntilMs;
  _Advert(this.owner, this.payload, this.expiresMs, {this.boostUntilMs = 0});
}

class BleService {
  BleService._();
  static final BleService instance = BleService._();

  CentralManager? _central;
  bool _inited = false;
  bool _advertiseSupported = true;
  WidgetsBindingObserver? _lifecycle;

  // Advertising backend: on Android/iOS use the ble_peripheral package (the
  // bluetooth_low_energy PeripheralManager doesn't reliably radiate on some
  // Android chipsets — geogram uses ble_peripheral for the same reason). On
  // Linux fall back to BlueZ D-Bus. Scanning always uses CentralManager above.
  bool get _useBlePeripheral => Platform.isAndroid || Platform.isIOS;
  bool _blePeripheralReady = false;

  // Linux advertising via BlueZ D-Bus (no ble_peripheral on Linux).
  // Transparent to wapps — hal_ble_advertise works the same; the host just
  // uses ble_peripheral (Android/iOS) or BlueZ (Linux) underneath.
  BlueZClient? _bluez;
  BlueZAdapter? _bzAdapter;
  BlueZAdvertisement? _bzAdvert;

  bool get supported => true;
  bool get advertiseSupported => _advertiseSupported;

  /// True only when the physical Bluetooth adapter is powered ON and usable.
  /// Goes false the moment the user turns Bluetooth off at the OS level, so a
  /// wapp can hide its "BLE available" indicator instead of claiming a channel
  /// that can't carry anything. Before init (no central yet) BLE is unavailable.
  bool get poweredOn {
    final c = _central;
    if (c != null) return c.state == BluetoothLowEnergyState.poweredOn;
    final bz = _bzAdapter;
    if (bz != null) return bz.powered;
    return false;
  }

  final _inbound = StreamController<BleInboundFrame>.broadcast();
  Stream<BleInboundFrame> get inbound => _inbound.stream;

  // Long-frame reassembly (ADV + scan-response continuation). The reassembler
  // holds logic; these per-peer timers bound how long a primary waits for its
  // continuation when the two arrive as separate scan events.
  final BleReassembler _reasm = BleReassembler();
  final Map<String, Timer> _holdTimers = {};

  // Broadcast-parcel (<=300B connectionless) reassembly + dedup, with a periodic
  // sweep to drop stale partials.
  final BleBroadcastReassembler _bcast = BleBroadcastReassembler();
  Timer? _bcastSweep;

  // Our 1-byte sender discriminator (srcTag): low byte of a stable hash of the
  // active callsign, written into every broadcast chunk so a NACK can address
  // the right sender. Opaque to the framing layer. Recomputed on first use.
  int? _myTag;
  // Owner of internally-generated control adverts (NACK frames) so they survive
  // a wapp's clearAdverts and aren't attributed to any wapp.
  final Object _ctrlOwner = Object();
  // True while at least one outbound NACK is in flight (awaiting resends): used
  // to bias the BlueZ duty cycle toward scanning so we catch the re-aired chunks.
  bool _awaitingResend = false;

  // BLE 5 connectionless broadcast (Android): when supported, APRS group
  // messages ride the shared Ble5Bus as ONE extended advert each (subtype 0x41),
  // multiplexed with Reticulum announces on a single advertising set. This
  // replaces the fragile legacy 13-24B chunk + NACK broadcast for the common
  // case; the legacy path stays only as a fallback for non-BLE5 devices.
  bool _ble5 = false; // device supports + we use BLE5 for APRS broadcast
  bool _ble5Checked = false;
  bool _ble5Wired = false;
  // BLE5 advert keys we registered, per owner, so clearAdverts can drop them.
  final Map<Object, Set<String>> _ble5Keys = {};
  // Receiver dedup for single-frame BLE5 APRS (keyed by payload hash) so the
  // sender's TTL re-airs are delivered to the wapp exactly once.
  final Map<String, DateTime> _ble5Seen = {};

  // Generic GATT parcel transport: this device is both a client (connects out
  // to peers' servers) and a server (peers connect in), bridged by one queue.
  BleGattClient? _gatt;
  BleGattServer? _gattServer;
  final BLEQueueService _queue = BLEQueueService();
  bool _parcelWired = false;
  bool _gattLinkUp = false; // a GATT client link is active → pause scanning
  // Auto-pair: last GATT data activity (epoch ms); an idle link is dropped so
  // the connectionless broadcast (APRS, RNS announces) resumes.
  int _gattActivityMs = 0;
  static const int _gattIdleMs = 25000;

  // Wire the parcel queue to both GATT endpoints. The single send callback
  // routes by deviceId: a peer that connected to our server is notified on
  // FFF2; a peer we connected to is written on FFF1. Reassembled inbound
  // messages are fanned out on the same stream wapps already read, so APRS (and
  // any wapp) needs no change.
  void _setupParcelTransport() {
    if (_parcelWired || _central == null) return;
    _parcelWired = true;
    _bcastSweep ??=
        Timer.periodic(const Duration(seconds: 2), (_) => _bcastTick());
    _gatt = BleGattClient(_central!, onData: (from, data) {
      _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
      // MSP (mesh session) frames peel off before the legacy parcel queue.
      if (mspIsFrame(data) &&
          MeshSessionManager.instance.onFrame(data, serverSide: false)) {
        return;
      }
      _queue.onDataReceived(from, data);
    }, onLinkChange: (connected) {
      _gattLinkUp = connected;
      if (connected) {
        _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
        _dbg('GATT link up (client) to ${_gatt?.peerId}');
        // Keep the BLE5 scan paused while the link is up so the transfer holds
        // (extended scan vs an active connection contend on one radio).
        unawaited(Ble5Bus.instance.stopScan());
        _flushPendingGatt();
        MeshSessionManager.instance.onLinkUp(serverSide: false);
      } else {
        _dbg('GATT link down (client)');
        MeshSessionManager.instance.onLinkDown(serverSide: false);
        _resumeBle5Scan(); // transfer done/failed → resume broadcast reception
      }
      _applyScan(); // pause scanning while a GATT link is up (radio contention)
    })
      ..start();
    _gattServer = BleGattServer(onData: (from, data) {
      _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
      if (mspIsFrame(data) &&
          MeshSessionManager.instance.onFrame(data, serverSide: true)) {
        return;
      }
      _queue.onDataReceived(from, data);
    }, onClientsChanged: () {
      final n = _gattServer?.clientIds.length ?? 0;
      if (n > 0) {
        _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
        unawaited(Ble5Bus.instance.stopScan()); // free the radio for the transfer
        MeshSessionManager.instance.onLinkUp(serverSide: true);
      } else {
        MeshSessionManager.instance.onLinkDown(serverSide: true);
        _resumeBle5Scan();
      }
      _dbg('GATT server clients: $n');
      _applyScan(); // pause scanning while we're serving a client (contention)
    });
    _wireMeshHooks();
    _queue.setSendCallback((deviceId, data) async {
      _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
      // Native GATT path (BLE5): route by which role holds this peer.
      if (_ngClientUp && deviceId == _ngClientPeer) {
        await Ble5Bus.instance.gattWrite(data); // our client -> peer FFF1
        return;
      }
      if (deviceId == _ngServerCentral) {
        await Ble5Bus.instance.serverNotify(data); // our server -> central FFF2
        return;
      }
      // Legacy (non-BLE5) plugin path.
      if (_gattServer?.clientIds.contains(deviceId) ?? false) {
        await _gattServer!.notify(deviceId, data); // server -> client FFF2
      } else {
        await _gatt?.writeRaw(data); // client -> peer FFF1
      }
    });
    _queue.incomingMessages.listen((m) {
      _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
      _dbg('GATT message received ${m.payload.length}B from ${m.sourceDeviceId}');
      if (!_inbound.isClosed) {
        _inbound.add(BleInboundFrame(m.sourceDeviceId, 0, m.payload));
      }
    });
  }

  // ── Mesh custody transport hooks (doc/mesh.md M2) ──────────────────────────
  // The MSP session layer (mesh_custody.dart) is transport-agnostic; these
  // hooks give it a send path on whichever GATT stack is live, an inbound
  // delivery tap, and a way to drop the dialed link when a session ends.
  bool _meshHooksWired = false;
  void _wireMeshHooks() {
    if (_meshHooksWired) return;
    _meshHooksWired = true;
    final hooks = MeshSessionManager.instance.hooks;
    hooks.clientSend = (data) async {
      _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
      if (_ble5) {
        await Ble5Bus.instance.gattWrite(data);
      } else {
        await _gatt?.writeRaw(data);
      }
    };
    hooks.serverSend = (data) async {
      _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
      if (_ble5) {
        await Ble5Bus.instance.serverNotify(data);
      } else {
        final id = _gattServer?.clientIds.firstOrNull;
        if (id != null) await _gattServer!.notify(id, data);
      }
    };
    hooks.deliverLocal = (wire) {
      // Custody-carried frame enters the same stream broadcast frames use, so
      // the chat wapp (and any other consumer) needs no mesh awareness.
      if (!_inbound.isClosed) _inbound.add(BleInboundFrame('mesh', 0, wire));
    };
    hooks.dropClientLink = () {
      if (_ble5) {
        unawaited(Ble5Bus.instance.gattDisconnect());
      } else {
        unawaited(_gatt?.disconnect() ?? Future.value());
      }
    };
    hooks.dial = meshDial;
    hooks.dialable = meshDialable;
    // Beacon sightings feed the dial registry too (the extended beacon lands
    // at fringe RSSI where the legacy presence advert is missed).
    MeshService.instance.onPeerSighting = (callsign, addr) {
      final cs = callsign.toUpperCase();
      final my = (ProfileService.instance.activeProfile?.callsign ?? '')
          .trim()
          .toUpperCase();
      if (cs.isEmpty || cs == my) return;
      _meshPeers[cs] =
          (addr: addr, ms: DateTime.now().millisecondsSinceEpoch);
    };
    MeshTransferScheduler.instance.start();
  }

  // Callsign → (BLE address, last-seen ms) registry from the native discovery
  // scan, so the mesh scheduler can dial a SPECIFIC peer (the old single
  // _lastPeerAddr slot only ever remembered the most recent one).
  final Map<String, ({String addr, int ms})> _meshPeers = {};
  static const int _meshPeerFreshMs = 150000; // ~2.5 min (a few scan gaps)

  /// Peers the mesh can currently dial: callsign → freshness.
  Map<String, int> meshDialable() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _meshPeers.removeWhere((_, v) => now - v.ms > _meshPeerFreshMs);
    return {for (final e in _meshPeers.entries) e.key: now - e.value.ms};
  }

  /// Dial [callsign] for a mesh custody session. Returns false when the peer
  /// hasn't been seen recently, the radio is busy, or GATT is unavailable.
  bool meshDial(String callsign) {
    if (!_ble5) return false; // scheduler dialing is native-path only for now
    if (_ngClientUp || _ngServerCentral != null) return false; // radio busy
    final p = _meshPeers[callsign.toUpperCase()];
    final now = DateTime.now().millisecondsSinceEpoch;
    if (p == null || now - p.ms > _meshPeerFreshMs) return false;
    _ngClientPeer = p.addr;
    _dbg('mesh dial: GATT connect to $callsign (${p.addr})');
    Ble5Bus.instance.gattConnect(p.addr);
    return true;
  }

  /// All peers currently reachable over the parcel transport (server clients +
  /// the peer we are a client of).
  List<String> _connectedPeers() {
    final ids = <String>{...?_gattServer?.clientIds};
    final p = _gatt?.peerId;
    if (p != null) ids.add(p);
    if (_ngClientUp && _ngClientPeer != null) ids.add(_ngClientPeer!);
    if (_ngServerCentral != null) ids.add(_ngServerCentral!);
    return ids.toList();
  }

  // Scanning (ref-counted).
  int _scanRefs = 0;
  bool _scanning = false;

  // Advertising (round-robin queue).
  final List<_Advert> _adverts = [];
  Timer? _rotateTimer;
  int _rotateIdx = 0;
  int _dutyTick = 0;       // scan/advertise duty-cycle phase
  bool _rotating = false;  // re-entrancy guard for _rotate

  // Noise control: skip re-registering an unchanged advert, and rate-limit
  // the repetitive BlueZ failure / oversized-frame messages so they don't
  // flood the console.
  String? _bzRegisteredHex; // payload currently registered with BlueZ
  String? _pkgAdvertHex;    // payload currently latched via ble_peripheral
  String _lastWarn = '';
  int _lastWarnMs = 0;
  int _dropLogMs = 0;

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  /// Our broadcast source tag: low byte of an FNV-1a hash of the active callsign
  /// (stable per identity). Cached; recomputed if it was never set. Falls back to
  /// a fixed non-zero value when no callsign is available yet.
  int get _srcTag {
    final cached = _myTag;
    if (cached != null) return cached;
    final cs = ProfileService.instance.activeProfile?.callsign ?? '';
    if (cs.isEmpty) return 0x7E; // no identity yet — don't cache the fallback
    var h = 0x811c9dc5; // FNV-1a 32-bit offset basis
    for (final c in cs.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    final tag = h & 0xFF;
    _myTag = tag;
    return tag;
  }

  void _warnThrottled(String msg) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (msg == _lastWarn && now - _lastWarnMs < 10000) return;
    _lastWarn = msg;
    _lastWarnMs = now;
    debugPrint('BleService: $msg');
  }

  Future<void> _ensure() async {
    if (_inited) return;
    _inited = true;
    try {
      _central = CentralManager();
      try {
        // Bounded: on Android authorize() can stall (it routes through
        // ActivityCompat.requestPermissions); the perms are requested up front
        // in the onboarding panel, so don't let a stalled call block scanning.
        await _central!.authorize().timeout(const Duration(seconds: 3),
            onTimeout: () => true);
      } catch (_) {}
      // Permanent discovered subscription; frames only flow while scanning.
      _central!.discovered.listen(_onDiscovered);
      _central!.stateChanged.listen((_) => _applyScan());
      _setupParcelTransport();
      // Re-arm the scan when the app returns to the foreground: Android may stop
      // a scan while we were paused (screen off) without notifying us, leaving
      // _scanning true so _applyScan would never restart it. The lifecycle hook
      // forces a fresh discovery so reception resumes.
      try {
        _lifecycle ??= _BleLifecycleObserver(this);
        WidgetsBinding.instance.addObserver(_lifecycle!);
      } catch (_) {}
    } catch (e) {
      _central = null;
      debugPrint('BleService: central unavailable: $e');
    }
    // Advertising backend.
    if (_useBlePeripheral) {
      try {
        await bp.BlePeripheral.initialize();
        _blePeripheralReady = true;
        _advertiseSupported = true;
      } catch (e) {
        _blePeripheralReady = false;
        _advertiseSupported = false;
        debugPrint('BleService: ble_peripheral init failed: $e');
      }
    } else if (Platform.isLinux) {
      _advertiseSupported = true; // BlueZ D-Bus (lazily connected in _bluezReady)
      debugPrint('BleService: using BlueZ D-Bus for advertising');
    } else {
      _advertiseSupported = false; // no advertise backend (e.g. desktop w/o BlueZ)
      debugPrint('BleService: advertising unavailable (scan-only)');
    }
    await _initBle5();
  }

  // Detect BLE5 support once and, if present, wire the shared bus so APRS
  // broadcast uses single extended adverts instead of legacy chunking.
  Future<void> _initBle5() async {
    if (_ble5Checked) return;
    _ble5Checked = true;
    try {
      _ble5 = await Ble5Bus.instance.supported();
    } catch (_) {
      _ble5 = false;
    }
    if (_ble5 && !_ble5Wired) {
      _ble5Wired = true;
      // Surface scan self-healing events in the app log (the bus watchdog
      // re-registers a scan that a vendor power manager silently killed).
      Ble5Bus.instance.onLog = (m) => LogService.instance.add(m);
      Ble5Bus.instance.onFrame(Ble5Subtype.aprs, _onBle5Aprs);
      // Any legacy broadcast chunks aired during the brief startup window before
      // BLE5 was confirmed must be dropped now — otherwise their rotation keeps
      // re-airing through the single ble_peripheral advertiser, clobbering the
      // GATT connectable presence beacon (which breaks GATT connects).
      _adverts.clear();
      _stopRotation();
      _bcast.sweep();
      // GATT large-file transfer runs ENTIRELY native on BLE5 devices: a single
      // coordinated stack (native GATT server + client + legacy connectable advert
      // + legacy discovery scan) with plain/unencrypted characteristics — no
      // pairing, and no dual-plugin handle-cache confusion. BLE5 extended
      // advertising carries only the connectionless broadcast (APRS + RNS).
      Ble5Bus.instance
        ..onGattConnected = _onNgConnected
        ..onGattDisconnected = _onNgDisconnected
        ..onGattData = _onNgClientData
        ..onGattDiscovered = _onNgDiscovered
        ..onGattServerData = _onNgServerData
        ..onGattServerConnected = _onNgServerConnected
        ..onGattServerDisconnected = _onNgServerDisconnected
        ..startGattEvents();
      _dbg('BLE5 broadcast + native GATT enabled');
    }
    // Street-mesh node (doc/mesh.md): rides the same BLE5 bus on its own
    // subtype. Non-BLE5 devices still start it as a scan-only leaf so the
    // Bluetooth wapp has a live (if empty) registry + self status.
    unawaited(MeshService.instance.start(canAdvertise: _ble5));
  }

  // ── Native GATT event handlers (BLE5) ─────────────────────────────────────
  void _onNgConnected() {
    _ngClientUp = true;
    _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
    _dbg('native GATT client link up to $_ngClientPeer');
    unawaited(Ble5Bus.instance.stopScan()); // quiet the extended scan during xfer
    _applyScan();
    _flushPendingGatt();
    _wireMeshHooks();
    MeshSessionManager.instance.onLinkUp(serverSide: false);
  }

  void _onNgDisconnected() {
    _dbg('native GATT client link down ($_ngClientPeer)');
    _ngClientUp = false;
    _ngClientPeer = null;
    MeshSessionManager.instance.onLinkDown(serverSide: false);
    if (_ngServerCentral == null) _resumeBle5Scan();
    _applyScan();
  }

  void _onNgClientData(Uint8List data) {
    _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
    if (mspIsFrame(data) &&
        MeshSessionManager.instance.onFrame(data, serverSide: false)) {
      return;
    }
    _queue.onDataReceived(_ngClientPeer ?? 'gatt', data);
  }

  void _onNgDiscovered(String address, String callsign) {
    if (address.isEmpty) return;
    final myCall = (ProfileService.instance.activeProfile?.callsign ?? '').trim();
    if (callsign.isNotEmpty && callsign == myCall) return; // ourselves
    _lastPeerAddr = address;
    _lastPeerCall = callsign;
    _lastPeerMs = DateTime.now().millisecondsSinceEpoch;
    if (callsign.isNotEmpty) {
      _meshPeers[callsign.toUpperCase()] =
          (addr: address, ms: _lastPeerMs); // mesh scheduler dial registry
    }
    _maybeAutoPair();
  }

  int _ngServerRxCount = 0;
  void _onNgServerData(String address, Uint8List data) {
    _ngServerCentral = address;
    _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
    _dbg('native server rx #${++_ngServerRxCount} ${data.length}B from $address');
    if (mspIsFrame(data) &&
        MeshSessionManager.instance.onFrame(data, serverSide: true)) {
      return;
    }
    _queue.onDataReceived(address, data);
  }

  void _onNgServerConnected(String address) {
    _ngServerCentral = address;
    _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
    _dbg('native GATT server: central $address connected');
    unawaited(Ble5Bus.instance.stopScan()); // quiet extended scan during xfer
    _applyScan();
    _wireMeshHooks();
    MeshSessionManager.instance.onLinkUp(serverSide: true);
  }

  void _onNgServerDisconnected(String address) {
    if (_ngServerCentral == address) _ngServerCentral = null;
    _dbg('native GATT server: central $address disconnected');
    MeshSessionManager.instance.onLinkDown(serverSide: true);
    if (!_ngClientUp) _resumeBle5Scan();
    _applyScan();
  }

  // One inbound single-frame APRS broadcast over BLE5. Dedup by payload hash
  // (the sender re-airs the same bytes for its TTL) and deliver once to wapps.
  void _onBle5Aprs(Ble5Frame f) {
    if (f.data.isEmpty || _inbound.isClosed) return;
    final key = _hashHex(f.data);
    final now = DateTime.now();
    final seen = _ble5Seen[key];
    if (seen != null && now.difference(seen) < kBleBcastDedup) return;
    _ble5Seen[key] = now;
    // Always logged (post-dedup = once per unique frame, low rate): the one
    // line that proves whether a peer's APRS frame reached this phone at all —
    // the exact visibility we lacked when dongle messages vanished en route.
    LogService.instance
        .add('BLE5 rx aprs ${f.data.length}B rssi=${f.rssi}');
    // Mesh custody tap: overheard ?ACKs purge, our 1:1s feed the have-bloom,
    // others' 1:1s get parked for GATT delivery (doc/mesh.md §6).
    MeshCustodyDelegate.onAirFrame(f.data, outbound: false);
    _inbound.add(BleInboundFrame(f.addr, f.rssi, f.data));
  }

  // Verbose BLE transport diagnostics — emitted only when the "BLE debug"
  // setting is on, and routed to LogService so they show in the in-app log and
  // /api/log (not just adb logcat).
  void _dbg(String msg) {
    if (PreferencesService.instanceSync?.bleDebug ?? false) {
      debugPrint('BleService: $msg');
      LogService.instance.add('BLE: $msg');
    }
  }

  // Short stable hex hash of a payload (FNV-1a 32-bit) for dedup / advert keys.
  static String _hashHex(Uint8List b) {
    var h = 0x811c9dc5;
    for (final x in b) {
      h ^= x;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16);
  }

  Future<bool> _bluezReady() async {
    if (_bzAdapter != null) return true;
    try {
      _bluez ??= BlueZClient();
      await _bluez!.connect();
      for (final a in _bluez!.adapters) {
        _bzAdapter = a;
        break;
      }
      return _bzAdapter != null;
    } catch (e) {
      debugPrint('BleService: BlueZ connect failed: $e');
      _advertiseSupported = false;
      return false;
    }
  }

  void _onDiscovered(DiscoveredEventArgs e) {
    final from = e.peripheral.uuid.toString();
    // Split our company-id manufacturer entries: broadcast-parcel chunks
    // (0x3E,0x50/0x51) go to the chunk reassembler; everything else (legacy
    // single-frame compact + its 0x42 continuation, presence beacons) goes to
    // the single-frame reassembler. Scanning is the default; we do NOT auto-
    // connect over GATT (that pauses scanning and breaks broadcast reception).
    final legacy = <Uint8List>[];
    for (final m in e.advertisement.manufacturerSpecificData) {
      if (m.id != kBleCompanyId || m.data.isEmpty) continue;
      final d = m.data;
      // On BLE5 devices the legacy chunk/NACK broadcast path is fully retired
      // (APRS + RNS ride the BLE5 extended bus) and GATT discovery is handled by
      // the NATIVE legacy scan (which gives the peer's MAC for the native
      // connect). So the bluetooth_low_energy _central scan ignores our company
      // frames entirely here — processing legacy chunks/NACKs would restart the
      // multi-chunk re-air loop that thrashes the advertiser and breaks connects.
      if (_ble5) continue;
      if (BleBroadcastReassembler.isNack(d)) {
        // A resend request — handle it here; it is NOT a data chunk and must not
        // reach the chunk reassembler or the legacy single-frame path.
        _onNack(d);
        continue;
      }
      if (BleBroadcastReassembler.isChunk(d)) {
        final full = _bcast.ingest(from, d);
        if (full != null && !_inbound.isClosed) {
          _dbg('broadcast-parcel reassembled (${full.length}B) from $from');
          _inbound.add(BleInboundFrame(from, e.rssi, full));
        }
      } else {
        // Presence beacon ([0x3E, deviceId 1..15, callsign…]): a connectable
        // Aurora peer. Consider auto-pairing a GATT link for larger transfers.
        if (d.length >= 3 && d[0] == kBleMarker && d[1] >= 1 && d[1] <= 15) {
          // Remember this connectable peer so a later queued payload can dial it
          // even though Android won't report it again for a while.
          _lastPeer = e.peripheral;
          _lastPeerCall = String.fromCharCodes(d.sublist(2)).trim();
          _lastPeerMs = DateTime.now().millisecondsSinceEpoch;
          _maybeAutoPair(); // in case a payload is already waiting
        }
        legacy.add(d);
      }
    }
    if (legacy.isEmpty) return;

    for (final f in _reasm.ingest(from, legacy)) {
      _inbound.add(BleInboundFrame(from, e.rssi, f));
    }

    // If a compact primary is now held waiting for its continuation, (re)arm a
    // short timer to deliver it as a short frame should none arrive.
    _holdTimers.remove(from)?.cancel();
    if (_reasm.held(from)) {
      final rssi = e.rssi;
      _holdTimers[from] = Timer(kBleContWindow, () {
        _holdTimers.remove(from);
        final p = _reasm.expire(from);
        if (p != null && !_inbound.isClosed) {
          _inbound.add(BleInboundFrame(from, rssi, p));
        }
      });
    }
  }

  /// Auto-pair: when we have a large payload waiting (and no link yet), open a
  /// GATT link to the most recently discovered Aurora peer with NO manual
  /// pairing. The SENDER (the side with data) initiates; the receiver stays a
  /// passive server, so the two don't both connect. On-demand only — when
  /// nothing is queued we stay in broadcast mode, and [_bcastTick] drops the
  /// link once the transfer idles. Called both on discovery and when data queues.
  void _maybeAutoPair() {
    if (!(PreferencesService.instanceSync?.bleAutoPair ?? true)) return;
    if (_pendingGatt.isEmpty) return;                         // nothing to send
    final fresh =
        DateTime.now().millisecondsSinceEpoch - _lastPeerMs <= _peerFreshMs;
    if (_ble5) {
      // Native connect path: dial the most-recently discovered peer's address
      // (from the native legacy discovery scan). The SENDER (side with data)
      // dials; the receiver stays a passive native server. Plain characteristics
      // = no pairing. Already serving a central → don't also dial (tie-breaker).
      if (_ngClientUp || _ngServerCentral != null) return;
      if (!fresh || _lastPeerAddr.isEmpty) return;
      _ngClientPeer = _lastPeerAddr;
      _dbg('auto-pair: native GATT connect to $_lastPeerCall ($_lastPeerAddr) '
          'for ${_pendingGatt.length} payload(s)');
      Ble5Bus.instance.gattConnect(_lastPeerAddr);
      return;
    }
    // Legacy plugin path (non-BLE5): bluetooth_low_energy considerPeer.
    if (_gattServer?.clientIds.isNotEmpty ?? false) return; // already serving
    final peer = _lastPeer;
    if (peer == null || (_gatt?.isConnected ?? true) || !fresh) return;
    final myCall = (ProfileService.instance.activeProfile?.callsign ?? '').trim();
    if (_lastPeerCall == myCall && _lastPeerCall.isNotEmpty) return;
    _dbg('auto-pair: opening GATT to $_lastPeerCall (legacy plugin)');
    _gatt!.considerPeer(peer);
  }

  // Resume the shared BLE5 extended scan after a GATT connect/transfer ends.
  void _resumeBle5Scan() {
    if (_ble5 && _scanRefs > 0) unawaited(Ble5Bus.instance.startScan());
  }

  /// Periodic broadcast housekeeping: sweep stale partials/dedup, then emit a
  /// NACK for any incomplete partial that has stalled (a multi-chunk message we
  /// caught only part of). The sender hears its own srcTag and re-airs the
  /// missing chunks. While requests are outstanding, bias toward scanning so we
  /// catch the resends.
  void _bcastTick() {
    _bcast.sweep();
    // Prune the BLE5 single-frame dedup table.
    if (_ble5Seen.isNotEmpty) {
      final now = DateTime.now();
      _ble5Seen.removeWhere((_, t) => now.difference(t) > kBleBcastDedup);
    }
    // Drop an idle auto-paired GATT link so the radio returns to the
    // connectionless broadcast (APRS + RNS announces) when no transfer is active.
    // Only the CLIENT side disconnects (the dialer); the server lets the central
    // leave. On BLE5 this is the native client link.
    final linkUp = _ngClientUp || (_gatt?.isConnected ?? false);
    if (linkUp && _gattActivityMs > 0) {
      final idle = DateTime.now().millisecondsSinceEpoch - _gattActivityMs;
      if (idle > _gattIdleMs) {
        _dbg('GATT idle ${idle ~/ 1000}s — disconnecting to resume broadcast');
        if (_ngClientUp) {
          unawaited(Ble5Bus.instance.gattDisconnect());
        } else {
          unawaited(_gatt!.disconnect());
        }
      }
    }
    // The legacy chunk/NACK ARQ is retired on BLE5 devices — never emit NACKs
    // (they thrash the single advertiser and clobber the connectable beacon).
    if (_ble5) return;
    final reqs = _bcast.partialsNeedingNack(
        idle: const Duration(seconds: 4), maxRetries: 4);
    if (reqs.isEmpty) {
      if (_awaitingResend) {
        _awaitingResend = false;
      }
      return;
    }
    final wasAwaiting = _awaitingResend;
    _awaitingResend = true;
    for (final r in reqs) {
      final frame =
          BleBroadcastReassembler.buildNack(r.srcTag, r.msgId, r.total, r.missing);
      if (frame == null) continue;
      if (frame.length > (_useBlePeripheral ? 20 : 24)) {
        // Too many missing indices to fit one advert — request the lowest few
        // that do fit; subsequent ticks will request the rest.
        continue;
      }
      _dbg('emit NACK msgId=${r.msgId} tag=${r.srcTag} missing=${r.missing}');
      _enqueueControl(frame);
      _bcast.markNacked(r.srcTag, r.msgId);
    }
    // NOTE: do NOT re-arm the Android scan here. Android already scans
    // continuously (no duty-cycle), and stop+start discovery during recovery
    // trips Android's "scanning too frequently" throttle (max ~5 starts/30s),
    // which disables the scanner mid-transfer — fatal for multi-chunk messages
    // like RNS announces. The continuous scan picks up the re-aired chunks.
    if (wasAwaiting) {/* still awaiting; nothing to do */}
  }

  /// A peer asked us (by our [srcTag]) to re-air specific chunks of one of our
  /// broadcast messages. Find those chunks still queued, boost + refresh them,
  /// and air the first one immediately. Chunks already expired/superseded can't
  /// be re-aired (we no longer hold the payload) — log and skip them gracefully.
  void _onNack(Uint8List d) {
    if (_ble5) return; // legacy chunk ARQ retired on BLE5 (no re-air thrash)
    final req = BleBroadcastReassembler.parseNack(d);
    if (req == null) return;
    if (req.srcTag != _srcTag) return; // not addressed to us
    final now = DateTime.now().millisecondsSinceEpoch;
    final boostUntil = now + 4000;
    final reaired = <int>[];
    final missing = <int>[];
    for (final idx in req.missing) {
      _Advert? hit;
      for (final a in _adverts) {
        final p = a.payload;
        if (p.length > kBleBcastPrimaryHdr &&
            p[1] == kBleBcastPrimary &&
            p[2] == req.srcTag &&
            p[3] == req.msgId &&
            p[4] == idx) {
          hit = a;
          break;
        }
      }
      if (hit != null) {
        hit.boostUntilMs = boostUntil;
        if (hit.expiresMs < boostUntil) hit.expiresMs = boostUntil;
        reaired.add(idx);
      } else {
        missing.add(idx);
      }
    }
    _dbg('NACK rx msgId=${req.msgId} '
        'reair=$reaired${missing.isEmpty ? "" : " gone=$missing"}');
    if (reaired.isNotEmpty) {
      _rotateIdx = 0;
      _rotate();
    }
  }

  Future<bool> startScan() async {
    await _ensure();
    // Start the shared BLE5 extended scan (also feeds Reticulum). Independent of
    // the legacy _central scan, which still runs for legacy/ESP32 peers.
    if (_ble5) await Ble5Bus.instance.startScan();
    if (_central == null) return _ble5; // BLE5-only is still usable
    _scanRefs++;
    // The adapter may not report poweredOn immediately after init (Android
    // reads state asynchronously); wait briefly so the first scan isn't lost.
    await _awaitPoweredOn();
    await _applyScan();
    // Become a connectable peer for large-file GATT transfer. On BLE5 the entire
    // endpoint is NATIVE: one coordinated GATT server + legacy connectable advert
    // + legacy discovery scan (avoids the dual-plugin handle-cache confusion that
    // dropped writes and broke notify). On non-BLE5 devices, fall back to the
    // ble_peripheral server + a legacy connectable presence beacon. No-op on
    // Linux/BlueZ.
    final cs = ProfileService.instance.activeProfile?.callsign ?? '';
    if (_ble5) {
      unawaited(Ble5Bus.instance.startServer(cs.isEmpty ? 'AURORA' : cs));
    } else if (_gattServer?.isRunning != true) {
      unawaited(_gattServer?.start(cs, advertise: true) ?? Future<void>.value());
    }
    return true;
  }

  Future<void> _awaitPoweredOn() async {
    final c = _central;
    if (c == null) return;
    for (var i = 0; i < 20; i++) {
      if (c.state == BluetoothLowEnergyState.poweredOn) return;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  Future<void> stopScan() async {
    if (_scanRefs > 0) _scanRefs--;
    await _applyScan();
  }

  // Called on app resume: if we still want to scan, force a fresh discovery in
  // case Android quietly stopped it while we were paused (our _scanning flag
  // would otherwise stay true and _applyScan would never restart it).
  Future<void> _reArmScan() async {
    if (_scanRefs <= 0 || _central == null) return;
    if (_scanning) {
      try { await _central!.stopDiscovery(); } catch (_) {}
      _scanning = false;
    }
    await _applyScan();
  }

  Future<void> _applyScan() async {
    final c = _central;
    if (c == null) return;
    // While the BlueZ backend is duty-cycling (it can't scan and advertise at
    // once), the rotation owns discovery — don't fight it here.
    if (_dutyCycling) return;
    // Pause scanning while any GATT link is up (we are a client of a peer, OR a
    // peer is connected to our server) — scan and connection contend on a single
    // radio and the link drops otherwise. This is what kept the phone<->desktop
    // link from holding (the serving side kept scanning).
    final serverBusy = (_gattServer?.clientIds.isNotEmpty ?? false) ||
        _ngServerCentral != null;
    final want =
        _scanRefs > 0 && !_gattLinkUp && !_ngClientUp && !serverBusy;
    try {
      if (want && !_scanning && c.state == BluetoothLowEnergyState.poweredOn) {
        await c.startDiscovery();
        _scanning = true;
      } else if (!want && _scanning) {
        await c.stopDiscovery();
        _scanning = false;
      }
    } catch (e) {
      debugPrint('BleService: scan toggle failed: $e');
    }
  }

  // True only on the BlueZ backend when we both want to scan AND have something
  // to advertise: a single controller can't scan and advertise at once, so the
  // rotation time-slices it and _applyScan must not also drive discovery.
  // Android/iOS (ble_peripheral) support concurrent scan+advertise, so they do
  // NOT duty-cycle — they scan continuously AND keep the advert latched on air
  // (a duty-cycled, bursty advert is missed by a peer that is also duty-cycling).
  bool get _dutyCycling =>
      !_useBlePeripheral && _adverts.isNotEmpty && _scanRefs > 0;

  // ── Outbound advertising ──────────────────────────────────────────
  // BLE here is receive-first: a node listens (scans) continuously and only
  // transmits a frame as a brief burst when it actually has something to send.
  // Peers are listening, so a short burst is enough; we don't hold the radio
  // advertising indefinitely.
  void enqueueAdvert(Object owner, Uint8List payload,
      {Duration ttl = const Duration(seconds: 10)}) {
    _ensure();
    // Size router. SMALL → connectionless one-to-many broadcast (one sender,
    // many listeners, aired ONCE, never per-peer). LARGE → point-to-point GATT
    // (a binary file / RNS resource), which auto-pairs a transient link.
    // The BLE5 cap is THIS controller's real advert ceiling (many chips carry
    // only ~247 B, far under the 450 B spec-side default) — an over-cap frame
    // is rejected by the stack, not truncated, so it must go GATT instead.
    final smallCap = _ble5 ? Ble5Bus.instance.maxPayload : kBleBcastMax;
    // Mesh custody tap on our own outbound 1:1s: parked in-transit so the
    // GATT plane also owes delivery. BEFORE the size router — encrypted 1:1s
    // exceed the advert cap and never reach the broadcast path at all.
    MeshCustodyDelegate.onAirFrame(payload, outbound: true);
    if (payload.length > smallCap) {
      _gattSend(payload);
      return;
    }
    // BLE5 path (preferred): a whole APRS message fits ONE extended advert, so
    // register it as a single frame on the shared bus (no chunking, no NACK).
    // Keyed by payload hash so the wapp's periodic re-advertise refreshes it.
    if (_ble5) {
      final key = 'aprs:${_hashHex(payload)}';
      final keys = _ble5Keys.putIfAbsent(owner, () => <String>{});
      final fresh = keys.add(key);
      if (keys.length > 64) keys.remove(keys.first);
      if (fresh) _dbg('BLE5 APRS advert ${payload.length}B key=$key');
      Ble5Bus.instance.advertiseFrame(key, Ble5Subtype.aprs, payload, ttl: ttl);
      return;
    }
    // Legacy small-chunk connectionless broadcast (non-BLE5 devices).
    _enqueueBroadcast(owner, payload, ttl);
  }

  // Large payloads await a GATT link; auto-pair opens one on the next discovered
  // peer, then [_flushPendingGatt] sends them. Bounded so a peer that never
  // appears can't grow this unbounded.
  final List<Uint8List> _pendingGatt = [];
  // Most recently discovered connectable Aurora peer. Android dedups scan
  // results (a peer is reported once, then suppressed), so we remember the last
  // one and dial it when data is queued — not only on a fresh discovery event.
  Peripheral? _lastPeer;
  String _lastPeerCall = '';
  String _lastPeerAddr = ''; // BLE MAC for the native connect path (from beacon)
  int _lastPeerMs = 0;
  static const int _peerFreshMs = 60000;
  // Native GATT (BLE5 devices): the whole transfer endpoint is native — server +
  // client + legacy connectable advert + legacy discovery scan, one coordinated
  // stack. _ngClientPeer is the address we dialed; _ngServerCentral is the
  // address of a central connected to our server.
  bool _ngClientUp = false;
  String? _ngClientPeer;
  String? _ngServerCentral;

  /// Send a large payload point-to-point over GATT. If a link is up, enqueue it
  /// to the connected peer(s); otherwise stash it and let auto-pair open a link.
  void _gattSend(Uint8List payload) {
    final peers = _connectedPeers();
    if (peers.isNotEmpty) {
      for (final id in peers) {
        _queue.enqueue(BLEOutgoingMessage(payload: payload, targetDeviceId: id));
      }
      _dbg('GATT send ${payload.length}B to ${peers.length} peer(s)');
      return;
    }
    _pendingGatt.add(payload);
    if (_pendingGatt.length > 16) _pendingGatt.removeAt(0);
    _dbg('GATT: ${payload.length}B queued, awaiting auto-pair link');
    _maybeAutoPair(); // dial the last-seen peer now (Android won't re-report it)
  }

  final Object _testOwner = Object();

  /// GATT auto-pair status (for diagnostics / the remote API).
  Map<String, dynamic> gattStatus() => {
        'autoPair': PreferencesService.instanceSync?.bleAutoPair ?? true,
        'ble5': _ble5,
        'native': _ble5,
        'clientLinkUp': _ngClientUp || (_gatt?.isConnected ?? false),
        'clientPeer': _ngClientPeer ?? _gatt?.peerId,
        'serverClients': _ngServerCentral != null
            ? [_ngServerCentral!]
            : (_gattServer?.clientIds.toList() ?? <String>[]),
        'pendingGatt': _pendingGatt.length,
        'lastPeer': _ble5
            ? (_lastPeerAddr.isEmpty ? null : _lastPeerAddr)
            : _lastPeer?.uuid.toString(),
        'idleMs': _gattActivityMs == 0
            ? null
            : DateTime.now().millisecondsSinceEpoch - _gattActivityMs,
      };

  /// Test helper: send [size] bytes point-to-point over GATT. Larger than the
  /// broadcast cap, so it routes through the auto-pairing GATT path.
  void gattSendTest(int size) {
    final n = size < 1 ? 1 : (size > 8192 ? 8192 : size);
    final blob = Uint8List(n);
    for (var i = 0; i < n; i++) {
      blob[i] = 0x41 + (i % 26); // A..Z filler
    }
    _dbg('gattSendTest: ${n}B');
    enqueueAdvert(_testOwner, blob, ttl: const Duration(seconds: 30));
  }

  /// Flush stashed large payloads to the freshly-connected peer.
  void _flushPendingGatt() {
    final peer = (_ngClientUp ? _ngClientPeer : null) ?? _gatt?.peerId;
    if (peer == null || _pendingGatt.isEmpty) return;
    for (final p in _pendingGatt) {
      _queue.enqueue(BLEOutgoingMessage(payload: p, targetDeviceId: peer));
    }
    _dbg('GATT: flushed ${_pendingGatt.length} pending payload(s) to $peer');
    _pendingGatt.clear();
  }

  // Rolling per-message id (1 byte) grouping a broadcast's chunks; paired with
  // the source address on the receiver to dedup across many advertisers.
  int _bcastTxMsgId = 0;

  /// Split [payload] (<= [kBleBcastMax]) into broadcast-parcel chunks and queue
  /// them into the advert rotation. Each chunk is one ADV-only manufacturer
  /// field `[3E 50 srcTag msgId idx total flags data]` — neither ble_peripheral
  /// nor the BlueZ backend exposes scan-response data, so flags bit0
  /// (continuation) is always 0 and the per-chunk payload is bounded by the
  /// legacy advert size. [srcTag] lets a receiver address a NACK back to us.
  void _enqueueBroadcast(Object owner, Uint8List payload, Duration ttl) {
    final cap = (_useBlePeripheral ? 20 : 24) - kBleBcastPrimaryHdr;
    final tag = _srcTag;
    final msgId = _bcastTxMsgId = (_bcastTxMsgId + 1) & 0xFF;
    final total = payload.isEmpty ? 1 : ((payload.length + cap - 1) ~/ cap);
    // Keep the whole chunk set on air long enough for at least two full rotation
    // cycles so a scanner that joins mid-cycle still collects every chunk.
    final cycleMs = total * _rotateIntervalMs;
    final effectiveMs =
        ttl.inMilliseconds > cycleMs * 2 ? ttl.inMilliseconds : cycleMs * 2 + 2000;
    final expiresMs = DateTime.now().millisecondsSinceEpoch + effectiveMs;
    _dbg('enqueue broadcast (legacy) ${payload.length}B '
        '($total chunk${total == 1 ? "" : "s"}, on-air ${effectiveMs ~/ 1000}s, '
        'msgId=$msgId tag=$tag)');
    for (var idx = 0; idx < total; idx++) {
      final off = idx * cap;
      final end = (off + cap < payload.length) ? off + cap : payload.length;
      final chunk = payload.sublist(off, end);
      final adv = Uint8List(kBleBcastPrimaryHdr + chunk.length)
        ..[0] = kBleMarker
        ..[1] = kBleBcastPrimary
        ..[2] = tag
        ..[3] = msgId
        ..[4] = idx
        ..[5] = total
        ..[6] = 0 // flags: ADV-only, no scan-response continuation
        ..setRange(kBleBcastPrimaryHdr, kBleBcastPrimaryHdr + chunk.length, chunk);
      _adverts.add(_Advert(owner, adv, expiresMs));
    }
    _rotateTimer ??= Timer.periodic(
        const Duration(milliseconds: _rotateIntervalMs), (_) => _rotate());
    _rotate();
  }

  /// Queue a short-lived control frame (e.g. a NACK) straight into the advert
  /// rotation, bypassing the chunking/air-time-extension of [_enqueueBroadcast]
  /// (a control frame must NOT be pinned on air for a message's whole TTL). The
  /// frame is also boosted so the rotation airs it promptly.
  void _enqueueControl(Uint8List frame, {Duration ttl = const Duration(seconds: 6)}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _adverts.add(_Advert(_ctrlOwner, frame, now + ttl.inMilliseconds,
        boostUntilMs: now + ttl.inMilliseconds));
    _rotateTimer ??= Timer.periodic(
        const Duration(milliseconds: _rotateIntervalMs), (_) => _rotate());
    _rotate();
  }

  // Advert rotation tick. Must stay below kBleBcastWindow so a receiver's
  // partial survives across one full chunk cycle (a new chunk each tick resets
  // its drop timer).
  static const int _rotateIntervalMs = 900;

  void clearAdverts(Object owner) {
    // Drop this owner's BLE5 broadcast frames from the shared bus.
    final ble5Keys = _ble5Keys.remove(owner);
    if (ble5Keys != null) {
      for (final k in ble5Keys) {
        Ble5Bus.instance.removeFrame(k);
      }
    }
    _adverts.removeWhere((a) => a.owner == owner);
    if (_adverts.isEmpty) {
      _stopRotation();
      _stopAdvertise();
      _applyScan(); // resume continuous scanning now the radio is free
    }
  }

  // Legacy broadcast-advert rotation — deprecated by the GATT parcel transport
  // and no longer driven (kept for reference / possible non-Linux fallback).
  // ignore: unused_element
  Future<void> _rotate() async {
    if (_rotating) return; // don't let slow ticks overlap
    _rotating = true;
    try {
      await _rotateBody();
    } finally {
      _rotating = false;
    }
  }

  Future<void> _rotateBody() async {
    await _ensure();
    if (!_advertiseSupported) {
      _stopRotation();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    _adverts.removeWhere((a) => a.expiresMs <= now);
    // On the legacy BlueZ backend, drop anything that won't fit a 31-byte
    // advert (once), rather than retrying it forever.
    // Drop frames that won't fit a 31-byte legacy advert (once), rather than
    // retrying them forever. The package/Android backend has less room than
    // BlueZ because Android prepends a 3-byte flags AD to connectable adverts
    // (max manufacturer payload ~24B vs ~27B on BlueZ).
    {
      // ble_peripheral advert also carries flags (3B) + the 0xFFE0 service
      // UUID (4B), leaving ~20B of manufacturer payload in a legacy advert.
      // BlueZ prepends only flags (3B) to a peripheral advert, so the usable
      // manufacturer payload is 31 - 3(flags) - 2(AD len+type) - 2(company id)
      // = 24B. A larger frame is rejected by the controller with
      // "Invalid Parameters" and, left queued, forces BlueZ into a scan/advertise
      // duty cycle that drops incoming frames — so drop it here instead.
      final maxLen = _useBlePeripheral ? 20 : 24;
      int dropped = 0;
      _adverts.removeWhere((a) {
        if (a.payload.length > maxLen) { dropped++; return true; }
        return false;
      });
      if (dropped > 0) {
        final t = DateTime.now().millisecondsSinceEpoch;
        if (t - _dropLogMs > 10000) {
          _dropLogMs = t;
          _dbg('dropped $dropped BLE frame(s) too long for '
              'legacy advertising (>${maxLen}B)');
        }
      }
    }
    if (_adverts.isEmpty) {
      _stopRotation();
      await _stopAdvertise();
      await _applyScan();
      return;
    }
    // Boost-aware rotation: while any advert is boosted (a NACK frame, or a
    // chunk a peer just asked us to re-air), rotate ONLY among the boosted set so
    // those air rapidly instead of waiting their turn behind every queued chunk.
    final boosted = _adverts.where((a) => a.boostUntilMs > now).toList();
    final active = boosted.isNotEmpty ? boosted : _adverts;
    if (_rotateIdx >= active.length) _rotateIdx = 0;
    final payload = active[_rotateIdx++].payload;

    // Android/iOS (ble_peripheral) — or when nothing is being received —
    // advertise continuously and concurrently with scanning. Keeping the frame
    // latched on air (see the skip in _advertiseFrame) is what lets a peer that
    // is itself duty-cycling actually catch it. _applyScan keeps scanning.
    if (_useBlePeripheral || _scanRefs == 0) {
      await _advertiseFrame(payload);
      return;
    }

    // BlueZ + scanning: a single controller can't do both at once, so
    // time-slice — mostly scan, one tick in three a brief advertise burst. While
    // awaiting resends, scan even more (1-in-4) so we catch the re-aired chunks.
    final period = _awaitingResend ? 4 : 3;
    _dutyTick = (_dutyTick + 1) % period;
    if (_dutyTick == 0) {
      await _stopScanWindow();
      await _advertiseFrame(payload);
    } else {
      await _stopAdvertise();
      await _startScanWindow();
    }
  }

  /// Advertise one frame via whichever backend is available (ble_peripheral on
  /// Android/iOS, else BlueZ). On the ble_peripheral path the frame is latched
  /// (timeout: 0) and kept on air — re-registering only when the payload
  /// changes — so a single message stays continuously broadcast for its TTL
  /// rather than churning start/stop each tick (which a duty-cycling peer
  /// would miss).
  Future<void> _advertiseFrame(Uint8List payload) async {
    if (_useBlePeripheral) {
      if (!_blePeripheralReady) return;
      final hex = _hex(payload);
      if (_pkgAdvertHex == hex) return; // already on air with this frame
      try {
        await bp.BlePeripheral.stopAdvertising();
        // Advertise ONLY the manufacturer data — no service UUID, no name. The
        // ffe0 UUID is a 128-bit string here; including it (18B) plus flags (3B)
        // plus our manufacturer data (~24B) overflows the 31-byte legacy advert,
        // which makes Android silently switch to EXTENDED advertising — invisible
        // to the ESP32's legacy scanner, so the iGate never hears the phone.
        // Receivers don't need it: the central scan is unfiltered and matches on
        // company id 0xFFFF, not the service UUID.
        await bp.BlePeripheral.startAdvertising(
          services: const [],
          manufacturerData: bp.ManufacturerData(
            manufacturerId: kBleCompanyId,
            data: payload,
          ),
        );
        _pkgAdvertHex = hex;
      } catch (e) {
        _pkgAdvertHex = null;
        _warnThrottled('advertise failed: $e');
      }
      return;
    }
    if (await _bluezReady()) await _bzRegister(payload);
  }

  Future<void> _startScanWindow() async {
    final c = _central;
    if (c == null || _scanning) return;
    try {
      if (c.state == BluetoothLowEnergyState.poweredOn) {
        await c.startDiscovery();
        _scanning = true;
      }
    } catch (_) {}
  }

  Future<void> _stopScanWindow() async {
    final c = _central;
    if (c == null || !_scanning) return;
    try {
      await c.stopDiscovery();
    } catch (_) {}
    _scanning = false;
  }

  Future<void> _bzRegister(Uint8List payload) async {
    final hex = _hex(payload);
    // Already advertising exactly this payload — don't churn the controller
    // (re-registering the same advert every tick is what triggers BlueZ
    // "Failed to register advertisement").
    if (_bzAdvert != null && _bzRegisteredHex == hex) return;
    try {
      await _bzUnadvertise();
      _bzAdvert = await _bzAdapter!.advertisingManager.registerAdvertisement(
        type: BlueZAdvertisementType.peripheral,
        manufacturerData: {
          BlueZManufacturerId(kBleCompanyId): DBusArray.byte(payload),
        },
      );
      _bzRegisteredHex = hex;
    } catch (e) {
      _warnThrottled('advertise failed: $e');
      final s = e.toString();
      if (s.contains('UnknownObject') || s.contains("doesn't exist")) {
        // The adapter/advertising object went away — drop refs so the next
        // tick reconnects via _bluezReady() instead of failing forever.
        _bzAdapter = null;
        _bzAdvert = null;
        _bzRegisteredHex = null;
      }
    }
  }

  Future<void> _bzUnadvertise() async {
    if (_bzAdvert != null && _bzAdapter != null) {
      try {
        await _bzAdapter!.advertisingManager.unregisterAdvertisement(_bzAdvert!);
      } catch (_) {}
      _bzAdvert = null;
    }
    _bzRegisteredHex = null;
  }

  Future<void> _stopAdvertise() async {
    if (_useBlePeripheral) {
      try {
        await bp.BlePeripheral.stopAdvertising();
      } catch (_) {}
      _pkgAdvertHex = null;
      // Android has one advertiser: airing broadcast chunks clobbered the GATT
      // server's presence beacon. Now the rotation is idle, restore presence as
      // the steady-state advert so peers (and the ESP32 iGate) keep hearing our
      // callsign rather than going silent until the next reconnect.
      if (_gattServer?.isRunning == true) {
        unawaited(_gattServer!.readvertise());
      }
    }
    await _bzUnadvertise();
  }

  void _stopRotation() {
    _rotateTimer?.cancel();
    _rotateTimer = null;
    _rotateIdx = 0;
  }
}

/// Re-arms the BLE scan when the app returns to the foreground. Android can
/// silently stop a scan while the app is paused (screen off); this forces a
/// fresh discovery on resume so reception recovers without a manual toggle.
class _BleLifecycleObserver extends WidgetsBindingObserver {
  _BleLifecycleObserver(this._svc);
  final BleService _svc;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // ignore: invalid_use_of_protected_member, unawaited_futures
      _svc._reArmScan();
    }
  }
}
