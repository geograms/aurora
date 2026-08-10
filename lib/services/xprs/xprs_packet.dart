/// The XPRS wire format: `key:value` fields separated by single spaces.
///
/// Specified in `docs/XPRS.md` sections 2 and 4. The whole format is one line
/// of text under 250 bytes, and design rule 2 asks that it stay readable
/// without a decoder:
///
/// ```
/// t:message f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 m:net starts in ten minutes
/// ```
///
/// This is the only parser in `lib/`. Before it there were three partial ones —
/// `MeshCourier._take`, `MeshCustodyDelegate._urgOf` and a pair of inline
/// `substring` reads — each of which understood a different subset of the same
/// syntax.
library;

import 'dart:convert';

/// One parsed XPRS packet.
///
/// Fields keep their transmitted order, because the identifier (`xprs_id.dart`)
/// is a hash of the packet as written. Reordering a packet would change its
/// identity, so nothing here sorts, normalises or rewrites.
class XprsPacket {
  /// Fields in transmitted order. Duplicates are preserved: the format does not
  /// forbid them and dropping one silently would change the identifier.
  final List<MapEntry<String, String>> fields;

  const XprsPacket(this.fields);

  /// The largest a packet may be on any bearer (`docs/XPRS.md` section 2).
  static const int maxBytes = 250;

  /// A key is 1 to 8 characters, lowercase letters and digits, starting with a
  /// letter (`docs/XPRS.md` section 4.1).
  static final RegExp _key = RegExp(r'^[a-z][a-z0-9]{0,7}$');

  /// Parse one line of wire text, or null if it is not an XPRS packet.
  ///
  /// Tolerant by design rule 8: an unknown or malformed field is skipped
  /// without error, because a receiver that rejects a whole packet over one
  /// field it does not recognise cannot be forward-compatible. The only way to
  /// get null is for the packet not to be XPRS at all — no leading `t:`.
  static XprsPacket? parse(String wire) {
    if (!wire.startsWith('t:')) return null;

    final out = <MapEntry<String, String>>[];
    var i = 0;
    while (i < wire.length) {
      // `m:` is the last field and its value runs to the end of the packet,
      // spaces and colons included (section 4). Nothing after it is a field.
      if (wire.startsWith('m:', i)) {
        out.add(MapEntry('m', wire.substring(i + 2)));
        break;
      }

      var end = wire.indexOf(' ', i);
      if (end < 0) end = wire.length;
      final token = wire.substring(i, end);
      i = end + 1;

      final colon = token.indexOf(':');
      if (colon <= 0) continue; // not a field; skip it and keep reading
      final key = token.substring(0, colon);
      if (!_key.hasMatch(key)) continue;
      out.add(MapEntry(key, token.substring(colon + 1)));
    }

    if (out.isEmpty || out.first.key != 't') return null;
    return XprsPacket(out);
  }

  /// The value of [key], or null. The first wins where a key repeats.
  String? operator [](String key) {
    for (final f in fields) {
      if (f.key == key) return f.value;
    }
    return null;
  }

  bool has(String key) => this[key] != null;

  /// The packet type, always the first field (design rule 2).
  String get type => fields.first.value;

  /// Rebuild the wire text. Round-trips: `parse(x).encode() == x` for any
  /// packet this parser accepted without skipping a field.
  String encode() => fields.map((f) => '${f.key}:${f.value}').join(' ');

  /// This packet with [keys] removed, order otherwise untouched.
  ///
  /// Used to derive an identifier (`sig:` and `via:` come out first) and to
  /// build the bytes a signature covers.
  XprsPacket without(Set<String> keys) =>
      XprsPacket(fields.where((f) => !keys.contains(f.key)).toList());

  /// This packet with [key] set to [value], replacing the first occurrence or
  /// appending before `m:` when the key is new.
  ///
  /// Appending *before* `m:` matters: `m:` must stay last or everything after
  /// it is read as part of the message. Five packets in the specification
  /// itself once had `sig:` after `m:`, which silently folded the signature
  /// into the message text.
  XprsPacket with_(String key, String value) {
    final out = <MapEntry<String, String>>[];
    var replaced = false;
    for (final f in fields) {
      if (f.key == key && !replaced) {
        out.add(MapEntry(key, value));
        replaced = true;
      } else {
        out.add(f);
      }
    }
    if (!replaced) {
      final at = out.indexWhere((f) => f.key == 'm');
      out.insert(at < 0 ? out.length : at, MapEntry(key, value));
    }
    return XprsPacket(out);
  }

  /// How many bytes this packet occupies on the wire.
  ///
  /// UTF-8, not characters: the `text` value type is "any bytes, spaces
  /// included" (section 4.3), so a message with accents costs more than it
  /// looks and the 250-byte limit is about bytes.
  int get byteLength => utf8.encode(encode()).length;

  /// Whether it fits the limit every bearer has to honour.
  bool get fits => byteLength <= maxBytes;

  @override
  String toString() => encode();
}
