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

import 'package:reticulum/reticulum.dart' show Ble5Bus, Ble5Subtype;

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
    // One advert, superseded by the next announce (latest presence wins).
    Ble5Bus.instance.advertiseFrame(_kRnsKey, Ble5Subtype.rns, frame,
        ttl: const Duration(seconds: 35));
  }

  @override
  bool unicast(Uint8List frame) {
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
