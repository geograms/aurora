// End-to-end test of the store-and-forward blob deposit protocol: a depositor
// node pushes a blob to a host node over in-process Reticulum links, the host
// verifies the compact NOSTR auth, classifies the depositor's tier, enforces the
// quota, receives the bytes as an RNS Resource, verifies the hash, and stores it.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';

import 'package:aurora/profile/profile_storage_io.dart';
import 'package:aurora/services/files/composite_file_source.dart';
import 'package:aurora/services/files/file_node.dart';
import 'package:aurora/services/files/file_transfer.dart';
import 'package:aurora/services/files/media_file_source.dart';
import 'package:aurora/services/reticulum/rns_identity.dart';
import 'package:aurora/services/reticulum/rns_packet.dart';
import 'package:aurora/services/social/host_retention_policy.dart';
import 'package:aurora/services/social/retention_tier.dart';
import 'package:aurora/util/media_archive.dart';
import 'package:aurora/util/nostr_crypto.dart';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List _unhex(String h) => Uint8List.fromList([
      for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)
    ]);

void main() {
  setUpAll(() {
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
  });

  final temps = <Directory>[];
  tearDownAll(() {
    for (final d in temps) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  // Build a host + depositor pair wired by two in-process packet queues, with the
  // host hosting into [archive], following [follows], under [quota].
  Future<({FileTransferNode host, FileTransferNode dep, RnsIdentity hostPub, Future<void> Function(bool Function()) pump})>
      pair(MediaArchive archive, Set<String> follows, HostQuota quota) async {
    final hostId = await RnsIdentity.generate();
    final depId = await RnsIdentity.generate();
    final hostPub = RnsIdentity.fromPublicKey(hostId.getPublicKey());
    final toHost = <Uint8List>[];
    final toDep = <Uint8List>[];
    final source = CompositeFileSource([MediaFileSource(archive)]);
    final host = FileTransferNode(
      identity: hostId,
      source: source,
      send: (raw) => toDep.add(raw),
      onDepositOffer: (sha, size, ext, pubHex, sigHex) {
        if (!NostrCrypto.schnorrVerify(
            depositAuthMessageHex(_hex(sha)), sigHex, pubHex)) {
          return const DepositVerdict.reject('bad auth');
        }
        final tier = tierOf(pubHex, selfPubHex: null, followsHex: follows);
        final t = archive.hostedTotals();
        final d = admit(tier, size,
            isMedia: true,
            totalHostedBytes: t.totalHostedBytes,
            strangerHostedBytes: t.strangerBytes,
            strangerNotesThisMonth: 0,
            q: quota);
        if (!d.ok) return DepositVerdict.reject(d.reason);
        return DepositVerdict.accept(tier.index, pubHex, ext);
      },
      onDepositStore: (sha, bytes, originPub, tier, ext) =>
          archive.putHosted(bytes, ext, originPubHex: originPub, tier: tier),
    );
    final dep = FileTransferNode(
      identity: depId,
      source: const EmptyFileSource(),
      send: (raw) => toHost.add(raw),
    );
    Future<void> pump(bool Function() done) async {
      for (var i = 0; i < 2000 && !done(); i++) {
        while (toHost.isNotEmpty) {
          final p = RnsPacket.parse(toHost.removeAt(0));
          if (p != null) await host.handlePacket(p);
        }
        while (toDep.isNotEmpty) {
          final p = RnsPacket.parse(toDep.removeAt(0));
          if (p != null) await dep.handlePacket(p);
        }
        await Future<void>.delayed(Duration.zero);
      }
    }

    return (host: host, dep: dep, hostPub: hostPub, pump: pump);
  }

  MediaArchive freshArchive() {
    final dir = Directory.systemTemp.createTempSync('deposit_test_');
    temps.add(dir);
    return MediaArchive.forStorage(makeFilesystemStorage(dir.path));
  }

  HostQuota quota({int sliceBytes = 100 << 20}) => HostQuota(
      ceilingBytes: 100 << 20,
      strangerSliceBytes: sliceBytes,
      strangerNotesPerMonth: 1000,
      strangerRetentionMs: 1 << 50);

  Uint8List blob(int n, int seed) =>
      Uint8List.fromList(List.generate(n, (i) => (i + seed) % 256));

  // Run one deposit; returns (ok, archive).
  Future<bool> runDeposit(
    MediaArchive archive,
    Set<String> follows,
    HostQuota q,
    Uint8List bytes,
    String depPrivHex,
    String depPubHex, {
    String? signShaHexOverride, // forge: sign a different sha
  }) async {
    final p = await pair(archive, follows, q);
    final sha = Uint8List.fromList(crypto.sha256.convert(bytes).bytes);
    final signSha = signShaHexOverride ?? _hex(sha);
    final sigHex =
        NostrCrypto.schnorrSign(depositAuthMessageHex(signSha), depPrivHex);
    var done = false;
    var ok = false;
    // ignore: unawaited_futures
    p.dep
        .deposit(sha, bytes, 'png', _unhex(depPubHex), _unhex(sigHex), p.hostPub)
        .then((v) {
      ok = v;
      done = true;
    });
    await p.pump(() => done);
    return ok;
  }

  test('stranger deposit is verified, classified, stored', () async {
    final archive = freshArchive();
    final kp = NostrCrypto.generateKeyPair();
    final bytes = blob(5000, 1);
    final ok = await runDeposit(
        archive, <String>{}, quota(), bytes, kp.privateKeyHex, kp.publicKeyHex);
    expect(ok, isTrue);
    final shaHex = _hex(crypto.sha256.convert(bytes).bytes);
    expect(archive.has(shaHex), isTrue);
    final inv = archive.hostedInventory();
    expect(inv.length, 1);
    expect(inv.first.tier, Tier.stranger.index); // stranger
    expect(inv.first.bytes, bytes.length);
  });

  test('followed depositor is classified as tier followed', () async {
    final archive = freshArchive();
    final kp = NostrCrypto.generateKeyPair();
    final ok = await runDeposit(archive, {kp.publicKeyHex.toLowerCase()},
        quota(), blob(4096, 2), kp.privateKeyHex, kp.publicKeyHex);
    expect(ok, isTrue);
    expect(archive.hostedInventory().first.tier, Tier.followed.index);
  });

  test('forged auth (signature over a different blob) is rejected', () async {
    final archive = freshArchive();
    final kp = NostrCrypto.generateKeyPair();
    final ok = await runDeposit(
        archive, <String>{}, quota(), blob(3000, 3), kp.privateKeyHex,
        kp.publicKeyHex,
        signShaHexOverride: 'ab' * 32); // sign the wrong sha
    expect(ok, isFalse);
    expect(archive.hostedInventory(), isEmpty);
  });

  test('deposit refused when it would exceed the stranger slice', () async {
    final archive = freshArchive();
    final kp = NostrCrypto.generateKeyPair();
    final ok = await runDeposit(archive, <String>{}, quota(sliceBytes: 1000),
        blob(5000, 4), kp.privateKeyHex, kp.publicKeyHex);
    expect(ok, isFalse);
    expect(archive.hostedInventory(), isEmpty);
  });
}
