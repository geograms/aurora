/*
 * Native (dart:io) implementation of the Aurora remote-control HTTP API.
 * See remote_api_service.dart for the endpoint contract. Modelled on
 * geogram's LogApiService: binds InternetAddress.anyIPv4:<port>, dispatches
 * the /api/ paths, CORS-open, JSON in/out.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../connections/bluetooth/ble_service.dart';
import '../platform/platform.dart' as platform;
import '../profile/profile_service.dart';
import '../profile/storage_paths.dart';
import '../util/media_archive.dart';
import '../util/media_ref.dart';
import '../util/nostr_crypto.dart';
import '../wapp/geoui/widgets/media_view.dart' show sharedMediaArchive;
import '../wapp/shared_media_fetch.dart' show resolveSharedMedia;
import '../wapp/wapp_page.dart';
import 'blossom_server.dart';
import 'files/media_file_source.dart';
import 'i2p/i2p_service.dart';
import 'log_service.dart';
import 'reticulum/rns_service.dart';
import 'preferences_service.dart';
import 'torrent_service.dart';

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
      // --- headless media / BitTorrent control (drive a node with no UI) ---
      if (req.method == 'GET' && path == '/api/media/torrents') {
        return _json(res, {'torrents': TorrentService.instance.status()});
      }
      if (req.method == 'GET' && path == '/api/media/has') {
        final archive = _mediaArchive();
        final raw = req.uri.queryParameters['sha256'] ?? '';
        // archive.has() accepts a token, hex, or b64u and normalises internally.
        final has = archive != null && raw.isNotEmpty && archive.has(raw);
        return _json(res, {'sha256': raw, 'has': has});
      }
      if (req.method == 'POST' && path == '/api/media/fetch') {
        final data = await _body(req);
        final ihRaw = (data['ih'] ?? data['infohash'] ?? '').toString().toLowerCase();
        final sha256 = (data['sha256'] ?? '').toString();
        final ext = (data['ext'] ?? 'bin').toString();
        if (_mediaArchive() == null) {
          return _json(res, {'ok': false, 'error': 'storage not ready'},
              status: HttpStatus.serviceUnavailable);
        }
        if (sha256.isEmpty) {
          return _json(res, {'ok': false, 'error': 'sha256 required'},
              status: HttpStatus.badRequest);
        }
        final ih = RegExp(r'^[0-9a-f]{40}$').hasMatch(ihRaw) ? ihRaw : null;
        // Full tiered resolution: cache → LAN Blossom → public Blossom →
        // BitTorrent. Fire-and-forget (the swarm tier can run for minutes);
        // poll /api/media/has and /api/media/torrents to observe completion.
        resolveSharedMedia(sha256, ext, ih: ih).then((ok) => LogService.instance
            .add('RemoteApi: media resolve $sha256 -> ${ok ? 'ok' : 'failed'}'));
        return _json(res, {'ok': true, 'started': true, 'sha256': sha256, 'ih': ih});
      }
      if (req.method == 'POST' && path == '/api/media/publish') {
        final data = await _body(req);
        final token = (data['token'] ?? '').toString();
        final archive = _mediaArchive();
        if (archive == null) {
          return _json(res, {'ok': false, 'error': 'storage not ready'},
              status: HttpStatus.serviceUnavailable);
        }
        final ref = MediaRef.parse(token);
        if (ref == null) {
          return _json(res, {'ok': false, 'error': 'bad token'},
              status: HttpStatus.badRequest);
        }
        final bytes = archive.get(ref.sha256);
        if (bytes == null) {
          return _json(res, {'ok': false, 'error': 'not in archive'},
              status: HttpStatus.notFound);
        }
        final profile = ProfileService.instance.activeProfile;
        if (profile == null) {
          return _json(res, {'ok': false, 'error': 'no profile'},
              status: HttpStatus.serviceUnavailable);
        }
        String privHex;
        try {
          privHex = NostrCrypto.decodeNsec(profile.nsec);
        } catch (_) {
          return _json(res, {'ok': false, 'error': 'bad key'},
              status: HttpStatus.internalServerError);
        }
        final n =
            await BlossomServer.publishToPublic(bytes, privHex, ext: ref.ext);
        return _json(res, {'ok': n > 0, 'token': token, 'servers': n});
      }
      if (req.method == 'POST' && path == '/api/media/seed') {
        final data = await _body(req);
        final token = (data['token'] ?? '').toString();
        if (_mediaArchive() == null) {
          return _json(res, {'ok': false, 'error': 'storage not ready'},
              status: HttpStatus.serviceUnavailable);
        }
        final ih = await TorrentService.instance.seed(token);
        return _json(res, {'ok': ih != null, 'token': token, 'ih': ih},
            status: ih != null ? HttpStatus.ok : HttpStatus.badRequest);
      }
      // --- headless I2P control (pure-Dart node; drive desktop<->phone) ---
      if (req.method == 'GET' && path == '/api/i2p/status') {
        final s = I2pService.instance;
        return _json(res, {'up': s.isUp, 'starting': s.isStarting, 'b32': s.b32});
      }
      if (req.method == 'POST' && path == '/api/i2p/start') {
        // Reseed + tunnel build can take a while; start in the background and
        // poll GET /api/i2p/status for {up:true, b32}.
        I2pService.instance.ensureStarted();
        return _json(res, {'started': true});
      }
      if (req.method == 'POST' && path == '/api/i2p/put') {
        final data = await _body(req);
        final archive = _mediaArchive();
        if (archive == null) {
          return _json(res, {'ok': false, 'error': 'storage not ready'},
              status: HttpStatus.serviceUnavailable);
        }
        final bytes = base64.decode((data['data'] ?? '').toString());
        final ext = (data['ext'] ?? 'bin').toString();
        final token = archive.putBytes(bytes, ext);
        final ref = MediaRef.parse(token);
        return _json(res, {
          'ok': true,
          'token': token,
          'sha256': ref?.sha256,
          'sha256hex': ref?.sha256Hex,
          'len': bytes.length,
        });
      }
      if (req.method == 'POST' && path == '/api/i2p/fetch') {
        final data = await _body(req);
        final b32 = (data['b32'] ?? '').toString();
        final ext = (data['ext'] ?? 'bin').toString();
        final sha = _shaBytes((data['sha256'] ?? '').toString());
        if (!I2pService.instance.isUp) {
          return _json(res, {'ok': false, 'error': 'i2p not up'},
              status: HttpStatus.serviceUnavailable);
        }
        if (b32.isEmpty || sha == null) {
          return _json(res, {'ok': false, 'error': 'b32 and sha256 required'},
              status: HttpStatus.badRequest);
        }
        final ok = await I2pService.instance.fetchByB32(b32, sha, ext);
        return _json(res, {'ok': ok});
      }
      if (req.method == 'POST' && path == '/api/i2p/peer') {
        // Register a peer's callsign -> b32 (roster for content discovery).
        final data = await _body(req);
        final cs = (data['callsign'] ?? '').toString();
        final b32 = (data['b32'] ?? '').toString();
        if (cs.isEmpty || b32.isEmpty) {
          return _json(res, {'ok': false, 'error': 'callsign and b32 required'},
              status: HttpStatus.badRequest);
        }
        I2pService.instance.registerB32(cs, b32);
        return _json(res, {'ok': true});
      }
      if (req.method == 'POST' && path == '/api/i2p/announce') {
        final sha = _shaBytes((await _body(req))['sha256']?.toString() ?? '');
        if (!I2pService.instance.isUp || sha == null) {
          return _json(res, {'ok': false, 'error': 'i2p not up / bad sha256'},
              status: HttpStatus.serviceUnavailable);
        }
        await I2pService.instance.announce(sha);
        return _json(res, {'ok': true});
      }
      if (req.method == 'POST' && path == '/api/i2p/discover') {
        // Find any provider of this sha256 across the network and archive it.
        final data = await _body(req);
        final sha = _shaBytes((data['sha256'] ?? '').toString());
        final ext = (data['ext'] ?? 'bin').toString();
        if (!I2pService.instance.isUp || sha == null) {
          return _json(res, {'ok': false, 'error': 'i2p not up / bad sha256'},
              status: HttpStatus.serviceUnavailable);
        }
        final ok = await I2pService.instance.discover(sha, ext);
        return _json(res, {'ok': ok});
      }

      // ── Reticulum (RNS) device-to-device validation ──
      if (req.method == 'GET' && path == '/api/rns/status') {
        return _json(res, RnsService.instance.status());
      }
      if (req.method == 'POST' && path == '/api/rns/start') {
        // {"mode":"tcpserver"|"tcpclient"|"ble","host":"127.0.0.1","port":4242}
        final data = await _body(req);
        final mode = (data['mode'] ?? 'tcpclient').toString();
        final host = (data['host'] ?? '127.0.0.1').toString();
        final port = int.tryParse('${data['port'] ?? 4242}') ?? 4242;
        // Announce our callsign so peers/repeaters can show a human name (the
        // announce app_data is plaintext; this is a public presence beacon).
        final cs = (ProfileService.instance.activeProfile?.callsign ?? '').trim();
        final name = cs.isNotEmpty ? cs : 'aurora';
        // Serve content we already hold (received media, imports) over RNS.
        final arch = _mediaArchive();
        if (arch != null) {
          RnsService.instance.fileServeSource = MediaFileSource(arch);
        }
        // Persist the social relay/index DB + folder key-store under the shared
        // wapp-data root.
        final prefs = PreferencesService.instanceSync;
        if (prefs != null) {
          RnsService.instance.relayStorePath =
              wappsDataStorage(prefs).getAbsolutePath('social.sqlite3');
          RnsService.instance.folderStorePath =
              wappsDataStorage(prefs).getAbsolutePath('folders.json');
          RnsService.instance.diskFoldersPath =
              wappsDataStorage(prefs).getAbsolutePath('disk_folders.json');
          RnsService.instance.subscriptionsPath =
              wappsDataStorage(prefs).getAbsolutePath('folder_subscriptions.json');
          RnsService.instance.serveStatsPath =
              wappsDataStorage(prefs).getAbsolutePath('serve_stats.sqlite3');
          RnsService.instance.identityPath =
              wappsDataStorage(prefs).getAbsolutePath('rns_identity.key');
        }
        final ok = await RnsService.instance
            .start(mode: mode, host: host, port: port, announceName: name);
        return _json(res, {'started': ok, ...RnsService.instance.status()});
      }
      if (req.method == 'POST' && path == '/api/rns/announce') {
        // {"text":"hello"} — one-to-many announce of our chat destination.
        final data = await _body(req);
        final text = (data['text'] ?? '').toString();
        if (!RnsService.instance.isUp) {
          return _json(res, {'ok': false, 'error': 'rns not up'},
              status: HttpStatus.serviceUnavailable);
        }
        await RnsService.instance.announce(text);
        return _json(res, {'ok': true});
      }
      if (req.method == 'GET' && path == '/api/rns/inbox') {
        return _json(res, {'inbox': RnsService.instance.inbox});
      }
      if (req.method == 'POST' && path == '/api/rns/get') {
        // {"sha256":"<hex|b64u>","ext":"png"} — DISCOVER providers via the DHT,
        // fetch the bytes from the best one, cache them, and auto-seed (publish
        // our own provider record). No peer needed; the DHT is the index.
        final data = await _body(req);
        final shaB = _shaBytes('${data['sha256'] ?? ''}');
        final ext = '${data['ext'] ?? 'bin'}';
        if (shaB == null) {
          return _json(res, {'ok': false, 'error': 'sha256 required'},
              status: HttpStatus.badRequest);
        }
        // Optional "from" callsign → fetch DIRECTLY from that known sender first
        // (reliable cross-network), falling back to DHT discovery.
        final from = '${data['from'] ?? ''}'.trim();
        Uint8List? bytes;
        if (from.isNotEmpty) {
          bytes = await RnsService.instance.fetchFileFromCallsign(shaB, from);
        }
        bytes ??= await RnsService.instance.dhtResolveFetch(shaB);
        if (bytes == null) {
          return _json(res, {'ok': false, 'error': 'not found'});
        }
        String? token;
        final arch = _mediaArchive();
        if (arch != null) token = arch.putBytes(bytes, ext);
        final holders = await RnsService.instance.dhtPublish(shaB); // auto-seed
        return _json(res,
            {'ok': true, 'len': bytes.length, 'token': token, 'seeded': holders});
      }
      if (req.method == 'POST' && path == '/api/rns/seed') {
        // {"sha256":"<hex|b64u>"} — publish a provider record for content we hold,
        // so peers can discover us as a source.
        final data = await _body(req);
        final shaB = _shaBytes('${data['sha256'] ?? ''}');
        if (shaB == null) {
          return _json(res, {'ok': false, 'error': 'sha256 required'},
              status: HttpStatus.badRequest);
        }
        final holders = await RnsService.instance.dhtPublish(shaB);
        return _json(res, {'ok': true, 'seeded': holders});
      }
      if (req.method == 'POST' && path == '/api/rns/fetchfile') {
        // {"sha256":"<hex|b64u>","peer":"<peer dest hex>","ext":"png"} — fetch a
        // file by content hash from a known peer over a Reticulum link; on success
        // cache it in MediaArchive (so we can then serve it too).
        final data = await _body(req);
        final shaB = _shaBytes('${data['sha256'] ?? ''}');
        final peer = '${data['peer'] ?? ''}'.trim();
        final ext = '${data['ext'] ?? 'bin'}';
        if (shaB == null || peer.isEmpty) {
          return _json(res, {'ok': false, 'error': 'sha256 + peer required'},
              status: HttpStatus.badRequest);
        }
        final bytes = await RnsService.instance.fetchFileFrom(shaB, peer);
        if (bytes == null) {
          return _json(res, {'ok': false, 'error': 'fetch failed'});
        }
        String? token;
        final arch = _mediaArchive();
        if (arch != null) token = arch.putBytes(bytes, ext);
        return _json(res, {'ok': true, 'len': bytes.length, 'token': token});
      }
      if (req.method == 'POST' && path == '/api/rns/relay/publish') {
        // {"event": {NIP-01 signed event json}} — store locally + fan out to an
        // indexer. The event must already be Schnorr-signed by the caller.
        final data = await _body(req);
        final ev = data['event'];
        if (ev is! Map) {
          return _json(res, {'ok': false, 'error': 'event object required'},
              status: HttpStatus.badRequest);
        }
        final ok = await RnsService.instance
            .relayPublish(Map<String, dynamic>.from(ev));
        return _json(res, {'ok': ok});
      }
      if (req.method == 'POST' && path == '/api/rns/relay/search') {
        // {"q":"text","kinds":[1],"limit":50,"topic":"reticulum"}
        final data = await _body(req);
        final q = '${data['q'] ?? ''}';
        final kinds = (data['kinds'] as List?)?.map((e) => e as int).toList();
        final limit = int.tryParse('${data['limit'] ?? 50}') ?? 50;
        final topic = data['topic']?.toString();
        final events = await RnsService.instance
            .relaySearch(q, kinds: kinds, limit: limit, topic: topic);
        return _json(res, {'ok': true, 'count': events.length, 'events': events});
      }
      if (req.method == 'POST' && path == '/api/rns/relay/query') {
        // {"filter":{NIP-01 filter}, "topic":"reticulum"}
        final data = await _body(req);
        final filter = data['filter'];
        if (filter is! Map) {
          return _json(res, {'ok': false, 'error': 'filter object required'},
              status: HttpStatus.badRequest);
        }
        final events = await RnsService.instance.relayQuery(
            Map<String, dynamic>.from(filter),
            topic: data['topic']?.toString());
        return _json(res, {'ok': true, 'count': events.length, 'events': events});
      }
      if (req.method == 'POST' && path == '/api/rns/relay/topic') {
        // {"topic":"reticulum"} — add a topic to our indexer interest set.
        final data = await _body(req);
        final topic = '${data['topic'] ?? ''}'.trim();
        if (topic.isEmpty) {
          return _json(res, {'ok': false, 'error': 'topic required'},
              status: HttpStatus.badRequest);
        }
        RnsService.instance.addRelayTopic(topic);
        return _json(res, {'ok': true, 'indexers': RnsService.instance.relayIndexerCount});
      }
      if (req.method == 'POST' && path == '/api/rns/folder/create') {
        // {"name":"My folder","desc":"..."} -> creates a mutable folder.
        final data = await _body(req);
        final name = '${data['name'] ?? ''}'.trim();
        if (name.isEmpty) {
          return _json(res, {'ok': false, 'error': 'name required'},
              status: HttpStatus.badRequest);
        }
        final id = RnsService.instance
            .folderCreate(name, desc: '${data['desc'] ?? ''}');
        return _json(res, {'ok': id != null, 'folderId': id});
      }
      if (req.method == 'POST' && path == '/api/rns/folder/edit') {
        // {"folderId":"<hex>","op":{"op":"addFile","x":"<sha256hex>",...}}
        final data = await _body(req);
        final folderId = '${data['folderId'] ?? ''}'.trim();
        final op = data['op'];
        if (folderId.isEmpty || op is! Map) {
          return _json(res, {'ok': false, 'error': 'folderId + op required'},
              status: HttpStatus.badRequest);
        }
        RnsService.instance
            .folderEdit(folderId, Map<String, dynamic>.from(op));
        return _json(res, {'ok': true});
      }
      if (req.method == 'POST' && path == '/api/rns/folder/browse') {
        // {"folderId":"<hex>"} -> the cached folder state (refreshes async).
        final data = await _body(req);
        final folderId = '${data['folderId'] ?? ''}'.trim();
        if (folderId.isEmpty) {
          return _json(res, {'ok': false, 'error': 'folderId required'},
              status: HttpStatus.badRequest);
        }
        return _json(res,
            {'ok': true, 'state': RnsService.instance.folderBrowse(folderId)});
      }
      if (req.method == 'GET' && path == '/api/rns/folder/list') {
        return _json(res, {'folders': RnsService.instance.folderList()});
      }
      if (req.method == 'POST' && path == '/api/rns/folder/adddisk') {
        // {"path":"/abs/dir"} — register an on-disk directory as an owned folder
        // (served from disk, not copied to the archive).
        final data = await _body(req);
        final p = '${data['path'] ?? ''}'.trim();
        if (p.isEmpty) {
          return _json(res, {'ok': false, 'error': 'path required'},
              status: HttpStatus.badRequest);
        }
        final id = await RnsService.instance.folderAddFromDisk(p);
        return _json(res, {'ok': id != null, 'folderId': id});
      }
      if (req.method == 'POST' && path == '/api/rns/folder/rescan') {
        final data = await _body(req);
        final fid = data['folderId']?.toString();
        await RnsService.instance.folderRescan(fid);
        return _json(res, {'ok': true, 'owned': RnsService.instance.ownedDiskFolders()});
      }
      if (req.method == 'POST' && path == '/api/rns/folder/download') {
        // {"folderId":..,"sha":..,"name":..} or {"folderId":..,"all":true}
        final data = await _body(req);
        final fid = '${data['folderId'] ?? ''}'.trim();
        if (fid.isEmpty) {
          return _json(res, {'ok': false, 'error': 'folderId required'},
              status: HttpStatus.badRequest);
        }
        if (data['all'] == true) {
          final n = await RnsService.instance.folderDownloadAll(fid);
          return _json(res, {'ok': true, 'downloaded': n});
        }
        final sha = '${data['sha'] ?? ''}'.trim();
        final name = '${data['name'] ?? sha}';
        if (sha.isEmpty) {
          return _json(res, {'ok': false, 'error': 'sha or all required'},
              status: HttpStatus.badRequest);
        }
        final ok = await RnsService.instance.folderDownloadFile(fid, sha, name);
        return _json(res, {'ok': ok});
      }
      if (req.method == 'POST' && path == '/api/rns/folder/autosync') {
        // {"folderId":..,"on":true}
        final data = await _body(req);
        final fid = '${data['folderId'] ?? ''}'.trim();
        if (fid.isEmpty) {
          return _json(res, {'ok': false, 'error': 'folderId required'},
              status: HttpStatus.badRequest);
        }
        RnsService.instance.setFolderAutoSync(fid, data['on'] == true);
        return _json(res, {'ok': true});
      }
      if (req.method == 'GET' && path == '/api/rns/folder/subscriptions') {
        return _json(res, {'subscriptions': RnsService.instance.folderSubscriptions()});
      }
      if (req.method == 'GET' && path == '/api/rns/folder/owned') {
        return _json(res, {'owned': RnsService.instance.ownedDiskFolders()});
      }
      if (req.method == 'GET' && path == '/api/ble/status') {
        return _json(res, BleService.instance.gattStatus());
      }
      if (req.method == 'POST' && path == '/api/ble/gattsend') {
        // {"size":1024} — send a test blob point-to-point over GATT (auto-pairs).
        final data = await _body(req);
        final size = int.tryParse('${data['size'] ?? 1024}') ?? 1024;
        BleService.instance.gattSendTest(size);
        return _json(res, {'ok': true, 'size': size, ...BleService.instance.gattStatus()});
      }

      return _json(res, {
        'error': 'Not found',
        'endpoints': [
          'GET /api/status',
          'GET /api/log?n=200',
          'GET /api/wapps',
          'POST /api/launch {"wapp":"<id>"}',
          'GET /api/media/torrents',
          'GET /api/media/has?sha256=<hex|b64u>',
          'POST /api/media/fetch {"sha256":"<hex|b64u>","ext":"png","ih":"<40hex?>"}',
          'POST /api/media/seed {"token":"file:<sha256>.<ext>"}',
          'POST /api/media/publish {"token":"file:<sha256>.<ext>"}',
          'GET /api/i2p/status',
          'POST /api/i2p/start',
          'POST /api/i2p/put {"data":"<base64>","ext":"txt"}',
          'POST /api/i2p/fetch {"b32":"<addr>","sha256":"<hex|b64u>","ext":"txt"}',
          'POST /api/i2p/peer {"callsign":"X1...","b32":"<addr>"}',
          'POST /api/i2p/announce {"sha256":"<hex|b64u>"}',
          'POST /api/i2p/discover {"sha256":"<hex|b64u>","ext":"txt"}',
          'GET /api/rns/status',
          'POST /api/rns/start {"mode":"tcpserver|tcpclient|ble","host":"..","port":4242}',
          'POST /api/rns/announce {"text":"hello"}',
          'GET /api/rns/inbox',
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

  /// Normalise a sha256 given as 64-hex or 43-char base64url to 32 raw bytes.
  Uint8List? _shaBytes(String s) {
    try {
      if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s)) {
        final out = Uint8List(32);
        for (var i = 0; i < 32; i++) {
          out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
        }
        return out;
      }
      if (s.length == 43) {
        final b = base64Url.decode('$s=');
        return b.length == 32 ? b : null;
      }
    } catch (_) {}
    return null;
  }

  /// Parse a JSON request body into a map (empty on no/invalid body).
  Future<Map<String, dynamic>> _body(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    if (body.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return {};
  }

  /// The shared media archive, with TorrentService configured against it and the
  /// per-profile share dir (mirrors shared_media_fetch). Null when storage isn't
  /// ready (e.g. web / before a profile is active).
  MediaArchive? _mediaArchive() {
    final archive = sharedMediaArchive();
    final prefs = PreferencesService.instanceSync;
    if (archive == null || prefs == null) return null;
    TorrentService.instance
        .configure(archive, wappsDataStorage(prefs).getAbsolutePath('share'));
    return archive;
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
      'build': kAuroraBuildTag,
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
