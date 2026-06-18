/*
 * RelayNode — a NOSTR relay/indexer endpoint on the Dart Reticulum stack.
 *
 * Registers a 'geogram'/['relay'] destination and answers relay requests over an
 * RnsLink (responder side): EVENT publishes an event into the local
 * [RelayEventStore], REQ runs a NIP-01 filter (incl. NIP-50 search) and returns
 * the matches, COUNT returns a tally. As a client (initiator side) it can
 * publish/query/count against another relay's identity.
 *
 * Transport-agnostic like FileTransferNode / LxmfRouter: the owner supplies
 * [send] (e.g. transport.sendOnAll) and [nextHopFor] (transport addressing for
 * routed peers). Request and response each ride the link as a single encrypted
 * packet when small, else as an RNS Resource — the shared [_RelayLink] session
 * demuxes both directions by packet context (only one transfer is in flight at a
 * time in a request/response exchange, so contexts never collide).
 */
import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../reticulum/rns_crypto.dart';
import '../reticulum/rns_identity.dart';
import '../reticulum/rns_link.dart';
import '../reticulum/rns_packet.dart';
import '../reticulum/rns_resource.dart';
import '../reticulum/rns_resource_receiver.dart';
import '../reticulum/lxmf/lxmf.dart';
import '../reticulum/lxmf/lxmf_message.dart';
import '../reticulum/lxmf/lxmf_router.dart';
import '../../util/nostr_event.dart';
import 'relay_event_store.dart';
import 'relay_protocol.dart';
import 'spam.dart';

const String kRelayApp = 'geogram';
const List<String> kRelayAspects = ['relay'];

// Max relay message we send as a single link packet (else an RNS Resource).
const int _pktMax = 360;

class RelayNode {
  final RnsIdentity identity;
  final RelayEventStore store;
  final void Function(Uint8List raw) send;
  final Uint8List? Function(RnsIdentity peer)? nextHopFor;
  final void Function(String msg)? log;

  /// Optional anti-spam acceptance policy applied to inbound EVENTs (PoW / rate
  /// / size). Null = accept anything with a valid signature.
  final SpamPolicy? spam;

  /// Whether to act as a relay SERVER (accept inbound links and answer
  /// EVENT/REQ/COUNT from the network). A phone/leaf sets this false: it still
  /// queries other relays (the client API below), but never serves the network
  /// — serving the whole network's queries off the device store pegged the UI
  /// isolate (57 MB/s of sqlite reads) and ANR'd the app. Mutable so the owner
  /// can flip hosting on/off at runtime (capacity / settings switch).
  bool serve;

  /// Hosting tier classifier: maps an author pubkey (hex) to a retention tier
  /// index (0 self / 1 followed / 2 stranger). Null = treat everyone as stranger.
  int Function(String pubHex)? tierOfPub;

  /// Hosting admission gate for inbound EVENTs: returns a rejection reason, or
  /// null to accept. Null hook = accept (subject only to spam). Lets the owner
  /// enforce per-tier quotas without coupling the relay to the policy.
  String? Function(NostrEvent ev, int tier)? admitEvent;

  /// Called whenever an event is accepted via an inbound EVENT (so the owner can
  /// fan it out / re-index). Optional.
  void Function(NostrEvent event)? onEvent;

  late final Uint8List relayDestHash =
      RnsDestination.hash(identity, kRelayApp, kRelayAspects);

  final Map<String, _RelayLink> _in = {}; // responder links by link-id hex
  final Map<String, _Pending> _out = {}; // initiator requests by link-id hex
  int _subSeq = 0;

  RelayNode({
    required this.identity,
    required this.store,
    required this.send,
    this.nextHopFor,
    this.spam,
    this.onEvent,
    this.log,
    this.serve = true,
    this.tierOfPub,
    this.admitEvent,
  });

  /// Feed an inbound packet; true if it belonged to the relay.
  Future<bool> handlePacket(RnsPacket p) async {
    if (serve &&
        p.packetType == RnsPacketType.linkRequest &&
        RnsCrypto.constantTimeEquals(p.destHash, relayDestHash)) {
      await _accept(p);
      return true;
    }
    if (p.destType == RnsDestType.link) {
      final id = _hex(p.destHash);
      final i = _in[id];
      if (i != null) {
        if (i.link.status != RnsLinkStatus.active &&
            p.context == RnsContext.lrrtt) {
          i.link.handleRtt(p);
        } else {
          i.handleData(p);
        }
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

  // ── Client API ──────────────────────────────────────────────────────────

  /// Publish [e] to the relay owned by [relay]. Returns true if it was stored.
  Future<bool> publish(RnsIdentity relay, NostrEvent e,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final r = await _request(relay, RelayProtocol.event(e), timeout: timeout);
    return r != null && r.op == RelayOp.stored && r.ok;
  }

  /// Run a NIP-01 filter (set [NostrFilter.search] for NIP-50) against [relay].
  Future<List<NostrEvent>> query(RnsIdentity relay, NostrFilter filter,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final sub = 's${_subSeq++}';
    final r = await _request(relay, RelayProtocol.req(sub, filter),
        timeout: timeout);
    return r?.events ?? const [];
  }

  /// Count matches for [filter] on [relay].
  Future<int> countMatches(RnsIdentity relay, NostrFilter filter,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final sub = 's${_subSeq++}';
    final r = await _request(relay, RelayProtocol.count(sub, filter),
        timeout: timeout);
    return r?.count ?? 0;
  }

  /// Store-and-forward: deposit a packed LXMF message at propagation node
  /// [propNode] for offline recipient [recipientDeliveryDestHex]. Returns true
  /// if the node accepted it into its mailbox.
  Future<bool> deposit(
      RnsIdentity propNode, String recipientDeliveryDestHex, Uint8List packed,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final r = await _request(
        propNode, RelayProtocol.deposit(recipientDeliveryDestHex, packed),
        timeout: timeout);
    return r != null && r.op == RelayOp.stored && r.ok;
  }

  /// Indexer side: deliver any mail queued for [recipient] (now believed online)
  /// via [router]. Removes each message once delivered. Returns delivered count.
  Future<int> flushFor(RnsIdentity recipient, LxmfRouter router) async {
    final destHex =
        _hex(RnsDestination.hash(recipient, kLxmfApp, kLxmfDeliveryAspects));
    var delivered = 0;
    for (final item in store.sfPending(destHex)) {
      final msg = LxmfMessage.unpack(item.blob);
      if (msg == null) {
        store.sfDelete(item.msgId); // undecodable — drop
        continue;
      }
      if (await router.send_(msg)) {
        store.sfDelete(item.msgId);
        delivered++;
      }
    }
    return delivered;
  }

  /// Does the mailbox hold anything for this recipient's delivery dest?
  bool hasMailFor(RnsIdentity recipient) {
    final destHex =
        _hex(RnsDestination.hash(recipient, kLxmfApp, kLxmfDeliveryAspects));
    return store.sfCount(destHex) > 0;
  }

  Future<RelayFrame?> _request(RnsIdentity relay, Uint8List reqBytes,
      {required Duration timeout}) async {
    final link = await RnsLink.initiator(relay, kRelayApp, kRelayAspects);
    link.nextHop = nextHopFor?.call(relay);
    final reqPkt = link.buildRequest();
    final done = Completer<RelayFrame?>();
    final rl = _RelayLink(link, send, (msg) {
      if (!done.isCompleted) done.complete(RelayProtocol.decode(msg));
    });
    final pending = _Pending(link, rl, reqBytes, done);
    final id = _hex(link.linkId!);
    _out[id] = pending;
    send(reqPkt.pack());
    final r = await done.future.timeout(timeout, onTimeout: () => null);
    _out.remove(id);
    return r;
  }

  Future<void> _onOut(_Pending e, RnsPacket p) async {
    if (e.link.status != RnsLinkStatus.active) {
      if (p.packetType == RnsPacketType.proof &&
          p.context == RnsContext.lrproof) {
        final rtt = await e.link.handleProof(p);
        if (rtt == null) {
          if (!e.done.isCompleted) e.done.complete(null);
          return;
        }
        send(rtt.pack());
        e.rl.sendMessage(e.requestBytes); // link is active now
      }
      return;
    }
    e.rl.handleData(p);
  }

  // ── Responder side ────────────────────────────────────────────────────────

  Future<void> _accept(RnsPacket request) async {
    try {
      final link = await RnsLink.responder(identity, request);
      final rl = _RelayLink(link, send, (msg) => _serve(link, msg));
      _in[_hex(link.linkId!)] = rl;
      send((await link.buildProof()).pack());
    } catch (err) {
      log?.call('relay: accept link failed: $err');
    }
  }

  void _serve(RnsLink link, Uint8List msg) {
    final f = RelayProtocol.decode(msg);
    final rl = _in[_hex(link.linkId!)];
    if (f == null || rl == null) return;
    try {
      switch (f.op) {
        case RelayOp.event:
          final ev = f.event;
          if (ev == null) {
            rl.sendMessage(RelayProtocol.stored(false, 'no event'));
            break;
          }
          final verdict = spam?.check(ev);
          if (verdict != null && !verdict.accepted) {
            rl.sendMessage(RelayProtocol.stored(false, verdict.reason));
            break;
          }
          // Hosting tier + quota: classify the author, then run the admission
          // gate. self (0) is always admitted; strangers can be refused past
          // their monthly note / storage caps.
          final tier = tierOfPub?.call(ev.pubkey) ?? 2;
          final reject = admitEvent?.call(ev, tier);
          if (reject != null) {
            rl.sendMessage(RelayProtocol.stored(false, reject));
            break;
          }
          final ok = store.put(ev, tier: tier);
          if (ok) onEvent?.call(ev);
          rl.sendMessage(RelayProtocol.stored(ok, ok ? null : 'rejected'));
          break;
        case RelayOp.req:
          final events = store.query(f.filter!);
          rl.sendMessage(RelayProtocol.result(f.subId ?? '', events, true));
          break;
        case RelayOp.count:
          final n = store.count(f.filter);
          rl.sendMessage(RelayProtocol.countResult(f.subId ?? '', n));
          break;
        case RelayOp.deposit:
          final dest = f.dest;
          final blob = f.blob;
          var ok = false;
          if (dest != null && blob != null && blob.isNotEmpty) {
            final msgId = _hex(crypto.sha256.convert(blob).bytes);
            ok = store.sfDeposit(msgId: msgId, dest: dest, blob: blob);
            // ok==false also means "already queued" — treat as accepted.
            ok = true;
          }
          rl.sendMessage(RelayProtocol.stored(ok, ok ? null : 'rejected'));
          break;
        default:
          break;
      }
    } catch (err) {
      log?.call('relay: serve error: $err');
    }
  }

  /// Drop idle responder links (call periodically from the owner).
  void pruneLinks() => _in.clear();

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}

class _Pending {
  final RnsLink link;
  final _RelayLink rl;
  final Uint8List requestBytes;
  final Completer<RelayFrame?> done;
  _Pending(this.link, this.rl, this.requestBytes, this.done);
}

/// One full-duplex message channel over an established link. Sends one message
/// at a time (packet or Resource) and assembles one inbound message at a time;
/// in a request/response exchange the two never overlap, so inbound packets are
/// demuxed purely by context.
class _RelayLink {
  final RnsLink link;
  final void Function(Uint8List raw) send;
  final void Function(Uint8List msg) onMessage;

  RnsResourceSender? _tx; // our outbound Resource (if the message is large)
  RnsResourceReceiver? _rx; // inbound Resource being assembled

  _RelayLink(this.link, this.send, this.onMessage);

  /// Send [msg] over the link — single packet if it fits, else a Resource.
  void sendMessage(Uint8List msg) {
    if (msg.length <= _pktMax) {
      send(link.encrypt(msg, context: RnsContext.none).pack());
      return;
    }
    final s = RnsResourceSender(link, msg)..prepare();
    _tx = s;
    send(s.advertisementPacket().pack());
  }

  void handleData(RnsPacket p) {
    switch (p.context) {
      case RnsContext.resourceReq: // peer requests parts of our outbound Resource
        final tx = _tx;
        if (tx != null) {
          for (final part in tx.handleRequest(link.decrypt(p))) {
            send(part.pack());
          }
        }
        break;
      case RnsContext.resourcePrf: // peer proved receipt of our Resource
        _tx?.validateProof(link.decrypt(p));
        _tx = null;
        break;
      case RnsContext.none: // a complete single-packet message
        onMessage(link.decrypt(p));
        break;
      case RnsContext.resourceAdv: // start receiving an inbound Resource
        final rx = RnsResourceReceiver(link);
        _rx = rx;
        if (rx.ingestAdvertisement(link.decrypt(p))) {
          send(rx.buildRequest().pack());
        }
        break;
      case RnsContext.resource: // an inbound Resource part
        final rx = _rx;
        if (rx == null) break;
        final done = rx.ingestPart(p.data);
        if (done && rx.error == null) {
          final prf = rx.proofPacket();
          if (prf != null) send(prf.pack());
          _rx = null;
          onMessage(rx.payload!);
        }
        break;
      default:
        break;
    }
  }
}
