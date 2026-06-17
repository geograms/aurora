/*
 * StoreForward — LXMF store-and-forward orchestration (slice 4).
 *
 * Two halves of the same idea:
 *  - SENDER side: when a 1:1 LXMF message can't be delivered directly (recipient
 *    offline / no path), hand the packed, already-signed message to a
 *    PROPAGATION NODE — an indexer advertising RelayCap.storeForward in the
 *    RelayDirectory — which holds it (default 30-day TTL).
 *  - INDEXER side: when a recipient is seen online again (its LXMF delivery
 *    destination announces), flush the queued mail to it via the LxmfRouter and
 *    drop each message once delivered.
 *
 * The stored bytes are the original sender's signed LxmfMessage, so the eventual
 * recipient verifies the original author — the propagation node is just a relay
 * and cannot forge. Reuses RelayNode (deposit/flush + sf_inbox) and LxmfRouter
 * (the proven direct-delivery path). Owner (rns_service) drives onRecipientOnline
 * from announce ingest; here it's transport-agnostic.
 */
import '../reticulum/lxmf/lxmf_message.dart';
import '../reticulum/lxmf/lxmf_router.dart';
import '../reticulum/rns_identity.dart';
import 'relay_node.dart';
import 'relay_role.dart';

enum SendOutcome { delivered, stored, failed }

class StoreForward {
  final RelayNode node;
  final LxmfRouter router;
  final RelayDirectory directory;
  final void Function(String msg)? log;

  StoreForward({
    required this.node,
    required this.router,
    required this.directory,
    this.log,
  });

  /// Try to deliver [msg] directly; if that fails, deposit it at the best
  /// available store-and-forward indexer for pickup when the recipient returns.
  /// [recipientHint] (the recipient identity) lets us skip a hopeless direct
  /// attempt when we know there's no path — pass null to always try direct first.
  Future<SendOutcome> sendOrStore(
    LxmfMessage msg, {
    RnsIdentity? recipientHint,
    bool tryDirect = true,
  }) async {
    if (tryDirect) {
      try {
        if (await router.send_(msg)) return SendOutcome.delivered;
      } catch (e) {
        log?.call('store-forward: direct send threw: $e');
      }
    }
    final prop = _pickPropagationNode();
    if (prop == null) {
      log?.call('store-forward: no propagation node available');
      return SendOutcome.failed;
    }
    final destHex = _hex(msg.destinationHash);
    final ok = await node.deposit(prop.identity, destHex, msg.packed);
    if (ok) {
      log?.call('store-forward: queued at ${prop.idHex.substring(0, 8)}');
      return SendOutcome.stored;
    }
    return SendOutcome.failed;
  }

  /// Indexer side: a recipient is believed online — deliver its queued mail.
  /// Returns the number of messages delivered.
  Future<int> onRecipientOnline(RnsIdentity recipient) async {
    if (!node.hasMailFor(recipient)) return 0;
    final n = await node.flushFor(recipient, router);
    if (n > 0) log?.call('store-forward: delivered $n queued msg(s)');
    return n;
  }

  RelayEntry? _pickPropagationNode() {
    final candidates = directory
        .indexers()
        .where((e) => e.announcement.has(RelayCap.storeForward))
        .toList();
    if (candidates.isEmpty) return null;
    // Prefer higher capacity (lower kCap), then freshness.
    candidates.sort((a, b) {
      final d = a.announcement.capacity.compareTo(b.announcement.capacity);
      if (d != 0) return d;
      return b.lastSeenMs.compareTo(a.lastSeenMs);
    });
    return candidates.first;
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
