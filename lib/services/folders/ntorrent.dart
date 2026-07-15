/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * `ntorrent1…` — the shareable address of a torrent folder (docs/torrents.md §11).
 *
 * A NIP-19-style TLV bech32 pointer with its own human-readable prefix, so a
 * parser knows it is holding a TORRENT and not a person before it knows anything
 * about the network:
 *
 *   T=0 special : 32-byte folder public key        (required, exactly one)
 *   T=1 hint    : 16-byte RNS destination hash of a provider/indexer (0..n)
 *   T=2 author  : 32-byte pubkey of the publisher  (optional, off by default)
 *   T=3 kind    : uint32 big-endian                (optional, reserved)
 *
 * The hints and the author are UNSIGNED and are only a hint: a hostile sharer
 * can make us dial a peer that turns out not to have the folder (costing one
 * failed link) but can never alter the listing, because the op-log is signed by
 * the folder key — which is TLV 0 of the very link they handed us.
 *
 * Unknown TLV types are skipped rather than rejected, so the encoding can grow
 * without breaking clients built today.
 */

import 'dart:typed_data';

import 'package:bech32/bech32.dart';
import 'package:hex/hex.dart';

const String kNtorrentHrp = 'ntorrent';

/// A decoded torrent pointer.
class NtorrentRef {
  /// 64-hex folder public key (the folder id).
  final String folderId;

  /// RNS destination hashes (16 bytes each) of providers/indexers worth asking
  /// first, before walking the DHT. May be stale — they are a hint, not a fact.
  final List<Uint8List> hints;

  /// 64-hex pubkey of the publisher, when the sharer chose to include it (it is
  /// off by default, so most links carry none — see RnsService.folderLink).
  final String? author;

  const NtorrentRef({
    required this.folderId,
    this.hints = const [],
    this.author,
  });
}

class Ntorrent {
  Ntorrent._();

  /// Encode a torrent pointer. [hints] are 16-byte RNS destination hashes;
  /// anything of another length is dropped rather than silently truncated.
  static String encode(
    String folderIdHex, {
    List<Uint8List> hints = const [],
    String? authorHex,
  }) {
    final id = _hex32(folderIdHex);
    if (id == null) {
      throw ArgumentError('folderId must be 32 bytes of hex');
    }
    final tlv = <int>[];
    _put(tlv, 0, id);
    for (final h in hints) {
      if (h.length != 16) continue;
      _put(tlv, 1, h);
    }
    final author = authorHex == null ? null : _hex32(authorHex);
    if (author != null) _put(tlv, 2, author);

    final data = _convertBits(Uint8List.fromList(tlv), 8, 5, true);
    return const Bech32Codec()
        .encode(Bech32(kNtorrentHrp, List<int>.from(data)), 4096);
  }

  /// Decode any address a user might paste: `ntorrent1…`, a bare `npub1…`, or
  /// 64 hex characters. Returns null when it is none of those.
  ///
  /// A bare npub decodes to a pointer with no hints and no author — it works,
  /// it is just the slow cold start.
  static NtorrentRef? decode(String input) {
    var s = input.trim();
    if (s.startsWith('nostr:')) s = s.substring(6);
    if (s.startsWith('geogram://torrent/')) s = s.substring(18);
    if (s.isEmpty) return null;

    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s)) {
      return NtorrentRef(folderId: s.toLowerCase());
    }

    try {
      // NIP-19 does not apply bech32's 90-char address limit, and a pointer
      // carrying several hints runs well past it.
      final d = const Bech32Codec().decode(s, 4096);
      final hrp = d.hrp.toLowerCase();
      final bytes = _convertBits(Uint8List.fromList(d.data), 5, 8, false);
      if (bytes.isEmpty) return null;

      if (hrp == 'npub') {
        if (bytes.length != 32) return null;
        return NtorrentRef(folderId: HEX.encode(bytes));
      }
      if (hrp != kNtorrentHrp) return null;

      final tlv = _decodeTlv(bytes);
      final special = tlv[0];
      if (special == null || special.isEmpty || special.first.length != 32) {
        return null;
      }
      final author = tlv[2];
      return NtorrentRef(
        folderId: HEX.encode(special.first),
        hints: [
          for (final h in tlv[1] ?? const <Uint8List>[])
            if (h.length == 16) h,
        ],
        author: (author != null &&
                author.isNotEmpty &&
                author.first.length == 32)
            ? HEX.encode(author.first)
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// True when [s] looks like a torrent pointer of any accepted form.
  static bool looksLikeTorrent(String s) => decode(s) != null;

  static void _put(List<int> out, int type, Uint8List value) {
    if (value.length > 255) return;
    out
      ..add(type)
      ..add(value.length)
      ..addAll(value);
  }

  static Uint8List? _hex32(String hex) {
    final s = hex.trim();
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s)) return null;
    return Uint8List.fromList(HEX.decode(s.toLowerCase()));
  }

  static Map<int, List<Uint8List>> _decodeTlv(Uint8List data) {
    final out = <int, List<Uint8List>>{};
    var i = 0;
    while (i + 1 < data.length) {
      final type = data[i];
      final len = data[i + 1];
      i += 2;
      if (i + len > data.length) break;
      out
          .putIfAbsent(type, () => <Uint8List>[])
          .add(Uint8List.fromList(data.sublist(i, i + len)));
      i += len;
    }
    return out;
  }

  static Uint8List _convertBits(Uint8List data, int from, int to, bool pad) {
    var acc = 0;
    var bits = 0;
    final maxv = (1 << to) - 1;
    final out = <int>[];
    for (final v in data) {
      if (v < 0 || (v >> from) != 0) return Uint8List(0);
      acc = (acc << from) | v;
      bits += from;
      while (bits >= to) {
        bits -= to;
        out.add((acc >> bits) & maxv);
      }
    }
    if (pad) {
      if (bits > 0) out.add((acc << (to - bits)) & maxv);
    } else if (bits >= from || ((acc << (to - bits)) & maxv) != 0) {
      return Uint8List(0);
    }
    return Uint8List.fromList(out);
  }
}
