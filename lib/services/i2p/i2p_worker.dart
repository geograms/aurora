/*
 * I2pWorker — runs the pure-Dart I2pNode in a dedicated background ISOLATE so
 * its crypto and network loops never starve the app's UI isolate (the phone
 * test showed the node, on the main isolate, made the app unresponsive).
 *
 * The main isolate keeps the MediaArchive (sqlite) and the UI; the worker
 * isolate owns the node and its sockets. They talk over SendPorts:
 *   main -> worker: start, fetch, discoverFetch, announce, setRoster, provide,
 *                   pause, resume, stop  (each with a request id)
 *   worker -> main: 'ready' (b32), 'log', 'result' (id+data), and 'getReq'
 *                   (the node asks the main isolate to serve bytes for a sha256;
 *                   the main isolate answers from the archive).
 */
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'i2p_node.dart';
import 'i2p_structures.dart';

class I2pWorkerConfig {
  final int netId;
  final String? hostOverride;
  final int? portOverride;
  final Uint8List? ivOverride;
  final int hops;
  /// Raw RouterInfo blobs to use instead of reseeding (testing / pinned peers).
  final List<Uint8List>? peersRaw;
  const I2pWorkerConfig(
      {this.netId = 2,
      this.hostOverride,
      this.portOverride,
      this.ivOverride,
      this.hops = 1,
      this.peersRaw});

  Map<String, dynamic> toMap() => {
        'netId': netId,
        'host': hostOverride,
        'port': portOverride,
        'iv': ivOverride,
        'hops': hops,
        'peers': peersRaw,
      };
}

class I2pWorker {
  final void Function(String)? log;
  /// Serve content by sha256 from the main isolate (e.g. the MediaArchive).
  final Future<Uint8List?> Function(Uint8List sha256)? onGet;

  I2pWorker({this.log, this.onGet});

  Isolate? _iso;
  SendPort? _tx; // -> worker
  final _ready = Completer<String?>();
  final _pending = <int, Completer<dynamic>>{};
  int _seq = 0;
  String? _b32;

  bool get isRunning => _iso != null;
  String? get b32 => _b32;

  /// Spawn the isolate and start the node. Returns our b32, or null on failure.
  Future<String?> start(I2pWorkerConfig config) async {
    if (_iso != null) return _b32;
    final rx = ReceivePort();
    _iso = await Isolate.spawn(_isolateMain, rx.sendPort, debugName: 'i2p-node');
    rx.listen(_onMessage);
    // First message back is the worker's command SendPort.
    _tx = await _firstPort.future;
    _tx!.send({'cmd': 'start', 'config': config.toMap()});
    _b32 = await _ready.future;
    return _b32;
  }

  final _firstPort = Completer<SendPort>();

  void _onMessage(dynamic m) {
    if (m is SendPort) {
      _firstPort.complete(m);
      return;
    }
    if (m is! Map) return;
    switch (m['t']) {
      case 'ready':
        if (!_ready.isCompleted) _ready.complete(m['b32'] as String?);
        break;
      case 'log':
        log?.call(m['msg'] as String);
        break;
      case 'result':
        final c = _pending.remove(m['id']);
        if (c != null && !c.isCompleted) c.complete(m['data']);
        break;
      case 'getReq':
        // The node (in the worker) needs bytes for a sha256; serve from main.
        final id = m['id'];
        final sha = m['sha'] as Uint8List;
        () async {
          Uint8List? bytes;
          try {
            bytes = await onGet?.call(sha);
          } catch (_) {}
          _tx?.send({'cmd': 'getResp', 'id': id, 'bytes': bytes});
        }();
        break;
    }
  }

  Future<dynamic> _call(String cmd, [Map<String, dynamic> args = const {}]) {
    final id = _seq++;
    final c = Completer<dynamic>();
    _pending[id] = c;
    _tx?.send({'cmd': cmd, 'id': id, ...args});
    return c.future;
  }

  Future<Uint8List?> fetch(Uint8List destHash, Uint8List sha256) async =>
      await _call('fetch', {'dest': destHash, 'sha': sha256}) as Uint8List?;

  Future<Uint8List?> discoverFetch(Uint8List sha256) async =>
      await _call('discoverFetch', {'sha': sha256}) as Uint8List?;

  /// Collective multi-device piece download (the path for files > ~64 KiB).
  /// [seed] optionally pre-seeds the provider set with a known peer's dest hash.
  Future<Uint8List?> swarmFetch(Uint8List sha256,
          {List<Uint8List> seed = const []}) async =>
      await _call('swarmFetch', {'sha': sha256, 'seed': seed}) as Uint8List?;

  Future<void> announce(Uint8List sha256) => _call('announce', {'sha': sha256});
  Future<void> setRoster(List<Uint8List> hashes) =>
      _call('setRoster', {'roster': hashes});
  Future<void> pause() => _call('pause');
  Future<void> resume() => _call('resume');

  void stop() {
    _tx?.send({'cmd': 'stop'});
    _iso?.kill(priority: Isolate.beforeNextEvent);
    _iso = null;
    _tx = null;
  }
}

// ---- isolate side ----

void _isolateMain(SendPort main) {
  final rx = ReceivePort();
  main.send(rx.sendPort);

  I2pNode? node;
  final getReqs = <int, Completer<Uint8List?>>{};
  var getSeq = 0;

  rx.listen((m) async {
    if (m is! Map) return;
    switch (m['cmd']) {
      case 'start':
        final cfg = m['config'] as Map;
        node = I2pNode(
          netId: cfg['netId'] as int,
          log: (s) => main.send({'t': 'log', 'msg': s}),
          onGet: (sha) {
            // Ask the main isolate to serve the bytes.
            final id = getSeq++;
            final c = Completer<Uint8List?>();
            getReqs[id] = c;
            main.send({'t': 'getReq', 'id': id, 'sha': sha});
            return c.future
                .timeout(const Duration(seconds: 10), onTimeout: () => null);
          },
        );
        final rawPeers = (cfg['peers'] as List?)?.cast<Uint8List>();
        final peers = rawPeers
            ?.map(parseRouterInfo)
            .whereType<RouterInfo>()
            .toList();
        final ok = await node!.start(
          peers: peers,
          hostOverride: cfg['host'] as String?,
          portOverride: cfg['port'] as int?,
          ivOverride: cfg['iv'] as Uint8List?,
          hops: cfg['hops'] as int,
        );
        main.send({'t': 'ready', 'b32': ok ? node!.b32 : null});
        break;
      case 'getResp':
        final c = getReqs.remove(m['id']);
        if (c != null && !c.isCompleted) c.complete(m['bytes'] as Uint8List?);
        break;
      case 'fetch':
        final r = await node?.fetch(m['dest'] as Uint8List, m['sha'] as Uint8List);
        main.send({'t': 'result', 'id': m['id'], 'data': r});
        break;
      case 'discoverFetch':
        final r = await node?.discoverFetch(m['sha'] as Uint8List);
        main.send({'t': 'result', 'id': m['id'], 'data': r});
        break;
      case 'swarmFetch':
        final seed = (m['seed'] as List?)?.cast<Uint8List>() ?? const [];
        final r = await node?.swarmFetch(m['sha'] as Uint8List, seedProviders: seed);
        main.send({'t': 'result', 'id': m['id'], 'data': r});
        break;
      case 'announce':
        await node?.announce(m['sha'] as Uint8List);
        main.send({'t': 'result', 'id': m['id'], 'data': null});
        break;
      case 'setRoster':
        node?.setRoster((m['roster'] as List).cast<Uint8List>());
        main.send({'t': 'result', 'id': m['id'], 'data': null});
        break;
      case 'pause':
        node?.pause();
        main.send({'t': 'result', 'id': m['id'], 'data': null});
        break;
      case 'resume':
        await node?.resume();
        main.send({'t': 'result', 'id': m['id'], 'data': null});
        break;
      case 'stop':
        node?.close();
        break;
    }
  });
}
