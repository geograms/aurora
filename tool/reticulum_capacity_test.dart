// CapacityGovernor policy gate: verifies the (network, charging) -> serving
// profile mapping and that applying a profile configures the ServeQuota as
// expected (charger + Wi-Fi => unlimited; cellular => off unless allowed; etc.).
//
//   dart run tool/reticulum_capacity_test.dart
import 'package:aurora/services/files/capacity_policy.dart';
import 'package:aurora/services/files/dht/provider_record.dart';
import 'package:aurora/services/files/serve_quota.dart';

void _expect(bool c, String what) {
  if (!c) {
    // ignore: avoid_print
    print('FAIL: $what');
    throw StateError(what);
  }
}

CapacityProfile _p(NetKind net, bool charging,
        {bool cell = false, int mb = 1024}) =>
    policyFor(net, charging, serveOnCellular: cell, quotaMb: mb);

Future<void> main() async {
  const mb = 1 << 20;

  // Charger + Wi-Fi => unlimited, serving on, home-wifi class.
  final wifiCharging = _p(NetKind.wifi, true);
  _expect(wifiCharging.unlimited && wifiCharging.servingAllowed, 'wifi+charge unlimited');
  _expect(wifiCharging.capacity == kCapHomeWifi, 'wifi class');

  // Charger + Ethernet => unlimited, home-fiber class.
  final eth = _p(NetKind.ethernet, true);
  _expect(eth.unlimited && eth.capacity == kCapHomeFiber, 'ethernet+charge unlimited/fiber');

  // Battery + Wi-Fi => limited to the daily budget, serving on.
  final wifiBattery = _p(NetKind.wifi, false, mb: 1024);
  _expect(!wifiBattery.unlimited && wifiBattery.servingAllowed, 'wifi+battery limited');
  _expect(wifiBattery.dailyBudgetBytes == 1024 * mb, 'wifi+battery budget = quota');

  // Cellular, not allowed => serving off.
  final cellOff = _p(NetKind.cellular, true, cell: false);
  _expect(!cellOff.servingAllowed && cellOff.capacity == kCapCellular, 'cellular off by default');

  // Cellular, allowed => serving on but capped at 200 MB.
  final cellOn = _p(NetKind.cellular, false, cell: true, mb: 1024);
  _expect(cellOn.servingAllowed, 'cellular on when allowed');
  _expect(cellOn.dailyBudgetBytes == 200 * mb, 'cellular capped at 200MB');

  // No network => serving off.
  _expect(!_p(NetKind.none, true).servingAllowed, 'no network => off');

  // applyTo configures the quota: unlimited disables limiting.
  final q = ServeQuota();
  wifiCharging.applyTo(q);
  _expect(!q.enabled && q.servingAllowed, 'unlimited => quota disabled');
  wifiBattery.applyTo(q);
  _expect(q.enabled && q.dailyBudgetBytes == 1024 * mb, 'battery => quota enabled w/ budget');
  cellOff.applyTo(q);
  _expect(q.enabled && !q.servingAllowed, 'cellular-off => not serving');

  // ignore: avoid_print
  print('OK capacity policy');

  // Interface-name classification (the Android-accurate heuristic).
  _expect(classifyInterfaceName('wlan0') == NetKind.wifi, 'wlan0 => wifi');
  _expect(classifyInterfaceName('eth0') == NetKind.ethernet, 'eth0 => ethernet');
  _expect(classifyInterfaceName('rmnet_data0') == NetKind.cellular, 'rmnet => cellular');
  _expect(classifyInterfaceName('en0') == NetKind.wifi, 'en0 => wifi (macOS)');
  _expect(rankNetKind(NetKind.wifi) > rankNetKind(NetKind.cellular),
      'wifi preferred over cellular');
  // ignore: avoid_print
  print('OK interface classification');

  // ignore: avoid_print
  print('ALL OK');
}
