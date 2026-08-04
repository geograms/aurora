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
  int _msgId = 0;
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
    await Ble5Bus.instance.startScan();
  }

  @override
  int get broadcastCap => Ble5Bus.instance.maxPayload;

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
    Ble5Bus.instance.advertiseFrame(_advertKey(frame), Ble5Subtype.rns, frame,
        ttl: const Duration(seconds: 35));
  }

  /// Advert slot for [frame]: keyed by its destination hash, so an announce for
  /// one destination never displaces another's. Falls back to the shared slot
  /// for anything too short to carry a destination.
  String _advertKey(Uint8List frame) {
    if (frame.length < 18) return _kRnsKey;
    final b = StringBuffer(_kRnsKey);
    for (var i = 2; i < 8; i++) {
      b.write(frame[i].toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
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
    final cap = broadcastCap;
    final id = _msgId = (_msgId + 1) & 0xFF;
    final parts = rnsChunkSplit(frame, cap, id);
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
          ttl: kRnsChunkTtl);
    }
    _sent++;
    return true;
  }

  @override
  void onReceive(void Function(Uint8List frame) handler) => _handler = handler;

  static const String _kRnsKey = 'rns';
}
