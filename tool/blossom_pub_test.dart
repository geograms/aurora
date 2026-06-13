// De-risk the public-Blossom path: BUD-02 authed upload of a small blob to one
// or more PUBLIC Blossom servers, then fetch it back by sha256. If this works,
// the phone (symmetric-NAT, outbound-only) can pull shared files from a public
// reachable host with no router config.
//   dart run tool/blossom_pub_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import 'package:aurora/util/nostr_crypto.dart';
import 'package:aurora/util/nostr_event.dart';

const servers = [
  'https://blossom.band',
  'https://blossom.primal.net',
  'https://nostr.download',
  'https://cdn.satellite.earth',
];

Future<void> main() async {
  final kp = NostrCrypto.generateKeyPair();
  final priv = kp.privateKeyHex;
  var pub = NostrCrypto.derivePublicKey(priv);
  if (pub.length == 66) pub = pub.substring(2); // x-only (drop 02/03 prefix)
  print('test pubkey: $pub');

  final blob = Uint8List.fromList(
      utf8.encode('aurora blossom test ${DateTime.now().toIso8601String()}'));
  final shaHex = sha256.convert(blob).toString();
  print('blob ${blob.length}B sha256=$shaHex');

  final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 600;
  final auth = NostrEvent(
    pubkey: pub,
    createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    kind: 24242,
    tags: [
      ['t', 'upload'],
      ['x', shaHex],
      ['expiration', '$exp'],
    ],
    content: 'Upload $shaHex',
  );
  auth.sign(priv);
  final authHeader =
      'Nostr ${base64.encode(utf8.encode(jsonEncode(auth.toJson())))}';

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  for (final base in servers) {
    print('\n=== $base ===');
    try {
      final put = await client.putUrl(Uri.parse('$base/upload'));
      put.headers.set('Authorization', authHeader);
      put.headers.contentType = ContentType('application', 'octet-stream');
      put.add(blob);
      final pr = await put.close().timeout(const Duration(seconds: 20));
      final body = await utf8.decoder.bind(pr).join();
      print('PUT /upload -> ${pr.statusCode}');
      if (pr.statusCode >= 400) {
        print('  body: ${body.length > 200 ? body.substring(0, 200) : body}');
        continue;
      }
      // fetch back by sha256
      final get = await client.getUrl(Uri.parse('$base/$shaHex'));
      final gr = await get.close().timeout(const Duration(seconds: 20));
      final got = <int>[];
      await for (final c in gr) {
        got.addAll(c);
      }
      final ok = gr.statusCode == 200 &&
          sha256.convert(got).toString() == shaHex;
      print('GET /$shaHex -> ${gr.statusCode} (${got.length}B) '
          '${ok ? 'HASH OK' : 'MISMATCH/!=200'}');
      if (ok) {
        print('>>> SUCCESS on $base — public Blossom round-trip works.');
      }
    } catch (e) {
      print('  error: $e');
    }
  }
  client.close();
}
