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

/// APRS-over-BLE manufacturer id carried in advertisement manufacturer data.
/// Must match peer firmware (e.g. ESP32). 0xFFFF is the reserved test id.
const int kBleCompanyId = 0xFFFF;

class BleInboundFrame {
  final String from; // peer uuid
  final int rssi;
  final Uint8List data; // the manufacturer payload (e.g. an APRS TNC2 frame)
  BleInboundFrame(this.from, this.rssi, this.data);
}

class _Advert {
  final Object owner;
  final Uint8List payload;
  final int expiresMs;
  _Advert(this.owner, this.payload, this.expiresMs);
}

class BleService {
  BleService._();
  static final BleService instance = BleService._();

  CentralManager? _central;
  bool _inited = false;
  bool _advertiseSupported = true;

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

  final _inbound = StreamController<BleInboundFrame>.broadcast();
  Stream<BleInboundFrame> get inbound => _inbound.stream;

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
  String _lastWarn = '';
  int _lastWarnMs = 0;
  int _dropLogMs = 0;

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

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
    for (final m in e.advertisement.manufacturerSpecificData) {
      if (m.id == kBleCompanyId && m.data.isNotEmpty) {
        _inbound.add(BleInboundFrame(e.peripheral.uuid.toString(), e.rssi, m.data));
      }
    }
  }

  Future<bool> startScan() async {
    await _ensure();
    if (_central == null) return false;
    _scanRefs++;
    // The adapter may not report poweredOn immediately after init (Android
    // reads state asynchronously); wait briefly so the first scan isn't lost.
    await _awaitPoweredOn();
    await _applyScan();
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

  Future<void> _applyScan() async {
    final c = _central;
    if (c == null) return;
    // While the BlueZ backend is duty-cycling (it can't scan and advertise at
    // once), the rotation owns discovery — don't fight it here.
    if (_dutyCycling) return;
    final want = _scanRefs > 0;
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

  // True whenever we both want to scan AND have something to advertise — then
  // the rotation owns the radio and time-slices it (scan-primary), so
  // _applyScan must not also drive discovery. This holds for BOTH backends:
  // BlueZ literally can't scan+advertise at once, and on Android doing both
  // concurrently makes the outbound advert unreliable on some chipsets. We
  // are a receiver first — advertise only in brief bursts between scans.
  bool get _dutyCycling => _adverts.isNotEmpty && _scanRefs > 0;

  // ── Outbound advertising ──────────────────────────────────────────
  void enqueueAdvert(Object owner, Uint8List payload,
      {Duration ttl = const Duration(seconds: 30)}) {
    if (!_advertiseSupported) {
      // Try to (lazily) discover support; if none, drop quietly.
      _ensure();
      if (!_advertiseSupported) return;
    }
    final exp = DateTime.now().millisecondsSinceEpoch + ttl.inMilliseconds;
    _adverts.add(_Advert(owner, payload, exp));
    _rotateTimer ??=
        Timer.periodic(const Duration(milliseconds: 1500), (_) => _rotate());
    _rotate();
  }

  void clearAdverts(Object owner) {
    _adverts.removeWhere((a) => a.owner == owner);
    if (_adverts.isEmpty) {
      _stopRotation();
      _stopAdvertise();
      _applyScan(); // resume continuous scanning now the radio is free
    }
  }

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
      final maxLen = _useBlePeripheral ? 24 : 27;
      int dropped = 0;
      _adverts.removeWhere((a) {
        if (a.payload.length > maxLen) { dropped++; return true; }
        return false;
      });
      if (dropped > 0) {
        final t = DateTime.now().millisecondsSinceEpoch;
        if (t - _dropLogMs > 10000) {
          _dropLogMs = t;
          debugPrint('BleService: dropped $dropped BLE frame(s) too long for '
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
    if (_rotateIdx >= _adverts.length) _rotateIdx = 0;
    final payload = _adverts[_rotateIdx++].payload;

    // Nothing to receive → advertise continuously.
    if (_scanRefs == 0) {
      await _advertiseFrame(payload);
      return;
    }

    // Scan-primary duty cycle: we are a receiver first. Spend most ticks
    // scanning and only one tick in three on a brief advertise burst, so the
    // outbound frame radiates cleanly (never concurrent with scanning, which
    // is unreliable on BlueZ and on some Android chipsets) while a peer that
    // is also scanning still catches the burst.
    _dutyTick = (_dutyTick + 1) % 3;
    if (_dutyTick == 0) {
      await _stopScanWindow();
      await _advertiseFrame(payload);
    } else {
      await _stopAdvertise();
      await _startScanWindow();
    }
  }

  /// Advertise one frame via whichever backend is available (package
  /// PeripheralManager, else BlueZ). The caller owns the scan/advertise
  /// time-slicing.
  Future<void> _advertiseFrame(Uint8List payload) async {
    if (_useBlePeripheral) {
      if (!_blePeripheralReady) return;
      try {
        await bp.BlePeripheral.stopAdvertising();
        await bp.BlePeripheral.startAdvertising(
          services: const [],
          manufacturerData: bp.ManufacturerData(
            manufacturerId: kBleCompanyId,
            data: payload,
          ),
        );
      } catch (e) {
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
    }
    await _bzUnadvertise();
  }

  void _stopRotation() {
    _rotateTimer?.cancel();
    _rotateTimer = null;
    _rotateIdx = 0;
  }
}
