/*
 * I2P reseed — bootstrap the network database by downloading a signed su3
 * bundle of RouterInfos over HTTPS, parsing the su3 container, and unzipping
 * the routerInfo .dat entries. Pure Dart (dart:io + archive).
 *
 * NOTE: Phase 0 does NOT verify the su3 RSA signature. That is acceptable for a
 * feasibility test because the NTCP2 handshake cryptographically authenticates
 * each router via the static key in its RouterInfo; a tampered reseed could at
 * worst feed unusable routers. Production MUST verify the su3 signer cert.
 */
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'i2p_structures.dart';

/// Reseed servers (rotated; we try several). i2pseeds.su3 is the standard path.
const reseedUrls = [
  'https://reseed-fr.i2pd.xyz/i2pseeds.su3',
  'https://reseed.stormycloud.org/i2pseeds.su3',
  'https://reseed.diva.exchange/i2pseeds.su3',
  'https://banana.incognet.io/i2pseeds.su3',
  'https://i2pseed.creativecowpat.net:8443/i2pseeds.su3',
  'https://reseed.i2p-projekt.de/i2pseeds.su3',
  'https://reseed.onion.im/i2pseeds.su3',
];

List<RouterInfo>? _reseedCache;

/// Reseed once and cache parsed RouterInfos for reuse within a process run.
/// Dedups by router identity across the multiple sources.
Future<List<RouterInfo>> reseedRouters({void Function(String)? log}) async {
  if (_reseedCache != null) return _reseedCache!;
  final blobs = await reseed(log: log);
  final out = <RouterInfo>[];
  final seen = <String>{};
  for (final raw in blobs) {
    final ri = parseRouterInfo(raw);
    if (ri == null) continue;
    final k = ri.identityHash
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    if (seen.add(k)) out.add(ri);
  }
  log?.call('reseed: ${out.length} unique routers from ${blobs.length} blobs');
  _reseedCache = out;
  return out;
}

/// Download reseed su3 bundles from SEVERAL operators and return ALL their raw
/// RouterInfo blobs merged. Using multiple sources (not just the first that
/// answers) is essential for ROUTER DIVERSITY: a single reseed's small set makes
/// us pick the same 2-3 gateways/OBEPs every time, so when those degrade (decline
/// tunnel builds / stop forwarding) the whole node fails. Sources are shuffled so
/// we don't always lean on the same operator. Dedup happens in reseedRouters().
Future<List<Uint8List>> reseed(
    {void Function(String)? log, int wantSources = 3}) async {
  final urls = [...reseedUrls]..shuffle(Random.secure());
  final all = <Uint8List>[];
  var ok = 0;
  for (final url in urls) {
    if (ok >= wantSources) break;
    try {
      log?.call('reseed: trying $url');
      final su3 = await _download(url);
      if (su3 == null || su3.length < 64) continue;
      final content = _extractSu3Content(su3);
      if (content == null) {
        log?.call('reseed: bad su3 from $url');
        continue;
      }
      final ris = _unzipRouterInfos(content);
      if (ris.isNotEmpty) {
        log?.call('reseed: got ${ris.length} routerInfos from $url');
        all.addAll(ris);
        ok++;
      }
    } catch (e) {
      log?.call('reseed: $url failed: $e');
    }
  }
  return all;
}

Future<Uint8List?> _download(String url) async {
  // Some reseed servers reject non-wget user agents and use various certs.
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..badCertificateCallback = (cert, host, port) => true; // Phase 0 only
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.userAgentHeader, 'Wget/1.11.4');
    final res = await req.close().timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) return null;
    final b = BytesBuilder(copy: false);
    await for (final chunk in res.timeout(const Duration(seconds: 30))) {
      b.add(chunk);
    }
    return b.takeBytes();
  } finally {
    client.close(force: true);
  }
}

/// Validate the su3 magic and return the inner content (a zip), or null.
Uint8List? _extractSu3Content(Uint8List su3) {
  // Header is 40 bytes fixed, then version, signer id, content, signature.
  if (su3.length < 40) return null;
  const magic = 'I2Psu3';
  for (var i = 0; i < magic.length; i++) {
    if (su3[i] != magic.codeUnitAt(i)) return null;
  }
  int u16(int o) => (su3[o] << 8) | su3[o + 1];
  int u64(int o) {
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | su3[o + i];
    }
    return v;
  }

  final sigLen = u16(10);
  final versionLen = su3[13];
  final signerIdLen = su3[15];
  final contentLen = u64(16);
  final contentStart = 40 + versionLen + signerIdLen;
  final contentEnd = contentStart + contentLen;
  if (contentEnd + sigLen > su3.length) return null;
  return su3.sublist(contentStart, contentEnd);
}

/// Unzip the su3 content and return each routerInfo entry's bytes.
List<Uint8List> _unzipRouterInfos(Uint8List zipBytes) {
  final out = <Uint8List>[];
  final archive = ZipDecoder().decodeBytes(zipBytes);
  for (final f in archive.files) {
    if (!f.isFile) continue;
    if (!f.name.contains('routerInfo') && !f.name.endsWith('.dat')) continue;
    final data = f.content;
    if (data is List<int> && data.isNotEmpty) {
      out.add(Uint8List.fromList(data));
    }
  }
  return out;
}
