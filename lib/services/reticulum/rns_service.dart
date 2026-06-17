/*
 * RnsService — app-facing facade that runs a Reticulum node on the main isolate
 * for device-to-device validation. It owns an identity + a SINGLE destination
 * "aurora.chat", a transport (acting as a transport node so a TCP-server host
 * relays between connected clients), and one or more interfaces (TCP client, TCP
 * server, or BLE broadcast).
 *
 * "Chat" here is deliberately simple and broadcast-friendly: a message is an
 * announce of our destination carrying the text as app_data. Announces are
 * inherently one-to-many, so a single transmission reaches every peer — the same
 * property over LAN (UDP/TCP) and BLE. Received announces from other identities
 * land in [inbox].
 *
 * Driven over the remote API (the /api/rns endpoints) so it can be validated
 * headlessly on
 * phones (adb) and on Linux, mirroring how the I2P node was tested.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../connections/bluetooth/ble5_radio.dart';
import '../../connections/bluetooth/ble_rns_radio.dart';
import '../files/capacity_governor.dart';
import '../files/dht/dht_core.dart' show kDhtAspects;
import '../files/dht/provider_record.dart' show kCapUnknown;
import '../files/file_node.dart';
import '../files/file_transfer.dart';
import '../files/serve_quota.dart';
import '../log_service.dart';
import 'lxmf/lxmf.dart' show kLxmfApp, kLxmfDeliveryAspects;
import 'lxmf/lxmf_message.dart';
import 'lxmf/lxmf_router.dart';
import 'rns_announce.dart';
import 'rns_ble_interface.dart';
import 'rns_crypto.dart';
import 'rns_identity.dart';
import 'rns_packet.dart';
import 'rns_tcp_interface.dart';
import 'rns_tcp_server_interface.dart';
import 'rns_transport.dart';

const String _app = 'aurora';
const List<String> _aspects = ['chat'];

class RnsService {
  RnsService._();
  static final RnsService instance = RnsService._();

  RnsIdentity? _id;
  Uint8List? _destHash;
  RnsTransport? _transport;
  final List<RnsInterface> _ifaces = [];
  RnsTcpServerInterface? _server;
  RnsTcpInterface? _client;

  // Content-addressed file sharing over this node. The serve source is pluggable
  // (set [fileServeSource] before start to serve from MediaArchive); a fetcher
  // needs no source. Inbound link/file packets are routed here from _onInbound.
  FileTransferNode? _files;
  FileSource? fileServeSource;
  // LXMF messaging (interop with Sideband/NomadNet/MeshChat).
  LxmfRouter? _lxmf;
  final List<Map<String, dynamic>> _lxmfInbox = [];
  /// Capacity class we advertise in our provider records (set from connectivity:
  /// home/wifi/cellular/ble). Affects how peers rank us. Default unknown.
  int selfCapacity = kCapUnknown;

  bool _up = false;
  bool _starting = false;
  String _mode = '';
  final List<Map<String, dynamic>> _inbox = [];

  /// Last announced app_data and a periodic re-announce so the node stays
  /// visible to the mesh (and so repeaters keep an "in range" view of it). The
  /// CONTENT is supplied by the caller (e.g. the device callsign) — kept generic.
  String _announceText = 'online';
  Timer? _announceTimer;
  static const Duration _announceEvery = Duration(seconds: 30);
  // Re-publish our DHT provider records well under their 45-minute TTL so they
  // survive and follow churn (the k-closest set changes as nodes come and go).
  Timer? _republishTimer;
  static const Duration _republishEvery = Duration(minutes: 30);

  bool get isUp => _up;
  bool get isStarting => _starting;
  String? get identityHex => _id?.hexHash;
  String? get destHex => _destHash == null ? null : _hex(_destHash!);
  String get mode => _mode;
  List<Map<String, dynamic>> get inbox => List.unmodifiable(_inbox);

  Map<String, dynamic> status() => {
        'up': _up,
        'starting': _starting,
        'mode': _mode,
        'identity': identityHex,
        'dest': destHex,
        'paths': _transport?.pathCount ?? 0,
        'connections': _server?.connectionCount ?? 0,
        'interfaces': _ifaces.length + (_server != null ? 1 : 0),
        'inbox': _inbox.length,
        'provided': _files?.providedCount ?? 0,
        'lxmfDest': lxmfDeliveryHex,
        'lxmfInbox': _lxmfInbox.length,
        'selfCapacity': selfCapacity,
        'net': CapacityGovernor.instance.lastNet.name,
        'charging': CapacityGovernor.instance.lastCharging,
        if (_files != null) 'serveQuota': _files!.serveQuota.status(),
      };

  /// Start the node. [mode] is 'tcpserver' (LAN hub), 'tcpclient' (connect to a
  /// hub at host:port), or 'ble' (connectionless broadcast). [announceName] is
  /// the app_data broadcast in the initial + periodic announces (e.g. the
  /// device callsign); kept generic — the caller decides the content.
  Future<bool> start({
    required String mode,
    String host = '127.0.0.1',
    int port = 4242,
    String announceName = 'online',
  }) async {
    if (_up || _starting) return _up;
    _starting = true;
    try {
      _id = await RnsIdentity.generate();
      _destHash = RnsDestination.hash(_id!, _app, _aspects);
      _transport = RnsTransport(
          transportId: _id!.hash, log: (m) => LogService.instance.add('RNS: $m'));
      _mode = mode;
      _files = FileTransferNode(
        identity: _id!,
        source: fileServeSource ?? const EmptyFileSource(),
        send: (raw) => _transport?.sendOnAll(raw),
        log: (m) => LogService.instance.add('RNS/files: $m'),
        enableDht: true,
        nextHopFor: (peer) => _transport?.nextHopForIdentity(peer),
      );
      _lxmf = LxmfRouter(
        identity: _id!,
        send: (raw) => _transport?.sendOnAll(raw),
        nextHopFor: (peer) => _transport?.nextHopForIdentity(peer),
        identityForDest: (h) => _transport?.pathFor(h)?.identity,
        onMessage: (m) {
          _lxmfInbox.add({
            'from': _hex(m.sourceHash),
            'title': m.titleString,
            'content': m.contentString,
            'hash': _hex(m.hash),
            'ts': m.timestamp,
          });
          LogService.instance
              .add('LXMF: from ${_hex(m.sourceHash)}: "${m.contentString}"');
        },
        log: (msg) => LogService.instance.add('RNS/lxmf: $msg'),
      );

      // Auto-configure the serving budget + advertised capacity from the device
      // situation (charger + Wi-Fi => unlimited; cellular => off/sparing; etc.).
      await CapacityGovernor.instance.start(apply: (p) {
        selfCapacity = p.capacity;
        final q = _files?.serveQuota;
        if (q != null) p.applyTo(q);
      });

      switch (mode) {
        case 'tcpserver':
          _server = RnsTcpServerInterface(
            port: port,
            transport: _transport!,
            onPacket: _onInbound,
            log: (m) => LogService.instance.add('RNS/tcps: $m'),
          );
          await _server!.bind();
          break;
        case 'tcpclient':
          final c = RnsTcpInterface(
            host: host,
            port: port,
            label: 'tcp',
            onPacket: (raw) => _onInbound(raw, 'tcp'),
            log: (m) => LogService.instance.add('RNS/tcp: $m'),
          );
          await c.connect();
          _client = c;
          _transport!.addInterface(c);
          _ifaces.add(c);
          break;
        case 'ble':
          final radio = BleServiceRnsRadio();
          final b = RnsBleInterface(
            radio: radio,
            onPacket: (raw) => _onInbound(raw, 'ble'),
            log: (m) => LogService.instance.add('RNS/ble: $m'),
          );
          _transport!.addInterface(b);
          _ifaces.add(b);
          break;
        case 'ble5':
          final radio = Ble5Radio();
          if (!await radio.supported()) {
            LogService.instance.add('RNS: BLE5 extended advertising unsupported');
            _starting = false;
            return false;
          }
          await radio.startScan();
          final b5 = RnsBleInterface(
            radio: radio,
            onPacket: (raw) => _onInbound(raw, 'ble5'),
            log: (m) => LogService.instance.add('RNS/ble5: $m'),
          );
          _transport!.addInterface(b5);
          _ifaces.add(b5);
          break;
        default:
          LogService.instance.add('RNS: unknown mode $mode');
          _starting = false;
          return false;
      }

      _up = true;
      LogService.instance
          .add('RNS: node up mode=$mode id=${_id!.hexHash} dest=$destHex');
      await announce(announceName);
      await _announceServiceDests();
      _announceTimer?.cancel();
      _announceTimer = Timer.periodic(_announceEvery, (_) {
        if (_up) {
          announce(_announceText);
          _announceServiceDests();
        }
      });
      _republishTimer?.cancel();
      _republishTimer = Timer.periodic(_republishEvery, (_) {
        if (_up) _files?.republishAll();
      });
      return true;
    } catch (e) {
      LogService.instance.add('RNS: start error: $e');
      _starting = false;
      _up = false;
      return false;
    } finally {
      _starting = false;
    }
  }

  /// Announce our destination carrying [text] as app_data — a one-to-many
  /// "chat" message. One transmission per interface; peers reassemble + record.
  Future<void> announce(String text) async {
    if (!_up || _id == null) return;
    _announceText = text;   /* remember for the periodic re-announce */
    final pkt = await RnsAnnounceBuilder.build(
      _id!,
      _app,
      _aspects,
      appData: Uint8List.fromList(utf8.encode(text)),
    );
    _transport!.sendOnAll(pkt.pack());
    LogService.instance.add('RNS: announced "$text"');
  }

  /// Announce our FILES and DHT destinations so transport nodes (rnsd) learn a
  /// route to them and peers can open file/DHT links to us across the network.
  /// (The chat dest is announced separately by [announce] with the callsign.)
  Future<void> _announceServiceDests() async {
    if (!_up || _id == null) return;
    for (final aspects in [_aspectsFiles, _aspectsDht]) {
      final pkt = await RnsAnnounceBuilder.build(_id!, _app, aspects,
          appData: Uint8List(0));
      _transport!.sendOnAll(pkt.pack());
    }
    // Announce our LXMF delivery destination so peers (and other LXMF clients,
    // e.g. Sideband/NomadNet) can route messages to us.
    final lx = await RnsAnnounceBuilder.build(
        _id!, kLxmfApp, kLxmfDeliveryAspects,
        appData: Uint8List.fromList(utf8.encode(_announceText)));
    _transport!.sendOnAll(lx.pack());
  }

  static const List<String> _aspectsFiles = kFilesAspects;
  static const List<String> _aspectsDht = kDhtAspects;

  Future<void> _onInbound(Uint8List raw, String via) async {
    final p = RnsPacket.parse(raw);
    if (p == null) return;
    // Link / file-transfer packets (link requests + link-addressed data) are
    // handled by the files node, not the announce path.
    if (p.packetType != RnsPacketType.announce) {
      if (await _files?.handlePacket(p) ?? false) return;
      if (await _lxmf?.handlePacket(p) ?? false) return;
    }
    final ann = await _transport!.ingest(p, via);
    if (ann == null) return;
    // Skip our own announces.
    if (_id != null &&
        RnsCrypto.constantTimeEquals(ann.identity.hash, _id!.hash)) {
      return;
    }
    // Learn the peer as a DHT contact (bootstraps the index from announces).
    _files?.addPeerFromAnnounce(ann.identity);
    final text = utf8.decode(ann.appData, allowMalformed: true);
    _inbox.add({
      'from': ann.identity.hexHash,
      'dest': _hex(ann.destHash),
      'text': text,
      'via': via,
    });
    LogService.instance
        .add('RNS: rx from ${ann.identity.hexHash} via $via: "$text"');
  }

  /// Fetch a file by its sha256 (32B) from a peer we have a path to. [peerDestHex]
  /// is any destination hash of that peer we have heard announce (e.g. its chat
  /// dest) — its identity is reused to address the peer's files destination.
  /// Returns the verified bytes, or null if no path / not held / timeout. (Multi-
  /// source discovery via the DHT is a later layer; this fetches from one known
  /// provider.)
  Future<Uint8List?> fetchFileFrom(
    Uint8List fileHash,
    String peerDestHex, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final f = _files;
    if (!_up || f == null) return null;
    final dh = _bytesFromHex(peerDestHex);
    if (dh == null) return null;
    final entry = _transport?.pathFor(dh);
    if (entry == null) {
      LogService.instance.add('RNS/files: no path to $peerDestHex');
      return null;
    }
    return f.fetch(fileHash, entry.identity, timeout: timeout);
  }

  /// Resolve providers for [fileHash] (sha256, 32B) via the DHT and fetch the
  /// bytes from the best available provider over a Reticulum link. Returns the
  /// verified bytes or null. No fixed peer needed — discovery is the DHT.
  Future<Uint8List?> dhtResolveFetch(
    Uint8List fileHash, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!_up) return null;
    return _files?.resolveAndFetch(fileHash, timeout: timeout);
  }

  /// The serving budget / anti-abuse guard (null until the node has started).
  ServeQuota? get serveQuota => _files?.serveQuota;

  /// Allow or forbid serving files (e.g. set false on metered/cellular). When
  /// off, we still fetch; we just decline to serve and let our records age out.
  set servingAllowed(bool v) {
    final q = _files?.serveQuota;
    if (q != null) q.servingAllowed = v;
  }

  /// Announce ourselves as a provider of [fileHash] (auto-seed): publish a signed
  /// provider record into the DHT. Returns the number of holders that accepted.
  Future<int> dhtPublish(Uint8List fileHash, {int? capacity}) async {
    if (!_up) return 0;
    return _files?.publishProvider(fileHash, capacity: capacity ?? selfCapacity) ??
        0;
  }

  /// This node's LXMF delivery destination hash (peers address messages here).
  String? get lxmfDeliveryHex {
    final h = _lxmf?.deliveryDestHash;
    return h == null ? null : _hex(h);
  }

  /// Received LXMF messages (verified). Newest appended.
  List<Map<String, dynamic>> get lxmfInbox => List.unmodifiable(_lxmfInbox);

  /// Send an LXMF message to [destHex] (a peer's LXMF delivery destination hash,
  /// learned from its announce). Returns true once delivered over the link.
  Future<bool> sendLxmf({
    required String destHex,
    String title = '',
    String content = '',
    Map<int, Object?>? fields,
  }) async {
    final r = _lxmf;
    if (!_up || r == null || _id == null) return false;
    final dh = _bytesFromHex(destHex);
    if (dh == null) return false;
    final msg = await LxmfMessage.create(
      destinationHash: dh,
      source: _id!,
      title: title,
      content: content,
      fields: fields,
    );
    return r.send_(msg);
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _republishTimer?.cancel();
    _republishTimer = null;
    _lxmf = null;
    CapacityGovernor.instance.stop();
    await _server?.close();
    _client?.close();
    _server = null;
    _client = null;
    _files = null;
    _ifaces.clear();
    _transport = null;
    _up = false;
    _mode = '';
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List? _bytesFromHex(String hex) {
    final s = hex.trim();
    if (s.isEmpty || s.length.isOdd) return null;
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final b = int.tryParse(s.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) return null;
      out[i] = b;
    }
    return out;
  }
}
