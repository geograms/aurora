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
import 'dart:io';
import 'dart:typed_data';

import '../util/media_archive.dart';
import '../util/media_ref.dart';
import 'log_service.dart';

class BlossomServer {
  BlossomServer._();
  static final BlossomServer instance = BlossomServer._();

  static const int defaultPort = 3457;

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

  /// Start serving [archive] (idempotent). Returns true when listening.
  Future<bool> start(MediaArchive archive, {int? port}) async {
    _archive = archive;
    if (port != null) _port = port;
    if (_server != null) return true;
    try {
      _server =
          await HttpServer.bind(InternetAddress.anyIPv4, _port, shared: true);
      _port = _server!.port;   // resolve an ephemeral request (port 0)
      LogService.instance.add('Blossom: serving media on 0.0.0.0:$_port');
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
}
