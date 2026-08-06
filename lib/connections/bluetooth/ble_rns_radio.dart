// On-device binding of the RNS BLE interface to Aurora's shared [BleService].
//
// BleService.enqueueAdvert already does the size routing we want: payloads up to
// kBleBcastMax go out connectionless as a chunked broadcast-parcel (every device
// in range reassembles it, with NACK selective-repeat reliability), and larger
// payloads fall back to GATT point-to-point. That is exactly the broadcast-first
// model RnsBleRadio expects, so this adapter is thin.
//
// This file is the only RNS<->BLE glue that imports Flutter/BLE; the routing
// logic and broadcast semantics live in (and are tested via) the pure-Dart
// lib/services/reticulum/rns_ble_interface.dart.
import 'dart:typed_data';

import 'package:reticulum/reticulum.dart'
    show Ble5Bus, Ble5Subtype, RnsTransport;

import '../../services/log_service.dart';
import '../../services/reticulum/rns_ble_interface.dart';
import 'ble_reassembler.dart' show kBleBcastMax;
import 'ble_service.dart';
import 'rns_chunk.dart';

class BleServiceRnsRadio implements RnsBleRadio {
  /// Owner token for our adverts in BleService's per-owner rotation.
  final Object _owner = Object();
  void Function(Uint8List frame)? _handler;

  BleServiceRnsRadio() {
    BleService.instance.inbound.listen((frame) => _handler?.call(frame.data));
    // Receiving requires the scan path (it feeds [inbound]); advertising alone
    // is transmit-only. Ref-counted, so this coexists with other BLE users.
    BleService.instance.startScan();
  }

  @override
  int get broadcastCap => kBleBcastMax;

  @override
  void broadcast(Uint8List frame) =>
      BleService.instance.enqueueAdvert(_owner, frame);

  @override
  bool unicast(Uint8List frame) {
    // enqueueAdvert routes anything over the broadcast cap to GATT peers.
    BleService.instance.enqueueAdvert(_owner, frame);
    return true;
  }

  @override
  bool get hasLink => BleService.instance.gattLinkUp;

  @override
  void onReceive(void Function(Uint8List frame) handler) => _handler = handler;
}

/// The BLE 5 radio for Reticulum, with a fragmenting path for packets that do
/// not fit one extended advert.
///
/// [Ble5Radio] (in the reticulum package) is broadcast-only: its `unicast`
/// returns false, so `RnsBleInterface` had nothing to fall back to and dropped
/// every oversized packet —
/// `dropped 239B packet: exceeds broadcast cap and no point-to-point path`,
/// logged over and over on a device whose only link to the world was Bluetooth.
/// Announces are exactly the packets that go over, and an announce that never
/// leaves is a device nobody can find.
class Ble5ChunkedRnsRadio implements RnsBleRadio {
  void Function(Uint8List frame)? _handler;
  final RnsChunkAssembler _assembler = RnsChunkAssembler();
  int _sent = 0;
  int _refused = 0;

  /// Fragmented packets sent, and packets too large even for fragmenting.
  int get fragmentedSent => _sent;
  int get refused => _refused;

  Future<bool> supported() => Ble5Bus.instance.supported();

  /// Listen for whole packets (subtype rns) and fragments (subtype rnsChunk).
  Future<void> startScan() async {
    Ble5Bus.instance.onFrame(Ble5Subtype.rns, (f) => _handler?.call(f.data));
    Ble5Bus.instance.onFrame(Ble5Subtype.rnsChunk, (f) {
      final whole = _assembler.accept(f.addr, f.data);
      if (whole != null) _handler?.call(whole);
    });
    // Packets that arrive over the GATT link, not the advert channel.
    BleService.instance.onGattRnsFrame = (f) => _handler?.call(f);
    await Ble5Bus.instance.startScan();
  }

  @override
  int get broadcastCap => Ble5Bus.instance.maxPayload;

  /// A native GATT link, in either role, is up right now.
  @override
  bool get hasLink => BleService.instance.gattLinkUp;

  @override
  void broadcast(Uint8List frame) {
    if (!_allowPathRequest(frame)) return;
    // One advert slot PER DESTINATION, not one for everything.
    //
    // A single shared key meant every packet replaced the one before it within
    // milliseconds. Presence is three announces in a row — identity, LXMF
    // delivery, LXMF propagation — so only the last survived, and a peer that
    // heard us was still told "message from unknown source (no announce) —
    // dropped" when we wrote to it, because the announce that carries the
    // delivery address never made it onto the air. The rotation cycles the
    // slots, so all three go out.
    // An ANNOUNCE is presence: one slot per destination, refreshed by the next
    // announce for that destination, held long enough to be heard.
    //
    // Everything else is TRAFFIC — a link handshake is three packets in a row
    // on the same destination, and keying those by destination made each
    // replace the one before it. The peer answered a request we had already
    // overwritten, so links timed out and only the occasional message got
    // through (2 of 5 on a measured run). Traffic gets its own slot per frame
    // and a short life: it has to be heard once, soon, not held for half a
    // minute.
    final isAnnounce = frame.isNotEmpty &&
        (frame[0] & 0x03) == 0x01; // RnsPacketType.announce
    Ble5Bus.instance.advertiseFrame(
      isAnnounce ? _announceKey(frame) : 'rnst:${_frameKey(frame)}',
      Ble5Subtype.rns,
      frame,
      ttl: isAnnounce
          ? const Duration(seconds: 35)
          : const Duration(seconds: 8),
      prio: !isAnnounce,
    );
  }

  /// Advert slot for an announce: keyed by its destination hash, so an announce
  /// for one destination never displaces another's.
  String _announceKey(Uint8List frame) {
    if (frame.length < 18) return _kRnsKey;
    final b = StringBuffer(_kRnsKey);
    for (var i = 2; i < 8; i++) {
      b.write(frame[i].toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }

  /// Slot for one traffic frame — distinct per frame, so nothing it shares a
  /// destination with can overwrite it before the peer has read it.
  String _frameKey(Uint8List frame) {
    var h = 0x811c9dc5;
    for (final b in frame) {
      h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16);
  }

  // ── Path requests must not drown the channel ──────────────────────────────
  //
  // A node that has been on the internet holds hundreds of destinations, and
  // resolving them fires a path request each. On a hub uplink that is nothing;
  // on Bluetooth it is the whole medium — a phone with wifi off was airing
  // hundreds of path requests a minute through a channel that carries roughly
  // one advert at a time, leaving no room for the announces a neighbour needs
  // to learn it exists at all. Those requests are for destinations reachable
  // over the internet, which is exactly what this link is not.
  //
  // A trickle still gets through, so genuinely resolving a nearby peer works.
  static const int _pathReqPerMinute = 6;
  final List<int> _pathReqAt = [];
  int _pathReqDropped = 0;

  bool _allowPathRequest(Uint8List frame) {
    if (!RnsTransport.isPathRequest(frame)) return true;
    final now = DateTime.now().millisecondsSinceEpoch;
    _pathReqAt.removeWhere((t) => now - t > 60000);
    if (_pathReqAt.length >= _pathReqPerMinute) {
      _pathReqDropped++;
      if (_pathReqDropped == 1 || _pathReqDropped % 200 == 0) {
        LogService.instance.add(
            'RNS/ble5: throttling path requests ($_pathReqDropped held back) — '
            'the advert channel is for the peers in the room');
      }
      return false;
    }
    _pathReqAt.add(now);
    return true;
  }

  /// Path requests held back so the channel stays usable (diagnostics).
  int get pathRequestsDropped => _pathReqDropped;

  @override
  bool unicast(Uint8List frame) {
    if (!_allowPathRequest(frame)) return true; // dropped on purpose

    // An over-cap packet takes the GATT link: the documented size router
    // (docs/ble.md), and what commit 4b4e4d5 validated to a screen-off phone.
    // enqueueAdvert routes anything past this controller's advert ceiling to
    // _gattSend, which either hands it to a live link or stashes it and dials.
    //
    // The pairing dialog that made this route unusable was not the link's
    // doing at all: ble_peripheral's GATT server callback calls createBond()
    // on every unbonded device its server sees — and Android reports our own
    // client's connections to our own server callback too, so merely having
    // that plugin open bonded whichever peer we dialled. It is no longer
    // initialised on a BLE5 device (BleService._ensureBlePeripheral).
    // sendOverGatt, NOT enqueueAdvert: the size router airs its payload as an
    // APRS-subtype advert, and the peer's RNS handler only reads the rns
    // subtype — so every RNS packet sent that way was heard by nobody.
    if (BleService.instance.gattLinkUp) {
      BleService.instance.sendOverGatt(frame);
      _sent++;
      return true;
    }
    BleService.instance.sendOverGatt(frame); // queues + dials

    // No link yet — it is being dialled, and dialling takes seconds. Air the
    // packet across adverts as well rather than let it wait: RNS drops the
    // duplicate by packet hash if both copies land, and an announce that
    // arrives twice costs far less than one that never arrives.
    final id = _msgId = (_msgId + 1) & 0xFF;
    final parts = rnsChunkSplit(frame, broadcastCap, id, senderId: _senderId);
    if (parts.isEmpty) {
      _refused++;
      LogService.instance.add(
          'RNS/ble5: ${frame.length}B needs more than $kRnsChunkMaxParts '
          'fragments — not aired');
      return false;
    }
    for (var i = 0; i < parts.length; i++) {
      // Each fragment is its own advert key, so the rotation airs them all
      // rather than one superseding the next. Short TTL: the set is only
      // useful while the receiver is still assembling it.
      Ble5Bus.instance.advertiseFrame(
          'rnsc:$id:$i', Ble5Subtype.rnsChunk, parts[i],
          ttl: kRnsChunkTtl, prio: true);
    }
    _sent++;
    return true;
  }

  int _msgId = 0;

  /// Stable for this radio's lifetime, unlike the advertiser MAC which Android
  /// rotates mid-packet — see rns_chunk.dart.
  final int _senderId = DateTime.now().microsecondsSinceEpoch & 0xFF;

  @override
  void onReceive(void Function(Uint8List frame) handler) => _handler = handler;

  static const String _kRnsKey = 'rns';
}
