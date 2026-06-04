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
  PeripheralManager? _peripheral;
  bool _inited = false;
  bool _advertiseSupported = true;

  // Linux advertising fallback via BlueZ D-Bus (the bluetooth_low_energy
  // package has no Linux peripheral). Transparent to wapps — hal_ble_advertise
  // works the same; the host just uses a different backend here.
  bool _useBluez = false;
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

  Future<void> _ensure() async {
    if (_inited) return;
    _inited = true;
    try {
      _central = CentralManager();
      try {
        await _central!.authorize();
      } catch (_) {}
      // Permanent discovered subscription; frames only flow while scanning.
      _central!.discovered.listen(_onDiscovered);
      _central!.stateChanged.listen((_) => _applyScan());
    } catch (e) {
      _central = null;
      debugPrint('BleService: central unavailable: $e');
    }
    try {
      _peripheral = PeripheralManager();
      try {
        await _peripheral!.authorize();
      } catch (_) {}
    } catch (e) {
      _peripheral = null;
      // No package peripheral here — on Linux fall back to BlueZ D-Bus so
      // advertising (send) still works; elsewhere it's genuinely unsupported.
      if (Platform.isLinux) {
        _useBluez = true;
        _advertiseSupported = true;
        debugPrint('BleService: using BlueZ D-Bus for advertising');
      } else {
        _advertiseSupported = false;
        debugPrint('BleService: advertising unavailable (scan-only): $e');
      }
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
      _useBluez = false;
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
    await _applyScan();
    return true;
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

  // True when BlueZ is the advertising backend AND we have something to
  // advertise AND we also want to scan — i.e. we must time-slice the radio.
  bool get _dutyCycling =>
      _peripheral == null && _useBluez && _adverts.isNotEmpty && _scanRefs > 0;

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
      _bzAdv = false;
      _stopAdvertise();
      _applyScan(); // resume continuous scanning now the radio is free
    }
  }

  Future<void> _rotate() async {
    await _ensure();
    if (!_advertiseSupported) {
      _stopRotation();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    _adverts.removeWhere((a) => a.expiresMs <= now);
    // On the legacy BlueZ backend, drop anything that won't fit a 31-byte
    // advert (once), rather than retrying it forever.
    if (_peripheral == null && _useBluez) {
      _adverts.removeWhere((a) {
        if (a.payload.length > 27) {
          debugPrint('BleService: BLE frame too long for legacy advertising '
              '(${a.payload.length}B); dropped');
          return true;
        }
        return false;
      });
    }
    if (_adverts.isEmpty) {
      _stopRotation();
      _bzAdv = false;
      await _stopAdvertise();
      await _applyScan();
      return;
    }
    if (_rotateIdx >= _adverts.length) _rotateIdx = 0;
    final payload = _adverts[_rotateIdx++].payload;

    // Concurrent-capable backend (package peripheral): just (re)advertise.
    final p = _peripheral;
    if (p != null) {
      try {
        if (p.state != BluetoothLowEnergyState.poweredOn) return;
        await p.stopAdvertising();
        await p.startAdvertising(Advertisement(manufacturerSpecificData: [
          ManufacturerSpecificData(id: kBleCompanyId, data: payload),
        ]));
      } catch (e) {
        debugPrint('BleService: advertise failed: $e');
      }
      return;
    }

    // BlueZ backend: this controller can't scan + advertise at once, so when
    // we also want to scan we alternate advertise/scan windows each tick.
    if (!await _bluezReady()) return;
    if (_scanRefs == 0) {
      await _bzRegister(payload); // advertise continuously, nothing to receive
      return;
    }
    if (_bzAdv) {
      await _bzUnadvertise(); // → scan window
      _bzAdv = false;
      try {
        if (!_scanning) { await _central!.startDiscovery(); _scanning = true; }
      } catch (_) {}
    } else {
      try {
        if (_scanning) { await _central!.stopDiscovery(); _scanning = false; }
      } catch (_) {}
      await _bzRegister(payload); // → advertise window
      _bzAdv = true;
    }
  }

  bool _bzAdv = false; // current BlueZ duty phase (true = advertising)

  Future<void> _bzRegister(Uint8List payload) async {
    try {
      await _bzUnadvertise();
      _bzAdvert = await _bzAdapter!.advertisingManager.registerAdvertisement(
        type: BlueZAdvertisementType.peripheral,
        manufacturerData: {
          BlueZManufacturerId(kBleCompanyId): DBusArray.byte(payload),
        },
      );
    } catch (e) {
      debugPrint('BleService: advertise failed: $e');
    }
  }

  Future<void> _bzUnadvertise() async {
    if (_bzAdvert != null && _bzAdapter != null) {
      try {
        await _bzAdapter!.advertisingManager.unregisterAdvertisement(_bzAdvert!);
      } catch (_) {}
      _bzAdvert = null;
    }
  }

  Future<void> _stopAdvertise() async {
    try {
      await _peripheral?.stopAdvertising();
    } catch (_) {}
    await _bzUnadvertise();
  }

  void _stopRotation() {
    _rotateTimer?.cancel();
    _rotateTimer = null;
    _rotateIdx = 0;
  }
}
