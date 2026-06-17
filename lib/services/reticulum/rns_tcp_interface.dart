/*
 * RNS TCP client interface (wire-compatible, RNS 1.3.5 — TCPClientInterface).
 *
 * Connects to a TCPServerInterface (e.g. a Python rnsd), sends RNS packets as
 * HDLC frames, and deframes inbound bytes into packets. IFAC is disabled (the
 * default for a passphrase-less TCP interface), so packets go on the wire raw,
 * HDLC-framed.
 */
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'rns_hdlc.dart';
import 'rns_transport.dart';

class RnsTcpInterface implements RnsInterface {
  final String host;
  final int port;
  @override
  final String label;
  final void Function(Uint8List packetRaw) onPacket;
  final void Function(String msg)? log;

  Socket? _socket;
  final RnsHdlcDeframer _deframer = RnsHdlcDeframer();
  bool _connected = false;

  RnsTcpInterface({
    required this.host,
    required this.port,
    required this.onPacket,
    this.log,
    String? label,
  }) : label = label ?? '$host:$port';

  bool get isConnected => _connected;

  Future<void> connect({Duration timeout = const Duration(seconds: 10)}) async {
    final s = await Socket.connect(host, port, timeout: timeout);
    s.setOption(SocketOption.tcpNoDelay, true);
    _socket = s;
    _connected = true;
    log?.call('TCP connected to $host:$port');
    s.listen(
      (data) {
        for (final frame in _deframer.feed(data)) {
          try {
            onPacket(frame);
          } catch (e) {
            log?.call('onPacket error: $e');
          }
        }
      },
      onError: (e) {
        log?.call('TCP error: $e');
        _connected = false;
      },
      onDone: () {
        log?.call('TCP closed');
        _connected = false;
      },
      cancelOnError: true,
    );
  }

  /// Send one RNS packet (raw, already-packed bytes), HDLC-framed.
  void sendPacket(Uint8List packetRaw) {
    final s = _socket;
    if (s == null || !_connected) {
      throw StateError('TCP interface not connected');
    }
    s.add(hdlcFrame(packetRaw));
  }

  /// [RnsInterface] entry point — same as [sendPacket].
  @override
  void send(Uint8List packetRaw) => sendPacket(packetRaw);

  Future<void> close() async {
    _connected = false;
    try {
      await _socket?.flush();
      await _socket?.close();
    } catch (_) {}
    _socket?.destroy();
    _socket = null;
  }
}
