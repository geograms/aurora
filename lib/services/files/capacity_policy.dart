/*
 * Pure capacity policy: maps a device situation (network kind + charging) to a
 * file-serving profile, with no Flutter/plugin dependencies so it is unit-
 * testable headlessly. The runtime governor (battery + prefs + timers) lives in
 * capacity_governor.dart and uses these.
 */
import 'dht/provider_record.dart';
import 'serve_quota.dart';

enum NetKind { ethernet, wifi, cellular, other, none }

class CapacityProfile {
  final int capacity; // advertised capacity class (kCap*)
  final bool servingAllowed;
  final bool unlimited; // serve with no daily limit
  final int dailyBudgetBytes;

  const CapacityProfile({
    required this.capacity,
    required this.servingAllowed,
    required this.unlimited,
    required this.dailyBudgetBytes,
  });

  /// Apply this profile to a [ServeQuota].
  void applyTo(ServeQuota q) {
    q.enabled = !unlimited; // unlimited => no limiting at all
    q.servingAllowed = servingAllowed;
    q.dailyBudgetBytes = dailyBudgetBytes;
  }

  String describe() => unlimited
      ? 'unlimited'
      : (servingAllowed ? '${dailyBudgetBytes ~/ (1 << 20)}MB/day' : 'serving off');
}

/// Device situation -> serving profile.
///   charger + Wi-Fi/Ethernet => unlimited (an ideal provider)
///   battery + Wi-Fi/Ethernet => serve within the daily budget
///   cellular                 => only if allowed, and then capped at 200 MB
///   no network               => don't serve
CapacityProfile policyFor(
  NetKind net,
  bool charging, {
  required bool serveOnCellular,
  required int quotaMb,
}) {
  final budget = quotaMb * (1 << 20);
  switch (net) {
    case NetKind.ethernet:
    case NetKind.wifi:
      if (charging) {
        return CapacityProfile(
          capacity: net == NetKind.ethernet ? kCapHomeFiber : kCapHomeWifi,
          servingAllowed: true,
          unlimited: true,
          dailyBudgetBytes: budget,
        );
      }
      return CapacityProfile(
        capacity: kCapHomeWifi,
        servingAllowed: true,
        unlimited: false,
        dailyBudgetBytes: budget,
      );
    case NetKind.cellular:
      final cellBudget = (quotaMb < 200 ? quotaMb : 200) * (1 << 20);
      return CapacityProfile(
        capacity: kCapCellular,
        servingAllowed: serveOnCellular,
        unlimited: false,
        dailyBudgetBytes: cellBudget,
      );
    case NetKind.other:
      return CapacityProfile(
        capacity: kCapUnknown,
        servingAllowed: true,
        unlimited: false,
        dailyBudgetBytes: budget,
      );
    case NetKind.none:
      return CapacityProfile(
        capacity: kCapUnknown,
        servingAllowed: false,
        unlimited: false,
        dailyBudgetBytes: budget,
      );
  }
}

/// Classify a network interface name (lowercased) into a [NetKind].
NetKind classifyInterfaceName(String n) {
  if (n.startsWith('eth') || n.startsWith('enp') || n.startsWith('eno') ||
      n.startsWith('ens')) {
    return NetKind.ethernet;
  }
  if (n.startsWith('wlan') || n.startsWith('wlp') || n.startsWith('wl') ||
      n.startsWith('ap') || n.contains('wifi') || n.startsWith('en')) {
    // 'en0' is Wi-Fi on macOS; on Android Wi-Fi is wlan0.
    return NetKind.wifi;
  }
  if (n.startsWith('rmnet') || n.startsWith('ccmni') || n.startsWith('pdp') ||
      n.startsWith('wwan') || n.startsWith('radio') || n.startsWith('clat')) {
    return NetKind.cellular;
  }
  return NetKind.other;
}

/// Capability ranking: ethernet best, then wifi, cellular, other, none.
int rankNetKind(NetKind k) {
  switch (k) {
    case NetKind.ethernet:
      return 4;
    case NetKind.wifi:
      return 3;
    case NetKind.cellular:
      return 2;
    case NetKind.other:
      return 1;
    case NetKind.none:
      return 0;
  }
}
