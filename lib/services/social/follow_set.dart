/*
 * Generic host-side NOSTR follow set: the set of public keys (lowercase hex) the
 * local user follows. The host stays app-agnostic — it just holds "pubkeys I
 * follow"; the APRS wapp populates it by bridging its callsign follow list
 * through social.follow / social.unfollow host messages (a followed callsign whose
 * public key we have heard becomes a followed npub here).
 *
 * Used by the store-and-forward host to classify content into the "followed"
 * retention tier (see retention_tier.dart). Persisted as a small JSON array.
 */
import 'dart:convert';
import 'dart:io';

import '../../util/nostr_crypto.dart';

class FollowSet {
  final Set<String> _hex = {};
  String? _path;

  Set<String> get asSet => _hex;
  bool contains(String hex) => _hex.contains(hex.toLowerCase());
  int get length => _hex.length;

  /// Normalize any of: 64-char hex, an `npub1…` bech32 string, or the 43-char
  /// base64url key form used on the NOSTR beacon, to lowercase 64-char hex.
  /// Returns null if it can't be parsed.
  static String? toHex(String key) {
    final k = key.trim();
    if (k.isEmpty) return null;
    // Already hex?
    if (k.length == 64 && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(k)) {
      return k.toLowerCase();
    }
    if (k.startsWith('npub1')) {
      try {
        return NostrCrypto.decodeNpub(k).toLowerCase();
      } catch (_) {
        return null;
      }
    }
    // base64url (unpadded) of 32 raw bytes -> hex.
    try {
      final pad = (4 - (k.length % 4)) % 4;
      final bytes = base64Url.decode(k + ('=' * pad));
      if (bytes.length != 32) return null;
      final sb = StringBuffer();
      for (final b in bytes) {
        sb.write(b.toRadixString(16).padLeft(2, '0'));
      }
      return sb.toString();
    } catch (_) {
      return null;
    }
  }

  /// Add a follow from any key form; returns true if it changed the set.
  bool add(String key) {
    final h = toHex(key);
    if (h == null) return false;
    final changed = _hex.add(h);
    if (changed) _save();
    return changed;
  }

  /// Remove a follow from any key form; returns true if it changed the set.
  bool remove(String key) {
    final h = toHex(key);
    if (h == null) return false;
    final changed = _hex.remove(h);
    if (changed) _save();
    return changed;
  }

  /// Bind a persistence path and load any saved follows.
  void load(String path) {
    _path = path;
    try {
      final f = File(path);
      if (!f.existsSync()) return;
      final data = jsonDecode(f.readAsStringSync());
      if (data is List) {
        for (final e in data) {
          final h = toHex('$e');
          if (h != null) _hex.add(h);
        }
      }
    } catch (_) {
      // ignore a corrupt file; start empty
    }
  }

  void _save() {
    final p = _path;
    if (p == null) return;
    try {
      File(p).writeAsStringSync(jsonEncode(_hex.toList()));
    } catch (_) {
      // best effort
    }
  }
}
