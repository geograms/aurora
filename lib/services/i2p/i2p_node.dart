/*
 * I2pNode — top-level pure-Dart I2P node that ties the layers together:
 * reseed + NetDB, an NTCP2 session to a gateway peer (our inbound tunnel
 * gateway), a built inbound tunnel, a published LeaseSet2 (stored on the
 * floodfills closest to our routing key), and a GET-by-sha256 data path
 * (serve + fetch) over repliable datagrams.
 *
 * Reachability model (works behind CGNAT, the whole point): we only make
 * OUTBOUND NTCP2 connections. Our inbound tunnel's gateway is a router we dial;
 * tunnel traffic for us flows back over that same connection. To reach another
 * destination we dial its inbound gateway directly and hand it a TunnelGateway
 * message. NetDB store/lookup uses short-lived dials to the closest floodfills
 * (Kademlia XOR distance to the daily routing key), matching how real I2P
 * selects floodfills so two independent nodes converge on the same ones.
 */
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'i2p_crypto.dart';
import 'i2p_datagram.dart';
import 'i2p_i2np.dart';
import 'i2p_leaseset.dart';
import 'i2p_ntcp2.dart';
import 'i2p_reseed.dart';
import 'i2p_router.dart';
import 'i2p_structures.dart';
import 'i2p_swarm.dart';
import 'i2p_tunnel_build.dart';
import 'i2p_tunnel_data.dart';

String i2pBase32(Uint8List data) {
  const alpha = 'abcdefghijklmnopqrstuvwxyz234567';
  final sb = StringBuffer();
  var buffer = 0, bits = 0;
  for (final b in data) {
    buffer = (buffer << 8) | b;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      sb.write(alpha[(buffer >> bits) & 0x1f]);
    }
  }
  if (bits > 0) sb.write(alpha[(buffer << (5 - bits)) & 0x1f]);
  return sb.toString();
}

/// Decode a "<52 base32 chars>.b32.i2p" (or bare base32) to the 32-byte hash.
Uint8List? i2pBase32Decode(String addr) {
  var s = addr.trim().toLowerCase();
  if (s.endsWith('.b32.i2p')) s = s.substring(0, s.length - 8);
  const alpha = 'abcdefghijklmnopqrstuvwxyz234567';
  var buffer = 0, bits = 0;
  final out = <int>[];
  for (final ch in s.codeUnits) {
    final v = alpha.indexOf(String.fromCharCode(ch));
    if (v < 0) return null;
    buffer = (buffer << 5) | v;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xff);
    }
  }
  return out.length < 32 ? null : Uint8List.fromList(out.sublist(0, 32));
}

/// One inbound tunnel through a gateway router: its session (also used for
/// serving), the tunnel id the gateway receives on, and the layer keys to
/// decrypt tunnel data the gateway forwards to us.
class _Gw {
  final Ntcp2Session session; // session tunnel data ARRIVES on (last hop)
  final RouterInfo ri; // router of the receiving session
  final int tunnelId; // our endpoint receive tunnel id
  final TunnelLayer layer; // last hop's layer
  // 2-hop: the lease gateway (hop1) differs from the receiving session (hop2),
  // and there's an extra (gateway) layer to peel. Null for 1-hop.
  final List<TunnelLayer>? extraLayers; // gateway-side layers (after [layer])
  final RouterInfo? leaseGw; // lease gateway router (hop1)
  final int? leaseTun; // lease tunnel id (hop1's receive tunnel)
  bool dead = false; // set when its serve loop / session fails
  _Gw(this.session, this.ri, this.tunnelId, this.layer,
      {this.extraLayers, this.leaseGw, this.leaseTun});

  /// Layers to apply in order to decrypt inbound tunnel data (endpoint->gateway).
  List<TunnelLayer> get decryptChain => [layer, ...?extraLayers];
  /// The gateway senders deliver to (lease gateway).
  RouterInfo get gateway => leaseGw ?? ri;
  int get gatewayTunnel => leaseTun ?? tunnelId;
}

/// A 1-hop outbound tunnel: us (gateway) -> OBEP (endpoint). We hold a session to
/// the OBEP and send tunnel data (type 18) on [tunnelId]; the OBEP decrypts our
/// layer and delivers the carried message to its destination.
class _Ob {
  final Ntcp2Session session;
  final RouterInfo obep;
  final int tunnelId;
  final TunnelLayer layer;
  bool dead = false;
  _Ob(this.session, this.obep, this.tunnelId, this.layer);
}

class I2pNode {
  final void Function(String)? log;
  final int netId;
  final Future<Uint8List?> Function(Uint8List sha256)? onGet;

  I2pNode({this.log, this.netId = 2, this.onGet});

  late OurRouter router;
  late Destination dest;
  // Multiple inbound tunnels through different gateways (lease/gateway
  // diversity), so a peer can reach us even if one gateway is flaky.
  final _gws = <_Gw>[];
  final _peers = <RouterInfo>[];
  final _floodfills = <RouterInfo>[];
  bool _running = false;
  // Cancellable keepalive timers — a pending Future.delayed keeps the whole Dart
  // process alive, so these MUST be cancellable (close/pause) or the node never
  // shuts down.
  Timer? _kaTimer;
  Timer? _natTimer;

  // dial overrides (local-i2pd testing); null on the real network
  String? _dialHost;
  int? _dialPort;
  Uint8List? _dialIv;

  final _fetches = <String, Completer<Uint8List?>>{};
  final _reasm = TunnelReassembler();
  // Outbound tunnel (us -> OBEP): the standard I2P path to deliver to another
  // destination — the OBEP hands our message off to the target's inbound gateway
  // (real routers don't forward our direct-to-gateway injections; the OBEP does).
  _Ob? _ob;

  // ---- swarm (multi-device piece download) state ----
  /// Active downloads / partial-or-complete stores we keep serving, by fileShaHex.
  final _stores = <String, SwarmStore>{};
  final _manifestWaiters = <String, Completer<Uint8List?>>{};
  final _haveWaiters = <String, Completer<Uint8List?>>{}; // 'shaHex:provHex'
  final _pieceWaiters = <String, Completer<Uint8List?>>{}; // 'shaHex:index'
  /// Cached destination leases for repeated piece delivery: destHex -> (leases, expiryMs).
  final _leaseCache = <String, (List<ParsedLease>, int)>{};
  /// Resolved gateway RouterInfos (routerHex -> RI) so we can dial a peer's
  /// inbound gateway even when it isn't in our reseed set (cross-device).
  final _riCache = <String, RouterInfo>{};
  /// Reused send-only sessions to peer gateways (avoids a handshake per piece).
  final _txSessions = <String, Ntcp2Session>{};
  /// One-entry whole-file cache so a seeder slices pieces without re-bridging.
  String? _wholeKey;
  Uint8List? _wholeBytes;
  /// Where in-progress piece files live (overridable for tests).
  Directory? swarmBaseDir;

  // ---- content-routing (provider DHT) state ----
  /// Roster of known peer device destination hashes (hex), from beacons.
  final _roster = <String, Uint8List>{};
  /// Provider records we hold: contentShaHex -> {providerDestHex: expiryMs}.
  final _providers = <String, Map<String, int>>{};
  /// In-flight FINDPROV accumulators: contentShaHex -> set of provider hex.
  final _findAcc = <String, Set<String>>{};
  static const _providerTtlMs = 30 * 60 * 1000;
  static const _replicas = 4; // K closest devices that hold a record

  String get b32 => '${i2pBase32(dest.hash)}.b32.i2p';
  Uint8List get destHash => dest.hash;
  int get gatewayCount => _gws.length;
  bool get isUp => _running && _gws.isNotEmpty;

  /// Replace the known-peer roster (device destination hashes).
  void setRoster(Iterable<Uint8List> destHashes) {
    _roster.clear();
    for (final h in destHashes) {
      if (h.length == 32) _roster[_hex(h)] = h;
    }
  }

  void addPeer(Uint8List destHash) {
    if (destHash.length == 32) _roster[_hex(destHash)] = destHash;
  }

  String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  /// Inbound tunnel hops. 1 = gateway only (proven, reliable for a NAT'd node).
  /// 2 = gateway + one middle hop for anonymity (hides our router from the
  /// gateway); requires maintaining a session to the last hop so it can forward
  /// to us, so it has more moving parts.
  int hops = 1;
  bool get isPaused => _paused;
  bool _paused = false;
  final _dialable = <RouterInfo>[];
  /// Routers that failed to build a tunnel or whose tunnel died — deprioritised
  /// in gateway selection (cleared when we run out of fresh candidates).
  final _demoted = <String>{};

  /// Gateway candidates with demoted (flaky) routers last; resets demotion if
  /// every candidate has been demoted so we always have something to try.
  static final _rng = Random.secure();

  /// True for high-bandwidth routers (caps tier O/P/X). These backbone routers
  /// are reliable tunnel forwarders; low-tier (K/L/M) routers often build a
  /// tunnel but then forward little/nothing, which is what made delivery flaky.
  static bool _highBw(RouterInfo r) {
    final caps = r.options['caps'] ?? '';
    return caps.contains('O') || caps.contains('P') || caps.contains('X');
  }

  /// Candidate routers to build gateways/OB through. PREFER high-bandwidth routers
  /// (good forwarders), SHUFFLED within each tier so we still spread load and
  /// don't hammer the same few. Demoted (flaky) routers are tried last.
  List<RouterInfo> _gatewayCandidates() {
    final fresh = _dialable
        .where((r) => !_demoted.contains(_hex(r.identityHash)))
        .toList();
    if (fresh.isEmpty) {
      _demoted.clear();
      final all = [..._dialable];
      final hi = all.where(_highBw).toList()..shuffle(_rng);
      final lo = all.where((r) => !_highBw(r)).toList()..shuffle(_rng);
      return [...hi, ...lo];
    }
    final freshHi = fresh.where(_highBw).toList()..shuffle(_rng);
    final freshLo = fresh.where((r) => !_highBw(r)).toList()..shuffle(_rng);
    final bad = _dialable
        .where((r) => _demoted.contains(_hex(r.identityHash)))
        .toList()
      ..shuffle(_rng);
    return [...freshHi, ...freshLo, ...bad];
  }

  Future<bool> start({
    List<RouterInfo>? peers,
    String? hostOverride,
    int? portOverride,
    Uint8List? ivOverride,
    int hops = 1,
  }) async {
    this.hops = hops;
    router = await OurRouter.generate(netId: netId);
    dest = await Destination.generate();
    _dialHost = hostOverride;
    _dialPort = portOverride;
    _dialIv = ivOverride;
    log?.call('node: dest $b32');

    _peers.addAll(peers ?? await reseedRouters(log: log));
    _dialable.addAll(_peers.where((ri) {
      final a = ri.ntcp2;
      return ri.isEcies &&
          a != null &&
          (hostOverride != null || (a.host != null && a.port != null)) &&
          a.staticKey?.length == 32 &&
          (ivOverride != null || a.iv?.length == 16);
    }));
    _floodfills.addAll(
        _dialable.where((ri) => (ri.options['caps'] ?? '').contains('f')));
    log?.call('node: ${_dialable.length} dialable ECIES, ${_floodfills.length} floodfill');
    return _bringUp();
  }

  /// Build inbound tunnels, publish, and start serving + keepalive. Re-runnable
  /// (used by start and resume). Keeps the existing destination identity.
  Future<bool> _bringUp() async {
    _running = true;
    _paused = false;
    await _buildGateways(_wantGateways);
    if (_gws.isEmpty) {
      _running = false;
      return false;
    }
    await _ensureOutbound();
    await _publish();
    _startKeepAlive();
    log?.call('node: up with ${_gws.length} gateway(s)'
        '${_ob != null ? " + outbound tunnel" : " (no outbound)"}, $hops-hop tunnels');
    return true;
  }

  /// Build inbound-tunnel gateways up to [want], dialing candidates in CONCURRENT
  /// batches. A diverse reseed pool has many dead/stale routers; sequential dials
  /// would burn ~8 s each on the dead ones and make startup crawl. Batching means
  /// a batch costs ~one timeout, not the sum.
  Future<void> _buildGateways(int want) async {
    final candidates = _gatewayCandidates().take(48).toList();
    const batch = 6;
    var idx = 0;
    while (_gws.length < want && _running && idx < candidates.length) {
      final slice = candidates.sublist(idx, min(idx + batch, candidates.length));
      idx += slice.length;
      final built = await Future.wait(slice.map((ri) async {
        try {
          return await _buildTunnel(ri);
        } catch (_) {
          return null;
        }
      }));
      for (var i = 0; i < slice.length; i++) {
        final gw = built[i];
        if (gw == null) {
          _demoted.add(_hex(slice[i].identityHash));
          continue;
        }
        if (_gws.length < want && _running) {
          _gws.add(gw);
          _serveGw(gw);
          log?.call('node: gateway ${_hex(slice[i].identityHash).substring(0, 12)} '
              '$hops-hop tunnel=${gw.tunnelId} (${_gws.length}/$want)');
        } else {
          try {
            gw.session.close(); // surplus from the batch
          } catch (_) {}
        }
      }
    }
  }

  /// Build an outbound tunnel if we don't have a live one. The OBEP must differ
  /// from our inbound gateways (don't reuse the same router for both directions).
  Future<void> _ensureOutbound() async {
    if (_ob != null && !_ob!.dead) return;
    final inUse = _gws.map((g) => _hex(g.ri.identityHash)).toSet();
    // Prefer an OBEP distinct from our inbound gateways; if none works, fall back
    // to any dialable router (a single-router/loopback setup, or all distinct
    // candidates failed) — an OB tunnel even through a gateway still routes by the
    // per-message delivery instructions.
    // Self-limit: dialing many flaky candidates can take minutes; cap the wall
    // time so a keepalive rebuild can't run away in the background.
    final deadline = DateTime.now().add(const Duration(seconds: 35));
    for (final distinct in [true, false]) {
      for (final ri in _gatewayCandidates().take(12)) {
        if (!_running || (_ob != null && !_ob!.dead)) return;
        if (DateTime.now().isAfter(deadline)) return;
        if (distinct && inUse.contains(_hex(ri.identityHash))) continue;
        try {
          final ob = await _buildOutbound(ri);
          if (ob != null) {
            _ob = ob;
            log?.call('node: outbound via ${_hex(ri.identityHash).substring(0, 12)} '
                'tunnel=${ob.tunnelId}');
            return;
          }
          _demoted.add(_hex(ri.identityHash));
        } catch (_) {
          _demoted.add(_hex(ri.identityHash));
        }
      }
    }
  }

  /// Suspend all network activity (serve loops, keepalive) and free the gateway
  /// sessions — for CPU-overload / low-battery throttling. Keeps our identity,
  /// roster and provider records so resume() can re-establish cheaply.
  void pause() {
    if (_paused) return;
    _paused = true;
    _running = false; // stops keepalive + serve loops
    _kaTimer?.cancel();
    _natTimer?.cancel();
    for (final g in _gws) {
      g.session.close();
    }
    _gws.clear();
    for (final s in _txSessions.values) {
      try {
        s.close();
      } catch (_) {}
    }
    _txSessions.clear();
    _leaseCache.clear(); // leases change after the next republish
    try {
      _ob?.session.close();
    } catch (_) {}
    _ob = null;
    log?.call('node: paused (tunnels torn down)');
  }

  /// Re-establish tunnels and republish after a pause. No-op if already running.
  Future<bool> resume() async {
    if (_running && _gws.isNotEmpty) return true;
    log?.call('node: resuming');
    return _bringUp();
  }

  /// Run [op] with an overall [t] timeout so a slow/hung dial can't stall the
  /// keepalive loop (a stalled step used to stop republishing -> leases expire
  /// -> the node silently goes dark after ~10 min).
  Future<void> _guard(String what, Future<void> Function() op, Duration t) async {
    try {
      await op().timeout(t);
    } catch (e) {
      log?.call('node: keepalive $what skipped: $e');
    }
  }

  /// Leases/tunnels expire (~10 min); republish periodically and re-announce the
  /// content we provide so records stay fresh on the responsible peers. Each step
  /// is time-bounded and PUBLISH runs first so a slow gateway/OB rebuild can never
  /// prevent us from refreshing our leases and staying reachable.
  void _startKeepAlive() {
    if (natKeepAliveEnabled) _startNatKeepAlive();
    _kaTimer?.cancel();
    var busy = false;
    _kaTimer = Timer.periodic(const Duration(minutes: 4), (t) async {
      if (!_running) {
        t.cancel();
        return;
      }
      if (busy) return; // don't overlap a slow cycle
      busy = true;
      try {
        await _guard('publish', _publish, const Duration(seconds: 40));
        if (!_running) return;
        await _guard('rotateGateways', _rotateGateways, const Duration(seconds: 50));
        if (!_running) return;
        await _guard('ensureOutbound', _ensureOutbound, const Duration(seconds: 40));
        final mine = <Uint8List>[];
        final me = _hex(dest.hash);
        _providers.forEach((shaHex, m) {
          if (m.containsKey(me)) mine.add(_fromHex(shaHex)!);
        });
        for (final sha in mine) {
          if (!_running) break;
          await _guard('announce', () => announce(sha), const Duration(seconds: 30));
        }
      } catch (_) {
      } finally {
        busy = false;
      }
    });
  }

  /// Keep every live session warm with a padding frame so the NAT mapping in
  /// front of us stays open and our gateways can keep PUSHING inbound tunnel data
  /// over our outbound-initiated connections — a firewalled node (e.g. a phone on
  /// home WiFi) has no other way to receive, and consumer NATs drop idle mappings
  /// within a couple of minutes. ~45 s is well under typical NAT timeouts.
  void _startNatKeepAlive() {
    _natTimer?.cancel();
    var busy = false;
    _natTimer = Timer.periodic(const Duration(seconds: 45), (t) async {
      if (!_running) {
        t.cancel();
        return;
      }
      if (busy) return;
      busy = true;
      try {
        final sessions = <Ntcp2Session>[
          for (final g in _gws) g.session,
          if (_ob != null && !_ob!.dead) _ob!.session,
          ..._txSessions.values,
        ];
        for (final s in sessions) {
          if (!_running) break;
          try {
            await s.sendKeepAlive().timeout(const Duration(seconds: 8));
          } catch (_) {}
        }
      } finally {
        busy = false;
      }
    });
  }

  // More inbound gateways = more delivery paths to us. A single 1-hop gateway
  // forwards reliably only ~half the time on the live net (router-dependent), so
  // a sender that delivers to ALL our published leases reaches us if ANY one
  // forwards — 4 gateways turns ~50% into ~90%+. Parallel bringup keeps it fast.
  static const _wantGateways = 4;

  /// Gateway health/rotation: drop dead gateways and rebuild through fresh
  /// routers to keep the target count, so a node recovers from flaky/expired
  /// tunnels without going dark.
  Future<void> _rotateGateways() async {
    final dead = _gws.where((g) => g.dead).toList();
    for (final g in dead) {
      _demoted.add(_hex(g.ri.identityHash));
      g.session.close();
      _gws.remove(g);
    }
    if (dead.isNotEmpty) {
      log?.call('node: dropped ${dead.length} dead gateway(s)');
    }
    if (_gws.length >= _wantGateways) return;
    final inUse = _gws.map((g) => _hex(g.ri.identityHash)).toSet();
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    for (final ri in _gatewayCandidates()) {
      if (_gws.length >= _wantGateways || !_running) break;
      if (DateTime.now().isAfter(deadline)) break; // self-limit flaky dials
      if (inUse.contains(_hex(ri.identityHash))) continue;
      try {
        final gw = await _buildTunnel(ri);
        if (gw != null) {
          _gws.add(gw);
          _serveGw(gw);
          inUse.add(_hex(ri.identityHash));
          log?.call('node: rebuilt gateway ${_hex(ri.identityHash).substring(0, 12)}');
        } else {
          _demoted.add(_hex(ri.identityHash));
        }
      } catch (_) {
        _demoted.add(_hex(ri.identityHash));
      }
    }
  }

  /// Dial a router. The stable gateway/receiving session uses our real identity;
  /// ephemeral store/lookup/deliver dials use a throwaway identity so a router
  /// that dedups sessions per remote identity won't stall our second connection.
  Future<Ntcp2Session> _dial(RouterInfo ri, {bool ephemeral = false}) async {
    final us = ephemeral ? await OurRouter.generate(netId: netId) : router;
    return Ntcp2Session(ri, us,
        hostOverride: _dialHost,
        portOverride: _dialPort,
        ivOverride: _dialIv,
        netId: netId);
  }

  /// Dial [gw] and build an inbound tunnel through it (1 hop, or 2 hops for
  /// anonymity when [hops] >= 2). Returns the gateway handle or null.
  Future<_Gw?> _buildTunnel(RouterInfo gw) async {
    if (hops >= 2) return _buildTwoHop(gw);
    Ntcp2Session? s;
    try {
      s = await _dial(gw);
      // Dead/stale routers (common in a diverse reseed pool) should fail FAST so
      // we cycle to a live one — a good router handshakes in well under a second.
      await s.handshake().timeout(const Duration(seconds: 8));
      final t = DateTime.now().microsecondsSinceEpoch;
      final inTun = (t & 0x7fffffff) | 1;
      final plain = buildShortRequestPlaintext(
        receiveTunnel: inTun,
        nextTunnel: ((t >> 8) & 0x7fffffff) | 1,
        nextIdent: router.identityHash,
        isGateway: true,
        isEndpoint: false,
        sendMsgId: (t >> 16) & 0x7fffffff,
      );
      final (rec, keys) = await buildShortRecord(
          hopIdentHash: gw.identityHash,
          hopStaticKey: gw.encryptionKey!,
          plaintext: plain);
      await s.sendI2np(25, buildShortTunnelBuildMessage([rec]));
      final reply = await s.nextI2np(const Duration(seconds: 12));
      if (reply == null || reply.$2.length < 1 + shortRecordSize) {
        s.close();
        return null;
      }
      final rp = await openShortReplyRecord(
          record: reply.$2.sublist(1, 1 + shortRecordSize),
          replyKey: keys.replyKey, h: keys.h, recordIndex: 0);
      if (rp[shortReplyRetOffset] != 0) {
        log?.call('node: tunnel build declined ret=${rp[shortReplyRetOffset]}');
        s.close();
        return null;
      }
      return _Gw(s, gw, inTun, TunnelLayer(keys.layerKey, keys.ivKey));
    } catch (e) {
      s?.close();
      rethrow;
    }
  }

  /// Build a 1-hop OUTBOUND tunnel through [obep]: us (gateway) -> OBEP
  /// (endpoint). We dial the OBEP and route the build reply back to us directly
  /// (nextIdent=us); the OBEP replies over the session as a symmetric-garlic
  /// (i2pd wraps the endpoint reply) which we decrypt. Returns the OB handle.
  Future<_Ob?> _buildOutbound(RouterInfo obep) async {
    Ntcp2Session? s;
    try {
      // Ephemeral identity: the OBEP keys the build reply by the symmetric
      // RGarlicKeyAndTag (not our identity), and the reply comes back over this
      // same session — so a throwaway identity works and avoids a same-identity
      // session dedup when the OBEP happens to be one of our gateways.
      s = await _dial(obep, ephemeral: true);
      await s.handshake().timeout(const Duration(seconds: 15));
      final t = DateTime.now().microsecondsSinceEpoch;
      final outTun = (t & 0x7fffffff) | 1;
      final plain = buildShortRequestPlaintext(
        receiveTunnel: outTun, // OBEP receives our tunnel data on this id
        nextTunnel: 0, // endpoint: reply routing only
        nextIdent: s.us.identityHash, // reply to the dialing (ephemeral) identity
        isGateway: false,
        isEndpoint: true,
        sendMsgId: (t >> 16) & 0x7fffffff,
      );
      final (rec, keys) = await buildShortRecord(
          hopIdentHash: obep.identityHash,
          hopStaticKey: obep.encryptionKey!,
          plaintext: plain,
          isEndpoint: true);
      await s.sendI2np(25, buildShortTunnelBuildMessage([rec]));
      // reply arrives over the session as a TunnelGateway wrapping an I2NP Garlic
      final reply = await s.nextI2np(const Duration(seconds: 12));
      if (reply == null || reply.$1 != 19 || reply.$2.length < 6) {
        s.close();
        return null;
      }
      final tg = reply.$2;
      final ilen = (tg[4] << 8) | tg[5];
      if (6 + ilen > tg.length) {
        s.close();
        return null;
      }
      final inner = tg.sublist(6, 6 + ilen); // inner I2NP message
      if (inner.isEmpty || inner[0] != 11 || inner.length < 16 ||
          keys.garlicKey == null) {
        s.close();
        return null;
      }
      final ret = await openShortBuildReplyGarlic(
        garlicBody: inner.sublist(16),
        garlicKey: keys.garlicKey!,
        garlicTag: keys.garlicTag!,
        replyKey: keys.replyKey,
        h: keys.h,
        recordIndex: 0,
      );
      if (ret != 0) {
        log?.call('node: outbound build declined/failed ret=$ret');
        s.close();
        return null;
      }
      return _Ob(s, obep, outTun, TunnelLayer(keys.layerKey, keys.ivKey));
    } catch (e) {
      s?.close();
      rethrow;
    }
  }

  /// Build a 2-hop inbound tunnel: gateway [hop1] -> hop2 -> us. Hides our
  /// router from the gateway (anonymity). We dial hop1 (to send the build) and
  /// hop2 (the last hop, which forwards tunnel data + the build reply to us).
  Future<_Gw?> _buildTwoHop(RouterInfo hop1) async {
    final used = {
      _hex(hop1.identityHash),
      for (final g in _gws) ...[_hex(g.ri.identityHash), _hex(g.gateway.identityHash)]
    };
    RouterInfo? hop2;
    for (final ri in _gatewayCandidates()) {
      if (!used.contains(_hex(ri.identityHash))) {
        hop2 = ri;
        break;
      }
    }
    if (hop2 == null) return null;
    final hop2Ri = hop2;
    Ntcp2Session? sHop1, sHop2;
    try {
      // Dialing two flaky routers is the failure-prone part — use short
      // timeouts and demote whichever hop fails so we move on quickly.
      try {
        sHop2 = await _dial(hop2Ri);
        await sHop2.handshake().timeout(const Duration(seconds: 8));
      } catch (e) {
        _demoted.add(_hex(hop2Ri.identityHash));
        sHop2?.close();
        return null;
      }
      sHop1 = await _dial(hop1);
      await sHop1.handshake().timeout(const Duration(seconds: 8));
      final t = DateTime.now().microsecondsSinceEpoch;
      final t1 = (t & 0x7fffffff) | 1; // hop1 receive = lease tunnel
      final t2 = ((t >> 8) & 0x7fffffff) | 1; // hop2 receive
      final t3 = ((t >> 16) & 0x7fffffff) | 1; // our endpoint receive
      final sid = (t >> 24) & 0x7fffffff;
      final p0 = buildShortRequestPlaintext(
          receiveTunnel: t1, nextTunnel: t2, nextIdent: hop2Ri.identityHash,
          isGateway: true, isEndpoint: false, sendMsgId: sid);
      final p1 = buildShortRequestPlaintext(
          receiveTunnel: t2, nextTunnel: t3, nextIdent: router.identityHash,
          isGateway: false, isEndpoint: false, sendMsgId: sid);
      final (rec0, k0) = await buildShortRecord(
          hopIdentHash: hop1.identityHash, hopStaticKey: hop1.encryptionKey!, plaintext: p0);
      final (rec1, k1) = await buildShortRecord(
          hopIdentHash: hop2Ri.identityHash, hopStaticKey: hop2Ri.encryptionKey!, plaintext: p1);
      await sHop1.sendI2np(25, buildShortTunnelBuildMessage([rec0, rec1]));
      log?.call('node: 2-hop build sent via ${_hex(hop1.identityHash).substring(0, 8)}'
          ' -> ${_hex(hop2Ri.identityHash).substring(0, 8)}, awaiting reply');
      // The build propagates hop1 -> hop2 -> us; the reply (type 25) arrives via
      // hop2. Skip any other I2NP traffic hop2 sends first.
      Uint8List? replyBody;
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        final r = await sHop2.nextI2np(deadline.difference(DateTime.now()));
        if (r == null) break;
        if (r.$1 == 25 && r.$2.length >= 1 + 2 * shortRecordSize) {
          replyBody = r.$2;
          break;
        }
      }
      if (replyBody == null) {
        sHop1.close();
        sHop2.close();
        return null;
      }
      final accepts = await openMultiHopReply(
          message: replyBody, hopKeys: [k0, k1], recordIndex: [0, 1]);
      if (accepts[0] != 0 || accepts[1] != 0) {
        log?.call('node: 2-hop build declined $accepts');
        sHop1.close();
        sHop2.close();
        return null;
      }
      sHop1.close(); // only needed to inject the build
      return _Gw(sHop2, hop2, t3, TunnelLayer(k1.layerKey, k1.ivKey),
          extraLayers: [TunnelLayer(k0.layerKey, k0.ivKey)],
          leaseGw: hop1, leaseTun: t1);
    } catch (e) {
      sHop1?.close();
      sHop2?.close();
      rethrow;
    }
  }

  // ---- NetDB: closest-floodfill DHT ----

  Uint8List _routingKey(Uint8List destHash) {
    final now = DateTime.now().toUtc();
    final d = '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    return I2pCrypto.sha256(Uint8List.fromList([...destHash, ...d.codeUnits]));
  }

  List<RouterInfo> _closestFloodfills(Uint8List routingKey, int n) {
    final list = [..._floodfills];
    list.sort((a, b) {
      for (var i = 0; i < 32; i++) {
        final da = a.identityHash[i] ^ routingKey[i];
        final db = b.identityHash[i] ^ routingKey[i];
        if (da != db) return da - db;
      }
      return 0;
    });
    return list.take(n).toList();
  }

  Future<void> _publish() async {
    final end = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600;
    final leases = [
      for (final g in _gws) Lease2(g.gateway.identityHash, g.gatewayTunnel, end)
    ];
    final ls = await dest.buildLeaseSet2(leases);
    final store = buildLeaseSetStore(dest.hash, ls, leaseSetStoreType);
    // Store to several closest floodfills so an independently-reseeded peer
    // (e.g. the phone on another network) converges on at least one of them.
    // In PARALLEL: 8 sequential dials (each up to ~15 s) could otherwise stall
    // the keepalive loop and let our leases expire.
    final targets = _closestFloodfills(_routingKey(dest.hash), 8);
    final results = await Future.wait(targets.map((ff) async {
      try {
        final s = await _dial(ff, ephemeral: true);
        await s.handshake().timeout(const Duration(seconds: 15));
        await s.sendI2np(I2npType.databaseStore, store);
        await Future.delayed(const Duration(milliseconds: 400));
        s.close();
        return true;
      } catch (_) {
        return false;
      }
    }));
    final stored = results.where((ok) => ok).length;
    log?.call('node: published LeaseSet2 to $stored/${targets.length} floodfills');
  }

  Future<ParsedLease?> lookupLease(Uint8List targetDestHash) async {
    final all = await lookupLeases(targetDestHash);
    return all.isEmpty ? null : all.first;
  }

  /// Look up all current leases (gateways) of a destination from the netDB.
  /// Queries the closest floodfills CONCURRENTLY and returns the first non-empty
  /// answer — a diverse reseed pool has dead/slow floodfills, and querying them
  /// sequentially (up to 8 x 12 s) used to stall every delivery and time out the
  /// whole fetch. Racing them makes a lookup as fast as the quickest responder.
  Future<List<ParsedLease>> lookupLeases(Uint8List targetDestHash) async {
    final targets = _closestFloodfills(_routingKey(targetDestHash), 8);
    final wantKey = _hex(targetDestHash);
    final done = Completer<List<ParsedLease>>();
    var pending = targets.length;
    if (pending == 0) return [];
    for (final ff in targets) {
      () async {
        Ntcp2Session? s;
        try {
          s = await _dial(ff, ephemeral: true);
          await s.handshake().timeout(const Duration(seconds: 8));
          // Reply comes back over THIS ephemeral session, so the lookup's "from"
          // is this session's own identity (not our stable identity, which would
          // route the reply to our gateway session instead).
          await s.sendI2np(I2npType.databaseLookup,
              buildLeaseSetLookup(targetDestHash, s.us.identityHash));
          for (var i = 0; i < 4; i++) {
            final r = await s.nextI2np(const Duration(seconds: 6));
            if (r == null) break;
            if (r.$1 == I2npType.databaseStore &&
                _hex(r.$2.sublist(0, 32)) == wantKey &&
                r.$2[32] == leaseSetStoreType) {
              final leases = parseLeaseSet2Leases(r.$2.sublist(37));
              if (leases.isNotEmpty && !done.isCompleted) done.complete(leases);
              break;
            } else if (r.$1 == I2npType.databaseSearchReply &&
                _hex(r.$2.sublist(0, 32)) == wantKey) {
              break; // not here
            }
          }
        } catch (_) {
        } finally {
          try {
            s?.close();
          } catch (_) {}
          if (--pending == 0 && !done.isCompleted) done.complete([]);
        }
      }();
    }
    return done.future;
  }

  // ---- serving (inbound tunnel read loop, one per gateway) ----

  void _serveGw(_Gw gw) {
    _running = true;
    () async {
      while (_running && _gws.contains(gw)) {
        try {
          await gw.session.pumpI2np(
              const Duration(seconds: 30), (t, b) => _dispatch(t, b, gw));
        } catch (_) {
          break;
        }
      }
      gw.dead = true; // serve loop ended -> gateway no longer usable
    }();
  }

  void _dispatch(int type, Uint8List body, _Gw gw) {
    if (_rxDiag) {
      log?.call('node: rx i2np type=$type len=${body.length} via gw '
          '${_hex(gw.ri.identityHash).substring(0, 12)}');
    }
    if (type == 18) _handleTunnelData(body, gw);
  }

  /// Diagnostic: log every I2NP message arriving on a gateway session. Off by
  /// default; flip on to bisect "gateway not delivering" vs "received but the
  /// tunnel-data decrypt/reassembly failed".
  static bool _rxDiag = false;
  static set rxDiag(bool v) => _rxDiag = v;

  /// Periodic NAT/connection keepalive (padding frames) on all live sessions —
  /// on by default; can be disabled for wired hosts or A/B testing.
  static bool natKeepAliveEnabled = true;

  Future<void> _handleTunnelData(Uint8List body, _Gw gw) async {
    try {
      if (body.length < 4 + 1024) return;
      final dec = decryptLayers(gw.decryptChain, body.sublist(4, 4 + 1024));
      // A large datagram (a real file / piece) spans many cells; the gateway
      // fragments it and we reassemble by message id before processing.
      for (final m in _reasm.addCell(dec)) {
        if (m.isNotEmpty && m[0] == i2npData) await _processI2npData(m, gw);
      }
    } catch (e) {
      log?.call('node: tunnel-data error: $e');
    }
  }

  Future<void> _processI2npData(Uint8List m, _Gw gw) async {
    try {
      if (m.length < 16) return;
      final size = (m[13] << 8) | m[14];
      if (16 + size > m.length) return;
      final dg = unwrapDataBody(m.sublist(16, 16 + size));
      if (dg == null) return;
      final pd = await parseDatagram(dg);
      if (pd == null || !pd.sigValid) return;
      if (pd.payload.isEmpty) return;
      final p = pd.payload;
      switch (p[0]) {
        case 0x47: // GET -> serve
          final req = parseGet(p);
          if (req == null || onGet == null) return;
          final bytes = await onGet!(req.sha256) ?? Uint8List(0);
          if (bytes.isEmpty) return; // we don't have it; stay silent
          log?.call('node: serving GET ${_hex(req.sha256).substring(0, 12)} '
              '-> ${bytes.length}b');
          await _deliverToLeases(req.replyLeases,
              await buildDatagram(dest, buildDat(req.sha256, bytes)));
          break;
        case 0x44: // DAT -> complete fetch
          final dat = parseDat(p);
          if (dat == null) return;
          log?.call('node: got DAT ${_hex(dat.sha256).substring(0, 12)} '
              '${dat.bytes.length}b');
          final c = _fetches.remove(_hex(dat.sha256));
          if (c != null && !c.isCompleted) c.complete(dat.bytes);
          break;
        case 0x50: // PROVIDE -> store provider record
          final pr = parseProvide(p);
          if (pr != null) {
            _addProvider(pr.$1, pr.$2);
            log?.call('node: got PROVIDE ${_hex(pr.$1).substring(0, 12)}');
          }
          break;
        case 0x46: // FINDPROV -> reply with known providers
          final fp = parseFindProv(p);
          if (fp == null) return;
          final provs = _localProviders(fp.contentSha);
          log?.call('node: got FINDPROV ${_hex(fp.contentSha).substring(0, 12)} '
              '-> ${provs.length} known, ${fp.replyLeases.length} reply leases');
          if (provs.isEmpty) return; // nothing to report
          await _deliverToLeases(fp.replyLeases,
              await buildDatagram(dest, buildFpReply(fp.contentSha, provs)));
          break;
        case 0x52: // FPREPLY -> accumulate providers
          final r = parseFpReply(p);
          if (r == null) return;
          log?.call('node: got FPREPLY ${r.providers.length} provider(s)');
          final acc = _findAcc[_hex(r.contentSha)];
          if (acc != null) {
            for (final pv in r.providers) {
              acc.add(_hex(pv));
            }
          }
          break;
        case opGetManifest: // 'M' -> serve the file's manifest
          final r = parseFileShaReq(p);
          if (r == null) return;
          final mf = await _manifestFor(r.$1);
          log?.call('node: GETMANIFEST ${_hex(r.$1).substring(0, 12)} '
              '-> ${mf == null ? "(none)" : "${mf.pieceCount} pieces"}, '
              '${r.$2.length} reply leases');
          if (mf == null) return;
          await _deliverToLeases(r.$2,
              await buildDatagram(dest, buildDatManifest(r.$1, mf.encode())));
          break;
        case opDatManifest: // 'N' -> complete a manifest request
          final r = parseDatManifest(p);
          if (r == null) return;
          log?.call('node: got DATMANIFEST ${_hex(r.$1).substring(0, 12)} ${r.$2.length}b');
          _complete(_manifestWaiters, _hex(r.$1), r.$2);
          break;
        case opGetHave: // 'H' -> serve our piece bitmap
          final r = parseFileShaReq(p);
          if (r == null) return;
          final h = await _haveFor(r.$1);
          log?.call('node: GETHAVE ${_hex(r.$1).substring(0, 12)} '
              '-> ${h == null ? "(none)" : "${h.$1} pieces"}');
          if (h == null) return;
          await _deliverToLeases(r.$2,
              await buildDatagram(dest, buildDatHave(r.$1, h.$1, h.$2)));
          break;
        case opDatHave: // 'I' -> complete a HAVE request (keyed by provider)
          final r = parseDatHave(p);
          if (r == null) return;
          log?.call('node: got DATHAVE ${_hex(r.$1).substring(0, 12)} '
              'from ${_hex(pd.srcHash).substring(0, 12)}');
          _complete(_haveWaiters, '${_hex(r.$1)}:${_hex(pd.srcHash)}', r.$3);
          break;
        case opGetPiece: // 'p' -> serve one verified piece
          final r = parseGetPiece(p);
          if (r == null) return;
          final bytes = await _pieceFor(r.$1, r.$2);
          log?.call('node: GETPIECE ${_hex(r.$1).substring(0, 12)} #${r.$2} '
              '-> ${bytes == null ? "(none)" : "${bytes.length}b"}');
          if (bytes == null) return;
          await _deliverToLeases(r.$3,
              await buildDatagram(dest, buildDatPiece(r.$1, r.$2, bytes)));
          break;
        case opDatPiece: // 'q' -> complete a piece request
          final r = parseDatPiece(p);
          if (r == null) return;
          log?.call('node: got DATPIECE ${_hex(r.$1).substring(0, 12)} '
              '#${r.$2} ${r.$3.length}b');
          _complete(_pieceWaiters, '${_hex(r.$1)}:${r.$2}', r.$3);
          break;
      }
    } catch (e) {
      log?.call('node: tunnel-data error: $e');
    }
  }

  /// Send an I2NP message through our outbound tunnel to [gatewayHash]/[tunnelId]
  /// (TUNNEL delivery). The OBEP forwards it to that inbound gateway — the proper
  /// I2P path, which real routers honour (unlike our direct injection).
  Future<bool> _sendViaOutbound(
      Uint8List gatewayHash, int tunnelId, Uint8List i2npMessage) async {
    final ob = _ob;
    if (ob == null || ob.dead) return false;
    try {
      final cells = fragmentForTunnel(
          message: i2npMessage,
          deliveryType: 1, // TUNNEL
          toHash: gatewayHash,
          toTunnel: tunnelId);
      for (final cell in cells) {
        final wire = ob.layer.decrypt(cell); // OB gateway preprocessing
        final body = Uint8List(4 + 1024);
        body[0] = (ob.tunnelId >> 24) & 0xff;
        body[1] = (ob.tunnelId >> 16) & 0xff;
        body[2] = (ob.tunnelId >> 8) & 0xff;
        body[3] = ob.tunnelId & 0xff;
        body.setRange(4, 4 + 1024, wire);
        await ob.session.sendI2np(18, body); // TunnelData
      }
      log?.call('node: sent ${cells.length} cell(s) via OB to '
          '${_hex(gatewayHash).substring(0, 12)}/$tunnelId');
      return true;
    } catch (e) {
      ob.dead = true;
      return false;
    }
  }

  /// Deliver a datagram into [tunnelId] at gateway [gatewayHash]. I2P delivery is
  /// best-effort and our requests are idempotent (a duplicate GET just gets
  /// answered twice; the fetch completer fires once), so we fire BOTH the proper
  /// outbound-tunnel path AND direct injection into the target's inbound gateway.
  /// Relying on the OB send's local success alone masks silent downstream loss at
  /// the OBEP, so we never want it to short-circuit the direct path.
  Future<bool> _deliver(Uint8List gatewayHash, int tunnelId, Uint8List datagram) async {
    final msg = buildStandardI2np(i2npData, randomMsgId(), wrapDataBody(datagram));
    final viaOb = await _sendViaOutbound(gatewayHash, tunnelId, msg);
    final viaDirect = await _injectDirect(gatewayHash, tunnelId, msg);
    return viaOb || viaDirect;
  }

  /// Inject an I2NP message straight into a destination's inbound gateway by
  /// handing it a TunnelGateway (type 19) — the gateway forwards it down the
  /// tunnel to its owner. Reuses an existing session to that gateway when we have
  /// one (our own gateway, or a cached tx session), otherwise dials it.
  Future<bool> _injectDirect(
      Uint8List gatewayHash, int tunnelId, Uint8List msg) async {
    final tg = buildTunnelGateway(tunnelId, msg);
    final k = _hex(gatewayHash);
    for (final g in _gws) {
      if (k == _hex(g.ri.identityHash)) {
        try {
          await g.session.sendI2np(19, tg);
          return true;
        } catch (_) {}
      }
    }
    final existing = _txSessions[k];
    if (existing != null) {
      try {
        await existing.sendI2np(19, tg);
        return true;
      } catch (_) {
        try {
          existing.close();
        } catch (_) {}
        _txSessions.remove(k);
      }
    }
    final ri = await _resolveRouter(gatewayHash);
    if (ri == null) {
      log?.call('node: deliver: no RI for gw ${k.substring(0, 12)}');
      return false;
    }
    Ntcp2Session? s;
    try {
      s = await _dial(ri, ephemeral: true);
      await s.handshake().timeout(const Duration(seconds: 8));
      _txSessions[k] = s;
      await s.sendI2np(19, tg);
      log?.call('node: deliver: injected to gw ${k.substring(0, 12)}');
      return true;
    } catch (e) {
      log?.call('node: deliver: dial/send failed gw ${k.substring(0, 12)}: $e');
      try {
        s?.close();
      } catch (_) {}
      _txSessions.remove(k);
      return false;
    }
  }

  RouterInfo? _findPeer(Uint8List hash) {
    final h = _hex(hash);
    for (final ri in _peers) {
      if (_hex(ri.identityHash) == h) return ri;
    }
    return null;
  }

  /// Resolve a router's full RouterInfo so we can dial it: from our reseed set,
  /// the cache, or a netDB RouterInfo lookup. Essential cross-device — another
  /// device's inbound gateway is almost never in our reseed set, so to deliver
  /// to it we must fetch its address from the floodfills.
  Future<RouterInfo?> _resolveRouter(Uint8List hash) async {
    return _findPeer(hash) ?? _riCache[_hex(hash)] ?? await lookupRouterInfo(hash);
  }

  /// Look up a RouterInfo (store type 0) from the closest floodfills and cache
  /// it. Mirrors lookupLeases: queries floodfills CONCURRENTLY and returns the
  /// first hit (sequential dials to dead floodfills used to cost ~8 s each on the
  /// delivery hot path, stalling every send).
  Future<RouterInfo?> lookupRouterInfo(Uint8List routerHash) async {
    final k = _hex(routerHash);
    final targets =
        _closestFloodfills(_routingKey(routerHash), 8).where((ff) => _hex(ff.identityHash) != k).toList();
    final done = Completer<RouterInfo?>();
    var pending = targets.length;
    if (pending == 0) return null;
    for (final ff in targets) {
      () async {
        Ntcp2Session? s;
        try {
          s = await _dial(ff, ephemeral: true);
          await s.handshake().timeout(const Duration(seconds: 8));
          await s.sendI2np(I2npType.databaseLookup,
              buildDatabaseLookup(routerHash, s.us.identityHash));
          for (var i = 0; i < 4; i++) {
            final r = await s.nextI2np(const Duration(seconds: 6));
            if (r == null) break;
            if (r.$1 == I2npType.databaseStore &&
                _hex(r.$2.sublist(0, 32)) == k &&
                r.$2[32] == 0) {
              final raw = gunzipRi(r.$2);
              final ri = raw == null ? null : parseRouterInfo(raw);
              if (ri != null) {
                _riCache[k] = ri;
                if (!done.isCompleted) done.complete(ri);
              }
              break;
            } else if (r.$1 == I2npType.databaseSearchReply &&
                _hex(r.$2.sublist(0, 32)) == k) {
              break; // not here
            }
          }
        } catch (_) {
        } finally {
          try {
            s?.close();
          } catch (_) {}
          if (--pending == 0 && !done.isCompleted) done.complete(null);
        }
      }();
    }
    return done.future;
  }

  Future<Uint8List?> fetch(Uint8List targetDestHash, Uint8List sha256,
      {Duration timeout = const Duration(seconds: 40)}) async {
    final shaKey = _hex(sha256);
    final get = await buildDatagram(dest, buildGet(sha256, _myLeases()));
    // Several rounds: fan the GET out to all the target's gateways and await the
    // reply (which also fans back over all our gateways). Re-send on timeout
    // since per-hop 1-hop tunnel delivery is lossy on the live net.
    const rounds = 4;
    final per = Duration(
        milliseconds: (timeout.inMilliseconds ~/ rounds).clamp(7000, 15000));
    for (var round = 0; round < rounds; round++) {
      final c = Completer<Uint8List?>();
      _fetches[shaKey] = c;
      final sent = await _sendToDest(targetDestHash, get);
      if (!sent && round == 0) {
        _fetches.remove(shaKey);
        log?.call('node: fetch: no lease for target');
        return null;
      }
      final bytes = await c.future.timeout(per, onTimeout: () => null);
      _fetches.remove(shaKey);
      if (bytes != null && bytes.isNotEmpty) {
        if (_hex(I2pCrypto.sha256(bytes)) == shaKey) return bytes;
        log?.call('node: fetch: hash mismatch');
        return null;
      }
    }
    return null;
  }

  // ---- content-routing API ----

  Uint8List? _fromHex(String h) {
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// The [n] roster devices whose IDs are XOR-closest to [key], excluding self.
  List<Uint8List> _closestPeers(Uint8List key, int n) {
    final list = _roster.values
        .where((h) => _hex(h) != _hex(dest.hash))
        .toList();
    list.sort((a, b) {
      for (var i = 0; i < 32; i++) {
        final da = a[i] ^ key[i], db = b[i] ^ key[i];
        if (da != db) return da - db;
      }
      return 0;
    });
    return list.take(n).toList();
  }

  /// Our current reply leases (one per gateway) to embed in outgoing requests.
  List<ReplyLease> _myLeases() =>
      [for (final g in _gws) ReplyLease(g.gateway.identityHash, g.gatewayTunnel)];

  /// Fan a reply datagram out to every embedded reply lease.
  Future<void> _deliverToLeases(List<ReplyLease> leases, Uint8List datagram) async {
    for (final l in leases) {
      try {
        await _deliver(l.gatewayHash, l.tunnelId, datagram);
      } catch (_) {}
    }
  }

  /// Deliver a datagram to a destination via ALL of its gateways (fan-out).
  /// A gateway accepting a TunnelGateway doesn't guarantee it forwards to the
  /// endpoint, so sending through every gateway maximises arrival. Returns true
  /// if at least one gateway accepted it.
  Future<bool> _sendToDest(Uint8List destHash, Uint8List datagram) async {
    final leases = await lookupLeases(destHash);
    var any = false;
    for (final lease in leases) {
      try {
        if (await _deliver(lease.gatewayHash, lease.tunnelId, datagram)) any = true;
      } catch (_) {}
    }
    return any;
  }

  void _addProvider(Uint8List contentSha, Uint8List providerDest) {
    final m = _providers.putIfAbsent(_hex(contentSha), () => {});
    m[_hex(providerDest)] = DateTime.now().millisecondsSinceEpoch + _providerTtlMs;
  }

  List<Uint8List> _localProviders(Uint8List contentSha) {
    final m = _providers[_hex(contentSha)];
    if (m == null) return [];
    final now = DateTime.now().millisecondsSinceEpoch;
    m.removeWhere((_, exp) => exp < now);
    return m.keys.map(_fromHex).whereType<Uint8List>().toList();
  }

  /// Announce that we provide [contentSha]: store locally and tell the K closest
  /// devices. Call after archiving content you want others to find.
  Future<void> announce(Uint8List contentSha) async {
    _addProvider(contentSha, dest.hash);
    final dg = await buildDatagram(dest, buildProvide(contentSha, dest.hash));
    final peers = _closestPeers(contentSha, _replicas);
    var ok = 0;
    for (final peer in peers) {
      try {
        if (await _sendToDest(peer, dg)) ok++;
      } catch (_) {}
    }
    log?.call('node: announced to $ok/${peers.length} closest peers');
  }

  /// Find devices that provide [contentSha] by querying the K closest devices
  /// (and our own records). Returns provider destination hashes.
  Future<List<Uint8List>> findProviders(Uint8List contentSha,
      {int rounds = 3, Duration perRound = const Duration(seconds: 8)}) async {
    final key = _hex(contentSha);
    final acc = _findAcc.putIfAbsent(key, () => {});
    for (final p in _localProviders(contentSha)) {
      acc.add(_hex(p));
    }
    final peers = _closestPeers(contentSha, _replicas);
    // Per-hop tunnel delivery is lossy on the live net; re-send each round so a
    // reply has several chances to get back through our (or their) gateways.
    for (var r = 0; r < rounds && acc.isEmpty; r++) {
      final dg = await buildDatagram(dest, buildFindProv(contentSha, _myLeases()));
      var ok = 0;
      for (final peer in peers) {
        try {
          if (await _sendToDest(peer, dg)) ok++;
        } catch (_) {}
      }
      log?.call('node: FINDPROV round ${r + 1} sent to $ok/${peers.length}');
      await Future.delayed(perRound);
    }
    _findAcc.remove(key);
    return acc.map(_fromHex).whereType<Uint8List>().toList();
  }

  /// Discover providers for [contentSha] across the network (no prior knowledge
  /// of who holds it) and fetch the verified bytes from one of them.
  Future<Uint8List?> discoverFetch(Uint8List contentSha,
      {Duration timeout = const Duration(seconds: 40)}) async {
    final providers = await findProviders(contentSha);
    log?.call('node: discover ${_hex(contentSha).substring(0, 12)} -> '
        '${providers.length} provider(s)');
    for (final p in providers) {
      if (_hex(p) == _hex(dest.hash)) continue;
      final bytes = await fetch(p, contentSha, timeout: timeout);
      if (bytes != null) return bytes;
    }
    return null;
  }

  // ---- swarm: serving (we are a provider) ----

  void _complete(Map<String, Completer<Uint8List?>> m, String key, Uint8List v) {
    final c = m.remove(key);
    if (c != null && !c.isCompleted) c.complete(v);
  }

  /// The whole file for [fileSha] (from the host archive via onGet), cached once
  /// so repeated piece/manifest/have requests don't re-cross the isolate bridge.
  Future<Uint8List?> _wholeFile(Uint8List fileSha) async {
    final k = _hex(fileSha);
    if (_wholeKey == k && _wholeBytes != null) return _wholeBytes;
    if (onGet == null) return null;
    final b = await onGet!(fileSha);
    if (b == null || b.isEmpty) return null;
    if (b.length <= 64 * 1024 * 1024) {
      _wholeKey = k;
      _wholeBytes = b;
    }
    return b;
  }

  /// The manifest we'd serve for [fileSha]: from an active store, else built from
  /// the complete file in our archive.
  Future<TorrentManifest?> _manifestFor(Uint8List fileSha) async {
    final s = _stores[_hex(fileSha)];
    if (s != null) return s.manifest;
    final b = await _wholeFile(fileSha);
    return b == null ? null : TorrentManifest.fromBytes(b);
  }

  /// Our HAVE bitmap for [fileSha]: the store's partial bitmap, or a full bitmap
  /// if we hold the complete file.
  Future<(int, Uint8List)?> _haveFor(Uint8List fileSha) async {
    final s = _stores[_hex(fileSha)];
    if (s != null) return (s.pieceCount, s.bitmap());
    final b = await _wholeFile(fileSha);
    if (b == null) return null;
    final mf = TorrentManifest.fromBytes(b);
    final bm = Uint8List(mf.bitmapBytes);
    for (var i = 0; i < mf.pieceCount; i++) {
      bm[i >> 3] |= (0x80 >> (i & 7));
    }
    return (mf.pieceCount, bm);
  }

  /// Piece [index] of [fileSha]: from an active store, else sliced from the
  /// complete file in our archive.
  Future<Uint8List?> _pieceFor(Uint8List fileSha, int index) async {
    final s = _stores[_hex(fileSha)];
    if (s != null) {
      final pc = await s.readPiece(index);
      if (pc != null) return pc;
    }
    final b = await _wholeFile(fileSha);
    if (b == null) return null;
    final mf = TorrentManifest.fromBytes(b);
    if (index < 0 || index >= mf.pieceCount) return null;
    final start = index * mf.pieceLen;
    final end = (start + mf.pieceLen <= b.length) ? start + mf.pieceLen : b.length;
    return Uint8List.fromList(b.sublist(start, end));
  }

  // ---- swarm: delivery to peer gateways (reused send-only sessions) ----

  /// Send a TunnelGateway to [gatewayHash]/[tunnelId], reusing our own gateway
  /// session or a cached send-only session to that gateway (so a long download
  /// doesn't re-handshake per piece). Returns true if sent.
  Future<bool> _deliverCached(
      Uint8List gatewayHash, int tunnelId, Uint8List datagram) async {
    final msg = buildStandardI2np(i2npData, randomMsgId(), wrapDataBody(datagram));
    final viaOb = await _sendViaOutbound(gatewayHash, tunnelId, msg);
    final viaDirect = await _injectDirect(gatewayHash, tunnelId, msg);
    return viaOb || viaDirect;
  }

  /// Deliver [datagram] to [destHash] using cached leases + reused sessions.
  Future<bool> _sendToCachedDest(Uint8List destHash, Uint8List datagram) async {
    final k = _hex(destHash);
    final now = DateTime.now().millisecondsSinceEpoch;
    var entry = _leaseCache[k];
    if (entry == null || entry.$2 < now) {
      final leases = await lookupLeases(destHash);
      if (leases.isEmpty) {
        log?.call('node: send: no leases for ${k.substring(0, 12)}');
        return false;
      }
      entry = (leases, now + 5 * 60 * 1000);
      _leaseCache[k] = entry;
    }
    var any = false;
    for (final l in entry.$1) {
      try {
        if (await _deliverCached(l.gatewayHash, l.tunnelId, datagram)) any = true;
      } catch (_) {}
    }
    if (!any) _leaseCache.remove(k); // force a fresh lookup next time
    return any;
  }

  // ---- swarm: downloading (we are a leecher pulling from many providers) ----

  Future<TorrentManifest?> _requestManifest(
      Uint8List provider, Uint8List fileSha, Duration t) async {
    final key = _hex(fileSha);
    final c = Completer<Uint8List?>();
    _manifestWaiters[key] = c;
    final dg = await buildDatagram(dest, buildGetManifest(fileSha, _myLeases()));
    if (!await _sendToCachedDest(provider, dg)) {
      _manifestWaiters.remove(key);
      return null;
    }
    final bytes = await c.future.timeout(t, onTimeout: () => null);
    _manifestWaiters.remove(key);
    if (bytes == null) return null;
    final mf = TorrentManifest.decode(bytes);
    if (mf == null || _hex(mf.fileSha) != key) return null;
    return mf;
  }

  Future<Uint8List?> _requestHave(
      Uint8List provider, Uint8List fileSha, Duration t) async {
    final wk = '${_hex(fileSha)}:${_hex(provider)}';
    final c = Completer<Uint8List?>();
    _haveWaiters[wk] = c;
    final dg = await buildDatagram(dest, buildGetHave(fileSha, _myLeases()));
    if (!await _sendToCachedDest(provider, dg)) {
      _haveWaiters.remove(wk);
      return null;
    }
    final bm = await c.future.timeout(t, onTimeout: () => null);
    _haveWaiters.remove(wk);
    return bm;
  }

  Future<bool> _downloadPiece(Uint8List provider, Uint8List fileSha, int index,
      SwarmStore store, Duration t) async {
    final wk = '${_hex(fileSha)}:$index';
    final c = Completer<Uint8List?>();
    _pieceWaiters[wk] = c;
    final dg =
        await buildDatagram(dest, buildGetPiece(fileSha, index, _myLeases()));
    if (!await _sendToCachedDest(provider, dg)) {
      _pieceWaiters.remove(wk);
      return false;
    }
    final bytes = await c.future.timeout(t, onTimeout: () => null);
    _pieceWaiters.remove(wk);
    if (bytes == null) return false;
    return store.writePiece(index, bytes);
  }

  int _avail(Map<String, Uint8List> have, int idx) {
    var n = 0;
    for (final bm in have.values) {
      if (bitmapHas(bm, idx)) n++;
    }
    return n;
  }

  /// Collectively download [fileSha] from MANY providers in parallel (the swarm
  /// path; the only way to move a file over ~64 KiB, and the way large files are
  /// shared across devices). Discovers providers, fetches the manifest, then
  /// pulls missing pieces rarest-first across providers with failover. As pieces
  /// land we serve them, so this device seeds mid-download. Returns the verified
  /// complete file, or null. Keeps serving the (partial/complete) file after.
  Future<Uint8List?> swarmFetch(Uint8List fileSha,
      {List<Uint8List> seedProviders = const [],
      Duration perPiece = const Duration(seconds: 12),
      Duration budget = const Duration(minutes: 5),
      int cap = 8}) async {
    final key = _hex(fileSha);
    final me = _hex(dest.hash);
    final deadline = DateTime.now().add(budget);
    // With known seed providers (e.g. a direct share from a peer) skip the broad
    // discovery up front — we already know who has it; discovery is only the
    // fallback when we stall or when no seeds were given.
    var providers = <Uint8List>[
      ...seedProviders,
      if (seedProviders.isEmpty) ...await findProviders(fileSha),
    ].where((p) => _hex(p) != me).toList();
    // de-dup
    final seen = <String>{};
    providers = providers.where((p) => seen.add(_hex(p))).toList();
    if (providers.isEmpty) {
      log?.call('swarm: no providers for ${key.substring(0, 12)}');
      return null;
    }
    log?.call('swarm: ${providers.length} provider(s), requesting manifest');
    TorrentManifest? manifest;
    // 1-hop tunnel forwarding on the live net is PROBABILISTIC — a given router
    // forwards only a fraction of the time, so a request often needs many tries
    // before one round-trips. Keep retrying (re-resolving leases as the provider
    // rotates its gateways) until a deadline rather than giving up after a few
    // misses; this is what turns intermittent into reliable. Cap the manifest
    // phase at ~60% of the budget so pieces still get time.
    final reqTimeout = Duration(
        milliseconds: (perPiece.inMilliseconds ~/ 2).clamp(5000, 10000));
    final mfDeadline = DateTime.now().add(Duration(
        milliseconds:
            (budget.inMilliseconds * 3 ~/ 5).clamp(60000, 180000)));
    var mfRound = 0;
    while (manifest == null && _running && DateTime.now().isBefore(mfDeadline)) {
      if (mfRound > 0 && mfRound % 3 == 0) {
        // periodically re-resolve in case the provider rotated to fresh gateways
        for (final p in providers) {
          _leaseCache.remove(_hex(p));
        }
      }
      mfRound++;
      for (final p in providers) {
        manifest = await _requestManifest(p, fileSha, reqTimeout);
        if (manifest != null) break;
      }
    }
    if (manifest == null) {
      log?.call('swarm: no manifest from ${providers.length} provider(s) '
          'after $mfRound rounds');
      return null;
    }
    log?.call('swarm: ${key.substring(0, 12)} '
        '${manifest.pieceCount} pieces x ${manifest.pieceLen}B from '
        '${providers.length} provider(s)');
    final store = await SwarmStore.open(manifest, swarmBaseDir ?? Directory.systemTemp);
    _stores[key] = store;
    _addProvider(fileSha, dest.hash); // discoverable as a (partial) seed
    final full = Uint8List(manifest.bitmapBytes);
    for (var i = 0; i < manifest.pieceCount; i++) {
      full[i >> 3] |= (0x80 >> (i & 7));
    }
    // HAVE bitmaps are CACHED across rounds (a provider that doesn't answer is
    // assumed to be a whole-file seeder). Refetching every round would burn a
    // whole perPiece timeout per round on a lossy link; instead we only refresh
    // when new providers join. Each piece is re-requested afresh until it lands
    // (a lost cell can't be patched across requests — every request remakes the
    // I2NP message id — so we retry whole pieces within the overall budget).
    final have = <String, Uint8List>{};
    Future<void> refreshHave() async {
      await Future.wait(providers.map((p) async {
        final bm = await _requestHave(p, fileSha, perPiece);
        if (bm != null && bm.isNotEmpty) have[_hex(p)] = bm;
      }));
      for (final p in providers) {
        have.putIfAbsent(_hex(p), () => full);
      }
    }
    await refreshHave();
    var provRot = 0;
    var roundsSinceProgress = 0;
    while (_running && !store.isComplete && DateTime.now().isBefore(deadline)) {
      final needed = <int>[];
      for (var i = 0; i < manifest.pieceCount; i++) {
        if (!store.hasPiece(i)) needed.add(i);
      }
      needed.sort((a, b) => _avail(have, a) - _avail(have, b)); // rarest first
      final provList = providers.map(_hex).toList();
      final before = store.haveCount;
      final jobs = <Future<bool>>[];
      for (final idx in needed) {
        if (jobs.length >= cap) break;
        Uint8List? chosen;
        for (var n = 0; n < provList.length; n++) {
          final ph = provList[(provRot + n) % provList.length];
          if (bitmapHas(have[ph] ?? Uint8List(0), idx)) {
            chosen = _fromHex(ph);
            provRot = (provRot + n + 1) % provList.length;
            break;
          }
        }
        chosen ??= _fromHex(provList[provRot++ % provList.length]); // fallback
        if (chosen != null) {
          jobs.add(_downloadPiece(chosen, fileSha, idx, store, perPiece));
        }
      }
      if (jobs.isEmpty) break; // no providers at all
      await Future.wait(jobs);
      log?.call('swarm: ${store.haveCount}/${manifest.pieceCount} pieces');
      if (store.haveCount > before) {
        roundsSinceProgress = 0;
        await announce(fileSha); // re-seed as pieces land
      } else if (++roundsSinceProgress % 6 == 0) {
        // stalled a while: look for fresh providers and refresh HAVE
        final more = (await findProviders(fileSha, rounds: 2))
            .where((p) => _hex(p) != me && seen.add(_hex(p)))
            .toList();
        if (more.isNotEmpty) {
          providers = [...providers, ...more];
          await refreshHave();
        }
      }
    }
    final out = await store.assemble();
    if (out != null) {
      log?.call('swarm: complete ${key.substring(0, 12)} ${out.length}B');
      await announce(fileSha);
    } else {
      log?.call('swarm: incomplete ${store.haveCount}/${manifest.pieceCount}');
    }
    return out;
  }

  void close() {
    _running = false;
    _kaTimer?.cancel();
    _natTimer?.cancel();
    for (final g in _gws) {
      g.session.close();
    }
    _gws.clear();
    for (final s in _txSessions.values) {
      try {
        s.close();
      } catch (_) {}
    }
    _txSessions.clear();
    try {
      _ob?.session.close();
    } catch (_) {}
    _ob = null;
    for (final st in _stores.values) {
      st.close();
    }
    _stores.clear();
  }

  static Uint8List? gunzipRi(Uint8List storeBody) {
    try {
      final l = (storeBody[37] << 8) | storeBody[38];
      return Uint8List.fromList(GZipDecoder().decodeBytes(storeBody.sublist(39, 39 + l)));
    } catch (_) {
      return null;
    }
  }
}
