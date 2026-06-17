/*
 * RNS over BLE — broadcast-first interface.
 *
 * A shared BLE advertising medium is, physically, a broadcast RNS interface:
 * one connectionless transmission is heard by every device in range, and RNS's
 * own addressing decides who acts on each packet. That makes group traffic
 * efficient — an announce, or a packet to a GROUP/PLAIN destination, is aired
 * ONCE and reaches all N members, instead of N separate point-to-point sends
 * (the limitation of GATT-only designs like torlando-tech/ble-reticulum).
 *
 * This interface therefore broadcasts every outgoing packet that fits the
 * connectionless cap, and falls back to a point-to-point (GATT) send only for
 * packets too large to advertise. Reassembly + selective-repeat (NACK)
 * reliability for the chunked broadcast live in the underlying radio (Aurora's
 * BleService); RNS provides confidentiality/auth on top, so the BLE transport
 * itself needs no pairing.
 *
 * The [RnsBleRadio] abstraction keeps this file free of Flutter/BLE imports so
 * the broadcast routing is unit-testable; the on-device binding to BleService
 * lives in lib/connections/bluetooth/ble_rns_radio.dart.
 */
import 'dart:typed_data';

import 'rns_transport.dart';

/// A packet radio with a connectionless broadcast medium (one transmission ->
/// all in-range receivers) and an optional point-to-point path for oversized
/// frames. Chunking/reassembly/retransmit are the radio's responsibility.
abstract class RnsBleRadio {
  /// Largest RNS packet that fits the connectionless broadcast path.
  int get broadcastCap;

  /// Air [frame] once on the broadcast medium; every device in range receives
  /// and reassembles it.
  void broadcast(Uint8List frame);

  /// Send [frame] point-to-point (e.g. GATT) when it exceeds [broadcastCap].
  /// Returns false if no point-to-point path is currently available.
  bool unicast(Uint8List frame);

  /// Register the handler for inbound (already-reassembled) frames.
  void onReceive(void Function(Uint8List frame) handler);
}

/// An [RnsInterface] that carries RNS over a broadcast-capable BLE radio.
class RnsBleInterface implements RnsInterface {
  final RnsBleRadio radio;
  @override
  final String label;
  final void Function(Uint8List packetRaw) onPacket;
  final void Function(String msg)? log;

  int _broadcasts = 0;
  int _unicasts = 0;
  int _dropped = 0;

  int get broadcastCount => _broadcasts;
  int get unicastCount => _unicasts;
  int get droppedCount => _dropped;

  RnsBleInterface({
    required this.radio,
    required this.onPacket,
    this.label = 'ble',
    this.log,
  }) {
    radio.onReceive((frame) {
      try {
        onPacket(frame);
      } catch (e) {
        log?.call('onPacket error: $e');
      }
    });
  }

  /// [RnsInterface] send: broadcast once if it fits (the efficient path for
  /// announces and group/PLAIN destinations), else fall back to point-to-point.
  @override
  void send(Uint8List packetRaw) {
    if (packetRaw.length <= radio.broadcastCap) {
      radio.broadcast(packetRaw);
      _broadcasts++;
    } else if (radio.unicast(packetRaw)) {
      _unicasts++;
    } else {
      _dropped++;
      log?.call('dropped ${packetRaw.length}B packet: '
          'exceeds broadcast cap and no point-to-point path');
    }
  }
}
