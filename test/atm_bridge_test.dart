import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';

import 'package:aurora/profile/profile_storage.dart';
import 'package:aurora/profile/profile_storage_io.dart';
import 'package:aurora/wapp/coin/atm_host_bridge.dart';
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
  (ProfileStorage, String) freshStore() {
    final dir = Directory.systemTemp.createTempSync('atm_');
    temps.add(dir);
    return (makeFilesystemStorage(dir.path), dir.path);
  }

  tearDownAll(() {
    for (final d in temps) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  final operator = NostrCrypto.generateKeyPair();
  final recipient = NostrCrypto.generateKeyPair();

  List itemsOf(Map<String, Object?> r) =>
      ((r['atm_coins'] as List).first as Map)['items'] as List;

  test('create a coin: it appears with its own ledger and a descriptor', () async {
    final (storage, _) = freshStore();
    final b = AtmHostBridge(storage, operatorPriv: operator.privateKeyHex);
    await b.init();
    final r = b.handle('atm.create', {'plural': 'Mesh', 'code': 'MSH', 'exp': 8});
    expect(r['atm_status'].toString(), contains('Created'));
    expect((r['atm_descriptor'] as String).startsWith('coindesc1'), isTrue);
    expect(itemsOf(r).length, 1);
  });

  test('faucet distribution is registered on the coin\'s blockchain', () async {
    final (storage, path) = freshStore();
    final b = AtmHostBridge(storage, operatorPriv: operator.privateKeyHex);
    await b.init();
    final created = b.handle('atm.create', {'plural': 'Mesh', 'code': 'MSH', 'exp': 8});
    final coinId = (itemsOf(created).first as Map)['id'] as String;

    final r = b.handle('atm.faucet',
        {'coinId': coinId, 'to': recipient.npub, 'amount': 5});
    expect(r['atm_status'].toString(), contains('Distributed 5'));
    // Give the fire-and-forget chain persist a moment.
    await Future<void>.delayed(const Duration(milliseconds: 80));

    // Re-open the persisted per-coin blockchain DB and verify the credit.
    final raw = File('$path/atm_chain_$coinId.json').readAsStringSync();
    final blocks = (jsonDecode(raw)['blocks'] as List);
    expect(blocks.length, 1); // one block registered the distribution

    final mint = CoinMintKeys.derive(coinId,
        // reload uses the same seed via the registry, but we only need the
        // public keyset to replay; rebuild a chain and apply the stored block.
        _seedFromRegistry(path, coinId),
        maxExp: 8);
    final chain = AtmChain(coinId, mint.public, [operator.publicKeyHex]);
    for (final bj in blocks) {
      expect(chain.appendBlock(AtmBlock.fromJson(bj)!), isTrue);
    }
    expect(chain.state.balanceOf(recipient.publicKeyHex), 5);
  });

  test('ATM state and ledger persist across reloads', () async {
    final (storage, _) = freshStore();
    final b1 = AtmHostBridge(storage, operatorPriv: operator.privateKeyHex);
    await b1.init();
    final created = b1.handle('atm.create', {'plural': 'Mesh', 'code': 'MSH', 'exp': 8});
    final coinId = (itemsOf(created).first as Map)['id'] as String;
    b1.handle('atm.faucet', {'coinId': coinId, 'to': recipient.npub, 'amount': 7});
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final b2 = AtmHostBridge(storage, operatorPriv: operator.privateKeyHex);
    await b2.init();
    final r = b2.handle('atm.list', {});
    final sub = (itemsOf(r).first as Map)['subtitle'].toString();
    expect(sub, contains('issued 7'));
    expect(sub, contains('1 blocks'));
  });

  test('a coin created on the ATM can be held in the wallet (descriptor)', () async {
    final (atmStore, _) = freshStore();
    final atm = AtmHostBridge(atmStore, operatorPriv: operator.privateKeyHex);
    await atm.init();
    final created = atm.handle('atm.create', {'plural': 'Mesh', 'code': 'MSH', 'exp': 8});
    final descriptor = created['atm_descriptor'] as String;

    final (walletStore, _) = freshStore();
    final wallet = CoinHostBridge(walletStore);
    await wallet.init();
    final added = wallet.handle('coin.add', {'descriptor': descriptor});
    expect(added['coin_status'].toString(), contains('Added'));
  });

  test('atm.npub returns the operator npub to share', () async {
    final (storage, _) = freshStore();
    final b = AtmHostBridge(storage, operatorPriv: operator.privateKeyHex);
    await b.init();
    final r = b.handle('atm.npub', {});
    expect(r['atm_npub'], operator.npub);
  });
}

// Read the coin seed the ATM persisted, so the test can replay its keyset.
String _seedFromRegistry(String path, String coinId) {
  final reg = jsonDecode(File('$path/atm_coins.json').readAsStringSync());
  for (final c in (reg['coins'] as List)) {
    if (c['coinId'] == coinId) return c['seed'] as String;
  }
  throw StateError('coin not found');
}
