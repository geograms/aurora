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
 * Wire (the compact 0x41 frame every custodian already parks):
 *
 *   FROM \x1F TO \x1F am:6hex [sd:32hex] [np:npub] body [~sig]
 *
 * The envelope is deliberately public — a carrier that cannot read who a
 * message is for cannot decide whom to hand it to — while the body is sealed to
 * the recipient's key whenever we hold one. `sd:` is the sender's LXMF delivery
 * address, so the receiving side can key the conversation by identity instead
 * of by callsign, and `np:` names the identity the copy is FOR, so a device
 * cannot be tricked into rendering someone else's mail as its own.
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
    if (_armed.isEmpty) {
      _pump?.cancel();
      _pump = null;
      return;
    }
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
    final wire = _pack(self, call, body, npub);
    if (wire == null) return;
    if (wire.length > maxWire) {
      MeshCourierCounters.refusedTooLong++;
      LogService.instance.add(
          'Courier: ${wire.length}B is more than a carrier can hold ($maxWire) '
          '— not aired');
      return;
    }
    // Straight down the same pipe a wapp broadcast uses, so the custody tap in
    // BleService parks our own copy exactly as it parks anyone else's.
    //
    // Aired MORE THAN ONCE, deliberately. A receiver scans in bursts, so a
    // single advert window is a lottery: a dongle two metres away parked six
    // frames from one run and none from the next. The frame stays registered
    // for five minutes and is refreshed twice inside that, which is what the
    // old wapp path did by accident (its digipeater re-aired at +75s and
    // +150s) and the only reason it looked reliable.
    final bytes = Uint8List.fromList(wire);
    void air() => ble.enqueueAdvert(this, bytes,
        ttl: const Duration(seconds: 300));
    air();
    Timer(const Duration(seconds: 90), air);
    Timer(const Duration(seconds: 180), air);
    MeshCourierCounters.aired++;
    LogService.instance.add(
        'Courier: no path to $call — ${wire.length}B handed to the mesh'
        '${npub.isEmpty ? "" : " (sealed)"} '
        '[${utf8.decode(wire, allowMalformed: true).replaceAll('\x1F', '|').substring(0, wire.length < 48 ? wire.length : 48)}]');
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

  /// Build the frame. am: goes FIRST — both custody layers (the phones'
  /// MeshCustodyDelegate and the dongle's blemesh_scf_offer) read the receipt id
  /// at the very start, and a frame without one is carried but can never be
  /// handed on inside a session.
  List<int>? _pack(String self, String to, String body, String npub) {
    final am = _amId();
    final sd = RnsService.instance.lxmfDeliveryHex ?? '';
    final sb = StringBuffer()..write('am:$am ');
    if (sd.isNotEmpty) sb.write('sd:$sd ');
    // No np: token. An npub costs 66 of the 240 bytes a carrier can hold, and
    // buys nothing a sealed body does not already prove — only the holder of
    // that key can open it. For a plaintext body the callsign on the envelope
    // is the same claim the public 1:1 lane has always made.
    sb.write(body);
    final core = sb.toString();
    final sig = _sign(self, core);
    final text = sig.isEmpty ? core : '$core ~$sig';
    return utf8.encode('$self\x1F$to\x1F$text');
  }

  String _amId() {
    final r = DateTime.now().microsecondsSinceEpoch;
    final h = sha256.convert(utf8.encode('$r')).bytes;
    return HEX.encode(h.sublist(0, 3));
  }

  /// Same canonical form the chat wapp and the host verifier already agree on:
  /// `callsign|text`, short-Schnorr over its sha256, base85.
  String _sign(String self, String core) {
    final d = _privScalar();
    if (d == null) return '';
    try {
      final m = Uint8List.fromList(
          sha256.convert(utf8.encode('$self|$core')).bytes);
      return AprxSign.b85encode(AprxSign.sign(m, d));
    } catch (_) {
      return '';
    }
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

  BigInt? _privScalar() {
    final nsec = ProfileService.instance.activeProfile?.nsec ?? '';
    if (nsec.isEmpty) return null;
    try {
      var d = BigInt.zero;
      for (final b in HEX.decode(NostrCrypto.decodeNsec(nsec))) {
        d = (d << 8) | BigInt.from(b);
      }
      return d;
    } catch (_) {
      return null;
    }
  }

  // ── inbound ───────────────────────────────────────────────────────────────

  /// A frame addressed to us arrived — overheard on air, or handed over by a
  /// custodian in an MSP session. Verify it is ours, unwrap it, and give it to
  /// the wapp through the ordinary inbox. Returns true when it was ingested.
  bool ingest(Uint8List wire, {required String via}) {
    final parts = _split(wire);
    if (parts == null) return false;
    final (from, to, text) = parts;
    final self = MeshService.instance.tableCallsign.trim();
    if (self.isEmpty || to.toUpperCase() != self.toUpperCase()) return false;

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

  static (String, String, String)? _split(Uint8List wire) {
    final s = utf8.decode(wire, allowMalformed: true);
    final a = s.indexOf('\x1F');
    if (a <= 0) return null;
    final b = s.indexOf('\x1F', a + 1);
    if (b < 0) return null;
    return (s.substring(0, a), s.substring(a + 1, b), s.substring(b + 1));
  }

  static _Token? _take(String s, String tag) {
    if (!s.startsWith(tag)) return null;
    final sp = s.indexOf(' ');
    if (sp < 0) return _Token(s.substring(tag.length), '');
    return _Token(s.substring(tag.length, sp), s.substring(sp + 1));
  }
}

class _Token {
  _Token(this.value, this.rest);
  final String value;
  final String rest;
}
