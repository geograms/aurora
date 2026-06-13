// Desktop side of the device-to-device test over PUBLIC infrastructure.
// Generates a unique blob (or uses a file you pass), uploads it to the public
// Blossom servers using the app's own BlossomServer.uploadTo (BUD-02 auth), and
// prints its sha256 so the phone can fetch it by content hash.
//   dart run tool/blossom_publish.dart [path/to/file]
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import 'package:aurora/util/nostr_crypto.dart';
import 'package:aurora/util/nostr_event.dart';

// Mirror of BlossomServer.publicServers (kept Flutter-free for `dart run`).
const publicServers = ['https://blossom.primal.net', 'https://nostr.download'];

String _b64u(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

String _mime(String ext) {
  switch (ext.toLowerCase()) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    default:
      return 'application/octet-stream';
  }
}

Future<bool> _uploadTo(String baseUrl, Uint8List data, String privHex, String ext) async {
  HttpClient? client;
  try {
    var pub = NostrCrypto.derivePublicKey(privHex);
    if (pub.length == 66) pub = pub.substring(2);
    final shaHex = sha256.convert(data).toString();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final auth = NostrEvent(
      pubkey: pub,
      createdAt: now,
      kind: 24242,
      tags: [
        ['t', 'upload'],
        ['x', shaHex],
        ['expiration', '${now + 600}'],
      ],
      content: 'Upload $shaHex',
    )..sign(privHex);
    final header = 'Nostr ${base64.encode(utf8.encode(jsonEncode(auth.toJson())))}';
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    final put = await client.putUrl(Uri.parse('$base/upload'));
    put.headers.set('Authorization', header);
    final m = _mime(ext).split('/');
    put.headers.contentType = ContentType(m[0], m[1]);
    put.add(data);
    final res = await put.close().timeout(const Duration(seconds: 30));
    await res.drain();
    return res.statusCode >= 200 && res.statusCode < 300;
  } catch (e) {
    print('  ($baseUrl error: $e)');
    return false;
  } finally {
    client?.close(force: true);
  }
}

Future<void> main(List<String> args) async {
  late Uint8List data;
  String ext;
  if (args.isNotEmpty && File(args[0]).existsSync()) {
    data = await File(args[0]).readAsBytes();
    final dot = args[0].lastIndexOf('.');
    ext = dot > 0 ? args[0].substring(dot + 1) : 'bin';
  } else {
    final b = Uint8List(48 * 1024);
    for (var i = 0; i < b.length; i++) {
      b[i] = ((i + pid) * 2654435761 >> 11) & 0xFF;
    }
    b.setAll(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]); // PNG magic
    data = b;
    ext = 'png';
  }
  final hashBytes = sha256.convert(data).bytes;
  final hex = hashBytes.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  final b64u = _b64u(hashBytes);

  final kp = NostrCrypto.generateKeyPair();
  print('uploading ${data.length}B ($hex.$ext) to public Blossom...');
  var ok = 0;
  for (final base in publicServers) {
    final r = await _uploadTo(base, data, kp.privateKeyHex, ext);
    print('  $base -> ${r ? 'OK' : 'FAIL'}');
    if (r) ok++;
  }
  print('=========================================================');
  print('PUBLISHED to $ok/${publicServers.length} public server(s)');
  print('SHA256_HEX  = $hex');
  print('SHA256_B64U = $b64u');
  print('EXT         = $ext');
  print('WIRE        = file:$b64u.$ext');
  print('=========================================================');
  exit(ok > 0 ? 0 : 1);
}
