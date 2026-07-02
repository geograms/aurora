import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'dart:io'
    if (dart.library.html) '../platform/io_stub.dart'
    show Directory, File, FileMode, Platform, Process, Socket, RawSynchronousSocket,
        HttpClient;

import 'package:wasm_run/wasm_run.dart';

import 'i18n_context.dart';
import '../profile/profile_storage.dart';
import '../connections/hal/connection_hal_imports.dart';
import '../connections/internet/http_transport.dart';
import '../connections/bluetooth/ble_service.dart';
import '../services/location_service.dart';
import '../profile/profile_service.dart';
import 'wapp_event_broker.dart';
import '../profile/storage_paths.dart';
import '../services/android_permissions_service.dart';
import '../services/blossom_server.dart';
import '../services/preferences_service.dart';
import '../services/reticulum/rns_service.dart';
import '../services/log_service.dart';
import '../services/mesh/mesh_service.dart';
import '../services/torrent_service.dart';
import '../util/media_archive.dart';
import '../util/media_ref.dart';
import '../util/nostr_nip19.dart';
import '../util/nostr_crypto.dart';
import '../util/aprx_sign.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:hex/hex.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:pointycastle/export.dart' as pc;

/// State for a single hal_process_exec subprocess. Lives in
/// [WappEngine._procs] keyed by handle. The wapp polls hal_process_poll
/// until [exitCode] is set, drains stdout/stderr at any time, then calls
/// hal_process_free to release the entry.
class _WappProcState {
  Process? proc;
  int? exitCode;
  final List<int> stdoutBuf = <int>[];
  final List<int> stderrBuf = <int>[];
  StreamSubscription<List<int>>? stdoutSub;
  StreamSubscription<List<int>>? stderrSub;
}

/// State for a single hal_file_* handle. Lives in [WappEngine._files]
/// keyed by handle. Reads slurp the whole file at open and serve from
/// the buffer; writes accumulate and flush at close. Fine for the
/// source-code-sized files wapps actually use.
class _WappFileState {
  _WappFileState({required this.path, required this.mode});
  final String path;
  final int mode; // 0 = read, 1 = write (truncate), 2 = append
  Uint8List? readBuf;
  int readOffset = 0;
  final List<int> writeBuf = <int>[];
}

/// One real TCP connection shared by every wapp engine that opens the same
/// (host, port) — there is exactly ONE connection to APRS-IS per server for the
/// whole app, instead of one per engine (foreground page + background service),
/// which used to produce duplicate/triplicate logins for the same callsign and
/// a kick-war on APRS-IS (the server drops duplicate logins). Inbound bytes are
/// fanned out to every [view]'s rxBuf; the duplicate APRS-IS login line is
/// suppressed (only the first is sent). Shared statically across engines.
class _SharedSocket {
  _SharedSocket(this.key);
  final String key; // "host:port"
  Socket? socket;
  int state = 0; // 0 connecting, 1 up, 2 closed/error
  bool loginSent = false; // first "user ..." login forwarded; later ones dropped
  StreamSubscription<List<int>>? sub;
  final List<_WappSocketState> views = <_WappSocketState>[];
  void fanOut(List<int> data) {
    for (final v in views) {
      v.rxBuf.addAll(data);
    }
  }
}

/// State for a single hal_socket_* handle. Lives in [WappEngine._sockets]
/// keyed by handle. Each handle is a VIEW onto a [_SharedSocket]: it has its own
/// [rxBuf] (so two engines each drain their own copy of the inbound stream),
/// while [shared] holds the one real TCP socket. [state] for a view mirrors
/// [shared.state].
class _WappSocketState {
  _SharedSocket? shared;
  final List<int> rxBuf = <int>[];
  int get state => shared?.state ?? 2;
}

/// State for a single hal_http_* request. Lives in [WappEngine._https]
/// keyed by handle. The request runs asynchronously via [HttpTransport];
/// [done] flips true on completion (success or failure). The wapp polls
/// hal_http_poll until done, checks hal_http_status, then drains the body
/// with hal_http_read_response (which advances [readOffset]) and frees.
class _WappHttpState {
  bool done = false;
  bool failed = false; // transport-level failure (no HTTP response at all)
  int status = -1; // HTTP status code once [done] && !failed
  Uint8List body = Uint8List(0);
  int readOffset = 0;
}

/// State for a single hal_http_stream_* handle (online radio). A streamed GET
/// keeps audio bytes flowing into [rxBuf] over time; the wapp drains them and
/// decodes incrementally. ICY (SHOUTcast) metadata is requested and stripped
/// out here so the wapp only sees pure audio; the latest StreamTitle is exposed
/// via [title]. [state]: 0 = connecting, 1 = open, 2 = closed/error.
class _WappStreamState {
  StreamSubscription<List<int>>? sub;
  final List<int> rxBuf = <int>[];
  int state = 0;
  // ICY metadata de-interleaving.
  int icyMetaInt = 0; // 0 = no metadata interleaved
  int sinceMeta = 0; // audio bytes since the last metadata block
  bool readingMetaLen = false; // next byte is a metadata length (×16)
  int metaLeft = 0; // metadata bytes still to read
  final List<int> metaAcc = <int>[];
  String title = '';
  static const int _maxBuf = 4 * 1024 * 1024; // bound memory if the wapp stalls

  void ingest(List<int> data) {
    for (final b in data) {
      if (icyMetaInt == 0) { rxBuf.add(b); continue; }
      if (readingMetaLen) { metaLeft = b * 16; readingMetaLen = false; continue; }
      if (metaLeft > 0) {
        metaAcc.add(b);
        if (--metaLeft == 0) { _parseTitle(); metaAcc.clear(); }
        continue;
      }
      rxBuf.add(b);
      if (++sinceMeta >= icyMetaInt) { sinceMeta = 0; readingMetaLen = true; }
    }
    if (rxBuf.length > _maxBuf) rxBuf.removeRange(0, rxBuf.length - _maxBuf);
  }

  void _parseTitle() {
    // metaAcc looks like: StreamTitle='Artist - Song';StreamUrl='...';
    final s = String.fromCharCodes(metaAcc);
    const key = "StreamTitle='";
    final i = s.indexOf(key);
    if (i < 0) return;
    final j = s.indexOf("'", i + key.length);
    if (j < 0) return;
    title = s.substring(i + key.length, j);
  }
}

/// State for a single hal_sqlite_* handle. Lives in [WappEngine._sqlite] keyed
/// by handle. Wraps one open [Database] (a file under the wapp's private data
/// dir) and the last error string for hal_sqlite_error.
class _WappSqliteState {
  _WappSqliteState(this.db);
  final Database db;
  String? lastError;
}

/// Log entry from a WASM module.
class WappLogEntry {
  final int level; // 0=debug, 1=info, 2=warn, 3=error
  final String message;
  final DateTime timestamp;

  WappLogEntry(this.level, this.message) : timestamp = DateTime.now();

  String get levelName => const ['DEBUG', 'INFO', 'WARN', 'ERROR'][level.clamp(0, 3)];
}

/// Lightweight WASM engine that loads a module and provides the full Geogram HAL.
class WappEngine {
  static int _nextEngineId = 0;

  /// Lookup table of every live engine, keyed by [engineId]. Used by
  /// [WidgetBroker] to find a caller engine and inject a
  /// widget.response message without needing a widget tree reference.
  static final Map<String, WappEngine> _byId = {};

  /// Find a live engine by id, or null if none is registered. Called
  /// by the widget broker on the response delivery path.
  static WappEngine? lookup(String engineId) => _byId[engineId];

  /// Stable identifier for this engine instance, used by
  /// [WappEventBroker] for routing cross-wapp pub/sub and by
  /// [WidgetBroker] for delivering widget.response messages.
  final String engineId = 'engine-${_nextEngineId++}';

  WasmInstance? _instance;
  WasmMemory? _memory;
  final List<WappLogEntry> logs = [];

  /// token → shareable magnet link, filled asynchronously by hal_media_magnet
  /// so a later synchronous call can return it.
  static final Map<String, String> _magnetCache = {};

  /// token → deterministic torrent infohash (40-hex), filled asynchronously by
  /// hal_media_infohash so a later synchronous call can return it.
  static final Map<String, String> _infohashCache = {};
  final List<String> _inbox = [];
  final List<String> _outbox = [];
  final _stopwatch = Stopwatch();
  final _random = Random.secure();
  final Map<String, Uint8List> _kv = {};
  ProfileStorage? _storage;
  bool _loaded = false;

  // ── Codec-free A/V sink callbacks ──────────────────────────────────
  // A media wapp decodes video IN wasm and pushes raw frames/PCM out
  // through the hal_video_*/hal_audio_pcm imports below. The host holds
  // NO codec; it only forwards what the wapp hands it to whatever render
  // session is attached (wired by the owning WappPage). Null => drop.
  void Function(int width, int height, int pixfmt)? onVideoConfig;
  void Function(Uint8List rgba, int width, int height, int pixfmt, int ptsMs)?
      onVideoFrame;
  void Function(
          Uint8List pcm, int sampleRate, int channels, int sampfmt, int ptsMs)?
      onAudioPcm;
  void Function()? onVideoEnd;

  // hal_process_* state. Handles are positive ints; 0 is reserved so
  // callers can use 0 as an "absent" sentinel.
  final Map<int, _WappProcState> _procs = {};
  int _nextProcHandle = 1;

  // hal_file_* state. Same handle convention as _procs.
  final Map<int, _WappFileState> _files = {};
  int _nextFileHandle = 1;

  // hal_socket_* state. Same handle convention as _procs.
  final Map<int, _WappSocketState> _sockets = {};
  int _nextSocketHandle = 1;
  // One real TCP per (host, port) shared across ALL engines (foreground page +
  // background service), so APRS-IS sees a single connection/login per server.
  static final Map<String, _SharedSocket> _sharedSockets = {};

  // hal_http_* state. Same handle convention as _procs. Backed by the
  // host's one HttpTransport so the Wapp Store can fetch its catalog
  // index.json from a remote repo (raw.githubusercontent.com/...).
  final Map<int, _WappHttpState> _https = {};
  int _nextHttpHandle = 1;
  final Map<int, _WappStreamState> _streams = {};
  int _nextStreamHandle = 1;

  // hal_sqlite_* state. Per-wapp databases live under the wapp's private data
  // dir; handles are disposed on teardown.
  final Map<int, _WappSqliteState> _sqlite = {};
  int _nextSqliteHandle = 1;

  // This wapp's id (folder name), used as the tag for the per-wapp RNS datagram
  // channel so hal_rns_* traffic demultiplexes between wapps. Set via setAppId.
  String? _appId;
  // Local staging buffer for inbound RNS datagrams (JSON envelopes), drained from
  // RnsService one datagram at a time to give hal_rns_available/recv semantics.
  final List<String> _rnsRx = [];
  // Staging buffer for NOSTR-relay DMs fetched by hal_relay_dm_fetch (async),
  // drained one JSON entry at a time by hal_relay_dm_recv.
  final List<String> _relayDmRx = [];

  // Staging buffer for callsign→npub resolutions from hal_relay_resolve (async),
  // drained one JSON entry at a time by hal_relay_resolve_recv.
  final List<String> _relayResolveRx = [];

  // hal_socket_*_sync state — blocking sockets for synchronous test code
  // (the wasm test runner can't await async I/O). Keyed by handle.
  final Map<int, RawSynchronousSocket> _syncSockets = {};
  int _nextSyncSocketHandle = 1;

  // hal_ble_* state — this engine's view of the SHARED BleService. Inbound
  // frames are buffered per-engine (each as JSON bytes) so every wapp receives
  // every frame; advertising is multiplexed by the shared service keyed on
  // this engine instance.
  final List<List<int>> _bleRx = [];
  StreamSubscription<BleInboundFrame>? _bleSub;
  bool _bleScanning = false;

  /// Translation tables handed over by [WappPage._reloadI18n]. Used
  /// by the `hal_i18n_get` import to resolve `@key` / bare-key lookups
  /// from the wapp's C code. An empty context (the default) means
  /// `hal_i18n_get` always returns 0 — the wapp's fallback literal
  /// takes over. See i18n_context.dart for the resolution rules.
  I18nContext _i18n = I18nContext.empty();

  /// Attach or replace the translation tables. Called once on wapp
  /// load and again on every [LocaleChangedEvent].
  void setI18n(I18nContext context) {
    _i18n = context;
  }

  WappEngine() {
    _byId[engineId] = this;
    WappEventBroker.instance.registerEngine(engineId);
  }

  bool get isLoaded => _loaded;
  List<String> get outbox => List.unmodifiable(_outbox);

  /// Attach a [ProfileStorage] for persistent KV. Call before [load].
  /// The storage must support sync variants (FilesystemProfileStorage is
  /// fine); the WASM KV callbacks run synchronously and cannot await.
  void setStorage(ProfileStorage storage) {
    _storage = storage;
    _loadKv();
  }

  /// Identify this wapp (its folder id) before [load]. Used as the tag for the
  /// per-wapp RNS datagram channel (hal_rns_*) so two devices running the same
  /// wapp see each other's datagrams and other wapps don't.
  void setAppId(String id) {
    _appId = id;
    RnsService.instance.wappRegister(id);
  }

  void _loadKv() {
    final storage = _storage;
    if (storage == null) return;
    final bytes = storage.readBytesSync('kv.json');
    if (bytes == null) return;
    try {
      final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      for (final e in data.entries) {
        _kv[e.key] = Uint8List.fromList((e.value as String).codeUnits);
      }
    } catch (_) {}
  }

  void _saveKv() {
    final storage = _storage;
    if (storage == null) return;
    final data = <String, String>{};
    for (final e in _kv.entries) {
      data[e.key] = String.fromCharCodes(e.value);
    }
    storage.writeStringSync('kv.json', jsonEncode(data));
  }

  /// Check if a KV key exists (before module is loaded).
  bool hasKvKey(String key) => _kv.containsKey(key);

  /// Read a KV value as a string (before/after the module loads), or null when
  /// the key isn't set. Lets the host restore persisted settings into its field
  /// map so a wapp's saved settings (e.g. the map's my_lat/my_lon) survive a
  /// restart instead of reverting to the declared defaults.
  String? kvGet(String key) {
    final v = _kv[key];
    return v == null ? null : String.fromCharCodes(v);
  }

  /// List all KV keys (for debugging).
  List<String> get kvKeys => _kv.keys.toList();

  /// Set a KV key directly (before module is loaded).
  void kvSet(String key, String value) {
    _kv[key] = Uint8List.fromList(value.codeUnits);
    _saveKv();
  }

  void sendMessage(String msg) => _inbox.add(msg);

  /// Host→wapp messages still queued. `module_handle_event` consumes one per
  /// call, so a caller that needs its message processed must pump [handleEvent]
  /// until this is zero.
  int get inboxLength => _inbox.length;

  List<String> drainOutbox() {
    final out = List<String>.from(_outbox);
    _outbox.clear();
    return out;
  }

  // ── Helpers ──────────────────────────────────────────────────────────

  String _readStr(int ptr, int len) {
    final mem = _memory!.view;
    return String.fromCharCodes(mem.buffer.asUint8List(ptr, len));
  }

  Uint8List _readBytes(int ptr, int len) {
    final mem = _memory!.view;
    return Uint8List.fromList(mem.buffer.asUint8List(ptr, len));
  }

  int _writeStr(int ptr, int maxLen, String s) {
    final bytes = s.codeUnits;
    final n = bytes.length < maxLen ? bytes.length : maxLen;
    final mem = _memory!.view;
    for (var i = 0; i < n; i++) mem[ptr + i] = bytes[i];
    // NUL-terminate so the wapp's strlen-based readers work on uninitialized
    // (stack) buffers — without this, s_len() runs past the data into garbage,
    // corrupting e.g. signatures carried in datagram JSON.
    if (n < maxLen) mem[ptr + n] = 0;
    return n;
  }

  /// The active profile's public key as base64url (no padding) of the raw 32
  /// bytes, decoded from the stored npub. Empty if unavailable.
  String _pubkeyBase64() {
    final npub = ProfileService.instance.activeProfile?.npub ?? '';
    if (npub.isEmpty) return '';
    final hex = NostrNip19.decode(npub)?.hex;
    if (hex == null || hex.length != 64) return '';
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Sign [msg] with the active profile's key (APRX short-Schnorr). Returns the
  /// base85 signature string, or '' if no key. The private key never leaves here.
  String _signMessage(Uint8List msg) {
    final d = _profilePrivScalar();
    if (d == null) return '';
    try {
      final m = Uint8List.fromList(sha256.convert(msg).bytes);
      return AprxSign.b85encode(AprxSign.sign(m, d));
    } catch (_) {
      return '';
    }
  }

  /// Verify a base85 signature [sigStr] on [msg] for [pubB64] (base64url x-only
  /// pubkey, as hal_identity_pubkey emits). Returns true iff valid.
  bool _verifyMessage(String pubB64, Uint8List msg, String sigStr) {
    try {
      final pub = _b64urlDecode(pubB64);
      final sig = AprxSign.b85decode(sigStr);
      if (sig == null || sig.length != 48 || pub == null || pub.length != 32) {
        return false;
      }
      final m = Uint8List.fromList(sha256.convert(msg).bytes);
      return AprxSign.verify(m, sig, pub);
    } catch (_) {
      return false;
    }
  }

  /// The active profile's private key as a scalar, or null if none.
  BigInt? _profilePrivScalar() {
    final nsec = ProfileService.instance.activeProfile?.nsec ?? '';
    if (nsec.isEmpty) return null;
    try {
      var d = BigInt.zero;
      for (final b in HEX.decode(NostrCrypto.decodeNsec(nsec))) {
        d = (d << 8) | BigInt.from(b);
      }
      return d;
    } catch (_) {
      return null;
    }
  }

  /// Decode a base64url string (with or without padding) to bytes, or null.
  Uint8List? _b64urlDecode(String s) {
    try {
      final pad = (4 - s.length % 4) % 4;
      return base64Url.decode(s + ('=' * pad));
    } catch (_) {
      return null;
    }
  }

  int _writeBytes(int ptr, int maxLen, Uint8List bytes) {
    final n = bytes.length < maxLen ? bytes.length : maxLen;
    final mem = _memory!.view;
    for (var i = 0; i < n; i++) mem[ptr + i] = bytes[i];
    return n;
  }

  /// Read a UTF-8 string from wasm memory (correct for non-ASCII text, unlike
  /// the byte-preserving [_readStr]). Used by the sqlite HAL where SQL and bound
  /// values can carry user chat text.
  String _readUtf8(int ptr, int len) =>
      utf8.decode(_readBytes(ptr, len), allowMalformed: true);

  /// Write a UTF-8 string into wasm memory; returns bytes written. Pair with the
  /// wapp utf8-decoding the buffer.
  int _writeUtf8(int ptr, int maxLen, String s) {
    final n = _writeBytes(ptr, maxLen, Uint8List.fromList(utf8.encode(s)));
    if (n < maxLen) _memory!.view[ptr + n] = 0; // NUL-terminate (see _writeStr)
    return n;
  }

  /// Resolve a wapp-supplied sqlite path to an absolute path confined to this
  /// wapp's private data dir. Rejects absolute paths and any '..' segment so a
  /// wapp can't escape its sandbox. Returns null if unresolvable/unsafe.
  String? _wappDbPath(String rel) {
    final s = _storage;
    if (s == null || rel.isEmpty) return null;
    final parts =
        rel.split('/').where((p) => p.isNotEmpty && p != '.').toList();
    if (parts.isEmpty || parts.contains('..')) return null;
    return s.getAbsolutePath(parts.join('/'));
  }

  /// Decode the optional JSON-array bind parameters for a sqlite call.
  List<Object?> _sqliteParams(int ptr, int len) {
    if (len <= 0) return const [];
    try {
      final v = jsonDecode(_readUtf8(ptr, len));
      return v is List ? v : const [];
    } catch (_) {
      return const [];
    }
  }

  /// AES-256-CBC with PKCS7 padding (matches AprxSign's scheme). [iv] is 16 bytes.
  Uint8List _aesCbc(bool encrypt, Uint8List key, Uint8List iv, Uint8List data) {
    final c = pc.PaddedBlockCipherImpl(
        pc.PKCS7Padding(), pc.CBCBlockCipher(pc.AESEngine()));
    c.init(
        encrypt,
        pc.PaddedBlockCipherParameters(
            pc.ParametersWithIV(pc.KeyParameter(key), iv), null));
    return c.process(data);
  }

  // ── Load ─────────────────────────────────────────────────────────────

  Future<void> load(Uint8List wasmBytes) async {
    _stopwatch.start();
    final module = await compileWasmModule(wasmBytes);
    final builder = module.builder();

    // ── System HAL ──

    final halPlatform = WasmFunction(
      (int ptr, int len) => _writeStr(ptr, len, 'flutter-desktop'),
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    // Device identity (the active profile's callsign) — so a wapp uses THIS
    // device's callsign instead of a hardcoded default. Empty if no profile.
    final halIdentity = WasmFunction(
      (int ptr, int len) => _writeStr(
          ptr, len, ProfileService.instance.activeProfile?.callsign ?? ''),
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    // The active profile's Nostr public key as base64url (no padding) of the
    // raw 32 bytes — 43 chars, compact enough for one APRS message / a BLE
    // advert (an npub bech32 string would be 63). A wapp publishes this so
    // peers can map callsign -> pubkey and later send encrypted messages;
    // base64url-decoding it yields the 32-byte key used for NIP-04/44.
    // Empty if no profile or the npub can't be decoded.
    final halIdentityPubkey = WasmFunction(
      (int ptr, int len) => _writeStr(ptr, len, _pubkeyBase64()),
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    // Sign msg with the active profile's key; write the base85 signature string.
    final halIdentitySign = WasmFunction(
      (int msgPtr, int msgLen, int outPtr, int outCap) {
        if (msgLen <= 0 || outCap <= 0) return 0;
        final sig = _signMessage(_readBytes(msgPtr, msgLen));
        if (sig.isEmpty) return 0;
        return _writeStr(outPtr, outCap, sig);
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Encode a base64url x-only pubkey to its npub bech32 string.
    final halNpub = WasmFunction(
      (int inPtr, int inLen, int outPtr, int outCap) {
        if (inLen <= 0 || outCap <= 0) return 0;
        try {
          final b64 = _readStr(inPtr, inLen);
          final pad = (4 - b64.length % 4) % 4;
          final bytes = base64Url.decode(b64 + ('=' * pad));
          if (bytes.length != 32) return 0;
          final npub = NostrCrypto.encodeNpub(HEX.encode(bytes));
          return _writeStr(outPtr, outCap, npub);
        } catch (_) {
          return 0;
        }
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Encrypt msg for a base64url pubkey with the profile key → base64url blob.
    final halEncrypt = WasmFunction(
      (int pubPtr, int pubLen, int msgPtr, int msgLen, int outPtr, int outCap) {
        if (pubLen <= 0 || msgLen <= 0 || outCap <= 0) return 0;
        try {
          final d = _profilePrivScalar();
          final pub = _b64urlDecode(_readStr(pubPtr, pubLen));
          if (d == null || pub == null || pub.length != 32) return 0;
          final blob = AprxSign.encryptFor(d, pub, _readBytes(msgPtr, msgLen));
          if (blob == null) return 0;
          return _writeStr(outPtr, outCap, base64Url.encode(blob).replaceAll('=', ''));
        } catch (_) {
          return 0;
        }
      },
      params: [
        ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32,
        ValueTy.i32
      ],
      results: [ValueTy.i32],
    );
    // Decrypt a base64url blob from a base64url pubkey → plaintext bytes.
    final halDecrypt = WasmFunction(
      (int pubPtr, int pubLen, int blobPtr, int blobLen, int outPtr, int outCap) {
        if (pubLen <= 0 || blobLen <= 0 || outCap <= 0) return 0;
        try {
          final d = _profilePrivScalar();
          final pub = _b64urlDecode(_readStr(pubPtr, pubLen));
          final blob = _b64urlDecode(_readStr(blobPtr, blobLen));
          if (d == null || pub == null || pub.length != 32 || blob == null) return 0;
          final pt = AprxSign.decryptFrom(d, pub, blob);
          if (pt == null) return 0;
          return _writeBytes(outPtr, outCap, pt);
        } catch (_) {
          return 0;
        }
      },
      params: [
        ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32,
        ValueTy.i32
      ],
      results: [ValueTy.i32],
    );
    // ── Media archive + sharing HAL (Files wapp; DESIGN.md §4/§5/§6) ──────
    // The shared content-addressed archive (media.sqlite3) + the Blossom
    // provider endpoint + the BitTorrent seeder live host-side; these calls
    // are the wapp-facing control surface.
    MediaArchive? mediaArchive() {
      final prefs = PreferencesService.instanceSync;
      if (prefs == null) return null;
      return MediaArchive.forDirectory(wappsDataStorage(prefs).getAbsolutePath(''));
    }

    Map<String, dynamic> metaJson(MediaMeta m) => {
          'sha256': m.sha256,
          'token': 'file:${m.sha256}.${m.ext}',
          'name': m.name ?? '',
          'ext': m.ext,
          'description': m.description ?? '',
          'tags': m.tags,
          'size': m.size,
          'first': m.firstSeenMs,
          'last': m.lastSeenMs,
          'shot': m.hasScreenshot,
          'folder': m.folder ?? '',
          'parent': m.parent ?? '',
          'downloads': m.downloads,
          'pinned': m.pinned,
        };

    // List archive metadata (newest first) → JSON array.
    final halMediaList = WasmFunction(
      (int offset, int limit, int outPtr, int outCap) {
        final archive = mediaArchive();
        if (archive == null || outCap <= 0) return 0;
        final metas = archive.list(
            offset: offset < 0 ? 0 : offset,
            limit: limit <= 0 ? 100 : limit);
        return _writeStr(
            outPtr, outCap, jsonEncode([for (final m in metas) metaJson(m)]));
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // One entry's metadata (token / bare hash / hex accepted) → JSON.
    final halMediaMeta = WasmFunction(
      (int hashPtr, int hashLen, int outPtr, int outCap) {
        final archive = mediaArchive();
        if (archive == null || hashLen <= 0 || outCap <= 0) return 0;
        final m = archive.getMeta(_readStr(hashPtr, hashLen));
        if (m == null) return 0;
        return _writeStr(outPtr, outCap, jsonEncode(metaJson(m)));
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Import a host file into the archive → wire token.
    final halMediaPutFile = WasmFunction(
      (int pathPtr, int pathLen, int outPtr, int outCap) {
        final archive = mediaArchive();
        if (archive == null || pathLen <= 0 || outCap <= 0) return 0;
        try {
          final path = _readStr(pathPtr, pathLen);
          final f = File(path);
          if (!f.existsSync()) return 0;
          final dot = path.lastIndexOf('.');
          final slash =
              path.lastIndexOf('/') > path.lastIndexOf('\\')
                  ? path.lastIndexOf('/')
                  : path.lastIndexOf('\\');
          final ext = (dot > slash && dot >= 0)
              ? path.substring(dot + 1).toLowerCase()
              : 'bin';
          final name = path.substring(slash + 1);
          final token = archive.putBytes(
              f.readAsBytesSync(),
              RegExp(r'^[a-z0-9]{1,18}$').hasMatch(ext) ? ext : 'bin',
              name: name);
          return _writeStr(outPtr, outCap, token);
        } catch (_) {
          return 0;
        }
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Update name/description/tags/folder/parent from a JSON object. The host
    // clamps description to 250 chars. 1 = applied.
    final halMediaSetMeta = WasmFunction(
      (int hashPtr, int hashLen, int jsonPtr, int jsonLen) {
        final archive = mediaArchive();
        if (archive == null || hashLen <= 0 || jsonLen <= 0) return 0;
        try {
          final d =
              jsonDecode(_readStr(jsonPtr, jsonLen)) as Map<String, dynamic>;
          archive.updateMeta(
            _readStr(hashPtr, hashLen),
            name: d['name'] as String?,
            description: d['description'] as String?,
            tags: (d['tags'] as List?)?.map((t) => '$t').toList(),
            folder: d['folder'] as String?,
            parent: d['parent'] as String?,
          );
          return 1;
        } catch (_) {
          return 0;
        }
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Search the archive: an exact sha256 (token / 43-char b64u / 64-hex)
    // returns that one entry; anything else is a full-text query over
    // name/description/tags/folder/parent. → JSON array of metas.
    final halMediaSearch = WasmFunction(
      (int qPtr, int qLen, int outPtr, int outCap) {
        final archive = mediaArchive();
        if (archive == null || qLen <= 0 || outCap <= 0) return 0;
        final q = _readStr(qPtr, qLen).trim();
        final looksLikeSha =
            RegExp(r'^(file:)?[A-Za-z0-9_-]{43}(\.[a-z0-9]+)?$').hasMatch(q) ||
                RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(q);
        final List<MediaMeta> metas;
        if (looksLikeSha) {
          final one = archive.lookupBySha(q);
          metas = one == null ? const [] : [one];
        } else {
          metas = archive.search(q, limit: 100);
        }
        return _writeStr(
            outPtr, outCap, jsonEncode([for (final m in metas) metaJson(m)]));
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Virtual-folder tree: JSON array of {parent, folder, count}.
    final halMediaFolders = WasmFunction(
      (int outPtr, int outCap) {
        final archive = mediaArchive();
        if (archive == null || outCap <= 0) return 0;
        return _writeStr(outPtr, outCap,
            jsonEncode([for (final f in archive.folders()) f.toJson()]));
      },
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Files inside one virtual folder. Input JSON {"parent":..,"folder":..}
    // (empty strings = the uncategorized bucket). → JSON array of metas.
    final halMediaListFolder = WasmFunction(
      (int jsonPtr, int jsonLen, int outPtr, int outCap) {
        final archive = mediaArchive();
        if (archive == null || jsonLen <= 0 || outCap <= 0) return 0;
        try {
          final d =
              jsonDecode(_readStr(jsonPtr, jsonLen)) as Map<String, dynamic>;
          final metas = archive.listByFolder(
              (d['parent'] ?? '').toString(), (d['folder'] ?? '').toString());
          return _writeStr(outPtr, outCap,
              jsonEncode([for (final m in metas) metaJson(m)]));
        } catch (_) {
          return 0;
        }
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // ── Mutable folders (IPNS-like) ─────────────────────────────────────────
    // Create a folder: input {"name":..,"desc":..} → folderId hex (or empty).
    final halFolderCreate = WasmFunction(
      (int jsonPtr, int jsonLen, int outPtr, int outCap) {
        if (jsonLen <= 0 || outCap <= 0) return 0;
        try {
          final d =
              jsonDecode(_readStr(jsonPtr, jsonLen)) as Map<String, dynamic>;
          final id = RnsService.instance.folderCreate(
              (d['name'] ?? '').toString(),
              desc: (d['desc'] ?? '').toString());
          return id == null ? 0 : _writeStr(outPtr, outCap, id);
        } catch (_) {
          return 0;
        }
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Owned folders → JSON array of {folderId, npub, name}.
    final halFolderList = WasmFunction(
      (int outPtr, int outCap) {
        if (outCap <= 0) return 0;
        return _writeStr(
            outPtr, outCap, jsonEncode(RnsService.instance.folderList()));
      },
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Apply an edit: folderId + op JSON ({"op":"addFile","x":..} etc). 1=started.
    final halFolderEdit = WasmFunction(
      (int idPtr, int idLen, int jsonPtr, int jsonLen) {
        if (idLen <= 0 || jsonLen <= 0) return 0;
        try {
          final op =
              jsonDecode(_readStr(jsonPtr, jsonLen)) as Map<String, dynamic>;
          RnsService.instance.folderEdit(_readStr(idPtr, idLen), op);
          return 1;
        } catch (_) {
          return 0;
        }
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Browse a folder → cached FolderState JSON (refreshes in the background).
    final halFolderBrowse = WasmFunction(
      (int idPtr, int idLen, int outPtr, int outCap) {
        if (idLen <= 0 || outCap <= 0) return 0;
        // Accept "folderId\tsubpath" to browse just one directory level (only
        // the immediate subfolders + files at that path) — keeps the payload
        // and the wapp's work flat regardless of how big the folder is. A bare
        // id (no tab) returns the full state (back-compat).
        final arg = _readStr(idPtr, idLen);
        final tab = arg.indexOf('\t');
        final Map<String, dynamic> out = tab >= 0
            ? RnsService.instance
                .folderBrowseLevel(arg.substring(0, tab), arg.substring(tab + 1))
            : RnsService.instance.folderBrowse(arg);
        return _writeStr(outPtr, outCap, jsonEncode(out));
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Folder info + serve statistics (times served, over time) for the info
    // panel → JSON {npub, name, fileCount, totalBytes, serves, last24h, ...}.
    final halFolderStats = WasmFunction(
      (int idPtr, int idLen, int outPtr, int outCap) {
        if (idLen <= 0 || outCap <= 0) return 0;
        return _writeStr(outPtr, outCap,
            jsonEncode(RnsService.instance.folderStats(_readStr(idPtr, idLen))));
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Stop sharing an owned disk folder (files on disk are left untouched).
    final halFolderRemove = WasmFunction(
      (int idPtr, int idLen) {
        if (idLen <= 0) return 0;
        RnsService.instance.folderRemove(_readStr(idPtr, idLen));
        return 1;
      },
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Open an owned disk folder's directory in the OS file manager (edit on disk).
    final halFolderOpenDir = WasmFunction(
      (int idPtr, int idLen) {
        if (idLen <= 0) return 0;
        return RnsService.instance.folderOpenDir(_readStr(idPtr, idLen)) ? 1 : 0;
      },
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // ── Disk-backed owner folders + consumer downloads ──────────────────────
    // Register an on-disk directory as an owned folder (async). 1 = started;
    // poll hal_folder_owned for the resulting folderId.
    final halFolderAddDisk = WasmFunction(
      (int pPtr, int pLen) {
        if (pLen <= 0) return 0;
        if (!RnsService.instance.foldersReady) return 0; // node not running
        // ignore: discarded_futures
        RnsService.instance.folderAddFromDisk(_readStr(pPtr, pLen));
        return 1;
      },
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Re-scan owned disk folders (one if id given, else all). 1 = started.
    final halFolderRescan = WasmFunction(
      (int idPtr, int idLen) {
        // ignore: discarded_futures
        RnsService.instance.folderRescan(idLen > 0 ? _readStr(idPtr, idLen) : null);
        return 1;
      },
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Download from a folder: json {"sha":..,"name":..} or {"all":true}. 1=started.
    final halFolderDownload = WasmFunction(
      (int idPtr, int idLen, int jsonPtr, int jsonLen) {
        if (idLen <= 0 || jsonLen <= 0) return 0;
        try {
          final fid = _readStr(idPtr, idLen);
          final d = jsonDecode(_readStr(jsonPtr, jsonLen)) as Map<String, dynamic>;
          if (d['all'] == true) {
            // ignore: discarded_futures
            RnsService.instance.folderDownloadAll(fid);
          } else {
            final sha = '${d['sha'] ?? ''}';
            if (sha.isEmpty) return 0;
            // ignore: discarded_futures
            RnsService.instance.folderDownloadFile(fid, sha, '${d['name'] ?? sha}');
          }
          return 1;
        } catch (_) {
          return 0;
        }
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Toggle auto-sync for a folder (on != 0).
    final halFolderAutosync = WasmFunction(
      (int idPtr, int idLen, int on) {
        if (idLen <= 0) return 0;
        RnsService.instance.setFolderAutoSync(_readStr(idPtr, idLen), on != 0);
        return 1;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Owned disk folders → JSON [{folderId, dir, files}].
    final halFolderOwned = WasmFunction(
      (int outPtr, int outCap) {
        if (outCap <= 0) return 0;
        return _writeStr(
            outPtr, outCap, jsonEncode(RnsService.instance.ownedDiskFolders()));
      },
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Folder subscriptions → JSON [{folderId, autoSync, downloaded}].
    final halFolderSubs = WasmFunction(
      (int outPtr, int outCap) {
        if (outCap <= 0) return 0;
        return _writeStr(outPtr, outCap,
            jsonEncode(RnsService.instance.folderSubscriptions()));
      },
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // List a real directory (for the in-app folder browser): JSON
    // [{"name","path","dir"}], directories first. Subject to OS file access.
    final halFsListdir = WasmFunction(
      (int pPtr, int pLen, int outPtr, int outCap) {
        if (pLen <= 0 || outCap <= 0) return 0;
        try {
          final dir = Directory(_readStr(pPtr, pLen));
          if (!dir.existsSync()) return 0;
          final items = <Map<String, dynamic>>[];
          for (final e in dir.listSync(followLinks: false)) {
            items.add({
              'name': e.path.split(Platform.pathSeparator).last,
              'path': e.path,
              'dir': e is Directory,
            });
          }
          items.sort((a, b) {
            final d = (b['dir'] == true ? 1 : 0) - (a['dir'] == true ? 1 : 0);
            return d != 0 ? d : (a['name'] as String).compareTo(b['name'] as String);
          });
          return _writeStr(outPtr, outCap, jsonEncode(items));
        } catch (_) {
          return 0;
        }
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Request broad file access (Android all-files). 1 = granted/not-needed.
    // Fire-and-forget (opens the system screen on Android); poll fs_listdir.
    final halStorageRequest = WasmFunction(
      (int _) {
        // ignore: discarded_futures
        AndroidPermissionsService.instance.requestAllFilesAccess();
        return 1;
      },
      params: [ValueTy.i32],
      results: [ValueTy.i32],
    );
    // A sensible starting directory for the in-app browser: the user's primary
    // storage on Android (/storage/emulated/0), else the home dir on desktop.
    final halFsHome = WasmFunction(
      (int outPtr, int outCap) {
        if (outCap <= 0) return 0;
        var root = '/';
        try {
          if (Platform.isAndroid) {
            for (final c in const ['/storage/emulated/0', '/sdcard']) {
              if (Directory(c).existsSync()) { root = c; break; }
            }
          } else {
            final h = Platform.environment['HOME'];
            root = (h != null && h.isNotEmpty && Directory(h).existsSync())
                ? h
                : Directory.current.path;
          }
        } catch (_) {}
        return _writeStr(outPtr, outCap, root);
      },
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halMediaDelete = WasmFunction(
      (int hashPtr, int hashLen) {
        if (hashLen <= 0) return 0;
        mediaArchive()?.delete(_readStr(hashPtr, hashLen));
        return 1;
      },
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halMediaStats = WasmFunction(
      (int outPtr, int outCap) {
        final archive = mediaArchive();
        if (archive == null || outCap <= 0) return 0;
        final s = archive.stats();
        return _writeStr(
            outPtr,
            outCap,
            jsonEncode({
              'count': s.count,
              'bytes': s.totalBytes,
              'screenshots': s.screenshotCount
            }));
      },
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Apply a sharing-control JSON: {"server":bool, "port":n, "uploads":bool,
    // "seed":bool}. Long-running work continues in the background; the wapp
    // polls hal_share_status. 1 = accepted.
    final halShareCtl = WasmFunction(
      (int jsonPtr, int jsonLen) {
        final archive = mediaArchive();
        if (archive == null || jsonLen <= 0) return 0;
        try {
          final d =
              jsonDecode(_readStr(jsonPtr, jsonLen)) as Map<String, dynamic>;
          final prefs = PreferencesService.instanceSync;
          if (d['uploads'] is bool) {
            BlossomServer.instance.uploadsEnabled = d['uploads'] as bool;
          }
          if (d['server'] is bool) {
            if (d['server'] as bool) {
              BlossomServer.instance
                  .start(archive, port: (d['port'] as num?)?.toInt());
            } else {
              BlossomServer.instance.stop();
            }
          }
          if (d['seed'] is bool && prefs != null) {
            TorrentService.instance.configure(
                archive, wappsDataStorage(prefs).getAbsolutePath('share'));
            if (d['seed'] as bool) {
              TorrentService.instance.seedAll();
            } else {
              TorrentService.instance.stop();
            }
          }
          return 1;
        } catch (_) {
          return 0;
        }
      },
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Sharing status snapshot → JSON {server:{...}, torrents:[...]}.
    final halShareStatus = WasmFunction(
      (int outPtr, int outCap) {
        if (outCap <= 0) return 0;
        final b = BlossomServer.instance;
        return _writeStr(
            outPtr,
            outCap,
            jsonEncode({
              'server': {
                'running': b.running,
                'port': b.port,
                'url': b.lanUrl ?? '',
                'uploads': b.uploadsEnabled,
                'requests': b.requests,
                'bytes': b.bytesServed,
              },
              'torrents': TorrentService.instance.status(),
            }));
      },
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Routine LAN Blossom scan (driven by the Files wapp on a timer): probe the
    // local network for Aurora Blossom servers and refresh the cached directory.
    // Media resolution then queries those KNOWN servers for a hash without
    // re-scanning. Returns the current reachable-server count; writes their
    // base URLs as a JSON array to [out]. Fire-and-forget scan (re-entrant-safe).
    final halLanScan = WasmFunction(
      (int outPtr, int outCap) {
        BlossomServer.discoverLan(); // async; refreshes the directory
        final servers = BlossomServer.knownServers();
        if (outCap > 0) _writeStr(outPtr, outCap, jsonEncode(servers));
        return servers.length;
      },
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Fetch a file by its token: scan the LAN for a Blossom peer that has it
    // (the Blossom path is for nearby devices), then fall back to the
    // BitTorrent swarm via any recorded infohash. Fire-and-forget; the wapp
    // re-lists once the bytes land.
    final halMediaFetch = WasmFunction(
      (int tokenPtr, int tokenLen) {
        final archive = mediaArchive();
        final prefs = PreferencesService.instanceSync;
        if (archive == null || tokenLen <= 0) return 0;
        final ref = MediaRef.parse(_readStr(tokenPtr, tokenLen));
        if (ref == null) return 0;
        if (archive.has(ref.sha256)) return 1;
        if (prefs != null) {
          TorrentService.instance.configure(
              archive, wappsDataStorage(prefs).getAbsolutePath('share'));
        }
        () async {
          // 1. LAN: scan nearby devices on the Blossom port.
          if (await BlossomServer.scanLan(
                  ref.sha256Hex, ref.ext, archive,
                  port: BlossomServer.instance.port) !=
              null) {
            return;
          }
          // 2. Internet: any infohash we learned for this hash → the swarm.
          for (final (kind, value) in archive.getSources(ref.sha256)) {
            if (kind == 'infohash') {
              final token = await TorrentService.instance
                  .fetch(value, expectedSha256: ref.sha256, ext: ref.ext);
              if (token != null) return;
            }
          }
        }();
        return 1;
      },
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Fetch from a magnet: link (the cross-internet path — a user shares a
    // magnet, we join the swarm). [expected] is the file:token to verify the
    // content against (may be empty). Fire-and-forget.
    final halMediaFetchMagnet = WasmFunction(
      (int magPtr, int magLen, int expPtr, int expLen) {
        final archive = mediaArchive();
        final prefs = PreferencesService.instanceSync;
        if (archive == null || magLen <= 0) return 0;
        final magnet = _readStr(magPtr, magLen);
        final ih = TorrentService.infohashFromMagnet(magnet);
        if (ih == null) return 0;
        final ref = expLen > 0 ? MediaRef.parse(_readStr(expPtr, expLen)) : null;
        if (prefs != null) {
          TorrentService.instance.configure(
              archive, wappsDataStorage(prefs).getAbsolutePath('share'));
        }
        TorrentService.instance.fetch(ih,
            expectedSha256: ref?.sha256, ext: ref?.ext ?? 'bin');
        return 1;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Record a source for a hash: kind = blossom|infohash|callsign.
    final halMediaAddSource = WasmFunction(
      (int tokenPtr, int tokenLen, int kindPtr, int kindLen, int valPtr,
          int valLen) {
        final archive = mediaArchive();
        if (archive == null || tokenLen <= 0 || kindLen <= 0 || valLen <= 0) {
          return 0;
        }
        archive.addSource(_readStr(tokenPtr, tokenLen),
            _readStr(kindPtr, kindLen), _readStr(valPtr, valLen));
        return 1;
      },
      params: [
        ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32,
        ValueTy.i32
      ],
      results: [ValueTy.i32],
    );
    // A shareable magnet: link for an archived token (xt + name + trackers) —
    // the reference a user hands to someone on another network. Built async
    // and cached; returns 0 until ready, then the magnet on a later call.
    final halMediaMagnet = WasmFunction(
      (int tokenPtr, int tokenLen, int outPtr, int outCap) {
        final archive = mediaArchive();
        final prefs = PreferencesService.instanceSync;
        if (archive == null || prefs == null || tokenLen <= 0 || outCap <= 0) {
          return 0;
        }
        final token = _readStr(tokenPtr, tokenLen);
        TorrentService.instance.configure(
            archive, wappsDataStorage(prefs).getAbsolutePath('share'));
        final cached = _magnetCache[token];
        if (cached != null) return _writeStr(outPtr, outCap, cached);
        TorrentService.instance.magnetOf(token).then((m) {
          if (m != null) _magnetCache[token] = m;
        });
        return 0;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // The deterministic torrent infohash (40-hex) for an archived token — the
    // sender appends this to the share message so the receiver can join the
    // swarm. Built async + cached; 0 until ready, then the hex on a later call.
    final halMediaInfohash = WasmFunction(
      (int tokenPtr, int tokenLen, int outPtr, int outCap) {
        final archive = mediaArchive();
        final prefs = PreferencesService.instanceSync;
        if (archive == null || prefs == null || tokenLen <= 0 || outCap <= 0) {
          return 0;
        }
        final token = _readStr(tokenPtr, tokenLen);
        TorrentService.instance.configure(
            archive, wappsDataStorage(prefs).getAbsolutePath('share'));
        // Sharing a file means we should be reachable both ways: in the swarm
        // (so off-network peers can fetch via the infohash) AND on the LAN (so
        // same-network peers can fetch the hash over Blossom without any address
        // on the air). start() is idempotent.
        BlossomServer.instance.start(archive);
        final cached = _infohashCache[token];
        if (cached != null) return _writeStr(outPtr, outCap, cached);
        // Seed (not just compute): appending ih: to a share message only helps
        // the receiver if we're actually in the swarm. seed() is idempotent and
        // returns the same deterministic infohash.
        TorrentService.instance.seed(token).then((ih) {
          if (ih != null) _infohashCache[token] = ih;
        });
        return 0;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );

    // Verify a base85 signature against a base64url x-only pubkey. 1 = valid.
    final halVerify = WasmFunction(
      (int pubPtr, int pubLen, int msgPtr, int msgLen, int sigPtr, int sigLen) {
        if (pubLen <= 0 || msgLen <= 0 || sigLen <= 0) return 0;
        final ok = _verifyMessage(_readStr(pubPtr, pubLen),
            _readBytes(msgPtr, msgLen), _readStr(sigPtr, sigLen));
        return ok ? 1 : 0;
      },
      params: [
        ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32,
        ValueTy.i32
      ],
      results: [ValueTy.i32],
    );
    final halHeapFree = WasmFunction(() => 1024 * 1024,
        params: [], results: [ValueTy.i32]);
    final halTimeMs = WasmFunction(
      () => _stopwatch.elapsedMilliseconds,
      params: [], results: [ValueTy.i64],
    );
    final halTimeEpoch = WasmFunction(
      () => DateTime.now().millisecondsSinceEpoch ~/ 1000,
      params: [], results: [ValueTy.i64],
    );
    final halLog = WasmFunction.voidReturn(
      (int level, int ptr, int len) {
        logs.add(WappLogEntry(level, _readStr(ptr, len)));
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
    );
    final halYield = WasmFunction.voidReturn(
      () {}, params: [],
    );

    // ── KV HAL ──

    final halKvGet = WasmFunction(
      (int kPtr, int kLen, int vPtr, int vLen) {
        final key = _readStr(kPtr, kLen);
        final val = _kv[key];
        if (val == null) return 0;
        final n = val.length < vLen ? val.length : vLen;
        final mem = _memory!.view;
        for (var i = 0; i < n; i++) mem[vPtr + i] = val[i];
        return n;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halKvSet = WasmFunction(
      (int kPtr, int kLen, int vPtr, int vLen) {
        final key = _readStr(kPtr, kLen);
        final mem = _memory!.view;
        _kv[key] = Uint8List.fromList(mem.buffer.asUint8List(vPtr, vLen));
        _saveKv();
        return 0;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halKvDelete = WasmFunction(
      (int kPtr, int kLen) {
        final removed = _kv.remove(_readStr(kPtr, kLen)) != null;
        if (removed) _saveKv();
        return removed ? 0 : -1;
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halKvList = WasmFunction(
      (int pPtr, int pLen, int bPtr, int bLen) {
        final prefix = _readStr(pPtr, pLen);
        final keys = _kv.keys.where((k) => k.startsWith(prefix)).toList();
        var offset = 0, count = 0;
        final mem = _memory!.view;
        for (final key in keys) {
          final kb = key.codeUnits;
          if (offset + kb.length + 1 > bLen) break;
          for (var i = 0; i < kb.length; i++) mem[bPtr + offset + i] = kb[i];
          offset += kb.length;
          mem[bPtr + offset] = 0;
          offset++;
          count++;
        }
        return count;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halKvExists = WasmFunction(
      (int kPtr, int kLen) => _kv.containsKey(_readStr(kPtr, kLen)) ? 1 : 0,
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halKvSize = WasmFunction(
      (int kPtr, int kLen) {
        final val = _kv[_readStr(kPtr, kLen)];
        return val?.length ?? 0;
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );

    // ── i18n HAL ──
    //
    // Look up a translation key in the wapp's loaded [_i18n]
    // context. Returns the number of bytes written. Zero means
    // "not found" (empty buffer is OK for the caller) — the
    // wapp's C code is expected to fall back to its hard-coded
    // literal in that case. See docs/plan/wapp-i18n.md for the
    // resolution rules.
    final halI18nGet = WasmFunction(
      (int kPtr, int kLen, int oPtr, int oCap) {
        final key = _readStr(kPtr, kLen);
        // Use resolve() so the key's `@` sentinel is stripped if
        // the wapp happens to pass `@foo.bar` instead of `foo.bar`.
        final raw = key.startsWith('@') ? key : '@$key';
        final value = _i18n.resolve(raw);
        // If the lookup missed, resolve() returns the bare key —
        // detect that and report zero so the wapp falls back to
        // its literal instead of writing "foo.bar" into the UI.
        if (value == key || value == raw.substring(1)) return 0;
        final bytes = utf8.encode(value);
        final n = bytes.length < oCap ? bytes.length : oCap;
        final mem = _memory!.view;
        for (var i = 0; i < n; i++) mem[oPtr + i] = bytes[i];
        return n;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );

    // ── Message HAL ──

    final halMsgAvailable = WasmFunction(
      () => _inbox.isEmpty ? 0 : _inbox.first.codeUnits.length,
      params: [], results: [ValueTy.i32],
    );
    final halMsgRecv = WasmFunction(
      (int ptr, int len) {
        if (_inbox.isEmpty) return 0;
        return _writeStr(ptr, len, _inbox.removeAt(0));
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halMsgSend = WasmFunction.voidReturn(
      (int ptr, int len) => _outbox.add(_readStr(ptr, len)),
      params: [ValueTy.i32, ValueTy.i32],
    );

    // ── Event HAL (cross-wapp pub/sub via WappEventBroker) ──

    final halEventSubscribe = WasmFunction(
      (int tPtr, int tLen) => WappEventBroker.instance
          .subscribe(engineId, _readStr(tPtr, tLen)),
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halEventUnsubscribe = WasmFunction(
      (int tPtr, int tLen) => WappEventBroker.instance
          .unsubscribe(engineId, _readStr(tPtr, tLen)),
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halEventPublish = WasmFunction(
      (int tPtr, int tLen, int dPtr, int dLen) =>
          WappEventBroker.instance.publish(
        engineId,
        _readStr(tPtr, tLen),
        _readStr(dPtr, dLen),
      ),
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halEventAvailable = WasmFunction(
      () => WappEventBroker.instance.availableSize(engineId),
      params: [],
      results: [ValueTy.i32],
    );
    final halEventRecv = WasmFunction(
      (int tPtr, int tLen, int dPtr, int dLen) {
        final ev = WappEventBroker.instance.recv(engineId);
        if (ev == null) return 0;
        // Null-terminate both buffers so C wapps can read them with
        // strlen(). Reserve one byte of each buffer for the null.
        final tWritten = _writeStr(tPtr, tLen - 1, ev.topic);
        _memory!.view[tPtr + tWritten] = 0;
        final dWritten = _writeStr(dPtr, dLen - 1, ev.data);
        _memory!.view[dPtr + dWritten] = 0;
        // Return value is bytes written to the DATA buffer, not
        // counting the null terminator — matches hal_msg_recv.
        return dWritten;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );

    // ── Process HAL (host subprocess, no sandbox) ──
    //
    // Async polling, mirroring hal_http_*: exec spawns and returns a
    // handle immediately; the wapp polls hal_process_poll until done,
    // drains stdout/stderr at any time, then frees. Full host trust —
    // a wapp must declare the "process" permission to import these, and
    // the engine only binds imports the module actually declares.

    final halProcessExec = WasmFunction(
      (int argvPtr, int argvLen, int cwdPtr, int cwdLen) {
        final argvJson = _readStr(argvPtr, argvLen);
        final cwd = cwdLen > 0 ? _readStr(cwdPtr, cwdLen) : null;
        List<String> argv;
        try {
          final parsed = jsonDecode(argvJson);
          if (parsed is! List || parsed.isEmpty) return -1;
          argv = parsed.map((e) => e.toString()).toList();
        } catch (_) {
          return -1;
        }
        final h = _nextProcHandle++;
        final s = _WappProcState();
        _procs[h] = s;
        // Spawn asynchronously — return the handle immediately so the
        // wapp can poll on the next tick.
        Process.start(
          argv.first,
          argv.skip(1).toList(),
          workingDirectory: (cwd != null && cwd.isNotEmpty) ? cwd : null,
          runInShell: false,
        ).then((p) {
          s.proc = p;
          s.stdoutSub = p.stdout.listen(s.stdoutBuf.addAll);
          s.stderrSub = p.stderr.listen(s.stderrBuf.addAll);
          p.exitCode.then((c) => s.exitCode = c);
        }).catchError((Object e) {
          // Spawn failed (binary missing, permission, etc). Mark the
          // entry as exited 127 so the wapp's poll loop ends cleanly,
          // and stash the error in stderr so it can be surfaced.
          s.exitCode = 127;
          s.stderrBuf.addAll(utf8.encode('$e\n'));
        });
        return h;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halProcessPoll = WasmFunction(
      (int h) {
        final s = _procs[h];
        if (s == null) return -1;
        return s.exitCode == null ? 0 : 1;
      },
      params: [ValueTy.i32], results: [ValueTy.i32],
    );
    final halProcessExitCode = WasmFunction(
      (int h) {
        final s = _procs[h];
        if (s == null) return -1;
        return s.exitCode ?? -1;
      },
      params: [ValueTy.i32], results: [ValueTy.i32],
    );
    int drainBuf(List<int> buf, int bufPtr, int bufLen) {
      final n = buf.length < bufLen ? buf.length : bufLen;
      if (n == 0) return 0;
      final mem = _memory!.view;
      for (var i = 0; i < n; i++) mem[bufPtr + i] = buf[i];
      buf.removeRange(0, n);
      return n;
    }
    final halProcessReadStdout = WasmFunction(
      (int h, int bufPtr, int bufLen) {
        final s = _procs[h];
        if (s == null) return 0;
        return drainBuf(s.stdoutBuf, bufPtr, bufLen);
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halProcessReadStderr = WasmFunction(
      (int h, int bufPtr, int bufLen) {
        final s = _procs[h];
        if (s == null) return 0;
        return drainBuf(s.stderrBuf, bufPtr, bufLen);
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halProcessFree = WasmFunction.voidReturn(
      (int h) {
        final s = _procs.remove(h);
        if (s == null) return;
        s.stdoutSub?.cancel();
        s.stderrSub?.cancel();
        if (s.exitCode == null) {
          try { s.proc?.kill(); } catch (_) {}
        }
      },
      params: [ValueTy.i32],
    );

    // ── HTTP HAL (host internet, backed by HttpTransport) ──
    //
    // Async polling, same shape as the process HAL: request spawns and
    // returns a handle immediately; the wapp polls hal_http_poll until
    // done (0 = pending, 1 = done, <0 = unknown handle / transport
    // failure), reads the status with hal_http_status, drains the body
    // with hal_http_read_response (repeatable — advances an internal
    // offset), then frees. Used by the Wapp Store to GET its catalog
    // index.json from a remote repo. method: 0=GET 1=POST 2=PUT 3=DELETE.
    final halHttpRequest = WasmFunction(
      (int method, int urlPtr, int urlLen, int bodyPtr, int bodyLen) {
        final url = _readStr(urlPtr, urlLen);
        if (url.isEmpty) return -1;
        final body = bodyLen > 0 ? _readStr(bodyPtr, bodyLen) : null;
        final Uri uri;
        try {
          uri = Uri.parse(url);
        } catch (_) {
          return -1;
        }
        final h = _nextHttpHandle++;
        final s = _WappHttpState();
        _https[h] = s;
        const transport = HttpTransport.shared;
        const timeout = Duration(seconds: 30);
        Future<HttpResult> req;
        switch (method) {
          case 1:
            req = transport.post(uri, body: body, timeout: timeout);
            break;
          case 0:
          default:
            // GET (and any unmapped method) — the store only needs GET.
            req = transport.get(uri, timeout: timeout);
            break;
        }
        req.then((r) {
          s.status = r.statusCode;
          s.body = r.bodyBytes;
          s.done = true;
        }).catchError((Object _) {
          s.failed = true;
          s.done = true;
        });
        return h;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halHttpPoll = WasmFunction(
      (int h) {
        final s = _https[h];
        if (s == null) return -1;
        if (!s.done) return 0; // pending
        return s.failed ? -1 : 1; // transport failure vs. got a response
      },
      params: [ValueTy.i32], results: [ValueTy.i32],
    );
    final halHttpStatus = WasmFunction(
      (int h) {
        final s = _https[h];
        if (s == null) return -1;
        return s.status;
      },
      params: [ValueTy.i32], results: [ValueTy.i32],
    );
    final halHttpReadResponse = WasmFunction(
      (int h, int bufPtr, int bufLen) {
        final s = _https[h];
        if (s == null || !s.done || s.failed) return 0;
        final remaining = s.body.length - s.readOffset;
        if (remaining <= 0 || bufLen <= 0) return 0;
        final n = remaining < bufLen ? remaining : bufLen;
        final mem = _memory!.view;
        for (var i = 0; i < n; i++) mem[bufPtr + i] = s.body[s.readOffset + i];
        s.readOffset += n;
        return n;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halHttpFree = WasmFunction.voidReturn(
      (int h) { _https.remove(h); },
      params: [ValueTy.i32],
    );

    // ── Streaming HTTP HAL (online radio) ──
    // A long-lived GET whose bytes flow in over time (https + redirects + ICY
    // metadata handled here). The wapp reads chunks with hal_http_stream_read
    // and decodes incrementally; hal_http_stream_meta returns the StreamTitle.
    final halHttpStreamOpen = WasmFunction(
      (int urlPtr, int urlLen) {
        final url = _readStr(urlPtr, urlLen);
        if (url.isEmpty) return -1;
        final Uri uri;
        try { uri = Uri.parse(url); } catch (_) { return -1; }
        final h = _nextStreamHandle++;
        final s = _WappStreamState();
        _streams[h] = s;
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 20)
          ..autoUncompress = false;
        client.getUrl(uri).then((req) {
          req.headers.set('Icy-MetaData', '1');
          req.headers.set('User-Agent', 'Aurora/1.0');
          return req.close();
        }).then((resp) {
          final mi = resp.headers.value('icy-metaint');
          if (mi != null) s.icyMetaInt = int.tryParse(mi) ?? 0;
          s.state = 1;
          s.sub = resp.listen(
            s.ingest,
            onDone: () { s.state = 2; client.close(force: true); },
            onError: (Object _) { s.state = 2; client.close(force: true); },
            cancelOnError: true,
          );
        }).catchError((Object _) {
          s.state = 2;
          client.close(force: true);
        });
        return h;
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halHttpStreamRead = WasmFunction(
      (int h, int bufPtr, int bufLen) {
        final s = _streams[h];
        if (s == null) return -1;
        if (s.rxBuf.isEmpty) return s.state == 2 ? -1 : 0; // -1 closed, 0 wait
        if (bufLen <= 0) return 0;
        final n = s.rxBuf.length < bufLen ? s.rxBuf.length : bufLen;
        final mem = _memory!.view;
        for (var i = 0; i < n; i++) mem[bufPtr + i] = s.rxBuf[i];
        s.rxBuf.removeRange(0, n);
        return n;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halHttpStreamMeta = WasmFunction(
      (int h, int bufPtr, int bufLen) {
        final s = _streams[h];
        if (s == null || s.title.isEmpty || bufLen <= 0) return 0;
        return _writeStr(bufPtr, bufLen, s.title);
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halHttpStreamClose = WasmFunction.voidReturn(
      (int h) {
        final s = _streams.remove(h);
        s?.sub?.cancel();
      },
      params: [ValueTy.i32],
    );

    // ── File HAL (host filesystem, no sandbox) ──
    //
    // Absolute paths, full filesystem access — same trust model as
    // hal_process_exec. Reads slurp the whole file at open; writes
    // accumulate and flush at close. Parent dirs are created on
    // write/append open so wapps don't need a separate mkdir.

    final halFileOpen = WasmFunction(
      (int pathPtr, int pathLen, int mode) {
        final path = _readStr(pathPtr, pathLen);
        if (path.isEmpty || mode < 0 || mode > 2) return -1;
        final s = _WappFileState(path: path, mode: mode);
        if (mode == 0) {
          try {
            s.readBuf = File(path).readAsBytesSync();
          } catch (_) {
            return -1;
          }
        } else {
          try {
            final parent = File(path).parent;
            if (!parent.existsSync()) parent.createSync(recursive: true);
          } catch (_) {
            return -1;
          }
        }
        final h = _nextFileHandle++;
        _files[h] = s;
        return h;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halFileRead = WasmFunction(
      (int h, int bufPtr, int bufLen) {
        final s = _files[h];
        if (s == null || s.mode != 0) return -1;
        final buf = s.readBuf;
        if (buf == null) return -1;
        final remain = buf.length - s.readOffset;
        if (remain <= 0) return 0;
        final n = remain < bufLen ? remain : bufLen;
        final mem = _memory!.view;
        for (var i = 0; i < n; i++) {
          mem[bufPtr + i] = buf[s.readOffset + i];
        }
        s.readOffset += n;
        return n;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halFileWrite = WasmFunction(
      (int h, int bufPtr, int bufLen) {
        final s = _files[h];
        if (s == null || s.mode == 0) return -1;
        if (bufLen <= 0) return 0;
        final mem = _memory!.view;
        for (var i = 0; i < bufLen; i++) {
          s.writeBuf.add(mem[bufPtr + i]);
        }
        return bufLen;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halFileClose = WasmFunction.voidReturn(
      (int h) {
        final s = _files.remove(h);
        if (s == null) return;
        if (s.mode == 1) {
          try { File(s.path).writeAsBytesSync(s.writeBuf); } catch (_) {}
        } else if (s.mode == 2) {
          try {
            File(s.path).writeAsBytesSync(s.writeBuf, mode: FileMode.append);
          } catch (_) {}
        }
      },
      params: [ValueTy.i32],
    );

    // ── Socket HAL (raw TCP, host network, no sandbox) ──
    //
    // Abstracts dart:io Socket behind the wasm ABI so any wapp can open a
    // TCP connection (e.g. APRS-IS). Async, mirroring hal_process_*:
    // `open` kicks off Socket.connect and returns a handle immediately;
    // the wapp polls `status` until it reports open, then send/recv.
    // Inbound bytes buffer in rxBuf and are drained by `recv`.

    final halSocketOpen = WasmFunction(
      (int hostPtr, int hostLen, int port) {
        final host = _readStr(hostPtr, hostLen);
        if (host.isEmpty || port <= 0 || port > 65535) return -1;
        final key = '$host:$port';
        // Reuse the live shared connection to this server if one exists; a dead
        // one (state 2) was unregistered on drop, so a fresh connect happens.
        var sh = _sharedSockets[key];
        if (sh == null) {
          sh = _SharedSocket(key);
          _sharedSockets[key] = sh;
          final created = sh;
          Socket.connect(host, port, timeout: const Duration(seconds: 15))
              .then((sock) {
            created.socket = sock;
            created.state = 1;
            created.sub = sock.listen(
              created.fanOut,
              onDone: () {
                created.state = 2;
                _sharedSockets.remove(created.key); // next open reconnects fresh
              },
              onError: (_) {
                created.state = 2;
                _sharedSockets.remove(created.key);
              },
              cancelOnError: true,
            );
          }).catchError((_) {
            created.state = 2;
            _sharedSockets.remove(created.key);
          });
        }
        final view = _WappSocketState()..shared = sh;
        sh.views.add(view);
        final h = _nextSocketHandle++;
        _sockets[h] = view;
        return h;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halSocketStatus = WasmFunction(
      (int h) => _sockets[h]?.state ?? 2,
      params: [ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halSocketSend = WasmFunction(
      (int h, int bufPtr, int bufLen) {
        final sh = _sockets[h]?.shared;
        if (sh == null || sh.state != 1 || sh.socket == null) return -1;
        if (bufLen <= 0) return 0;
        final mem = _memory!.view;
        final out = List<int>.generate(bufLen, (i) => mem[bufPtr + i]);
        // Suppress duplicate APRS-IS logins on the shared connection: the first
        // engine's "user <call> pass ..." authenticates the single connection;
        // any other engine's login for the same connection is dropped (pretend
        // sent) so the server never sees two logins for one callsign and kicks
        // us into a reconnect war. Beacons/messages/acks all pass through.
        if (out.length >= 5 &&
            out[0] == 0x75 && out[1] == 0x73 && out[2] == 0x65 &&
            out[3] == 0x72 && out[4] == 0x20) { // "user "
          if (sh.loginSent) return bufLen;
          sh.loginSent = true;
        }
        try {
          sh.socket!.add(out);
          return bufLen;
        } catch (_) {
          sh.state = 2;
          _sharedSockets.remove(sh.key);
          return -1;
        }
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halSocketRecv = WasmFunction(
      (int h, int bufPtr, int bufLen) {
        final s = _sockets[h];
        if (s == null) return 0;
        return drainBuf(s.rxBuf, bufPtr, bufLen);
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halSocketClose = WasmFunction.voidReturn(
      (int h) => _closeSocketHandle(h),
      params: [ValueTy.i32],
    );

    // ── Synchronous socket HAL (blocking; for the test runner) ──
    //
    // The wasm test runner (module_run_tests) is one synchronous call —
    // it can't await the async hal_socket_* above. These blocking
    // variants (backed by RawSynchronousSocket) let a test connect,
    // write, and drain bytes within that single call: connect blocks,
    // `avail` reports kernel-buffered bytes without blocking, and `read`
    // only pulls what's already there. A test loop bounded by
    // hal_time_ms() spins while the kernel fills the socket. Blocks the
    // calling isolate — fine for a one-shot, headless test engine.

    final halSocketOpenSync = WasmFunction(
      (int hostPtr, int hostLen, int port) {
        final host = _readStr(hostPtr, hostLen);
        if (host.isEmpty || port <= 0 || port > 65535) return -1;
        try {
          final sock = RawSynchronousSocket.connectSync(host, port);
          final h = _nextSyncSocketHandle++;
          _syncSockets[h] = sock;
          return h;
        } catch (_) {
          return -1;
        }
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halSocketAvailSync = WasmFunction(
      (int h) {
        final s = _syncSockets[h];
        if (s == null) return -1;
        try {
          return s.available();
        } catch (_) {
          return -1;
        }
      },
      params: [ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halSocketReadSync = WasmFunction(
      (int h, int bufPtr, int bufLen) {
        final s = _syncSockets[h];
        if (s == null) return -1;
        try {
          final avail = s.available();
          if (avail <= 0) return 0;
          final want = avail < bufLen ? avail : bufLen;
          final data = s.readSync(want);
          if (data == null) return -1; // EOF
          final mem = _memory!.view;
          for (var i = 0; i < data.length; i++) mem[bufPtr + i] = data[i];
          return data.length;
        } catch (_) {
          return -1;
        }
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halSocketWriteSync = WasmFunction(
      (int h, int bufPtr, int bufLen) {
        final s = _syncSockets[h];
        if (s == null || bufLen <= 0) return -1;
        try {
          final mem = _memory!.view;
          final out = List<int>.generate(bufLen, (i) => mem[bufPtr + i]);
          s.writeFromSync(out);
          return bufLen;
        } catch (_) {
          return -1;
        }
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halSocketCloseSync = WasmFunction.voidReturn(
      (int h) {
        final s = _syncSockets.remove(h);
        if (s == null) return;
        try { s.closeSync(); } catch (_) {}
      },
      params: [ValueTy.i32],
    );

    // ── Stubs (return sentinel values) ──

    // The stub closures MUST accept as many positional args as the import
    // declares: wasm_run invokes them via Function.apply(inner, args), so a
    // zero-arg closure throws NoSuchMethodError ("mismatched arguments") the
    // moment a module actually calls the stub WITH arguments — and a throw in
    // a host callback returns null to the runtime, which then derefs it and
    // crashes the whole app natively. Most wapps never hit this (they don't
    // call gpio/wasi/lib_call stubs), but a libc-heavy wapp like mp4player
    // does. The optional positional params cover every stub arity in use
    // (max 8, for lib_call); extra params just stay null.
    WasmFunction stubVoid(List<ValueTy> p) => WasmFunction.voidReturn(
        ([Object? a, Object? b, Object? c, Object? d, Object? e, Object? f,
                Object? g, Object? h]) {},
        params: p);
    WasmFunction stubI32(List<ValueTy> p, int v) => WasmFunction(
        ([Object? a, Object? b, Object? c, Object? d, Object? e, Object? f,
                Object? g, Object? h]) =>
            v,
        params: p,
        results: [ValueTy.i32]);

    // ── Generic codec-free A/V sink ───────────────────────────────────
    // The wapp's wasm decoder pushes decoded frames/PCM here; the host
    // copies the bytes out of linear memory (the view is invalidated on
    // memory growth, so the copy is mandatory) and forwards to the
    // attached session, if any. No codec lives in the host.
    // A thrown exception inside a host import callback crashes the wasm
    // runtime NATIVELY (SIGSEGV), taking the whole app down — so every sink
    // callback swallows and logs instead of letting anything escape.
    final halVideoConfig = WasmFunction.voidReturn(
      (int width, int height, int pixfmt) {
        try {
          onVideoConfig?.call(width, height, pixfmt);
        } catch (e) {
          debugPrint('hal_video_config error: $e');
        }
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
    );
    final halVideoFrame = WasmFunction.voidReturn(
      (int ptr, int len, int width, int height, int pixfmt, int ptsMs) {
        try {
          final cb = onVideoFrame;
          if (cb == null) return; // no session attached — drop
          final mem = _memory!.view;
          if (ptr < 0 || len < 0 || ptr + len > mem.lengthInBytes) return;
          cb(Uint8List.fromList(mem.buffer.asUint8List(ptr, len)), width,
              height, pixfmt, ptsMs);
        } catch (e) {
          debugPrint('hal_video_frame error: $e');
        }
      },
      params: [
        ValueTy.i32, ValueTy.i32, ValueTy.i32, // ptr, len, width
        ValueTy.i32, ValueTy.i32, ValueTy.i32, // height, pixfmt, pts_ms
      ],
    );
    final halAudioPcm = WasmFunction.voidReturn(
      (int ptr, int len, int sampleRate, int channels, int sampfmt,
          int ptsMs) {
        try {
          final cb = onAudioPcm;
          if (cb == null) return;
          final mem = _memory!.view;
          if (ptr < 0 || len < 0 || ptr + len > mem.lengthInBytes) return;
          cb(Uint8List.fromList(mem.buffer.asUint8List(ptr, len)), sampleRate,
              channels, sampfmt, ptsMs);
        } catch (e) {
          debugPrint('hal_audio_pcm error: $e');
        }
      },
      params: [
        ValueTy.i32, ValueTy.i32, ValueTy.i32, // ptr, len, sample_rate
        ValueTy.i32, ValueTy.i32, ValueTy.i32, // channels, sampfmt, pts_ms
      ],
    );
    final halVideoEnd = WasmFunction.voidReturn(
      () {
        try {
          onVideoEnd?.call();
        } catch (e) {
          debugPrint('hal_video_end error: $e');
        }
      },
      params: const [],
    );

    final wasiRandomGet = WasmFunction(
      (int ptr, int len) {
        final mem = _memory!.view;
        for (var i = 0; i < len; i++) mem[ptr + i] = _random.nextInt(256);
        return 0;
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );

    // ── BLE (shared adapter via BleService) ──
    // Each wapp drains its own inbound queue (fed from the shared broadcast
    // stream) and advertises through the shared multiplexed queue, so BLE is
    // never owned exclusively by one wapp.
    final ble = BleService.instance;
    final halBleScanStart = WasmFunction(
      () {
        if (!_bleScanning) {
          _bleScanning = true;
          LogService.instance.add('WappEngine[$_appId]: BLE scan subscribe');
          _bleSub = ble.inbound.listen((f) {
            _bleRx.add(jsonEncode({
              'from': f.from,
              'rssi': f.rssi,
              'data': String.fromCharCodes(f.data),
            }).codeUnits);
            if (_bleRx.length > 256) {
              _bleRx.removeRange(0, _bleRx.length - 256);
            }
          });
          ble.startScan();
        }
        return 0;
      },
      params: [], results: [ValueTy.i32],
    );
    final halBleScanStop = WasmFunction.voidReturn(
      () {
        if (_bleScanning) {
          _bleScanning = false;
          _bleSub?.cancel();
          _bleSub = null;
          ble.stopScan();
        }
      },
      params: [],
    );
    final halBleScanRead = WasmFunction(
      (int bufPtr, int bufLen) {
        if (_bleRx.isEmpty || bufLen <= 0) return 0;
        final rec = _bleRx.removeAt(0);
        final n = rec.length < bufLen ? rec.length : bufLen;
        final mem = _memory!.view;
        for (var i = 0; i < n; i++) mem[bufPtr + i] = rec[i];
        return n;
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halBleAdvertise = WasmFunction(
      (int bufPtr, int bufLen) {
        if (bufLen <= 0) return -1;
        final mem = _memory!.view;
        final bytes = Uint8List(bufLen);
        for (var i = 0; i < bufLen; i++) bytes[i] = mem[bufPtr + i];
        // Keep wapp broadcasts on air long enough to span a receiver's
        // duty-cycled scan. Android phones scan in bursts (~every 2 min), so a
        // one-shot 10 s advert almost always falls between scan windows and the
        // message never arrives — only continuously-repeated beacons get through.
        // 120 s (< the 130 s receiver dedup, so it still delivers exactly once)
        // spans a full scan cycle. The wapp re-advertising replaces stale frames.
        ble.enqueueAdvert(this, bytes,
            ttl: const Duration(seconds: 120));
        return 0;
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halBleAdvertiseStop = WasmFunction.voidReturn(
      () => ble.clearAdverts(this),
      params: [],
    );
    // Report whether the physical Bluetooth adapter is powered ON right now (the
    // user can toggle it at the OS level at any time). A wapp uses this to avoid
    // claiming BLE is available when Bluetooth is off. Returns 1 = on, 0 = off.
    final halBleAvailable = WasmFunction(
      () => ble.poweredOn ? 1 : 0,
      params: [], results: [ValueTy.i32],
    );

    // ── SQLite HAL (per-wapp database, scoped to the wapp data dir) ──────────
    final halSqliteOpen = WasmFunction(
      (int pathPtr, int pathLen) {
        if (pathLen <= 0) return -1;
        final p = _wappDbPath(_readUtf8(pathPtr, pathLen));
        if (p == null) return -1;
        try {
          final slash = p.lastIndexOf('/');
          if (slash > 0) {
            Directory(p.substring(0, slash)).createSync(recursive: true);
          }
          final db = sqlite3.open(p);
          db.execute('PRAGMA journal_mode=WAL;');
          final h = _nextSqliteHandle++;
          _sqlite[h] = _WappSqliteState(db);
          return h;
        } catch (_) {
          return -1;
        }
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halSqliteExec = WasmFunction(
      (int h, int sqlPtr, int sqlLen, int parPtr, int parLen) {
        final st = _sqlite[h];
        if (st == null || sqlLen <= 0) return -1;
        try {
          st.db.execute(_readUtf8(sqlPtr, sqlLen), _sqliteParams(parPtr, parLen));
          st.lastError = null;
          return 0;
        } catch (e) {
          st.lastError = e.toString();
          return -1;
        }
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halSqliteQuery = WasmFunction(
      (int h, int sqlPtr, int sqlLen, int parPtr, int parLen, int outPtr,
          int outCap) {
        final st = _sqlite[h];
        if (st == null || sqlLen <= 0 || outCap <= 0) return -1;
        try {
          final rs =
              st.db.select(_readUtf8(sqlPtr, sqlLen), _sqliteParams(parPtr, parLen));
          final cols = rs.columnNames;
          final rows = [
            for (final row in rs) {for (final c in cols) c: row[c]}
          ];
          final bytes = utf8.encode(jsonEncode(rows));
          if (bytes.length > outCap) return -2;
          st.lastError = null;
          return _writeBytes(outPtr, outCap, Uint8List.fromList(bytes));
        } catch (e) {
          st.lastError = e.toString();
          return -1;
        }
      },
      params: [
        ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32,
        ValueTy.i32, ValueTy.i32
      ],
      results: [ValueTy.i32],
    );
    final halSqliteError = WasmFunction(
      (int h, int outPtr, int outCap) {
        final st = _sqlite[h];
        if (st == null || outCap <= 0) return 0;
        return _writeUtf8(outPtr, outCap, st.lastError ?? '');
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halSqliteClose = WasmFunction.voidReturn(
      (int h) {
        final st = _sqlite.remove(h);
        if (st != null) {
          try {
            st.db.dispose();
          } catch (_) {}
        }
      },
      params: [ValueTy.i32],
    );

    // ── Generic crypto HAL (caller-supplied keys) ───────────────────────────
    final halCryptoKeygen = WasmFunction(
      (int outPtr, int outCap) {
        if (outCap <= 0) return 0;
        try {
          final kp = NostrCrypto.generateKeyPair();
          return _writeStr(outPtr, outCap,
              jsonEncode({'priv': kp.privateKeyHex, 'pub': kp.publicKeyHex}));
        } catch (_) {
          return 0;
        }
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halCryptoSign = WasmFunction(
      (int privPtr, int privLen, int msgPtr, int msgLen, int outPtr, int outCap) {
        if (privLen <= 0 || msgLen <= 0 || outCap <= 0) return 0;
        try {
          final priv = _readStr(privPtr, privLen);
          final digest =
              HEX.encode(sha256.convert(_readBytes(msgPtr, msgLen)).bytes);
          return _writeStr(
              outPtr, outCap, NostrCrypto.schnorrSign(digest, priv));
        } catch (_) {
          return 0;
        }
      },
      params: [
        ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32,
        ValueTy.i32
      ],
      results: [ValueTy.i32],
    );
    final halCryptoVerify = WasmFunction(
      (int pubPtr, int pubLen, int sigPtr, int sigLen, int msgPtr, int msgLen) {
        if (pubLen <= 0 || sigLen <= 0 || msgLen <= 0) return 0;
        try {
          final digest =
              HEX.encode(sha256.convert(_readBytes(msgPtr, msgLen)).bytes);
          return NostrCrypto.schnorrVerify(
                  digest, _readStr(sigPtr, sigLen), _readStr(pubPtr, pubLen))
              ? 1
              : 0;
        } catch (_) {
          return 0;
        }
      },
      params: [
        ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32,
        ValueTy.i32
      ],
      results: [ValueTy.i32],
    );
    final halCryptoRandom = WasmFunction(
      (int outPtr, int outLen) {
        if (outLen <= 0) return 0;
        final b = Uint8List(outLen);
        for (var i = 0; i < outLen; i++) b[i] = _random.nextInt(256);
        return _writeBytes(outPtr, outLen, b);
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halCryptoAesEncrypt = WasmFunction(
      (int keyPtr, int keyLen, int inPtr, int inLen, int outPtr, int outCap) {
        if (keyLen != 32 || inLen <= 0 || outCap <= 0) return 0;
        try {
          final iv = Uint8List(16);
          for (var i = 0; i < 16; i++) iv[i] = _random.nextInt(256);
          final ct = _aesCbc(
              true, _readBytes(keyPtr, keyLen), iv, _readBytes(inPtr, inLen));
          final out = Uint8List(iv.length + ct.length)
            ..setAll(0, iv)
            ..setAll(iv.length, ct);
          if (out.length > outCap) return 0;
          return _writeBytes(outPtr, outCap, out);
        } catch (_) {
          return 0;
        }
      },
      params: [
        ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32,
        ValueTy.i32
      ],
      results: [ValueTy.i32],
    );
    final halCryptoAesDecrypt = WasmFunction(
      (int keyPtr, int keyLen, int inPtr, int inLen, int outPtr, int outCap) {
        if (keyLen != 32 || inLen <= 16 || outCap <= 0) return 0;
        try {
          final blob = _readBytes(inPtr, inLen);
          final iv = Uint8List.sublistView(blob, 0, 16);
          final ct = Uint8List.sublistView(blob, 16);
          final pt = _aesCbc(false, _readBytes(keyPtr, keyLen), iv, ct);
          if (pt.length > outCap) return 0;
          return _writeBytes(outPtr, outCap, pt);
        } catch (_) {
          return 0;
        }
      },
      params: [
        ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32,
        ValueTy.i32
      ],
      results: [ValueTy.i32],
    );

    // ── Reticulum HAL (wapp-scoped datagrams) ───────────────────────────────
    final halRnsIdentity = WasmFunction(
      (int outPtr, int outCap) {
        if (outCap <= 0) return 0;
        return _writeStr(outPtr, outCap, RnsService.instance.destHex ?? '');
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halRnsBroadcast = WasmFunction(
      (int payPtr, int payLen) {
        final tag = _appId;
        if (tag == null || payLen <= 0) return -1;
        // Fire-and-forget broadcast, like hal-level announces.
        RnsService.instance.wappBroadcast(tag, _readBytes(payPtr, payLen));
        return 1;
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    // Reliable ADDRESSED datagram to one peer's RNS dest (LXMF: direct, else
    // stored for the peer to pull). Generic — any wapp gets reliable, NAT/inbound-
    // tolerant member-to-member delivery instead of best-effort broadcast.
    final halRnsSendTo = WasmFunction(
      (int destPtr, int destLen, int payPtr, int payLen) {
        final tag = _appId;
        if (tag == null || destLen <= 0 || payLen <= 0) return -1;
        RnsService.instance.wappSendTo(
            tag, _readStr(destPtr, destLen), _readBytes(payPtr, payLen));
        return 1;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Pull store-and-forwarded datagrams a peer holds for us, from its
    // propagation dest. Fire-and-forget; pulled datagrams land on the same
    // inbound queue as hal_rns_recv.
    final halRnsPull = WasmFunction(
      (int destPtr, int destLen) {
        final tag = _appId;
        if (tag == null || destLen <= 0) return -1;
        RnsService.instance.wappPull(_readStr(destPtr, destLen));
        return 1;
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    // This node's LXMF propagation (mailbox) dest hex — peers pull from it.
    final halRnsPropDest = WasmFunction(
      (int outPtr, int outCap) {
        if (outCap <= 0) return 0;
        return _writeStr(outPtr, outCap, RnsService.instance.lxmfPropagationHex ?? '');
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    // This node's LXMF delivery dest hex — peers address messages to it.
    final halRnsDeliveryDest = WasmFunction(
      (int outPtr, int outCap) {
        if (outCap <= 0) return 0;
        return _writeStr(outPtr, outCap, RnsService.instance.lxmfDeliveryHex ?? '');
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    // Short-code rendezvous (discovery without a directory). Owner announces a
    // rendezvous dest derived from a public seed (the short code) carrying its
    // address; a joiner resolves the same seed to that address. See RnsService.
    final halRnsRvAnnounce = WasmFunction(
      (int seedPtr, int seedLen, int appPtr, int appLen) {
        if (seedLen <= 0) return -1;
        RnsService.instance.rvAnnounce(
            _readBytes(seedPtr, seedLen),
            appLen > 0 ? _readBytes(appPtr, appLen) : Uint8List(0));
        return 1;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halRnsRvResolve = WasmFunction(
      (int seedPtr, int seedLen, int outPtr, int outCap) {
        if (seedLen <= 0 || outCap <= 0) return 0;
        final app = RnsService.instance.rvResolve(_readBytes(seedPtr, seedLen));
        if (app.isEmpty) return 0;
        return _writeBytes(outPtr, outCap, app);
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Send a payload (e.g. a join request) to the rendezvous dest derived from a
    // seed — ONE connectionless encrypted packet the owner receives without a
    // link handshake (first-contact channel that survives a flaky owner inbound).
    final halRnsRvSend = WasmFunction(
      (int seedPtr, int seedLen, int payPtr, int payLen) {
        if (seedLen <= 0 || payLen <= 0) return -1;
        RnsService.instance.rvSend(
            _readBytes(seedPtr, seedLen), _readBytes(payPtr, payLen));
        return 1;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halRnsAvailable = WasmFunction(
      () {
        final tag = _appId;
        if (tag == null) return 0;
        if (_rnsRx.isEmpty) {
          for (final d in RnsService.instance.wappDrain(tag)) {
            _rnsRx.add(jsonEncode(d));
          }
        }
        if (_rnsRx.isEmpty) return 0;
        return utf8.encode(_rnsRx.first).length;
      },
      params: [], results: [ValueTy.i32],
    );
    final halRnsRecv = WasmFunction(
      (int outPtr, int outCap) {
        if (_rnsRx.isEmpty || outCap <= 0) return 0;
        final bytes = utf8.encode(_rnsRx.first);
        if (bytes.length > outCap) return 0; // caller must size via rns_available
        _rnsRx.removeAt(0);
        return _writeBytes(outPtr, outCap, Uint8List.fromList(bytes));
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    // ── NOSTR-relay DM store-and-forward backup HAL ──────────────────────────
    // Lets a wapp back up 1:1 messages to up to 3 NOSTR relays reachable over
    // Reticulum: publish each as a kind-4 (NIP-04) DM signed by the profile key,
    // poll the pre-agreed relays for DMs addressed to us, and delete them once
    // received. The host owns the profile key (sign/encrypt/decrypt); the wapp
    // passes the recipient npub (base64url) + plaintext.
    List<String> jsonStrList(String s) {
      try {
        final v = jsonDecode(s);
        if (v is List) return [for (final e in v) e.toString()];
      } catch (_) {}
      return const [];
    }

    // Reachable relays (RNS identity hashes hex) as a JSON array, up to 3.
    final halRelayReachable = WasmFunction(
      (int outPtr, int outCap) {
        if (outCap <= 0) return 0;
        final bytes = utf8.encode(
            jsonEncode(RnsService.instance.relayReachable(max: 3)));
        if (bytes.length > outCap) return 0;
        return _writeBytes(outPtr, outCap, Uint8List.fromList(bytes));
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    // Publish a kind-4 DM (npub=base64url recipient, text=plaintext, relays=JSON
    // array of relay hashes, mid=dedup id). Fire-and-forget; returns 1 if queued.
    final halRelayDmSend = WasmFunction(
      (int npubPtr, int npubLen, int textPtr, int textLen, int relaysPtr,
          int relaysLen, int midPtr, int midLen) {
        final npub = _readStr(npubPtr, npubLen);
        final text = _readStr(textPtr, textLen);
        if (npub.isEmpty || text.isEmpty) return -1;
        final relays = jsonStrList(_readStr(relaysPtr, relaysLen));
        final mid = midLen > 0 ? _readStr(midPtr, midLen) : '';
        // ignore: discarded_futures
        RnsService.instance
            .relayDmSend(npub, text, relayDestsHex: relays, msgId: mid);
        return 1;
      },
      params: [
        ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32,
        ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32
      ],
      results: [ValueTy.i32],
    );
    // Rendezvous relay set for a pubkey (hex or b64url) — sender and receiver
    // derive the same relays from their own directory views (doc: relay DM).
    final halRelayFor = WasmFunction(
      (int keyPtr, int keyLen, int outPtr, int outCap) {
        if (outCap <= 0) return 0;
        final key = _readStr(keyPtr, keyLen);
        final list = RnsService.instance.relayDestsFor(key);
        final bytes = utf8.encode(jsonEncode(list));
        if (bytes.length > outCap) return -bytes.length;
        return _writeBytes(outPtr, outCap, Uint8List.fromList(bytes));
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Trigger an async fetch of kind-4 DMs addressed to us (created_at >= since)
    // from the given relays; results land on _relayDmRx for hal_relay_dm_recv.
    final halRelayDmFetch = WasmFunction(
      (int sinceSec, int relaysPtr, int relaysLen) {
        final relays = jsonStrList(_readStr(relaysPtr, relaysLen));
        RnsService.instance
            .relayDmFetch(sinceSec, relayDestsHex: relays)
            .then((dms) {
          for (final m in dms) {
            _relayDmRx.add(jsonEncode(m));
          }
        }).ignore();
        return 1;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    // Pop the next fetched DM JSON {id, from(b64url), ts, text, mid}; 0 if none.
    final halRelayDmRecv = WasmFunction(
      (int outPtr, int outCap) {
        if (_relayDmRx.isEmpty || outCap <= 0) return 0;
        final bytes = utf8.encode(_relayDmRx.first);
        _relayDmRx.removeAt(0); // pop regardless (drop oversized to avoid a stall)
        if (bytes.length > outCap) return 0;
        return _writeBytes(outPtr, outCap, Uint8List.fromList(bytes));
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    // Recipient-authorized delete of received DMs [ids] from [relays]. Fire-and-
    // forget; returns 1 if queued.
    final halRelayDmDrop = WasmFunction(
      (int idsPtr, int idsLen, int relaysPtr, int relaysLen) {
        final ids = jsonStrList(_readStr(idsPtr, idsLen));
        if (ids.isEmpty) return 0;
        final relays = jsonStrList(_readStr(relaysPtr, relaysLen));
        // ignore: discarded_futures
        RnsService.instance.relayDmDrop(ids, relayDestsHex: relays);
        return 1;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Publish OUR identity (callsign → npub + Reticulum dests) to [relays] as a
    // signed, replaceable kind-30078 event, so peers can resolve us by callsign.
    // Fire-and-forget; returns 1 if queued.
    final halRelayIdentityPublish = WasmFunction(
      (int callPtr, int callLen, int delivPtr, int delivLen, int propPtr,
          int propLen, int relaysPtr, int relaysLen) {
        final call = _readStr(callPtr, callLen);
        if (call.isEmpty) return -1;
        final deliv = delivLen > 0 ? _readStr(delivPtr, delivLen) : '';
        final prop = propLen > 0 ? _readStr(propPtr, propLen) : '';
        final relays = jsonStrList(_readStr(relaysPtr, relaysLen));
        // ignore: discarded_futures
        RnsService.instance
            .publishIdentityToRelays(call, deliv, prop, relayDestsHex: relays);
        return 1;
      },
      params: [
        ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32,
        ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32
      ],
      results: [ValueTy.i32],
    );
    // Trigger an async resolve of a callsign → npub by querying [relays] for the
    // identity event; the result (if any) lands on _relayResolveRx for
    // hal_relay_resolve_recv. Fire-and-forget; returns 1 if queued.
    final halRelayResolve = WasmFunction(
      (int callPtr, int callLen, int relaysPtr, int relaysLen) {
        final call = _readStr(callPtr, callLen);
        if (call.isEmpty) return -1;
        final relays = jsonStrList(_readStr(relaysPtr, relaysLen));
        RnsService.instance
            .relayResolveCallsign(call, relayDestsHex: relays)
            .then((m) {
          if (m != null) _relayResolveRx.add(jsonEncode(m));
        }).ignore();
        return 1;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    // Pop the next resolution JSON {callsign, npub(b64url), deliv, prop}; 0 if none.
    final halRelayResolveRecv = WasmFunction(
      (int outPtr, int outCap) {
        if (_relayResolveRx.isEmpty || outCap <= 0) return 0;
        final bytes = utf8.encode(_relayResolveRx.first);
        _relayResolveRx.removeAt(0); // pop regardless (drop oversized)
        if (bytes.length > outCap) return 0;
        return _writeBytes(outPtr, outCap, Uint8List.fromList(bytes));
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    // ── Reticulum visualization/management HAL (read-only) ───────────────────
    // These expose the node's observed network + status + bootstrap hubs as JSON
    // so the "reticulum" wapp can render an interactive graph. Config (add/remove/
    // connect hubs, passive toggle) is done via host-action messages, not here.
    // Overflow protocol: when the JSON doesn't fit, return the NEGATED required
    // byte length (nothing written) so the wapp can re-call with a bigger buffer.
    final halRnsStatus = WasmFunction(
      (int outPtr, int outCap) {
        if (outCap <= 0) return 0;
        final bytes = utf8.encode(jsonEncode(RnsService.instance.status()));
        if (bytes.length > outCap) return -bytes.length;
        return _writeBytes(outPtr, outCap, Uint8List.fromList(bytes));
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halRnsHubs = WasmFunction(
      (int outPtr, int outCap) {
        if (outCap <= 0) return 0;
        final bytes = utf8.encode(jsonEncode(RnsService.instance.hubsInfo()));
        if (bytes.length > outCap) return -bytes.length;
        return _writeBytes(outPtr, outCap, Uint8List.fromList(bytes));
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halRnsNodes = WasmFunction(
      (int filterPtr, int filterLen, int outPtr, int outCap) {
        if (outCap <= 0) return 0;
        String? service;
        var geogramOnly = false;
        String? search;
        if (filterLen > 0) {
          try {
            final f = jsonDecode(_readStr(filterPtr, filterLen))
                as Map<String, dynamic>;
            final s = f['service'];
            if (s is String && s.isNotEmpty) service = s;
            geogramOnly = f['geogramOnly'] == true;
            final q = f['search'];
            if (q is String && q.isNotEmpty) search = q;
          } catch (_) {}
        }
        final snap = RnsService.instance.graphSnapshot(
            service: service, geogramOnly: geogramOnly, search: search);
        final bytes = utf8.encode(jsonEncode(snap));
        if (bytes.length > outCap) return -bytes.length;
        return _writeBytes(outPtr, outCap, Uint8List.fromList(bytes));
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );

    // ── Mesh HAL (BLE street mesh, doc/mesh.md) ─────────────────────────────
    final halMeshStatus = WasmFunction(
      (int outPtr, int outCap) {
        if (outCap <= 0) return 0;
        final bytes = utf8.encode(MeshService.instance.statusJson());
        if (bytes.length > outCap) return -bytes.length;
        return _writeBytes(outPtr, outCap, Uint8List.fromList(bytes));
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halMeshDevices = WasmFunction(
      (int outPtr, int outCap) {
        if (outCap <= 0) return 0;
        final bytes = utf8.encode(MeshService.instance.peopleSectionsJson());
        if (bytes.length > outCap) return -bytes.length;
        return _writeBytes(outPtr, outCap, Uint8List.fromList(bytes));
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );

    // ── Contacts HAL (reusable people picker source) ────────────────────────
    final halContactsQuery = WasmFunction(
      (int qPtr, int qLen, int outPtr, int outCap) {
        if (outCap <= 0) return -1;
        final q = qLen > 0 ? _readUtf8(qPtr, qLen) : '';
        final bytes = utf8.encode(jsonEncode(RnsService.instance.contacts(q)));
        if (bytes.length > outCap) return -2;
        return _writeBytes(outPtr, outCap, Uint8List.fromList(bytes));
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );

    final allImports = [
      // System
      WasmImport('hal', 'platform', halPlatform),
      WasmImport('hal', 'identity', halIdentity),
      WasmImport('hal', 'identity_pubkey', halIdentityPubkey),
      WasmImport('hal', 'identity_sign', halIdentitySign),
      WasmImport('hal', 'verify', halVerify),
      WasmImport('hal', 'media_list', halMediaList),
      WasmImport('hal', 'media_meta', halMediaMeta),
      WasmImport('hal', 'media_put_file', halMediaPutFile),
      WasmImport('hal', 'media_set_meta', halMediaSetMeta),
      WasmImport('hal', 'media_delete', halMediaDelete),
      WasmImport('hal', 'media_stats', halMediaStats),
      WasmImport('hal', 'media_search', halMediaSearch),
      WasmImport('hal', 'media_folders', halMediaFolders),
      WasmImport('hal', 'media_list_folder', halMediaListFolder),
      WasmImport('hal', 'folder_create', halFolderCreate),
      WasmImport('hal', 'folder_list', halFolderList),
      WasmImport('hal', 'folder_edit', halFolderEdit),
      WasmImport('hal', 'folder_browse', halFolderBrowse),
      WasmImport('hal', 'folder_stats', halFolderStats),
      WasmImport('hal', 'folder_remove', halFolderRemove),
      WasmImport('hal', 'folder_opendir', halFolderOpenDir),
      WasmImport('hal', 'folder_add_disk', halFolderAddDisk),
      WasmImport('hal', 'folder_rescan', halFolderRescan),
      WasmImport('hal', 'folder_download', halFolderDownload),
      WasmImport('hal', 'folder_autosync', halFolderAutosync),
      WasmImport('hal', 'folder_owned', halFolderOwned),
      WasmImport('hal', 'folder_subs', halFolderSubs),
      WasmImport('hal', 'fs_listdir', halFsListdir),
      WasmImport('hal', 'fs_home', halFsHome),
      WasmImport('hal', 'storage_request', halStorageRequest),
      WasmImport('hal', 'media_fetch', halMediaFetch),
      WasmImport('hal', 'media_fetch_magnet', halMediaFetchMagnet),
      WasmImport('hal', 'media_add_source', halMediaAddSource),
      WasmImport('hal', 'media_magnet', halMediaMagnet),
      WasmImport('hal', 'media_infohash', halMediaInfohash),
      WasmImport('hal', 'share_ctl', halShareCtl),
      WasmImport('hal', 'share_status', halShareStatus),
      WasmImport('hal', 'lan_scan', halLanScan),
      WasmImport('hal', 'npub', halNpub),
      WasmImport('hal', 'encrypt', halEncrypt),
      WasmImport('hal', 'decrypt', halDecrypt),
      WasmImport('hal', 'heap_free', halHeapFree),
      WasmImport('hal', 'time_ms', halTimeMs),
      WasmImport('hal', 'time_epoch', halTimeEpoch),
      WasmImport('hal', 'log', halLog),
      WasmImport('hal', 'yield', halYield),
      // KV
      WasmImport('hal', 'kv_get', halKvGet),
      WasmImport('hal', 'kv_set', halKvSet),
      WasmImport('hal', 'kv_delete', halKvDelete),
      WasmImport('hal', 'kv_list', halKvList),
      WasmImport('hal', 'kv_exists', halKvExists),
      WasmImport('hal', 'kv_size', halKvSize),
      // i18n
      WasmImport('hal', 'i18n_get', halI18nGet),
      // Messages
      WasmImport('hal', 'msg_available', halMsgAvailable),
      WasmImport('hal', 'msg_recv', halMsgRecv),
      WasmImport('hal', 'msg_send', halMsgSend),
      // File (host filesystem, no sandbox)
      WasmImport('hal', 'file_open', halFileOpen),
      WasmImport('hal', 'file_read', halFileRead),
      WasmImport('hal', 'file_write', halFileWrite),
      WasmImport('hal', 'file_close', halFileClose),
      // Socket (raw TCP, host network)
      WasmImport('hal', 'socket_open', halSocketOpen),
      WasmImport('hal', 'socket_status', halSocketStatus),
      WasmImport('hal', 'socket_send', halSocketSend),
      WasmImport('hal', 'socket_recv', halSocketRecv),
      WasmImport('hal', 'socket_close', halSocketClose),
      // Synchronous (blocking) socket — test runner only.
      WasmImport('hal', 'socket_open_sync', halSocketOpenSync),
      WasmImport('hal', 'socket_avail_sync', halSocketAvailSync),
      WasmImport('hal', 'socket_read_sync', halSocketReadSync),
      WasmImport('hal', 'socket_write_sync', halSocketWriteSync),
      WasmImport('hal', 'socket_close_sync', halSocketCloseSync),
      // BLE (shared adapter via BleService — receive on all wapps, multiplexed
      // transmit). Real implementation, not a stub.
      WasmImport('hal', 'ble_scan_start', halBleScanStart),
      WasmImport('hal', 'ble_scan_stop', halBleScanStop),
      WasmImport('hal', 'ble_scan_read', halBleScanRead),
      WasmImport('hal', 'ble_advertise', halBleAdvertise),
      WasmImport('hal', 'ble_advertise_stop', halBleAdvertiseStop),
      WasmImport('hal', 'ble_available', halBleAvailable),
      // HTTP HAL — real, backed by HttpTransport (so the Wapp Store can
      // fetch its remote catalog). Defined above; replaces the old stubs.
      WasmImport('hal', 'http_request', halHttpRequest),
      WasmImport('hal', 'http_poll', halHttpPoll),
      WasmImport('hal', 'http_read_response', halHttpReadResponse),
      WasmImport('hal', 'http_status', halHttpStatus),
      WasmImport('hal', 'http_free', halHttpFree),
      WasmImport('hal', 'http_stream_open', halHttpStreamOpen),
      WasmImport('hal', 'http_stream_read', halHttpStreamRead),
      WasmImport('hal', 'http_stream_meta', halHttpStreamMeta),
      WasmImport('hal', 'http_stream_close', halHttpStreamClose),
      // Remaining transport HAL (hal.lora) — stubs defined in
      // lib/connections/hal/. (hal.ble is implemented above, not stubbed.)
      ...connectionHalImports(stubVoid: stubVoid, stubI32: stubI32),
      // Process (host subprocess, no sandbox)
      WasmImport('hal', 'process_exec', halProcessExec),
      WasmImport('hal', 'process_poll', halProcessPoll),
      WasmImport('hal', 'process_exit_code', halProcessExitCode),
      WasmImport('hal', 'process_read_stdout', halProcessReadStdout),
      WasmImport('hal', 'process_read_stderr', halProcessReadStderr),
      WasmImport('hal', 'process_free', halProcessFree),
      // Sensors (stubs — INT32_MIN)
      WasmImport('hal', 'sensor_temperature', stubI32([], -2147483648)),
      WasmImport('hal', 'sensor_humidity', stubI32([], -2147483648)),
      WasmImport('hal', 'sensor_battery', stubI32([], -2147483648)),
      // GPS — real device position via LocationService (cached; deg×1e7 int32,
      // INT32_MIN when no fix/permission so the wapp falls back to its config).
      WasmImport(
          'hal',
          'sensor_gps_lat',
          WasmFunction(() {
            LocationService.instance.ensureStarted();
            return LocationService.instance.latE7 ?? -2147483648;
          }, params: const [], results: const [ValueTy.i32])),
      WasmImport(
          'hal',
          'sensor_gps_lon',
          WasmFunction(() {
            LocationService.instance.ensureStarted();
            return LocationService.instance.lonE7 ?? -2147483648;
          }, params: const [], results: const [ValueTy.i32])),
      // Display (stubs)
      WasmImport('hal', 'display_width', stubI32([], 0)),
      WasmImport('hal', 'display_height', stubI32([], 0)),
      WasmImport('hal', 'display_clear', stubVoid([])),
      WasmImport('hal', 'display_text', stubVoid([ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32])),
      WasmImport('hal', 'display_pixel', stubVoid([ValueTy.i32, ValueTy.i32, ValueTy.i32])),
      WasmImport('hal', 'display_rect', stubVoid([ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32])),
      WasmImport('hal', 'display_flush', stubVoid([])),
      // Codec-free A/V sink (real — forwards wasm-decoded frames/PCM to the
      // attached render session; host carries no codec).
      WasmImport('hal', 'video_config', halVideoConfig),
      WasmImport('hal', 'video_frame', halVideoFrame),
      WasmImport('hal', 'audio_pcm', halAudioPcm),
      WasmImport('hal', 'video_end', halVideoEnd),
      // GPIO (stubs)
      WasmImport('hal', 'gpio_mode', stubVoid([ValueTy.i32, ValueTy.i32])),
      WasmImport('hal', 'gpio_read', stubI32([ValueTy.i32], 0)),
      WasmImport('hal', 'gpio_write', stubVoid([ValueTy.i32, ValueTy.i32])),
      // Library calls (stub)
      WasmImport('hal', 'lib_call', stubI32([ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32], -1)),
      // Events (real — backed by WappEventBroker)
      WasmImport('hal', 'event_subscribe', halEventSubscribe),
      WasmImport('hal', 'event_unsubscribe', halEventUnsubscribe),
      WasmImport('hal', 'event_publish', halEventPublish),
      WasmImport('hal', 'event_available', halEventAvailable),
      WasmImport('hal', 'event_recv', halEventRecv),
      // SQLite (per-wapp relational storage, scoped to the wapp data dir)
      WasmImport('hal', 'sqlite_open', halSqliteOpen),
      WasmImport('hal', 'sqlite_exec', halSqliteExec),
      WasmImport('hal', 'sqlite_query', halSqliteQuery),
      WasmImport('hal', 'sqlite_error', halSqliteError),
      WasmImport('hal', 'sqlite_close', halSqliteClose),
      // Generic crypto (caller-supplied keys; complements identity_*/encrypt)
      WasmImport('hal', 'crypto_keygen', halCryptoKeygen),
      WasmImport('hal', 'crypto_sign', halCryptoSign),
      WasmImport('hal', 'crypto_verify', halCryptoVerify),
      WasmImport('hal', 'crypto_random', halCryptoRandom),
      WasmImport('hal', 'crypto_aes_encrypt', halCryptoAesEncrypt),
      WasmImport('hal', 'crypto_aes_decrypt', halCryptoAesDecrypt),
      // Reticulum (wapp-scoped peer-to-peer datagrams via RnsService)
      WasmImport('hal', 'rns_identity', halRnsIdentity),
      WasmImport('hal', 'rns_broadcast', halRnsBroadcast),
      WasmImport('hal', 'rns_send_to', halRnsSendTo),
      WasmImport('hal', 'rns_pull', halRnsPull),
      WasmImport('hal', 'rns_prop_dest', halRnsPropDest),
      WasmImport('hal', 'rns_delivery_dest', halRnsDeliveryDest),
      WasmImport('hal', 'rns_rv_announce', halRnsRvAnnounce),
      WasmImport('hal', 'rns_rv_resolve', halRnsRvResolve),
      WasmImport('hal', 'rns_rv_send', halRnsRvSend),
      WasmImport('hal', 'rns_available', halRnsAvailable),
      WasmImport('hal', 'rns_recv', halRnsRecv),
      WasmImport('hal', 'relay_reachable', halRelayReachable),
      WasmImport('hal', 'relay_dm_send', halRelayDmSend),
      WasmImport('hal', 'relay_dm_fetch', halRelayDmFetch),
      WasmImport('hal', 'relay_for', halRelayFor),
      WasmImport('hal', 'relay_dm_recv', halRelayDmRecv),
      WasmImport('hal', 'relay_dm_drop', halRelayDmDrop),
      WasmImport('hal', 'relay_identity_publish', halRelayIdentityPublish),
      WasmImport('hal', 'relay_resolve', halRelayResolve),
      WasmImport('hal', 'relay_resolve_recv', halRelayResolveRecv),
      WasmImport('hal', 'rns_status', halRnsStatus),
      WasmImport('hal', 'mesh_status', halMeshStatus),
      WasmImport('hal', 'mesh_devices', halMeshDevices),
      WasmImport('hal', 'rns_hubs', halRnsHubs),
      WasmImport('hal', 'rns_nodes', halRnsNodes),
      // Contacts (reusable people picker source)
      WasmImport('hal', 'contacts_query', halContactsQuery),
      // WASI
      WasmImport('wasi_snapshot_preview1', 'random_get', wasiRandomGet),
      WasmImport('wasi_snapshot_preview1', 'args_get', stubI32([ValueTy.i32, ValueTy.i32], 0)),
      WasmImport('wasi_snapshot_preview1', 'args_sizes_get', stubI32([ValueTy.i32, ValueTy.i32], 0)),
      WasmImport('wasi_snapshot_preview1', 'environ_get', stubI32([ValueTy.i32, ValueTy.i32], 0)),
      WasmImport('wasi_snapshot_preview1', 'environ_sizes_get', stubI32([ValueTy.i32, ValueTy.i32], 0)),
      WasmImport('wasi_snapshot_preview1', 'clock_time_get', stubI32([ValueTy.i32, ValueTy.i64, ValueTy.i32], 0)),
      WasmImport('wasi_snapshot_preview1', 'proc_exit', stubVoid([ValueTy.i32])),
      WasmImport('wasi_snapshot_preview1', 'fd_close', stubI32([ValueTy.i32], 0)),
      WasmImport('wasi_snapshot_preview1', 'fd_write', stubI32([ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32], 0)),
      WasmImport('wasi_snapshot_preview1', 'fd_read', stubI32([ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32], 0)),
      // fd_seek(fd, offset:i64, whence, newoffset_ptr) -> errno. Four args —
      // the trailing result pointer was missing, so the signature mismatched
      // and the import was silently dropped, breaking any wapp whose libc
      // pulls in fd_seek (e.g. the C++ mp4player). Return ESPIPE(29) since
      // these are non-seekable stubs.
      WasmImport('wasi_snapshot_preview1', 'fd_seek', stubI32([ValueTy.i32, ValueTy.i64, ValueTy.i32, ValueTy.i32], 29)),
      WasmImport('wasi_snapshot_preview1', 'fd_fdstat_get', stubI32([ValueTy.i32, ValueTy.i32], 0)),
      // Preopen enumeration + poll: a wapp linking more of wasi-libc (e.g.
      // the mp4player's C++ runtime) imports these. EBADF (8) from
      // fd_prestat_get tells libc there are no preopens; poll is a no-op.
      WasmImport('wasi_snapshot_preview1', 'fd_prestat_get', stubI32([ValueTy.i32, ValueTy.i32], 8)),
      WasmImport('wasi_snapshot_preview1', 'fd_prestat_dir_name', stubI32([ValueTy.i32, ValueTy.i32, ValueTy.i32], 8)),
      WasmImport('wasi_snapshot_preview1', 'poll_oneoff', stubI32([ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32], 0)),
    ];

    // Add imports one by one, skipping any the module doesn't declare.
    // wasm_run throws if we provide an import the module doesn't need.
    for (final imp in allImports) {
      try {
        builder.addImports([imp]);
      } catch (_) {
        // Module doesn't use this import — skip it
      }
    }

    _instance = await builder.build();
    _memory = _instance!.exports['memory'] as WasmMemory?;
    _loaded = true;
  }

  void init() { _instance?.getFunction('module_init')?.call([]); }
  void tick() { _instance?.getFunction('module_tick')?.call([]); }
  void handleEvent() { _instance?.getFunction('module_handle_event')?.call([]); }
  void destroy() { _instance?.getFunction('module_destroy')?.call([]); }

  /// Invoke the test runner export (present only in a `tests.wasm`
  /// built from a wapp's `tests/`). The runner emits `tests.case` /
  /// `tests.complete` JSON via `hal_msg_send`, drained from [drainOutbox].
  void runTests() { _instance?.getFunction('module_run_tests')?.call([]); }

  int get tickIntervalMs {
    final fn = _instance?.getFunction('module_tick_interval_ms');
    if (fn == null) return 5000;
    return (fn.call([]).first as int?) ?? 5000;
  }

  /// Release a socket handle (a view onto a shared connection). The underlying
  /// TCP socket is closed only when the last view on that shared connection is
  /// released, so one engine closing doesn't drop a connection another still
  /// uses.
  void _closeSocketHandle(int h) {
    final view = _sockets.remove(h);
    final sh = view?.shared;
    if (sh == null) return;
    sh.views.remove(view);
    if (sh.views.isEmpty) {
      sh.sub?.cancel();
      try { sh.socket?.destroy(); } catch (_) {}
      sh.state = 2;
      _sharedSockets.remove(sh.key);
    }
  }

  void dispose() {
    if (_loaded) { destroy(); _loaded = false; }
    // Tear down any subprocesses the wapp left running. Best-effort —
    // dispose is cleanup, so swallow failures.
    for (final s in _procs.values) {
      s.stdoutSub?.cancel();
      s.stderrSub?.cancel();
      if (s.exitCode == null) {
        try { s.proc?.kill(); } catch (_) {}
      }
    }
    _procs.clear();
    // Flush any open write/append files so a wapp that forgot to close
    // doesn't silently lose data. Reads can be dropped.
    for (final s in _files.values) {
      if (s.mode == 1) {
        try { File(s.path).writeAsBytesSync(s.writeBuf); } catch (_) {}
      } else if (s.mode == 2) {
        try {
          File(s.path).writeAsBytesSync(s.writeBuf, mode: FileMode.append);
        } catch (_) {}
      }
    }
    _files.clear();
    // Release any socket handles this engine left open — each is a view onto a
    // shared connection, so the real TCP closes only when the LAST engine using
    // it goes away (the foreground page disposing must not drop the connection
    // the background service is still using, and vice-versa).
    for (final h in _sockets.keys.toList()) {
      _closeSocketHandle(h);
    }
    for (final s in _syncSockets.values) {
      try { s.closeSync(); } catch (_) {}
    }
    _syncSockets.clear();
    // Drop any in-flight HTTP request state. Pending futures still hold
    // their own state reference and resolve harmlessly into nothing.
    _https.clear();
    // Stop any radio streams.
    for (final s in _streams.values) {
      try { s.sub?.cancel(); } catch (_) {}
    }
    _streams.clear();
    // Close any sqlite databases the wapp left open.
    for (final s in _sqlite.values) {
      try { s.db.dispose(); } catch (_) {}
    }
    _sqlite.clear();
    // Release this wapp's slot on the RNS datagram channel.
    if (_appId != null) {
      RnsService.instance.wappUnregister(_appId!);
    }
    _rnsRx.clear();
    // Release this wapp's share of the BLE adapter.
    _bleSub?.cancel();
    _bleSub = null;
    if (_bleScanning) {
      _bleScanning = false;
      BleService.instance.stopScan();
    }
    BleService.instance.clearAdverts(this);
    _bleRx.clear();
    _byId.remove(engineId);
    WappEventBroker.instance.unregisterEngine(engineId);
    _stopwatch.stop();
  }

  /// Direct handle on the outbox for the widget broker's headless
  /// provider path. Ordinary callers should use [drainOutbox] instead,
  /// which also clears the list.
  List<String> peekOutbox() => List<String>.unmodifiable(_outbox);
}
