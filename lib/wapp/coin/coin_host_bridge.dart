/*
 * coin_host_bridge — host-side service backing the "wallet" wapp.
 *
 * Uses the participation-coin library directly (package:reticulum, no shims) to
 * manage the coins a user holds from different providers (administrators). It
 * keeps a small per-wapp registry of coin descriptors (coin metadata + public
 * keyset) plus a CoinWallet of bearer-token holdings, and answers the coin.*
 * messages the wallet wapp emits — mirroring the social.* bridge pattern.
 *
 * Each coin carries display metadata (CoinMeta): a denomination name in singular
 * and plural (Euro / Euros), a short code (EUR), an optional symbol (€), a
 * description and a small picture (emoji / svg).
 *
 * Messages (wapp -> host) -> map of UI field updates:
 *   coin.list                          -> {coins, coin_status}
 *   coin.add     {descriptor}          -> {coins, coin_status}
 *   coin.remove  {coinId}              -> {coins, coin_status}
 *   coin.receive {token}               -> {coins, coin_status}
 *   coin.send    {coinId, to, amount}  -> {coins, coin_status, send_result}
 *   coin.detail  {coinId}              -> {detail_*}
 */
import 'dart:convert';

import 'package:reticulum/reticulum.dart';

import '../../profile/profile_service.dart';
import '../../profile/profile_storage.dart';

/// Display metadata for a coin (a denomination, like Euro / Euros / EUR / €).
class CoinMeta {
  final String singular; // "Euro"
  final String plural; // "Euros"
  final String code; // "EUR" (shortname)
  final String symbol; // "€" (optional)
  final String desc; // free-text description
  final String picture; // emoji / single char, or "svg:<xml>" (optional)

  const CoinMeta({
    this.singular = '',
    this.plural = '',
    this.code = '',
    this.symbol = '',
    this.desc = '',
    this.picture = '',
  });

  String get displayName => plural.isNotEmpty
      ? plural
      : code.isNotEmpty
          ? code
          : singular.isNotEmpty
              ? singular
              : 'Coin';

  /// The unit word for a count (singular for 1, else plural).
  String unit(int n) => n == 1
      ? (singular.isNotEmpty ? singular : displayName)
      : (plural.isNotEmpty ? plural : displayName);

  /// A compact amount label: "€5", or "5 EUR", or "5 Euros".
  String amount(int n) => symbol.isNotEmpty
      ? '$symbol$n'
      : code.isNotEmpty
          ? '$n $code'
          : '$n ${unit(n)}';

  /// Avatar glyph for list rows: the symbol or an emoji picture, else ''.
  String get avatar => symbol.isNotEmpty
      ? symbol
      : (picture.isNotEmpty && !picture.startsWith('svg:') ? picture : '');

  Map<String, dynamic> toJson() => {
        'sg': singular,
        'pl': plural,
        'cd': code,
        'sy': symbol,
        'de': desc,
        'pic': picture,
      };

  static CoinMeta fromJson(Object? o) {
    if (o is! Map) return const CoinMeta();
    return CoinMeta(
      singular: (o['sg'] ?? '').toString(),
      plural: (o['pl'] ?? '').toString(),
      code: (o['cd'] ?? '').toString(),
      symbol: (o['sy'] ?? '').toString(),
      desc: (o['de'] ?? '').toString(),
      picture: (o['pic'] ?? '').toString(),
    );
  }
}

/// One coin the user holds, from some provider/administrator.
class CoinReg {
  final String coinId;
  final CoinMeta meta;
  final CoinKeyset keyset;
  const CoinReg(this.coinId, this.meta, this.keyset);

  Map<String, dynamic> toJson() =>
      {'coinId': coinId, 'meta': meta.toJson(), 'keyset': keyset.toJson()};

  static CoinReg? fromJson(Object? o) {
    if (o is! Map) return null;
    final keyset = CoinKeyset.fromJson(o['keyset']);
    if (keyset == null) return null;
    return CoinReg(keyset.coinId, CoinMeta.fromJson(o['meta']), keyset);
  }
}

const String _kDescriptorPrefix = 'coindesc1';

class CoinHostBridge {
  CoinHostBridge(this._storage);

  final ProfileStorage _storage;
  final Map<String, CoinReg> _coins = {}; // coinId -> registry entry
  CoinWallet? _wallet;
  bool _loaded = false;

  static const String _registryFile = 'coins.json';
  static const String _walletFile = 'coin_wallet.sqlite3';

  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    final data = await _storage.readJson(_registryFile);
    final list = data?['coins'];
    if (list is List) {
      for (final e in list) {
        final reg = CoinReg.fromJson(e);
        if (reg != null) _coins[reg.coinId] = reg;
      }
    }
  }

  /// Build a shareable descriptor a provider hands out so users can hold the
  /// coin (the coinId is inside the keyset).
  static String encodeDescriptor(CoinMeta meta, CoinKeyset keyset) {
    final json = jsonEncode({'meta': meta.toJson(), 'keyset': keyset.toJson()});
    return _kDescriptorPrefix + base64Url.encode(utf8.encode(json));
  }

  static CoinReg? _decodeDescriptor(String input) {
    final s = input.trim();
    try {
      if (s.startsWith(_kDescriptorPrefix)) {
        final json = jsonDecode(
            utf8.decode(base64Url.decode(s.substring(_kDescriptorPrefix.length))));
        return CoinReg.fromJson(json);
      }
      return CoinReg.fromJson(jsonDecode(s));
    } catch (_) {
      return null;
    }
  }

  CoinWallet _w() =>
      _wallet ??= CoinWallet.open(_storage.getAbsolutePath(_walletFile));

  String? get _myPriv {
    final nsec = ProfileService.instance.activeProfile?.nsec;
    if (nsec == null || nsec.isEmpty) return null;
    try {
      return NostrCrypto.decodeNsec(nsec);
    } catch (_) {
      return null;
    }
  }

  void _persist() {
    _storage.writeJson(
        _registryFile, {'coins': [for (final c in _coins.values) c.toJson()]});
  }

  Map<String, Object?> handle(String type, Map<String, dynamic> data) {
    switch (type) {
      case 'coin.list':
        return _listFields();
      case 'coin.add':
        return _add((data['descriptor'] ?? '').toString());
      case 'coin.remove':
        return _remove((data['coinId'] ?? '').toString());
      case 'coin.receive':
        return _receive((data['token'] ?? '').toString());
      case 'coin.send':
        return _send((data['coinId'] ?? '').toString(),
            (data['to'] ?? '').toString(), data['amount']);
      case 'coin.detail':
        return _detail((data['coinId'] ?? '').toString());
      default:
        return const {};
    }
  }

  // ── operations ──────────────────────────────────────────────────────────────

  Map<String, Object?> _add(String descriptor) {
    if (descriptor.isEmpty) return _withStatus('Paste a coin descriptor first.');
    final reg = _decodeDescriptor(descriptor);
    if (reg == null) return _withStatus('Invalid coin descriptor.');
    _coins[reg.coinId] = reg;
    _persist();
    return _withStatus('Added ${reg.meta.displayName}.');
  }

  Map<String, Object?> _remove(String coinId) {
    if (_coins.remove(coinId) != null) {
      _persist();
      return _withStatus('Removed.');
    }
    return _withStatus('No such coin.');
  }

  Map<String, Object?> _receive(String tokenStr) {
    if (tokenStr.isEmpty) return _withStatus('Paste a token to receive.');
    final token = BearerToken.decode(tokenStr.trim());
    if (token == null) return _withStatus('Not a valid coin token.');
    final reg = _coins[token.coinId];
    if (reg == null) {
      return _withStatus('Unknown coin — add the provider first.');
    }
    var received = 0;
    for (final p in token.proofs) {
      if (p.keysetId != reg.keyset.keysetId) continue;
      final k = reg.keyset.keyFor(p.amount);
      if (k == null || !Bdhke.verifyOffline(p, k)) continue;
      if (_w().add(token.coinId, p)) received += p.amount;
    }
    if (received == 0) {
      return _withStatus('Nothing accepted (already held or invalid).');
    }
    return _withStatus('Received ${reg.meta.amount(received)}.');
  }

  Map<String, Object?> _send(String coinId, String to, Object? amountRaw) {
    if (coinId.isEmpty && _coins.length == 1) coinId = _coins.keys.first;
    final reg = _coins[coinId];
    if (reg == null) return _withStatus('Pick a coin you hold (paste its Coin ID).');
    final amount = amountRaw is int
        ? amountRaw
        : int.tryParse((amountRaw ?? '').toString().trim()) ?? 0;
    if (amount <= 0) return _withStatus('Enter an amount greater than zero.');
    if (to.trim().isEmpty) return _withStatus('Enter a recipient npub.');
    final priv = _myPriv;
    if (priv == null) return _withStatus('No active profile key to sign with.');
    String toHex;
    try {
      toHex = to.startsWith('npub') ? NostrCrypto.decodeNpub(to.trim()) : to.trim();
    } catch (_) {
      return _withStatus('Invalid recipient npub.');
    }
    final service = CoinService(
        coinId: coinId, myPriv: priv, keyset: reg.keyset, wallet: _w());
    final handoff = service.sendOffline(toHex, amount);
    if (handoff == null) {
      return _withStatus('Insufficient ${reg.meta.displayName} balance.');
    }
    final out = _listFields();
    out['send_result'] = handoff.token.encode();
    out['coin_status'] =
        'Sent ${reg.meta.amount(handoff.amount)} — share the token below.';
    return out;
  }

  Map<String, Object?> _detail(String coinId) {
    final reg = _coins[coinId];
    if (reg == null) return {'detail_name': 'Unknown coin'};
    final bal = _w().balance(coinId);
    final m = reg.meta;
    return {
      'detail_picture': m.picture,
      'detail_name': m.displayName,
      'detail_balance': '${m.amount(bal)}   ·   $bal ${m.unit(bal)}',
      'detail_code': m.code,
      'detail_symbol': m.symbol,
      'detail_desc': m.desc,
      'detail_id': coinId,
    };
  }

  // ── view ─────────────────────────────────────────────────────────────────

  Map<String, Object?> _listFields() => {'coins': _coinSections()};

  Map<String, Object?> _withStatus(String status) {
    final out = _listFields();
    out['coin_status'] = status;
    return out;
  }

  /// People-field sections: one row per coin with its balance.
  List<Map<String, dynamic>> _coinSections() {
    final items = <Map<String, dynamic>>[];
    for (final c in _coins.values) {
      final bal = _w().balance(c.coinId);
      final m = c.meta;
      items.add({
        'id': c.coinId,
        'avatar': m.avatar,
        'title': m.displayName,
        'subtitle': m.desc.isNotEmpty
            ? m.desc
            : (m.code.isNotEmpty ? m.code : 'tap for details'),
        'tags': [m.amount(bal)],
      });
    }
    return [
      {'title': 'Coins', 'items': items}
    ];
  }
}
