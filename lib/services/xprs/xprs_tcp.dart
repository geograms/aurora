/*
 * xprs_tcp — the plain-text half of the dual-protocol port.
 *
 * docs/XPRS.md section 24.4: port 4242 answers both Reticulum and XPRS on one
 * socket, told apart by the first byte. The TCP server does the telling; this
 * file is what a text connection gets. One packet per line, in and out, and
 * everything on the socket is an ordinary packet: a ping is answered with a
 * pong, a cmd:history with the section 25.2 replay served inline (no pacing —
 * the socket is the asker's own bandwidth).
 *
 * Where the peer IS decides what its packets are worth (24.4): a private or
 * loopback address is the LAN it looks like — bearer `lan`, on the air view,
 * archived like any local bearer. A public address travelled the internet, so
 * it gets exactly the Reticulum lane's treatment: no sighting, archived only
 * under the mailbox-declaration rule (36.3).
 */
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../log_service.dart';
import '../mesh/mesh_service.dart';
import 'xprs_history_server.dart';
import 'xprs_id.dart';
import 'xprs_ingest.dart';
import 'xprs_packet.dart';
import 'xprs_sig.dart';

class XprsTcp {
  XprsTcp._();

  /// Lines longer than this are not XPRS (a packet is 250 bytes); a peer
  /// sending one is talking some other protocol at the wrong port.
  static const int _maxLine = 512;
  static const int _maxBuffered = 8192;

  static int served = 0;

  /// Attach a plain-text connection: returns the sink the TCP server feeds
  /// every chunk into. Matches RnsTcpServerInterface.onPlainText.
  static void Function(Uint8List data) attach(Socket socket, String label) {
    final local = _isLocal(socket.remoteAddress);
    final buf = StringBuffer();
    LogService.instance
        .add('XPRS/tcp: $label connected (${local ? "lan" : "internet"})');

    void handleLine(String line) {
      final wire = line.trim();
      if (wire.isEmpty) return;
      final p = XprsPacket.parse(wire);
      if (p == null) return;
      final selfCall = MeshService.instance.tableCallsign.trim();
      if (selfCall.isEmpty) return;
      final selfBase = selfCall.toUpperCase().split('-').first;

      if (local) {
        // A LAN peer is a local bearer like any radio: sighting + spool.
        XprsIngest.heard(p, bearer: 'lan', selfCallsign: selfCall);
      } else {
        // The internet lane: declaration-gated, never a sighting.
        XprsIngest.reticulum(label, Uint8List.fromList(utf8.encode(wire)));
      }

      void reply(String w) {
        try {
          socket.add(utf8.encode('$w\n'));
        } catch (_) {}
      }

      // A reachability test is answered on the socket that asked (section 7's
      // vocabulary; no rssi: — a TCP byte has no signal strength to report).
      final to = (p['d'] ?? '').trim().toUpperCase().split('-').first;
      if (p.type == 'ping' && (to.isEmpty || to == selfBase)) {
        final from = (p['f'] ?? '').trim().toUpperCase();
        final now = DateTime.now().toUtc();
        String two(int n) => n.toString().padLeft(2, '0');
        var pong = XprsPacket.parse('t:pong f:$selfBase d:$from '
            'ts:${now.year}-${two(now.month)}-${two(now.day)}_'
            '${two(now.hour)}:${two(now.minute)}:${two(now.second)} '
            'r:${xprsIdentifier(p)}');
        if (pong != null) {
          final d = xprsProfileScalar();
          if (d != null) pong = xprsSign(pong, d);
          reply(pong.encode());
        }
        return;
      }

      // The whole reason this port serves text: catching up from the spool.
      final page =
          XprsHistoryServer.instance.serveInline(p, selfBase: selfBase);
      if (page.isNotEmpty) {
        served++;
        for (final w in page) {
          reply(w);
        }
        LogService.instance.add(
            'XPRS/tcp: served ${page.length - 2 < 0 ? 0 : page.length - 2} '
            'packet(s) to $label');
      }
    }

    return (Uint8List data) {
      buf.write(utf8.decode(data, allowMalformed: true));
      if (buf.length > _maxBuffered) {
        // Not line-oriented text — stop pretending it is XPRS.
        try {
          socket.destroy();
        } catch (_) {}
        return;
      }
      var s = buf.toString();
      var nl = s.indexOf('\n');
      while (nl >= 0) {
        final line = s.substring(0, nl);
        s = s.substring(nl + 1);
        if (line.length <= _maxLine) handleLine(line);
        nl = s.indexOf('\n');
      }
      buf
        ..clear()
        ..write(s);
    };
  }

  static bool _isLocal(InternetAddress a) {
    if (a.isLoopback || a.isLinkLocal) return true;
    final b = a.rawAddress;
    if (a.type == InternetAddressType.IPv4 && b.length == 4) {
      if (b[0] == 10) return true;
      if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
      if (b[0] == 192 && b[1] == 168) return true;
      return false;
    }
    // IPv6: unique-local fc00::/7 is the private range.
    return b.isNotEmpty && (b[0] & 0xFE) == 0xFC;
  }
}
