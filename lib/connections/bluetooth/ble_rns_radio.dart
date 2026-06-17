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

import '../../services/reticulum/rns_ble_interface.dart';
import 'ble_reassembler.dart' show kBleBcastMax;
import 'ble_service.dart';

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
