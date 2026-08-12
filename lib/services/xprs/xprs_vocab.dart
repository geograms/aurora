/// The XPRS vocabularies a transport has to understand.
///
/// Deliberately not all of them. Most of the format is content — `mood:`,
/// `kind:` on a place, the poll options — and a transport has no business
/// knowing those. What is here is what decides how bytes travel: how urgent a
/// packet is, how far it may be relayed, and where it may go.
library;

import 'dart:convert';

import 'xprs_packet.dart';

/// How much a carried packet is worth keeping when the store is full
/// (`docs/XPRS.md` section 13.5).
///
/// Ordered lowest-first: the custody store evicts `ORDER BY urg, ts`.
enum XprsUrgency {
  low,
  normal,
  high,
  urgent;

  /// Parse an `urg:` value. Anything unrecognised is [normal], because design
  /// rule 8 skips an unknown word rather than failing, and dropping a message
  /// whose urgency did not parse would be worse than carrying it.
  static XprsUrgency fromWire(String? v) =>
      switch (v?.trim().toLowerCase()) {
        'low' => XprsUrgency.low,
        'high' => XprsUrgency.high,
        'urgent' => XprsUrgency.urgent,
        _ => XprsUrgency.normal,
      };

  /// The highest level this may be raised to. A sender states what it wants;
  /// the carrier decides what it is allowed to have (section 13.5).
  XprsUrgency cappedAt(XprsUrgency cap) => index <= cap.index ? this : cap;
}

/// How far a packet may be relayed, by packet type (`docs/XPRS.md` section 13.1).
///
/// The limit belongs to the type rather than to a field, so a sender cannot ask
/// the network for more airtime than its traffic warrants, and an emergency does
/// not have to remember to ask.
int xprsRelayLimit(String type) =>
    (type == 'sos' || type == 'warning') ? 9 : 3;

/// The callsigns that have relayed a packet, oldest first (section 13).
///
/// The hop count is not transmitted: it is the length of this list.
List<String> xprsVia(XprsPacket p) {
  final v = p['via'];
  if (v == null || v.isEmpty) return const [];
  return v.split(',').where((c) => c.isNotEmpty).toList();
}

/// Whether [p] may still be relayed, given its type and the hops it has taken.
bool xprsMayRelay(XprsPacket p) =>
    xprsVia(p).length < xprsRelayLimit(p.type);

/// Whether [self] already appears in `via:` (section 13.2).
///
/// A station that finds itself in the path does not relay, whatever the count
/// says: the limit bounds how far a packet travels, the path stops it going in
/// a circle, and neither substitutes for the other.
bool xprsWouldLoop(XprsPacket p, String self) {
  final me = self.toUpperCase();
  return xprsVia(p).any((c) => c.toUpperCase() == me);
}

/// [p] with [self] appended to `via:`, which is what a relay transmits.
///
/// Neither the identifier nor the signature changes, because both are computed
/// with `via:` removed (sections 5 and 9.1).
XprsPacket xprsAppendVia(XprsPacket p, String self) {
  final path = xprsVia(p);
  return p.with_('via', [...path, self.toUpperCase()].join(','));
}

/// How far a packet may travel, geographically and by network
/// (`docs/XPRS.md` section 13.11).
enum XprsScope {
  /// Anywhere, including the internet. The default when `scope:` is absent.
  global,

  /// Only the bearers in range now — Bluetooth, WiFi Direct, WiFi Aware, a LAN.
  /// Never carried, never gatewayed.
  local,

  /// One or more ISO 3166-1 alpha-2 country codes.
  country,
}

/// The scope of [p], and the country codes when it names any.
({XprsScope scope, List<String> countries}) xprsScope(XprsPacket p) {
  final v = p['scope'];
  if (v == null || v.isEmpty || v == 'global') {
    return (scope: XprsScope.global, countries: const []);
  }
  if (v == 'local') return (scope: XprsScope.local, countries: const []);
  return (
    scope: XprsScope.country,
    countries: v.split(',').where((c) => c.isNotEmpty).toList()
  );
}

/// Whether [p] may be handed to a carrier at all (section 13.11.3).
///
/// A `local` packet is for the bearers in range now, so carrying it to another
/// town is precisely what it excludes — and the refusal belongs at admission,
/// not at transmission, or a parked copy leaks later.
bool xprsMayCarry(XprsPacket p) => xprsScope(p).scope != XprsScope.local;

/// The bearer a reading is about (`docs/XPRS.md` section 10.6.1).
///
/// Required on any packet carrying `busy:`, `txtime:` or `hears:`, because a
/// station here is not one radio on one channel and a figure averaged across
/// LoRa and a LAN is not a quantity.
const Set<String> kXprsBearers = {
  'lora',
  'ble',
  'wifi',
  'halow',
  'lan',
  'internet',
  'vhf',
  'uhf',
  'hf',
  'cb',
  'pmr',
  'satellite',
  'other',
};

/// Build the neighbour half of a discovery beacon (`docs/XPRS.md` section
/// 10.6.4).
///
/// [candidates] must already be ordered most-relevant-first — the format leaves
/// what "relevant" means to the sender, so the caller decides whether that is
/// signal now, uptime, or being a powered relay on a hill.
///
/// Returns `hears:` truncated to whatever fits [budget] and `peers:` set to the
/// **full** count, which is the point: without it a short list cannot be told
/// from a small mesh, and a client would draw a map that is quietly wrong.
({int peers, List<String> hears}) xprsNeighbourFit(
  List<String> candidates,
  XprsPacket envelope,
  int budget,
) {
  final total = candidates.length;
  var take = <String>[];
  for (var i = 1; i <= candidates.length; i++) {
    final trial = candidates.sublist(0, i);
    final p = envelope
        .with_('peers', '$total')
        .with_('hears', trial.join(','));
    if (utf8.encode(p.encode()).length > budget) break;
    take = trial;
  }
  return (peers: total, hears: take);
}

/// How many stations the sender can reach directly, of which `hears:` lists the
/// ones that fitted (section 10.6.4). Null when the packet states none.
int? xprsPeers(XprsPacket p) => int.tryParse(p['peers'] ?? '');

/// A duration as an XPRS `qty` (section 10.9: `s`, `min`, `h`, `day`) — coarse
/// on purpose. `uptime:` and `lifetime:` (section 10.5) change by the second
/// while their meaning changes by the hour, so the spec asks for `uptime:26h`,
/// not `uptime:94340s`.
String xprsFmtDuration(int seconds) {
  if (seconds < 120) return '${seconds}s';
  if (seconds < 120 * 60) return '${seconds ~/ 60}min';
  if (seconds < 48 * 3600) return '${seconds ~/ 3600}h';
  return '${seconds ~/ 86400}day';
}

/// Messages this station holds for others and would hand over (section 10.6.5).
///
/// Deliberately not part of [xprsReadingIsScoped]: mail held is a fact about the
/// station, not about one bearer, so it needs no `link:`.
int? xprsMail(XprsPacket p) => int.tryParse(p['mail'] ?? '');

/// Whether a channel reading on [p] is usable: it must name its bearer.
///
/// A reading without `link:` is discarded rather than guessed at — it is not
/// vague, it is unanswerable.
bool xprsReadingIsScoped(XprsPacket p) {
  final hasReading = p.has('busy') || p.has('txtime') || p.has('hears');
  if (!hasReading) return true;
  final link = p['link'];
  return link != null && kXprsBearers.contains(link);
}
