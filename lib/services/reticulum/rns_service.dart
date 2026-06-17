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
import '../files/composite_file_source.dart';
import '../files/file_node.dart';
import '../files/file_transfer.dart';
import '../files/media_file_source.dart';
import '../files/serve_quota.dart';
import '../log_service.dart';
import '../social/relay_event_store.dart';
import '../social/relay_node.dart';
import '../social/relay_role.dart';
import '../social/spam.dart';
import '../social/store_forward.dart';
import '../folders/disk_folder_manager.dart';
import '../folders/folder_event.dart' show kKindFolderKeyset, kKindFolderOp;
import '../folders/folder_keystore.dart';
import '../folders/folder_relay.dart';
import '../folders/folder_service.dart';
import '../folders/folder_state.dart';
import '../folders/folder_subscriptions.dart';
import '../../profile/profile_service.dart';
import '../../util/nostr_crypto.dart';
import '../../util/nostr_event.dart';
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

  // Distributed NOSTR-like relay/indexer: a local event store + search, a relay
  // endpoint over Reticulum, a directory of peer indexers, a capacity-driven
  // role, and LXMF store-and-forward. The DB path is set by the app before start
  // (persistent); if unset we fall back to an in-memory store.
  String? relayStorePath;
  RelayEventStore? _relayStore;
  RelayNode? _relay;
  final RelayDirectory _relayDir = RelayDirectory();
  RelayRoleManager? _relayRole;
  StoreForward? _storeForward;

  // IPNS-like mutable folders (folder = secp256k1 identity; events on the relay).
  // The keystore (owned master keys) persists at [folderStorePath]; set by the
  // app before start (else in-memory). Browsed states are cached for the wapp.
  String? folderStorePath;
  FolderService? _folders;
  FolderRelay? _folderRelay;
  final Map<String, String> _folderCache = {}; // folderId -> FolderState JSON

  // Disk-backed owner folders + consumer subscriptions. Serve source is a
  // composite so disk-folder bytes are served straight from disk (no sqlite
  // copy), alongside the MediaArchive.
  String? diskFoldersPath;
  String? subscriptionsPath;
  CompositeFileSource? _composite;
  DiskFolderManager? _diskMgr;
  FolderSubscriptions? _subs;
  Timer? _diskSyncTimer;
  Timer? _autoSyncTimer;
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
        if (_relay != null) 'relayDest': relayDestHex,
        if (_relayRole != null) 'relayRole': _relayRole!.current.role.name,
        if (_relayStore != null) 'relayEvents': _relayStore!.count(),
        if (_relayStore != null) 'relayMailbox': _relayStore!.sfCount(),
        'relayIndexers': _relayDir.indexers().length,
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
      // One serve source that fans out: the MediaArchive plus any owner disk
      // folders (added later by the DiskFolderManager) — disk bytes are never
      // copied into sqlite.
      _composite = CompositeFileSource([fileServeSource ?? const EmptyFileSource()]);
      _files = FileTransferNode(
        identity: _id!,
        source: _composite!,
        send: (raw) => _transport?.sendOnAll(raw),
        log: (m) => LogService.instance.add('RNS/files: $m'),
        enableDht: true,
        nextHopFor: (peer) => _transport?.nextHopForIdentity(peer),
        // Count a download whenever we serve a file's manifest to another node.
        onServed: (h) {
          final src = fileServeSource;
          if (src is MediaFileSource) src.archive.incrementDownloads(_hex(h));
        },
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

      // Distributed relay/indexer: local event store + search + serve endpoint.
      try {
        _relayStore = RelayEventStore.open(relayStorePath ?? ':memory:');
        _relay = RelayNode(
          identity: _id!,
          store: _relayStore!,
          send: (raw) => _transport?.sendOnAll(raw),
          nextHopFor: (peer) => _transport?.nextHopForIdentity(peer),
          spam: SpamPolicy.lenient(),
          log: (m) => LogService.instance.add('RNS/relay: $m'),
        );
        _relayRole = RelayRoleManager(
          onChanged: (_) => _announceRelayDest(),
        );
        _storeForward = StoreForward(
          node: _relay!,
          router: _lxmf!,
          directory: _relayDir,
          log: (m) => LogService.instance.add('RNS/sf: $m'),
        );
      } catch (e) {
        LogService.instance.add('RNS/relay: disabled (store open failed: $e)');
        _relay = null;
      }

      // Mutable folders: owned-key store + service. Discovery is peer-to-peer via
      // the DHT (no indexer): any holder advertises itself under the folder key
      // and a browser resolves providers by that key — exactly like sha256 files.
      try {
        final store = _relayStore;
        if (store != null) {
          _folderRelay = FolderRelay(
            store: store,
            publishProvider: (key) async {
              await _files?.publishKey(key, capacity: selfCapacity);
            },
            resolveProviders: (key) async =>
                (await _files?.resolveProviders(key)) ?? const [],
            queryProvider: (p, f) async => (await _relay?.query(p, f)) ?? const [],
            log: (m) => LogService.instance.add('RNS/folders: $m'),
          );
          _folders = FolderService(
            keystore: FolderKeystore.open(folderStorePath ?? ':memory:'),
            publish: (ev) => relayPublish(ev.toJson()),
            query: (f) => _folderRelay!.query(f),
            adminPrivHex: _profilePrivHex,
            log: (m) => LogService.instance.add('RNS/folders: $m'),
          );
          _subs = FolderSubscriptions.open(subscriptionsPath ?? ':memory:');
          _diskMgr = DiskFolderManager(
            folders: _folders!,
            localState: _localFolderState,
            publishFolderProvider: (fid) => _folderRelay!.publish(fid),
            publishFileProvider: (sha) async {
              await _files?.publishKey(sha, capacity: selfCapacity);
            },
            registerSource: (src) => _composite?.add(src),
            registryPath: diskFoldersPath ?? ':memory:',
            log: (m) => LogService.instance.add('RNS/folders: $m'),
          );
          await _diskMgr!.load();
        }
      } catch (e) {
        LogService.instance.add('RNS/folders: disabled ($e)');
        _folders = null;
        _folderRelay = null;
        _diskMgr = null;
        _subs = null;
      }

      // Auto-configure the serving budget + advertised capacity from the device
      // situation (charger + Wi-Fi => unlimited; cellular => off/sparing; etc.).
      // The same profile drives our relay ROLE (unlimited => indexer).
      await CapacityGovernor.instance.start(apply: (p) {
        selfCapacity = p.capacity;
        final q = _files?.serveQuota;
        if (q != null) p.applyTo(q);
        _relayRole?.applyCapacity(p);
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
      // Re-index owned disk folders so edits on disk get signed + synced to the
      // network without the user doing anything.
      _diskSyncTimer?.cancel();
      _diskSyncTimer = Timer.periodic(const Duration(seconds: 60), (_) {
        if (_up) _diskMgr?.syncAll();
      });
      // Pull newer versions of files the user downloaded from auto-sync folders.
      _autoSyncTimer?.cancel();
      _autoSyncTimer = Timer.periodic(const Duration(minutes: 5), (_) {
        if (_up) _autoSyncTick();
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
    // Announce our relay role + interest set so peers can find/rank us.
    await _announceRelayDest();
  }

  /// Announce the relay destination carrying our role/capacity/interest summary
  /// (RelayAnnouncement). Peers collect these into their RelayDirectory.
  Future<void> _announceRelayDest() async {
    if (!_up || _id == null || _relayRole == null) return;
    final pkt = await RnsAnnounceBuilder.build(_id!, kRelayApp, kRelayAspects,
        appData: _relayRole!.announcementAppData());
    _transport!.sendOnAll(pkt.pack());
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
      if (await _relay?.handlePacket(p) ?? false) return;
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
    // Relay directory: record a peer's relay role announcement.
    final relayHash = RnsDestination.hash(ann.identity, kRelayApp, kRelayAspects);
    if (RnsCrypto.constantTimeEquals(ann.destHash, relayHash)) {
      _relayDir.observe(ann.identity, ann.appData, hops: p.hops + 1);
    }
    // Store-and-forward: a recipient's LXMF dest came online — flush its mail.
    final lxHash =
        RnsDestination.hash(ann.identity, kLxmfApp, kLxmfDeliveryAspects);
    if (RnsCrypto.constantTimeEquals(ann.destHash, lxHash) &&
        (_relay?.hasMailFor(ann.identity) ?? false)) {
      _storeForward?.onRecipientOnline(ann.identity);
    }
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

  // ── Social relay / indexer (app-facing) ────────────────────────────────────

  /// This node's relay destination hash (peers open relay links here).
  String? get relayDestHex {
    final r = _relay;
    return r == null ? null : _hex(r.relayDestHash);
  }

  /// Register an interest (topic / author pubkey) so this node, when it is an
  /// indexer, advertises and aggregates it. Re-announces the role.
  void addRelayTopic(String topic) {
    _relayRole?.interests.addTopic(topic);
    final p = CapacityGovernor.instance.lastProfile;
    if (p != null) _relayRole?.interestsChanged(p);
  }

  void addRelayAuthor(String pubkeyHex) {
    _relayRole?.interests.addAuthor(pubkeyHex);
    final p = CapacityGovernor.instance.lastProfile;
    if (p != null) _relayRole?.interestsChanged(p);
  }

  /// Publish a signed NOSTR event (JSON, NIP-01). Stored locally and, if we know
  /// an indexer, pushed to the best one for it. Returns true if stored locally.
  Future<bool> relayPublish(Map<String, dynamic> eventJson) async {
    final store = _relayStore;
    if (store == null) return false;
    final ev = NostrEvent.fromJson(eventJson);
    final stored = store.put(ev);
    // Best-effort fan-out to an indexer that would hold it.
    final topics = [
      for (final t in ev.tags)
        if (t.length >= 2 && t[0] == 't') t[1]
    ];
    final best = _relayDir.bestIndexer(
        topic: topics.isEmpty ? null : topics.first, author: ev.pubkey);
    if (best != null && _relay != null) {
      // ignore: discarded_futures
      _relay!.publish(best.identity, ev);
    }
    return stored;
  }

  /// Full-text search (NIP-50). Queries the best known indexer if available,
  /// otherwise the local store. Returns matching events as JSON.
  Future<List<Map<String, dynamic>>> relaySearch(String text,
      {List<int>? kinds, int limit = 50, String? topic}) async {
    final filter = NostrFilter(search: text, kinds: kinds, limit: limit);
    return _relayRun(filter, topic: topic);
  }

  /// Run a NIP-01 filter (JSON form) against the best indexer or the local store.
  Future<List<Map<String, dynamic>>> relayQuery(Map<String, dynamic> filterJson,
      {String? topic}) async {
    return _relayRun(NostrFilter.fromJson(filterJson), topic: topic);
  }

  Future<List<Map<String, dynamic>>> _relayRun(NostrFilter filter,
      {String? topic}) async {
    final best = _relayDir.bestIndexer(topic: topic);
    if (best != null && _relay != null) {
      final events = await _relay!.query(best.identity, filter);
      if (events.isNotEmpty) return [for (final e in events) e.toJson()];
    }
    final local = _relayStore?.query(filter) ?? const [];
    return [for (final e in local) e.toJson()];
  }

  /// Known peer indexers (for diagnostics / UI).
  int get relayIndexerCount => _relayDir.indexers().length;

  /// The active profile's private key (hex) for signing folder edits as an admin.
  String? _profilePrivHex() {
    final nsec = ProfileService.instance.activeProfile?.nsec;
    if (nsec == null || nsec.isEmpty) return null;
    try {
      return NostrCrypto.decodeNsec(nsec);
    } catch (_) {
      return null;
    }
  }

  // ── Mutable folders (app-facing) ────────────────────────────────────────────

  /// Create a folder; returns its folderId (hex; npub is the shareable address).
  /// The master key is stored locally; initial relay state is published async.
  String? folderCreate(String name, {String desc = ''}) {
    final f = _folders;
    if (f == null) return null;
    final folderId = f.createKey(name);
    // ignore: discarded_futures
    f.publishInitial(folderId, name: name, desc: desc);
    // Advertise ourselves as a provider so peers find this folder by its key.
    // ignore: discarded_futures
    _folderRelay?.publish(folderId);
    return folderId;
  }

  /// Normalize a folderId to hex: accepts hex already or an `npub1...` address.
  String _normFolderId(String id) {
    final s = id.trim();
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s)) return s.toLowerCase();
    if (s.startsWith('npub1')) {
      try {
        return NostrCrypto.decodeNpub(s);
      } catch (_) {}
    }
    return s;
  }

  /// Apply an edit to a folder (op JSON: addFile/rmFile/setMeta/link/unlink/
  /// grant/revoke). Fire-and-forget; the browse cache refreshes on next browse.
  void folderEdit(String folderIdOrNpub, Map<String, dynamic> op) {
    final f = _folders;
    if (f == null) return;
    final folderId = _normFolderId(folderIdOrNpub);
    final kind = op['op'];
    Future<bool>? fut;
    switch (kind) {
      case 'addFile':
        fut = f.addFile(folderId, _normShaHex('${op['x']}'),
            name: op['name'] as String?,
            desc: op['desc'] as String?,
            mime: op['mime'] as String?,
            size: op['size'] is int ? op['size'] as int : null);
        break;
      case 'rmFile':
        fut = f.removeFile(folderId, '${op['x']}');
        break;
      case 'setMeta':
        fut = f.setMeta(folderId,
            name: op['name'] as String?, desc: op['desc'] as String?);
        break;
      case 'link':
        fut = f.linkFolder(folderId, _normFolderId('${op['f']}'),
            name: op['name'] as String?);
        break;
      case 'unlink':
        fut = f.unlinkFolder(folderId, _normFolderId('${op['f']}'));
        break;
      case 'grant':
        fut = f.grantAdmin(folderId, '${op['p']}',
            role: (op['role'] ?? 'contributor').toString());
        break;
      case 'revoke':
        fut = f.revokeAdmin(folderId, '${op['p']}');
        break;
      default:
        return;
    }
    // Refresh the cache once the edit is on the relay.
    // ignore: discarded_futures
    fut.then((_) => folderRefresh(folderId));
  }

  /// Owned folders (we hold the master key): [{folderId, npub, name}].
  List<Map<String, dynamic>> folderList() {
    final f = _folders;
    if (f == null) return const [];
    return [
      for (final k in f.ownedFolders())
        {'folderId': k.folderId, 'npub': k.npub, 'name': k.name}
    ];
  }

  /// The cached state of a folder (may be empty until the first refresh). Always
  /// kicks off a background refresh so the next call returns fresh data.
  Map<String, dynamic> folderBrowse(String folderIdOrNpub) {
    final folderId = _normFolderId(folderIdOrNpub);
    folderRefresh(folderId);
    final cached = _folderCache[folderId];
    if (cached == null) return {'folderId': folderId};
    try {
      return jsonDecode(cached) as Map<String, dynamic>;
    } catch (_) {
      return {'folderId': folderId};
    }
  }

  /// Normalize a file id to 64-char sha256 hex. Accepts hex already, a
  /// `file:<b64u>.<ext>` media token, or a bare 43-char base64url sha — so the
  /// folder layer (hex, like file_meta) and the media archive (base64url) agree.
  String _normShaHex(String x) {
    var s = x.trim();
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s)) return s.toLowerCase();
    if (s.startsWith('file:')) s = s.substring(5);
    final dot = s.indexOf('.');
    if (dot > 0) s = s.substring(0, dot);
    if (RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(s)) {
      try {
        final padded = s + '=' * ((4 - s.length % 4) % 4);
        final bytes = base64Url.decode(padded);
        if (bytes.length == 32) return _hex(bytes);
      } catch (_) {}
    }
    return x; // leave as-is; reducer will simply key on whatever was given
  }

  /// Trigger an async browse and update the cache (no-op if folders disabled).
  void folderRefresh(String folderIdOrNpub) {
    final f = _folders;
    if (f == null) return;
    final folderId = _normFolderId(folderIdOrNpub);
    // ignore: discarded_futures
    f.browse(folderId).then((st) {
      _folderCache[folderId] = jsonEncode(st.toJson());
      // We now hold this folder's events — auto-seed so others can find it too.
      if (st.files.isNotEmpty || st.name != null) {
        // ignore: discarded_futures
        _folderRelay?.publish(folderId);
      }
    }).catchError((_) {});
  }

  // Published folder state from the LOCAL store only (no DHT) — used by the disk
  // sync to diff against what we've already published.
  Future<FolderState> _localFolderState(String folderId) async {
    final store = _relayStore;
    if (store == null) return FolderState(folderId);
    final ks = store.query(NostrFilter(
        authors: [folderId], kinds: [kKindFolderKeyset], limit: 1));
    final ops = store.query(NostrFilter(
        kinds: [kKindFolderOp],
        tags: {
          'd': [folderId]
        },
        limit: 5000));
    return reduceFolder(folderId, ks.isEmpty ? null : ks.first, ops);
  }

  // ── Owner disk folders (app-facing) ─────────────────────────────────────────

  /// Register an on-disk directory as a folder we own (key file kept inside it),
  /// index it, and sync it to the network. Returns its folderId, or null.
  Future<String?> folderAddFromDisk(String dirPath) async {
    final m = _diskMgr;
    if (m == null) return null;
    try {
      return await m.addFromDisk(dirPath);
    } catch (e) {
      LogService.instance.add('RNS/folders: addFromDisk failed: $e');
      return null;
    }
  }

  /// Re-scan owned disk folders and sync any changes (all, or one).
  Future<void> folderRescan([String? folderId]) async {
    final m = _diskMgr;
    if (m == null) return;
    if (folderId == null) {
      await m.syncAll();
    } else {
      await m.sync(folderId);
    }
  }

  List<Map<String, dynamic>> ownedDiskFolders() => _diskMgr?.owned() ?? const [];

  // ── Consumer downloads + auto-sync (app-facing) ─────────────────────────────

  /// Download one file of a folder by its sha (fetched from any provider over the
  /// DHT), store it in the local archive, record it for this folder, and auto-seed.
  Future<bool> folderDownloadFile(
      String folderId, String shaHex, String name) async {
    final shaB = _bytesFromHex(shaHex);
    if (shaB == null) return false;
    final bytes = await _files?.resolveAndFetch(shaB);
    if (bytes == null) return false;
    final src = fileServeSource;
    if (src is MediaFileSource) src.archive.putBytes(bytes, _extOf(name));
    _subs?.recordDownload(folderId, name, shaHex);
    // ignore: discarded_futures
    _files?.publishProvider(shaB, capacity: selfCapacity); // become a provider
    return true;
  }

  /// Download every file in a folder. Returns how many succeeded.
  Future<int> folderDownloadAll(String folderId) async {
    final f = _folders;
    if (f == null) return 0;
    final st = await f.browse(folderId);
    var n = 0;
    for (final file in st.fileList) {
      if (await folderDownloadFile(folderId, file.sha, file.name ?? file.sha)) {
        n++;
      }
    }
    return n;
  }

  void setFolderAutoSync(String folderId, bool on) =>
      _subs?.setAutoSync(folderId, on);

  List<Map<String, dynamic>> folderSubscriptions() {
    final s = _subs;
    if (s == null) return const [];
    return [
      for (final fid in s.folderIds()) {'folderId': fid, ...s.status(fid)}
    ];
  }

  // For each auto-sync folder, re-fetch downloaded files whose sha changed.
  Future<void> _autoSyncTick() async {
    final s = _subs, f = _folders;
    if (s == null || f == null) return;
    for (final fid in s.folderIds()) {
      if (!s.autoSyncOf(fid)) continue;
      final st = await f.browse(fid);
      final cur = <String, String>{
        for (final e in st.fileList) (e.name ?? e.sha): e.sha
      };
      for (final entry in s.downloadedOf(fid).entries) {
        final now = cur[entry.key];
        if (now != null && now != entry.value) {
          await folderDownloadFile(fid, now, entry.key);
        }
      }
    }
  }

  String _extOf(String name) {
    final dot = name.lastIndexOf('.');
    final slash = name.lastIndexOf('/');
    final e =
        (dot > slash && dot >= 0) ? name.substring(dot + 1).toLowerCase() : 'bin';
    return RegExp(r'^[a-z0-9]{1,18}$').hasMatch(e) ? e : 'bin';
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _republishTimer?.cancel();
    _republishTimer = null;
    _lxmf = null;
    _relay = null;
    _relayRole = null;
    _storeForward = null;
    _relayDir.clear();
    _relayStore?.close();
    _relayStore = null;
    _folders = null;
    _folderRelay = null;
    _folderCache.clear();
    _diskSyncTimer?.cancel();
    _diskSyncTimer = null;
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
    _diskMgr = null;
    _subs = null;
    _composite = null;
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
