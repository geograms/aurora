// LXMF FORMAT interop gate: cross-validates Aurora's Dart LXMF against the
// reference python implementation (markqvist/LXMF) in BOTH directions.
//   1. Dart packs a message -> python validates the signature + reads fields.
//   2. python LXMF packs a message -> Dart unpacks + verifies the signature.
// Proves wire compatibility with Sideband / NomadNet / MeshChat at the message
// layer.
//
//   dart run tool/lxmf_format_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/lxmf/lxmf.dart';
import 'package:aurora/services/reticulum/lxmf/lxmf_message.dart';

const _py = '/home/brito/.platformio/penv/bin/python3';
const _xcheck = 'tool/lxmf_xcheck.py';

void _expect(bool c, String what) {
  if (!c) {
    stderr.writeln('FAIL: $what');
    exit(1);
  }
}

Future<void> main() async {
  // ── Direction 1: Dart -> python ──────────────────────────────────────────
  final source = await RnsIdentity.generate();
  final destId = await RnsIdentity.generate();
  final destHash =
      RnsDestination.hash(destId, kLxmfApp, kLxmfDeliveryAspects);
  final msg = await LxmfMessage.create(
    destinationHash: destHash,
    source: source,
    title: 'hi-dart',
    content: 'hello from aurora dart',
    fields: {LxmfField.renderer: LxmfRenderer.plain},
  );
  await File('/tmp/lxmf_dart.bin').writeAsBytes(msg.packed);
  await File('/tmp/lxmf_dart_src.bin').writeAsBytes(source.getPublicKey());

  final v = await Process.run(
      _py, [_xcheck, 'verify_dart', '/tmp/lxmf_dart.bin', '/tmp/lxmf_dart_src.bin']);
  stdout.write(v.stdout);
  if (v.exitCode != 0) {
    stderr.writeln(v.stderr);
    _expect(false, 'python verify_dart crashed');
  }
  final out = v.stdout.toString();
  _expect(out.contains('SIG True'), 'python validated the Dart message signature');
  _expect(out.contains('CONTENT hello from aurora dart'),
      'python read the Dart content');
  _expect(out.contains('TITLE hi-dart'), 'python read the Dart title');
  stdout.writeln('OK Dart->python: signature + content verified by reference LXMF');

  // ── Direction 2: python LXMF -> Dart ─────────────────────────────────────
  final mk = await Process.run(
      _py, [_xcheck, 'make_py', '/tmp/lxmf_py.bin', '/tmp/lxmf_py_src.bin']);
  if (mk.exitCode != 0) {
    stderr.writeln(mk.stderr);
    _expect(false, 'python make_py crashed');
  }
  final packed = Uint8List.fromList(await File('/tmp/lxmf_py.bin').readAsBytes());
  final pyPub = Uint8List.fromList(await File('/tmp/lxmf_py_src.bin').readAsBytes());

  final parsed = LxmfMessage.unpack(packed);
  _expect(parsed != null, 'Dart unpacked the python message');
  final pySource = RnsIdentity.fromPublicKey(pyPub);
  final ok = await parsed!.verify(pySource);
  _expect(ok, 'Dart verified the python LXMF signature');
  _expect(parsed.contentString == 'hello from python LXMF',
      'Dart read the python content (${parsed.contentString})');
  _expect(parsed.titleString == 'py-title', 'Dart read the python title');
  _expect(parsed.fields.containsKey(LxmfField.fileAttachments),
      'Dart read the python file-attachment field');
  stdout.writeln('OK python->Dart: signature + content + fields verified by Aurora');

  stdout.writeln('ALL OK (LXMF wire-compatible with reference implementation)');
}
