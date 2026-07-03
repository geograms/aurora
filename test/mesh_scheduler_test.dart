/*
 * MeshTransferScheduler gate-state tests — the one mesh component that had
 * none, and where every silent stall of 2026-07-03 lived.
 */
import 'package:aurora/services/mesh/mesh_transfer_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final s = MeshTransferScheduler.instance;

  test('backoff doubles on failure, clears on clean close', () {
    s.dialResult('AAAA', clean: false); // 15s
    s.dialResult('AAAA', clean: false); // 30s
    s.dialResult('AAAA', clean: false); // 60s
    final b1 = s.statusJson()['backoff'] as Map;
    expect(b1['AAAA'], greaterThan(45)); // ≥ ~60s pending
    s.dialResult('AAAA', clean: true); // clean: quiet 60s then free
    final b2 = s.statusJson()['backoff'] as Map;
    expect(b2['AAAA'], lessThanOrEqualTo(60));
  });

  test('backoff caps at 2 minutes', () {
    for (var i = 0; i < 10; i++) {
      s.dialResult('BBBB', clean: false);
    }
    final b = s.statusJson()['backoff'] as Map;
    expect(b['BBBB'], lessThanOrEqualTo(120));
  });

  test('statusJson always reports a decision', () {
    final j = s.statusJson();
    expect(j['decision'], isNotNull);
    expect(j.containsKey('dialing'), true);
    expect(j.containsKey('lastDialAttempt'), true);
  });
}
