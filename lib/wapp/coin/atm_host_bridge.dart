/*
 * atm_host_bridge — host-side service backing the "atm" wapp.
 *
 * An ATM is a trusted node for a coin: it runs that coin's permissioned
 * blockchain (registering transactions) and distributes assigned coins per the
 * administrator's rules (a faucet / event participation reward). This bridge
 * uses the participation-coin library directly (package:reticulum) to let the
 * device operate as an ATM for one or more coins — each coin with its OWN
 * metadata, keyset, rules and persistent blockchain database (one file per
 * coin). The operator's npub is the coin's trusted validator.
 *
 * v1 scope: this node is the operator/issuer for the coins it creates (it holds
 * the coin master key, so it can sign issuance, and its profile key produces the
 * blocks). The trusted-ATM set is recorded for when networked multi-node
 * consensus lands (that needs the Reticulum transport, still pending). A coin a
 * user creates here can be shared as a descriptor and held in the "wallet" wapp.
 *
 * Messages (wapp -> host) -> map of UI field updates:
 *   atm.list                                              -> {atm_coins, atm_status}
 *   atm.npub                                              -> {atm_npub}
 *   atm.create  {singular,plural,code,symbol,desc,picture,exp,reward}
 *                                                         -> {atm_coins, atm_status, atm_descriptor}
 *   atm.faucet  {coinId,to,amount}                        -> {atm_coins, atm_status}
 *   atm.addatm  {coinId,npub}                             -> {atm_coins, atm_status}
 *   atm.descriptor {coinId}                               -> {atm_descriptor, atm_status}
 */
import 'package:reticulum/reticulum.dart';

import '../../profile/profile_service.dart';
import '../../profile/profile_storage.dart';
import 'coin_host_bridge.dart' show CoinHostBridge, CoinMeta;

/// A coin this device operates an ATM for.
class _AtmCoin {
  final String coinId;
  CoinMeta meta;
  final String masterPriv; // coin administrator key (signs issuance)
  final String seed; // mint keyset derivation seed
  final int exp; // max denomination exponent
  Map<String, dynamic> rules; // assignment/faucet rules
  final List<String> atms; // trusted ATM pubkeys (incl. this operator)
  int issued; // total distributed
  List<dynamic> blocksJson; // persisted chain blocks

  CoinMintKeys? _mint;
  AtmChain? _chain;

  _AtmCoin({
    required this.coinId,
    required this.meta,
    required this.masterPriv,
    required this.seed,
    required this.exp,
    required this.rules,
    required this.atms,
    required this.issued,
    required this.blocksJson,
  });

  CoinMintKeys get mint =>
      _mint ??= CoinMintKeys.derive(coinId, seed, maxExp: exp);
  CoinKeyset get keyset => mint.public;

  Map<String, dynamic> toReg() => {
        'coinId': coinId,
        'meta': meta.toJson(),
        'masterPriv': masterPriv,
        'seed': seed,
        'exp': exp,
        'rules': rules,
        'atms': atms,
        'issued': issued,
      };

  static _AtmCoin? fromReg(Object? o) {
    if (o is! Map) return null;
    final coinId = o['coinId'];
    final masterPriv = o['masterPriv'];
    final seed = o['seed'];
    if (coinId is! String || masterPriv is! String || seed is! String) {
      return null;
    }
    return _AtmCoin(
      coinId: coinId,
      meta: CoinMeta.fromJson(o['meta']),
      masterPriv: masterPriv,
      seed: seed,
      exp: o['exp'] is int ? o['exp'] as int : 10,
      rules: o['rules'] is Map
          ? Map<String, dynamic>.from(o['rules'] as Map)
          : <String, dynamic>{},
      atms: (o['atms'] is List)
          ? List<String>.from((o['atms'] as List).map((e) => e.toString()))
          : <String>[],
      issued: o['issued'] is int ? o['issued'] as int : 0,
      blocksJson: const [],
    );
  }
}

class AtmHostBridge {
  AtmHostBridge(this._storage, {String? operatorPriv})
      : _opPrivOverride = operatorPriv;

  final ProfileStorage _storage;
  final String? _opPrivOverride; // test injection; null => active profile
  final Map<String, _AtmCoin> _coins = {};
  bool _loaded = false;

  static const String _registryFile = 'atm_coins.json';
  String _chainFile(String coinId) => 'atm_chain_$coinId.json';

  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    final data = await _storage.readJson(_registryFile);
    final list = data?['coins'];
    if (list is List) {
      for (final e in list) {
        final coin = _AtmCoin.fromReg(e);
        if (coin == null) continue;
        final chainData = await _storage.readJson(_chainFile(coin.coinId));
        final blocks = chainData?['blocks'];
        if (blocks is List) coin.blocksJson = blocks;
        _coins[coin.coinId] = coin;
      }
    }
  }

  // ── identity ────────────────────────────────────────────────────────────────

  String? get _operatorPriv {
    if (_opPrivOverride != null) return _opPrivOverride;
    final nsec = ProfileService.instance.activeProfile?.nsec;
    if (nsec == null || nsec.isEmpty) return null;
    try {
      return NostrCrypto.decodeNsec(nsec);
    } catch (_) {
      return null;
    }
  }

  String? get _operatorPub {
    final p = _operatorPriv;
    return p == null ? null : NostrCrypto.derivePublicKey(p);
  }

  // ── dispatch ────────────────────────────────────────────────────────────────

  Map<String, Object?> handle(String type, Map<String, dynamic> data) {
    switch (type) {
      case 'atm.list':
        return _list();
      case 'atm.npub':
        final pub = _operatorPub;
        return {'atm_npub': pub == null ? '' : NostrCrypto.encodeNpub(pub)};
      case 'atm.create':
        return _create(data);
      case 'atm.faucet':
        return _faucet((data['coinId'] ?? '').toString(),
            (data['to'] ?? '').toString(), data['amount']);
      case 'atm.addatm':
        return _addAtm((data['coinId'] ?? '').toString(),
            (data['npub'] ?? '').toString());
      case 'atm.descriptor':
        return _descriptor((data['coinId'] ?? '').toString());
      default:
        return const {};
    }
  }

  // ── operations ──────────────────────────────────────────────────────────────

  Map<String, Object?> _create(Map<String, dynamic> data) {
    final opPub = _operatorPub;
    if (opPub == null) return _status('No active profile to operate as ATM.');
    final meta = CoinMeta(
      singular: (data['singular'] ?? '').toString().trim(),
      plural: (data['plural'] ?? '').toString().trim(),
      code: (data['code'] ?? '').toString().trim(),
      symbol: (data['symbol'] ?? '').toString().trim(),
      desc: (data['desc'] ?? '').toString().trim(),
      picture: (data['picture'] ?? '').toString().trim(),
    );
    if (meta.singular.isEmpty && meta.plural.isEmpty && meta.code.isEmpty) {
      return _status('Name the coin (singular, plural and/or short code).');
    }
    final exp = _int(data['exp'], 10).clamp(0, 20);
    final master = NostrCrypto.generateKeyPair();
    final seed = NostrCrypto.generateKeyPair().privateKeyHex;
    final coin = _AtmCoin(
      coinId: master.publicKeyHex,
      meta: meta,
      masterPriv: master.privateKeyHex,
      seed: seed,
      exp: exp,
      rules: {
        'reward': _int(data['reward'], 1),
        'cap': _int(data['cap'], 0),
        'window': _int(data['window'], 86400),
      },
      atms: [opPub],
      issued: 0,
      blocksJson: const [],
    );
    _coins[coin.coinId] = coin;
    _persistRegistry();
    final out = _list();
    out['atm_status'] =
        'Created ${meta.displayName} — share its descriptor or distribute.';
    out['atm_descriptor'] = _descriptorOf(coin);
    return out;
  }

  Map<String, Object?> _faucet(String coinId, String to, Object? amountRaw) {
    final coin = _coins[
        coinId.isEmpty && _coins.length == 1 ? _coins.keys.first : coinId];
    if (coin == null) return _status('Pick one of your coins.');
    final opPriv = _operatorPriv;
    if (opPriv == null) return _status('No operator key to sign blocks.');
    final amount = _int(amountRaw, 0);
    if (amount <= 0) return _status('Enter an amount greater than zero.');
    if (to.trim().isEmpty) return _status('Enter a recipient npub.');
    String toHex;
    try {
      toHex =
          to.startsWith('npub') ? NostrCrypto.decodeNpub(to.trim()) : to.trim();
    } catch (_) {
      return _status('Invalid recipient npub.');
    }
    final chain = _chainFor(coin);
    if (chain == null) return _status('Could not open the coin ledger.');
    final nonce = 'g:${chain.blocks.length}:$amount';
    final grant = buildGrantTx(coin.coinId, coin.masterPriv, toHex, amount, nonce);
    final block = chain.produceBlock(opPriv, [grant]);
    if (block == null) return _status('Distribution was rejected by the ledger.');
    coin.issued += amount;
    _persistChain(coin, chain);
    _persistRegistry();
    final out = _list();
    out['atm_status'] =
        'Distributed ${coin.meta.amount(amount)} — ledger height ${chain.state.height}.';
    return out;
  }

  Map<String, Object?> _addAtm(String coinId, String npub) {
    final coin = _coins[coinId];
    if (coin == null) return _status('Pick one of your coins.');
    String hex;
    try {
      hex = npub.startsWith('npub')
          ? NostrCrypto.decodeNpub(npub.trim())
          : npub.trim();
    } catch (_) {
      return _status('Invalid npub.');
    }
    if (hex.isEmpty) return _status('Enter an npub to trust.');
    if (!coin.atms.contains(hex)) {
      coin.atms.add(hex);
      _persistRegistry();
      return _status('Designated as a trusted ATM for ${coin.meta.displayName}.');
    }
    return _status('Already trusted.');
  }

  Map<String, Object?> _descriptor(String coinId) {
    final coin = _coins[
        coinId.isEmpty && _coins.length == 1 ? _coins.keys.first : coinId];
    if (coin == null) return _status('Pick one of your coins.');
    return {
      'atm_descriptor': _descriptorOf(coin),
      'atm_status': 'Descriptor ready to share.'
    };
  }

  // ── view + helpers ───────────────────────────────────────────────────────────

  String _descriptorOf(_AtmCoin coin) =>
      CoinHostBridge.encodeDescriptor(coin.meta, coin.keyset);

  AtmChain? _chainFor(_AtmCoin coin) {
    if (coin._chain != null) return coin._chain;
    final op = _operatorPub;
    if (op == null) return null;
    final chain = AtmChain(coin.coinId, coin.keyset, [op]);
    for (final bj in coin.blocksJson) {
      final b = AtmBlock.fromJson(bj);
      if (b != null) chain.appendBlock(b);
    }
    coin._chain = chain;
    return chain;
  }

  Map<String, Object?> _list() => {'atm_coins': _sections()};

  Map<String, Object?> _status(String status) {
    final out = _list();
    out['atm_status'] = status;
    return out;
  }

  List<Map<String, dynamic>> _sections() {
    final items = <Map<String, dynamic>>[];
    for (final c in _coins.values) {
      final height = c.blocksJson.length;
      items.add({
        'id': c.coinId,
        'avatar': c.meta.avatar,
        'title': c.meta.displayName,
        'subtitle':
            'issued ${c.issued}  ·  ledger $height blocks  ·  ${c.atms.length} ATM(s)',
        if (c.meta.code.isNotEmpty) 'tags': [c.meta.code],
      });
    }
    return [
      {'title': 'Your coins', 'items': items}
    ];
  }

  void _persistRegistry() {
    _storage.writeJson(
        _registryFile, {'coins': [for (final c in _coins.values) c.toReg()]});
  }

  void _persistChain(_AtmCoin coin, AtmChain chain) {
    final blocks = [for (final b in chain.blocks) b.toJson()];
    coin.blocksJson = blocks;
    _storage.writeJson(_chainFile(coin.coinId), {'blocks': blocks});
  }

  static int _int(Object? v, int fallback) {
    if (v is int) return v;
    return int.tryParse((v ?? '').toString().trim()) ?? fallback;
  }
}
