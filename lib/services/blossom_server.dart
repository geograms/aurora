/*
 * Blossom-compatible media provider endpoint (Files wapp, DESIGN.md §5).
 *
 * Serves the device's shared MediaArchive over plain HTTP using the Blossom
 * (Blobs Stored Simply on Mediaservers) conventions from the NOSTR
 * ecosystem, so both other Aurora stations and stock Blossom clients can
 * fetch referenced media directly:
 *
 *   GET  /<sha256-hex>[.<ext>]   → the blob (Content-Type from the ext)
 *   HEAD /<sha256-hex>[.<ext>]   → headers only
 *   PUT  /upload                 → store a blob (off by default; the body's
 *                                  own SHA-256 is the key, so an uploader
 *                                  cannot poison a foreign hash)
 *
 * BUD-02 NOSTR authorization (kind 24242, BIP-340) is NOT verified yet —
 * uploads are guarded by an explicit user toggle instead and the auth lands
 * together with the NOSTR relay integration. Downloads need no auth (BUD-01).
 *
 * Modelled on RemoteApiService (same dart:io HttpServer shape). Default port
 * 3457 (3456 is the device API).
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import '../util/media_archive.dart';
import '../util/media_ref.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';
import 'log_service.dart';

class BlossomServer {
  BlossomServer._();
  static final BlossomServer instance = BlossomServer._();

  static const int defaultPort = 3457;

  /// GET / banner identifying an Aurora Blossom server to a LAN scanner.
  static const String _banner = '{"app":"aurora-blossom","v":1}';

  HttpServer? _server;
  int _port = defaultPort;
  MediaArchive? _archive;

  /// Accept `PUT /upload` (user opt-in; see header note on auth).
  bool uploadsEnabled = false;

  int _requests = 0;
  int _bytesServed = 0;

  bool get running => _server != null;
  int get port => _port;
  int get requests => _requests;
  int get bytesServed => _bytesServed;

  String? _lanUrl;

  /// A LAN-reachable base URL for this server (http://<lan-ip>:<port>), so a
  /// station can announce where peers may fetch its blobs. Null until started.
  /// This is only reachable from the same network / a port-forwarded host —
  /// across NAT, peers must use the BitTorrent path instead.
  String? get lanUrl => _lanUrl;

  Future<void> _resolveLanUrl() async {
    try {
      final ifaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      for (final i in ifaces) {
        for (final a in i.addresses) {
          if (!a.isLoopback && !a.isLinkLocal) {
            _lanUrl = 'http://${a.address}:$_port';
            return;
          }
        }
      }
    } catch (_) {}
  }

  /// Start serving [archive] (idempotent). Returns true when listening.
  Future<bool> start(MediaArchive archive, {int? port}) async {
    _archive = archive;
    if (port != null) _port = port;
    if (_server != null) return true;
    try {
      _server =
          await HttpServer.bind(InternetAddress.anyIPv4, _port, shared: true);
      _port = _server!.port;   // resolve an ephemeral request (port 0)
      await _resolveLanUrl();
      LogService.instance.add('Blossom: serving media on 0.0.0.0:$_port'
          '${_lanUrl == null ? '' : ' ($_lanUrl)'}');
      _server!.listen(_handle, onError: (e) {
        LogService.instance.add('Blossom: request error: $e');
      });
      return true;
    } catch (e) {
      _server = null;
      LogService.instance.add('Blossom: bind failed on $_port: $e');
      return false;
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    if (s != null) {
      await s.close(force: true);
      LogService.instance.add('Blossom: stopped');
    }
  }

  Future<void> _handle(HttpRequest req) async {
    _requests++;
    final res = req.response;
    // CORS-open, like every public Blossom server.
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Methods', 'GET, HEAD, PUT, OPTIONS');
    res.headers.set('Access-Control-Allow-Headers', '*');
    try {
      final path = req.uri.path;
      if (req.method == 'OPTIONS') {
        res.statusCode = HttpStatus.noContent;
      } else if ((req.method == 'GET' || req.method == 'HEAD') &&
          (path == '/' || path == '/id')) {
        // Discovery banner: lets a LAN scanner recognise an Aurora Blossom
        // server (GET / → this marker) without probing for a specific hash.
        res.headers.contentType = ContentType.json;
        res.statusCode = HttpStatus.ok;
        if (req.method == 'GET') res.write(_banner);
      } else if ((req.method == 'GET' || req.method == 'HEAD') &&
          _blobPath(path) != null) {
        _serveBlob(req, res, _blobPath(path)!);
      } else if (req.method == 'PUT' && path == '/upload') {
        await _upload(req, res);
      } else {
        res.statusCode = HttpStatus.notFound;
      }
    } catch (e) {
      try {
        res.statusCode = HttpStatus.internalServerError;
      } catch (_) {}
      LogService.instance.add('Blossom: $e');
    }
    try {
      await res.close();
    } catch (_) {}
  }

  /// `/<64-hex>[.<ext>]` → the hex digest, else null.
  String? _blobPath(String path) {
    final m =
        RegExp(r'^/([0-9a-fA-F]{64})(?:\.[a-z0-9]{1,18})?$').firstMatch(path);
    return m?.group(1)?.toLowerCase();
  }

  void _serveBlob(HttpRequest req, HttpResponse res, String hex) {
    final archive = _archive;
    final meta = archive?.getMeta(hex);
    if (archive == null || meta == null) {
      res.statusCode = HttpStatus.notFound;
      return;
    }
    res.headers.contentType = _mime(meta.ext);
    res.headers.set('Content-Length', meta.size.toString());
    res.statusCode = HttpStatus.ok;
    if (req.method == 'HEAD') return;
    final data = archive.get(hex);
    if (data == null) {
      res.statusCode = HttpStatus.notFound;
      return;
    }
    _bytesServed += data.length;
    archive.incrementDownloads(hex); // a GET is one download by another node
    res.add(data);
  }

  Future<void> _upload(HttpRequest req, HttpResponse res) async {
    final archive = _archive;
    if (!uploadsEnabled || archive == null) {
      res.statusCode = HttpStatus.forbidden;
      return;
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in req) {
      builder.add(chunk);
      if (builder.length > 64 * 1024 * 1024) {
        res.statusCode = HttpStatus.requestEntityTooLarge;
        return;
      }
    }
    final data = builder.takeBytes();
    if (data.isEmpty) {
      res.statusCode = HttpStatus.badRequest;
      return;
    }
    final ext = _extFromType(req.headers.contentType);
    final token = archive.putBytes(Uint8List.fromList(data), ext);
    final ref = MediaRef.parse(token)!;
    final hex = ref.sha256Hex;
    res.statusCode = HttpStatus.ok;
    res.headers.contentType = ContentType.json;
    res.write('{"url":"http://${req.headers.host ?? 'localhost'}:$_port/'
        '$hex.${ref.ext}","sha256":"$hex","size":${data.length},'
        '"type":"${_mime(ref.ext).mimeType}",'
        '"uploaded":${DateTime.now().millisecondsSinceEpoch ~/ 1000}}');
  }

  static ContentType _mime(String ext) => switch (ext) {
        'png' => ContentType('image', 'png'),
        'jpg' || 'jpeg' => ContentType('image', 'jpeg'),
        'gif' => ContentType('image', 'gif'),
        'webp' => ContentType('image', 'webp'),
        'svg' => ContentType('image', 'svg+xml'),
        'bmp' => ContentType('image', 'bmp'),
        'mp4' => ContentType('video', 'mp4'),
        'webm' => ContentType('video', 'webm'),
        'mpeg' || 'mpg' => ContentType('video', 'mpeg'),
        'mov' => ContentType('video', 'quicktime'),
        'mp3' => ContentType('audio', 'mpeg'),
        'ogg' => ContentType('audio', 'ogg'),
        'opus' => ContentType('audio', 'opus'),
        'flac' => ContentType('audio', 'flac'),
        'wav' => ContentType('audio', 'wav'),
        'pdf' => ContentType('application', 'pdf'),
        'txt' => ContentType('text', 'plain'),
        _ => ContentType('application', 'octet-stream'),
      };

  static String _extFromType(ContentType? t) => switch (t?.mimeType) {
        'image/png' => 'png',
        'image/jpeg' => 'jpg',
        'image/gif' => 'gif',
        'image/webp' => 'webp',
        'video/mp4' => 'mp4',
        'video/webm' => 'webm',
        'audio/mpeg' => 'mp3',
        'audio/ogg' => 'ogg',
        'application/pdf' => 'pdf',
        'text/plain' => 'txt',
        _ => 'bin',
      };

  /// LAN discovery: probe every host on our local /24 subnets at [port] for a
  /// `HEAD /<sha256-hex>`; the first that answers 200 is fetched into
  /// [archive] (hash-verified). This is how Blossom sharing is meant to work —
  /// scan nearby devices rather than flooding any wide-area network. Returns
  /// the wire token, or null when no LAN peer has it.
  static Future<String?> scanLan(
      String sha256Hex, String ext, MediaArchive archive,
      {int port = defaultPort,
      Duration probeTimeout = const Duration(milliseconds: 600)}) async {
    final bases = <String>[];
    try {
      final ifaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      for (final i in ifaces) {
        for (final a in i.addresses) {
          if (a.isLoopback || a.isLinkLocal) continue;
          final parts = a.address.split('.');
          if (parts.length != 4) continue;
          final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
          for (var h = 1; h < 255; h++) {
            if ('$prefix.$h' == a.address) continue; // skip self
            bases.add('http://$prefix.$h:$port');
          }
        }
      }
    } catch (_) {
      return null;
    }
    // Probe in bounded-concurrency batches; fetch from the first responder.
    const batch = 32;
    for (var i = 0; i < bases.length; i += batch) {
      final slice = bases.sublist(i, (i + batch).clamp(0, bases.length));
      final hits = await Future.wait(slice.map((base) async {
        final client = HttpClient()..connectionTimeout = probeTimeout;
        try {
          final req = await client
              .openUrl('HEAD', Uri.parse('$base/$sha256Hex'))
              .timeout(probeTimeout);
          final res = await req.close().timeout(probeTimeout);
          await res.drain<void>();
          return res.statusCode == HttpStatus.ok ? base : null;
        } catch (_) {
          return null;
        } finally {
          client.close(force: true);
        }
      }));
      for (final base in hits) {
        if (base == null) continue;
        final token = await fetchFrom(base, sha256Hex, ext, archive);
        if (token != null) {
          LogService.instance.add('Blossom: fetched $sha256Hex from LAN $base');
          return token;
        }
      }
    }
    return null;
  }

  /// Fetch a blob by hash from a remote Blossom server; verifies the digest
  /// before storing it in [archive]. Returns the wire token, or null.
  static Future<String?> fetchFrom(
      String baseUrl, String sha256Hex, String ext, MediaArchive archive,
      {Duration timeout = const Duration(seconds: 20)}) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = timeout;
      final base = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl;
      final req = await client
          .getUrl(Uri.parse('$base/$sha256Hex'))
          .timeout(timeout);
      final res = await req.close().timeout(timeout);
      if (res.statusCode != HttpStatus.ok) return null;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(timeout)) {
        builder.add(chunk);
        if (builder.length > 256 * 1024 * 1024) return null;
      }
      final data = builder.takeBytes();
      final token = archive.putBytes(Uint8List.fromList(data), ext);
      final got = MediaRef.parse(token)!;
      if (got.sha256Hex != sha256Hex.toLowerCase()) {
        // Server lied about the content — drop it again.
        archive.delete(got.sha256);
        return null;
      }
      return token;
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  // ── Public Blossom servers (internet reachable, content-addressed) ───────
  // When two stations are on different NAT'd networks, direct BitTorrent peer
  // connections are impossible (e.g. a phone behind cellular CGNAT/symmetric
  // NAT). The reachable, no-router-config path both sides reach OUTBOUND is a
  // public Blossom host: the sharer PUTs the blob (authed, BUD-02), any fetcher
  // GETs it by sha256. These were verified to accept our exact BIP-340 auth and
  // serve the blob back (blossom.band rejects by file-type; satellite needs a
  // paid plan — excluded).
  static const List<String> publicServers = [
    'https://blossom.primal.net',
    'https://nostr.download',
  ];

  static String _mimeFor(String ext) {
    switch (ext.toLowerCase()) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }

  /// Upload [data] to one public Blossom [baseUrl] using BUD-02 authorization
  /// (a kind-24242 NOSTR event signed with [privHex], BIP-340). Returns true on
  /// a 2xx response. The blob is addressed by its own SHA-256, so this cannot
  /// poison a foreign hash.
  static Future<bool> uploadTo(String baseUrl, Uint8List data, String privHex,
      {String ext = 'bin',
      Duration timeout = const Duration(seconds: 30)}) async {
    HttpClient? client;
    try {
      var pub = NostrCrypto.derivePublicKey(privHex);
      if (pub.length == 66) pub = pub.substring(2); // x-only
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
      final header =
          'Nostr ${base64.encode(utf8.encode(jsonEncode(auth.toJson())))}';
      final base = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl;
      client = HttpClient()..connectionTimeout = timeout;
      final put =
          await client.putUrl(Uri.parse('$base/upload')).timeout(timeout);
      put.headers.set('Authorization', header);
      final mime = _mimeFor(ext).split('/');
      put.headers.contentType = ContentType(mime[0], mime[1]);
      put.add(data);
      final res = await put.close().timeout(timeout);
      await res.drain();
      final ok = res.statusCode >= 200 && res.statusCode < 300;
      LogService.instance.add(
          'Blossom: upload $shaHex.$ext -> $baseUrl ${res.statusCode}');
      return ok;
    } catch (e) {
      LogService.instance.add('Blossom: upload to $baseUrl failed: $e');
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  /// Publish [data] to every public Blossom server so it is reachable over the
  /// internet by its sha256. Returns the number of servers that accepted it.
  static Future<int> publishToPublic(Uint8List data, String privHex,
      {String ext = 'bin'}) async {
    var n = 0;
    for (final base in publicServers) {
      if (await uploadTo(base, data, privHex, ext: ext)) n++;
    }
    return n;
  }

  /// Fetch [sha256Hex] from the public Blossom servers (internet tier). Returns
  /// the archived token on the first hit, or null.
  static Future<String?> fetchFromPublic(
      String sha256Hex, String ext, MediaArchive archive) async {
    for (final base in publicServers) {
      final token = await fetchFrom(base, sha256Hex, ext, archive);
      if (token != null) return token;
    }
    return null;
  }

  // ── LAN Blossom directory ────────────────────────────────────────────────
  // A cached list of reachable Aurora Blossom servers on the local network,
  // refreshed by a periodic scan (driven by the Files wapp). Media resolution
  // queries these KNOWN servers for a hash — cheap, vs scanning the whole /24
  // on every file link.
  static final Map<String, DateTime> _lanServers = {}; // baseUrl → lastSeen
  static bool _scanning = false;

  /// Base URLs of Blossom servers seen on the LAN recently (excludes stale).
  static List<String> knownServers({Duration maxAge = const Duration(minutes: 10)}) {
    final cutoff = DateTime.now().subtract(maxAge);
    return _lanServers.entries
        .where((e) => e.value.isAfter(cutoff))
        .map((e) => e.key)
        .toList(growable: false);
  }

  /// Probe the local /24(s) for Aurora Blossom servers (GET / → banner) and
  /// refresh the directory. Returns the current reachable base URLs. This is
  /// the routine LAN scan — run periodically, NOT per file link.
  static Future<List<String>> discoverLan({
    int port = defaultPort,
    Duration probeTimeout = const Duration(milliseconds: 500),
  }) async {
    if (_scanning) return knownServers(); // a scan is already in flight
    _scanning = true;
    try {
      return await _discoverLan(port, probeTimeout);
    } finally {
      _scanning = false;
    }
  }

  static Future<List<String>> _discoverLan(
      int port, Duration probeTimeout) async {
    final bases = <String>[];
    try {
      final ifaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      for (final i in ifaces) {
        for (final a in i.addresses) {
          if (a.isLoopback || a.isLinkLocal) continue;
          final parts = a.address.split('.');
          if (parts.length != 4) continue;
          final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
          for (var h = 1; h < 255; h++) {
            if ('$prefix.$h' == a.address) continue; // skip self
            bases.add('http://$prefix.$h:$port');
          }
        }
      }
    } catch (_) {
      return knownServers();
    }
    const batch = 48;
    final now = DateTime.now();
    for (var i = 0; i < bases.length; i += batch) {
      final slice = bases.sublist(i, (i + batch).clamp(0, bases.length));
      final hits = await Future.wait(slice.map((base) async {
        final client = HttpClient()..connectionTimeout = probeTimeout;
        try {
          final req =
              await client.getUrl(Uri.parse('$base/id')).timeout(probeTimeout);
          final res = await req.close().timeout(probeTimeout);
          if (res.statusCode != HttpStatus.ok) return null;
          final bytes = await res
              .fold<List<int>>(<int>[], (b, d) => b..addAll(d))
              .timeout(probeTimeout);
          return String.fromCharCodes(bytes).contains('aurora-blossom')
              ? base
              : null;
        } catch (_) {
          return null;
        } finally {
          client.close(force: true);
        }
      }));
      for (final base in hits) {
        if (base != null) _lanServers[base] = now;
      }
    }
    // Drop entries not seen in this scan that are also stale.
    _lanServers.removeWhere(
        (_, seen) => seen.isBefore(now.subtract(const Duration(minutes: 30))));
    final found = knownServers();
    LogService.instance
        .add('Blossom: LAN scan → ${found.length} server(s): ${found.join(", ")}');
    return found;
  }

  /// Try to fetch [sha256Hex] from the KNOWN LAN servers (no scan). Returns the
  /// wire token on the first hit, or null. Used as the LAN tier of media
  /// resolution, before falling back to the BitTorrent swarm.
  static Future<String?> fetchFromKnown(
      String sha256Hex, String ext, MediaArchive archive) async {
    for (final base in knownServers()) {
      final token = await fetchFrom(base, sha256Hex, ext, archive);
      if (token != null) {
        LogService.instance
            .add('Blossom: fetched $sha256Hex from known LAN $base');
        return token;
      }
    }
    return null;
  }
}
