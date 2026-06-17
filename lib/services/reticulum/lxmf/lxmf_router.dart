/*
 * LxmfRouter — LXMF DIRECT (over-link) delivery on the Dart Reticulum stack.
 *
 * Registers this node's LXMF "delivery" destination (Destination(identity, IN,
 * SINGLE, 'lxmf', 'delivery')). Outbound: open a Link to the recipient's delivery
 * destination and send the packed LXMessage — as a single link packet if it fits,
 * else as an RNS Resource. Inbound: accept the link, receive the packet/resource,
 * unpack + verify the message (resolving the sender's identity from the path
 * table), and hand it to [onMessage].
 *
 * Transport-agnostic like FileTransferNode: the owner supplies [send] (e.g.
 * transport.sendOnAll), [nextHopFor] (transport addressing for routed peers), and
 * [identityForDest] (resolve an identity from a destination hash, via the path
 * table). Opportunistic single-packet + propagation-node delivery are follow-ups.
 */
import 'dart:async';
import 'dart:typed_data';

import '../rns_crypto.dart';
import '../rns_identity.dart';
import '../rns_link.dart';
import '../rns_packet.dart';
import '../rns_resource.dart';
import '../rns_resource_receiver.dart';
import 'lxmf.dart';
import 'lxmf_message.dart';

// Max LXMF packed bytes we send as a single link packet (else use a Resource).
// One link DATA packet's plaintext budget is ~400B after header + token overhead.
const int _linkPacketMax = 360;

class _LxIn {
  final RnsLink link;
  RnsResourceReceiver? rx;
  _LxIn(this.link);
}

class _LxOut {
  final RnsLink link;
  final Uint8List packed;
  final Completer<bool> done;
  RnsResourceSender? sender;
  bool sent = false;
  _LxOut(this.link, this.packed, this.done);
}

class LxmfRouter {
  final RnsIdentity identity;
  final void Function(Uint8List raw) send;
  final Uint8List? Function(RnsIdentity peer)? nextHopFor;
  final RnsIdentity? Function(Uint8List destHash)? identityForDest;
  void Function(LxmfMessage message)? onMessage;
  final void Function(String msg)? log;

  late final Uint8List deliveryDestHash =
      RnsDestination.hash(identity, kLxmfApp, kLxmfDeliveryAspects);

  final Map<String, _LxIn> _in = {};
  final Map<String, _LxOut> _out = {};

  LxmfRouter({
    required this.identity,
    required this.send,
    this.nextHopFor,
    this.identityForDest,
    this.onMessage,
    this.log,
  });

  /// Feed an inbound packet; true if it was an LXMF link/delivery packet.
  Future<bool> handlePacket(RnsPacket p) async {
    if (p.packetType == RnsPacketType.linkRequest &&
        RnsCrypto.constantTimeEquals(p.destHash, deliveryDestHash)) {
      await _accept(p);
      return true;
    }
    if (p.destType == RnsDestType.link) {
      final id = _hex(p.destHash);
      final i = _in[id];
      if (i != null) {
        await _onIn(i, p);
        return true;
      }
      final o = _out[id];
      if (o != null) {
        await _onOut(o, p);
        return true;
      }
    }
    return false;
  }

  /// Send [message] to its destination over a Reticulum link. Returns true once
  /// it's been delivered to the link (packet) or proven (resource).
  Future<bool> send_(
    LxmfMessage message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final rid = identityForDest?.call(message.destinationHash);
    if (rid == null) {
      log?.call('lxmf: no path/identity for destination — cannot send');
      return false;
    }
    final link =
        await RnsLink.initiator(rid, kLxmfApp, kLxmfDeliveryAspects);
    link.nextHop = nextHopFor?.call(rid);
    final reqPkt = link.buildRequest();
    final entry = _LxOut(link, message.packed, Completer<bool>());
    final id = _hex(link.linkId!);
    _out[id] = entry;
    send(reqPkt.pack());
    final ok = await entry.done.future
        .timeout(timeout, onTimeout: () => false);
    _out.remove(id);
    return ok;
  }

  // ── Inbound (responder) ────────────────────────────────────────────────────
  Future<void> _accept(RnsPacket request) async {
    try {
      final link = await RnsLink.responder(identity, request);
      _in[_hex(link.linkId!)] = _LxIn(link);
      send((await link.buildProof()).pack());
    } catch (e) {
      log?.call('lxmf: accept link failed: $e');
    }
  }

  Future<void> _onIn(_LxIn e, RnsPacket p) async {
    if (e.link.status != RnsLinkStatus.active && p.context == RnsContext.lrrtt) {
      e.link.handleRtt(p);
      return;
    }
    switch (p.context) {
      case RnsContext.none:
        _deliver(e.link.decrypt(p)); // a single-packet message
        break;
      case RnsContext.resourceAdv:
        final rx = RnsResourceReceiver(e.link);
        e.rx = rx;
        if (rx.ingestAdvertisement(e.link.decrypt(p))) {
          send(rx.buildRequest().pack());
        }
        break;
      case RnsContext.resource:
        final rx = e.rx;
        if (rx == null) break;
        final done = rx.ingestPart(p.data);
        if (done && rx.error == null) {
          final prf = rx.proofPacket();
          if (prf != null) send(prf.pack());
          _deliver(rx.payload!);
        }
        break;
      default:
        break;
    }
  }

  Future<void> _deliver(Uint8List packed) async {
    final m = LxmfMessage.unpack(packed);
    if (m == null) {
      log?.call('lxmf: dropped undecodable message');
      return;
    }
    final src = identityForDest?.call(m.sourceHash);
    if (src == null) {
      log?.call('lxmf: message from unknown source (no announce) — dropped');
      return;
    }
    if (!await m.verify(src)) {
      log?.call('lxmf: signature verification FAILED — dropped');
      return;
    }
    log?.call('lxmf: message ${_hex(m.hash).substring(0, 8)} verified, delivering');
    onMessage?.call(m);
  }

  void _sendBody(_LxOut e) {
    if (e.packed.length <= _linkPacketMax) {
      send(e.link.encrypt(e.packed, context: RnsContext.none).pack());
      if (!e.done.isCompleted) e.done.complete(true); // packet delivery
    } else {
      try {
        final s = RnsResourceSender(e.link, e.packed)..prepare();
        e.sender = s;
        send(s.advertisementPacket().pack());
      } catch (err) {
        log?.call('lxmf: resource prepare failed: $err');
        if (!e.done.isCompleted) e.done.complete(false);
      }
    }
  }

  // ── Outbound (initiator) ───────────────────────────────────────────────────
  Future<void> _onOut(_LxOut e, RnsPacket p) async {
    if (!e.sent) {
      if (p.packetType == RnsPacketType.proof && p.context == RnsContext.lrproof) {
        final rtt = await e.link.handleProof(p);
        if (rtt == null) {
          if (!e.done.isCompleted) e.done.complete(false);
          return;
        }
        send(rtt.pack());
        e.sent = true;
        // Give the peer a moment to activate the link and install its delivery
        // callbacks before sending the message — otherwise a fast responder (a
        // real LXMF/RNS node) may receive the message packet before the link is
        // fully established and drop it.
        Future.delayed(const Duration(milliseconds: 500), () => _sendBody(e));
      }
      return;
    }
    // Resource delivery in progress.
    switch (p.context) {
      case RnsContext.resourceReq:
        final s = e.sender;
        if (s != null) {
          for (final part in s.handleRequest(e.link.decrypt(p))) {
            send(part.pack());
          }
        }
        break;
      case RnsContext.resourcePrf:
        e.sender?.validateProof(e.link.decrypt(p));
        if (!e.done.isCompleted) e.done.complete(true);
        break;
      default:
        break;
    }
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
