// WifiDirectCoordinator — the brain that turns "a bulk transfer wants a
// BLE-adjacent peer" into a WiFi-Direct group, negotiated entirely over BLE.
//
// BLE (Ble5Bus subtype 0x57) carries a tiny handshake; the actual data plane is
// the RNS interfaces RnsService attaches over the P2P link (see
// enableWfdServer/attachWfdClient). Everything here is host-generic — no wapp
// logic — so any wapp's Reticulum traffic (file swarm, folders, LXMF) rides the
// fast link automatically.
//
// Negotiation (0x57, [ver=1][type] + body; addressed frames carry a cleartext
// 16-byte toHash filter + an RnsIdentity-encrypted inner blob; a nonce echo
// pairs REQ↔OFFER and kills replays):
//   WFD_ADVERT  flags(standing|accepting), identityHash16, clientCount
//   WFD_REQ     toHash16 + enc(fromHash16, nonce8, cond(powered))
//   WFD_OFFER   toHash16 + enc(fromHash16, nonce8 echo, port2, ssid, psk)
//   WFD_NACK    toHash16 + enc(fromHash16, nonce8, reason)
//
// Role election when neither side hosts a group: powered beats battery; tie →
// higher identityHash16 becomes group owner.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:battery_plus/battery_plus.dart';

import '../../connections/bluetooth/ble5_bus.dart';
import '../../connections/wifi_direct/wifi_direct_service.dart';
import '../log_service.dart';
import '../reticulum/rns_service.dart';

const int kWfdRnsPortDefault = 4965;

class _WfdType {
  static const advert = 0x01;
  static const req = 0x02;
  static const offer = 0x03;
  static const nack = 0x04;
}

class _Pending {
  final Uint8List destHash16;
  final int nonce;
  final Completer<bool> done = Completer<bool>();
  Timer? timeout;
  _Pending(this.destHash16, this.nonce);
}

class WifiDirectCoordinator {
  WifiDirectCoordinator._();
  static final WifiDirectCoordinator instance = WifiDirectCoordinator._();

  final WifiDirectService _wfd = WifiDirectService.instance;
  final Battery _battery = Battery();

  bool _started = false;
  bool enabled = true; // user setting (persisted by the caller)
  int port = kWfdRnsPortDefault;

  bool _powered = false;
  bool _groupUp = false; // we host or joined a group
  bool _isGo = false;
  int _clientCount = 0;
  int _lastTrafficMs = 0;
  int _nonceCounter = 1;

  // In-flight negotiations keyed by the peer's identity-hash hex.
  final Map<String, _Pending> _pending = {};
  // Per-peer cooldown after a failed negotiation (hex → epoch ms until).
  final Map<String, int> _cooldownUntil = {};
  // Peers currently advertising a joinable group (hex → {ssid?, accepting}).
  final Map<String, int> _peerAdvertMs = {};

  Timer? _idleTimer;
  StreamSubscription? _wfdEvents;

  static const int _idleTeardownMs = 60 * 1000;
  static const int _cooldownMs = 5 * 60 * 1000;
  static const int _maxClients = 4;

  int get _now => DateTime.now().millisecondsSinceEpoch;
  bool get groupUp => _groupUp;
  bool get powered => _powered;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    if (!await _wfd.supported()) {
      LogService.instance.add('WFD: unsupported on this device');
      return;
    }
    Ble5Bus.instance.onFrame(Ble5Subtype.wfd, _onFrame);
    _wfdEvents = _wfd.events.listen(_onWfdEvent);
    // Charging state drives standing-group policy (Phase 4) + role election.
    try {
      _powered = (await _battery.batteryState) != BatteryState.discharging;
      _battery.onBatteryStateChanged
          .listen((s) => _powered = s != BatteryState.discharging);
    } catch (_) {
      _powered = true; // desktop / no battery API
    }
    LogService.instance.add('WFD: coordinator started (powered=$_powered)');
  }

  void noteTraffic() => _lastTrafficMs = _now;

  void _onWfdEvent(WfdEvent e) {
    if (e.event == 'connection') {
      if (!e.connected) {
        _groupUp = false;
        _isGo = false;
      }
    } else if (e.event == 'group') {
      _clientCount = (e.data['clientCount'] as int?) ?? _clientCount;
    } else if (e.event == 'p2pState' && e.data['enabled'] == false) {
      // WiFi/airplane off — drop everything.
      // ignore: discarded_futures
      _teardown();
    }
  }

  /// THE trigger. Ensure a rank-4 (WiFi-Direct) path to [destHex] is up, forming
  /// or joining a group via BLE negotiation if needed. Returns true if a fast
  /// path is now available; false → caller proceeds on the existing path.
  Future<bool> ensureFastPath(String destHex,
      {Duration wait = const Duration(seconds: 90), bool force = false}) async {
    if (!enabled || !_started) return false;
    final rns = RnsService.instance;
    // Only worth negotiating when the peer's best path is BLE-only (a bulk
    // transfer would otherwise crawl). [force] bypasses this for bench testing
    // where both devices share a WiFi LAN and the path is already 'lan'.
    if (!force && !rns.isBlePath(destHex)) return _groupUp;
    final peer = rns.identityHash16 == null ? null : _destPeerHash16(destHex);
    if (peer == null) return false; // unknown identity → can't address the peer
    final peerHex = _hex(peer);
    if ((_cooldownUntil[peerHex] ?? 0) > _now) return false;

    // Already have a group? Just make sure the peer is on it (send an OFFER if
    // we host, or REQ if it hosts). If we're a client and the peer is the GO,
    // it should already be reachable.
    noteTraffic();
    final ok = await _negotiate(peer).timeout(wait, onTimeout: () => false);
    if (!ok) {
      _cooldownUntil[peerHex] = _now + _cooldownMs;
      return false;
    }
    // Give RNS a moment to hear the peer's announce over wfd and upgrade the
    // path (the server re-announces on connect).
    for (var i = 0; i < 16; i++) {
      if (!rns.isBlePath(destHex)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return !rns.isBlePath(destHex);
  }

  // The peer identity-hash for a dest we route to (the dest hash's owner).
  Uint8List? _destPeerHash16(String destHex) {
    // The dest hash is not the identity hash; resolve via the known peer set.
    return RnsService.instance.identityHash16ForDest(destHex);
  }

  Future<bool> _negotiate(Uint8List peerHash16) async {
    final peerHex = _hex(peerHash16);
    // Is the peer advertising a joinable group right now? Then REQ its creds.
    // Otherwise elect a role. Either way we drive to: one side hosts, the other
    // joins, and both attach RNS over the link.
    final pend = _Pending(peerHash16, _nonceCounter++);
    _pending[peerHex] = pend;
    // BLE is slow — advert TTL ~12s and the peer's scan can batch for tens of
    // seconds each way, so a full REQ→OFFER→join round-trip is ~30-70s.
    pend.timeout = Timer(const Duration(seconds: 80), () {
      if (!pend.done.isCompleted) pend.done.complete(false);
    });

    final iHost = await _shouldHost(peerHash16);
    if (iHost) {
      // Host a group (reuse if present) and OFFER creds to the peer.
      final creds = await _wfd.ensureGroup();
      if (creds == null) {
        _finish(peerHex, false);
        return pend.done.future;
      }
      _groupUp = true;
      _isGo = true;
      await RnsService.instance.enableWfdServer(port);
      _armIdleTeardown();
      await _sendOffer(peerHash16, pend.nonce, creds.ssid, creds.psk);
    } else {
      // Ask the peer to host + send us creds (WFD_OFFER answers our REQ).
      await _sendReq(peerHash16, pend.nonce);
    }
    return pend.done.future;
  }

  // Powered beats battery; tie → higher identity hash hosts. We only know the
  // peer's powered bit from its REQ, so at election time use our own powered
  // state vs the assumption the peer mirrors us; the deterministic tiebreak
  // (hash compare) guarantees exactly one host even without that.
  Future<bool> _shouldHost(Uint8List peerHash16) async {
    final me = RnsService.instance.identityHash16;
    if (me == null) return false;
    // Higher hash hosts (deterministic, symmetric on both devices).
    return _compare(me, peerHash16) > 0;
  }

  // ── frame TX ──
  Future<void> _sendReq(Uint8List peerHash16, int nonce) async {
    final inner = (BytesBuilder()
          ..add(RnsService.instance.identityHash16!)
          ..add(_u64(nonce))
          ..addByte(_powered ? 1 : 0))
        .toBytes();
    await _sendAddressed(_WfdType.req, peerHash16, inner);
  }

  Future<void> _sendOffer(
      Uint8List peerHash16, int nonce, String ssid, String psk) async {
    final ss = utf8.encode(ssid), pk = utf8.encode(psk);
    final inner = (BytesBuilder()
          ..add(RnsService.instance.identityHash16!)
          ..add(_u64(nonce))
          ..add(_u16(port))
          ..addByte(ss.length)
          ..add(ss)
          ..addByte(pk.length)
          ..add(pk))
        .toBytes();
    await _sendAddressed(_WfdType.offer, peerHash16, inner);
  }

  Future<void> _sendNack(Uint8List peerHash16, int nonce, int reason) async {
    final inner = (BytesBuilder()
          ..add(RnsService.instance.identityHash16!)
          ..add(_u64(nonce))
          ..addByte(reason))
        .toBytes();
    await _sendAddressed(_WfdType.nack, peerHash16, inner);
  }

  Future<void> _sendAddressed(
      int type, Uint8List toHash16, Uint8List inner) async {
    final enc = await RnsService.instance.encryptToIdentityHash(toHash16, inner);
    if (enc == null) return; // unknown peer key → can't address privately
    final frame = (BytesBuilder()
          ..addByte(0x01) // ver
          ..addByte(type)
          ..add(toHash16)
          ..add(enc))
        .toBytes();
    // TTL ~12s; keyed per (type,peer) so a new frame supersedes.
    await Ble5Bus.instance.advertiseFrame(
        'wfd:$type:${_hex(toHash16)}', Ble5Subtype.wfd, frame,
        ttl: const Duration(seconds: 12));
  }

  // ── frame RX ──
  Future<void> _onFrame(Ble5Frame f) async {
    final d = f.data;
    if (d.length < 2 || d[0] != 0x01) return;
    final type = d[1];
    if (type == _WfdType.advert) {
      _onAdvert(d);
      return;
    }
    // Addressed: [ver][type][toHash16][encrypted inner].
    if (d.length < 2 + 16) return;
    final toHash = d.sublist(2, 18);
    final me = RnsService.instance.identityHash16;
    if (me == null || !_eq(toHash, me)) return; // not for us
    final token = d.sublist(18);
    final inner = await RnsService.instance.decryptForSelf(token);
    if (inner == null) return;
    switch (type) {
      case _WfdType.req:
        await _onReq(inner);
        break;
      case _WfdType.offer:
        await _onOffer(inner);
        break;
      case _WfdType.nack:
        _onNack(inner);
        break;
    }
  }

  void _onAdvert(Uint8List d) {
    // [ver][type][flags][identityHash16][clientCount]
    if (d.length < 2 + 1 + 16 + 1) return;
    final id = d.sublist(3, 19);
    _peerAdvertMs[_hex(id)] = _now;
  }

  // Peer asks us to host + share creds.
  Future<void> _onReq(Uint8List inner) async {
    if (inner.length < 16 + 8 + 1) return;
    final from = inner.sublist(0, 16);
    final nonce = _readU64(inner, 16);
    if (_isGo && _clientCount >= _maxClients) {
      await _sendNack(from, nonce, 1); // busy
      return;
    }
    final creds = await _wfd.ensureGroup();
    if (creds == null) {
      await _sendNack(from, nonce, 3); // failed
      return;
    }
    _groupUp = true;
    _isGo = true;
    await RnsService.instance.enableWfdServer(port);
    _armIdleTeardown();
    noteTraffic();
    await _sendOffer(from, nonce, creds.ssid, creds.psk);
  }

  // Peer offers us its group creds → join + attach RNS client.
  Future<void> _onOffer(Uint8List inner) async {
    var o = 0;
    if (inner.length < 16 + 8 + 2 + 1) return;
    final from = inner.sublist(0, 16);
    o = 16;
    final nonce = _readU64(inner, o);
    o += 8;
    final p = inner[o] | (inner[o + 1] << 8);
    o += 2;
    final ssidLen = inner[o++];
    if (o + ssidLen > inner.length) return;
    final ssid = utf8.decode(inner.sublist(o, o + ssidLen));
    o += ssidLen;
    if (o >= inner.length) return;
    final pskLen = inner[o++];
    if (o + pskLen > inner.length) return;
    final psk = utf8.decode(inner.sublist(o, o + pskLen));

    final ok = await _wfd.connectToGroup(ssid, psk);
    if (!ok) {
      _finishByNonce(nonce, false);
      return;
    }
    final goIp = await _wfd.awaitConnected();
    if (goIp == null) {
      _finishByNonce(nonce, false);
      return;
    }
    _groupUp = true;
    _isGo = false;
    noteTraffic();
    final rns = await RnsService.instance.attachWfdClient(goIp, p);
    _armIdleTeardown();
    _finishByNonce(nonce, rns);
    _finish(_hex(from), rns);
  }

  void _onNack(Uint8List inner) {
    if (inner.length < 16 + 8 + 1) return;
    final nonce = _readU64(inner, 16);
    _finishByNonce(nonce, false);
  }

  void _finish(String peerHex, bool ok) {
    final pend = _pending.remove(peerHex);
    pend?.timeout?.cancel();
    if (pend != null && !pend.done.isCompleted) pend.done.complete(ok);
  }

  void _finishByNonce(int nonce, bool ok) {
    for (final e in _pending.entries.toList()) {
      if (e.value.nonce == nonce) {
        e.value.timeout?.cancel();
        if (!e.value.done.isCompleted) e.value.done.complete(ok);
        _pending.remove(e.key);
        return;
      }
    }
  }

  // ── lifecycle ──
  void _armIdleTeardown() {
    _idleTimer?.cancel();
    _idleTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      // Standing group while charging stays up; otherwise tear down on idle.
      if (_powered) return;
      if (_now - _lastTrafficMs > _idleTeardownMs) {
        // ignore: discarded_futures
        _teardown();
      }
    });
  }

  Future<void> _teardown() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (!_groupUp) return;
    _groupUp = false;
    _isGo = false;
    await RnsService.instance.detachWfd();
    await _wfd.removeGroup();
    LogService.instance.add('WFD: group torn down (idle)');
  }

  // ── helpers ──
  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static int _compare(Uint8List a, Uint8List b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }

  static Uint8List _u16(int v) => Uint8List.fromList([v & 0xFF, (v >> 8) & 0xFF]);
  static Uint8List _u64(int v) {
    final b = Uint8List(8);
    for (var i = 0; i < 8; i++) {
      b[i] = (v >> (8 * i)) & 0xFF;
    }
    return b;
  }

  static int _readU64(Uint8List d, int o) {
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v |= d[o + i] << (8 * i);
    }
    return v;
  }
}
