/*
 * FileTransferNode — wires the file-transfer sessions to a live Reticulum
 * transport. It is the per-node hub that:
 *   - serves files: accepts inbound LINKREQUESTs to our "files" destination,
 *     completes the link handshake (responder), and runs a FileServeSession that
 *     answers GET_MANIFEST/GET_CHUNK from a FileSource;
 *   - fetches files: opens a link to a provider's "files" destination (initiator),
 *     then runs a FileFetchSession to pull + verify a file by its sha256.
 *
 * Transport-agnostic: the owner supplies a [send] callback (e.g.
 * transport.sendOnAll) and feeds inbound packets to [handlePacket]. Link/file
 * packets are addressed by link_id, so broadcasting replies on all interfaces is
 * correct (the wrong peer ignores them); transport-routed unicast is a later
 * optimization.
 */
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../reticulum/rns_crypto.dart';
import '../reticulum/rns_identity.dart';
import '../reticulum/rns_link.dart';
import '../reticulum/rns_packet.dart';
import 'dht/dht_core.dart';
import 'dht/dht_message.dart';
import 'dht/dht_node.dart';
import 'dht/provider_record.dart';
import 'file_manifest.dart';
import 'file_transfer.dart';
import 'provider_connection.dart';
import 'serve_quota.dart';

const String kFilesApp = 'geogram';
const List<String> kFilesAspects = ['files'];

class _ServeEntry {
  final RnsLink link;
  final FileServeSession serve;
  _ServeEntry(this.link, this.serve);
}

class _FetchEntry {
  final RnsLink link;
  final Uint8List fileHash;
  final Completer<Uint8List?> done;
  FileFetchSession? fetch; // null until the link is active
  Timer? timeout;
  _FetchEntry(this.link, this.fileHash, this.done);
}

class _DhtRpcEntry {
  final RnsLink link;
  final Uint8List reqBytes;
  final Completer<Uint8List?> done = Completer<Uint8List?>();
  bool sent = false; // request sent (link active)
  _DhtRpcEntry(this.link, this.reqBytes);
}

class _DepositEntry {
  final RnsLink link;
  final Uint8List sha;
  final Uint8List bytes;
  final String ext;
  final Uint8List pub;
  final Uint8List sig;
  final Completer<bool> done;
  FileDepositSession? dep; // null until the link is active
  Timer? timeout;
  _DepositEntry(
      this.link, this.sha, this.bytes, this.ext, this.pub, this.sig, this.done);
}

class _Provided {
  final Uint8List sha;
  final int capacity;
  final Uint8List? manifestHash;
  _Provided(this.sha, this.capacity, this.manifestHash);
}

class FileTransferNode {
  final RnsIdentity identity; // our identity (must hold private keys)
  final FileSource source; // what we serve
  final void Function(Uint8List raw) send; // e.g. transport.sendOnAll
  final void Function(String msg)? log;

  late final Uint8List filesDestHash =
      RnsDestination.hash(identity, kFilesApp, kFilesAspects);
  late final Uint8List dhtDestHash =
      RnsDestination.hash(identity, kDhtApp, kDhtAspects);

  final Map<String, _ServeEntry> _serve = {}; // link_id hex -> serve
  final Map<String, _FetchEntry> _fetch = {}; // link_id hex -> fetch
  // DHT links: responder links we host, and in-flight outbound RPC links.
  final Map<String, RnsLink> _dhtServeLinks = {};
  final List<String> _dhtServeOrder = [];
  final Map<String, _DhtRpcEntry> _dhtRpcByLink = {};
  static const int _maxDhtServeLinks = 128;
  // Outbound provider connections (multi-source fetch), keyed by link_id hex.
  final Map<String, ProviderConnection> _provConns = {};
  // Files we advertise, for periodic republish (TTL refresh).
  final Map<String, _Provided> _provided = {};
  // Arbitrary DHT keys we advertise regardless of the file serve-quota (used for
  // folder discovery: folderId -> provider). Republished alongside files.
  final Map<String, _Provided> _providedKeys = {};

  /// The Kademlia index node (provider lookup/publish). Null unless [enableDht].
  DhtNode? dht;

  /// Serving-side budget / anti-abuse guard applied to everything we serve.
  final ServeQuota serveQuota;

  /// Resolves the next-hop transport for reaching a peer (null = direct
  /// neighbour). Supplied by the host (its RnsTransport path table); when it
  /// returns a transport id, our outbound links are transport-addressed so an
  /// rnsd forwards them — this is what makes fetch work across the internet.
  final Uint8List? Function(RnsIdentity peer)? nextHopFor;

  /// Called when we serve a file's manifest to another node (one download by a
  /// peer), with the 32-byte file hash. Drives the per-file download metric.
  final void Function(Uint8List fileHash)? onServed;

  /// Store-and-forward hosting hooks (see FileServeSession). When both are set
  /// this node accepts blob deposits from peers; null = deposits declined.
  final DepositVerdict Function(
      Uint8List sha, int size, String ext, String pubHex, String sigHex)?
      onDepositOffer;
  final void Function(
      Uint8List sha, Uint8List bytes, String originPubHex, int tier, String ext)?
      onDepositStore;

  FileTransferNode({
    required this.identity,
    required this.source,
    required this.send,
    this.log,
    bool enableDht = false,
    ServeQuota? serveQuota,
    this.nextHopFor,
    this.onServed,
    this.onDepositOffer,
    this.onDepositStore,
  }) : serveQuota = serveQuota ?? ServeQuota() {
    if (enableDht) {
      dht = DhtNode(identity: identity, sendRpc: _dhtSendRpc, log: log);
    }
  }

  /// Learn a peer (from its announce) as a DHT contact.
  void addPeerFromAnnounce(RnsIdentity peer) =>
      dht?.routing.add(DhtContact.ofIdentity(peer));

  /// Feed an inbound packet. Returns true if it was a file/link packet we
  /// consumed (so the caller can skip announce handling). Safe to call for every
  /// packet.
  Future<bool> handlePacket(RnsPacket p) async {
    // 1) A peer opening a link to one of our destinations.
    if (p.packetType == RnsPacketType.linkRequest) {
      if (RnsCrypto.constantTimeEquals(p.destHash, filesDestHash)) {
        await _acceptLink(p);
        return true;
      }
      if (dht != null && RnsCrypto.constantTimeEquals(p.destHash, dhtDestHash)) {
        await _acceptDhtLink(p);
        return true;
      }
    }
    // 2) Traffic on an existing link (handshake proof, link data, resource).
    if (p.destType == RnsDestType.link) {
      final id = _hex(p.destHash);
      final serve = _serve[id];
      if (serve != null) {
        _onServePacket(serve, p);
        return true;
      }
      final fetch = _fetch[id];
      if (fetch != null) {
        await _onFetchPacket(fetch, p);
        return true;
      }
      final dep = _deposit[id];
      if (dep != null) {
        await _onDepositPacket(dep, p);
        return true;
      }
      final ds = _dhtServeLinks[id];
      if (ds != null) {
        await _onDhtServePacket(ds, p);
        return true;
      }
      final dr = _dhtRpcByLink[id];
      if (dr != null) {
        await _onDhtRpcPacket(dr, p);
        return true;
      }
      final pc = _provConns[id];
      if (pc != null) {
        await pc.onPacket(p);
        return true;
      }
    }
    return false;
  }

  // ── Serve side ─────────────────────────────────────────────────────────
  Future<void> _acceptLink(RnsPacket request) async {
    try {
      final link = await RnsLink.responder(identity, request);
      final id = _hex(link.linkId!);
      _serve[id] = _ServeEntry(
        link,
        FileServeSession(link, source,
            quota: serveQuota,
            requesterId: id,
            onServed: onServed,
            onDepositOffer: onDepositOffer,
            onDepositStore: onDepositStore),
      );
      send((await link.buildProof()).pack());
      log?.call('files: accepted link $id');
    } catch (e) {
      log?.call('files: accept link failed: $e');
    }
  }

  void _onServePacket(_ServeEntry e, RnsPacket p) {
    if (e.link.status != RnsLinkStatus.active &&
        p.context == RnsContext.lrrtt) {
      e.link.handleRtt(p); // activate
      return;
    }
    for (final out in e.serve.onPacket(p)) {
      send(out.pack());
    }
  }

  // ── Fetch side ─────────────────────────────────────────────────────────
  /// Fetch [fileHash] (sha256, 32B) from [providerPublicIdentity] (learned from
  /// an announce). Returns the verified bytes, or null on failure/timeout.
  Future<Uint8List?> fetch(
    Uint8List fileHash,
    RnsIdentity providerPublicIdentity, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final link =
        await RnsLink.initiator(providerPublicIdentity, kFilesApp, kFilesAspects);
    link.nextHop = nextHopFor?.call(providerPublicIdentity);
    final req = link.buildRequest();
    final entry = _FetchEntry(link, fileHash, Completer<Uint8List?>());
    final id = _hex(link.linkId!);
    _fetch[id] = entry;
    entry.timeout = Timer(timeout, () {
      if (!entry.done.isCompleted) {
        log?.call('files: fetch timeout ${_hex(fileHash)}');
        entry.done.complete(null);
      }
    });
    send(req.pack());
    final result = await entry.done.future;
    entry.timeout?.cancel();
    _fetch.remove(id);
    return result;
  }

  Future<void> _onFetchPacket(_FetchEntry e, RnsPacket p) async {
    // Handshake: validate the responder's proof, send LRRTT, start the fetch.
    if (e.fetch == null) {
      if (p.packetType == RnsPacketType.proof && p.context == RnsContext.lrproof) {
        final rtt = await e.link.handleProof(p);
        if (rtt == null) {
          _finishFetch(e, null, 'proof validation failed');
          return;
        }
        send(rtt.pack());
        final f = FileFetchSession(e.link, e.fileHash);
        e.fetch = f;
        send(f.start().pack());
      }
      return;
    }
    // Active: drive the fetch session.
    final f = e.fetch!;
    for (final out in f.onPacket(p)) {
      send(out.pack());
    }
    if (f.state == FileFetchState.done) {
      _finishFetch(e, f.result, null);
    } else if (f.state == FileFetchState.failed) {
      _finishFetch(e, null, f.error);
    }
  }

  void _finishFetch(_FetchEntry e, Uint8List? result, String? err) {
    if (err != null) log?.call('files: fetch failed: $err');
    if (!e.done.isCompleted) e.done.complete(result);
  }

  // ── Deposit side (ask a host to keep a blob) ───────────────────────────────
  final Map<String, _DepositEntry> _deposit = {}; // link_id hex -> deposit

  /// Deposit [bytes] (sha256 = [sha], extension [ext]) to [hostPublicIdentity]
  /// for store-and-forward hosting. [pub]/[sig] are the depositor's NOSTR x-only
  /// pubkey (32B) and a Schnorr signature over depositAuthMessageHex(shaHex) (64B)
  /// that authorizes hosting this blob. Returns true if the host stored it.
  Future<bool> deposit(
    Uint8List sha,
    Uint8List bytes,
    String ext,
    Uint8List pub,
    Uint8List sig,
    RnsIdentity hostPublicIdentity, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final link =
        await RnsLink.initiator(hostPublicIdentity, kFilesApp, kFilesAspects);
    link.nextHop = nextHopFor?.call(hostPublicIdentity);
    final req = link.buildRequest();
    final entry = _DepositEntry(link, sha, bytes, ext, pub, sig, Completer<bool>());
    final id = _hex(link.linkId!);
    _deposit[id] = entry;
    entry.timeout = Timer(timeout, () {
      if (!entry.done.isCompleted) {
        log?.call('files: deposit timeout ${_hex(sha)}');
        entry.done.complete(false);
      }
    });
    send(req.pack());
    final ok = await entry.done.future;
    entry.timeout?.cancel();
    _deposit.remove(id);
    return ok;
  }

  Future<void> _onDepositPacket(_DepositEntry e, RnsPacket p) async {
    if (e.dep == null) {
      if (p.packetType == RnsPacketType.proof && p.context == RnsContext.lrproof) {
        final rtt = await e.link.handleProof(p);
        if (rtt == null) {
          if (!e.done.isCompleted) e.done.complete(false);
          return;
        }
        send(rtt.pack());
        final d =
            FileDepositSession(e.link, e.sha, e.bytes, e.ext, e.pub, e.sig);
        e.dep = d;
        send(d.start().pack());
      }
      return;
    }
    final d = e.dep!;
    for (final out in d.onPacket(p)) {
      send(out.pack());
    }
    if (d.state == FileDepositState.done) {
      if (!e.done.isCompleted) e.done.complete(true);
    } else if (d.state == FileDepositState.failed) {
      log?.call('files: deposit rejected: ${d.error}');
      if (!e.done.isCompleted) e.done.complete(false);
    }
  }

  // ── DHT over Reticulum links ───────────────────────────────────────────────
  /// Resolve providers for [sha256] via the DHT, then fetch the file from
  /// several of them in parallel (multi-source). Returns the verified bytes.
  Future<Uint8List?> resolveAndFetch(
    Uint8List sha256, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final d = dht;
    if (d == null) return null;
    final providers = await d.resolve(sha256);
    log?.call('files: resolved ${providers.length} provider(s) for '
        '${_hex(sha256).substring(0, 8)}');
    if (providers.isEmpty) return null;
    return multiSourceFetch(sha256, providers, timeout: timeout);
  }

  /// Fetch [sha256] from up to [maxConns] providers in parallel. The manifest is
  /// pulled from any provider; chunks are work-stolen from a shared queue, so
  /// faster providers naturally serve more (bandwidth-aware), and a failed chunk
  /// is requeued for another provider. Verifies each chunk and the whole file.
  Future<Uint8List?> multiSourceFetch(
    Uint8List sha256,
    List<ProviderRecord> providers, {
    int maxConns = 5,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (providers.isEmpty) return null;
    final chosen =
        providers.length <= maxConns ? providers : providers.sublist(0, maxConns);
    final conns = <ProviderConnection>[];
    for (final pr in chosen) {
      conns.add(await openProvider(pr.providerIdentity));
    }
    final ready = <ProviderConnection>[];
    await Future.wait(conns.map((c) async {
      if (await c.ready()) {
        ready.add(c);
      } else {
        closeProvider(c);
      }
    }));
    if (ready.isEmpty) return null;

    FileManifest? manifest;
    for (final c in ready) {
      manifest = await c.getManifest(sha256);
      if (manifest != null) break;
    }
    final m = manifest;
    if (m == null) {
      for (final c in ready) {
        closeProvider(c);
      }
      return null;
    }

    final n = m.chunkCount;
    final chunks = List<Uint8List?>.filled(n, null);
    final queue = Queue<int>()..addAll(List.generate(n, (i) => i));
    final attempts = <int, int>{};

    Future<void> worker(ProviderConnection c) async {
      while (queue.isNotEmpty) {
        int? idx;
        while (queue.isNotEmpty) {
          final i = queue.removeFirst();
          if (chunks[i] == null) {
            idx = i;
            break;
          }
        }
        if (idx == null) break;
        final bytes = await c.getChunk(sha256, idx);
        if (bytes != null && _sha(bytes) == _hex(m.chunkHashes[idx])) {
          chunks[idx] = bytes;
        } else {
          final t = (attempts[idx] ?? 0) + 1;
          attempts[idx] = t;
          if (t <= 3) queue.addLast(idx); // try another provider
          if (bytes == null) return; // this connection looks dead — retire it
        }
      }
    }

    await Future.wait(ready.map(worker)).timeout(timeout, onTimeout: () => const []);
    final sources = ready.length;
    for (final c in ready) {
      closeProvider(c);
    }
    if (chunks.any((c) => c == null)) return null;
    final out = BytesBuilder();
    for (final c in chunks) {
      out.add(c!);
    }
    final bytes = out.toBytes();
    if (_sha(bytes) != _hex(sha256)) return null;
    log?.call('files: assembled ${bytes.length}B from $sources source(s)');
    return bytes;
  }

  /// Open a (registered) provider connection to [provider]'s files destination.
  Future<ProviderConnection> openProvider(RnsIdentity provider) async {
    final link = await RnsLink.initiator(provider, kFilesApp, kFilesAspects);
    link.nextHop = nextHopFor?.call(provider);
    final reqPkt = link.buildRequest(); // sets link.linkId
    final conn = ProviderConnection(link, send);
    _provConns[_hex(link.linkId!)] = conn;
    send(reqPkt.pack());
    return conn;
  }

  void closeProvider(ProviderConnection c) {
    _provConns.remove(_hex(c.link.linkId!));
    c.close();
  }

  /// Announce ourselves as a provider of [sha256] (auto-seed): publish a signed
  /// provider record at the k DHT nodes closest to the file key, and remember it
  /// for periodic republish. Returns how many holders accepted it.
  Future<int> publishProvider(
    Uint8List sha256, {
    int capacity = kCapUnknown,
    Uint8List? manifestHash,
  }) async {
    _provided[_hex(sha256)] =
        _Provided(Uint8List.fromList(sha256), capacity, manifestHash);
    return _publishOne(sha256, capacity, manifestHash);
  }

  /// Advertise ourselves as a provider of an arbitrary 32-byte DHT [key] (e.g. a
  /// folder id), independent of the file serve-quota — folders are metadata, not
  /// bulk bytes, so they should always be discoverable. Remembered for republish.
  Future<int> publishKey(Uint8List key, {int capacity = kCapUnknown}) async {
    final d = dht;
    if (d == null) return 0;
    _providedKeys[_hex(key)] = _Provided(Uint8List.fromList(key), capacity, null);
    final rec = await ProviderRecord.create(
        providerIdentity: identity, sha256: key, capacity: capacity);
    return d.publish(rec);
  }

  /// Resolve the provider node identities advertising a 32-byte [key] (folder id
  /// or sha256), best capacity first, excluding ourselves.
  Future<List<RnsIdentity>> resolveProviders(Uint8List key) async {
    final d = dht;
    if (d == null) return const [];
    final recs = await d.resolve(key);
    final self = _hex(identity.hash);
    return [
      for (final r in recs)
        if (_hex(r.providerIdentity.hash) != self) r.providerIdentity
    ];
  }

  /// Stop advertising [sha256] (let its record expire at TTL).
  void unpublishProvider(Uint8List sha256) => _provided.remove(_hex(sha256));

  int get providedCount => _provided.length;

  /// Re-publish all advertised files (refreshes TTL + re-stores at the current k
  /// closest nodes after churn). Drive from a periodic timer well under the TTL.
  Future<void> republishAll() async {
    for (final p in _provided.values.toList()) {
      await _publishOne(p.sha, p.capacity, p.manifestHash);
    }
    // Folder (and other ungated) keys advertise regardless of the serve-quota.
    final d = dht;
    if (d != null) {
      for (final p in _providedKeys.values.toList()) {
        final rec = await ProviderRecord.create(
            providerIdentity: identity, sha256: p.sha, capacity: p.capacity);
        await d.publish(rec);
      }
    }
    final n = _provided.length + _providedKeys.length;
    if (n > 0) log?.call('files: republished $n record(s)');
  }

  Future<int> _publishOne(Uint8List sha256, int capacity, Uint8List? manifestHash) async {
    final d = dht;
    if (d == null) return 0;
    // Don't advertise when we can't serve (off switch or daily budget spent) —
    // our records simply age out so resolvers route around us until we recover.
    if (!serveQuota.available) return 0;
    final rec = await ProviderRecord.create(
      providerIdentity: identity,
      sha256: sha256,
      capacity: capacity,
      manifestHash: manifestHash,
    );
    return d.publish(rec);
  }

  static String _sha(Uint8List b) =>
      _hex(crypto.sha256.convert(b).bytes);

  // DhtNode.sendRpc bridge: send a DHT message to a contact over a (transient)
  // link to its dht destination, await the single-packet reply.
  Future<DhtMessage?> _dhtSendRpc(DhtContact to, DhtMessage req) async {
    final respBytes = await _dhtRpcRaw(to.identity, req.encode());
    return respBytes == null ? null : DhtMessage.decode(respBytes);
  }

  Future<Uint8List?> _dhtRpcRaw(RnsIdentity peer, Uint8List reqBytes) async {
    final link = await RnsLink.initiator(peer, kDhtApp, kDhtAspects);
    link.nextHop = nextHopFor?.call(peer);
    final reqPkt = link.buildRequest();
    final id = _hex(link.linkId!);
    final e = _DhtRpcEntry(link, reqBytes);
    _dhtRpcByLink[id] = e;
    send(reqPkt.pack());
    final resp = await e.done.future
        .timeout(const Duration(seconds: 8), onTimeout: () => null);
    _dhtRpcByLink.remove(id);
    return resp;
  }

  Future<void> _acceptDhtLink(RnsPacket request) async {
    try {
      final link = await RnsLink.responder(identity, request);
      final id = _hex(link.linkId!);
      _dhtServeLinks[id] = link;
      _dhtServeOrder.add(id);
      if (_dhtServeOrder.length > _maxDhtServeLinks) {
        _dhtServeLinks.remove(_dhtServeOrder.removeAt(0));
      }
      send((await link.buildProof()).pack());
    } catch (e) {
      log?.call('dht: accept link failed: $e');
    }
  }

  Future<void> _onDhtServePacket(RnsLink link, RnsPacket p) async {
    if (link.status != RnsLinkStatus.active && p.context == RnsContext.lrrtt) {
      link.handleRtt(p);
      return;
    }
    if (p.context == RnsContext.none) {
      final reqBytes = link.decrypt(p);
      final respBytes = await dht?.handleEncoded(reqBytes);
      if (respBytes != null) {
        send(link.encrypt(respBytes, context: RnsContext.none).pack());
      }
    }
  }

  Future<void> _onDhtRpcPacket(_DhtRpcEntry e, RnsPacket p) async {
    if (!e.sent) {
      if (p.packetType == RnsPacketType.proof && p.context == RnsContext.lrproof) {
        final rtt = await e.link.handleProof(p);
        if (rtt == null) {
          if (!e.done.isCompleted) e.done.complete(null);
          return;
        }
        send(rtt.pack());
        send(e.link.encrypt(e.reqBytes, context: RnsContext.none).pack());
        e.sent = true;
      }
      return;
    }
    if (p.context == RnsContext.none && !e.done.isCompleted) {
      e.done.complete(e.link.decrypt(p));
    }
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
