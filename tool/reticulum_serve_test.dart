// Dart<->Dart Reticulum serve/fetch gate: validates the RESPONDER side of Link
// and the RECEIVER side of Resource (the halves the stack was missing) entirely
// in-process, no Python peer. Node B (responder/sender) holds a payload; node A
// (initiator/receiver) establishes a link and pulls the payload as a multi-part
// Resource, then both confirm via the proof.
//
//   dart run tool/reticulum_serve_test.dart [payload_bytes]
//
// Success prints OK and exits 0; any mismatch exits 1.
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_link.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/reticulum/rns_resource.dart';
import 'package:aurora/services/reticulum/rns_resource_receiver.dart';

const _app = 'aurora';
const _aspects = ['files'];

String _hx(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void _expect(bool cond, String what) {
  if (!cond) {
    // ignore: avoid_print
    print('FAIL: $what');
    throw StateError(what);
  }
}

// Pass a packet "over the wire": pack then re-parse, so we exercise the real
// codec exactly as a network hop would.
RnsPacket _wire(RnsPacket p) {
  final parsed = RnsPacket.parse(p.pack());
  _expect(parsed != null, 'packet re-parse');
  return parsed!;
}

Future<void> main(List<String> args) async {
  final size = args.isNotEmpty ? int.parse(args[0]) : 5000;
  final payload = Uint8List(size);
  for (var i = 0; i < size; i++) {
    payload[i] = (i * 31 + 7) & 0xff; // deterministic, non-trivial
  }
  final wantSha = _hx(crypto.sha256.convert(payload).bytes);

  // Node B (the provider) owns an identity + a named destination.
  final idB = await RnsIdentity.generate();
  // Node A learns B's PUBLIC identity (as it would from an announce).
  final idBpub = RnsIdentity.fromPublicKey(idB.getPublicKey());

  // 1) A builds the LINKREQUEST toward B's destination.
  final aLink = await RnsLink.initiator(idBpub, _app, _aspects);
  final reqPkt = _wire(aLink.buildRequest());
  _expect(reqPkt.packetType == RnsPacketType.linkRequest, 'is link request');

  // 2) B accepts it (responder) and returns the LRPROOF.
  final bLink = await RnsLink.responder(idB, reqPkt);
  final proofPkt = _wire(await bLink.buildProof());

  // 3) A validates the proof and returns the LRRTT; 4) B activates.
  final rttPkt = await aLink.handleProof(proofPkt);
  _expect(rttPkt != null, 'A derived key + built LRRTT');
  _expect(aLink.status == RnsLinkStatus.active, 'A link active');
  final activated = bLink.handleRtt(_wire(rttPkt!));
  _expect(activated && bLink.status == RnsLinkStatus.active, 'B link active');

  // Sanity: both sides derived the same session key (encrypt on B, decrypt on A).
  final probe = Uint8List.fromList('reticulum'.codeUnits);
  final enc = bLink.encrypt(probe);
  _expect(_hx(aLink.decrypt(_wire(enc))) == _hx(probe), 'shared key agrees');

  // 5) B prepares the Resource and sends the advertisement.
  final sender = RnsResourceSender(bLink, payload);
  sender.prepare();
  final receiver = RnsResourceReceiver(aLink);
  final advPlain = aLink.decrypt(_wire(sender.advertisementPacket()));
  _expect(receiver.ingestAdvertisement(advPlain), 'A parsed advertisement');
  _expect(receiver.expectedParts == sender.parts, 'part count agrees');

  // 6) A requests the parts; B answers; A ingests until complete.
  final reqResource = bLink.decrypt(_wire(receiver.buildRequest()));
  final parts = sender.handleRequest(reqResource);
  _expect(parts.length == sender.parts, 'B returned all requested parts');
  var done = false;
  for (final part in parts) {
    done = receiver.ingestPart(_wire(part).data);
  }
  _expect(receiver.error == null, 'no receiver error (${receiver.error})');
  _expect(done && receiver.complete, 'A reassembled + verified payload');

  // 7) Integrity: A's payload matches B's by SHA-256.
  final gotSha = _hx(crypto.sha256.convert(receiver.payload!).bytes);
  _expect(gotSha == wantSha, 'payload sha256 matches ($gotSha vs $wantSha)');

  // 8) A returns the proof; B confirms completion.
  final prf = receiver.proofPacket();
  _expect(prf != null, 'A built proof');
  final ok = sender.validateProof(bLink.decrypt(_wire(prf!)));
  _expect(ok && sender.complete, 'B validated proof');

  // ignore: avoid_print
  print('OK serve/fetch: $size bytes in ${sender.parts} parts, sha256=$gotSha');
}
