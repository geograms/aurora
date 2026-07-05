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
import '../files/dht/provider_record.dart'
    show kCapUnknown, kCapArchive, kCapHomeWifi;
import '../files/composite_file_source.dart';
import '../files/disk_index.dart';
import '../files/file_node.dart';
import '../files/file_transfer.dart';
import '../files/media_file_source.dart';
import '../files/open_path.dart';
import '../files/partial_store.dart';
import '../files/serve_quota.dart';
import '../files/serve_stats.dart';
import '../log_service.dart';
import '../social/relay_event_store.dart';
import '../social/relay_node.dart';
import '../social/relay_role.dart';
import '../social/spam.dart';
import '../social/store_forward.dart';
import '../social/follow_set.dart';
import '../social/nostr_relay.dart';
import '../social/host_retention_policy.dart';
import '../social/retention_tier.dart';
import '../folders/disk_folder_manager.dart';
import '../folders/folder_event.dart'
    show kKindFolderKeyset, kKindFolderOp, FolderShareType;
import '../folders/folder_keystore.dart';
import '../folders/folder_relay.dart';
import '../folders/folder_service.dart';
import '../folders/folder_state.dart';
import '../folders/folder_subscriptions.dart';
import '../../profile/profile_service.dart';
import '../preferences_service.dart';
import '../../util/nostr_crypto.dart';
import '../../util/nostr_event.dart';
import '../../util/aprx_sign.dart';
import 'lxmf/lxmf.dart'
    show kLxmfApp, kLxmfDeliveryAspects, kLxmfPropagationAspects;
import 'lxmf/lxmf_message.dart';
import 'lxmf/lxmf_router.dart';
import 'observed_store.dart';
import 'rns_announce.dart';
import 'rns_ble_interface.dart';
import 'rns_crypto.dart';
import 'rns_identity.dart';
import 'rns_packet.dart';
import 'rns_lan_interface.dart';
import 'rns_tcp_interface.dart';
import 'rns_tcp_server_interface.dart';
import 'rns_transport.dart';

// Our Reticulum destination namespace is "geogram" (the platform); Aurora is one
// branch of it. All overlay services share it: geogram/chat, geogram/files,
// geogram/dht, geogram/relay. (LXMF stays the standard lxmf/delivery for
// interop with Sideband/NomadNet.)
const String _app = 'geogram';
const List<String> _aspects = ['chat'];
// Dedicated destination for wapp-to-wapp datagrams (circles, etc.), kept off the
// chat/files/dht/relay destinations so its traffic demultiplexes cleanly.
const List<String> _aspectsWapp = ['wapp'];

class RnsService {
  RnsService._();
  static final RnsService instance = RnsService._();

  RnsIdentity? _id;
  Uint8List? _destHash;
  RnsTransport? _transport;
  final List<RnsInterface> _ifaces = [];
  RnsTcpServerInterface? _server;
  // Loopback "shared instance" so other geogram apps (e.g. GNPA) route through
  // this node instead of each running their own Reticulum stack.
  RnsTcpServerInterface? _gateway;
  // Hub uplinks (tcpclient). We connect to ALL reachable bootstrap hubs at once
  // — a mesh, not first-wins — so two devices that each reach a different subset
  // still share at least one hub and can find each other (different community
  // hubs don't reliably bridge announces between themselves). _connectedHubs is
  // the set of "host:port" we currently hold an uplink to (top-up is idempotent).
  final List<RnsTcpInterface> _clients = [];
  final Set<String> _connectedHubs = {};

  /// Called when the hub uplink (tcpclient) drops — the socket errored/closed or
  /// went silent (e.g. the device's network changed). The owner (rns_autostart)
  /// wires this to kick an immediate reconnect across the bootstrap hub list.
  void Function()? onLinkDown;
  // Wall-clock of the last inbound packet on any interface; a live hub floods
  // announces continuously, so a long silence while "up" means the uplink died
  // (a network change often kills the socket without a clean close). The
  // watchdog reconnects on that silence.
  int _lastInboundMs = 0;
  Timer? _linkWatchdog;
  static const Duration _linkSilenceTimeout = Duration(seconds: 30);
  // LAN auto-peering interface for same-LAN discovery (co-located devices):
  // announces broadcast, data unicast to learned peers (no broadcast storm).
  RnsLanInterface? _lan;
  // Fixed UDP port every Aurora node broadcasts/listens on for LAN auto-peering.
  static const int _lanDiscoveryPort = 42671;

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
  /// JSON sidecar persisting the discovered callsign->identity map across
  /// restarts (set by the app before start). Without it, a joining/returning node
  /// re-pays minutes of announce-discovery before it can query peers for their
  /// notes (group/Activity backfill); restoring it lets backfill query known
  /// posters immediately on launch.
  String? callPeersPath;
  Timer? _callPeersSaveTimer;
  /// Directory for resumable-download partials (set by the app before start). When
  /// set, fetches survive a drop/app-restart by resuming from the last completed
  /// segment; unset = today's in-memory, all-or-nothing behaviour.
  String? partialStoreDir;
  PartialStore? _partialStore;
  RelayEventStore? _relayStore;
  RelayNode? _relay;
  final RelayDirectory _relayDir = RelayDirectory();
  RelayRoleManager? _relayRole;
  StoreForward? _storeForward;
  // NOSTR relay pipeline — runs entirely on a background isolate (NostrEngine);
  // this proxy just sends commands + reads caches. Plus the LAN wss server.
  NostrClient? _nostrHub;
  NostrWsServer? _nostrWs;

  // Store-and-forward hosting: the set of NOSTR pubkeys (hex) the local user
  // follows, used to classify hosted content into the "followed" retention tier.
  // Populated by the APRS wapp bridging its callsign follows (social.follow /
  // social.unfollow). Persisted at [followsPath]; in-memory if unset.
  String? followsPath;
  final FollowSet _follows = FollowSet();
  FollowSet get follows => _follows;

  /// Our own NOSTR pubkey (lowercase hex) from the active profile, or null.
  // Cache the decoded self pubkey: decodeNpub is bech32 work and this getter is
  // called on hot paths (per event for tiering, per relay link). Re-derive only
  // when the active profile's npub changes.
  String? _selfPubCacheNpub;
  String? _selfPubCacheHex;
  String? get selfPubHex {
    try {
      final npub = ProfileService.instance.activeProfile?.npub;
      if (npub == null || npub.isEmpty) return null;
      if (npub == _selfPubCacheNpub) return _selfPubCacheHex;
      final hex = NostrCrypto.decodeNpub(npub).toLowerCase();
      _selfPubCacheNpub = npub;
      _selfPubCacheHex = hex;
      return hex;
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
  // Wall-clock the node first came up this run; drives the advertised uptime
  // (relay announce + /api/rns/status) peers use to rank stable nodes.
  DateTime? _startedAt;
  // Count of verified inbound announces — proves a link really speaks Reticulum.
  int _rxAnnounces = 0;
  // callsign -> that peer's chat dest hex (learned from chat announces), for
  // direct media fetch from a known sender.
  final Map<String, String> _callsignDest = {};

  // callsign -> that peer's full RNS identity (learned from its chat announce).
  // Lets us derive the peer's relay destination and fetch its NOSTR events
  // (e.g. its kind-0 profile) DIRECTLY from it — no third-party indexer needed.
  final Map<String, RnsIdentity> _callIdentity = {};

  // callsign -> that peer's NOSTR pubkey (hex), bridged from the APRS wapp's
  // pubkey beacons (social.identity). Drives the npub shown on Activity posts
  // and the profile screen.
  final Map<String, String> _callPub = {};
  void recordCallsignPubkey(String callsign, String? key) {
    final c = callsign.trim();
    if (c.isEmpty || key == null || key.isEmpty) return;
    final hex = FollowSet.toHex(key); // accepts hex / npub / base64url
    if (hex != null) {
      _callPub[c] = hex;
      // Learning a followed callsign's key may unblock fetching its profile.
      _maybeFetchFollowedProfile(c);
    }
  }

  String? pubkeyForCallsign(String callsign) => _callPub[callsign.trim()];

  /// The bech32 npub for [callsign] if we've learned its key, else null.
  String? npubForCallsign(String callsign) {
    final h = _callPub[callsign.trim()];
    if (h == null) return null;
    try {
      return NostrCrypto.encodeNpub(h);
    } catch (_) {
      return null;
    }
  }

  /// The people this device knows, as pickable contacts — those seen on APRS
  /// (callsign↔pubkey, from [_callPub]) and those followed ([_follows]), each
  /// {npub, callsign, nick}. [query] filters case-insensitively across all three
  /// (empty = everyone); the result is sorted by callsign. Generic and exposed to
  /// wapps via the hal_contacts_* HAL so any wapp can offer an "add from contacts"
  /// picker. A callsign is always derivable from the key (X1<short>), and the
  /// observed APRS callsign overrides it when known.
  List<Map<String, dynamic>> contacts(String query) {
    final q = query.trim().toLowerCase();
    final byPub = <String, Map<String, dynamic>>{};
    String nickFor(String hex) {
      final ev = _relayStore?.profileOf(hex);
      if (ev == null) return '';
      try {
        final m = jsonDecode(ev.content);
        if (m is Map) {
          final n = m['display_name'] ?? m['name'];
          if (n is String && n.trim().isNotEmpty) return n.trim();
        }
      } catch (_) {}
      return '';
    }

    void add(String hex, {String? callsign}) {
      hex = hex.toLowerCase();
      if (hex.length != 64) return;
      final e = byPub.putIfAbsent(
          hex,
          () => <String, dynamic>{
                'npub': NostrCrypto.encodeNpub(hex),
                'callsign': '',
                'nick': '',
              });
      if (callsign != null && callsign.trim().isNotEmpty) {
        e['callsign'] = callsign.trim();
      }
      if ((e['callsign'] as String).isEmpty) {
        e['callsign'] = 'X1${NostrCrypto.deriveCallsign(hex)}';
      }
      if ((e['nick'] as String).isEmpty) e['nick'] = nickFor(hex);
    }

    _callPub.forEach((cs, hex) => add(hex, callsign: cs));
    for (final hex in _follows.asSet) {
      add(hex);
    }

    var list = byPub.values.toList();
    if (q.isNotEmpty) {
      list = list
          .where((e) =>
              (e['npub'] as String).toLowerCase().contains(q) ||
              (e['callsign'] as String).toLowerCase().contains(q) ||
              (e['nick'] as String).toLowerCase().contains(q))
          .toList();
    }
    list.sort((a, b) =>
        (a['callsign'] as String).compareTo(b['callsign'] as String));
    return list;
  }

  /// People search for the Messages "find a user" box: the union of our local
  /// database ([contacts] — callsign↔pubkey + follows) and everyone currently
  /// visible on the Reticulum network (the observed-announce registry, matched by
  /// callsign). [query] is a case-insensitive callsign/nick/npub substring; an
  /// empty query returns nothing (the caller shows the conversation list). Each
  /// entry is {npub, callsign, nick, online, devices}: `online` is true when at
  /// least one of the person's devices announced within [_onlineWindowMs] and
  /// `devices` is how many distinct Reticulum identities announce under the
  /// callsign. Sorted online-first, then by callsign. Generic (people/RNS), so it
  /// belongs on the host, not in any one wapp.
  List<Map<String, dynamic>> searchPeople(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final now = DateTime.now().millisecondsSinceEpoch;

    // Aggregate the observed-announce registry (the live network) by callsign:
    // device count + whether any device is currently online, keyed by uppercased
    // callsign with the original case preserved for display.
    final devCount = <String, int>{};
    final anyOnline = <String, bool>{};
    final callCase = <String, String>{};
    for (final n in _observed.values) {
      final cs = (n.callsign ?? '').trim();
      if (cs.isEmpty) continue;
      final key = cs.toUpperCase();
      callCase[key] = cs;
      devCount[key] = (devCount[key] ?? 0) + 1;
      if (now - n.lastSeenMs < _onlineWindowMs) anyOnline[key] = true;
    }

    final byCall = <String, Map<String, dynamic>>{};
    void put(String callsign, String npub, String nick) {
      final key = callsign.trim().toUpperCase();
      if (key.isEmpty) return;
      final e = byCall.putIfAbsent(
          key,
          () => <String, dynamic>{
                'npub': npub,
                'callsign': callsign.trim(),
                'nick': nick,
                'online': anyOnline[key] ?? false,
                'devices': devCount[key] ?? 0,
              });
      if ((e['npub'] as String).isEmpty && npub.isNotEmpty) e['npub'] = npub;
      if ((e['nick'] as String).isEmpty && nick.isNotEmpty) e['nick'] = nick;
    }

    // 1) Local database (already query-filtered, carries npub + nick).
    for (final e in contacts(query)) {
      put(e['callsign'] as String, (e['npub'] as String?) ?? '',
          (e['nick'] as String?) ?? '');
    }
    // 2) Reticulum network: observed callsigns matching the query (npub only when
    //    we happen to also know it locally — announces carry the callsign, not the
    //    NOSTR key).
    for (final entry in callCase.entries) {
      if (!entry.value.toLowerCase().contains(q)) continue;
      final pub = pubkeyForCallsign(entry.value);
      put(entry.value, pub != null ? NostrCrypto.encodeNpub(pub) : '', '');
    }

    final list = byCall.values.toList();
    list.sort((a, b) {
      final ao = (a['online'] as bool) ? 0 : 1;
      final bo = (b['online'] as bool) ? 0 : 1;
      if (ao != bo) return ao - bo;
      return (a['callsign'] as String).compareTo(b['callsign'] as String);
    });
    return list;
  }

  /// The Reticulum devices a user is using, for the profile panel's device list.
  /// [callsign] is matched against the observed-announce registry — each distinct
  /// identity that announces under the callsign is one device (a user's phone,
  /// dongle, desktop … all beacon the same callsign). Returns, freshest-first,
  /// {dest, hops, ageSec, online, services, via}: `dest` is the short identity
  /// hash, `ageSec` is seconds since its last announce, `online` is true within
  /// the freshness window. Empty when we've never heard the callsign on the mesh.
  List<Map<String, dynamic>> devicesForCallsign(String callsign) {
    final want = callsign.trim().toUpperCase();
    if (want.isEmpty) return const [];
    final now = DateTime.now().millisecondsSinceEpoch;
    final out = <Map<String, dynamic>>[];
    for (final n in _observed.values) {
      if ((n.callsign ?? '').trim().toUpperCase() != want) continue;
      out.add(<String, dynamic>{
        'dest': n.identityHex,
        'hops': n.hops,
        'ageSec': ((now - n.lastSeenMs) / 1000).round(),
        'online': now - n.lastSeenMs < _onlineWindowMs,
        'services': (n.services.toList()..sort()).join(', '),
        'via': n.via,
      });
    }
    out.sort((a, b) => (a['ageSec'] as int).compareTo(b['ageSec'] as int));
    return out;
  }

  // Local services (identity, store, folders, disk-folder adoption) are built
  // once and survive failed/slow bootstrap connects, so the user's own shared
  // folders are usable offline and a reconnect doesn't rebuild/rescan them.
  bool _localReady = false;
  String _mode = '';
  final List<Map<String, dynamic>> _inbox = [];

  // Per-wapp datagram channel: wapps (e.g. circles) exchange opaque, app-tagged
  // datagrams over the dedicated "geogram/wapp" destination. Inbound datagrams
  // are demultiplexed by tag into these per-tag queues, drained by the calling
  // wapp's engine; the payload is whatever bytes the wapp sent (it encrypts
  // end-to-end itself — this channel is a dumb pipe).
  final Map<String, List<Map<String, dynamic>>> _wappInbox = {};

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

  /// Live hub uplinks (mesh). 'host:port' of each connected bootstrap hub.
  Set<String> get connectedHubs => Set.unmodifiable(_connectedHubs);

  /// Ask the network for a path to [destHex] (32-hex destination hash). The pull
  /// half of RNS path-finding: reaches a destination whose announce never
  /// passively flooded to us. The response (a PATH_RESPONSE announce) is learned
  /// asynchronously; poll [hasPathTo] to see when the path lands.
  bool requestPath(String destHex) {
    final t = _transport;
    if (t == null) return false;
    final bytes = _hexToBytes(destHex);
    if (bytes == null || bytes.length != kRnsDestHashBytes) return false;
    t.requestPath(bytes);
    return true;
  }

  /// Whether we currently hold a path to [destHex] (32-hex destination hash).
  bool hasPathTo(String destHex) {
    final t = _transport;
    final bytes = _hexToBytes(destHex);
    if (t == null || bytes == null) return false;
    return t.hasPath(bytes);
  }

  /// Diagnostic: our routing to [destHex] (next hop, interface, hops, age) plus
  /// our live interfaces and passive state — to debug WHY addressed packets to a
  /// destination do or don't get forwarded.
  Map<String, dynamic> routeInfo(String destHex) {
    final t = _transport;
    final bytes = _hexToBytes(destHex);
    return {
      'dest': destHex,
      'path': (t == null || bytes == null) ? null : t.pathInfo(bytes),
      'interfaces': t?.interfaceLabels ?? const [],
      'passive': t?.passive ?? false,
    };
  }

  static Uint8List? _hexToBytes(String hex) {
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

  void _dropClient(RnsTcpInterface c) {
    _transport?.removeInterface(c);
    _ifaces.remove(c);
    _clients.remove(c);
    _connectedHubs.remove('${c.host}:${c.port}');
    // ignore: discarded_futures
    c.close();
  }

  /// One uplink's socket closed/errored. Drop it; if it was the LAST uplink the
  /// node has no internet path, so go down and reconnect the whole mesh from the
  /// current network. While other uplinks remain, the periodic autostart top-up
  /// re-adds the dropped hub. Keeps local services + LAN/gateway intact.
  void _onUplinkDown(RnsTcpInterface c, String why) {
    if (_mode != 'tcpclient') return;
    if (!_clients.contains(c)) return; // already removed
    LogService.instance.add('RNS: uplink ${c.host}:${c.port} down ($why)');
    _dropClient(c);
    if (_clients.isEmpty) _allLinksDown(why);
  }

  /// No uplink left (all sockets dead, or the watchdog saw total silence after a
  /// network change). Mark down, tear any stragglers, and trigger an immediate
  /// reconnect of the full hub mesh.
  void _allLinksDown(String why) {
    if (_mode != 'tcpclient') return;
    if (!_up && _clients.isEmpty) return;
    LogService.instance.add('RNS: all hub uplinks down ($why) — reconnecting');
    _up = false;
    _linkWatchdog?.cancel();
    _linkWatchdog = null;
    for (final c in List.of(_clients)) {
      _dropClient(c);
    }
    final cb = onLinkDown;
    if (cb != null) cb();
  }

  /// Build, connect and register a single TCP uplink — the ONE place a Reticulum
  /// TCP connection is created. Both initial start (tcpclient mode) and later
  /// mesh additions ([connectUplink]) route through here so the connect + wiring
  /// (clients / connectedHubs / transport / ifaces) never drift apart. Throws on
  /// connect failure; the caller decides how to react.
  Future<RnsTcpInterface> _attachTcpUplink(String host, int port,
      {Duration timeout = const Duration(seconds: 8)}) async {
    final key = '$host:$port';
    final tag = 'tcp:$key';
    late final RnsTcpInterface c;
    c = RnsTcpInterface(
      host: host,
      port: port,
      label: tag,
      onPacket: (raw) => _onInbound(raw, tag),
      log: (m) => LogService.instance.add('RNS/tcp: $m'),
      onDisconnect: () => _onUplinkDown(c, 'socket closed'),
    );
    await c.connect(timeout: timeout);
    _clients.add(c);
    _connectedHubs.add(key);
    _transport!.addInterface(c);
    _ifaces.add(c);
    return c;
  }

  /// Add an extra hub uplink to the already-up node (the mesh). Idempotent per
  /// host:port. Best-effort: a hub that won't connect is just skipped. Returns
  /// true if an uplink to [host]:[port] is now held.
  Future<bool> connectUplink(String host, int port) async {
    if (!_up || _transport == null) return false;
    final key = '$host:$port';
    if (_connectedHubs.contains(key)) return true;
    try {
      await _attachTcpUplink(host, port);
      LogService.instance.add('RNS: added hub uplink $key (mesh)');
      // Announce on the new interface so this hub (and peers reachable via it)
      // learn our destinations promptly instead of waiting for the next cycle.
      await announce(_announceText);
      await _announceServiceDests();
      return true;
    } catch (e) {
      LogService.instance.add('RNS: uplink $key failed: $e');
      return false;
    }
  }

  // True once this node holds a BLE edge interface and relays it onto the hubs.
  bool _bleBridge = false;

  /// Bring up this node's BLE radio as an EDGE interface and turn on scoped
  /// edge-bridge relaying, so BLE-only peers (no internet) become reachable from
  /// across the world through us (A —BLE→ us —TCP→ hubs → C). Only the
  /// announces/packets for those BLE peers cross to/from the hubs — the internet
  /// announce flood is never re-aired onto BLE (see [RnsTransport.edgeBridge]),
  /// so BLE air and the APRS traffic sharing it are protected. Automatic,
  /// idempotent, non-fatal: a device without BLE5 (e.g. desktop) just stays a
  /// leaf.
  Future<void> _enableBleBridge() async {
    if (_bleBridge || _transport == null || _id == null) return;
    try {
      final radio = Ble5Radio();
      if (!await radio.supported()) return; // no BLE5 here — remain a leaf
      await radio.startScan();
      final iface = RnsBleInterface(
        radio: radio,
        edge: true,
        onPacket: (raw) => _onInbound(raw, 'ble5'),
        log: (m) => LogService.instance.add('RNS/ble5: $m'),
      );
      _transport!
        ..addInterface(iface)
        ..transportId = _id!.hash // 16-byte relay id (truncated identity hash)
        ..edgeBridge = true
        // Scoped relay work is tiny; never auto-shed it (would stop bridging).
        ..setPassive(false, auto: false);
      _ifaces.add(iface);
      _bleBridge = true;
      LogService.instance.add(
          'RNS: BLE edge-bridge ON (relaying BLE peers onto the hubs)');
    } catch (e) {
      LogService.instance.add('RNS: BLE edge-bridge unavailable: $e');
    }
  }

  /// Whether this node is acting as a BLE↔internet edge-bridge.
  bool get isBleBridge => _bleBridge && (_transport?.edgeBridge ?? false);

  /// Seconds this node's Reticulum stack has been up this run (0 when down).
  /// Advertised on the wire (relay announce) and the API so peers can prefer
  /// stable, long-running nodes (likely indexers) when warm-starting discovery.
  int get uptimeSeconds {
    final t = _startedAt;
    if (!_up || t == null) return 0;
    return DateTime.now().difference(t).inSeconds;
  }

  Map<String, dynamic> status() => {
        'up': _up,
        'starting': _starting,
        'uptimeSeconds': uptimeSeconds,
        'mode': _mode,
        'identity': identityHex,
        'dest': destHex,
        'paths': _transport?.pathCount ?? 0,
        // Edge-bridge: this node relays BLE-only peers onto the internet hubs.
        'bridge': isBleBridge,
        // Passive = shedding relay work under CPU load (still meshed + sending/
        // receiving our own traffic); annRate = inbound announces/sec driving it.
        'passive': _transport?.passive ?? false,
        'annRate': (_transport?.announceRatePerSec ?? 0).round(),
        'connections': _server?.connectionCount ?? 0,
        'interfaces': _ifaces.length + (_server != null ? 1 : 0),
        'inbox': _inbox.length,
        'provided': _files?.providedCount ?? 0,
        'dhtStored': _files?.dhtStoredKeys ?? 0,
        'dhtReplicas': _files?.dhtReplicasStored ?? 0,
        'dhtDemoted': _files?.dhtProvidersDemoted ?? 0,
        'dhtRejected': _files?.dhtStoresRejected ?? 0,
        'dhtPeers': _files?.dhtRoutingSize ?? 0,
        'dhtPeerIds': _files?.dhtPeerHexes ?? const <String>[],
        'lxmfDest': lxmfDeliveryHex,
        'lxmfPropDest': lxmfPropagationHex,
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
        'observed': _observed.length,
      };

  // ─────────────────────────────────────────────────────────────────────────
  // Observed-node registry — the network as THIS node has heard it, fed by the
  // inbound-announce path (_observeAnnounce, called from _onInbound). A "node" is
  // an identity; one identity announces several service destinations (chat/files/
  // dht/wapp/relay/lxmf/rv), so we accumulate the services per identity. This is
  // a SAMPLED, capped, stale-swept view — never a hub's full client roster (a
  // leaf cannot enumerate a hub's clients). The reticulum wapp visualizes it; the
  // HAL exposes graphSnapshot()/hubsInfo() read-only (see hal_rns_nodes/_hubs).
  // ─────────────────────────────────────────────────────────────────────────
  static const int _observedCap = 4096;
  static const int _observedStaleMs = 30 * 60 * 1000; // drop entries idle >30min
  // A device counts as "online" if it announced within this window. The periodic
  // re-announce cadence is 30s (charging+wifi) … 5min (battery/cellular), so this
  // is a little over 2× the slow cadence to avoid flapping a battery peer offline
  // between announces, while staying well under the 30-min stale sweep.
  static const int _onlineWindowMs = 11 * 60 * 1000;
  // A node counts as reachable only once we've heard it RE-announce — at least
  // two announces spread over this span. Bursty connect-flood replays (the hub
  // dumping its cached announce table on link-up) all land within a second or
  // two, so they never clear this bar even though their lastSeen looks recent.
  static const int _reannounceMinSpanMs = 25 * 1000;
  final Map<String, _ObservedNode> _observed = {};

  // Persistent on-disk cache of observed nodes (set [observedStorePath] before
  // start; the app points it at the reticulum wapp's per-profile data folder).
  // Keeps "first seen by you" across restarts and answers fast count/geogram
  // queries over the full history, not just the live (capped/swept) set.
  String? observedStorePath;
  ObservedStore? _obStore;
  final Map<String, int> _firstSeenByHex = {}; // durable first-seen per id
  final Set<String> _obDirty = {}; // ids changed since the last flush
  Timer? _obFlushTimer;
  Map<String, dynamic> _obStats = const {
    'total': 0,
    'geogram': 0,
    'oldest': 0,
    'seen24h': 0
  };

  /// Flush the dirty observed nodes to disk and refresh the cached stats. Cheap:
  /// one batched transaction, only the nodes that changed. Called on a slow
  /// timer and at stop().
  void _flushObserved() {
    final st = _obStore;
    if (st == null || !st.isOpen) return;
    if (_obDirty.isNotEmpty) {
      final rows = <Map<String, Object?>>[];
      for (final id in _obDirty) {
        final n = _observed[id];
        if (n == null) continue;
        rows.add({
          'id': n.identityHex,
          'pubkey': n.publicKeyHex,
          'callsign': n.callsign ?? '',
          'services': (n.services.toList()..sort()).join(','),
          'geogram':
              n.services.any((s) => s != 'lxmf' && s != 'lxmf-prop') ? 1 : 0,
          'hops': n.hops,
          'via': n.via,
          'uptime': n.uptimeSeconds,
          'firstSeen': n.firstSeenMs,
          'lastSeen': n.lastSeenMs,
        });
      }
      if (rows.isNotEmpty) st.upsertMany(rows);
      _obDirty.clear();
    }
    _obStats = st.stats();
  }

  // Note: the observed registry is NOT hydrated from disk on boot. Cache entries
  // can't be confirmed reachable (no live re-announce), and showing them led to
  // ghost devices that had long gone away. The graph now fills only from live
  // re-announces; the on-disk cache still backs the persistent stats and the DHT
  // warm-start ([_warmStartFromCache], which reads the cache directly).

  /// Warm-start discovery from the persistent observed-node cache: seed the DHT
  /// routing table from the public keys of known geogram peers (so resolve /
  /// publish act immediately), then pull transport paths to the steadiest peers
  /// (highest advertised uptime → likely indexers) FIRST, so the first folder /
  /// file lookup is routable within seconds instead of waiting minutes for live
  /// announces to re-converge. Runs once on boot, after the node is up.
  Future<void> _warmStartFromCache() async {
    final st = _obStore;
    final f = _files;
    if (st == null || f == null || !_up) return;
    final rows = st.topGeogramPeers(limit: 64);
    if (rows.isEmpty) return;
    final pubs = <Uint8List>[];
    for (final r in rows) {
      final pub = _bytesFromHex((r['pubkey'] as String?) ?? '');
      if (pub != null && pub.length == 64) pubs.add(pub);
    }
    final seeded = f.seedPeers(pubs);
    // Rows are already ordered uptime-desc, last-seen-desc. Path-request the top
    // few (the steadiest) — a cheap PULL their hub answers — so they're reachable
    // first; don't flood the mesh with a request for every cached node.
    var pathed = 0;
    for (final r in rows.take(8)) {
      final pub = _bytesFromHex((r['pubkey'] as String?) ?? '');
      if (pub == null || pub.length != 64) continue;
      try {
        f.requestPeerPaths(RnsIdentity.fromPublicKey(pub));
        pathed++;
      } catch (_) {/* skip a malformed key */}
    }
    LogService.instance.add(
        'RNS: warm-start seeded $seeded cached peer(s), path-requested top $pathed');
  }

  // (serviceLabel, app, aspects) tuples. A destination hash binds an identity to
  // a (app, aspects) name, so we classify an announce by recomputing the hash for
  // the announcing identity and matching. Geogram software ⇔ announces any
  // non-LXMF service here (generic Reticulum nodes announce only lxmf/*).
  static final List<(String, String, List<String>)> _serviceTuples = [
    ('chat', _app, _aspects),
    ('files', _app, _aspectsFiles),
    ('dht', _app, _aspectsDht),
    ('wapp', _app, _aspectsWapp),
    ('relay', kRelayApp, kRelayAspects),
    ('lxmf', kLxmfApp, kLxmfDeliveryAspects),
    ('lxmf-prop', kLxmfApp, kLxmfPropagationAspects),
    ('rv', 'circles', ['rv']),
  ];

  /// Which service destination this announce is, or null if it's none we know.
  String? _classifyAnnounce(RnsIdentity id, Uint8List destHash) {
    for (final (label, app, aspects) in _serviceTuples) {
      if (RnsCrypto.constantTimeEquals(
          destHash, RnsDestination.hash(id, app, aspects))) {
        return label;
      }
    }
    return null;
  }

  /// Fold one inbound announce into the observed registry. [wireHops] is the
  /// packet's hop count (RNS convention: +1 for the stored path hops). [via] is
  /// the interface label. Skips our own announces.
  void _observeAnnounce(RnsAnnounce ann, int wireHops, String via) {
    if (_id != null &&
        RnsCrypto.constantTimeEquals(ann.identity.hash, _id!.hash)) {
      return;
    }
    final key = ann.identity.hexHash;
    final now = DateTime.now().millisecondsSinceEpoch;
    final svc = _classifyAnnounce(ann.identity, ann.destHash);
    // The relayer (transport node) we reach this destination through, if any.
    final relayer = _transport?.pathFor(ann.destHash)?.nextHop;
    var n = _observed[key];
    if (n == null) {
      if (_observed.length >= _observedCap) _evictOldestObserved();
      // Preserve the true first-seen across restarts/evictions: reuse the
      // persisted value if we've ever recorded this node before.
      final firstSeen = _firstSeenByHex[key] ?? now;
      _firstSeenByHex[key] = firstSeen;
      n = _ObservedNode(
        identityHex: key,
        publicKeyHex: _hex(ann.publicKey),
        firstSeenMs: firstSeen,
      );
      _observed[key] = n;
    }
    // Liveness tracking (this run). A genuinely-reachable node RE-announces on
    // its periodic cadence; a node we only know from the hub's connect-flood (it
    // dumps its cached announce table when we link) is heard exactly ONCE and
    // then goes silent — yet we stamp lastSeen=now on receipt, so "heard
    // recently" alone wrongly marks it reachable. So we require a re-announce
    // spread over time before treating a node as reachable (see graphSnapshot).
    if (n.firstHeardMs == 0) n.firstHeardMs = now;
    n.heardCount++;
    n.lastSeenMs = now;
    n.hops = wireHops + 1;
    n.via = via;
    n.relayerHex = relayer == null ? null : _hex(relayer);
    if (svc != null) {
      n.services.add(svc);
      if (svc == 'chat') {
        final cs = utf8.decode(ann.appData, allowMalformed: true).trim();
        if (cs.isNotEmpty && cs.length <= 20 && !cs.contains(' ')) {
          n.callsign = cs;
        }
      } else if (svc == 'relay') {
        // The relay announce carries the peer's advertised uptime (warm-start
        // ranking) and its NOSTR pubkey (for the npub shown per device).
        final ra = RelayAnnouncement.decode(ann.appData);
        if (ra != null) {
          if (ra.uptimeSeconds > 0) n.uptimeSeconds = ra.uptimeSeconds;
          if (ra.pubkey != null && ra.pubkey!.isNotEmpty) {
            n.nostrPubHex = ra.pubkey;
            // Once a peer is genuinely reachable (re-announced), pull its kind-0
            // profile directly from it so we can show its real nickname. Gating
            // on heardCount keeps the connect-flood from spamming queries.
            if (n.heardCount >= 2) {
              _maybeFetchObservedProfile(ra.pubkey!.toLowerCase());
            }
          }
        }
      }
    }
    // Mark for the next periodic flush to disk.
    if (_obStore != null) _obDirty.add(key);
  }

  void _evictOldestObserved() {
    String? oldestKey;
    var oldest = 1 << 62;
    _observed.forEach((k, v) {
      if (v.lastSeenMs < oldest) {
        oldest = v.lastSeenMs;
        oldestKey = k;
      }
    });
    if (oldestKey != null) _observed.remove(oldestKey);
  }

  /// Drop nodes not heard for [_observedStaleMs]. Called on a slow periodic
  /// sweep (rns_autostart) and at the head of graphSnapshot so a stale view is
  /// never returned.
  void sweepObserved() {
    final cutoff = DateTime.now().millisecondsSinceEpoch - _observedStaleMs;
    _observed.removeWhere((_, v) => v.lastSeenMs < cutoff);
  }

  /// Encode a NOSTR pubkey hex to an npub for display, or '' if absent/malformed.
  String _npubOrEmpty(String? pubHex) {
    if (pubHex == null || pubHex.isEmpty) return '';
    try {
      return NostrCrypto.encodeNpub(pubHex);
    } catch (_) {
      return '';
    }
  }

  /// A peer's friendly name from its cached kind-0 profile (display_name/name),
  /// or '' if we haven't fetched one. Used as the device "nickname".
  String _profileNameFor(String? pubHex) {
    if (pubHex == null || pubHex.length != 64) return '';
    final m = _parseProfileContent(_relayStore?.profileOf(pubHex)?.content);
    if (m == null) return '';
    final n = m['display_name'] ?? m['name'];
    return (n is String) ? n.trim() : '';
  }

  static const List<(int, String)> _capNames = [
    (1 << 0, 'search'),
    (1 << 1, 'firehose'),
    (1 << 2, 'store-forward'),
    (1 << 3, 'archive'),
  ];

  /// A snapshot of the observed network as a {nodes,edges} graph for the wapp's
  /// webview. Topology is hub-centric: [self] in the centre, identified transport
  /// nodes (the relayers other nodes are reached through) as hubs, and the
  /// remaining nodes as leaves clustered under their relayer (or direct neighbours
  /// of self). [service] filters to nodes announcing that service; [geogramOnly]
  /// hides generic Reticulum nodes; [search] matches callsign/identity/service.
  Map<String, dynamic> graphSnapshot({
    String? service,
    bool geogramOnly = false,
    String? search,
  }) {
    sweepObserved();
    final q = (search ?? '').trim().toLowerCase();
    // Relay roles, keyed by identity hex, joined in for meta.role/caps.
    final relayByHex = <String, RelayEntry>{};
    for (final e in _relayDir.entries()) {
      relayByHex[e.idHex] = e;
    }
    // The graph shows only nodes REACHABLE NOW. "Reachable" needs more than a
    // recent lastSeen: when we link a hub it floods its cached announce table at
    // us, so every long-dead node it ever heard gets stamped "now" once. A truly
    // reachable peer instead RE-announces on its cadence — so we require ≥2
    // announces spread over [_reannounceMinSpanMs] within the online window.
    // This drops the connect-flood ghosts the user saw. One definition, used for
    // the canvas, the hub child counts, and the headline badges alike.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    bool isFresh(_ObservedNode n) =>
        n.heardCount >= 2 &&
        nowMs - n.lastSeenMs <= _onlineWindowMs &&
        n.lastSeenMs - n.firstHeardMs >= _reannounceMinSpanMs;

    // Hub set = every identity that is a relayer for some node reachable now.
    final hubIds = <String>{};
    for (final n in _observed.values) {
      if (!isFresh(n)) continue;
      final r = n.relayerHex;
      if (r != null && r.isNotEmpty) hubIds.add(r);
    }

    bool isGeogram(_ObservedNode n) =>
        n.services.any((s) => s != 'lxmf' && s != 'lxmf-prop');
    bool matchesFilters(_ObservedNode n) {
      if (geogramOnly && !isGeogram(n)) return false;
      if (service != null &&
          service.isNotEmpty &&
          !n.services.contains(service)) {
        return false;
      }
      if (q.isNotEmpty) {
        final hay =
            '${n.callsign ?? ''} ${n.identityHex} ${n.services.join(' ')}'
                .toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }

    final nodes = <Map<String, dynamic>>[];
    final edges = <Map<String, dynamic>>[];
    final emitted = <String>{};
    final childCount = <String, int>{};

    String shortHex(String h) => h.length > 8 ? h.substring(0, 8) : h;
    Map<String, dynamic> nodeJson(_ObservedNode n, String kind) {
      final relay = relayByHex[n.identityHex];
      final caps = <String>[];
      if (relay != null) {
        for (final (bit, name) in _capNames) {
          if (relay.announcement.caps & bit != 0) caps.add(name);
        }
      }
      // Identity for display. In geogram the CALLSIGN is derived from the npub
      // (X1<4>), not the announced text — many devices announce the generic
      // nickname "aurora", so that alone is useless. The NICKNAME is the peer's
      // kind-0 display_name when we've fetched it, else its announced text.
      final pub = n.nostrPubHex;
      var callsign = '';
      if (pub != null && pub.length == 64) {
        try {
          callsign = 'X1${NostrCrypto.deriveCallsign(pub)}';
        } catch (_) {}
      }
      final announced = (n.callsign ?? '').trim();
      final profileName = _profileNameFor(pub);
      final nickname = profileName.isNotEmpty ? profileName : announced;
      // Title: "nickname (callsign)" when both are known and differ; otherwise
      // whichever we have, falling back to the short identity hex.
      final String label;
      if (callsign.isNotEmpty &&
          nickname.isNotEmpty &&
          nickname.toUpperCase() != callsign.toUpperCase()) {
        label = '$nickname ($callsign)';
      } else if (callsign.isNotEmpty) {
        label = callsign;
      } else if (nickname.isNotEmpty) {
        label = nickname;
      } else {
        label = shortHex(n.identityHex);
      }
      return {
        'id': n.identityHex,
        'label': label,
        'kind': kind,
        'services': n.services.toList()..sort(),
        // How this node can be reached for a 1:1 message, derived from what it
        // announced: 'lxmf' = LXMF delivery dest (direct, the cross-Reticulum
        // standard) · 'sf' = LXMF propagation only (store-and-forward) · 'chat' =
        // geogram-native chat · '' = no 1:1 messaging heard. The wapp renders an
        // indicator + a Message button from this (delivery dest derived from
        // meta.pubkey). 'self' kind never carries one.
        'dm': kind == 'self'
            ? ''
            : n.services.contains('lxmf')
                ? 'lxmf'
                : n.services.contains('lxmf-prop')
                    ? 'sf'
                    : n.services.contains('chat')
                        ? 'chat'
                        : '',
        'geogram': isGeogram(n),
        'hops': n.hops,
        'via': n.via,
        'relayer': n.relayerHex ?? '',
        'meta': {
          // Callsign = npub-derived (the stable geogram id); nickname = friendly
          // name (kind-0 display_name, else announced text). Both surfaced so the
          // detail panel can show them separately.
          'callsign': callsign.isNotEmpty ? callsign : announced,
          'nickname': nickname,
          'pubkey': n.publicKeyHex,
          // NOSTR npub (from the peer's relay announce) so same-nickname devices
          // are distinguishable; empty if the peer never advertised one.
          'npub': _npubOrEmpty(n.nostrPubHex),
          'role': relay?.announcement.role.name ?? '',
          'caps': caps,
          'capacity': relay?.announcement.capacity ?? 0,
          'firstSeen': n.firstSeenMs,
          'lastSeen': n.lastSeenMs,
        },
      };
    }

    void emit(_ObservedNode n, String kind) {
      if (emitted.add(n.identityHex)) nodes.add(nodeJson(n, kind));
    }

    // Self node (centre).
    nodes.add({
      'id': identityHex ?? 'self',
      'label': _announceText.isNotEmpty ? _announceText : 'this node',
      'kind': 'self',
      'services': const [],
      'geogram': true,
      'hops': 0,
      'via': '',
      'relayer': '',
      'meta': {
        'callsign': _announceText,
        'pubkey': '',
        'role': '',
        'caps': const [],
        'capacity': 0,
        'firstSeen': 0,
        'lastSeen': DateTime.now().millisecondsSinceEpoch,
      },
    });
    emitted.add(identityHex ?? 'self');

    // Pass 1: emit hubs (the structure) + count their reachable-now children.
    for (final n in _observed.values) {
      if (!isFresh(n)) continue;
      final r = n.relayerHex;
      if (r != null && r.isNotEmpty) childCount[r] = (childCount[r] ?? 0) + 1;
    }
    for (final hubId in hubIds) {
      final hub = _observed[hubId];
      if (hub != null) {
        emit(hub, 'hub');
      } else {
        // Relayer we route through but never heard announce directly — synth.
        nodes.add({
          'id': hubId,
          'label': 'hub ${shortHex(hubId)}',
          'kind': 'hub',
          'services': const [],
          'geogram': false,
          'hops': 1,
          'via': '',
          'relayer': '',
          'meta': {'callsign': '', 'pubkey': '', 'role': '', 'caps': const [], 'capacity': 0, 'firstSeen': 0, 'lastSeen': 0},
        });
        emitted.add(hubId);
      }
      edges.add({'from': identityHex ?? 'self', 'to': hubId, 'kind': 'uplink'});
    }
    // Annotate hub child counts (the "≈N heard (sample)" badge).
    for (final node in nodes) {
      if (node['kind'] == 'hub') {
        (node['meta'] as Map)['children'] = childCount[node['id']] ?? 0;
      }
    }

    // Pass 2: emit the reachable-now leaves / direct neighbours and their edges.
    for (final n in _observed.values) {
      if (hubIds.contains(n.identityHex)) continue; // already a hub
      if (!isFresh(n)) continue; // gone quiet — keep it off the canvas
      if (!matchesFilters(n)) continue;
      final r = n.relayerHex;
      if (r != null && r.isNotEmpty) {
        emit(n, 'leaf');
        edges.add({'from': r, 'to': n.identityHex, 'kind': 'relay'});
      } else {
        emit(n, 'leaf');
        edges.add({
          'from': identityHex ?? 'self',
          'to': n.identityHex,
          'kind': 'direct'
        });
      }
    }

    // Headline counts for the wapp: devices reachable right now (the same fresh
    // set the canvas shows) and how many of those accept LXMF. Deliberately
    // UNFILTERED so the search/service/geogram chips don't shrink them.
    var online = 0;
    var lxmfReachable = 0; // online peers that announced an LXMF delivery dest
    var geogramReachable = 0; // online peers running geogram software
    for (final n in _observed.values) {
      if (isFresh(n)) {
        online++;
        if (n.services.contains('lxmf')) lxmfReachable++;
        if (isGeogram(n)) geogramReachable++;
      }
    }

    return {
      'nodes': nodes,
      'edges': edges,
      'sample': true, // honest: this is what we heard, not a full roster
      'observed': _observed.length,
      'online': online,
      'lxmfReachable': lxmfReachable,
      'geogramReachable': geogramReachable,
      'passive': _transport?.passive ?? false,
      // Persistent all-time counts from the on-disk cache (total/geogram/oldest).
      'stats': _obStats,
    };
  }

  /// The configured bootstrap hubs (PreferencesService.rnsBootstrapServers)
  /// joined with which we currently hold an uplink to. Drives the Hubs screen.
  List<Map<String, dynamic>> hubsInfo() {
    final prefs = PreferencesService.instanceSync;
    final servers = prefs?.rnsBootstrapServers ?? const <String>[];
    final out = <Map<String, dynamic>>[];
    for (final s in servers) {
      final t = s.trim();
      if (t.isEmpty) continue;
      out.add({'endpoint': t, 'connected': _connectedHubs.contains(t)});
    }
    return out;
  }

  /// Add a bootstrap hub: persist it (if new) and dial an uplink immediately.
  /// [endpoint] is "host:port". Returns true if an uplink is now held.
  Future<bool> addBootstrap(String endpoint) async {
    final (host, port) = _parseEndpoint(endpoint);
    if (host == null) return false;
    final ep = '$host:$port';
    final prefs = PreferencesService.instanceSync;
    if (prefs != null) {
      final list = List<String>.from(prefs.rnsBootstrapServers);
      if (!list.contains(ep)) {
        list.add(ep);
        prefs.rnsBootstrapServers = list;
      }
    }
    return connectUplink(host, port);
  }

  /// Remove a bootstrap hub: drop any uplink and forget it from preferences.
  void removeBootstrap(String endpoint) {
    final (host, port) = _parseEndpoint(endpoint);
    final ep = host == null ? endpoint.trim() : '$host:$port';
    final prefs = PreferencesService.instanceSync;
    if (prefs != null) {
      prefs.rnsBootstrapServers = [
        for (final s in prefs.rnsBootstrapServers)
          if (s.trim() != ep) s
      ];
    }
    if (host != null) disconnectUplink(host, port);
  }

  /// Drop the live uplink to [host]:[port] without forgetting the bootstrap
  /// entry (so a later connect re-dials it).
  void disconnectUplink(String host, int port) {
    final ep = '$host:$port';
    for (final c in List.of(_clients)) {
      if ('${c.host}:${c.port}' == ep) {
        LogService.instance.add('RNS: disconnecting uplink $ep (user)');
        _dropClient(c);
      }
    }
  }

  /// Connect (idempotently) to an already-known bootstrap endpoint.
  Future<bool> connectBootstrap(String endpoint) async {
    final (host, port) = _parseEndpoint(endpoint);
    if (host == null) return false;
    return connectUplink(host, port);
  }

  /// Pin passive (relay-shedding) mode on/off. Passive still meshes and carries
  /// our own traffic; it just stops doing relay work for others.
  void setPassive(bool value) => _transport?.setPassive(value);

  static (String?, int) _parseEndpoint(String endpoint) {
    final t = endpoint.trim();
    final i = t.lastIndexOf(':');
    if (i <= 0) return (t.isEmpty ? null : t, 4242);
    final host = t.substring(0, i).trim();
    final port = int.tryParse(t.substring(i + 1).trim()) ?? 4242;
    return (host.isEmpty ? null : host, port);
  }

  /// Start the node. [mode] is 'tcpserver' (LAN hub), 'tcpclient' (connect to a
  /// hub at host:port), or 'ble' (connectionless broadcast). [announceName] is
  /// the app_data broadcast in the initial + periodic announces (e.g. the
  /// device callsign); kept generic — the caller decides the content.
  Future<bool> start({
    required String mode,
    String host = '127.0.0.1',
    int port = 4242,
    String announceName = 'online',
    bool localGateway = true,
    int localGatewayPort = 37242,
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
      // LEAF node (no transportId): like a reference RNS client with
      // enable_transport=False. A phone must NOT act as a transport node —
      // relaying the public hubs' whole announce flood across every uplink
      // saturates its CPU + bandwidth and starves real traffic (it made large
      // file transfers crawl/stall). The hubs do the routing; we still announce
      // ourselves and reach peers through them.
      _transport =
          RnsTransport(log: (m) => LogService.instance.add('RNS: $m'));
      // Never let the public-hub announce flood drown out OUR overlay's
      // announces: register the name_hashes of every Aurora destination so the
      // transport's per-second verify budget always processes them. Without
      // this, peers fail to discover each other (no media fetch / FEED backfill)
      // on busy hubs. The name_hash is constant per app+aspects.
      _transport!.priorityAnnounceNames.addAll([
        _hex(RnsDestination.nameHash(_app, _aspects)), // chat (callsign)
        _hex(RnsDestination.nameHash(_app, _aspectsFiles)), // files
        _hex(RnsDestination.nameHash(_app, _aspectsDht)), // dht
        _hex(RnsDestination.nameHash(kRelayApp, kRelayAspects)), // relay
        _hex(RnsDestination.nameHash(kLxmfApp, kLxmfDeliveryAspects)), // lxmf
        _hex(RnsDestination.nameHash(_app, _aspectsWapp)), // wapp datagrams
        // Short-code rendezvous beacons (circles/rv). Flood-exempt so a joiner
        // ALWAYS ingests the owner's beacon under a busy hub — that ingest is
        // exactly what makes the joiner's pathFor(rvDest) resolve the address.
        _hex(RnsDestination.nameHash('circles', const ['rv'])),
      ]);
      _mode = mode;
      // One serve source that fans out: the MediaArchive plus any owner disk
      // folders (added later by the DiskFolderManager) — disk bytes are never
      // copied into sqlite.
      _composite = CompositeFileSource([fileServeSource ?? const EmptyFileSource()]);
      // Resumable downloads: persist completed segments so a fetch resumes after a
      // drop or app restart. Generic — every fetch consumer (media, folders, wapp
      // store, updates, profiles) inherits it through fetch/resolveAndFetch.
      _partialStore = partialStoreDir == null
          ? null
          : FilePartialStore(Directory(partialStoreDir!));
      _files = FileTransferNode(
        identity: _id!,
        source: _composite!,
        send: (raw) => _transport?.sendLinkAware(raw),
        log: (m) => LogService.instance.add('RNS/files: $m'),
        enableDht: true,
        partialStore: _partialStore,
        // Relaxed Kademlia fanout, now that persistence anchors (below) guarantee
        // findability independent of XOR distance/k: resolve queries the always-on
        // anchors FIRST and publish stores to them, so the XOR-walk is only a
        // secondary/redundancy path. We therefore no longer need k to span the
        // whole overlay (the old k=96 was a workaround for records living only on
        // their holder). k=20/alpha=6 (vs the library's safe 96/12 default for
        // consumers WITHOUT anchors) cuts per-lookup RPCs and burst substantially.
        dhtK: 20,
        dhtAlpha: 6,
        // Run DHT RPC links over the CHAT destination, not the dedicated
        // geogram/dht dest. Public hubs rate-limit announces and routinely drop
        // the geogram/dht announce, so peers have no transport path to each
        // other's dht dest and STOREs never land (replication failed; resolve
        // only worked because the holder kept its own record + k=96). The chat
        // announce is the most reliably propagated one, so routing RPC there
        // makes any chat-reachable peer DHT-reachable. The Kademlia node id is
        // still derived from geogram/dht locally and is unaffected. Updated nodes
        // also dual-accept on the legacy dht dest for the mixed-fleet migration.
        rpcApp: _app, // 'geogram'
        rpcAspects: _aspects, // ['chat']
        // Persistence anchors: the always-on relay indexers. The DHT also STOREs
        // provider records to them and queries them FIRST on resolve, so records
        // survive churn of the ephemeral k-closest and stay findable regardless
        // of XOR distance (the enabler for shrinking k later). We pick the most
        // stable (lowest kCap) fresh indexers, excluding ourselves, capped to a
        // few to bound the extra traffic. Empty when none are known → unchanged.
        stableAnchors: () {
          final selfHash = _id?.hash;
          final list = _relayDir
              .indexers()
              .where((e) {
                final c = e.announcement.capacity;
                return c >= kCapArchive && c <= kCapHomeWifi;
              })
              .where((e) =>
                  selfHash == null ||
                  !RnsCrypto.constantTimeEquals(e.identity.hash, selfHash))
              .toList()
            ..sort((a, b) {
              final c =
                  a.announcement.capacity.compareTo(b.announcement.capacity);
              return c != 0 ? c : b.lastSeenMs.compareTo(a.lastSeenMs);
            });
          return [for (final e in list.take(6)) e.identity];
        },
        nextHopFor: (peer) => _transport?.nextHopForIdentity(peer),
        // Per-destination routing (Reticulum routes per-dest, not per-identity):
        // the files/dht dests of a node may be reached via different hubs, so the
        // link request must be transport-addressed to the hub that has a route to
        // THIS dest — using any of the identity's paths sent it to the wrong hub,
        // which dropped it (the silent device-to-device link failure).
        nextHopForDest: (h) => _transport?.pathFor(h)?.nextHop,
        hasPathForDest: (h) => _transport?.hasPath(h) ?? false,
        // Link MTU discovery: offer the next-hop interface's HW MTU so file
        // links over TCP negotiate large resource parts (much higher throughput).
        nextHopMtuForDest: (h) =>
            _transport?.nextHopInterfaceHwMtu(h) ?? kRnsMtu,
        // Pull a path to a peer we know by identity but have no cached route to
        // (its announce was never flooded to us) so DHT resolve + file fetch
        // links are routable — the fix that makes device-to-device folder
        // discovery work on busy/asymmetric public hubs.
        requestPath: (h) => _transport?.requestPath(h),
        // Pin an outbound file link to its dest's path interface (the LAN) up
        // front, so our GET_FILE/resource traffic can't be flipped onto a slow
        // hub by a proof copy arriving there.
        onLinkOpened: (linkId, destHash) {
          final via = _transport?.pathFor(destHash)?.via;
          if (via != null) _transport?.noteLinkIface(linkId, via);
        },
        // (LAN link-failure demotion intentionally NOT wired: the LAN lane is
        // reliable unicast now, so demoting it on a transient miss only flapped
        // co-located transfers onto a slower/again-failing hub. noteLinkFailure
        // stays available for a future, less trigger-happy policy.)
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
        send: (raw) => _transport?.sendLinkAware(raw),
        nextHopFor: (peer) => _transport?.nextHopForIdentity(peer),
        identityForDest: (h) => _transport?.pathFor(h)?.identity,
        requestPath: (h) => _transport?.requestPath(h),
        onMessage: (m) {
          // Wapp datagrams ride LXMF too — route them to the wapp inbox instead
          // of surfacing them as chat messages.
          if (_routeWappLxmf(m)) {
            LogService.instance.add(
                'LXMF: wapp datagram from ${_hex(m.sourceHash)} (${m.contentString.isEmpty ? 'addressed' : m.contentString})');
            return;
          }
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
        // Wapp datagrams carry their own app-layer signature (verified inside the
        // wapp), so deliver them even when we never heard the sender's announce —
        // otherwise a first-contact join request from a peer whose announce hasn't
        // reached us (asymmetric/quiet hubs) would be dropped before the wapp can
        // authenticate it.
        acceptUnverified: (m) => m.fields.containsKey(_kWappLxmfField),
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
          send: (raw) => _transport?.sendLinkAware(raw),
          nextHopFor: (peer) => _transport?.nextHopForIdentity(peer),
          nextHopForDest: (h) => _transport?.pathFor(h)?.nextHop,
          hasPathForDest: (h) => _transport?.hasPath(h) ?? false,
          requestPath: (h) => _transport?.requestPath(h),
          spam: SpamPolicy.lenient(),
          log: (m) => LogService.instance.add('RNS/relay: $m'),
          // Always answer relay queries when hosting isn't disabled, so peers can
          // fetch events we published (e.g. our own kind-0 profile) directly from
          // us — this is request-driven and cheap. The capacity gate still limits
          // the heavy role (accepting OTHERS' content) via admitEvent below.
          serve: PreferencesService.instanceSync?.hostEnabled ?? true,
          // Even when NOT hosting the network, answer queries for OUR OWN posts
          // so a peer can pull what we published directly from us (the poster) —
          // the decentralised "ask the device by callsign for its content" path.
          selfPubHex: () => selfPubHex,
          // Classify an author into a retention tier (0 self / 1 followed /
          // 2 stranger) for hosting quota + eviction.
          tierOfPub: (pub) => tierOf(pub,
              selfPubHex: selfPubHex, followsHex: _follows.asSet).index,
          // Per-tier admission: self always; strangers refused past their
          // monthly note / storage caps. Text notes only here (isMedia false).
          admitEvent: (ev, tier) {
            if (tier == Tier.self.index) return null;
            // kind-4 (NIP-04 DM) is a small, transient store-and-forward mailbox
            // item — admit it regardless of the author's stranger quota; the
            // recipient deletes it (recipient-authorized DROP) once received.
            if (ev.kind == NostrEventKind.encryptedDirectMessage) return null;
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
                selfPubkey: selfPubHex,
                uptimeProvider: () => uptimeSeconds,
                onChanged: (_) => _announceRelayDest(),
              )
            : null;
        _storeForward = StoreForward(
          node: _relay!,
          router: _lxmf!,
          directory: _relayDir,
          log: (m) => LogService.instance.add('RNS/sf: $m'),
        );
        // NOSTR client hub: transport-abstract relays (wss:// internet, rns://
        // Reticulum, local device) all merging into the SAME _relayStore. Plus a
        // local wss:// server so any stock NOSTR app on the LAN uses THIS device
        // as a relay, and its subscribers see mesh + internet events live.
        _nostrWs = NostrWsServer(_relayStore!,
            log: (m) => LogService.instance.add('NOSTR/wss: $m'));
        // ignore: discarded_futures
        _nostrWs!.start();
        // The NOSTR relay pipeline (WebSocket receive, decode, verify, SQLite,
        // like/reply/profile tallies) all runs on a DEDICATED background isolate
        // via NostrEngine — the UI isolate only sends commands + reads caches, so
        // a public firehose can never make the app unresponsive. Its store is a
        // separate SQLite file opened INSIDE that isolate.
        final base = relayStorePath == null
            ? null
            : relayStorePath!.replaceAll(RegExp(r'[^/]*$'), '');
        if (base != null) {
          // ignore: discarded_futures
          NostrClient.spawn(
            storePath: '${base}nostr_feed.sqlite3',
            persistPath: '${base}nostr_relays.json',
            selfPubHex: selfPubHex,
          ).then((c) => _nostrHub = c);
        }
      } catch (e) {
        LogService.instance.add('RNS/relay: disabled (store open failed: $e)');
        _relay = null;
      }

      // Restore discovered peers (callsign->identity) so backfill can query
      // known posters immediately instead of re-waiting for their announces.
      _loadCallPeers();

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
            queryProvider: (p, f) async =>
                (await _relay?.query(p, f,
                        timeout: const Duration(seconds: 12))) ??
                    const [],
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
        // Keep the responder answering queries (so peers can fetch our published
        // profile/notes) regardless of capacity; only the heavy hosting role is
        // capacity-gated, via admitEvent.
        if (_relay != null) {
          _relay!.serve = PreferencesService.instanceSync?.hostEnabled ?? true;
        }
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

      // Persistent observed-node cache (path chosen by the app — the reticulum
      // wapp's data folder). Load the durable first-seen map so restarts keep
      // the true first-seen, and flush dirty nodes on a slow timer.
      if (observedStorePath != null && _obStore == null) {
        final st = ObservedStore(observedStorePath!);
        if (st.open()) {
          _obStore = st;
          _firstSeenByHex.addAll(st.loadFirstSeen());
          _obStats = st.stats();
          _obFlushTimer =
              Timer.periodic(const Duration(seconds: 20), (_) => _flushObserved());
          LogService.instance.add(
              'RNS: observed cache at $observedStorePath (${_firstSeenByHex.length} known)');
        }
      }

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
          await _attachTcpUplink(host, port);
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

      // Edge-bridge: an internet-connected node ALSO brings up its BLE radio and
      // relays BLE-side peers onto the hubs, so a BLE-only phone becomes
      // reachable from across the world (A —BLE→ us —TCP→ hubs → C). Automatic
      // and non-fatal: skipped where BLE5 is unsupported (e.g. desktop), leaving
      // a normal leaf. BLE-only nodes (ble/ble5 modes) are the leaf being
      // bridged, so they don't add a second BLE interface here.
      if (mode == 'tcpclient' || mode == 'tcpserver') {
        await _enableBleBridge();
      }

      // Local loopback gateway: let other geogram apps on this device share this
      // node (one identity, one set of uplinks) instead of each binding their
      // own ports. Loopback-only and non-fatal if the port is taken.
      if (localGateway && _gateway == null) {
        try {
          final g = RnsTcpServerInterface(
            port: localGatewayPort,
            bindHost: '127.0.0.1',
            transport: _transport!,
            onPacket: _onInbound,
            shared: false,
            log: (m) => LogService.instance.add('RNS/gw: $m'),
          );
          await g.bind();
          _gateway = g;
          LogService.instance
              .add('RNS: local gateway on 127.0.0.1:$localGatewayPort');
        } catch (e) {
          LogService.instance.add('RNS: local gateway unavailable: $e');
        }
      }

      // LAN auto-peering: a UDP broadcast interface so co-located Aurora
      // devices (same Wi-Fi/LAN) discover each other and exchange announces +
      // links DIRECTLY — without depending on the public hub to cross-forward
      // between its clients (which it doesn't). This is what makes media fetch
      // and FEED backfill work between devices on the same network even with no
      // always-on relay. Best-effort + non-fatal (e.g. no UDP on the platform).
      if (_lan == null && mode != 'ble' && mode != 'ble5') {
        try {
          final lan = RnsLanInterface(
            port: _lanDiscoveryPort,
            onPacket: (raw) => _onInbound(raw, 'lan'),
            log: (m) => LogService.instance.add('RNS/lan: $m'),
            label: 'lan',
          );
          await lan.bind();
          _lan = lan;
          _transport!.addInterface(lan);
          _ifaces.add(lan);
          LogService.instance.add(
              'RNS: LAN on UDP $_lanDiscoveryPort (announce bcast + unicast data)');
        } catch (e) {
          LogService.instance.add('RNS: LAN auto-peering unavailable: $e');
        }
      }

      _up = true;
      _startedAt ??= DateTime.now();
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
        for (final c in _clients) {
          // ignore: discarded_futures
          c.close();
        }
        _clients.clear();
        _connectedHubs.clear();
        _ifaces.clear();
        return false;
      }

      LogService.instance
          .add('RNS: node up mode=$mode id=${_id!.hexHash} dest=$destHex');
      // Warm-start discovery from the persistent peer cache: seed the DHT overlay
      // and pull paths to the steadiest known geogram nodes first, so folder/file
      // discovery works within seconds instead of waiting minutes for live
      // announces to converge.
      unawaited(_warmStartFromCache());
      _scheduleAnnounce();
      _republishTimer?.cancel();
      _republishTimer = Timer.periodic(_republishEvery, (_) {
        if (_up) _files?.republishAll();
        // Reclaim stale/abandoned resumable-download partials (week-old or over a
        // 2 GB budget) so they don't accumulate on disk.
        // ignore: discarded_futures
        _partialStore?.gc(
            maxAge: const Duration(days: 7), maxBytes: 2 * 1024 * 1024 * 1024);
      });
      // Pull newer versions of files the user downloaded from auto-sync folders.
      _autoSyncTimer?.cancel();
      _autoSyncTimer = Timer.periodic(const Duration(minutes: 5), (_) {
        if (_up) {
          _autoSyncTick();
          refreshFollowedProfiles(); // keep followed nicknames/avatars current
        }
      });
      // Keep trying, every now and then, to fetch followed profiles we still
      // don't have (the author may have been unreachable on earlier attempts).
      _profileRetryTimer?.cancel();
      _profileRetryTimer = Timer.periodic(const Duration(seconds: 90), (_) {
        if (_up) _retryWantedProfiles();
      });
      // Hub-uplink watchdog: a connected hub floods signed announces nonstop, so
      // a stretch of total silence while "up" means the uplink died — typically a
      // network change (Wi-Fi⇄cellular, AP roam) that kills the socket without a
      // clean FIN. Reconnect on that silence (the socket onDisconnect handles the
      // clean-close case faster). Only the tcpclient uplink needs this.
      _linkWatchdog?.cancel();
      if (mode == 'tcpclient') {
        _lastInboundMs = DateTime.now().millisecondsSinceEpoch;
        _linkWatchdog = Timer.periodic(const Duration(seconds: 10), (_) {
          if (!_up || _clients.isEmpty) return;
          final silent =
              DateTime.now().millisecondsSinceEpoch - _lastInboundMs;
          if (silent > _linkSilenceTimeout.inMilliseconds) {
            _allLinksDown('no inbound for ${silent ~/ 1000}s');
          }
        });
      }
      return true;
    } catch (e) {
      LogService.instance.add('RNS: start error: $e');
      // Only the connect attempt failed — keep the local services (disk folders
      // stay usable offline) and just clean up the half-open interface so the
      // next retry reconnects without rebuilding or re-scanning anything.
      try {
        await _server?.close();
      } catch (_) {}
      try {
        await _gateway?.close();
      } catch (_) {}
      _server = null;
      _gateway = null;
      for (final c in _clients) {
        // ignore: discarded_futures
        c.close();
      }
      _clients.clear();
      _connectedHubs.clear();
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
    // No geogram/dht announce: DHT RPC rides the chat dest now (the dht dest is
    // never dialled), and overlay membership is learned from the chat/files
    // announces. Dropping it removes one of the per-cycle service announces so the
    // ones that matter are less likely to hit the hubs' announce budget. The
    // Kademlia node id is still derived from geogram/dht locally — it needs no
    // announce.
    for (final aspects in [_aspectsFiles]) {
      final pkt = await RnsAnnounceBuilder.build(_id!, _app, aspects,
          appData: Uint8List(0));
      _transport!.sendOnAll(pkt.pack());
    }
    await _announceLxmfDests();
    // Announce our relay role + interest set so peers can find/rank us.
    await _announceRelayDest();
  }

  /// Announce our LXMF delivery + propagation destinations so peers (and other
  /// LXMF clients, e.g. Sideband/NomadNet) can route messages to us, and so a
  /// path request for either can be answered by the hub we're attached to. Split
  /// out so the rendezvous re-announce can keep these fresh at a FAST cadence
  /// while we have joinable circles — a short-code applicant resolves our beacon
  /// quickly but then must PATH-REQUEST our delivery dest to push its join
  /// request, and the normal 30s–5min service-announce cadence is too slow.
  Future<void> _announceLxmfDests() async {
    if (!_up || _id == null || _transport == null) return;
    final lx = await RnsAnnounceBuilder.build(
        _id!, kLxmfApp, kLxmfDeliveryAspects,
        appData: Uint8List.fromList(utf8.encode(_announceText)));
    _transport!.sendOnAll(lx.pack());
    final lp = await RnsAnnounceBuilder.build(
        _id!, kLxmfApp, kLxmfPropagationAspects);
    _transport!.sendOnAll(lp.pack());
  }

  /// Announce the relay destination carrying our role/capacity/interest summary
  /// (RelayAnnouncement). Peers collect these into their RelayDirectory.
  Future<void> _announceRelayDest() async {
    if (!_up || _id == null || _relayRole == null) return;
    _relayRole!.selfPubkey = selfPubHex; // advertise our npub for profile fetch
    final pkt = await RnsAnnounceBuilder.build(_id!, kRelayApp, kRelayAspects,
        appData: _relayRole!.announcementAppData());
    _transport!.sendOnAll(pkt.pack());
  }

  static const List<String> _aspectsFiles = kFilesAspects;
  static const List<String> _aspectsDht = kDhtAspects;

  // ── Wapp datagram channel ───────────────────────────────────────────────────

  /// Start queueing inbound datagrams for wapp [tag] (the calling wapp's id).
  /// Idempotent; call again on each wapp load.
  void wappRegister(String tag) => _wappInbox.putIfAbsent(tag, () => []);

  /// Stop queueing for [tag] and drop any buffered datagrams.
  void wappUnregister(String tag) => _wappInbox.remove(tag);

  /// Broadcast [payload] to every reachable peer running wapp [tag]. Returns
  /// false if the node isn't up. The payload must fit one packet (a few hundred
  /// bytes) — larger transfers should be chunked by the wapp. Content privacy is
  /// the wapp's responsibility (encrypt before calling).
  Future<bool> wappBroadcast(String tag, Uint8List payload) async {
    if (!_up || _id == null) return false;
    // RAW app_data: [tagLen:1][tag][payload]. Earlier this JSON-wrapped a base64
    // payload, which inflated it ~33% and pushed the announce past the 500B MTU —
    // so a ~300B datagram (e.g. a join request) silently failed to send at all
    // (pack() throws inside a fire-and-forget async). Raw bytes avoid the inflation
    // so the same datagram fits one announce; we still guard the MTU and skip
    // (logging) anything too big rather than throwing into the void.
    final tagB = utf8.encode(tag);
    final appData = Uint8List(1 + tagB.length + payload.length)
      ..[0] = tagB.length & 0xff
      ..setRange(1, 1 + tagB.length, tagB)
      ..setRange(1 + tagB.length, 1 + tagB.length + payload.length, payload);
    final pkt =
        await RnsAnnounceBuilder.build(_id!, _app, _aspectsWapp, appData: appData);
    Uint8List raw;
    try {
      raw = pkt.pack();
    } catch (_) {
      LogService.instance.add(
          'RNS/wapp: broadcast for "$tag" too big for one announce (${appData.length}B app_data) — skipped');
      return false;
    }
    _transport!.sendOnAll(raw);
    return true;
  }

  /// Drain queued inbound datagrams for wapp [tag]. Each entry is
  /// {from: identityHex, payload: base64, ts: epochMs}.
  List<Map<String, dynamic>> wappDrain(String tag) {
    final q = _wappInbox[tag];
    if (q == null || q.isEmpty) return const [];
    final out = List<Map<String, dynamic>>.from(q);
    q.clear();
    return out;
  }

  /// LXMF field key marking a message as a wapp datagram: value = [tag, payload].
  /// Lets the reliable LXMF transport (direct + store-and-forward) carry wapp
  /// datagrams ADDRESSED to a specific peer, instead of the broadcast announce
  /// channel — the receiving wapp gets them on the same [_wappInbox] queue.
  static const int _kWappLxmfField = 0xB0;

  /// Reliably deliver wapp datagram [payload] for [tag] to ONE peer's LXMF
  /// delivery dest [destHex] (direct if reachable, else held for the peer to
  /// pull). Returns true on direct delivery (false also means "stored to relay").
  Future<bool> wappSendTo(String tag, String destHex, Uint8List payload) async {
    if (!_up || _id == null) return false;
    return sendLxmf(destHex: destHex, fields: {
      _kWappLxmfField: [tag, payload],
    });
  }

  /// Pull store-and-forwarded wapp datagrams a peer holds for us from its
  /// propagation dest [propDestHex]. Delivered datagrams land on [_wappInbox].
  Future<int> wappPull(String propDestHex) => pullLxmf(propDestHex);

  /// If [m] is a wapp datagram (carries [_kWappLxmfField]), route it to the
  /// matching wapp inbox and return true (so it isn't shown as an LXMF chat).
  bool _routeWappLxmf(LxmfMessage m) {
    final f = m.fields[_kWappLxmfField];
    if (f is! List || f.length < 2) return false;
    final tag = f[0];
    final payload = f[1];
    if (tag is! String || payload is! List) return false;
    final q = _wappInbox[tag];
    if (q != null) {
      q.add({
        'from': _hex(m.sourceHash),
        'payload': base64.encode(List<int>.from(payload)),
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
      while (q.length > 1024) {
        q.removeAt(0);
      }
    }
    return true;
  }

  Future<void> _onInbound(Uint8List raw, String via) async {
    final p = RnsPacket.parse(raw);
    if (p == null) return;
    // Liveness for the hub-uplink watchdog: only a hub uplink ('tcp' or
    // 'tcp:host:port') keeps the mesh "alive"; LAN/gateway/server ('tcps#…')
    // chatter must not mask all hubs being dead.
    if (via == 'tcp' || via.startsWith('tcp:')) {
      _lastInboundMs = DateTime.now().millisecondsSinceEpoch;
    }
    // Remember which interface a link's traffic arrives on, so our outbound link
    // packets (resource parts, etc.) go ONLY there instead of every hub uplink.
    if (p.destType == RnsDestType.link) {
      _transport?.noteLinkIface(p.destHash, via);
    }
    // Link / file-transfer packets (link requests + link-addressed data) are
    // handled by the files node, not the announce path.
    if (p.packetType != RnsPacketType.announce) {
      // Pass the arrival interface's HW MTU so the responder caps the link MTU
      // it confirms to what this return path can actually carry (MTU discovery).
      final arrivalMtu = _transport?.hwMtuForVia(via) ?? kRnsMtu;
      if (await _files?.handlePacket(p, arrivalHwMtu: arrivalMtu) ?? false) {
        return;
      }
      if (await _lxmf?.handlePacket(p) ?? false) return;
      if (await _relay?.handlePacket(p) ?? false) return;
      if (_rvInboundDests.isNotEmpty && await _handleRvInbound(p)) return;
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
    // Fold every (non-self) announce into the observed-node registry so the
    // reticulum wapp can visualize the network we've heard. Done BEFORE the
    // wapp-channel early-return below so wapp/rv destinations are observed too.
    _observeAnnounce(ann, p.hops, via);
    // Wapp datagram channel: a datagram arrives as an announce of the sender's
    // "geogram/wapp" destination carrying RAW app_data [tagLen:1][tag][payload].
    // Route it to the matching per-tag queue and stop — not a chat/route announce.
    final wappHash = RnsDestination.hash(ann.identity, _app, _aspectsWapp);
    if (RnsCrypto.constantTimeEquals(ann.destHash, wappHash)) {
      try {
        final a = ann.appData;
        if (a.length >= 1) {
          final tagLen = a[0];
          if (a.length >= 1 + tagLen) {
            final tag = utf8.decode(a.sublist(1, 1 + tagLen), allowMalformed: true);
            final payload = a.sublist(1 + tagLen);
            final q = _wappInbox[tag];
            if (q != null) {
              q.add({
                'from': ann.identity.hexHash,
                'payload': base64.encode(payload),
                'ts': DateTime.now().millisecondsSinceEpoch,
              });
              while (q.length > 1024) {
                q.removeAt(0);
              }
            }
          }
        }
      } catch (_) {}
      return;
    }
    // Learn the peer as a DHT contact from ANY of its Aurora-app announces (dht
    // OR files; the chat announce below adds it too). Every Aurora node runs the
    // DHT, and a contact's DHT id is derived from its IDENTITY regardless of
    // which aspect we heard — so keying overlay membership off ONLY the dedicated
    // "geogram/dht" announce was fragile: the public hubs rate-limit announce
    // propagation, and that single announce is frequently dropped while the same
    // node's files/chat announces get through (observed live: a peer's chat
    // announce arrived but its dht announce never did, so it never joined the
    // overlay and folder discovery failed). Matching any "geogram" dest is still
    // a cryptographic identity↔name proof, so non-Aurora identities
    // (Sideband/NomadNet/rnsd) — which never announce a "geogram" dest — are
    // still never added; lookups don't waste rounds on nodes that can't answer.
    final dhtHash = RnsDestination.hash(ann.identity, _app, _aspectsDht);
    final filesHash = RnsDestination.hash(ann.identity, _app, _aspectsFiles);
    if (RnsCrypto.constantTimeEquals(ann.destHash, dhtHash) ||
        RnsCrypto.constantTimeEquals(ann.destHash, filesHash)) {
      _files?.addPeerFromAnnounce(ann.identity);
    }
    // Relay directory: record a peer's relay role announcement.
    final relayHash = RnsDestination.hash(ann.identity, kRelayApp, kRelayAspects);
    if (RnsCrypto.constantTimeEquals(ann.destHash, relayHash)) {
      final e = _relayDir.observe(ann.identity, ann.appData, hops: p.hops + 1);
      // If this relay belongs to a followed author we couldn't reach before,
      // its npub→identity is now known — try fetching its profile.
      final pk = e?.announcement.pubkey;
      if (pk != null && _follows.contains(pk.toLowerCase())) {
        _maybeFetchFollowedProfileByPub(pk.toLowerCase());
      }
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
      // A chat announce is also proof of an Aurora node → DHT overlay member
      // (its dedicated dht announce may have been dropped in the hubs' announce
      // budget). This is the announce most reliably propagated, so it is the key
      // one for overlay convergence.
      _files?.addPeerFromAnnounce(ann.identity);
      final cs = text.trim();
      if (cs.isNotEmpty && cs.length <= 20 && !cs.contains(' ')) {
        final isNewPeer = _callIdentity[cs]?.hexHash != ann.identity.hexHash;
        _callsignDest[cs] = _hex(ann.destHash);
        _callIdentity[cs] = ann.identity;
        // Persist the discovered peer so backfill can query it on the next
        // launch without re-waiting for its announce.
        if (isNewPeer) _scheduleCallPeersSave();
        // Now that we can reach this peer directly, fetch its profile if we
        // follow it and don't have it yet.
        _maybeFetchFollowedProfile(cs);
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

  /// Live download progress (received, total bytes) for an in-flight
  /// content-addressed fetch of [fileHash] (32B) over Reticulum, or null when
  /// nothing is downloading for it. Drives the chat media progress label.
  ({int received, int total})? fileFetchProgress(Uint8List fileHash) =>
      _files?.fetchProgress(fileHash);

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

  /// THE single content-addressed fetch path over Reticulum, used by folders /
  /// updates / the wapp store AND APRS shared media. Given a file's [sha] (32B):
  ///   1. return a local copy if we already hold it (instant, no network);
  ///   2. if [fromCallsign] is set, fetch DIRECTLY from that sender (the most
  ///      reliable cross-network path — it's exactly who referenced the file);
  ///   3. otherwise / on miss, discover providers via the DHT and multi-source
  ///      fetch.
  /// The bytes are sha256-verified by the file layer (every chunk + the whole
  /// file), then stored in the serve archive under [ext] and re-advertised (a
  /// provider record) so this node becomes a holder others can pull from — every
  /// downloader becomes a seeder. Returns the verified bytes, or null on failure.
  Future<Uint8List?> fetchContentAddressed(
    Uint8List sha, {
    String ext = '',
    String? fromCallsign,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    // 1) Local hit — content is addressed by sha, so a copy we hold is identical
    // and instant. Lets a mirror answer when the owner is offline. Already a
    // holder, so no re-seed needed.
    final local = localFileBytes(sha);
    if (local != null) return local;
    if (!_up) return null;
    Uint8List? bytes;
    // 2) Direct from the named sender (route learned from its chat announce).
    if (fromCallsign != null && fromCallsign.isNotEmpty) {
      bytes = await fetchFileFromCallsign(sha, fromCallsign, timeout: timeout);
    }
    // 3) DHT discovery + multi-source fetch.
    if (bytes == null || bytes.isEmpty) {
      bytes = await dhtResolveFetch(sha, timeout: timeout);
    }
    if (bytes == null || bytes.isEmpty) return null;
    _archiveAndReseed(sha, bytes, ext);
    return bytes;
  }

  /// Store verified content-addressed [bytes] in the serve archive and advertise
  /// ourselves as a provider so peers can fetch them from us (re-seed).
  void _archiveAndReseed(Uint8List sha, Uint8List bytes, String ext) {
    final src = fileServeSource;
    if (src is MediaFileSource) {
      try {
        src.archive.putBytes(bytes, ext);
      } catch (e) {
        // A missing/non-media extension (e.g. an empty ext) must NOT discard a
        // file we already fetched successfully — the caller still gets the
        // bytes. We just can't honestly re-seed what we couldn't store, so skip
        // advertising ourselves as a provider in that case.
        LogService.instance.add('RNS/files: archive skipped for ${_hex(sha).substring(0, 8)} ($e)');
        return;
      }
    }
    // ignore: discarded_futures
    _files?.publishProvider(sha, capacity: selfCapacity); // become a provider
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
    // Self-heal: if we have no path to the recipient yet, pull one (path
    // request) and wait briefly. This lets delivery reach a peer whose announce
    // never passively flooded to us over busy/asymmetric public hubs.
    final t = _transport;
    if (t != null && !t.hasPath(dh)) {
      t.requestPath(dh);
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      while (!t.hasPath(dh) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    final msg = await LxmfMessage.create(
      destinationHash: dh,
      source: _id!,
      title: title,
      content: content,
      fields: fields,
    );
    return r.send_(msg);
  }

  /// Send a 1:1 LXMF message to a peer identified by its 64-byte public key hex
  /// (as carried in graphSnapshot's meta.pubkey). Derives the peer's LXMF
  /// delivery destination from the key — the same way the peer computes its own
  /// ([LxmfRouter.deliveryDestHash]) — then delegates to [sendLxmf]. Lets the
  /// reticulum wapp message an observed node straight from the graph without it
  /// ever announcing a pre-computed delivery hash. Returns false on a malformed
  /// key or when the stack is down.
  Future<bool> sendLxmfToPubkey({
    required String pubkeyHex,
    String title = '',
    String content = '',
  }) async {
    final pub = _bytesFromHex(pubkeyHex);
    if (pub == null || pub.length != 64) return false;
    final RnsIdentity id;
    try {
      id = RnsIdentity.fromPublicKey(pub);
    } catch (_) {
      return false;
    }
    final destHex = _hex(RnsDestination.hash(id, kLxmfApp, kLxmfDeliveryAspects));
    LogService.instance.add(
        'RNS: lxmf.send -> $destHex (pubkey ${pubkeyHex.substring(0, 8)})');
    final ok = await sendLxmf(destHex: destHex, title: title, content: content);
    LogService.instance
        .add('RNS: lxmf.send ${ok ? 'ok' : 'failed'} -> $destHex');
    return ok;
  }

  /// This node's LXMF propagation (cooperative mailbox) destination hash, hex.
  String? get lxmfPropagationHex {
    final lx = _lxmf;
    return lx == null ? null : _hex(lx.propagationDestHash);
  }

  /// Pull store-and-forwarded messages a peer is holding for us from its
  /// propagation destination [propDestHex]. We initiate the link (works even
  /// when our inbound is unreachable). Returns the number of messages delivered.
  Future<int> pullLxmf(String propDestHex) async {
    final lx = _lxmf;
    final dh = _bytesFromHex(propDestHex);
    if (!_up || lx == null || dh == null) return 0;
    return lx.pullFrom(dh);
  }

  // ── Short-code rendezvous (discovery without a directory) ──────────────────
  // A public short code (e.g. a circle's "5cc-d08") is deterministically mapped
  // to an RNS identity. A circle owner/member ANNOUNCES a "circles/rv" dest of
  // that identity carrying its real address; a joiner holding only the short
  // code derives the same identity, PATH-REQUESTS the dest, and reads the
  // address — bootstrapping addressed contact. Not secret (the code is public);
  // it is only a meeting point, membership is still owner-approved + encrypted.
  final Map<String, Uint8List> _rvCache = {}; // seedHex -> resolved appData
  final Set<String> _rvPending = {};
  // Active rendezvous beacons we (the owner) keep fresh: seedHex -> (appData,
  // lastRefreshMs). The wapp re-asserts each via rvAnnounce roughly once per
  // circle_tick (~15s), but a fresh circle needs its beacon propagated FAST and
  // OFTEN for a joiner's path request to land, so a host timer re-announces every
  // few seconds independent of the slow wapp tick. Entries not re-asserted for a
  // while (circle deleted / no longer owned) expire so this never grows unbounded.
  final Map<String, ({Uint8List appData, int lastMs})> _rvActive = {};
  Timer? _rvTimer;
  static const Duration _rvReannounceEvery = Duration(seconds: 8);
  static const int _rvActiveTtlMs = 90 * 1000;
  // rvDestHashHex -> the rv identity we (the owner) hold for it, so we can RECEIVE
  // a join request sent connectionlessly to our rendezvous dest and decrypt it.
  // This is the first-contact channel: a non-member applicant can't be pulled and
  // the owner's normal delivery-dest inbound may be path-stale, but the rv dest is
  // re-announced every 8s (flood-exempt) so the hub keeps a fresh route to us.
  final Map<String, RnsIdentity> _rvInboundDests = {};

  void _emitRvAnnounce(Uint8List seed, Uint8List appData) {
    final t = _transport;
    if (!_up || t == null) return;
    unawaited(() async {
      final id = await _rvIdentity(seed);
      final dest = RnsDestination.hash(id, 'circles', const ['rv']);
      _rvInboundDests[_hex(dest)] = id; // listen for inbound jr on this dest
      final pkt = await RnsAnnounceBuilder.build(id, 'circles', const ['rv'],
          appData: appData);
      t.sendOnAll(pkt.pack());
    }());
  }

  /// Owner side: a connectionless DATA packet to one of our rendezvous dests is a
  /// join request from an applicant that resolved our beacon. Decrypt it with the
  /// rv identity and hand the payload to the circles wapp inbox (it is the same
  /// signed `jr` datagram the wapp would get over LXMF; handle_jr verifies it).
  Future<bool> _handleRvInbound(RnsPacket p) async {
    if (p.packetType != RnsPacketType.data ||
        p.destType != RnsDestType.single) {
      return false;
    }
    final id = _rvInboundDests[_hex(p.destHash)];
    if (id == null) return false;
    try {
      final plain = await id.decrypt(p.data);
      final q = _wappInbox['circles'];
      if (q != null) {
        q.add({
          'from': '',
          'payload': base64.encode(plain),
          'ts': DateTime.now().millisecondsSinceEpoch,
        });
        while (q.length > 1024) {
          q.removeAt(0);
        }
        LogService.instance.add(
            'RNS/rv: join request received on rendezvous dest ${_hex(p.destHash).substring(0, 8)} (${plain.length}B)');
      }
    } catch (_) {
      // Not addressed to us / undecryptable — ignore.
    }
    return true;
  }

  /// Applicant side: send [payload] (a signed join-request datagram) to the
  /// rendezvous dest derived from [seed] (the circle's short code) as ONE
  /// encrypted connectionless packet. The owner listens there (see
  /// [_handleRvInbound]). No link handshake, so it survives a flaky owner inbound.
  void rvSend(Uint8List seed, Uint8List payload) {
    final t = _transport;
    if (!_up || t == null) return;
    unawaited(() async {
      final id = await _rvIdentity(seed);
      final dest = RnsDestination.hash(id, 'circles', const ['rv']);
      final enc = await id.encrypt(payload);
      if (enc.length + 24 > 500) {
        LogService.instance.add(
            'RNS/rv: join request too big for one packet (${enc.length}B) — relying on direct/broadcast');
        return;
      }
      // Self-heal a path to the rv dest so this works even without a prior beacon
      // resolution: without a path `sendDataTo` can only HEADER_1-broadcast, which
      // a hub may not forward toward a SINGLE dest. The owner announces the rv dest
      // flood-exempt every ~8s, so a path request is normally answered quickly.
      if (!t.hasPath(dest)) {
        t.requestPath(dest);
        final deadline = DateTime.now().add(const Duration(seconds: 12));
        while (!t.hasPath(dest) && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
      t.sendDataTo(dest, enc);
    }());
  }

  void _rvReannounceTick() {
    if (!_up || _transport == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _rvActive.removeWhere((_, v) => now - v.lastMs > _rvActiveTtlMs);
    if (_rvActive.isEmpty) return;
    for (final e in _rvActive.entries) {
      _emitRvAnnounce(_bytesFromHexOrEmpty(e.key), e.value.appData);
    }
    // While we have joinable circles, keep our delivery/propagation dests fresh
    // too so an applicant that just resolved our beacon can immediately path to
    // our delivery dest and push its join request (the slow service-announce
    // cadence would otherwise leave that path unresolvable for minutes).
    unawaited(_announceLxmfDests());
  }

  Uint8List _bytesFromHexOrEmpty(String hex) =>
      _bytesFromHex(hex) ?? Uint8List(0);

  Future<RnsIdentity> _rvIdentity(Uint8List seed) async {
    final xPrv = Uint8List.fromList(
        crypto.sha256.convert([...utf8.encode('circles-rv-x|'), ...seed]).bytes);
    final ePrv = Uint8List.fromList(
        crypto.sha256.convert([...utf8.encode('circles-rv-e|'), ...seed]).bytes);
    final prv = Uint8List(64)
      ..setAll(0, xPrv)
      ..setAll(32, ePrv);
    return RnsIdentity.fromPrivateKey(prv);
  }

  /// Announce the rendezvous destination for [seed] carrying [appData] (e.g. the
  /// full circle id + our delivery dest). Sends immediately AND registers the
  /// beacon so a host timer keeps re-announcing it every few seconds (decoupled
  /// from the slow wapp tick), so a joiner's path request can be answered fast —
  /// critical for a freshly-created circle whose beacon isn't cached on any hub.
  void rvAnnounce(Uint8List seed, Uint8List appData) {
    final t = _transport;
    if (!_up || t == null) return;
    _rvActive[_hex(seed)] = (
      appData: appData,
      lastMs: DateTime.now().millisecondsSinceEpoch,
    );
    _emitRvAnnounce(seed, appData);
    _rvTimer ??= Timer.periodic(_rvReannounceEvery, (_) => _rvReannounceTick());
  }

  /// Resolve the rendezvous for [seed] — returns the announced appData, or empty
  /// while pending (kicks off the async path-request on first call). The joiner
  /// polls this until it returns the owner's address.
  Uint8List rvResolve(Uint8List seed) {
    final t = _transport;
    if (!_up || t == null) return Uint8List(0);
    final key = _hex(seed);
    final cached = _rvCache[key];
    if (cached != null) return cached;
    if (!_rvPending.contains(key)) {
      _rvPending.add(key);
      unawaited(() async {
        final id = await _rvIdentity(seed);
        final dest = RnsDestination.hash(id, 'circles', const ['rv']);
        // Run well past one owner re-announce interval so a beacon that lands
        // mid-window is caught; the wapp's discovery_tick re-arms this between
        // windows. With the owner re-announcing every ~8s and the beacon now
        // flood-exempt, resolution typically lands within the first window.
        final deadline = DateTime.now().add(const Duration(seconds: 40));
        while (DateTime.now().isBefore(deadline)) {
          final e = t.pathFor(dest);
          if (e != null && e.appData.isNotEmpty) {
            _rvCache[key] = e.appData;
            break;
          }
          t.requestPath(dest);
          await Future<void>.delayed(const Duration(milliseconds: 600));
        }
        _rvPending.remove(key);
      }());
    }
    return Uint8List(0);
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
  Future<String?> publishNote(String text, {String? topic, String? parent}) async {
    final t = text.trim();
    final pub = selfPubHex;
    final priv = _profilePrivHex();
    if (t.isEmpty || pub == null || priv == null) return null;
    final tags = <List<String>>[];
    if (topic != null && topic.isNotEmpty) tags.add(['t', topic]);
    // Carry the reply parent (the APRS thread id) so a backfilled reply threads
    // under the right post instead of polluting the top-level feed.
    if (parent != null && parent.isNotEmpty) tags.add(['parent', parent]);
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
    // Replicate to EVERY known indexer (freshest first, capped), not just the
    // single "best" one. Redundant holders are the reliability fix: a joiner
    // queries indexers in parallel, so the more that hold this note, the more
    // likely at least one answers over the flaky public mesh (a single-holder
    // query frequently gets no response back).
    if (_relay != null) {
      final seen = <String>{};
      var fanned = 0;
      for (final ix in _relayDir.indexers()) {
        if (!seen.add(ix.identity.hexHash)) continue;
        // ignore: discarded_futures
        _relay!.publish(ix.identity, ev);
        if (++fanned >= 5) break; // bound the fan-out
      }
    }
    return stored;
  }

  /// Schedule a debounced write of the discovered callsign->identity map.
  void _scheduleCallPeersSave() {
    _callPeersSaveTimer?.cancel();
    _callPeersSaveTimer = Timer(const Duration(seconds: 5), _saveCallPeers);
  }

  /// Persist the discovered callsign->identity map (callsign -> 64B public key
  /// hex) so a returning node can query known posters immediately on launch.
  Future<void> _saveCallPeers() async {
    final path = callPeersPath;
    if (path == null || path.isEmpty) return;
    try {
      final m = <String, String>{};
      _callIdentity.forEach((cs, id) => m[cs] = _hex(id.getPublicKey()));
      await File(path).writeAsString(jsonEncode(m), flush: true);
    } catch (_) {
      // best-effort cache; ignore write errors
    }
  }

  /// Restore the persisted callsign->identity map on start. Stale entries are
  /// harmless (a query to a peer that moved simply gets no answer + is refreshed
  /// by the next live announce).
  void _loadCallPeers() {
    final path = callPeersPath;
    if (path == null || path.isEmpty) return;
    try {
      final f = File(path);
      if (!f.existsSync()) return;
      final m = jsonDecode(f.readAsStringSync());
      if (m is! Map) return;
      var n = 0;
      m.forEach((cs, ph) {
        if (cs is! String || ph is! String) return;
        final pub = _hexToBytes(ph);
        if (pub == null || pub.length != 64) return;
        final id = RnsIdentity.fromPublicKey(pub);
        _callIdentity[cs] = id;
        _callsignDest[cs] = _hex(RnsDestination.hash(id, _app, _aspects));
        n++;
      });
      if (n > 0) {
        LogService.instance.add('RNS: restored $n known peer(s) from cache');
      }
    } catch (_) {
      // corrupt cache — start clean
    }
  }

  /// Backfill the FEED stream from Reticulum: ask every known relay peer (and
  /// the best indexer) for kind-1 notes tagged [topic] with created_at >=
  /// [sinceSec], so posts that were lost over APRS-IS get recovered. Each peer
  /// serves at least its own notes. Fetched notes are cached in our store and
  /// returned as raw maps {pub, text, parent, ts} (newest first); the caller
  /// reconstructs the feed entries (callsign from pubkey, etc.). NOSTR-native.
  Future<List<Map<String, dynamic>>> fetchFeedBackfill(int sinceSec,
      {String topic = 'activity', int limit = 300}) async {
    final relay = _relay;
    final store = _relayStore;
    if (relay == null) return const [];
    final filter = NostrFilter(
        kinds: const [1], tags: {'t': [topic]}, since: sinceSec, limit: limit);
    final byId = <String, NostrEvent>{};
    void take(Iterable<NostrEvent> evs) {
      for (final e in evs) {
        if (e.id != null) byId.putIfAbsent(e.id!, () => e);
      }
    }

    // Local store first (cheap), then every reachable Aurora node we know.
    if (store != null) take(store.query(filter));
    final targets = <RnsIdentity>[];
    final best = _relayDir.bestIndexer(topic: topic);
    if (best != null) targets.add(best.identity);
    for (final e in _relayDir.entries()) {
      targets.add(e.identity);
    }
    // ALSO query every Aurora peer we discovered by its callsign announce, even
    // if it isn't a hosting indexer: each node answers at least its OWN posts,
    // so a joiner pulls what others published directly from the posters — the
    // decentralised path that doesn't depend on anyone hosting the network.
    for (final id in _callIdentity.values) {
      targets.add(id);
    }
    // Dedup, cap, and query peers in PARALLEL with a short timeout, so one
    // slow/unreachable peer can't stall the sweep and the queries don't pile up.
    final seen = <String>{};
    final unique = <RnsIdentity>[];
    for (final id in targets) {
      if (seen.add(_hex(id.hash))) unique.add(id);
    }
    const maxPeers = 12;
    final pick =
        unique.length <= maxPeers ? unique : unique.sublist(0, maxPeers);
    // Generous per-query timeout: a relay link to a peer through a busy public
    // hub is several round-trips and can take 20s+. Queries run in parallel, so
    // a long timeout doesn't serialise the sweep.
    final results = await Future.wait(pick.map((id) async {
      try {
        return await relay.query(id, filter,
            timeout: const Duration(seconds: 40));
      } catch (_) {
        return const <NostrEvent>[];
      }
    }));
    var hostsAnswered = 0;
    for (final r in results) {
      if (r.isNotEmpty) hostsAnswered++;
      take(r);
    }
    if (pick.isNotEmpty) {
      LogService.instance.add(
          'RNS/relay: FEED backfill queried ${pick.length} peer(s) '
          '($hostsAnswered answered)');
    }

    final out = <Map<String, dynamic>>[];
    final tierFollows = _follows.asSet;
    for (final e in byId.values) {
      // Cache the note in our store too (so we can serve it onward + keep it).
      store?.put(e,
          tier: tierOf(e.pubkey, selfPubHex: selfPubHex, followsHex: tierFollows)
              .index);
      String parent = '';
      for (final t in e.tags) {
        if (t.length >= 2 && t[0] == 'parent') parent = t[1];
      }
      out.add({
        'pub': e.pubkey,
        'text': e.content,
        'parent': parent,
        'ts': e.createdAt,
      });
    }
    out.sort((a, b) => (b['ts'] as int).compareTo(a['ts'] as int));
    if (out.isNotEmpty) {
      LogService.instance
          .add('RNS/relay: FEED backfill fetched ${out.length} note(s)');
    }
    return out;
  }

  /// Publish OUR profile as a NOSTR kind-0 (set_metadata) event, so peers can
  /// fetch it by npub. [name]/[about]/[picture] map to the standard kind-0
  /// fields ({name, about, picture}); [picture] is a `file:<sha>.<ext>` media
  /// token (content-addressed, fetchable over the swarm). Replaceable: the relay
  /// keeps only our newest kind-0. Self-tier (never evicted). Returns event id.
  Future<String?> publishMetadata(
      {String? name, String? about, String? picture}) async {
    final pub = selfPubHex;
    final priv = _profilePrivHex();
    if (pub == null || priv == null) return null;
    final content = <String, dynamic>{};
    if (name != null && name.isNotEmpty) content['name'] = name;
    if (about != null && about.isNotEmpty) content['about'] = about;
    if (picture != null && picture.isNotEmpty) content['picture'] = picture;
    final ev = NostrEvent(
      pubkey: pub,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: NostrEventKind.setMetadata,
      tags: const [],
      content: jsonEncode(content),
    );
    try {
      ev.sign(priv);
    } catch (e) {
      LogService.instance.add('RNS/relay: metadata sign failed: $e');
      return null;
    }
    await relayPublish(ev.toJson());
    return ev.id;
  }

  /// Fetch a peer's profile metadata (kind-0 content map: {name, about,
  /// picture}) by [npubOrHex]. Tries the local relay store first, then the best
  /// known indexer; a fetched event is cached locally for next time. Null if no
  /// metadata is known. (Direct by-npub peer fetch needs the peer's relay
  /// identity, which we don't always have — this is best-effort via indexers.)
  Future<Map<String, dynamic>?> fetchProfileMetadata(String npubOrHex) async {
    final hex = FollowSet.toHex(npubOrHex);
    if (hex == null) return null;
    Map<String, dynamic>? parse(NostrEvent? ev) {
      if (ev == null) return null;
      try {
        final m = jsonDecode(ev.content);
        if (m is Map) return m.cast<String, dynamic>();
      } catch (_) {}
      return null;
    }

    final local = parse(_relayStore?.profileOf(hex));
    if (local != null) return local;
    // Prefer a DIRECT query to the author (we may know its identity from a chat
    // announce) — no third-party indexer needed. Fall back to the best indexer.
    final id = _identityForPub(hex);
    try {
      if (id != null && _relay != null) {
        final evs = await _relay!
            .query(id, NostrFilter(authors: [hex], kinds: const [0], limit: 1));
        if (evs.isNotEmpty) {
          final ev = evs.first;
          _relayStore?.put(ev,
              tier: tierOf(ev.pubkey,
                      selfPubHex: selfPubHex, followsHex: _follows.asSet)
                  .index);
          return parse(ev);
        }
      }
      final res = await _relayRun(
          NostrFilter(authors: [hex], kinds: const [0], limit: 1));
      if (res.isNotEmpty) {
        final ev = NostrEvent.fromJson(res.first);
        final tier =
            tierOf(ev.pubkey, selfPubHex: selfPubHex, followsHex: _follows.asSet);
        _relayStore?.put(ev, tier: tier.index); // cache for next time
        return parse(ev);
      }
    } catch (e) {
      LogService.instance.add('RNS/relay: metadata fetch failed: $e');
    }
    return null;
  }

  /// The RNS identity for a pubkey hex, so we can query that node's relay
  /// directly. Learned either from its chat announce (callsign→identity) or — more
  /// reliably on a busy hub — from its relay announce (which carries its npub and
  /// is kept in the directory with a TTL).
  RnsIdentity? _identityForPub(String pubHex) {
    for (final e in _callPub.entries) {
      if (e.value == pubHex) {
        final id = _callIdentity[e.key];
        if (id != null) return id;
      }
    }
    return _relayDir.identityForPubkey(pubHex);
  }

  // ── Followed-profile auto-fetch + cache (drives nicknames/avatars on the
  //    Activity stream) ──────────────────────────────────────────────────────
  // callsign -> resolved kind-0 content map {name, about, picture}.
  final Map<String, Map<String, dynamic>> _profileMeta = {};
  final Map<String, int> _profileFetchedAt = {}; // callsign -> epoch ms
  final Set<String> _profileInFlight = {};
  static const int _profileTtlMs = 6 * 60 * 60 * 1000; // refetch after 6h

  // Callsigns the app says we follow (the wapp's follow list is authoritative).
  // Their profiles are retried periodically until we have them — see
  // [setFollowedCallsigns] + the retry timer.
  final Set<String> _wantProfiles = {};
  Timer? _profileRetryTimer;

  /// Tell the service which callsigns we follow, so it keeps trying to fetch
  /// their profiles in the background (even if earlier attempts failed).
  void setFollowedCallsigns(Iterable<String> callsigns) {
    _wantProfiles
      ..clear()
      ..addAll(callsigns.map((c) => c.trim()).where((c) => c.isNotEmpty));
    _retryWantedProfiles();
  }

  /// Retry fetching every followed callsign whose profile we don't have yet.
  void _retryWantedProfiles() {
    for (final cs in _wantProfiles) {
      if (!_profileMeta.containsKey(cs)) fetchFollowedProfile(cs);
    }
  }

  final List<void Function()> _profileListeners = [];
  void addProfileListener(void Function() cb) => _profileListeners.add(cb);
  void removeProfileListener(void Function() cb) =>
      _profileListeners.remove(cb);
  void _notifyProfiles() {
    for (final c in List.of(_profileListeners)) {
      try {
        c();
      } catch (_) {}
    }
  }

  /// Resolved profile metadata for [callsign] ({name, about, picture}) or null.
  Map<String, dynamic>? profileMetaFor(String callsign) =>
      _profileMeta[callsign.trim()];

  /// Fetch [callsign]'s profile because the app says we follow it (the wapp's
  /// follow list is authoritative; this bypasses the host pubkey follow-set,
  /// which may not have the key). Reaches the peer via its chat-announce identity
  /// or its relay announce (npub→identity). Deduped + TTL-gated; safe to call
  /// often (e.g. while rendering followed posts).
  void fetchFollowedProfile(String callsign) {
    final cs = callsign.trim();
    if (cs.isEmpty) return;
    final pub = _callPub[cs];
    if (pub == null) return; // need its key first (from the beacon)
    // Show a previously-fetched copy instantly (it persists in the relay store
    // across restarts) even before/without a live path to refresh it.
    _loadCachedProfile(cs, pub);
    if (_profileInFlight.contains(cs)) return;
    final last = _profileFetchedAt[cs] ?? 0;
    if (_profileMeta.containsKey(cs) &&
        DateTime.now().millisecondsSinceEpoch - last < _profileTtlMs) {
      return;
    }
    final id = _callIdentity[cs] ?? _relayDir.identityForPubkey(pub);
    if (id == null) return; // no path yet — retried on the next announce/sweep
    _profileInFlight.add(cs);
    unawaited(_fetchProfileDirect(cs, id, pub));
  }

  /// Populate the display cache from a kind-0 already in our relay store (from a
  /// prior fetch), so a followed profile shows immediately on restart.
  void _loadCachedProfile(String cs, String pub) {
    if (_profileMeta.containsKey(cs)) return;
    final cached = _parseProfileContent(_relayStore?.profileOf(pub)?.content);
    if (cached != null) {
      _profileMeta[cs] = cached;
      _notifyProfiles();
    }
  }

  /// Auto-fetch the profile of a FOLLOWED callsign directly from it, if we don't
  /// already hold a fresh copy and we know how to reach it. Cheap to call often
  /// (deduped + TTL-gated). We deliberately fetch ONLY followed callsigns.
  void _maybeFetchFollowedProfile(String callsign) {
    final cs = callsign.trim();
    if (cs.isEmpty) return;
    final pub = _callPub[cs];
    if (pub == null || !_follows.contains(pub)) return; // followed only
    _loadCachedProfile(cs, pub); // instant display from a prior fetch
    if (_profileInFlight.contains(cs)) return;
    final last = _profileFetchedAt[cs] ?? 0;
    final fresh = _profileMeta.containsKey(cs) &&
        DateTime.now().millisecondsSinceEpoch - last < _profileTtlMs;
    if (fresh) return;
    // Reach the peer via its chat-announce identity, or (more reliably on a busy
    // hub) via its relay announce, which carries its npub in the directory.
    final id = _callIdentity[cs] ?? _relayDir.identityForPubkey(pub);
    if (id == null) return; // can't reach it directly yet — retried on announce
    _profileInFlight.add(cs);
    unawaited(_fetchProfileDirect(cs, id, pub));
  }

  // De-dup / TTL state for observed-peer profile fetches (keyed by pubkey hex),
  // kept separate from the followed-callsign maps above.
  final Set<String> _obProfileInFlight = {};
  final Map<String, int> _obProfileFetchedAt = {};

  /// Best-effort fetch of an OBSERVED peer's kind-0 profile DIRECTLY from it (it
  /// runs a relay), so the reticulum wapp can show its real nickname instead of
  /// the generic announced text. Unlike [_maybeFetchFollowedProfile] this isn't
  /// gated on follow — any reachable geogram device. Deduped + TTL'd; the result
  /// lands in [_relayStore] where [_profileNameFor] reads it next snapshot.
  void _maybeFetchObservedProfile(String pubHex) {
    final r = _relay;
    if (r == null || pubHex.length != 64) return;
    if (_obProfileInFlight.contains(pubHex)) return;
    final last = _obProfileFetchedAt[pubHex] ?? 0;
    final haveFresh = _relayStore?.profileOf(pubHex) != null &&
        DateTime.now().millisecondsSinceEpoch - last < _profileTtlMs;
    if (haveFresh) return;
    final id = _relayDir.identityForPubkey(pubHex);
    if (id == null) return; // can't reach it directly yet
    _obProfileInFlight.add(pubHex);
    unawaited(() async {
      try {
        final evs = await r.query(
            id, NostrFilter(authors: [pubHex], kinds: const [0], limit: 1));
        if (evs.isNotEmpty) {
          final ev = evs.first;
          _relayStore?.put(ev,
              tier: tierOf(ev.pubkey,
                      selfPubHex: selfPubHex, followsHex: _follows.asSet)
                  .index);
          _obProfileFetchedAt[pubHex] = DateTime.now().millisecondsSinceEpoch;
          LogService.instance.add(
              'RNS/relay: fetched observed profile ${pubHex.substring(0, 8)}');
        }
      } catch (_) {
        // best-effort — retried on the next announce
      } finally {
        _obProfileInFlight.remove(pubHex);
      }
    }());
  }

  /// Like [_maybeFetchFollowedProfile] but keyed by pubkey (resolves to the
  /// callsign we learned from the key beacon).
  void _maybeFetchFollowedProfileByPub(String pubHex) {
    for (final e in _callPub.entries) {
      if (e.value == pubHex) {
        _maybeFetchFollowedProfile(e.key);
        return;
      }
    }
  }

  Future<void> _fetchProfileDirect(
      String cs, RnsIdentity id, String pubHex) async {
    try {
      Map<String, dynamic>? content;
      if (_relay != null) {
        final evs = await _relay!.query(
            id, NostrFilter(authors: [pubHex], kinds: const [0], limit: 1));
        if (evs.isNotEmpty) {
          final ev = evs.first;
          _relayStore?.put(ev,
              tier: tierOf(ev.pubkey,
                      selfPubHex: selfPubHex, followsHex: _follows.asSet)
                  .index);
          content = _parseProfileContent(ev.content);
        }
      }
      content ??= _parseProfileContent(_relayStore?.profileOf(pubHex)?.content);
      if (content != null) {
        // Only stamp "fetched" on success, so failures keep being retried.
        _profileFetchedAt[cs] = DateTime.now().millisecondsSinceEpoch;
        _profileMeta[cs] = content;
        LogService.instance
            .add('RNS/relay: fetched profile of $cs (${content['name'] ?? '?'})');
        _notifyProfiles();
      }
    } catch (e) {
      LogService.instance.add('RNS/relay: profile fetch for $cs failed: $e');
    } finally {
      _profileInFlight.remove(cs);
    }
  }

  Map<String, dynamic>? _parseProfileContent(String? content) {
    if (content == null || content.isEmpty) return null;
    try {
      final m = jsonDecode(content);
      if (m is Map) return m.cast<String, dynamic>();
    } catch (_) {}
    return null;
  }

  /// Sweep all followed callsigns and refresh any stale/missing profiles.
  /// Called periodically and right after a new follow.
  void refreshFollowedProfiles() {
    for (final e in _callPub.entries) {
      if (_follows.contains(e.value)) _maybeFetchFollowedProfile(e.key);
    }
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

  // ── NOSTR-relay store-and-forward DM backup (kind-4 NIP-04) ───────────────
  // The APRS wapp uses these (via hal_relay_*) to back up 1:1 messages to up to
  // 3 NOSTR relays reachable over Reticulum: publish each message as a kind-4
  // encrypted DM (BIP-340-signed by the profile key, NIP-04 content), poll the
  // pre-agreed relays for DMs addressed to us, and delete them once received.

  /// Up to [max] reachable relays (their RNS identity hashes, hex) that store +
  /// serve events — i.e. peers we've heard announce a relay role (they run with
  /// hosting on, so serve=true). Indexers are preferred, then any relay entry.
  List<String> relayReachable({int max = 3}) {
    final out = <String>[];
    final seen = <String>{};
    void take(Iterable<RelayEntry> es) {
      for (final e in es) {
        if (out.length >= max) return;
        final h = e.identity.hexHash;
        if (seen.add(h)) out.add(h);
      }
    }
    take(_relayDir.indexers());
    if (out.length < max) take(_relayDir.entries());
    return out;
  }

  /// Up to [max] relays chosen by RENDEZVOUS hashing on [pubkeyHexOrB64] (a
  /// recipient x-only pubkey, hex or the wapp's base64url form): rank every
  /// known relay by sha256(relayHash || pubkey) and take the top ranks. Both
  /// ends compute the SAME set from their own directory view, so the sender's
  /// publish set and the recipient's poll set meet without any control frame
  /// (the one-shot ?RLY announce is exactly what an offline receiver misses).
  List<String> relayDestsFor(String pubkeyHexOrB64, {int max = 3}) {
    var key = pubkeyHexOrB64.trim();
    // Accept the wapp's base64url npub form; normalize to lowercase hex.
    if (key.length != 64 || key.contains(RegExp(r'[^0-9a-fA-F]'))) {
      final b = _b64urlToBytes(key);
      if (b != null && b.length == 32) key = _hex(b);
    }
    key = key.toLowerCase();
    final seen = <String>{};
    final all = <RelayEntry>[
      for (final e in [..._relayDir.indexers(), ..._relayDir.entries()])
        if (seen.add(e.identity.hexHash)) e,
    ];
    final ranked = all.map((e) {
      final h = e.identity.hexHash;
      final score = crypto.sha256.convert(utf8.encode('$h|$key')).toString();
      return (h, score);
    }).toList()
      ..sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final r in ranked.take(max)) r.$1];
  }

  RnsIdentity? _relayIdentity(String hexHash) {
    for (final e in _relayDir.entries()) {
      if (e.identity.hexHash == hexHash) return e.identity;
    }
    return null;
  }

  BigInt _scalarFromHex(String hex) {
    var d = BigInt.zero;
    final b = _hexToBytes(hex);
    if (b == null) return d;
    for (final x in b) {
      d = (d << 8) | BigInt.from(x);
    }
    return d;
  }

  /// Decode a base64url (no-pad) x-only pubkey — the wapp's `hal_identity_pubkey`
  /// / pk-store format — to raw bytes. Returns null on error.
  Uint8List? _b64urlToBytes(String s) {
    try {
      final pad = (4 - s.length % 4) % 4;
      return base64Url.decode(s + ('=' * pad));
    } catch (_) {
      return null;
    }
  }

  /// Publish a kind-4 (NIP-04) DM of [plaintext] to recipient [recipientNpubB64]
  /// (base64url x-only pubkey, the wapp's pk-store format), signed by the active
  /// profile key, to each relay in [relayDestsHex] (+ stored locally). [msgId] is
  /// carried in a `d` tag so the recipient can dedup the relay copy against the
  /// directly-delivered copy. Returns the event id, or null.
  Future<String?> relayDmSend(String recipientNpubB64, String plaintext,
      {required List<String> relayDestsHex, String msgId = ''}) async {
    final pub = selfPubHex;
    final privHex = _profilePrivHex();
    if (pub == null || privHex == null) return null;
    final rpub = _b64urlToBytes(recipientNpubB64);
    if (rpub == null || rpub.length != 32) return null;
    final recipientPubHex = _hex(rpub);
    final content = AprxSign.nip04Encrypt(
        _scalarFromHex(privHex), rpub, utf8.encode(plaintext));
    if (content == null) return null;
    final ev = NostrEvent(
      pubkey: pub,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: NostrEventKind.encryptedDirectMessage,
      tags: [
        ['p', recipientPubHex.toLowerCase()],
        if (msgId.isNotEmpty) ['d', msgId],
      ],
      content: content,
    );
    try {
      ev.sign(privHex);
    } catch (e) {
      LogService.instance.add('RNS/relay: DM sign failed: $e');
      return null;
    }
    await relayPublish(ev.toJson()); // local store + best-indexer fan-out
    var sent = 0;
    final missing = <String>[];
    for (final hex in relayDestsHex) {
      final id = _relayIdentity(hex);
      if (id != null && _relay != null) {
        // ignore: discarded_futures
        _relay!.publish(id, ev);
        sent++;
      } else {
        missing.add(hex.substring(0, hex.length < 8 ? hex.length : 8));
      }
    }
    LogService.instance.add(
        'RNS/relay: DM ${ev.id?.substring(0, 8)} published to $sent relay(s)'
        '${missing.isEmpty ? '' : ' (unknown: ${missing.join(',')})'}');
    return ev.id;
  }

  /// Fetch kind-4 DMs addressed to us (p-tag == our pubkey) with created_at >=
  /// [sinceSec] from [relayDestsHex] (+ the local store), decrypt them with the
  /// profile key, and return `[{id, from(hex), ts, text, mid}]` (deduped by id).
  Future<List<Map<String, dynamic>>> relayDmFetch(int sinceSec,
      {required List<String> relayDestsHex}) async {
    final pub = selfPubHex;
    final privHex = _profilePrivHex();
    if (pub == null || privHex == null) return const [];
    final d = _scalarFromHex(privHex);
    final filter = NostrFilter(
      kinds: [NostrEventKind.encryptedDirectMessage],
      tags: {
        'p': [pub]
      },
      since: sinceSec,
      limit: 200,
    );
    final collected = <NostrEvent>[];
    var polled = 0;
    final missing = <String>[];
    for (final hex in relayDestsHex) {
      final id = _relayIdentity(hex);
      if (id != null && _relay != null) {
        try {
          collected.addAll(await _relay!
              .query(id, filter, timeout: const Duration(seconds: 12)));
          polled++;
        } catch (_) {}
      } else {
        missing.add(hex.substring(0, hex.length < 8 ? hex.length : 8));
      }
    }
    if (collected.isNotEmpty || missing.isNotEmpty) {
      LogService.instance.add(
          'RNS/relay: DM poll $polled/${relayDestsHex.length} relay(s), '
          '${collected.length} event(s)'
          '${missing.isEmpty ? '' : ' (unknown: ${missing.join(',')})'}');
    }
    collected.addAll(_relayStore?.query(filter) ?? const []);
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final ev in collected) {
      final id = ev.id;
      if (id == null || !seen.add(id)) continue;
      // Verify the kind-4 BIP-340 signature: the author claim (ev.pubkey, which
      // we map to a callsign + show as verified) is only trustworthy if signed.
      // Drop forgeries rather than deliver them.
      if (!ev.verify()) continue;
      final authorX = _hexToBytes(ev.pubkey);
      if (authorX == null || authorX.length != 32) continue;
      final pt = AprxSign.nip04Decrypt(d, authorX, ev.content);
      if (pt == null) continue;
      var mid = '';
      for (final t in ev.tags) {
        if (t.length >= 2 && t[0] == 'd') mid = t[1];
      }
      out.add({
        'id': id,
        // base64url (the wapp's pk-store format) so the wapp can map author→callsign
        'from': base64Url.encode(authorX).replaceAll('=', ''),
        // Derived callsign fallback so a relay DM is still delivered when the
        // recipient has never heard the sender (e.g. APRS-IS was down, so no
        // public copy taught it the callsign). The wapp prefers a known callsign.
        'callsign': 'X1${NostrCrypto.deriveCallsign(ev.pubkey)}',
        'ts': ev.createdAt,
        'text': utf8.decode(pt, allowMalformed: true),
        'mid': mid,
      });
    }
    return out;
  }

  /// Recipient-authorized delete of our received DMs [ids] from [relayDestsHex]
  /// (+ the local store). Signs sha256(ids.join(',')) with the profile key so a
  /// relay can verify we're the p-tagged recipient. Returns the count dropped.
  Future<int> relayDmDrop(List<String> ids,
      {required List<String> relayDestsHex}) async {
    final pub = selfPubHex;
    final privHex = _profilePrivHex();
    if (pub == null || privHex == null || ids.isEmpty) return 0;
    final digest = crypto.sha256.convert(utf8.encode(ids.join(','))).bytes;
    final msgHex = _hex(Uint8List.fromList(digest));
    final String sig;
    try {
      sig = NostrCrypto.schnorrSign(msgHex, privHex);
    } catch (_) {
      return 0;
    }
    _relayStore?.dropForRecipient(ids, pub); // local copy
    var n = 0;
    for (final hex in relayDestsHex) {
      final id = _relayIdentity(hex);
      if (id != null && _relay != null) {
        try {
          n += await _relay!.dropForRecipient(id, ids, pub, sig);
        } catch (_) {}
      }
    }
    return n;
  }

  // ── Identity directory on relays (callsign ↔ npub, for cold-start 1:1) ──────
  // A node publishes a signed, replaceable kind-30078 (NIP-78 app-data) event so
  // peers can resolve its callsign → npub (+ Reticulum dests) by querying relays,
  // even if they have never heard its key beacon. Queryable by the `d` tag
  // (= the callsign), which the relay store indexes like any other tag.
  static const int _kIdentityKind = 30078;

  /// Publish OUR identity (callsign → our npub + Reticulum delivery/propagation
  /// dests) to [relayDestsHex] (+ the local store) as a signed kind-30078 event,
  /// keyed (replaceable) by the uppercased callsign, so others can resolve us by
  /// callsign later. No-op without a profile key / callsign.
  Future<void> publishIdentityToRelays(
      String callsign, String delivHex, String propHex,
      {required List<String> relayDestsHex}) async {
    final pub = selfPubHex;
    final privHex = _profilePrivHex();
    final call = callsign.trim().toUpperCase();
    if (pub == null || privHex == null || call.isEmpty) return;
    final content =
        jsonEncode({'callsign': call, 'deliv': delivHex, 'prop': propHex});
    final ev = NostrEvent(
      pubkey: pub,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: _kIdentityKind,
      tags: [
        ['d', call],
        ['callsign', call],
      ],
      content: content,
    );
    try {
      ev.sign(privHex);
    } catch (e) {
      LogService.instance.add('RNS/relay: identity sign failed: $e');
      return;
    }
    await relayPublish(ev.toJson()); // local store + best-indexer fan-out
    for (final hex in relayDestsHex) {
      final id = _relayIdentity(hex);
      if (id != null && _relay != null) {
        // ignore: discarded_futures
        _relay!.publish(id, ev);
      }
    }
  }

  /// Resolve [callsign] → identity by querying [relayDestsHex] (+ the local
  /// store) for the newest verified kind-30078 event keyed by that callsign.
  /// Returns `{callsign, npub(base64url), deliv, prop}` (npub in the wapp's
  /// pk-store format so it can be stored directly) or null if none is found.
  Future<Map<String, dynamic>?> relayResolveCallsign(String callsign,
      {required List<String> relayDestsHex}) async {
    final call = callsign.trim().toUpperCase();
    if (call.isEmpty) return null;
    final filter = NostrFilter(
      kinds: [_kIdentityKind],
      tags: {
        'd': [call]
      },
      limit: 4,
    );
    final collected = <NostrEvent>[];
    for (final hex in relayDestsHex) {
      final id = _relayIdentity(hex);
      if (id != null && _relay != null) {
        try {
          collected.addAll(await _relay!
              .query(id, filter, timeout: const Duration(seconds: 12)));
        } catch (_) {}
      }
    }
    collected.addAll(_relayStore?.query(filter) ?? const []);
    NostrEvent? best;
    for (final ev in collected) {
      if (!ev.verify()) continue;
      var ok = false;
      for (final t in ev.tags) {
        if (t.length >= 2 && t[0] == 'd' && t[1].toUpperCase() == call) {
          ok = true;
          break;
        }
      }
      if (!ok) continue;
      if (best == null || ev.createdAt > best.createdAt) best = ev;
    }
    if (best == null) return null;
    final authorX = _hexToBytes(best.pubkey);
    if (authorX == null || authorX.length != 32) return null;
    var deliv = '', prop = '';
    try {
      final m = jsonDecode(best.content);
      if (m is Map) {
        deliv = (m['deliv'] ?? '').toString();
        prop = (m['prop'] ?? '').toString();
      }
    } catch (_) {}
    return {
      'callsign': call,
      'npub': base64Url.encode(authorX).replaceAll('=', ''),
      'deliv': deliv,
      'prop': prop,
    };
  }

  // ── Store-and-forward follow set (NOSTR-follow tier) ──────────────────────
  /// Mark [key] (hex / npub / base64url pubkey) as followed — its hosted notes
  /// and files get the "followed" retention tier (kept; media evicted only under
  /// pressure). Bridged from the APRS wapp's callsign follows.
  void followPubkey(String key) {
    _follows.add(key);
    // We just followed someone — pull their profile (if reachable) right away.
    refreshFollowedProfiles();
  }

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
    final enabled = PreferencesService.instanceSync?.hostEnabled ?? true;
    _relay!.serve = enabled; // responder on unless hosting is fully disabled
    if (enabled && _relayRole == null) {
      _relayRole = RelayRoleManager(
        selfPubkey: selfPubHex,
        uptimeProvider: () => uptimeSeconds,
        onChanged: (_) => _announceRelayDest(),
      );
      final prof = CapacityGovernor.instance.lastProfile;
      if (prof != null) _relayRole!.applyCapacity(prof);
      _announceRelayDest();
    } else if (!enabled) {
      _relayRole = null;
    }
  }

  /// The active profile's private key (hex) for signing folder edits as an admin.
  // ── NOSTR client (transport-abstract relays: wss:// + rns:// + local) ───────

  /// Relay list + live status for the "NOSTR servers" panel.
  List<Map<String, dynamic>> nostrRelays() =>
      _nostrHub?.relaysJson() ?? const [];

  /// Add/remove a relay by URI (wss://…, rns://<idhash>, local).
  bool nostrRelayAdd(String uri) => _nostrHub?.addRelay(uri) ?? false;
  bool nostrRelayRemove(String uri) => _nostrHub?.removeRelay(uri) ?? false;

  /// Open a subscription from a NIP-01 filter (JSON object or array). Returns a
  /// subId the caller drains with [nostrDrain].
  String? nostrSubscribe(String filtersJson) {
    final hub = _nostrHub;
    if (hub == null) return null;
    try {
      final j = jsonDecode(filtersJson);
      final filters = <NostrFilter>[];
      if (j is List) {
        for (final f in j) {
          if (f is Map) {
            filters.add(NostrFilter.fromJson(f.cast<String, dynamic>()));
          }
        }
      } else if (j is Map) {
        filters.add(NostrFilter.fromJson(j.cast<String, dynamic>()));
      }
      if (filters.isEmpty) return null;
      return hub.subscribe(filters);
    } catch (_) {
      return null;
    }
  }

  /// Pop buffered events for a subscription (JSON list, oldest first).
  List<Map<String, dynamic>> nostrDrain(String subId, {int max = 50}) =>
      _nostrHub?.drainEvents(subId, max: max) ?? const [];

  /// Discovery feed for users who follow nobody: a subId that only yields kind-1
  /// posts which have gathered >2 reactions (spam gets none). Drain like any sub.
  String? nostrDiscovery() => _nostrHub?.subscribeDiscovery(minLikes: 3);

  /// Track engagement (likes/replies) for the given post ids (event ids on
  /// screen). The feed calls this as posts scroll into view.
  void nostrTrackStats(List<String> ids) => _nostrHub?.trackStats(ids);

  /// Profile (kind-0 metadata) for an author pubkey: {name, pic, about, nip05,
  /// website, lud16, banner, npub}. Parsed by the engine; empty until it arrives
  /// (this call also triggers the fetch).
  Map<String, String> nostrProfile(String pubHex) =>
      _nostrHub?.profile(pubHex) ?? const {};

  /// Resolve a profile by the 12-char pubkey prefix (a post's `from`), from the
  /// engine's PERSISTENT store — so authors resolve even when they're not in the
  /// live feed (Saved tab, old threads). {} if unknown.
  Map<String, String> nostrProfileByShort12(String short12) =>
      _nostrHub?.profileByShort12(short12) ?? const {};

  /// Decode an `npub1…` to its 64-char hex pubkey (null on failure).
  String? nostrHexFromNpub(String npub) {
    try {
      return NostrCrypto.decodeNpub(npub.trim());
    } catch (_) {
      return null;
    }
  }

  /// Resolve a `npub1…` mention to its display name (fetching the profile if
  /// unknown). Returns null until the name is known.
  String? nostrMentionName(String npub) {
    if (!npub.startsWith('npub1')) return null;
    String hex;
    try {
      hex = NostrCrypto.decodeNpub(npub);
    } catch (_) {
      return null;
    }
    final name = _nostrHub?.profile(hex)['name'];
    return (name != null && name.isNotEmpty) ? name : null;
  }

  /// (likes, replies, likedByMe) for a post id — 0/0/false until stats arrive.
  ({int likes, int replies, bool mine}) nostrStats(String id) {
    final s = _nostrHub?.statsOf(id, selfPubHex);
    if (s == null) return (likes: 0, replies: 0, mine: false);
    return (likes: s.$1, replies: s.$2, mine: s.$3);
  }

  /// Replies to [postId]: [{id, pubkey, content, ts}] — from the engine cache
  /// (the call also refreshes it).
  List<Map<String, dynamic>> nostrReplies(String postId) {
    final hub = _nostrHub;
    if (hub == null) return const [];
    return [
      for (final e in hub.replies(postId))
        {
          'id': e['id'] ?? '',
          'pubkey': e['pubkey'] ?? '',
          'content': e['content'] ?? '',
          'ts': e['ts'] ?? 0,
        }
    ];
  }

  /// Reply to [parentId]: publish a kind-1 note tagged `e` = parent. Returns id.
  Future<String?> nostrReply(String parentId, String text) async {
    return nostrPost(1, text, [
      ['e', parentId, '', 'reply']
    ]);
  }

  /// Like a post: publish a kind-7 '+' reaction referencing [eventId] by
  /// [authorHex], signed with the profile key. SYNCHRONOUS so the optimistic
  /// like is recorded before the wapp's immediate stats-refresh reads it (an
  /// async body would run after and the like would appear to do nothing).
  void nostrReact(String eventId, String authorHex) {
    final pub = selfPubHex;
    final priv = _profilePrivHex();
    final hub = _nostrHub;
    if (pub == null || priv == null || hub == null) return;
    final ev = NostrEvent(
      pubkey: pub,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: NostrEventKind.reaction,
      tags: [
        ['e', eventId],
        if (authorHex.isNotEmpty) ['p', authorHex],
      ],
      content: '+',
    );
    try {
      ev.sign(priv);
    } catch (_) {
      return;
    }
    hub.recordReaction(eventId, pub); // optimistic, synchronous
    // ignore: discarded_futures
    hub.publish(ev); // fire-and-forget to the engine
  }

  void nostrUnsubscribe(String subId) => _nostrHub?.unsubscribe(subId);

  /// Build, sign (with the active profile key — nsec never leaves the host) and
  /// publish an event to the local store + every enabled relay. Returns its id.
  Future<String?> nostrPost(
      int kind, String content, List<List<String>> tags) async {
    final pub = selfPubHex;
    final priv = _profilePrivHex();
    final hub = _nostrHub;
    if (pub == null || priv == null || hub == null) return null;
    final ev = NostrEvent(
      pubkey: pub,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: kind,
      tags: tags,
      content: content,
    );
    try {
      ev.sign(priv);
    } catch (e) {
      LogService.instance.add('NOSTR: sign failed: $e');
      return null;
    }
    await hub.publish(ev);
    return ev.id;
  }

  /// Followed NOSTR pubkeys (hex) — the feed's author set.
  List<String> nostrFollows() => _follows.asSet.toList();
  void nostrFollow(String key) => followPubkey(key);
  void nostrUnfollow(String key) => unfollowPubkey(key);

  /// Our own x-only pubkey (hex) — the Messages tab filters kind-4 by `#p`=this.
  String? nostrSelfHex() => selfPubHex;

  /// Encrypt (NIP-04, to [recipientHex]) + sign (profile key) + publish a kind-4
  /// DM across every enabled relay. Returns the event id.
  Future<String?> nostrDmSend(String recipient, String text) async {
    final pub = selfPubHex;
    final priv = _profilePrivHex();
    final hub = _nostrHub;
    if (pub == null || priv == null || hub == null || text.isEmpty) return null;
    // Accept an npub or a raw hex pubkey.
    var recipientHex = recipient.trim();
    if (recipientHex.startsWith('npub1')) {
      try {
        recipientHex = NostrCrypto.decodeNpub(recipientHex);
      } catch (_) {
        return null;
      }
    }
    final rpub = _hexToBytes(recipientHex);
    if (rpub == null || rpub.length != 32) return null;
    final content = AprxSign.nip04Encrypt(
        _scalarFromHex(priv), rpub, utf8.encode(text));
    if (content == null) return null;
    final ev = NostrEvent(
      pubkey: pub,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: NostrEventKind.encryptedDirectMessage,
      tags: [
        ['p', recipientHex.toLowerCase()]
      ],
      content: content,
    );
    try {
      ev.sign(priv);
    } catch (e) {
      LogService.instance.add('NOSTR: DM sign failed: $e');
      return null;
    }
    await hub.publish(ev);
    return ev.id;
  }

  /// Decrypt a kind-4 [content] sent by [senderHex] with the profile key
  /// (NIP-04). Returns plaintext, or null if it isn't ours / can't decrypt.
  String? nostrDmDecrypt(String senderHex, String content) {
    final priv = _profilePrivHex();
    if (priv == null) return null;
    final authorX = _hexToBytes(senderHex);
    if (authorX == null || authorX.length != 32) return null;
    final pt = AprxSign.nip04Decrypt(_scalarFromHex(priv), authorX, content);
    if (pt == null) return null;
    try {
      return utf8.decode(pt);
    } catch (_) {
      return null;
    }
  }

  /// Feed author set — the people we follow. The wapp subscribes kind-1 from
  /// THIS (empty → the wapp falls back to the reaction-gated discovery feed).
  List<String> nostrWot() {
    final s = _follows.asSet.toList();
    return s.length > 500 ? s.take(500).toList() : s;
  }

  /// Authors whose posts are exempt from firehose eviction (people we follow).
  List<String> nostrProtectedAuthors() => _follows.asSet.toList();

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
  String? folderCreate(String name,
      {String desc = '', String shareType = FolderShareType.private}) {
    final f = _folders;
    if (f == null) return null;
    final folderId = f.createKey(name);
    // ignore: discarded_futures
    f.publishInitial(folderId, name: name, desc: desc, shareType: shareType);
    // A collab (synced) folder is one we also consume from our other devices /
    // co-members, so auto-subscribe it for download + re-seed convergence.
    if (FolderShareType.isCollab(shareType)) {
      // ignore: discarded_futures
      setFolderAutoSync(folderId, true);
    }
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
    final fid = _normFolderId(folderId);
    final bytes = await folderFetchBytes(fid, shaHex, ext: _extOf(name));
    if (bytes == null) return false;
    _subs?.recordDownload(fid, name, shaHex);
    return true;
  }

  /// Fetch the raw bytes of a content-addressed file (sha256 hex) over
  /// Reticulum and return them. The bytes are stored in the serve archive (so
  /// this device re-seeds the hash to others — peer-to-peer distribution) and
  /// we advertise as a provider; [ext] is the archive's filename hint (empty is
  /// fine when the caller only wants the bytes, e.g. the decentralized updater,
  /// which verifies sha256(bytes)==shaHex and writes the binary itself).
  /// Returns null on failure.
  Future<Uint8List?> folderFetchBytes(String folderId, String shaHex,
      {String ext = '', Duration timeout = const Duration(seconds: 30)}) async {
    final shaB = _bytesFromHex(shaHex);
    if (shaB == null) return null;
    // One content-addressed path for everything: local hit → DHT multi-source →
    // verify → archive → re-seed. (No fromCallsign: a folder file is discovered
    // via the DHT, not tied to a specific sender.)
    return fetchContentAddressed(shaB, ext: ext, timeout: timeout);
  }

  /// Like [folderBrowse] but awaits a fresh network fetch of the folder's
  /// op-log instead of returning the cached/local reduction immediately. The
  /// updater calls this so a one-shot "Check for updates" sees the latest
  /// release the moment it runs, rather than on the next 20s background refresh.
  Future<Map<String, dynamic>> folderBrowseAsync(
      String folderIdOrNpub) async {
    final folderId = _normFolderId(folderIdOrNpub);
    final f = _folders;
    if (f == null) return folderBrowse(folderId);
    try {
      final st = await f.browse(folderId);
      _folderCache[folderId] = jsonEncode(st.toJson());
      if (st.files.isNotEmpty || st.name != null) {
        // ignore: discarded_futures
        _folderRelay?.publish(folderId);
      }
      // NOTE: browsing a folder does NOT mirror it. Pulling the whole folder is
      // a deliberate "host this folder" choice (setFolderAutoSync / the host
      // action), not a side effect of viewing it — the wapp store, for one, only
      // fetches the index of available wapps here, never the bytes. Phase 3
      // mirroring (survive-owner-offline) runs in _autoSyncTick for folders the
      // node was explicitly told to host, gated to always-on indexer nodes.
      return st.toJson();
    } catch (_) {
      return folderBrowse(folderId); // fall back to whatever we hold locally
    }
  }

  /// Download every file in a folder. Returns how many succeeded.
  Future<int> folderDownloadAll(String folderId) async {
    final f = _folders;
    if (f == null) return 0;
    final fid = _normFolderId(folderId);
    final st = await f.browse(fid);
    var n = 0;
    for (final file in st.fileList) {
      if (await folderDownloadFile(fid, file.sha, file.name ?? file.sha)) {
        n++;
      }
    }
    return n;
  }

  void setFolderAutoSync(String folderId, bool on) =>
      _subs?.setAutoSync(_normFolderId(folderId), on);

  List<Map<String, dynamic>> folderSubscriptions() {
    final s = _subs;
    if (s == null) return const [];
    return [
      for (final fid in s.folderIds()) {'folderId': fid, ...s.status(fid)}
    ];
  }

  /// True when this node is a self-nominated INDEXER (always-on: charger +
  /// Wi-Fi/Ethernet, per RelayRole) AND hosting is enabled. Such nodes mirror
  /// the folders they discover so a folder stays reachable when its owner is
  /// offline. Leaf/battery nodes return false and never mirror others' folders.
  bool _isIndexerHost() {
    if (!(PreferencesService.instanceSync?.hostEnabled ?? true)) return false;
    return _relayRole?.current.isIndexer ?? false;
  }

  // Keep auto-sync folders current, and — on an indexer host — fully MIRROR them
  // (download every file, not just changed ones) so this node can serve both the
  // directory and the bytes after the owner sleeps. Runs on the background tick.
  Future<void> _autoSyncTick() async {
    final s = _subs, f = _folders;
    if (s == null || f == null) return;
    final mirror = _isIndexerHost();
    for (final fid in s.folderIds()) {
      if (!s.autoSyncOf(fid)) continue;
      final st = await f.browse(fid);
      // Re-cache + re-advertise as a folder provider so consumers resolve THIS
      // mirror by the folder key while the owner is offline.
      _folderCache[fid] = jsonEncode(st.toJson());
      if (mirror && (st.files.isNotEmpty || st.name != null)) {
        // ignore: discarded_futures
        _folderRelay?.publish(fid);
      }
      final cur = <String, String>{
        for (final e in st.fileList) (e.name ?? e.sha): e.sha
      };
      final have = s.downloadedOf(fid);
      for (final e in cur.entries) {
        final old = have[e.key];
        if (old == null) {
          // New / never-downloaded file: an indexer host mirrors it so it holds
          // (and re-seeds) the bytes; a leaf only tracks what it explicitly got.
          if (mirror) await folderDownloadFile(fid, e.value, e.key);
        } else if (old != e.value) {
          await folderDownloadFile(fid, e.value, e.key); // changed → refresh
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
    _rvTimer?.cancel();
    _rvTimer = null;
    _rvActive.clear();
    _rvInboundDests.clear();
    _linkWatchdog?.cancel();
    _linkWatchdog = null;
    _lxmf = null;
    _relay = null;
    _relayRole = null;
    _storeForward = null;
    _relayDir.clear();
    // ignore: discarded_futures
    _nostrHub?.close();
    _nostrHub = null;
    // ignore: discarded_futures
    _nostrWs?.stop();
    _nostrWs = null;
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
    _profileRetryTimer?.cancel();
    _profileRetryTimer = null;
    _hostPruneTimer?.cancel();
    _hostPruneTimer = null;
    _diskMgr = null;
    _subs = null;
    _composite = null;
    // Persist anything still dirty, then close the observed cache.
    _obFlushTimer?.cancel();
    _obFlushTimer = null;
    _flushObserved();
    _obStore?.close();
    _obStore = null;
    CapacityGovernor.instance.stop();
    await _server?.close();
    await _gateway?.close();
    for (final c in _clients) {
      // ignore: discarded_futures
      c.close();
    }
    _clients.clear();
    _connectedHubs.clear();
    await _lan?.close();
    _server = null;
    _gateway = null;
    _lan = null;
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

/// One node the local RNS stack has heard announce(s) from. Accumulated per
/// identity (a node announces several service destinations). Lives only in
/// memory; capped and stale-swept by RnsService. See [RnsService.graphSnapshot].
class _ObservedNode {
  final String identityHex;
  final String publicKeyHex;
  final int firstSeenMs;
  int lastSeenMs;
  String? callsign;
  final Set<String> services = {};
  int hops = 0;
  String via = '';
  // Last advertised uptime (seconds since the peer's RNS stack started), from
  // its relay announce. 0 = not advertised. Drives warm-start ranking: stable
  // (high-uptime) nodes are likely indexers and are tried first on next boot.
  int uptimeSeconds = 0;
  // Transport-id (hex) of the relayer we reach this node through; null = direct
  // neighbour of ours. Other nodes' relayer == a hub's identity.
  String? relayerHex;
  // This node's NOSTR pubkey (hex), learned from its relay announce — encoded to
  // an npub for display so peers with the same callsign/nickname are tellable
  // apart. Null until we hear a relay announce carrying it.
  String? nostrPubHex;
  // Liveness this run (NOT persisted): how many announces we've heard and when
  // the first arrived. Used to separate a genuine re-announcing peer from a
  // one-shot hub connect-flood replay. Reset every run (cache hydration removed).
  int heardCount = 0;
  int firstHeardMs = 0;

  _ObservedNode({
    required this.identityHex,
    required this.publicKeyHex,
    required this.firstSeenMs,
  }) : lastSeenMs = firstSeenMs;
}
