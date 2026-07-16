/*
 * CapacityGovernor — auto-configures the file-serving policy from the device's
 * physical situation, so users don't have to tune quotas by hand.
 *
 * The intuition: a device plugged into the charger on Wi-Fi/Ethernet is a great
 * provider — serve without limits. On battery + Wi-Fi, serve but within the daily
 * budget. On cellular, only serve if the user allowed it, and then sparingly. With
 * no network, don't serve. It re-evaluates when power state changes and on a slow
 * poll (network changes aren't event-driven without a connectivity plugin).
 *
 * The pure (network, charging) -> profile mapping lives in capacity_policy.dart
 * (headlessly testable). This file is the runtime: battery state, prefs, the
 * interface-name network heuristic, timers, and applying the profile via a
 * callback (rns_service wires that to the ServeQuota + advertised capacity class).
 */
import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';

import '../log_service.dart';
import '../preferences_service.dart';
import 'capacity_policy.dart';

export 'capacity_policy.dart' show NetKind, CapacityProfile, policyFor;

class CapacityGovernor {
  CapacityGovernor._();
  static final CapacityGovernor instance = CapacityGovernor._();

  final Battery _battery = Battery();
  StreamSubscription<BatteryState>? _sub;
  Timer? _poll;
  bool _running = false;
  void Function(CapacityProfile)? _apply;
  NetKind? _override;

  NetKind lastNet = NetKind.none;
  bool lastCharging = false;
  CapacityProfile? lastProfile;

  /// Start governing; [apply] receives each new profile (idempotent restart).
  Future<void> start({required void Function(CapacityProfile) apply}) async {
    _apply = apply;
    if (_running) {
      await evaluate();
      return;
    }
    _running = true;
    await evaluate();
    try {
      _sub = _battery.onBatteryStateChanged.listen((_) => evaluate());
    } catch (_) {}
    _poll = Timer.periodic(const Duration(minutes: 1), (_) => evaluate());
  }

  void stop() {
    _running = false;
    _sub?.cancel();
    _sub = null;
    _poll?.cancel();
    _poll = null;
  }

  /// Force a specific network kind (e.g. from a connectivity plugin / the UI).
  /// Pass null to return to auto-detection.
  void setNetworkOverride(NetKind? kind) {
    _override = kind;
    if (_running) evaluate();
  }

  Future<void> evaluate() async {
    final net = _override ?? await detectNetwork();
    var charging = false;
    try {
      final s = await _battery.batteryState;
      // A battery-less desktop/server reports `unknown` (the plugin doesn't
      // throw on Linux when there's no battery) — treat it as on mains power so
      // always-on machines qualify as unlimited providers/indexers. Only a real
      // battery that is discharging keeps charging=false.
      // "On power" means PLUGGED IN, not necessarily actively charging. A phone
      // sitting at 100% on a charger reports `connectedNotCharging` (or `full`) —
      // it is still mains-powered and should qualify as an indexer, per the role
      // design ("plugged to electricity + WiFi"). Only a real battery that is
      // discharging keeps charging=false.
      charging = s == BatteryState.charging ||
          s == BatteryState.full ||
          s == BatteryState.connectedNotCharging ||
          s == BatteryState.unknown;
    } catch (_) {
      charging = true; // no battery (desktop/server) — treat as on power
    }
    final prefs = PreferencesService.instanceSync;
    final profile = policyFor(
      net,
      charging,
      serveOnCellular: prefs?.fileServeOnCellular ?? false,
      quotaMb: prefs?.fileServeQuotaMb ?? 1024,
    );
    final changed = lastProfile == null ||
        lastNet != net ||
        lastCharging != charging ||
        lastProfile!.unlimited != profile.unlimited ||
        lastProfile!.servingAllowed != profile.servingAllowed ||
        lastProfile!.dailyBudgetBytes != profile.dailyBudgetBytes;
    lastNet = net;
    lastCharging = charging;
    lastProfile = profile;
    _apply?.call(profile);
    if (changed) {
      LogService.instance.add(
          'Capacity: net=${net.name} charging=$charging -> ${profile.describe()} '
          '(class ${profile.capacity})');
    }
  }

  /// Best-effort network classification from active IPv4 interface names. Picks
  /// the most capable link present (ethernet > wifi > cellular > other).
  Future<NetKind> detectNetwork() async {
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      var best = NetKind.none;
      for (final i in ifaces) {
        if (i.addresses.isEmpty) continue;
        final kind = classifyInterfaceName(i.name.toLowerCase());
        if (rankNetKind(kind) > rankNetKind(best)) best = kind;
      }
      return best;
    } catch (_) {
      return NetKind.none;
    }
  }
}
