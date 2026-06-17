/*
 * RNS TCP server interface — accepts inbound TCP connections (e.g. from phones)
 * and presents each as an [RnsInterface] to the transport. Combined with the
 * transport's announce rebroadcasting, this turns the host into a TRANSPORT hub:
 * an announce arriving from one client is relayed to all the others, so several
 * devices connected to one server can all talk to each other.
 *
 * Wire-compatible with RNS TCPServerInterface: HDLC-framed RNS packets, one
 * spawned connection per client.
 */
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'rns_hdlc.dart';
import 'rns_transport.dart';

/// One accepted client connection, exposed as an interface to the transport.
class _RnsTcpServerConn implements RnsInterface {
  @override
  final String label;
  final Socket socket;
  final RnsHdlcDeframer _deframer = RnsHdlcDeframer();

  _RnsTcpServerConn(this.label, this.socket);

  @override
  void send(Uint8List packetRaw) {
    try {
      socket.add(hdlcFrame(packetRaw));
    } catch (_) {}
  }
}

class RnsTcpServerInterface {
  final int port;
  final String bindHost;
  final RnsTransport transport;
  final void Function(Uint8List packetRaw, String via) onPacket;
  final void Function(String msg)? log;

  ServerSocket? _server;
  final List<_RnsTcpServerConn> _conns = [];
  int _seq = 0;

  RnsTcpServerInterface({
    required this.port,
    required this.transport,
    required this.onPacket,
    this.bindHost = '0.0.0.0',
    this.log,
  });

  int get connectionCount => _conns.length;

  Future<void> bind() async {
    final s = await ServerSocket.bind(bindHost, port, shared: true);
    _server = s;
    log?.call('TCP server listening on $bindHost:$port');
    s.listen(_onClient, onError: (e) => log?.call('server error: $e'));
  }

  void _onClient(Socket socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    final label = 'tcps#${_seq++}:${socket.remoteAddress.address}:${socket.remotePort}';
    final conn = _RnsTcpServerConn(label, socket);
    _conns.add(conn);
    transport.addInterface(conn);
    log?.call('client connected $label (${_conns.length} total)');

    socket.listen(
      (data) {
        for (final frame in conn._deframer.feed(data)) {
          try {
            onPacket(frame, label);
          } catch (e) {
            log?.call('onPacket error: $e');
          }
        }
      },
      onError: (e) => _drop(conn),
      onDone: () => _drop(conn),
      cancelOnError: true,
    );
  }

  void _drop(_RnsTcpServerConn conn) {
    if (!_conns.remove(conn)) return;
    transport.removeInterface(conn);
    try {
      conn.socket.destroy();
    } catch (_) {}
    log?.call('client disconnected ${conn.label} (${_conns.length} left)');
  }

  Future<void> close() async {
    for (final c in List.of(_conns)) {
      _drop(c);
    }
    try {
      await _server?.close();
    } catch (_) {}
    _server = null;
  }
}
