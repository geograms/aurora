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

import '../log_service.dart';
import '../preferences_service.dart';
import 'xprs_archive.dart';
import 'xprs_monitor.dart';
import 'xprs_packet.dart';

class XprsIngest {
  XprsIngest._();

  /// Set by XprsHistoryServer so a heard command reaches the responder
  /// without this file importing it (and without the responder having to
  /// listen on three radios itself).
  static void Function(XprsPacket p,
      {required String selfBase, required String bearer})? onCommand;

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
