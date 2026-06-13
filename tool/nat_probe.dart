// NAT-type probe (RFC 5389 STUN). Sends Binding Requests to several STUN servers
// from ONE local UDP port and compares the external (mapped) port each reports.
//   same external port for all  -> endpoint-independent mapping (cone NAT)
//                                  => UDP hole-punching is feasible
//   different external ports     -> endpoint-dependent mapping (symmetric NAT)
//                                  => hole-punching will NOT work (needs a relay)
//   dart run tool/nat_probe.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

// Use STUN servers on DIFFERENT IPs so a symmetric NAT reveals itself.
const servers = [
  ['stun.l.google.com', 19302],
  ['stun1.l.google.com', 19302],
  ['stun.cloudflare.com', 3478],
];

Uint8List _bindingRequest(int seed) {
  final b = Uint8List(20);
  final d = ByteData.view(b.buffer);
  d.setUint16(0, 0x0001); // Binding Request
  d.setUint16(2, 0x0000); // length 0
  d.setUint32(4, 0x2112A442); // magic cookie
  for (var i = 0; i < 12; i++) {
    b[8 + i] = (seed * 31 + i * 7) & 0xFF; // transaction id
  }
  return b;
}

/// Parse XOR-MAPPED-ADDRESS (0x0020) or MAPPED-ADDRESS (0x0001) -> "ip:port".
String? _parseMapped(Uint8List p) {
  if (p.length < 20) return null;
  final d = ByteData.view(p.buffer, p.offsetInBytes, p.length);
  if (d.getUint16(0) != 0x0101) return null; // Binding Success
  final msgLen = d.getUint16(2);
  var off = 20;
  final end = 20 + msgLen;
  while (off + 4 <= end && off + 4 <= p.length) {
    final type = d.getUint16(off);
    final len = d.getUint16(off + 2);
    final vOff = off + 4;
    if (vOff + len > p.length) break;
    if (type == 0x0020 || type == 0x0001) {
      final family = p[vOff + 1];
      var port = d.getUint16(vOff + 2);
      if (type == 0x0020) port ^= 0x2112;
      if (family == 0x01) {
        final ip = <int>[];
        for (var i = 0; i < 4; i++) {
          var byte = p[vOff + 4 + i];
          if (type == 0x0020) byte ^= [0x21, 0x12, 0xA4, 0x42][i];
          ip.add(byte);
        }
        return '${ip.join('.')}:$port';
      }
    }
    off = vOff + len + ((4 - (len % 4)) % 4); // 4-byte aligned
  }
  return null;
}

Completer<String?>? _pending;

Future<String?> _query(RawDatagramSocket sock, String host, int port, int seed) async {
  final addrs = await InternetAddress.lookup(host, type: InternetAddressType.IPv4);
  if (addrs.isEmpty) return null;
  final target = addrs.first;
  final completer = Completer<String?>();
  _pending = completer;
  sock.send(_bindingRequest(seed), target, port);
  final res = await completer.future
      .timeout(const Duration(seconds: 4), onTimeout: () => null);
  _pending = null;
  return res == null ? null : '$res (via $host)';
}

Future<void> main(List<String> args) async {
  // Helper modes for driving the phone test from adb:
  //   dart run tool/nat_probe.dart req <file>          -> write a binding request
  //   dart run tool/nat_probe.dart parse <file>        -> print mapped addr
  //   dart run tool/nat_probe.dart resolve <host>      -> print IPv4
  if (args.length == 2 && args[0] == 'req') {
    await File(args[1]).writeAsBytes(_bindingRequest(7));
    print('wrote ${args[1]}');
    return;
  }
  if (args.length == 2 && args[0] == 'parse') {
    final p = await File(args[1]).readAsBytes();
    print(_parseMapped(Uint8List.fromList(p)) ?? 'NO_MAPPED (${p.length} bytes)');
    return;
  }
  if (args.length == 2 && args[0] == 'resolve') {
    final a = await InternetAddress.lookup(args[1], type: InternetAddressType.IPv4);
    print(a.isEmpty ? 'NONE' : a.first.address);
    return;
  }
  // ONE socket, ONE local port, reused for every server — that's what reveals
  // the mapping behaviour.
  final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  sock.listen((e) {
    if (e == RawSocketEvent.read) {
      final dg = sock.receive();
      if (dg == null) return;
      final m = _parseMapped(dg.data);
      if (m != null && !(_pending?.isCompleted ?? true)) _pending!.complete(m);
    }
  });
  print('local UDP port: ${sock.port}');
  final mapped = <String>[];
  var seed = 1;
  for (final s in servers) {
    final r = await _query(sock, s[0] as String, s[1] as int, seed++);
    print('  ${s[0]}:${s[1]} -> ${r ?? 'no response'}');
    if (r != null) mapped.add(r.split(' ').first);
  }
  sock.close();

  if (mapped.isEmpty) {
    print('>>> RESULT: no STUN responses (UDP blocked?)');
    return;
  }
  final ports = mapped.map((m) => m.split(':').last).toSet();
  final ips = mapped.map((m) => m.split(':').first).toSet();
  print('external IP(s): ${ips.join(', ')}');
  print('external port(s): ${ports.join(', ')}');
  if (ports.length == 1) {
    print('>>> RESULT: ENDPOINT-INDEPENDENT mapping (cone NAT) — '
        'UDP hole-punching is FEASIBLE.');
  } else {
    print('>>> RESULT: ENDPOINT-DEPENDENT mapping (SYMMETRIC NAT) — '
        'hole-punching will NOT work; a relay/reachable node is required.');
  }
}
