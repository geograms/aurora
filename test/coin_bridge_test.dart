import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';

import 'package:aurora/profile/profile_storage_io.dart';
import 'package:aurora/wapp/coin/coin_host_bridge.dart';
import 'package:reticulum/reticulum.dart';

void main() {
  setUpAll(() {
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
  });

  final temps = <Directory>[];
  CoinHostBridge freshBridge() {
    final dir = Directory.systemTemp.createTempSync('coinbridge_');
    temps.add(dir);
    return CoinHostBridge(makeFilesystemStorage(dir.path));
  }

  tearDownAll(() {
    for (final d in temps) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  // A provider's coin + a helper to mint bearer tokens to receive.
  final admin = NostrCrypto.generateKeyPair();
  final coinId = admin.publicKeyHex;
  final mint = CoinMintKeys.derive(
      coinId, NostrCrypto.generateKeyPair().privateKeyHex,
      maxExp: 8);
  final descriptor = CoinHostBridge.encodeDescriptor(
      const CoinMeta(singular: 'Mesh Coin', plural: 'Mesh Coin', code: 'MSH'),
      mint.public);

  String mintToken(int amount) {
    final ctx = Bdhke.blind(amount, mint.keysetId);
    final sig = Bdhke.mintSign(
        amount, mint.keysetId, mint.privFor(amount)!, ctx.blinded);
    final proof = Bdhke.unblind(ctx, sig, mint.public.keyFor(amount)!);
    return BearerToken(coinId, [proof]).encode();
  }

  List sectionsOf(Map<String, Object?> r) =>
      (r['coins'] as List).cast<Map>();

  test('add a provider coin, then it shows in the list', () async {
    final b = freshBridge();
    await b.init();
    final r = b.handle('coin.add', {'descriptor': descriptor});
    expect(r['coin_status'], contains('Added'));
    final items = (sectionsOf(r).first['items'] as List);
    expect(items.length, 1);
    expect((items.first as Map)['title'], 'Mesh Coin');
  });

  test('rejects a garbage descriptor', () async {
    final b = freshBridge();
    await b.init();
    final r = b.handle('coin.add', {'descriptor': 'not-a-descriptor'});
    expect(r['coin_status'], contains('Invalid'));
  });

  test('receive a bearer token and see the balance', () async {
    final b = freshBridge();
    await b.init();
    b.handle('coin.add', {'descriptor': descriptor});
    final r = b.handle('coin.receive', {'token': mintToken(8)});
    expect(r['coin_status'].toString(), contains('Received 8 MSH'));
    // The balance shows as a tag chip on the coin row.
    final item = ((sectionsOf(r).first['items'] as List).first as Map);
    expect((item['tags'] as List).first, '8 MSH');
  });

  test('receiving a token for an unknown coin is refused', () async {
    final b = freshBridge();
    await b.init();
    // No coin.add first.
    final r = b.handle('coin.receive', {'token': mintToken(4)});
    expect(r['coin_status'], contains('Unknown coin'));
  });

  test('coin.detail returns metadata and balance', () async {
    final b = freshBridge();
    await b.init();
    b.handle('coin.add', {'descriptor': descriptor});
    b.handle('coin.receive', {'token': mintToken(4)});
    final d = b.handle('coin.detail', {'coinId': coinId});
    expect(d['detail_name'], 'Mesh Coin');
    expect(d['detail_code'], 'MSH');
    expect(d['detail_balance'].toString(), contains('4'));
  });

  test('registry persists across bridge reloads', () async {
    final dir = Directory.systemTemp.createTempSync('coinbridge_persist_');
    temps.add(dir);
    final storage = makeFilesystemStorage(dir.path);

    final b1 = CoinHostBridge(storage);
    await b1.init();
    b1.handle('coin.add', {'descriptor': descriptor});
    // Give the fire-and-forget persist a moment to flush.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final b2 = CoinHostBridge(storage);
    await b2.init();
    final r = b2.handle('coin.list', {});
    final items = (sectionsOf(r).first['items'] as List);
    expect(items.length, 1);
  });
}
