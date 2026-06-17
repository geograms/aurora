// ServeQuota gate: unit-tests the budget/anti-abuse logic, then checks in-process
// that a provider actually DECLINES to serve once its daily budget is spent (the
// fetch fails) and succeeds with a generous budget.
//
//   dart run tool/reticulum_quota_test.dart
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_link.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/files/file_transfer.dart';
import 'package:aurora/services/files/serve_quota.dart';

void _expect(bool c, String what) {
  if (!c) {
    // ignore: avoid_print
    print('FAIL: $what');
    throw StateError(what);
  }
}

final _sha = Uint8List.fromList(crypto.sha256.convert('x'.codeUnits).bytes);
final _sha2 = Uint8List.fromList(crypto.sha256.convert('y'.codeUnits).bytes);

void _unit() {
  // Global cap.
  var q = ServeQuota(dailyBudgetBytes: 100, perRequesterBytes: 1000);
  _expect(q.canServe('r', _sha, 60), 'within global');
  q.record('r', _sha, 60);
  _expect(!q.canServe('r2', _sha, 60), 'global cap blocks (60+60>100)');
  _expect(q.canServe('r2', _sha, 40), 'global allows up to remaining');

  // Per-requester cap.
  q = ServeQuota(dailyBudgetBytes: 100000, perRequesterBytes: 100);
  q.record('r', _sha, 60);
  _expect(!q.canServe('r', _sha, 60), 'per-requester cap blocks');
  _expect(q.canServe('r2', _sha, 60), 'other requester unaffected');

  // Serving switch.
  q = ServeQuota(servingAllowed: false);
  _expect(!q.canServe('r', _sha, 1), 'servingAllowed=false declines');
  _expect(!q.available, 'not available when serving off');

  // Disabled = no limiting.
  q = ServeQuota(enabled: false, servingAllowed: false, dailyBudgetBytes: 1);
  _expect(q.canServe('r', _sha, 1 << 30), 'disabled => always allowed');

  // Manifest refetch window: a full re-download is blocked, but chunks of the
  // current download are not.
  q = ServeQuota(dailyBudgetBytes: 1 << 30);
  _expect(q.canServe('r', _sha, 100, manifest: true), 'first manifest ok');
  q.record('r', _sha, 100, manifest: true);
  _expect(!q.canServe('r', _sha, 100, manifest: true), 'manifest refetch blocked');
  _expect(q.canServe('r', _sha, 32000), 'chunks of current file still allowed');
  _expect(q.canServe('r', _sha2, 100, manifest: true), 'different file ok');

  // ignore: avoid_print
  print('OK quota unit');
}

RnsPacket _wire(RnsPacket p) => RnsPacket.parse(p.pack())!;

Future<bool> _fetchWithBudget(int budget) async {
  final file = Uint8List(100000); // ~4 chunks
  for (var i = 0; i < file.length; i++) {
    file[i] = (i * 7 + 1) & 0xff;
  }
  final sha = Uint8List.fromList(crypto.sha256.convert(file).bytes);

  final idB = await RnsIdentity.generate();
  final a = await RnsLink.initiator(
      RnsIdentity.fromPublicKey(idB.getPublicKey()), 'aurora', ['files']);
  final req = _wire(a.buildRequest());
  final b = await RnsLink.responder(idB, req);
  final proof = _wire(await b.buildProof());
  final rtt = await a.handleProof(proof);
  b.handleRtt(_wire(rtt!));

  final serve = FileServeSession(b, MemoryFileSource()..add(file),
      quota: ServeQuota(dailyBudgetBytes: budget), requesterId: 'peer');
  final fetch = FileFetchSession(a, sha);

  final q = <(bool, RnsPacket)>[(true, fetch.start())];
  var steps = 0;
  while (q.isNotEmpty) {
    if (++steps > 100000) break;
    final (toProvider, pkt) = q.removeAt(0);
    final out = toProvider ? serve.onPacket(_wire(pkt)) : fetch.onPacket(_wire(pkt));
    for (final o in out) {
      q.add((!toProvider, o));
    }
  }
  return fetch.state == FileFetchState.done;
}

Future<void> main() async {
  _unit();

  // Tiny budget (40 KB): manifest + 1 chunk fit, the rest are declined -> fail.
  final small = await _fetchWithBudget(40000);
  _expect(!small, 'tiny budget => fetch declined/incomplete');
  // ignore: avoid_print
  print('OK quota serve: tiny budget declined');

  // Generous budget: full fetch succeeds.
  final big = await _fetchWithBudget(10 << 20);
  _expect(big, 'generous budget => fetch completes');
  // ignore: avoid_print
  print('OK quota serve: generous budget completes');

  // ignore: avoid_print
  print('ALL OK');
}
