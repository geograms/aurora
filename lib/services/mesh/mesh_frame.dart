/*
 * mesh_frame — one view over the two frame formats in flight.
 *
 * We emit XPRS (docs/XPRS.md). We still have to *read* the compact
 * `FROM \x1F TO \x1F text` frame, because the chat wapp and the ESP32 dongle
 * both still speak it and custody sees every advert on the air. Reading both
 * while emitting one is what makes the changeover survivable: nothing that
 * works today stops working the day XPRS starts transmitting.
 *
 * The legacy half of this file is scaffolding. It comes out when the wapp and
 * the dongle are ported, and nothing above it has to change when it does.
 */
import 'dart:convert';
import 'dart:typed_data';

import '../xprs/xprs_id.dart';
import '../xprs/xprs_packet.dart';

/// A frame custody and the courier can reason about, whichever format it is in.
class MeshFrame {
  /// Sender callsign — XPRS `f:`, or the first compact field.
  final String from;

  /// Recipient — XPRS `d:`, or the second compact field. Empty for a broadcast.
  final String to;

  /// The six-hex handle this frame is tracked by.
  ///
  /// For XPRS this is the derived identifier (section 5), which nothing
  /// transmits. For a compact frame it is the `am:` token the sender wrote.
  /// Both are six hex characters, so the custody store needs no change at all:
  /// the column that held `am` holds this.
  final String id;

  /// The message text, still sealed if it arrived sealed.
  final String body;

  /// The parsed packet, when this is XPRS. Null for a compact frame.
  final XprsPacket? packet;

  const MeshFrame({
    required this.from,
    required this.to,
    required this.id,
    required this.body,
    this.packet,
  });

  bool get isXprs => packet != null;

  /// Read [wire] as XPRS, falling back to the compact frame.
  ///
  /// XPRS is tried first and the test is unambiguous: a compact frame always
  /// contains two `\x1F` bytes and an XPRS packet contains none and starts
  /// with `t:`. No version marker, no negotiation, no guessing.
  static MeshFrame? parse(Uint8List wire) {
    final s = utf8.decode(wire, allowMalformed: true);

    final p = XprsPacket.parse(s);
    if (p != null) {
      return MeshFrame(
        from: p['f'] ?? '',
        to: p['d'] ?? '',
        id: xprsIdentifier(p),
        body: p['x'] ?? p['m'] ?? '',
        packet: p,
      );
    }

    final a = s.indexOf('\x1F');
    if (a <= 0) return null;
    final b = s.indexOf('\x1F', a + 1);
    if (b < 0) return null;
    final text = s.substring(b + 1);
    return MeshFrame(
      from: s.substring(0, a),
      to: s.substring(a + 1, b),
      id: (text.startsWith('am:') && text.length >= 9)
          ? text.substring(3, 9)
          : '',
      body: text,
    );
  }
}
