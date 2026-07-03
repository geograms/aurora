/*
 * mesh_custody — wires the MSP session FSM (mesh_session.dart) into the live
 * app: session lifecycle per GATT link, and the delegate that answers the
 * FSM's questions from the SCF store, the mesh table and (Stage 2) the bulk
 * spool.
 *
 * BleService owns the radios and calls in on three events only:
 *   onLinkUp / onLinkDown — a GATT link appeared/died (either role);
 *   onFrame               — bytes arrived that demuxed as MSP (0x4D 0x01).
 * Everything mesh-side happens here; ble_service_io stays transport-only.
 *
 * The existing connection model is one client link + one served central at a
 * time, so the manager holds at most two sessions (dialer + served).
 */
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../util/media_ref.dart';

import '../log_service.dart';
import 'mesh_beacon.dart';
import 'mesh_bulk_spool.dart';
import 'mesh_service.dart';
import 'mesh_session.dart';
import 'mesh_store.dart';
import 'mesh_transfer_scheduler.dart';

/// Hooks BleService injects so custody can talk back to the transport layer
/// without a circular import.
class MeshTransportHooks {
  /// Send one MSP frame on the client link (our GATT client → peer FFF1).
  Future<void> Function(Uint8List data)? clientSend;

  /// Send one MSP frame to the connected central (our server FFF2 notify).
  Future<void> Function(Uint8List data)? serverSend;

  /// Deliver a custody-carried 1:1 frame into the normal inbound path (wapps
  /// receive it exactly as if it had been heard on the broadcast plane).
  void Function(Uint8List wire)? deliverLocal;

  /// Drop the client GATT link (session over — free the radio).
  void Function()? dropClientLink;

  /// Dial [callsign] for a custody session (native GATT connect). Returns
  /// false when the peer is stale/unknown or the radio is busy.
  bool Function(String callsign)? dial;

  /// Callsigns currently dialable → ms since last seen.
  Map<String, int> Function()? dialable;
}

class MeshSessionManager {
  MeshSessionManager._();
  static final MeshSessionManager instance = MeshSessionManager._();

  final MeshTransportHooks hooks = MeshTransportHooks();

  MeshSession? _client; // we dialed out
  MeshSession? _served; // a central dialed us

  MeshSession? get clientSession => _client;
  MeshSession? get servedSession => _served;
  bool get anyActive => _client != null || _served != null;

  /// A GATT link came up. [serverSide] true when a central connected to our
  /// server (we are "served"); false when our own dial completed.
  void onLinkUp({required bool serverSide}) {
    final self =
        MeshService.instance.tableCallsign;
    if (self.isEmpty) return; // profile not ready — plain parcel traffic only
    final send = serverSide ? hooks.serverSend : hooks.clientSend;
    if (send == null) return;

    final store = MeshStore.instance;
    final session = MeshSession(
      dialer: !serverSide,
      selfCallsign: self,
      send: send,
      delegate: MeshCustodyDelegate.instance,
      maxFrame: 509,
      pendingMsgs: store.pendingCount().clamp(0, 0xFFFF),
      pendingBulk: MeshBulkSpool.instance.pendingCount().clamp(0, 255),
      log: (m) => LogService.instance.add('Mesh: $m'),
    );
    if (serverSide) {
      _served?.close(clean: false);
      _served = session;
    } else {
      _client?.close(clean: false);
      _client = session;
    }
    unawaited(session.start());
  }

  void onLinkDown({required bool serverSide}) {
    final s = serverSide ? _served : _client;
    if (serverSide) {
      _served = null;
    } else {
      _client = null;
    }
    if (!serverSide && s != null && s.peerCallsign.isNotEmpty) {
      // Feed the scheduler's backoff: a session that ended itself (BYE) or
      // had nothing outstanding is a clean visit; a mid-work drop is not.
      MeshTransferScheduler.instance.dialResult(s.peerCallsign,
          clean: s.state == MeshSessionState.closed || s.idle);
    }
    s?.close(clean: false);
  }

  /// Feed an inbound MSP frame. Returns true when consumed (caller must not
  /// pass it to the legacy parcel queue).
  bool onFrame(Uint8List data, {required bool serverSide}) {
    if (!mspIsFrame(data)) return false;
    var s = serverSide ? _served : _client;
    // A peer can start speaking MSP before our connect callback ran (server
    // side sees data first on some stacks) — bring the session up lazily.
    if (s == null) {
      onLinkUp(serverSide: serverSide);
      s = serverSide ? _served : _client;
    }
    if (s == null) return true; // MSP but no session possible: swallow
    final session = s;
    unawaited(session.onFrame(data).then((_) {
      // The session may have ended itself while handling this frame (peer's
      // BYE, all work done, error) — reap it so the link drops promptly and
      // the scheduler learns the outcome instead of waiting for idle-drop.
      if (session.state == MeshSessionState.closed) {
        _reap(session, serverSide: serverSide);
      }
    }));
    return true;
  }

  void _reap(MeshSession s, {required bool serverSide}) {
    if (serverSide) {
      if (identical(_served, s)) _served = null;
      return;
    }
    if (!identical(_client, s)) return;
    _client = null;
    hooks.dropClientLink?.call(); // free the radio for broadcast
    if (s.peerCallsign.isNotEmpty) {
      MeshTransferScheduler.instance
          .dialResult(s.peerCallsign, clean: s.closedClean);
    }
  }

  /// Politely end the dialed session (scheduler's politeness cycle).
  Future<void> byeClient() async {
    await _client?.bye(MspBye.politeness);
  }
}

/// The delegate: SCF store + mesh table behind the session FSM. Bulk is
/// stubbed until Stage 2 (offers are rejected as busy).
class MeshCustodyDelegate implements MeshSessionDelegate {
  MeshCustodyDelegate._();
  static final MeshCustodyDelegate instance = MeshCustodyDelegate._();

  void _log(String m) => LogService.instance.add('Mesh: $m');

  @override
  List<MeshPendingMsg> custodyBatchFor(String peer, int max) =>
      MeshStore.instance.pendingFor(peer, MeshService.instance.table, max: max);

  @override
  void custodyTransferred(String peer, MeshPendingMsg m) {
    MeshStore.instance.markArchived(m.key);
    _log('custody of ${m.key} -> $peer (archived)');
  }

  @override
  int msgReceived(String peer, MspMsg m) {
    if (m.wire.isEmpty) return MspMsgRej.malformed;
    final store = MeshStore.instance;
    final key = m.am.isNotEmpty ? m.am : MeshStore.contentKey(m.wire);

    // Parse the compact 0x41 frame: from \x1F to \x1F text.
    final parts = _splitWire(m.wire);
    if (parts == null) return MspMsgRej.malformed;
    final (from, to, _) = parts;

    final self = MeshService.instance.tableCallsign;
    if (to.toUpperCase() == self.toUpperCase()) {
      if (m.am.isNotEmpty && store.wasReceived(m.am)) return MspMsgRej.duplicate;
      store.recordReceivedAm(key);
      _log('custody delivery from $peer: $from -> $to');
      MeshSessionManager.instance.hooks.deliverLocal?.call(m.wire);
      return 0;
    }

    // Not for us: take custody (we owe delivery / next hop).
    final stored = store.offer(
        target: to, sender: from, wire: m.wire, am: m.am, inTransit: true);
    if (!stored) return MspMsgRej.duplicate;
    _log('took custody of $key for $to (via $peer)');
    return 0;
  }

  @override
  MspGossip gossipData() {
    final t = MeshService.instance.table;
    final entries = <MspGossipEntry>[
      if (t != null)
        for (final e in t.exportDv(maxEntries: 100))
          MspGossipEntry(e.hash, e.cost),
    ];
    return MspGossip(
        entries: entries, bloom: MeshStore.instance.buildHaveBloom());
  }

  @override
  void gossipReceived(String peer, MspGossip g) {
    final t = MeshService.instance.table;
    if (t == null) return;
    final n = t.neighbors[peer];
    if (n != null && g.entries.isNotEmpty) {
      // A gossip swap is the peer's full DV — same semantics as its beacon,
      // so reuse the beacon ingest (class/cond from the live neighbor entry).
      t.ingest(
        MeshBeacon(
          callsign: peer,
          deviceClass: n.deviceClass,
          cond: n.cond,
          dv: [for (final e in g.entries) MeshDvEntry(e.hash, e.cost)],
        ),
        rssi: n.lastRssi,
      );
      MeshService.instance.revision++;
    }
    if (g.bloom.isNotEmpty) {
      final purged = MeshStore.instance.applyPeerBloom(peer, g.bloom);
      if (purged > 0) _log('peer bloom purged $purged parked msg(s)');
    }
  }

  // --- bulk lane: backed by the disk spool -----------------------------------

  @override
  MeshBulkPending? nextBulkFor(String peer) =>
      MeshBulkSpool.instance.nextFor(peer, MeshService.instance.table);

  @override
  MeshBulkDecision bulkOffered(String peer, MspFileOffer offer) =>
      MeshBulkSpool.instance.offered(peer, offer);

  @override
  Uint8List bulkRead(Uint8List sha256, int offset, int len) =>
      MeshBulkSpool.instance.readAt(sha256, offset, len);

  @override
  bool bulkWrite(Uint8List sha256, int offset, Uint8List data) =>
      MeshBulkSpool.instance.writeAt(sha256, offset, data);

  @override
  bool bulkVerified(Uint8List sha256) => MeshBulkSpool.instance.verify(sha256);

  @override
  void bulkDone(String peer, Uint8List sha256, bool ok,
      {required bool toPeer}) {
    final spool = MeshBulkSpool.instance;
    if (!ok) {
      spool.transferEnded(sha256); // spool keeps the offset for resume
      return;
    }
    if (toPeer) {
      spool.handedOver(sha256, peer);
    } else {
      spool.completeInbound(sha256,
          selfCallsign: MeshService.instance.tableCallsign);
      MeshService.instance.revision++;
    }
  }

  @override
  void sessionClosed(String peer, {required bool clean}) {
    _log('session with ${peer.isEmpty ? "(pre-hello)" : peer} closed '
        '${clean ? "cleanly" : "abruptly"}');
  }

  /// Tap for every compact 0x41 frame crossing the broadcast plane, both
  /// directions (doc/mesh.md §6): overheard `?ACK`s purge parked copies,
  /// frames addressed to us feed the have-bloom, and 1:1 frames for OTHERS
  /// (plus our own outbound) are parked for GATT custody delivery.
  static void onAirFrame(Uint8List wire, {required bool outbound}) {
    final store = MeshStore.instance;
    if (!store.ready) return;
    final parts = _splitWire(wire);
    if (parts == null) return;
    final (from, to, text) = parts;
    if (from.isEmpty) return;

    // Overheard end-to-end receipt: `?ACK <am> d|r` — the target has it.
    if (text.startsWith('?ACK ')) {
      final am = text.length >= 11 ? text.substring(5, 11) : '';
      if (am.length == 6 && store.purgeAm(am) > 0) {
        LogService.instance.add('Mesh: ?ACK $am purged parked copy');
      }
      return;
    }
    // Only plain 1:1 traffic is custody material — no groups/control/queries.
    if (to.isEmpty || '#!?'.contains(to[0]) || text.startsWith('?')) return;

    final am = (text.startsWith('am:') && text.length >= 9)
        ? text.substring(3, 9)
        : '';
    final self = MeshService.instance.tableCallsign.toUpperCase();
    if (self.isEmpty) return;

    if (!outbound && to.toUpperCase() == self) {
      // Ours, heard on air — remember the am so our beacon bloom purges
      // custodians still carrying it.
      if (am.isNotEmpty) store.recordReceivedAm(am);
      return;
    }
    if (to.toUpperCase() == self || from.toUpperCase() == self && !outbound) {
      return;
    }
    // A 1:1 for someone else (or our own outbound): park for custody.
    if (store.offer(target: to, sender: from, wire: wire, am: am)) {
      LogService.instance.add(
          'Mesh: parked ${am.isEmpty ? "msg" : am} $from -> $to for custody');
    }
    // Chat attachment: our outbound 1:1 references media we host — queue the
    // payload for the bulk lane (the message travels custody, bytes follow).
    if (outbound && text.contains('file:')) {
      for (final ref in MediaRef.findAll(text)) {
        if (MeshBulkSpool.instance.enqueueFromArchive(ref.token, to, self)) {
          LogService.instance
              .add('Mesh: bulk queued ${ref.token} -> $to');
        }
      }
    }
  }

  /// Outgoing chat-bubble tap (the PLAINTEXT side): when a 1:1 we sent
  /// references media we host, queue the payload on the bulk lane. The wire
  /// tap cannot do this for encrypted 1:1s — the file: token is inside the
  /// ENC1 blob — but the wapp's ui.convo.msg carries the clear text.
  static void onConvoOutMessage(Map<String, dynamic> data) {
    try {
      if (data['dir'] != 'out') return;
      final id = data['id'] as String? ?? '';
      final text = data['text'] as String? ?? '';
      if (id.isEmpty || '#!?'.contains(id[0]) || !text.contains('file:')) {
        return;
      }
      final self = MeshService.instance.tableCallsign;
      if (self.isEmpty || !MeshBulkSpool.instance.ready) return;
      for (final ref in MediaRef.findAll(text)) {
        if (MeshBulkSpool.instance.enqueueFromArchive(ref.token, id, self)) {
          LogService.instance.add('Mesh: bulk queued ${ref.token} -> $id');
        }
      }
    } catch (_) {}
  }

  /// Split a compact frame `from\x1Fto\x1Ftext` (returns null when not one).
  static (String, String, String)? _splitWire(Uint8List wire) {
    final s = utf8.decode(wire, allowMalformed: true);
    final a = s.indexOf('\x1F');
    if (a <= 0) return null;
    final b = s.indexOf('\x1F', a + 1);
    if (b < 0) return null;
    return (s.substring(0, a), s.substring(a + 1, b), s.substring(b + 1));
  }
}
