// In-process multi-source fetch gate: one fetcher pulls a multi-chunk file from
// SEVERAL providers in parallel over a shared broadcast bus (each node ignores
// packets not addressed to it). Verifies the assembled file and that chunks were
// actually served by more than one provider (real multi-source work-stealing).
//
//   dart run tool/reticulum_multisource_test.dart [providers] [file_bytes]
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/files/dht/provider_record.dart';
import 'package:aurora/services/files/file_node.dart';
import 'package:aurora/services/files/file_transfer.dart';

void _expect(bool c, String what) {
  if (!c) {
    // ignore: avoid_print
    print('FAIL: $what');
    throw StateError(what);
  }
}

String _hx(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

class _Ser {
  Future<void> _c = Future.value();
  void run(Future<void> Function() f) {
    _c = _c.then((_) => f()).catchError((e) {
      // ignore: avoid_print
      print('dispatch error: $e');
    });
  }
}

/// Counts how many requests this provider actually served (manifest + chunks).
class CountingSource implements FileSource {
  final MemoryFileSource inner = MemoryFileSource();
  int reads = 0;
  CountingSource(Uint8List file) {
    inner.add(file);
  }
  @override
  Uint8List? read(Uint8List fileHash) {
    reads++;
    return inner.read(fileHash);
  }
}

Future<void> main(List<String> args) async {
  final m = args.isNotEmpty ? int.parse(args[0]) : 4;
  final size = args.length > 1 ? int.parse(args[1]) : 300000; // ~10 chunks
  final file = Uint8List(size);
  for (var i = 0; i < size; i++) {
    file[i] = (i * 67 + 5) & 0xff;
  }
  final sha = Uint8List.fromList(crypto.sha256.convert(file).bytes);

  final dispatchers = <void Function(RnsPacket)>[];
  void Function(Uint8List) sendFor(int self) => (raw) {
        final p = RnsPacket.parse(raw);
        if (p == null) return;
        for (var j = 0; j < dispatchers.length; j++) {
          if (j == self) continue;
          dispatchers[j](p);
        }
      };

  // Node 0 = fetcher; nodes 1..m = providers (each holds the whole file).
  final idF = await RnsIdentity.generate();
  final fetcher = FileTransferNode(
      identity: idF, source: const EmptyFileSource(), send: sendFor(0));
  final serF = _Ser();
  dispatchers.add((p) => serF.run(() => fetcher.handlePacket(p)));

  final provIds = <RnsIdentity>[];
  final sources = <CountingSource>[];
  for (var i = 1; i <= m; i++) {
    final id = await RnsIdentity.generate();
    provIds.add(id);
    final src = CountingSource(file);
    sources.add(src);
    final node = FileTransferNode(identity: id, source: src, send: sendFor(i));
    final ser = _Ser();
    dispatchers.add((p) => ser.run(() => node.handlePacket(p)));
  }

  // Build signed provider records (as the DHT would return).
  final records = <ProviderRecord>[];
  for (final id in provIds) {
    records.add(await ProviderRecord.create(
        providerIdentity: id, sha256: sha, capacity: kCapHomeWifi));
  }

  final got = await fetcher.multiSourceFetch(sha, records, maxConns: m);
  _expect(got != null, 'multi-source fetch returned bytes');
  _expect(_hx(crypto.sha256.convert(got!).bytes) == _hx(sha), 'assembled sha matches');

  final servedBy = sources.where((s) => s.reads > 0).length;
  final counts = sources.map((s) => s.reads).toList();
  _expect(servedBy >= 2, 'served by >=2 providers (got $servedBy, reads=$counts)');

  // ignore: avoid_print
  print('OK multi-source: $size bytes from $m providers, '
      'served-by=$servedBy reads=$counts');
}
