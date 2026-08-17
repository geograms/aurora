/*
 * xprs_ingest — the one funnel every heard XPRS packet passes through.
 *
 * Display, archive and command handling used to be one call each at three
 * different receive sites, which is how they drift apart. Now a receive site
 * calls [heard] and this file decides who gets the packet:
 *
 *   monitor — unchanged, with its own bearer allowlist (internet never enters
 *             the live view, and a custody session is not a sighting)
 *   archive — the persistent spool (xprs_archive.dart), when the owner has it
 *             on, which is the default
 *   history — a `t:command cmd:history d:us` is an ask, not traffic (the
 *             responder registers itself in [onCommand])
 *
 * The Reticulum lane is different on purpose ([reticulum]): radio traffic is
 * bounded by radio range, internet traffic is not, so a packet arriving over
 * a hub is archived ONLY when its author declared this station as a mailbox
 * (`t:mailbox hold:` — docs/XPRS.md section 13.12) or the packet is mail to a
 * station that did. Without that rule a well-connected hub would spool the
 * whole mesh's chatter and fill its disk with strangers (section 36.3: a
 * station pushes to the indexers its operator CHOSE).
 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:hex/hex.dart';

import '../../util/nostr_crypto.dart';
import '../log_service.dart';
import '../preferences_service.dart';
import 'xprs_archive.dart';
import 'xprs_monitor.dart';
import 'xprs_packet.dart';
import 'xprs_sig.dart';

class XprsIngest {
  XprsIngest._();

  /// Set by XprsHistoryServer so a heard command reaches the responder
  /// without this file importing it (and without the responder having to
  /// listen on three radios itself).
  static void Function(XprsPacket p,
      {required String selfBase, required String bearer})? onCommand;

  /// Set by RnsService, which owns the callsign→key map, so a `t:identity`
  /// heard on any bearer lands in the same place a key learned from an
  /// announce does. Same reasoning as [XprsArchive.keyResolver]: this file
  /// stays free of the node.
  static void Function(String callsign, String pubkeyHex)? onIdentity;

  /// Packets refused off the Reticulum lane for want of a declaration —
  /// the observable that says the admission rule is alive.
  static int refusedRns = 0;
  static int _lastRefuseLogMs = 0;

  static String _base(String c) => c.trim().toUpperCase().split('-').first;

  /// The archive's name for how a packet arrived. A custody session and the
  /// overheard mesh both run over a BLE link — physically local, so they
  /// belong in the spool even though the monitor's sighting ring (rightly)
  /// refuses 'custody' as a bearer a person watches.
  static String _archiveBearer(String bearer) =>
      (bearer == 'mesh' || bearer == 'custody') ? 'ble' : bearer;

  static bool get _archiveOn =>
      PreferencesService.instanceSync?.xprsArchive ?? true;

  /// A packet heard over the air or over a local link. The complete receive
  /// surface calls this: BLE 0x41, BLE 0x58, and the courier's session lane.
  static void heard(
    XprsPacket p, {
    required String bearer,
    required String selfCallsign,
    int rssi = 0,
  }) {
    XprsMonitor.instance
        .offer(p, bearer: bearer, selfCallsign: selfCallsign, rssi: rssi);

    // Exact-callsign skip, NOT base: our own echo is noise, but another of
    // our devices (X1SELF-2, section 3.1) is a station whose traffic — and
    // whose cmd:history asks — are as real as anyone's.
    final self = selfCallsign.trim().toUpperCase();
    final from = (p['f'] ?? '').trim().toUpperCase();
    if (from.isEmpty || from == self) return;

    // A mailbox declaration heard on the street counts exactly like one that
    // arrived over a hub: the author is saying where their mail may rest.
    if (p.type == 'mailbox') XprsArchive.instance.recordMailboxDecl(p);

    // `t:identity` (section 9.3) is a station publishing the key its callsign
    // signs with, and it is the only way to LEARN that binding off the air.
    // Without it every signature from a station we have never met stays
    // `unverified` — not because it is bad, but because nothing here could
    // check it.
    if (p.type == 'identity') _bindIdentity(from, p);

    if (_archiveOn) {
      XprsArchive.instance
          .admit(p, bearer: _archiveBearer(bearer), rssi: rssi);
    }

    try {
      onCommand?.call(p,
          selfBase: _base(selfCallsign), bearer: _archiveBearer(bearer));
    } catch (e) {
      LogService.instance.add('XPRS: command handling failed: $e');
    }
  }

  /// Identity packets verified in the current minute, and when that started.
  /// Verification is a curve operation and this runs on the receive path, so a
  /// station cannot be made to spend the afternoon checking invented callsigns.
  static int _idChecks = 0;
  static int _idWindowMs = 0;
  static const int _idChecksPerMinute = 20;

  /// Record a `k:npub…` against the callsign that signed for it.
  ///
  /// **Verified against the key it carries**, which is the whole point: a
  /// station saying "this is my key" must prove it holds that key, and it can,
  /// because the packet is signed with it. An unsigned or badly signed identity
  /// binds nothing.
  ///
  /// That still does not prove the CALLSIGN is theirs — nothing on an open
  /// bearer can — so the binding is [first-wins]: a later packet naming the
  /// same callsign with a different key is ignored. Overwriting would let
  /// anyone re-point a callsign by shouting last, and since the archive DROPS
  /// packets whose signature fails against the key it holds, that is enough to
  /// make a station's genuine traffic look forged and be thrown away.
  static void _bindIdentity(String callsign, XprsPacket p) {
    final hook = onIdentity;
    final npub = p['k'];
    if (hook == null || npub == null || !npub.startsWith('npub1')) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _idWindowMs > 60000) {
      _idWindowMs = now;
      _idChecks = 0;
    }
    if (++_idChecks > _idChecksPerMinute) return;

    try {
      final hex = NostrCrypto.decodeNpub(npub);
      if (hex.length != 64) return;
      final pub = Uint8List.fromList(HEX.decode(hex));
      if (xprsVerify(p, pub) != XprsSigState.verified) {
        LogService.instance
            .add('XPRS: identity from $callsign does not sign for its own key');
        return;
      }
      hook(callsign, hex);
    } catch (_) {
      // A malformed npub is a malformed field, and section 4 says skip it.
    }
  }

  /// One of OUR wires, at the moment it was successfully aired. Archived with
  /// `own=1` so a `cmd:history` asked of the author can replay the author —
  /// which is the whole reason a station keeps its own log (section 36.5).
  static void own(String wire, {required String bearer}) {
    if (!_archiveOn) return;
    final p = XprsPacket.parse(wire);
    if (p == null) return;
    XprsArchive.instance
        .admit(p, bearer: _archiveBearer(bearer), own: true);
  }

  /// An XPRS datagram off the Reticulum 'xprs' tag. Never shown as a sighting
  /// (the monitor's no-internet invariant is structural, and this lane does
  /// not call it), and archived only under the declaration rule above.
  static void reticulum(String from, Uint8List payload) {
    final p = XprsPacket.parse(utf8.decode(payload, allowMalformed: true));
    if (p == null) return;
    final self = _base(
        XprsArchive.instance.selfCallsign.isEmpty
            ? ''
            : XprsArchive.instance.selfCallsign);
    final fromC = _base(p['f'] ?? '');
    if (fromC.isEmpty || (self.isNotEmpty && fromC == self)) return;

    if (p.type == 'mailbox') {
      // Acting on it requires a verified signature (13.12); recordMailboxDecl
      // enforces that. A declaration naming us is itself worth keeping.
      if (XprsArchive.instance.recordMailboxDecl(p) && _archiveOn) {
        XprsArchive.instance.admit(p, bearer: 'rns');
      }
      return;
    }
    if (!_archiveOn) return;

    final toC = _base(p['d'] ?? '');
    final admitted = XprsArchive.instance.hasActiveDecl(fromC) ||
        (toC.isNotEmpty && XprsArchive.instance.hasActiveDecl(toC));
    if (!admitted) {
      refusedRns++;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastRefuseLogMs > 60000) {
        _lastRefuseLogMs = now;
        LogService.instance.add(
            'XPRS archive: rns refused (no declaration from $fromC — '
            '$refusedRns refused so far)');
      }
      return;
    }
    XprsArchive.instance.admit(p, bearer: 'rns');
  }
}
