/*
 * Native (dart:io) implementation of the Aurora remote-control HTTP API.
 * See remote_api_service.dart for the endpoint contract. Modelled on
 * geogram's LogApiService: binds InternetAddress.anyIPv4:<port>, dispatches
 * the /api/ paths, CORS-open, JSON in/out.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../platform/platform.dart' as platform;
import '../profile/profile_service.dart';
import '../profile/storage_paths.dart';
import '../wapp/wapp_page.dart';
import 'log_service.dart';

class RemoteApiService {
  RemoteApiService._();
  static final RemoteApiService instance = RemoteApiService._();

  /// Standard geogram device-API port.
  static const int defaultPort = 3456;

  HttpServer? _server;
  int _port = defaultPort;
  GlobalKey<NavigatorState>? _navigatorKey;

  bool get running => _server != null;
  int get port => _port;

  /// Start the API server (idempotent). [navigatorKey] is the app's root
  /// navigator, used to open wapps on POST /api/launch.
  Future<void> start({int? port, GlobalKey<NavigatorState>? navigatorKey}) async {
    if (navigatorKey != null) _navigatorKey = navigatorKey;
    if (port != null) _port = port;
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, _port, shared: true);
      LogService.instance.add('RemoteApi: listening on 0.0.0.0:$_port');
      _server!.listen(_handle, onError: (e) {
        LogService.instance.add('RemoteApi: request error: $e');
      });
    } catch (e) {
      _server = null;
      LogService.instance.add('RemoteApi: bind failed on $_port: $e');
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
      LogService.instance.add('RemoteApi: stopped');
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.headers.set('Access-Control-Allow-Headers', 'Content-Type');
    final path = req.uri.path;
    try {
      if (req.method == 'OPTIONS') {
        res.statusCode = HttpStatus.ok;
        await res.close();
        return;
      }
      if (req.method == 'GET' && (path == '/' || path == '/api/status')) {
        return _json(res, await _status());
      }
      if (req.method == 'GET' && (path == '/api/log' || path == '/api/logs')) {
        final n = int.tryParse(req.uri.queryParameters['n'] ?? '') ?? 200;
        return _json(res, {'lines': LogService.instance.tail(n)});
      }
      if (req.method == 'GET' && path == '/api/wapps') {
        return _json(res, {'wapps': await _listWapps()});
      }
      if (req.method == 'POST' && path == '/api/launch') {
        final body = await utf8.decoder.bind(req).join();
        Map<String, dynamic> data = {};
        if (body.trim().isNotEmpty) {
          final decoded = jsonDecode(body);
          if (decoded is Map<String, dynamic>) data = decoded;
        }
        final id = (data['wapp'] ?? data['id'] ?? data['name'] ?? '').toString();
        final ok = await _launch(id);
        return _json(res, {'ok': ok, 'wapp': id},
            status: ok ? HttpStatus.ok : HttpStatus.notFound);
      }
      return _json(res, {
        'error': 'Not found',
        'endpoints': [
          'GET /api/status',
          'GET /api/log?n=200',
          'GET /api/wapps',
          'POST /api/launch {"wapp":"<id>"}',
        ],
      }, status: HttpStatus.notFound);
    } catch (e) {
      LogService.instance.add('RemoteApi: handler error: $e');
      try {
        return _json(res, {'error': e.toString()},
            status: HttpStatus.internalServerError);
      } catch (_) {}
    }
  }

  Future<void> _json(HttpResponse res, Object data, {int status = 200}) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(const JsonEncoder.withIndent('  ').convert(data));
    await res.close();
  }

  Future<Map<String, dynamic>> _status() async {
    final p = ProfileService.instance.activeProfile;
    final wapps = await _listWapps();
    return {
      'app': 'aurora',
      'platform': platform.platformName(),
      'apiPort': _port,
      'profile': p?.nickname,
      'callsign': p?.callsign,
      'wappCount': wapps.length,
      'wapps': [for (final w in wapps) w['id']],
    };
  }

  Future<List<Map<String, String>>> _listWapps() async {
    final out = <Map<String, String>>[];
    final installed = installedAppsStorage();
    if (!await installed.directoryExists('')) return out;
    for (final e in await installed.listDirectory('')) {
      if (!e.isDirectory) continue;
      try {
        final pkg = wappPackageStorage(installed.getAbsolutePath(e.path));
        final m = await pkg.readJson('manifest.json');
        if (m == null) continue;
        out.add({
          'folder': e.name,
          'id': (m['id'] ?? '').toString(),
          'name': (m['name'] ?? e.name).toString(),
          'kind': (m['kind'] ?? 'app').toString(),
          'dir': pkg.basePath,
        });
      } catch (_) {}
    }
    return out;
  }

  /// Open a wapp by id / folder / name on the root navigator. Returns false
  /// when nothing matches or the navigator isn't available.
  Future<bool> _launch(String key) async {
    if (key.isEmpty) return false;
    final nav = _navigatorKey?.currentState;
    if (nav == null) {
      LogService.instance.add('RemoteApi: launch "$key" — no navigator');
      return false;
    }
    final wapps = await _listWapps();
    Map<String, String>? w;
    for (final x in wapps) {
      if (x['id'] == key || x['folder'] == key || x['name'] == key) {
        w = x;
        break;
      }
    }
    if (w == null) {
      LogService.instance.add('RemoteApi: launch "$key" — not found');
      return false;
    }
    final title = (w['name']?.isNotEmpty ?? false) ? w['name']! : w['folder']!;
    LogService.instance.add('RemoteApi: launching ${w['id']}');
    await nav.push(MaterialPageRoute(
      builder: (_) => WappPage(wappDir: w!['dir']!, title: title),
    ));
    return true;
  }
}
