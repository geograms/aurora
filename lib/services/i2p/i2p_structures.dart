/*
 * I2P common data structures (subset) — pure Dart.
 *
 * Parses a RouterInfo enough to (a) compute the router identity hash
 * (SHA-256 of the RouterIdentity) and (b) extract its RouterAddresses and
 * options, so we can find an NTCP2 address (host, port, static key s, IV i).
 * Formats per the I2P "Common Structures" spec: Integer (BE), String
 * (1-byte len + bytes), Mapping (2-byte len + key=value; pairs), Certificate
 * (1-byte type + 2-byte len + payload), Date (8 bytes ms).
 */
import 'dart:convert';
import 'dart:typed_data';

import 'i2p_crypto.dart';

/// I2P base64 alphabet uses '-' and '~' instead of '+' and '/'.
Uint8List i2pBase64Decode(String s) {
  var std = s.replaceAll('-', '+').replaceAll('~', '/');
  final pad = (4 - (std.length % 4)) % 4;
  std += '=' * pad;
  return base64.decode(std);
}

class I2pAddress {
  final int cost;
  final String style; // e.g. "NTCP2", "SSU2"
  final Map<String, String> options;
  I2pAddress(this.cost, this.style, this.options);

  // An NTCP2 address always carries a static key 's'; host/port may be absent
  // (e.g. an unpublished/bootstrapping router) and are optional here.
  bool get isNtcp2 => style == 'NTCP2' && options.containsKey('s');

  String? get host => options['host'];
  int? get port => int.tryParse(options['port'] ?? '');
  Uint8List? get staticKey =>
      options['s'] != null ? i2pBase64Decode(options['s']!) : null;
  Uint8List? get iv => options['i'] != null ? i2pBase64Decode(options['i']!) : null;
}

class RouterInfo {
  final Uint8List identityHash; // SHA-256 of the RouterIdentity (32 bytes)
  final Uint8List identity; // raw RouterIdentity bytes
  final List<I2pAddress> addresses;
  final Map<String, String> options;
  RouterInfo(this.identityHash, this.identity, this.addresses, this.options);

  I2pAddress? get ntcp2 {
    for (final a in addresses) {
      if (a.isNtcp2) return a;
    }
    return null;
  }

  /// The router's ECIES-X25519 encryption key (tunnel-build target). For a
  /// crypto-type-4 (ECIES) router it is the first 32 bytes of the identity's
  /// 256-byte public key field. Returns null if this router isn't ECIES.
  Uint8List? get encryptionKey =>
      isEcies ? identity.sublist(0, 32) : null;

  /// True if the RouterIdentity uses a KeyCertificate (type 5) declaring crypto
  /// type 4 (ECIES-X25519). Certificate sits after the 384-byte key section.
  bool get isEcies {
    try {
      const certStart = 256 + 128;
      if (identity.length < certStart + 7) return false;
      if (identity[certStart] != 5) return false; // KeyCertificate
      // payload: sigType(2) cryptoType(2); cryptoType at certStart+5..6
      final cryptoType = (identity[certStart + 5] << 8) | identity[certStart + 6];
      return cryptoType == 4;
    } catch (_) {
      return false;
    }
  }
}

class _Reader {
  final Uint8List b;
  int p = 0;
  _Reader(this.b);

  int u8() => b[p++];
  int u16() {
    final v = (b[p] << 8) | b[p + 1];
    p += 2;
    return v;
  }

  Uint8List take(int n) {
    final s = b.sublist(p, p + n);
    p += n;
    return s;
  }

  String i2pString() {
    final n = u8();
    return utf8.decode(take(n), allowMalformed: true);
  }

  /// I2P Mapping: 2-byte total length, then key=value; pairs.
  Map<String, String> mapping() {
    final total = u16();
    final end = p + total;
    final m = <String, String>{};
    while (p < end) {
      final key = i2pString();
      u8(); // '='
      final val = i2pString();
      u8(); // ';'
      m[key] = val;
    }
    p = end;
    return m;
  }
}

/// Parse a RouterInfo from raw bytes. Returns null on malformed input.
RouterInfo? parseRouterInfo(Uint8List data) {
  try {
    final r = _Reader(data);
    // RouterIdentity = 256 (crypto pubkey) + 128 (signing pubkey) + Certificate
    final idStart = r.p;
    r.take(256);
    r.take(128);
    r.u8(); // cert type
    final certLen = r.u16();
    r.take(certLen);
    final identity = data.sublist(idStart, r.p);
    final identityHash = I2pCrypto.sha256(identity);

    r.take(8); // published date
    final addrCount = r.u8();
    final addresses = <I2pAddress>[];
    for (var i = 0; i < addrCount; i++) {
      final cost = r.u8();
      r.take(8); // expiration date
      final style = r.i2pString();
      final opts = r.mapping();
      addresses.add(I2pAddress(cost, style, opts));
    }
    r.u8(); // peer_size (unused, 0)
    final options = r.mapping();
    // signature follows (length depends on sig type) — not needed here.
    return RouterInfo(identityHash, identity, addresses, options);
  } catch (_) {
    return null;
  }
}
