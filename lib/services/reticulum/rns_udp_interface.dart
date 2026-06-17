/*
 * RNS UDP interface (wire-compatible, RNS 1.3.5 — RNS/Interfaces/UDPInterface.py
 * and the AutoInterface data plane).
 *
 * On the wire this is the simplest possible transport: ONE raw RNS packet per
 * UDP datagram, no framing (unlike the HDLC-framed TCP/serial interfaces). It
 * listens on [listenPort] and sends to [forwardHost]:[forwardPort]. The same
 * raw-packet-per-datagram model is what AutoInterface peers use for their data
 * plane, so this doubles as the LAN data path.
 */
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'rns_transport.dart';

class RnsUdpInterface implements RnsInterface {
  @override
  final String label;
  final String listenHost;
  final int listenPort;
  final String forwardHost;
  final int forwardPort;
  final void Function(Uint8List packetRaw) onPacket;
  final void Function(String msg)? log;

  RawDatagramSocket? _socket;
  late final InternetAddress _forwardAddr;

  RnsUdpInterface({
    required this.listenPort,
    required this.forwardPort,
    required this.onPacket,
    this.listenHost = '0.0.0.0',
    this.forwardHost = '127.0.0.1',
    this.log,
    String? label,
  }) : label = label ?? 'udp:$forwardHost:$forwardPort';

  Future<void> bind() async {
    _forwardAddr = InternetAddress(forwardHost);
    final s = await RawDatagramSocket.bind(
        InternetAddress(listenHost), listenPort);
    s.broadcastEnabled = true;
    _socket = s;
    log?.call('UDP listening on $listenHost:$listenPort, '
        'forwarding to $forwardHost:$forwardPort');
    s.listen((event) {
      if (event == RawSocketEvent.read) {
        final dg = s.receive();
        if (dg == null) return;
        try {
          onPacket(Uint8List.fromList(dg.data));
        } catch (e) {
          log?.call('onPacket error: $e');
        }
      }
    });
  }

  /// Send one raw RNS packet as a single UDP datagram.
  @override
  void send(Uint8List packetRaw) {
    final s = _socket;
    if (s == null) throw StateError('UDP interface not bound');
    s.send(packetRaw, _forwardAddr, forwardPort);
  }

  Future<void> close() async {
    _socket?.close();
    _socket = null;
  }
}
