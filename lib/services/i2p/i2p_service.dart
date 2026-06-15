/*
 * I2pService — Aurora-facing singleton that owns the I2P node, which runs in a
 * dedicated background ISOLATE (I2pWorker) so its crypto/network never starves
 * the UI isolate. It serves content out of the shared MediaArchive by sha256
 * (bridged from the worker), keeps a callsign -> I2P destination registry (from
 * the destination beacon), fetches a file by sha256 (from a known peer OR by
 * content-routing discovery across the network), and exposes pause()/resume()
 * for the background-process governor (CPU overload / low battery).
 */
import 'dart:convert';
import 'dart:typed_data';

import '../log_service.dart';
import '../../wapp/geoui/widgets/media_view.dart' show sharedMediaArchive;
import 'i2p_worker.dart';

class I2pService {
  I2pService._() {
    _worker = I2pWorker(
      log: (m) => LogService.instance.add('I2P: $m'),
      onGet: _serve,
    );
  }
  static final I2pService instance = I2pService._();

  late final I2pWorker _worker;
  bool _started = false;
  bool _starting = false;
  bool _paused = false;
  String? _b32;
  final Map<String, Uint8List> _destByCallsign = {};

  bool get isUp => _started && !_paused;
  bool get isStarting => _starting;
  bool get isPaused => _paused;
  String? get b32 => _b32;

  /// Start the node (in its isolate) once (idempotent). Returns true when up.
  Future<bool> ensureStarted() async {
    if (_started) return true;
    if (_starting) return false;
    _starting = true;
    try {
      _b32 = await _worker.start(const I2pWorkerConfig(netId: 2));
      _started = _b32 != null;
      LogService.instance.add(_started
          ? 'I2P: node up (isolate), b32=$_b32'
          : 'I2P: node failed to start');
      if (_started) _pushRoster();
      return _started;
    } catch (e) {
      LogService.instance.add('I2P: start error: $e');
      return false;
    } finally {
      _starting = false;
    }
  }

  /// Suspend the node (governor / low-battery throttle): tears down tunnels and
  /// frees sessions in the worker isolate. Cheap to resume().
  Future<void> pause() async {
    if (!_started || _paused) return;
    _paused = true;
    await _worker.pause();
    LogService.instance.add('I2P: paused (throttled)');
  }

  Future<void> resume() async {
    if (!_started || !_paused) return;
    _paused = false;
    await _worker.resume();
    _pushRoster();
    LogService.instance.add('I2P: resumed');
  }

  /// Serve a sha256 (32 bytes) request from the shared MediaArchive (runs on the
  /// main isolate; bridged from the worker).
  Future<Uint8List?> _serve(Uint8List sha256) async {
    final archive = sharedMediaArchive();
    if (archive == null) return null;
    return archive.get(_b64u(sha256));
  }

  void _pushRoster() {
    if (_destByCallsign.isNotEmpty) {
      _worker.setRoster(_destByCallsign.values.toList());
    }
  }

  /// Record a callsign -> destination-hash mapping (from an incoming beacon).
  void registerDestination(String callsign, Uint8List destHash) {
    if (destHash.length != 32) return;
    _destByCallsign[callsign.toUpperCase()] = destHash;
    if (_started && !_paused) _pushRoster();
  }

  /// Register from a base32 b32 address ("<52chars>.b32.i2p").
  void registerB32(String callsign, String b32) {
    final h = decodeB32(b32);
    if (h != null) registerDestination(callsign, h);
  }

  Uint8List? destinationFor(String callsign) =>
      _destByCallsign[callsign.toUpperCase()];

  /// Fetch [sha256] from [callsign]'s destination and archive it under [ext].
  /// Small files come back in one datagram; larger ones (> ~64 KiB) fall back to
  /// the swarm, seeded with this peer plus any other devices that have it.
  Future<bool> fetchFrom(String callsign, Uint8List sha256, String ext) async {
    final dest = destinationFor(callsign);
    if (!isUp || dest == null) return false;
    final direct = await _worker.fetch(dest, sha256);
    if (direct != null && direct.isNotEmpty) {
      return _store(direct, sha256, ext, callsign);
    }
    return _store(
        await _worker.swarmFetch(sha256, seed: [dest]), sha256, ext, callsign);
  }

  /// Fetch [sha256] directly from a b32 destination and archive it under [ext].
  /// Small files arrive in one datagram; larger ones (> ~64 KiB) fall back to the
  /// swarm seeded with this destination.
  Future<bool> fetchByB32(String b32, Uint8List sha256, String ext) async {
    final dest = decodeB32(b32);
    if (!isUp || dest == null) return false;
    final direct = await _worker.fetch(dest, sha256);
    if (direct != null && direct.isNotEmpty) {
      return _store(direct, sha256, ext, b32);
    }
    return _store(await _worker.swarmFetch(sha256, seed: [dest]), sha256, ext, b32);
  }

  /// Discover any device(s) providing [sha256] across the network (no prior
  /// knowledge of who holds it) and collectively download it piece-by-piece from
  /// however many have it, archiving the verified bytes under [ext].
  Future<bool> discover(Uint8List sha256, String ext) async {
    if (!isUp) return false;
    return _store(await _worker.swarmFetch(sha256), sha256, ext, 'swarm');
  }

  /// Announce that we provide [sha256] so other devices can find it by hash.
  Future<void> announce(Uint8List sha256) async {
    if (isUp) await _worker.announce(sha256);
  }

  bool _store(Uint8List? bytes, Uint8List sha256, String ext, String from) {
    if (bytes == null || bytes.isEmpty) return false;
    sharedMediaArchive()?.putBytes(bytes, ext);
    LogService.instance
        .add('I2P: fetched ${_b64u(sha256)} from $from (${bytes.length}b)');
    return true;
  }

  void stop() {
    _worker.stop();
    _started = false;
    _b32 = null;
  }

  static String _b64u(Uint8List b) =>
      base64Url.encode(b).replaceAll('=', '');

  /// Decode a "<52 base32 chars>.b32.i2p" address to the 32-byte dest hash.
  static Uint8List? decodeB32(String addr) {
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
    if (out.length < 32) return null;
    return Uint8List.fromList(out.sublist(0, 32));
  }
}
