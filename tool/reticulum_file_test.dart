// Dart<->Dart file fetch-by-sha256 gate: a provider (node B) holds files; a
// fetcher (node A) establishes a link and pulls a file by its sha256 — manifest
// first, then every chunk — verifying each chunk and the assembled whole. Runs
// fully in-process (no network, no Python). Also checks the NOT_FOUND path.
//
//   dart run tool/reticulum_file_test.dart [file_bytes]
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_link.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/files/file_manifest.dart';
import 'package:aurora/services/files/file_transfer.dart';

const _app = 'aurora';
const _aspects = ['files'];

String _hx(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void _expect(bool c, String what) {
  if (!c) {
    // ignore: avoid_print
    print('FAIL: $what');
    throw StateError(what);
  }
}

RnsPacket _wire(RnsPacket p) => RnsPacket.parse(p.pack())!;

/// Establish an active initiator(A)/responder(B) link pair and return both ends.
Future<(RnsLink, RnsLink)> _establish(RnsIdentity idB) async {
  final idBpub = RnsIdentity.fromPublicKey(idB.getPublicKey());
  final a = await RnsLink.initiator(idBpub, _app, _aspects);
  final req = _wire(a.buildRequest());
  final b = await RnsLink.responder(idB, req);
  final proof = _wire(await b.buildProof());
  final rtt = await a.handleProof(proof);
  _expect(rtt != null, 'A built LRRTT');
  _expect(b.handleRtt(_wire(rtt!)), 'B activated');
  _expect(a.status == RnsLinkStatus.active && b.status == RnsLinkStatus.active,
      'both links active');
  return (a, b);
}

/// Drive packets between the fetcher (A) and the provider serve session (B) until
/// the fetch reaches a terminal state or the network goes quiet.
void _pump(FileFetchSession fetch, FileServeSession serve, RnsPacket first) {
  // queue entries: (toProvider, packet) — true => deliver to serve(B).
  final q = <(bool, RnsPacket)>[(true, first)];
  var steps = 0;
  while (q.isNotEmpty) {
    if (++steps > 100000) _expect(false, 'pump did not converge');
    final (toProvider, pkt) = q.removeAt(0);
    final out =
        toProvider ? serve.onPacket(_wire(pkt)) : fetch.onPacket(_wire(pkt));
    for (final o in out) {
      q.add((!toProvider, o));
    }
    if (fetch.state == FileFetchState.done ||
        fetch.state == FileFetchState.failed) {
      // Let any trailing packets (e.g. the final proof) flush to the provider.
    }
  }
}

Future<void> _roundtrip(int size) async {
  final file = Uint8List(size);
  for (var i = 0; i < size; i++) {
    file[i] = (i * 131 + 17) & 0xff;
  }
  final wantSha = crypto.sha256.convert(file).bytes;

  final idB = await RnsIdentity.generate();
  final (aLink, bLink) = await _establish(idB);

  final source = MemoryFileSource()..add(file);
  final serve = FileServeSession(bLink, source);
  final fetch = FileFetchSession(aLink, Uint8List.fromList(wantSha));
  _pump(fetch, serve, fetch.start());

  _expect(fetch.state == FileFetchState.done,
      '$size B fetch done (state=${fetch.state}, err=${fetch.error})');
  _expect(fetch.result != null, '$size B has result');
  final gotSha = crypto.sha256.convert(fetch.result!).bytes;
  _expect(_hx(gotSha) == _hx(wantSha), '$size B sha256 matches');
  final chunks = fetch.manifest?.chunkCount ?? -1;
  // ignore: avoid_print
  print('OK fetch: $size bytes in $chunks chunk(s), sha256=${_hx(gotSha)}');
}

Future<void> _notFound() async {
  final idB = await RnsIdentity.generate();
  final (aLink, bLink) = await _establish(idB);
  final serve = FileServeSession(bLink, MemoryFileSource()); // empty store
  final missing = Uint8List.fromList(crypto.sha256.convert('absent'.codeUnits).bytes);
  final fetch = FileFetchSession(aLink, missing);
  _pump(fetch, serve, fetch.start());
  _expect(fetch.state == FileFetchState.failed, 'missing file -> failed');
  // ignore: avoid_print
  print('OK not-found: provider declined cleanly (${fetch.error})');
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    await _roundtrip(int.parse(args[0]));
    return;
  }
  // Single chunk, exact boundary, multi-chunk, and a larger multi-chunk file.
  for (final n in [1, 1000, kFileChunkSize, kFileChunkSize + 1, 100000, 500000]) {
    await _roundtrip(n);
  }
  await _notFound();
  // ignore: avoid_print
  print('ALL OK');
}
