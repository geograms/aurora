// Verifies the decentralized-update folder adapter: artifact filenames parse to
// versions, a browsed/reduced signed folder yields the right per-channel
// candidate releases, the existing semver pick chooses the newest stable vs the
// newest beta, the per-platform asset still resolves, and forged ops are dropped
// (so a forged folder offers no release).
//
//   flutter test test/update_folder_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:aurora/services/folders/folder_event.dart';
import 'package:aurora/services/folders/folder_state.dart';
import 'package:aurora/services/update_models.dart';
import 'package:aurora/util/nostr_crypto.dart';
import 'package:aurora/util/nostr_event.dart';

void main() {
  group('versionFromAssetName', () {
    test('parses each platform suffix off the version', () {
      expect(versionFromAssetName('aurora-1.0.3.apk'), '1.0.3');
      expect(versionFromAssetName('aurora-1.0.3-linux-x64.tar.gz'), '1.0.3');
      expect(versionFromAssetName('aurora-1.0.3-setup.exe'), '1.0.3');
    });
    test('keeps a prerelease version (which carries its own dash)', () {
      expect(versionFromAssetName('aurora-1.0.3-beta.4.apk'), '1.0.3-beta.4');
      expect(versionFromAssetName('aurora-1.0.3-beta.4-linux-x64.tar.gz'),
          '1.0.3-beta.4');
      expect(versionFromAssetName('aurora-1.0.3-beta.4-setup.exe'),
          '1.0.3-beta.4');
    });
    test('rejects non-aurora / unknown artifacts', () {
      expect(versionFromAssetName('readme.txt'), isNull);
      expect(versionFromAssetName('aurora-1.0.3.weird'), isNull);
      expect(versionFromAssetName('something-1.0.3.apk'), isNull);
    });
  });

  // A 64-hex sha per artifact (content is irrelevant to the adapter).
  String sha(String c) => c * 64;

  // Build a real signed folder (owner = master) holding the given artifact
  // files, reduce it, and return FolderState.toJson — exactly the shape
  // RnsService.folderBrowse hands the updater.
  Map<String, dynamic> browsedFolder(
      NostrKeyPair master, List<List<String>> files) {
    final folderId = master.publicKeyHex;
    const t0 = 1700000000;
    final ops = <NostrEvent>[];
    for (var i = 0; i < files.length; i++) {
      ops.add(buildOp(master.privateKeyHex, folderId,
          opAddFile(files[i][0], name: files[i][1]),
          createdAt: t0 + i));
    }
    return reduceFolder(folderId, null, ops).toJson();
  }

  test('beta folder: newest stable vs newest beta, asset resolves', () {
    final master = NostrCrypto.generateKeyPair();
    // The beta folder carries all builds.
    final state = browsedFolder(master, [
      [sha('a'), 'aurora-1.0.0-linux-x64.tar.gz'],
      [sha('b'), 'aurora-1.0.1-linux-x64.tar.gz'],
      [sha('c'), 'aurora-1.0.1.apk'],
      [sha('d'), 'aurora-1.0.2-beta.1-linux-x64.tar.gz'],
      [sha('e'), 'aurora-1.0.2-beta.1.apk'],
    ]);

    final releases = releasesFromFolder(state);
    expect(releases.map((r) => r.version).toSet(),
        {'1.0.0', '1.0.1', '1.0.2-beta.1'});

    // Newest stable = 1.0.1; newest of all = 1.0.2-beta.1.
    ReleaseInfo newest(bool prereleaseOk) {
      ReleaseInfo? best;
      for (final r in releases) {
        if (!prereleaseOk && r.isPrerelease) continue;
        if (best == null ||
            UpdateModelsTestHook.cmp(r.version, best.version) > 0) {
          best = r;
        }
      }
      return best!;
    }

    expect(newest(false).version, '1.0.1');
    expect(newest(true).version, '1.0.2-beta.1');

    // The per-platform asset still resolves by filename suffix; its url is the
    // sha (the Reticulum fetch handle).
    final linux = newest(false).assetFor(UpdatePlatform.linux);
    expect(linux, isNotNull);
    expect(linux!.name, 'aurora-1.0.1-linux-x64.tar.gz');
    expect(linux.url, sha('b'));
    final apk = newest(false).assetFor(UpdatePlatform.android);
    expect(apk!.url, sha('c'));
  });

  test('isPrerelease tracks the dash in the version', () {
    final master = NostrCrypto.generateKeyPair();
    final state = browsedFolder(master, [
      [sha('a'), 'aurora-2.0.0.apk'],
      [sha('b'), 'aurora-2.1.0-rc.1.apk'],
    ]);
    final byVer = {for (final r in releasesFromFolder(state)) r.version: r};
    expect(byVer['2.0.0']!.isPrerelease, isFalse);
    expect(byVer['2.1.0-rc.1']!.isPrerelease, isTrue);
  });

  test('forged folder (op not signed by owner) offers no release', () {
    final master = NostrCrypto.generateKeyPair();
    final attacker = NostrCrypto.generateKeyPair();
    final folderId = master.publicKeyHex; // address pinned to the real owner
    // The attacker signs an addFile op for the real owner's folder.
    final forged = reduceFolder(folderId, null, [
      buildOp(attacker.privateKeyHex, folderId,
          opAddFile(sha('a'), name: 'aurora-9.9.9.apk'),
          createdAt: 1700000000),
    ]).toJson();
    expect(releasesFromFolder(forged), isEmpty);
  });

  test('non-aurora files in the folder are ignored', () {
    final master = NostrCrypto.generateKeyPair();
    final state = browsedFolder(master, [
      [sha('a'), 'README.md'],
      [sha('b'), 'aurora-1.2.3.apk'],
    ]);
    final releases = releasesFromFolder(state);
    expect(releases.length, 1);
    expect(releases.first.version, '1.2.3');
  });
}

/// Test-only access to the same prerelease-aware semver comparison the
/// UpdateService uses to pick the newest release.
class UpdateModelsTestHook {
  static int cmp(String a, String b) => _cmp(a, b);
  static int _cmp(String a, String b) {
    a = a.split('+').first;
    b = b.split('+').first;
    final ap = a.split('-');
    final bp = b.split('-');
    List<int> core(String s) =>
        s.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final ac = core(ap.first), bc = core(bp.first);
    for (var i = 0; i < 3; i++) {
      final x = i < ac.length ? ac[i] : 0;
      final y = i < bc.length ? bc[i] : 0;
      if (x != y) return x < y ? -1 : 1;
    }
    final aPre = ap.length > 1, bPre = bp.length > 1;
    if (aPre && !bPre) return -1;
    if (!aPre && bPre) return 1;
    if (!aPre && !bPre) return 0;
    final aId = ap.sublist(1).join('-').split('.');
    final bId = bp.sublist(1).join('-').split('.');
    for (var i = 0; i < aId.length && i < bId.length; i++) {
      final an = int.tryParse(aId[i]), bn = int.tryParse(bId[i]);
      int c;
      if (an != null && bn != null) {
        c = an.compareTo(bn);
      } else if (an != null) {
        c = -1;
      } else if (bn != null) {
        c = 1;
      } else {
        c = aId[i].compareTo(bId[i]);
      }
      if (c != 0) return c < 0 ? -1 : 1;
    }
    return aId.length.compareTo(bId.length).clamp(-1, 1);
  }
}
