/*
 * MeshCourier — the core's store-and-forward lane.
 *
 * Delivery is a transport problem, not a chat feature. When the core cannot
 * reach a destination directly, it hands a copy to whatever device is nearby
 * and lets the mesh carry it (docs/mesh.md §6). Wapps do not participate: they
 * hand the core a message, and the core calls them back when one arrives.
 *
 * Two halves:
 *
 *   OUT  [arm] every 1:1 the core sends. Twenty seconds later, if the message
 *        is still sitting in the retry queue, there is no working path — a peer
 *        on the LAN or reachable through a hub acknowledges in well under a
 *        second — so a compact copy goes on the air for any custodian to hold.
 *        Deciding up front does not work: the observed-node list calls a device
 *        "seen" because a hub replayed its announce cache, and a learned path
 *        outlives the peer that taught it by hours. Both were measured against
 *        a phone with its radios switched off.
 *
 *   IN   frames addressed to us — overheard on air or handed over an MSP
 *        session by a custodian — are verified, decrypted, and injected into
 *        the LXMF inbox as though they had arrived over Reticulum. The wapp
 *        that owns the conversation renders it through the path it already
 *        uses; nothing about custody reaches it.
 *
 * Wire: XPRS (docs/XPRS.md).
 *
 *   t:message f:FROM d:TO ts:2026-08-08_14:26:40 sig:<60> m:body
 *   t:message f:FROM d:TO ts:2026-08-08_14:26:40 x:<sealed> sig:<60>
 *
 * The envelope is deliberately public — a carrier that cannot read who a
 * message is for cannot decide whom to hand it to — while the body is sealed to
 * the recipient's key whenever we hold one.
 *
 * Three fields of the old compact frame are gone. `am:` because the identifier
 * is derived from the packet (section 5), so nothing announces its own id and a
 * relayed copy keeps the one it was born with. `sd:` because the sender's LXMF
 * address is a pure function of their public key, which is safer than trusting
 * an address written on the wire by whoever sent it. `np:` because a sealed
 * body already proves who the copy is for.
 *
 * We EMIT only XPRS. We still READ the compact frame (see mesh_frame.dart),
 * because the chat wapp and the ESP32 dongle still speak it and custody sees
 * every advert on the air. That half goes away when they are ported.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:crypto/crypto.dart' show sha256;

import '../../connections/bluetooth/ble_service.dart';
import '../../util/aprx_sign.dart';
import '../../util/nostr_crypto.dart';
import '../log_service.dart';
import '../../profile/profile_service.dart';
import '../reticulum/rns_service.dart';
import '../xprs/xprs_monitor.dart';
import '../xprs/xprs_packet.dart';
import '../xprs/xprs_sig.dart';
import 'mesh_custody.dart';
import 'mesh_frame.dart';
import 'mesh_service.dart';

/// One message waiting to find out whether it needs a carrier.
class _Armed {
  _Armed(this.destHex, this.text, this.armedMs);
  final String destHex;
  final String text;
  final int armedMs;
  bool aired = false;
}

class MeshCourierCounters {
  static int armed = 0;
  static int aired = 0;
  static int refusedTooLong = 0;
  static int refusedNoIdentity = 0;
  static int ingested = 0;
  static int ingestDropped = 0;

  static Map<String, dynamic> json() => {
        'armed': armed,
        'aired': aired,
        'refusedTooLong': refusedTooLong,
        'refusedNoIdentity': refusedNoIdentity,
        'ingested': ingested,
        'ingestDropped': ingestDropped,
      };
}

class MeshCourier {
  MeshCourier._();
  static final MeshCourier instance = MeshCourier._();

  /// Wait before airing a copy. The direct-link attempt inside sendLxmf gives
  /// up at 10s, so this is "the send has definitively failed", not a guess.
  static const Duration wait = Duration(seconds: 20);

  /// Stop caring: past this the retry ladder owns the message.
  static const Duration giveUp = Duration(minutes: 15);

  /// A frame a custodian cannot take whole is worse than no frame at all: the
  /// ESP32 parks up to BLEMESH_SCF_FRAME_MAX (252), so anything larger would be
  /// carried for days by the phones and dropped by the dongle you were counting
  /// on. Refuse at 240 and say so.
  static const int maxWire = 240;

  final List<_Armed> _armed = [];
  Timer? _pump;

  /// Also used by the ingest side to keep the same seen-set as the wapp bubble
  /// dedup would: a message that reaches us twice (aired copy + custody
  /// handover) must appear once.
  final Set<String> _ingested = <String>{};

  /// Note a 1:1 the core just sent over LXMF. Cheap and unconditional — the
  /// pump decides, twenty seconds later, whether it needed a carrier.
  void armLxmf({required String destHex, required String text}) {
    if (destHex.isEmpty || text.isEmpty) return;
    _armed.add(_Armed(destHex, text, DateTime.now().millisecondsSinceEpoch));
    MeshCourierCounters.armed++;
    _pump ??= Timer.periodic(const Duration(seconds: 5), (_) => _tick());
  }

  void _tick() {
    _retryUnresolved();
    if (_armed.isEmpty && _unresolved.isEmpty) {
      _pump?.cancel();
      _pump = null;
      return;
    }
    if (_armed.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _armed.removeWhere((a) {
      final age = now - a.armedMs;
      if (age < wait.inMilliseconds) return false;
      if (age > giveUp.inMilliseconds) return true;
      // Delivered while we waited: nothing to hand on.
      if (RnsService.instance.lxmfPendingFor(a.destHex) <= 0) return true;
      _air(a);
      return true;
    });
  }

  void _air(_Armed a) {
    final ble = BleService.instance;
    if (!ble.poweredOn) return;
    final self = MeshService.instance.tableCallsign.trim();
    if (self.isEmpty) return;

    final peer = RnsService.instance.identityFor(a.destHex);
    final call = (peer['callsign'] ?? '').trim();
    if (call.isEmpty) {
      MeshCourierCounters.refusedNoIdentity++;
      LogService.instance.add(
          'Courier: no callsign for ${_short(a.destHex)} — nothing to address '
          'a carrier with');
      return;
    }
    final npub = (peer['npub'] ?? '').trim();

    final body = _seal(npub, a.text);
    if (body == null) return;
    final wire = _pack(self, call, body);
    if (wire == null) return;
    if (wire.length > maxWire) {
      MeshCourierCounters.refusedTooLong++;
      LogService.instance.add(
          'Courier: ${wire.length}B is more than a carrier can hold ($maxWire) '
          '— not aired');
      return;
    }
    // PARKED, not aired.
    //
    // This used to broadcast the message itself: registered on the advert bus
    // for five minutes and refreshed twice inside that, so a passer-by might
    // catch a copy. That spent the shared channel on a message almost every
    // listener had no use for, and spent it again on every refresh, while the
    // bus rotates through all registered frames — so each extra copy also stole
    // airtime from the beacons that make the mesh work at all.
    //
    // The beacon now says `mail:N` instead (docs/XPRS.md §10.6.5). A neighbour
    // that can actually reach the recipient opens a session and takes custody;
    // everybody else spends nothing. Six bytes on a frame already on the air,
    // in place of a repeating broadcast per message.
    //
    // Parking is explicit here because it used to be a side effect of
    // `enqueueAdvert` — the custody tap parked our own outbound copy on its way
    // to the radio. No advert, no tap, so the copy is offered directly.
    MeshCustodyDelegate.onAirFrame(Uint8List.fromList(wire), outbound: true);
    MeshCourierCounters.aired++;
    LogService.instance.add(
        'Courier: no path to $call — ${wire.length}B parked for custody'
        '${npub.isEmpty ? "" : " (sealed)"}, beacon will advertise it');
  }

  /// ENC1 body when we hold their key, plaintext when we do not. Refusing to
  /// send without a key would leave the message nowhere, and the envelope is
  /// public either way — the same exposure the public 1:1 lane already has.
  String? _seal(String npub, String text) {
    if (npub.isEmpty) return text;
    try {
      final d = _privScalar();
      final pubHex = NostrCrypto.decodeNpub(npub);
      if (d == null || pubHex.isEmpty) return text;
      final blob = AprxSign.encryptFor(
          d, Uint8List.fromList(HEX.decode(pubHex)), utf8.encode(text));
      if (blob == null) return text;
      return 'ENC1:${base64Url.encode(blob).replaceAll('=', '')}';
    } catch (_) {
      return text;
    }
  }

  /// Build the frame as an XPRS packet (docs/XPRS.md).
  ///
  /// Three fields the compact frame carried are gone, and none of them is
  /// missed:
  ///
  /// `am:` — the receipt id is now derived from the packet (section 5), so
  /// nothing announces its own identifier and a relayed copy keeps the one it
  /// was born with. `ts:` is what makes that safe: without it every "OK" from
  /// the same sender would hash alike.
  ///
  /// `sd:` — the sender's LXMF address is a pure function of their public key
  /// (`RnsService._lxmfDestHexForPub`), and XPRS publishes public keys in
  /// `t:identity`. Deriving it is also the safer half: an address written on
  /// the wire by the sender is a claim, and an unsigned one lets anybody file
  /// messages into somebody else's conversation.
  ///
  /// `np:` — was already dropped; a sealed body proves the recipient better
  /// than a 66-byte token does.
  /// [body] arrives already sealed by [_seal], or plaintext when we hold no key.
  List<int>? _pack(String self, String to, String body) {
    var p = XprsPacket.parse('t:message f:$self d:$to ts:${_nowIso()} m:x');
    if (p == null) return null;
    // A sealed body is `x:`; plaintext is `m:`. `m:` must stay last either way,
    // so the sealed form drops it rather than putting `x:` after it.
    p = body.startsWith('ENC1:')
        ? XprsPacket(p.fields
            .where((f) => f.key != 'm')
            .followedBy([MapEntry('x', body.substring(5))]).toList())
        : p.with_('m', body);

    final d = _privScalar();
    if (d != null) p = xprsSign(p, d);
    if (!p.fits) return null;
    return utf8.encode(p.encode());
  }

  /// `YYYY-MM-DD_HH:MM:SS` in UTC (docs/XPRS.md section 4.8).
  static String _nowIso() {
    final t = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}_'
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// The signature covers `callsign|<everything before " ~">` — the same
  /// canonical form the chat wapp signs and the host verifier checks, so a
  /// carried copy and a directly-delivered one verify identically.
  bool _verify(String npub, String from, String core, String sigStr) {
    try {
      final pubHex = NostrCrypto.decodeNpub(npub);
      final sig = AprxSign.b85decode(sigStr);
      if (pubHex.isEmpty || sig == null || sig.length != 48) return false;
      final m = Uint8List.fromList(
          sha256.convert(utf8.encode('$from|$core')).bytes);
      return AprxSign.verify(
          m, sig, Uint8List.fromList(HEX.decode(pubHex)));
    } catch (_) {
      return false;
    }
  }

  // The signing key lives in ONE place now: xprsProfileScalar (xprs_sig.dart),
  // shared with the XPRS publisher.
  BigInt? _privScalar() => xprsProfileScalar();

  // ── inbound ───────────────────────────────────────────────────────────────

  /// Ingest an XPRS packet addressed to us.
  ///
  /// Shorter than the compact path it replaces, and not by accident: the
  /// identifier is derived rather than carried, the source address is derived
  /// from the sender's key rather than trusted off the wire, and the signature
  /// covers the packet rather than a hand-built canonical string.
  bool _ingestXprs(MeshFrame f, {required String via}) {
    final p = f.packet!;
    // Show it on the air view before deciding anything about it. `via` is the
    // transport's own word for how it arrived ('mesh' overheard, or a session);
    // anything the monitor does not recognise as a radio or local bearer is
    // dropped there rather than mislabelled here.
    XprsMonitor.instance.offer(p,
        bearer: via == 'mesh' ? 'ble' : via,
        selfCallsign: MeshService.instance.tableCallsign);
    final senderNpub = _npubForCallsign(f.from);

    // A carried packet passed through hands we do not control. When we hold the
    // sender's key a bad signature is not a glitch, it is someone else's words
    // under their callsign, and it stops here. Unsigned or unknown-key mail is
    // still delivered: most stations have never announced a key.
    if (p.has('sig') && senderNpub.isNotEmpty) {
      final pubHex = NostrCrypto.decodeNpub(senderNpub);
      final state = pubHex.isEmpty
          ? XprsSigState.unverified
          : xprsVerify(p, Uint8List.fromList(HEX.decode(pubHex)));
      if (state == XprsSigState.forged) {
        MeshCourierCounters.ingestDropped++;
        LogService.instance.add(
            'Courier: forged signature on a packet claiming to be from '
            '${f.from} — dropped');
        return false;
      }
    }

    var body = p['m'] ?? '';
    if (p.has('x')) {
      final clear = _open(senderNpub, p['x']!);
      if (clear == null) {
        MeshCourierCounters.ingestDropped++;
        LogService.instance
            .add('Courier: sealed packet from ${f.from} we cannot open');
        return false;
      }
      body = clear;
    }
    if (body.isEmpty) return false;

    // The identifier is the packet's own (section 5), so the copy that reached
    // us on air and the copy handed over in a session collapse onto one entry
    // without either of them carrying an id.
    if (!_ingested.add('id:${f.id}')) return false;
    if (_ingested.length > 512) _ingested.remove(_ingested.first);

    // No `sd:` to trust: the sender's delivery address is derived from the key
    // they published, which cannot be forged without the private half.
    final srcHex = RnsService.instance.lxmfDestForCallsign(f.from);
    if (srcHex.isEmpty) {
      // The author's key is not resolvable RIGHT NOW — which is the ordinary
      // case for carried mail: it arrives precisely because the sender is
      // away. Dropping here lost the message forever (the custodian archived
      // its copy on our ack). Hold it and retry when the sender's announce
      // returns; un-remember the id so a later custody redelivery can also
      // retry instead of collapsing into the dedup.
      _ingested.remove('id:${f.id}');
      if (_unresolved.length < 32 &&
          !_unresolved.any((u) => u.id == f.id)) {
        _unresolved.add(_UnresolvedMail(f.id, f.from, body, via));
        _pump ??= Timer.periodic(const Duration(seconds: 5), (_) => _tick());
        LogService.instance.add(
            'Courier: holding a carried packet from ${f.from} until its '
            'key is heard (${_unresolved.length} waiting)');
      }
      return false;
    }

    RnsService.instance
        .injectLxmf(sourceHex: srcHex, content: body, title: '', via: via);
    MeshCourierCounters.ingested++;
    LogService.instance
        .add('Courier: delivered a carried packet from ${f.from} (via $via)');
    return true;
  }

  /// Carried mail whose author we cannot address yet. Retried from [_tick];
  /// a day is plenty — after that the sender is not coming back soon and the
  /// content is only growing stale.
  final List<_UnresolvedMail> _unresolved = [];

  void _retryUnresolved() {
    if (_unresolved.isEmpty) return;
    final now = DateTime.now();
    _unresolved.removeWhere((u) {
      if (now.difference(u.since) > const Duration(hours: 24)) return true;
      final srcHex = RnsService.instance.lxmfDestForCallsign(u.from);
      if (srcHex.isEmpty) return false;
      _ingested.add('id:${u.id}');
      RnsService.instance
          .injectLxmf(sourceHex: srcHex, content: u.body, title: '', via: u.via);
      MeshCourierCounters.ingested++;
      LogService.instance.add(
          'Courier: delivered a held packet from ${u.from} — its key arrived');
      return true;
    });
  }

  /// A frame addressed to us arrived — overheard on air, or handed over by a
  /// custodian in an MSP session. Verify it is ours, unwrap it, and give it to
  /// the wapp through the ordinary inbox. Returns true when it was ingested.
  bool ingest(Uint8List wire, {required String via}) {
    final f = MeshFrame.parse(wire);
    if (f == null) return false;
    final self = MeshService.instance.tableCallsign.trim();
    if (self.isEmpty || f.to.toUpperCase() != self.toUpperCase()) return false;
    if (f.isXprs) return _ingestXprs(f, via: via);

    final (from, to, text) = (f.from, f.to, f.body);
    var rest = text;
    final am = _take(rest, 'am:');
    if (am != null) rest = am.rest;
    final sd = _take(rest, 'sd:');
    if (sd != null) rest = sd.rest;
    final np = _take(rest, 'np:');
    if (np != null) rest = np.rest;

    // Anyone can write our callsign on an envelope. Only mail naming our own
    // key is ours — a mislabelled copy must not surface as our conversation.
    if (np != null && np.value.isNotEmpty) {
      final mine = _selfNpub();
      if (mine.isNotEmpty && np.value != mine) {
        MeshCourierCounters.ingestDropped++;
        return false;
      }
    }

    // Trailing " ~sig" is the sender's, not part of the message.
    var body = rest;
    var sig = '';
    final tilde = body.lastIndexOf(' ~');
    if (tilde > 0) {
      sig = body.substring(tilde + 2);
      body = body.substring(0, tilde);
    }

    final senderNpub = _npubForCallsign(from);
    // A carried message passed through hands we do not control, so when we hold
    // the sender's key the signature is not decoration: a frame that fails it is
    // someone else's words under their callsign. Unsigned/unknown-key mail is
    // still delivered — most peers have never beaconed us a key — but a BAD
    // signature is a forgery and stops here.
    if (sig.isNotEmpty && senderNpub.isNotEmpty) {
      if (!_verify(senderNpub, from, rest.substring(0, tilde), sig)) {
        MeshCourierCounters.ingestDropped++;
        LogService.instance
            .add('Courier: forged signature on a message claiming to be '
                'from $from — dropped');
        return false;
      }
    }
    if (body.startsWith('ENC1:')) {
      final clear = _open(senderNpub, body.substring(5));
      if (clear == null) {
        MeshCourierCounters.ingestDropped++;
        LogService.instance
            .add('Courier: sealed message from $from we cannot open');
        return false;
      }
      body = clear;
    }
    if (body.isEmpty) return false;

    final key = am?.value.isNotEmpty == true
        ? 'am:${am!.value}'
        : 'c:${sha256.convert(utf8.encode('$from|$body'))}';
    if (!_ingested.add(key)) return false;
    if (_ingested.length > 512) _ingested.remove(_ingested.first);

    // Key the conversation by the sender's LXMF delivery address, so it lands
    // in the thread the user already has with that person rather than opening a
    // callsign-shaped one nothing can render. `sd:` is what the sender told us;
    // failing that, what our own directory knows about that callsign.
    final srcHex = (sd?.value.isNotEmpty == true)
        ? sd!.value
        : RnsService.instance.lxmfDestForCallsign(from);
    if (srcHex.isEmpty) {
      MeshCourierCounters.ingestDropped++;
      LogService.instance.add(
          'Courier: message from $from with no address to answer — dropped');
      return false;
    }

    RnsService.instance.injectLxmf(
      sourceHex: srcHex,
      content: body,
      title: '',
      via: via,
    );
    MeshCourierCounters.ingested++;
    LogService.instance
        .add('Courier: delivered a carried message from $from (via $via)');
    return true;
  }

  String _selfNpub() =>
      (ProfileService.instance.activeProfile?.npub ?? '').trim();

  String _npubForCallsign(String call) {
    final pub = RnsService.instance.pubkeyForCallsign(call);
    if (pub == null || pub.isEmpty) return '';
    try {
      return NostrCrypto.encodeNpub(pub);
    } catch (_) {
      return '';
    }
  }

  String? _open(String senderNpub, String blobB64) {
    if (senderNpub.isEmpty) return null;
    try {
      final d = _privScalar();
      final pubHex = NostrCrypto.decodeNpub(senderNpub);
      if (d == null || pubHex.isEmpty) return null;
      final pad = (4 - blobB64.length % 4) % 4;
      final blob = base64Url.decode(blobB64 + ('=' * pad));
      final pt = AprxSign.decryptFrom(
          d, Uint8List.fromList(HEX.decode(pubHex)), blob);
      if (pt == null) return null;
      return utf8.decode(pt);
    } catch (_) {
      return null;
    }
  }

  static String _short(String h) => h.length >= 8 ? h.substring(0, 8) : h;

  static _Token? _take(String s, String tag) {
    if (!s.startsWith(tag)) return null;
    final sp = s.indexOf(' ');
    if (sp < 0) return _Token(s.substring(tag.length), '');
    return _Token(s.substring(tag.length, sp), s.substring(sp + 1));
  }
}

/// One carried packet delivered to us whose author's key was unknown at the
/// time — held by [MeshCourier] and retried until the key is heard.
class _UnresolvedMail {
  final String id;
  final String from;
  final String body;
  final String via;
  final DateTime since = DateTime.now();
  _UnresolvedMail(this.id, this.from, this.body, this.via);
}

class _Token {
  _Token(this.value, this.rest);
  final String value;
  final String rest;
}
