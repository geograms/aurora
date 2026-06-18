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
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../../connections/bluetooth/ble5_radio.dart';
import '../../connections/bluetooth/ble_rns_radio.dart';
import '../files/capacity_governor.dart';
import '../files/dht/dht_core.dart' show kDhtAspects;
import '../files/dht/provider_record.dart' show kCapUnknown;
import '../files/composite_file_source.dart';
import '../files/disk_index.dart';
import '../files/file_node.dart';
import '../files/file_transfer.dart';
import '../files/file_transfer.dart';
import '../files/media_file_source.dart';
import '../files/open_path.dart';
import '../files/serve_quota.dart';
import '../files/serve_stats.dart';
import '../log_service.dart';
import '../social/relay_event_store.dart';
import '../social/relay_node.dart';
import '../social/relay_role.dart';
import '../social/spam.dart';
import '../social/store_forward.dart';
import '../social/follow_set.dart';
import '../social/host_retention_policy.dart';
import '../social/retention_tier.dart';
import '../folders/disk_folder_manager.dart';
import '../folders/folder_event.dart' show kKindFolderKeyset, kKindFolderOp;
import '../folders/folder_keystore.dart';
import '../folders/folder_relay.dart';
import '../folders/folder_service.dart';
import '../folders/folder_state.dart';
import '../folders/folder_subscriptions.dart';
import '../../profile/profile_service.dart';
import '../preferences_service.dart';
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

// Our Reticulum destination namespace is "geogram" (the platform); Aurora is one
// branch of it. All overlay services share it: geogram/chat, geogram/files,
// geogram/dht, geogram/relay. (LXMF stays the standard lxmf/delivery for
// interop with Sideband/NomadNet.)
const String _app = 'geogram';
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

  // Store-and-forward hosting: the set of NOSTR pubkeys (hex) the local user
  // follows, used to classify hosted content into the "followed" retention tier.
  // Populated by the APRS wapp bridging its callsign follows (social.follow /
  // social.unfollow). Persisted at [followsPath]; in-memory if unset.
  String? followsPath;
  final FollowSet _follows = FollowSet();
  FollowSet get follows => _follows;

  /// Our own NOSTR pubkey (lowercase hex) from the active profile, or null.
  String? get selfPubHex {
    try {
      final npub = ProfileService.instance.activeProfile?.npub;
      if (npub == null || npub.isEmpty) return null;
      return NostrCrypto.decodeNpub(npub).toLowerCase();
    } catch (_) {
      return null;
    }
  }

  // IPNS-like mutable folders (folder = secp256k1 identity; events on the relay).
  // The keystore (owned master keys) persists at [folderStorePath]; set by the
  // app before start (else in-memory). Browsed states are cached for the wapp.
  String? folderStorePath;
  FolderService? _folders;
  FolderRelay? _folderRelay;
  final Map<String, String> _folderCache = {}; // folderId -> FolderState JSON

  // Per-file serve statistics (times served, bucketed by day) — drives the
  // folder info/stats panel. Persisted at [serveStatsPath]; in-memory if unset.
  String? serveStatsPath;

  // Persistent node identity: the same dest/identity is kept across restarts so
  // peers' learned routes, DHT records and callsign mappings stay valid (a fresh
  // identity each launch made every reconnect look like a brand-new node). The
  // 64-byte private key is stored at [identityPath]; ephemeral if unset.
  String? identityPath;
  ServeStats? _serveStats;
  // Memoized local reductions: re-running reduceFolder (which Ed25519-verifies
  // every op) on each browse — and the tick browses every few seconds — would
  // burn the UI isolate. The op-log is append-only, so the op count is a safe
  // validity key: reuse the cached reduction until a new op appears.
  final Map<String, FolderState> _localReduceCache = {};
  final Map<String, int> _localReduceCount = {};

  // Disk-backed owner folders + consumer subscriptions. Serve source is a
  // composite so disk-folder bytes are served straight from disk (no sqlite
  // copy), alongside the MediaArchive.
  String? diskFoldersPath;
  String? subscriptionsPath;
  // Durable index of files served straight from disk (sha -> path/metadata).
  String? diskIndexPath;
  DiskIndex? _diskIndex;
  CompositeFileSource? _composite;
  DiskFolderManager? _diskMgr;
  FolderSubscriptions? _subs;
  Timer? _diskSyncTimer;
  Timer? _autoSyncTimer;
  Timer? _hostPruneTimer;
  /// Capacity class we advertise in our provider records (set from connectivity:
  /// home/wifi/cellular/ble). Affects how peers rank us. Default unknown.
  int selfCapacity = kCapUnknown;

  bool _up = false;
  bool _starting = false;
  // Count of verified inbound announces — proves a link really speaks Reticulum.
  int _rxAnnounces = 0;
  // callsign -> that peer's chat dest hex (learned from chat announces), for
  // direct media fetch from a known sender.
  final Map<String, String> _callsignDest = {};
  // Local services (identity, store, folders, disk-folder adoption) are built
  // once and survive failed/slow bootstrap connects, so the user's own shared
  // folders are usable offline and a reconnect doesn't rebuild/rescan them.
  bool _localReady = false;
  String _mode = '';
  final List<Map<String, dynamic>> _inbox = [];

  /// Last announced app_data and a periodic re-announce so the node stays
  /// visible to the mesh (and so repeaters keep an "in range" view of it). The
  /// CONTENT is supplied by the caller (e.g. the device callsign) — kept generic.
  String _announceText = 'online';
  Timer? _announceTimer;
  // Adaptive re-announce cadence: frequent when the device is a good always-on
  // citizen (charging AND on Wi-Fi/Ethernet), infrequent otherwise to spare
  // low-bandwidth links and phone batteries. The first announce is immediate
  // (on connect); this only governs the periodic refresh.
  static const Duration _announceFast = Duration(seconds: 30);  // charging + wifi/eth
  static const Duration _announceSlow = Duration(minutes: 5);   // battery / cellular
  Duration _announceInterval() {
    final g = CapacityGovernor.instance;
    final goodNet = g.lastNet == NetKind.wifi || g.lastNet == NetKind.ethernet;
    return (g.lastCharging && goodNet) ? _announceFast : _announceSlow;
  }

  /// Schedule the next periodic re-announce, re-reading the power/network state
  /// each time so the cadence adapts (plug in / move to Wi-Fi → speeds up; unplug
  /// / cellular → slows down) without a fixed timer locking in one rate.
  void _scheduleAnnounce() {
    _announceTimer?.cancel();
    _announceTimer = Timer(_announceInterval(), () {
      if (_up) {
        announce(_announceText);
        _announceServiceDests();
      }
      _scheduleAnnounce();
    });
  }
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
      // ── Local services: built ONCE and kept alive across failed connects, so
      // the user's own disk folders are listable/editable even when the
      // bootstrap is unreachable, and a reconnect never rebuilds or re-scans. ──
      if (!_localReady) {
      _id = await _loadOrCreateIdentity();
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
        // Both the media-archive metric (for archived files) and the serve-stats
        // store (works for disk-folder files too — they're never in the archive).
        onServed: (h) {
          final hex = _hex(h);
          final src = fileServeSource;
          if (src is MediaFileSource) src.archive.incrementDownloads(hex);
          _serveStats?.record(hex, DateTime.now().millisecondsSinceEpoch);
        },
        // Store-and-forward Blossom hosting: a peer asks us to keep a blob.
        onDepositOffer: (sha, size, ext, pubHex, sigHex) {
          if (!hostingActive) return const DepositVerdict.reject('not hosting');
          final src = fileServeSource;
          if (src is! MediaFileSource) {
            return const DepositVerdict.reject('no archive');
          }
          // Verify the compact NOSTR auth binds this depositor to this blob.
          final shaHex = _hex(sha);
          final msg = depositAuthMessageHex(shaHex);
          if (!NostrCrypto.schnorrVerify(msg, sigHex, pubHex)) {
            return const DepositVerdict.reject('bad deposit auth');
          }
          final tier =
              tierOf(pubHex, selfPubHex: selfPubHex, followsHex: _follows.asSet);
          final totals = src.archive.hostedTotals();
          final u = _relayStore?.hostUsage();
          final d = admit(tier, size,
              isMedia: true,
              totalHostedBytes: totals.totalHostedBytes,
              strangerHostedBytes: totals.strangerBytes,
              strangerNotesThisMonth: u?.strangerNotesThisMonth ?? 0,
              q: hostQuota());
          if (!d.ok) return DepositVerdict.reject(d.reason);
          return DepositVerdict.accept(tier.index, pubHex, ext);
        },
        onDepositStore: (sha, bytes, originPubHex, tier, ext) {
          final src = fileServeSource;
          if (src is! MediaFileSource) return;
          src.archive
              .putHosted(bytes, ext, originPubHex: originPubHex, tier: tier);
          // Auto-seed: advertise ourselves as a provider so the network can fetch
          // the blob we now host.
          unawaited(dhtPublish(sha));
          LogService.instance.add(
              'RNS/host: stored ${_hex(sha).substring(0, 8)} '
              '(${bytes.length}B, tier $tier) from '
              '${originPubHex.substring(0, 8)}');
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

      // Per-file serve statistics (best-effort; never blocks node start).
      try {
        _serveStats = ServeStats.open(serveStatsPath ?? ':memory:');
      } catch (e) {
        LogService.instance.add('RNS/stats: disabled ($e)');
        _serveStats = null;
      }

      // Store-and-forward follow set (who we host with "followed" treatment).
      if (followsPath != null) _follows.load(followsPath!);

      // Durable on-disk file index (best-effort).
      try {
        _diskIndex = DiskIndex.open(diskIndexPath ?? ':memory:');
      } catch (e) {
        LogService.instance.add('RNS/diskindex: disabled ($e)');
        _diskIndex = null;
      }

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
          // Host for the network only when the device is willing + capable
          // (settings switch + capacity gate). Toggled live by the capacity
          // callback / settings below.
          serve: hostingActive,
          // Classify an author into a retention tier (0 self / 1 followed /
          // 2 stranger) for hosting quota + eviction.
          tierOfPub: (pub) => tierOf(pub,
              selfPubHex: selfPubHex, followsHex: _follows.asSet).index,
          // Per-tier admission: self always; strangers refused past their
          // monthly note / storage caps. Text notes only here (isMedia false).
          admitEvent: (ev, tier) {
            if (tier == Tier.self.index) return null;
            final store = _relayStore;
            if (store == null) return null;
            final u = store.hostUsage();
            final bytes = jsonEncode(ev.toJson()).length;
            final d = admit(Tier.values[tier], bytes,
                isMedia: false,
                totalHostedBytes: u.totalBytes,
                strangerHostedBytes: u.strangerBytes,
                strangerNotesThisMonth: u.strangerNotesThisMonth,
                q: hostQuota());
            return d.ok ? null : d.reason;
          },
        );
        // A relay role is advertised whenever hosting is enabled; the capacity
        // profile decides leaf vs indexer + which caps (storeForward, archive).
        final p = PreferencesService.instanceSync;
        _relayRole = (p?.hostEnabled ?? true)
            ? RelayRoleManager(
                onChanged: (_) => _announceRelayDest(),
              )
            : null;
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
            unregisterSource: (src) => _composite?.remove(src),
            registryPath: diskFoldersPath ?? ':memory:',
            indexFiles: (folderId, files) {
              final di = _diskIndex;
              if (di == null) return;
              di.replaceFolder(folderId, [
                for (final f in files)
                  DiskIndexEntry(
                      f.sha, f.path, f.size, f.mtimeMs, folderId, f.name)
              ]);
            },
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
      await CapacityGovernor.instance.start(apply: (p) {
        selfCapacity = p.capacity;
        final q = _files?.serveQuota;
        if (q != null) p.applyTo(q);
        _relayRole?.applyCapacity(p);
        // Flip relay hosting on/off as power/network changes (capacity gate).
        if (_relay != null) _relay!.serve = hostingActive;
      });

      // Re-index owned disk folders so on-disk edits get signed + synced. Runs
      // even before/without a connection, so local browsing reflects disk edits
      // and the changes upload as soon as a link comes up.
      _diskSyncTimer?.cancel();
      _diskSyncTimer = Timer.periodic(const Duration(seconds: 60), (_) {
        if (_diskMgr != null) _diskMgr!.syncAll();
      });

      // Tier-aware retention sweep: drop hosted stranger text past its retention
      // age (our own + followed text are never pruned). Hourly is plenty; the
      // LXMF mailbox + media archive get their own sweeps.
      _hostPruneTimer?.cancel();
      _hostPruneTimer = Timer.periodic(const Duration(hours: 1), (_) {
        final store = _relayStore;
        if (store == null) return;
        final days = PreferencesService.instanceSync?.hostStrangerRetentionDays ?? 1825;
        try {
          final n = store.pruneHosted(strangerMaxAge: Duration(days: days));
          if (n > 0) LogService.instance.add('RNS/relay: pruned $n stranger note(s)');
          store.sfPrune();
          // Tier-aware media eviction: drop hosted stranger blobs past retention,
          // and, only under ceiling pressure, followed-people's media (largest
          // first). Our own media (hosted=0) is never in this inventory.
          final src = fileServeSource;
          if (src is MediaFileSource) {
            final inv = src.archive.hostedInventory();
            if (inv.isNotEmpty) {
              final items = [
                for (final r in inv)
                  StoredItem(r.sha, Tier.values[r.tier.clamp(0, 2)], r.bytes,
                      r.receivedAtMs, true)
              ];
              final del = planEviction(items, hostQuota(),
                  nowMs: DateTime.now().millisecondsSinceEpoch);
              for (final id in del) {
                src.archive.delete(id);
              }
              if (del.isNotEmpty) {
                LogService.instance
                    .add('RNS/host: evicted ${del.length} hosted blob(s)');
              }
            }
          }
        } catch (_) {}
      });

      _localReady = true;
      } // end if (!_localReady)

      // ── Network interface: (re)connect to the bootstrap. Cheap now that local
      // services exist — a failed connect is just retried, no rebuild/rescan. ──
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
            throw StateError('BLE5 extended advertising unsupported');
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
          throw StateError('unknown mode $mode');
      }

      _up = true;
      await announce(announceName);
      await _announceServiceDests();

      // Validate the bootstrap really speaks Reticulum before declaring "up": a
      // live hub floods cryptographically-signed announces; a wrong/dead/non-RNS
      // endpoint (e.g. a web server that accepts the TCP connect) never will.
      // We announce first so even a quiet hub routes traffic back to us.
      if (mode == 'tcpclient' &&
          !await _awaitRnsTraffic(const Duration(seconds: 8))) {
        LogService.instance.add(
            'RNS: $host:$port connected but spoke no Reticulum — trying next');
        _up = false;
        for (final i in _ifaces) {
          _transport?.removeInterface(i);
        }
        _client?.close();
        _client = null;
        _ifaces.clear();
        return false;
      }

      LogService.instance
          .add('RNS: node up mode=$mode id=${_id!.hexHash} dest=$destHex');
      _scheduleAnnounce();
      _republishTimer?.cancel();
      _republishTimer = Timer.periodic(_republishEvery, (_) {
        if (_up) _files?.republishAll();
      });
      // Pull newer versions of files the user downloaded from auto-sync folders.
      _autoSyncTimer?.cancel();
      _autoSyncTimer = Timer.periodic(const Duration(minutes: 5), (_) {
        if (_up) _autoSyncTick();
      });
      return true;
    } catch (e) {
      LogService.instance.add('RNS: start error: $e');
      // Only the connect attempt failed — keep the local services (disk folders
      // stay usable offline) and just clean up the half-open interface so the
      // next retry reconnects without rebuilding or re-scanning anything.
      try {
        await _server?.close();
      } catch (_) {}
      _server = null;
      _client?.close();
      _client = null;
      _ifaces.clear();
      _up = false;
      return false;
    } finally {
      _starting = false;
    }
  }

  /// Load the persisted node identity (64-byte private key at [identityPath]),
  /// or generate one and save it. Keeps the device's Reticulum address stable
  /// across restarts so peers don't have to re-learn it every launch.
  Future<RnsIdentity> _loadOrCreateIdentity() async {
    final path = identityPath;
    if (path != null && path.isNotEmpty) {
      try {
        final f = File(path);
        if (f.existsSync()) {
          final prv = f.readAsBytesSync();
          if (prv.length == 64) {
            final id = await RnsIdentity.fromPrivateKey(Uint8List.fromList(prv));
            LogService.instance.add('RNS: loaded identity ${id.hexHash}');
            return id;
          }
        }
      } catch (e) {
        LogService.instance.add('RNS: identity load failed ($e) — regenerating');
      }
    }
    final id = await RnsIdentity.generate();
    final prv = id.getPrivateKey();
    if (path != null && path.isNotEmpty && prv != null) {
      try {
        final f = File(path);
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(prv, flush: true);
        LogService.instance.add('RNS: new identity ${id.hexHash} (saved)');
      } catch (e) {
        LogService.instance.add('RNS: identity save failed ($e)');
      }
    }
    return id;
  }

  /// Wait up to [window] for at least one verified inbound RNS announce — proof
  /// the freshly-connected interface is genuinely talking Reticulum. Returns as
  /// soon as one arrives. Bails early if the node was torn down.
  Future<bool> _awaitRnsTraffic(Duration window) async {
    final base = _rxAnnounces;
    final deadline = DateTime.now().add(window);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (_rxAnnounces > base) return true;
      if (!_up) return false;
    }
    return _rxAnnounces > base;
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
    // A cryptographically-valid announce proves the link really speaks
    // Reticulum (a wrong/dead endpoint can't forge one) — used to validate a
    // bootstrap before declaring the node up.
    _rxAnnounces++;
    // Skip our own announces.
    if (_id != null &&
        RnsCrypto.constantTimeEquals(ann.identity.hash, _id!.hash)) {
      return;
    }
    // Learn the peer as a DHT contact ONLY from its DHT-destination announce.
    // Aurora is (currently) the only overlay running a DHT on Reticulum, so the
    // hub is full of Sideband/NomadNet/rnsd identities that do NOT run it. We
    // identify the ones that DO purely from the wire: an Aurora node announces a
    // destination named "aurora/dht" (see _announceServiceDests), and the signed
    // announce's destHash cryptographically binds that name to the announcing
    // identity. So a destHash that equals hash(identity, "aurora", ["dht"]) is
    // proof the peer runs our DHT — no guessing, no probing dead nodes. Other
    // identities are simply never added, so lookups don't waste rounds timing
    // out on nodes that can't answer.
    final dhtHash = RnsDestination.hash(ann.identity, _app, _aspectsDht);
    if (RnsCrypto.constantTimeEquals(ann.destHash, dhtHash)) {
      _files?.addPeerFromAnnounce(ann.identity);
    }
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
    // Map a peer's callsign (the appData of its CHAT announce) -> that peer's
    // chat dest, so media referenced in its messages can be fetched DIRECTLY
    // from it over Reticulum. Direct fetch from the known sender is far more
    // reliable than the file-DHT on a large foreign public testnet (where the
    // XOR-closest provider nodes are reference nodes that ignore our overlay).
    final chatHash = RnsDestination.hash(ann.identity, _app, _aspects);
    if (RnsCrypto.constantTimeEquals(ann.destHash, chatHash)) {
      final cs = text.trim();
      if (cs.isNotEmpty && cs.length <= 20 && !cs.contains(' ')) {
        _callsignDest[cs] = _hex(ann.destHash);
      }
    }
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

  /// Fetch a file by sha256 DIRECTLY from a peer identified by its [callsign]
  /// (learned from its chat announce). Returns null if we haven't heard that
  /// callsign announce or the fetch fails. The reliable cross-network path for
  /// media referenced in a known sender's message.
  Future<Uint8List?> fetchFileFromCallsign(
    Uint8List fileHash,
    String callsign, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final dest = _callsignDest[callsign.trim()];
    if (dest == null) {
      LogService.instance.add('RNS/files: no route to callsign "$callsign"');
      return null;
    }
    return fetchFileFrom(fileHash, dest, timeout: timeout);
  }

  /// Deposit [bytes] to a host (identified by its [peerDestHex]) for
  /// store-and-forward hosting. We sign a compact NOSTR auth with our profile key
  /// so the host can classify our tier. Returns true if the host stored it.
  Future<bool> depositFileTo(
    Uint8List bytes,
    String ext,
    String peerDestHex, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final f = _files;
    if (!_up || f == null) return false;
    final privHex = _profilePrivHex();
    final pubHex = selfPubHex;
    if (privHex == null || pubHex == null) {
      LogService.instance.add('RNS/host: cannot deposit (no profile key)');
      return false;
    }
    final dh = _bytesFromHex(peerDestHex);
    if (dh == null) return false;
    final entry = _transport?.pathFor(dh);
    if (entry == null) {
      LogService.instance.add('RNS/host: no path to $peerDestHex');
      return false;
    }
    final sha = Uint8List.fromList(crypto.sha256.convert(bytes).bytes);
    final shaHex = _hex(sha);
    final sigHex = NostrCrypto.schnorrSign(depositAuthMessageHex(shaHex), privHex);
    final pub = _bytesFromHex(pubHex);
    final sig = _bytesFromHex(sigHex);
    if (pub == null || pub.length != 32 || sig == null || sig.length != 64) {
      return false;
    }
    return f.deposit(sha, bytes, ext, pub, sig, entry.identity, timeout: timeout);
  }

  /// Deposit to a host by its [callsign] (route learned from its chat announce).
  Future<bool> depositFileToCallsign(Uint8List bytes, String ext, String callsign,
      {Duration timeout = const Duration(seconds: 60)}) async {
    final dest = _callsignDest[callsign.trim()];
    if (dest == null) {
      LogService.instance.add('RNS/host: no route to callsign "$callsign"');
      return false;
    }
    return depositFileTo(bytes, ext, dest, timeout: timeout);
  }

  /// Read a file WE host locally by its sha256 — from the media archive or any
  /// shared disk folder (the same composite source we serve to peers). Lets the
  /// sender render a shared-folder image it referenced (which isn't in the
  /// archive) by copying the bytes in. Null if we don't hold it.
  Uint8List? localFileBytes(Uint8List fileHash) => _composite?.read(fileHash);

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
  /// Store one of OUR chat messages (a group bulletin or an Activity post) as a
  /// signed NOSTR note (kind 1) in the relay, so other nodes can request our
  /// posts later. [topic] tags the group/context for search. Self-tier (never
  /// evicted). No-op without a profile key or text. Returns the event id.
  Future<String?> publishNote(String text, {String? topic}) async {
    final t = text.trim();
    final pub = selfPubHex;
    final priv = _profilePrivHex();
    if (t.isEmpty || pub == null || priv == null) return null;
    final tags = <List<String>>[];
    if (topic != null && topic.isNotEmpty) tags.add(['t', topic]);
    final ev = NostrEvent(
      pubkey: pub,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: NostrEventKind.textNote,
      tags: tags,
      content: t,
    );
    try {
      ev.sign(priv);
    } catch (e) {
      LogService.instance.add('RNS/relay: note sign failed: $e');
      return null;
    }
    await relayPublish(ev.toJson());
    return ev.id;
  }

  Future<bool> relayPublish(Map<String, dynamic> eventJson) async {
    final store = _relayStore;
    if (store == null) return false;
    final ev = NostrEvent.fromJson(eventJson);
    // Locally-published events are classified by author like any other, so our
    // own notes get the self tier (never evicted) and a followed author we
    // re-publish keeps the followed tier.
    final tier = tierOf(ev.pubkey, selfPubHex: selfPubHex, followsHex: _follows.asSet);
    final stored = store.put(ev, tier: tier.index);
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

  // ── Store-and-forward follow set (NOSTR-follow tier) ──────────────────────
  /// Mark [key] (hex / npub / base64url pubkey) as followed — its hosted notes
  /// and files get the "followed" retention tier (kept; media evicted only under
  /// pressure). Bridged from the APRS wapp's callsign follows.
  void followPubkey(String key) => _follows.add(key);

  /// Drop [key] from the follow set.
  void unfollowPubkey(String key) => _follows.remove(key);

  /// True if [pubHex] (64-char hex) is followed.
  bool isFollowedPubkey(String pubHex) => _follows.contains(pubHex);

  /// The current host quota built from user settings (whole-node ceiling,
  /// strangers' slice + note cap + retention). Used by the relay/archive tiering.
  HostQuota hostQuota() {
    final p = PreferencesService.instanceSync;
    final ceilingGb = p?.hostCeilingGb ?? 100;
    final sliceGb = p?.hostStrangerSliceGb ?? 100;
    final notes = p?.hostStrangerNotesPerMonth ?? 1000;
    final days = p?.hostStrangerRetentionDays ?? 1825;
    return HostQuota(
      ceilingBytes: ceilingGb * (1 << 30),
      strangerSliceBytes: sliceGb * (1 << 30),
      strangerNotesPerMonth: notes,
      strangerRetentionMs: days * 24 * 60 * 60 * 1000,
    );
  }

  /// Whether this node should HOST for others right now: master switch on, and
  /// (if capacity-gated) only when the device is an unlimited provider (charging
  /// on Wi-Fi/Ethernet). Drives serve-mode + relay-role advertisement.
  bool get hostingActive {
    final p = PreferencesService.instanceSync;
    if (!(p?.hostEnabled ?? true)) return false;
    if (!(p?.hostCapacityGated ?? true)) return true;
    return CapacityGovernor.instance.lastProfile?.unlimited ?? false;
  }

  /// Re-apply hosting settings live (call after the Settings switch changes):
  /// flip serve on/off and create or drop the advertised relay role.
  void applyHostingSettings() {
    if (_relay == null) return;
    _relay!.serve = hostingActive;
    final enabled = PreferencesService.instanceSync?.hostEnabled ?? true;
    if (enabled && _relayRole == null) {
      _relayRole = RelayRoleManager(onChanged: (_) => _announceRelayDest());
      final prof = CapacityGovernor.instance.lastProfile;
      if (prof != null) _relayRole!.applyCapacity(prof);
      _announceRelayDest();
    } else if (!enabled) {
      _relayRole = null;
    }
  }

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
            name: op['name'] as String?,
            desc: op['desc'] as String?,
            tags: op['tags'] as String?);
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

  /// Stop sharing an owned disk folder: unregister its disk source, drop it from
  /// the owned list/registry and clear its caches. The on-disk files are left
  /// untouched (only sharing stops). No-op for folders we don't own.
  void folderRemove(String folderIdOrNpub) {
    final folderId = _normFolderId(folderIdOrNpub);
    _diskMgr?.removeDisk(folderId);
    _folderCache.remove(folderId);
    _localReduceCache.remove(folderId);
    _localReduceCount.remove(folderId);
    _folderRefreshAt.remove(folderId);
  }

  /// Owned folders (we hold the master key): [{folderId, npub, name}].
  List<Map<String, dynamic>> folderList() {
    final f = _folders;
    if (f == null) return const [];
    return [
      for (final k in f.ownedFolders())
        {
          'folderId': k.folderId,
          'npub': k.npub,
          'name': k.name,
          // Disk-backed folders can be opened in the OS file manager to edit.
          'onDisk': _diskMgr?.owns(k.folderId) == true,
        }
    ];
  }

  /// Open an owned disk folder's directory in the OS file manager so the user can
  /// edit its files directly (changes sync on the next re-scan). Returns true if
  /// it's a known disk folder (the open itself runs asynchronously).
  bool folderOpenDir(String folderIdOrNpub) {
    final folderId = _normFolderId(folderIdOrNpub);
    final dir = _diskMgr?.dirOf(folderId);
    if (dir == null || dir.isEmpty) return false;
    unawaited(openFolderOnDisk(dir));
    return true;
  }

  /// The cached state of a folder (may be empty until the first refresh). Always
  /// kicks off a background refresh so the next call returns fresh data.
  // Throttle network refreshes per folder so the wapp's periodic browse (every
  // few seconds) doesn't fire a relay query each time.
  final Map<String, int> _folderRefreshAt = {};

  Map<String, dynamic> folderBrowse(String folderIdOrNpub) {
    final folderId = _normFolderId(folderIdOrNpub);
    // For folders we own, the local store IS the source of truth — never hit the
    // network. Re-querying the relay re-stored our own ops, which grew the op
    // count, invalidated the reduce cache, forced a re-verify of every signature
    // on the UI isolate and a re-render — that was the scroll lag. For consumed
    // folders, refresh at most every 20s.
    final owned = _diskMgr?.owns(folderId) == true;
    if (!owned) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - (_folderRefreshAt[folderId] ?? 0) > 20000) {
        _folderRefreshAt[folderId] = now;
        folderRefresh(folderId);
      }
    }
    // Reduce the local op-log synchronously (cached by op count) — the real
    // current contents.
    final local = _localFolderStateSync(folderId);
    if (local.files.isNotEmpty ||
        local.links.isNotEmpty ||
        local.name != null ||
        _diskMgr?.owns(folderId) == true) {
      return local.toJson();
    }
    final cached = _folderCache[folderId];
    if (cached == null) return {'folderId': folderId};
    try {
      return jsonDecode(cached) as Map<String, dynamic>;
    } catch (_) {
      return {'folderId': folderId};
    }
  }

  /// Browse ONE directory level of a folder: the immediate subfolders and the
  /// files directly at [path] (which is "" for the root, else ends with '/').
  /// File `name` keeps its full relative path (so a download recreates the tree)
  /// and `base` is the leaf name for display. This keeps the payload — and the
  /// wapp's work — proportional to one level, not the whole folder. Each file
  /// also carries `dl` (times served) for the stats panel.
  Map<String, dynamic> folderBrowseLevel(String folderIdOrNpub, String path) {
    final folderId = _normFolderId(folderIdOrNpub);
    final full = folderBrowse(folderId);
    final files = (full['files'] as List?) ?? const [];
    final pl = path.length;
    final dirs = <String>{};
    final outFiles = <Map<String, dynamic>>[];
    for (final f in files) {
      if (f is! Map) continue;
      final name = (f['name'] as String?) ?? '';
      if (name.isEmpty) continue;
      if (pl > 0 && !name.startsWith(path)) continue;
      final rest = name.substring(pl);
      final slash = rest.indexOf('/');
      if (slash >= 0) {
        dirs.add(rest.substring(0, slash));
      } else {
        final m = Map<String, dynamic>.from(f);
        m['base'] = rest;
        m['dl'] = _serveStats?.countFor((f['x'] as String?) ?? '') ?? 0;
        outFiles.add(m);
      }
    }
    final dirList = dirs.toList()..sort();
    return {
      'folderId': folderId,
      'npub': NostrCrypto.encodeNpub(folderId),
      if (full['name'] != null) 'name': full['name'],
      if (full['owner'] != null) 'owner': full['owner'],
      'owned': _diskMgr?.owns(folderId) == true,
      'path': path,
      'dirs': [for (final d in dirList) {'name': d}],
      'files': outFiles,
      if (pl == 0) 'links': full['links'] ?? const [],
    };
  }

  /// Folder info + serve statistics for the info panel: the shareable key, the
  /// file count and total bytes, and how often the folder's files have been
  /// served (all-time + last 24h / 7d / 30d, plus the most-served files).
  Map<String, dynamic> folderStats(String folderIdOrNpub) {
    final folderId = _normFolderId(folderIdOrNpub);
    final full = folderBrowse(folderId);
    final files = (full['files'] as List?) ?? const [];
    final shas = <String>[];
    var totalBytes = 0;
    final nameOf = <String, String>{};
    for (final f in files) {
      if (f is! Map) continue;
      final x = (f['x'] as String?) ?? '';
      if (x.isNotEmpty) {
        shas.add(x);
        final nm = (f['name'] as String?) ?? x;
        nameOf[x] = nm;
      }
      final s = f['size'];
      if (s is int) totalBytes += s;
    }
    final st = _serveStats?.forShas(
            shas, DateTime.now().millisecondsSinceEpoch) ??
        const FolderServeStats();
    return {
      'folderId': folderId,
      'npub': NostrCrypto.encodeNpub(folderId),
      if (full['name'] != null) 'name': full['name'],
      if (full['desc'] != null) 'desc': full['desc'],
      if (full['tags'] != null) 'tags': full['tags'],
      if (full['owner'] != null) 'owner': full['owner'],
      'owned': _diskMgr?.owns(folderId) == true,
      'fileCount': files.length,
      'totalBytes': totalBytes,
      'serves': st.totalServes,
      'last24h': st.last24h,
      'last7d': st.last7d,
      'last30d': st.last30d,
      'activeDays': st.days,
      'top': [
        for (final e in st.top)
          {'name': nameOf[e.key] ?? e.key, 'serves': e.value}
      ],
    };
  }

  /// Reduce a folder's current state from the LOCAL event store, synchronously
  /// (store.query is sync). Authoritative for owned folders.
  FolderState _localFolderStateSync(String folderId) {
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
    // The op-log only grows, so a stable (op count) means an unchanged
    // reduction — skip re-verifying every signature.
    final n = ops.length + ks.length;
    if (_localReduceCount[folderId] == n) {
      final cached = _localReduceCache[folderId];
      if (cached != null) return cached;
    }
    final st = reduceFolder(folderId, ks.isEmpty ? null : ks.first, ops);
    _localReduceCache[folderId] = st;
    _localReduceCount[folderId] = n;
    return st;
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
  Future<FolderState> _localFolderState(String folderId) async =>
      _localFolderStateSync(folderId);

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

  /// Whether the folder/disk-sharing layer is live (the Reticulum node is up).
  // Folder ops work as soon as the LOCAL services exist — no live link needed
  // (sharing/listing/editing disk folders is local; the network only carries
  // the sync). So this no longer requires _up.
  bool get foldersReady => _localReady && _diskMgr != null && _folders != null;

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
    _serveStats?.close();
    _serveStats = null;
    _folders = null;
    _folderRelay = null;
    _folderCache.clear();
    _localReduceCache.clear();
    _localReduceCount.clear();
    _diskSyncTimer?.cancel();
    _diskSyncTimer = null;
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
    _hostPruneTimer?.cancel();
    _hostPruneTimer = null;
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
    _localReady = false;
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
