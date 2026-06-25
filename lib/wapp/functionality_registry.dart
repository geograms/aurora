/*
 * FunctionalityRegistry — map of functionalityId → providers.
 *
 * The launcher rebuilds this whenever it scans for wapps. Providers
 * are WappManifest entries whose manifest.json declared one or more
 * functionality IDs under `provides.functionalities`, plus a
 * synthetic "Geogram Core" entry for the HAL capabilities built
 * into the runtime itself.
 *
 * Each functionality carries an optional [FunctionalityDef] with
 * endpoint signatures (params, return types) so alternative
 * providers know exactly what contract they must implement.
 */

import '../launcher/launcher.dart' show WappManifest;
import '../connections/hal/connection_functionalities.dart';

// The API definition data classes (ParamDef/ReturnDef/EndpointDef/
// FunctionalityDef) live in functionality_def.dart so lib/connections/ can
// build transport [FunctionalityDef]s without importing this registry. They
// are re-exported here so existing importers keep compiling unchanged.
export 'functionality_def.dart';
import 'functionality_def.dart';

// ── Registry ────────────────────────────────────────────────────────

class FunctionalityRegistry {
  FunctionalityRegistry._();
  static final FunctionalityRegistry instance = FunctionalityRegistry._();

  final Map<String, List<WappManifest>> _providers = {};

  /// API definitions keyed by functionality ID. Populated from core
  /// definitions and from wapp manifests that use the rich object
  /// format in `provides.functionalities`.
  final Map<String, FunctionalityDef> _defs = {};

  /// Every wapp manifest seen in the last launcher scan (not including
  /// the synthetic core entry). Read by [WappFileAssociations] so file
  /// handlers don't need a second scan of the wapp folders.
  final List<WappManifest> _allManifests = [];

  /// Manifests of all currently-installed wapps from the latest scan.
  List<WappManifest> get allManifests => List.unmodifiable(_allManifests);

  void clear() {
    _providers.clear();
    _defs.clear();
    _allManifests.clear();
  }

  void registerCore() {
    for (final entry in coreFunctionalities.entries) {
      (_providers[entry.key] ??= []).add(_coreManifest);
      _defs[entry.key] = entry.value;
    }
  }

  void register(WappManifest manifest) {
    _allManifests.add(manifest);
    for (final id in manifest.providedFunctionalities) {
      if (id.isEmpty) continue;
      (_providers[id] ??= []).add(manifest);
    }
    // Merge any rich definitions the manifest carries.
    for (final def in manifest.functionalityDefs) {
      if (def.id.isEmpty) continue;
      // Wapp definitions don't overwrite core — they supplement.
      _defs.putIfAbsent(def.id, () => def);
    }
  }

  List<WappManifest> providersFor(String functionalityId) {
    return List.unmodifiable(_providers[functionalityId] ?? const []);
  }

  FunctionalityDef? defFor(String functionalityId) => _defs[functionalityId];

  Set<String> get allFunctionalityIds => _providers.keys.toSet();

  Map<String, List<String>> toJson() => {
        for (final entry in _providers.entries)
          entry.key: [for (final p in entry.value) p.id],
      };

  static final WappManifest _coreManifest = WappManifest(
    id: 'geogram.core',
    name: 'core',
    title: 'Geogram Core',
    description: 'Built-in HAL capabilities provided by the geogram runtime.',
    kind: 'system',
    dirPath: '',
    providedFunctionalities: coreFunctionalities.keys.toList(),
  );

  // ── Core HAL API definitions ──────────────────────────────────────

  static final coreFunctionalities = <String, FunctionalityDef>{
    'hal.log': FunctionalityDef('hal.log', 'Logging', [
      EndpointDef('hal_log', 'Write a log message', [
        ParamDef('level', 'int', '0=debug, 1=info, 2=warn, 3=error'),
        ParamDef('msg', 'string', 'Message text'),
      ], ReturnDef('void')),
    ]),
    'hal.time': FunctionalityDef('hal.time', 'Time functions', [
      EndpointDef('hal_time_ms', 'Monotonic ms since host start', [],
          ReturnDef('uint64', 'Milliseconds')),
      EndpointDef('hal_time_epoch', 'Unix epoch seconds (0 if no RTC)', [],
          ReturnDef('uint64', 'Seconds')),
    ]),
    'hal.yield': FunctionalityDef('hal.yield', 'Cooperative multitasking', [
      EndpointDef('hal_yield', 'Yield to other tasks (ESP32)', [],
          ReturnDef('void')),
    ]),
    'hal.platform':
        FunctionalityDef('hal.platform', 'Platform identification', [
      EndpointDef('hal_platform', 'Get platform name', [
        ParamDef('buf', 'buffer', 'Output buffer'),
      ], ReturnDef('uint32', 'Bytes written. Values: esp32, android, linux-desktop, linux-cli')),
    ]),
    'hal.heap': FunctionalityDef('hal.heap', 'Heap status', [
      EndpointDef('hal_heap_free', 'Free heap bytes available to module', [],
          ReturnDef('uint32', 'Bytes')),
    ]),
    'hal.kv': FunctionalityDef(
        'hal.kv', 'Key-value storage (scoped per module)', [
      EndpointDef('hal_kv_get', 'Read a value by key', [
        ParamDef('key', 'string', 'Key to look up'),
      ], ReturnDef('bytes', 'Value bytes, 0 length if not found')),
      EndpointDef('hal_kv_set', 'Write a key-value pair', [
        ParamDef('key', 'string'),
        ParamDef('value', 'bytes'),
      ], ReturnDef('int', '0 on success, -1 on error')),
      EndpointDef('hal_kv_delete', 'Delete a key', [
        ParamDef('key', 'string'),
      ], ReturnDef('int', '0 on success, -1 if not found')),
      EndpointDef('hal_kv_list', 'List keys by prefix', [
        ParamDef('prefix', 'string', 'Key prefix to match'),
      ], ReturnDef('uint32', 'Count of matching keys; null-separated in buffer')),
      EndpointDef('hal_kv_exists', 'Check if a key exists', [
        ParamDef('key', 'string'),
      ], ReturnDef('int', '1 if exists, 0 if not')),
      EndpointDef('hal_kv_size', 'Get value size without reading', [
        ParamDef('key', 'string'),
      ], ReturnDef('uint32', 'Size in bytes, 0 if not found')),
    ]),
    'hal.i18n': FunctionalityDef('hal.i18n', 'Internationalization', [
      EndpointDef('hal_i18n_get', 'Look up translation key against lang/*.json', [
        ParamDef('key', 'string', 'Translation key'),
      ], ReturnDef('string', 'Translated text, empty if missing')),
    ]),
    'hal.file':
        FunctionalityDef('hal.file', 'File I/O (scoped per module)', [
      EndpointDef('hal_file_open', 'Open a file', [
        ParamDef('path', 'string', 'Relative path'),
        ParamDef('mode', 'int', '0=read, 1=write, 2=append'),
      ], ReturnDef('int', 'Handle (>=0) or -1 on error')),
      EndpointDef('hal_file_read', 'Read from an open file', [
        ParamDef('handle', 'int'),
      ], ReturnDef('int', 'Bytes read, 0 on EOF, -1 on error')),
      EndpointDef('hal_file_write', 'Write to an open file', [
        ParamDef('handle', 'int'),
        ParamDef('data', 'bytes'),
      ], ReturnDef('int', 'Bytes written or -1 on error')),
      EndpointDef('hal_file_close', 'Close a file handle', [
        ParamDef('handle', 'int'),
      ], ReturnDef('void')),
    ]),
    'hal.socket': FunctionalityDef(
        'hal.socket', 'Raw TCP sockets (async, host network)', [
      EndpointDef('hal_socket_open', 'Open a TCP connection', [
        ParamDef('host', 'string'),
        ParamDef('port', 'int'),
      ], ReturnDef('int', 'Handle (>=0) or -1 on error')),
      EndpointDef('hal_socket_status', 'Connection state', [
        ParamDef('handle', 'int'),
      ], ReturnDef('int', '0=connecting, 1=open, 2=closed/error')),
      EndpointDef('hal_socket_send', 'Queue bytes to send', [
        ParamDef('handle', 'int'),
        ParamDef('data', 'bytes'),
      ], ReturnDef('int', 'Bytes accepted or -1 on error')),
      EndpointDef('hal_socket_recv', 'Drain received bytes', [
        ParamDef('handle', 'int'),
      ], ReturnDef('int', 'Bytes read (0 if none yet)')),
      EndpointDef('hal_socket_close', 'Close the connection', [
        ParamDef('handle', 'int'),
      ], ReturnDef('void')),
    ]),
    'hal.sqlite': FunctionalityDef(
        'hal.sqlite', 'SQLite databases (scoped per module)', [
      EndpointDef('hal_sqlite_open', 'Open/create a database under the wapp data dir', [
        ParamDef('path', 'string', 'Relative path (no leading / or ..)'),
      ], ReturnDef('int', 'Handle (>=0) or -1 on error')),
      EndpointDef('hal_sqlite_exec', 'Run a non-SELECT statement', [
        ParamDef('handle', 'int'),
        ParamDef('sql', 'string'),
        ParamDef('params', 'string', 'Optional JSON array bound to ? placeholders'),
      ], ReturnDef('int', '0 on success, -1 on error')),
      EndpointDef('hal_sqlite_query', 'Run a SELECT; rows as a JSON array', [
        ParamDef('handle', 'int'),
        ParamDef('sql', 'string'),
        ParamDef('params', 'string', 'Optional JSON array bound to ? placeholders'),
      ], ReturnDef('int', 'Bytes written, -1 on error, -2 if buffer too small')),
      EndpointDef('hal_sqlite_error', 'Read the last error for a handle', [
        ParamDef('handle', 'int'),
      ], ReturnDef('uint32', 'Bytes written')),
      EndpointDef('hal_sqlite_close', 'Close a database handle', [
        ParamDef('handle', 'int'),
      ], ReturnDef('void')),
    ]),
    'hal.crypto': FunctionalityDef(
        'hal.crypto', 'Generic crypto with caller-supplied keys', [
      EndpointDef('hal_crypto_keygen', 'Generate a secp256k1 keypair', [],
          ReturnDef('uint32', 'Bytes written: JSON {priv,pub} hex')),
      EndpointDef('hal_crypto_sign', 'Sign a message (SHA-256 then BIP-340)', [
        ParamDef('priv', 'string', 'Private key hex'),
        ParamDef('msg', 'bytes'),
      ], ReturnDef('uint32', 'Bytes written: signature hex, 0 on error')),
      EndpointDef('hal_crypto_verify', 'Verify a signature', [
        ParamDef('pub', 'string', 'x-only public key hex'),
        ParamDef('sig', 'string', 'Signature hex'),
        ParamDef('msg', 'bytes'),
      ], ReturnDef('int', '1 if valid, 0 otherwise')),
      EndpointDef('hal_crypto_random', 'Fill a buffer with random bytes', [
        ParamDef('len', 'int'),
      ], ReturnDef('uint32', 'Bytes written')),
      EndpointDef('hal_crypto_aes_encrypt', 'AES-256-CBC encrypt (IV prepended)', [
        ParamDef('key', 'bytes', '32 bytes'),
        ParamDef('data', 'bytes'),
      ], ReturnDef('uint32', 'Bytes written, 0 on error')),
      EndpointDef('hal_crypto_aes_decrypt', 'AES-256-CBC decrypt (IV||ciphertext)', [
        ParamDef('key', 'bytes', '32 bytes'),
        ParamDef('data', 'bytes'),
      ], ReturnDef('uint32', 'Bytes written, 0 on error')),
    ]),
    'hal.rns': FunctionalityDef(
        'hal.rns', 'Reticulum peer-to-peer datagrams (scoped per wapp)', [
      EndpointDef('hal_rns_identity', 'This device RNS destination hex', [],
          ReturnDef('uint32', 'Bytes written, 0 if node down')),
      EndpointDef('hal_rns_broadcast', 'Broadcast a datagram to peers running this wapp', [
        ParamDef('payload', 'bytes'),
      ], ReturnDef('int', '1 if queued, -1 on error')),
      EndpointDef('hal_rns_available', 'Size of next inbound datagram', [],
          ReturnDef('uint32', '0 if none')),
      EndpointDef('hal_rns_recv', 'Read next inbound datagram (JSON {from,payload,ts})', [],
          ReturnDef('uint32', 'Bytes written, 0 if none')),
      EndpointDef('hal_rns_status', 'Node status JSON (up,mode,paths,observed,…)', [],
          ReturnDef('int', 'Bytes written, negated required size if too small')),
      EndpointDef('hal_rns_hubs', 'Configured bootstrap hubs [{endpoint,connected}]', [],
          ReturnDef('int', 'Bytes written, negated required size if too small')),
      EndpointDef('hal_rns_nodes', 'Observed network graph {nodes,edges} (filtered)', [
        ParamDef('filter', 'string', 'JSON {service,geogramOnly,search} (empty = none)'),
      ], ReturnDef('int', 'Bytes written, negated required size if too small')),
    ]),
    'hal.relay': FunctionalityDef('hal.relay',
        'NOSTR-relay store-and-forward DM backup (kind-4 over Reticulum)', [
      EndpointDef('hal_relay_reachable',
          'Up to 3 reachable relay identity hashes (JSON array)', [],
          ReturnDef('uint32', 'Bytes written, 0 if none/too small')),
      EndpointDef('hal_relay_dm_send',
          'Publish a kind-4 NIP-04 DM to relays (signed by the profile key)', [
        ParamDef('npub', 'string', 'recipient pubkey (base64url)'),
        ParamDef('text', 'string', 'plaintext'),
        ParamDef('relays', 'string', 'JSON array of relay hashes'),
        ParamDef('mid', 'string', 'dedup message id'),
      ], ReturnDef('int', '1 if queued, -1 on error')),
      EndpointDef('hal_relay_dm_fetch',
          'Trigger an async fetch of DMs addressed to us from the given relays', [
        ParamDef('since', 'uint32', 'created_at lower bound (unix seconds)'),
        ParamDef('relays', 'string', 'JSON array of relay hashes'),
      ], ReturnDef('int', '1 if queued')),
      EndpointDef('hal_relay_dm_recv',
          'Pop next fetched DM JSON {id,from,ts,text,mid}', [],
          ReturnDef('uint32', 'Bytes written, 0 if none')),
      EndpointDef('hal_relay_dm_drop',
          'Recipient-authorized delete of received DMs from relays', [
        ParamDef('ids', 'string', 'JSON array of event ids'),
        ParamDef('relays', 'string', 'JSON array of relay hashes'),
      ], ReturnDef('int', '1 if queued')),
    ]),
    'hal.contacts': FunctionalityDef(
        'hal.contacts', 'Known people (reusable contact picker source)', [
      EndpointDef('hal_contacts_query', 'List known contacts (APRS-seen + follows)', [
        ParamDef('query', 'string', 'Filter over npub/callsign/nick (empty = all)'),
      ], ReturnDef('int', 'Bytes of JSON [{npub,callsign,nick}], -1 error, -2 too small')),
    ]),
    // hal.http / hal.lora / hal.ble — the transport HAL — are defined in
    // lib/connections/, the single home for connection code, and spread in
    // here so the registry still advertises them as core functionalities.
    ...connectionFunctionalities,
    'hal.process': FunctionalityDef(
        'hal.process', 'Host subprocess execution (async polling)', [
      EndpointDef('hal_process_exec', 'Spawn a host process', [
        ParamDef('argv', 'string', 'JSON array: [binary, arg1, ...]'),
        ParamDef('cwd', 'string', 'Working directory (empty = inherit)'),
      ], ReturnDef('int', 'Handle (>=1) or -1 on error')),
      EndpointDef('hal_process_poll', 'Check if a process has exited', [
        ParamDef('handle', 'int'),
      ], ReturnDef('int', '0=running, 1=exited, -1=unknown handle')),
      EndpointDef('hal_process_exit_code', 'Read the exit code', [
        ParamDef('handle', 'int'),
      ], ReturnDef('int', 'Exit code, or -1 if still running/unknown')),
      EndpointDef('hal_process_read_stdout', 'Drain buffered stdout', [
        ParamDef('handle', 'int'),
      ], ReturnDef('int', 'Bytes written to buffer')),
      EndpointDef('hal_process_read_stderr', 'Drain buffered stderr', [
        ParamDef('handle', 'int'),
      ], ReturnDef('int', 'Bytes written to buffer')),
      EndpointDef('hal_process_free', 'Release a process handle (kills if running)', [
        ParamDef('handle', 'int'),
      ], ReturnDef('void')),
    ]),
    'hal.msg': FunctionalityDef(
        'hal.msg', 'Inter-wapp messaging (host ↔ module JSON)', [
      EndpointDef('hal_msg_send', 'Send a JSON message to the host', [
        ParamDef('json', 'string', 'JSON-encoded message'),
      ], ReturnDef('void')),
      EndpointDef('hal_msg_available', 'Bytes in next pending message', [],
          ReturnDef('uint32', '0 if none')),
      EndpointDef('hal_msg_recv', 'Receive next pending message', [],
          ReturnDef('string', 'JSON message bytes')),
    ]),
    'hal.event': FunctionalityDef(
        'hal.event', 'Event pub/sub between modules', [
      EndpointDef('hal_event_subscribe', 'Subscribe to a topic', [
        ParamDef('topic', 'string'),
      ], ReturnDef('int', '0 on success, -1 on error')),
      EndpointDef('hal_event_unsubscribe', 'Unsubscribe from a topic', [
        ParamDef('topic', 'string'),
      ], ReturnDef('int', '0 on success, -1 if not subscribed')),
      EndpointDef('hal_event_publish', 'Publish data to a topic', [
        ParamDef('topic', 'string'),
        ParamDef('data', 'bytes'),
      ], ReturnDef('int', 'Number of subscribers notified')),
      EndpointDef('hal_event_available', 'Size of next pending event', [],
          ReturnDef('uint32', '0 if none')),
      EndpointDef('hal_event_recv', 'Receive next event', [],
          ReturnDef('bytes', 'Topic + data bytes')),
    ]),
    'hal.lib': FunctionalityDef('hal.lib', 'Cross-module library calls', [
      EndpointDef('hal_lib_call', 'Call a function in another module', [
        ParamDef('lib_id', 'string', 'Target module ID'),
        ParamDef('fn_name', 'string', 'Function name'),
        ParamDef('args', 'string', 'JSON arguments'),
      ], ReturnDef('string',
          'JSON result. Errors: -1=lib not found, -2=fn not found, -3=buffer too small, -4=internal')),
    ]),
    'hal.sensor': FunctionalityDef(
        'hal.sensor', 'Hardware sensors (returns INT32_MIN if N/A)', [
      EndpointDef('hal_sensor_temperature', 'Temperature', [],
          ReturnDef('int', 'Centidegrees C (2500 = 25.00°C)')),
      EndpointDef('hal_sensor_humidity', 'Humidity', [],
          ReturnDef('int', 'Centipercent (6500 = 65.00%)')),
      EndpointDef('hal_sensor_battery', 'Battery voltage', [],
          ReturnDef('int', 'Millivolts (3700 = 3.7V)')),
      EndpointDef('hal_sensor_gps_lat', 'GPS latitude', [],
          ReturnDef('int', 'Latitude × 1e7')),
      EndpointDef('hal_sensor_gps_lon', 'GPS longitude', [],
          ReturnDef('int', 'Longitude × 1e7')),
    ]),
    'hal.display': FunctionalityDef('hal.display', 'Display/screen output', [
      EndpointDef('hal_display_width', 'Screen width', [],
          ReturnDef('uint32', 'Pixels, 0 if no display')),
      EndpointDef('hal_display_height', 'Screen height', [],
          ReturnDef('uint32', 'Pixels, 0 if no display')),
      EndpointDef('hal_display_clear', 'Clear the display', [],
          ReturnDef('void')),
      EndpointDef('hal_display_text', 'Draw text', [
        ParamDef('x', 'int'),
        ParamDef('y', 'int'),
        ParamDef('color', 'int', '0=black, 1=white'),
        ParamDef('text', 'string'),
      ], ReturnDef('void')),
      EndpointDef('hal_display_pixel', 'Draw a pixel', [
        ParamDef('x', 'int'),
        ParamDef('y', 'int'),
        ParamDef('color', 'int'),
      ], ReturnDef('void')),
      EndpointDef('hal_display_rect', 'Draw a filled rectangle', [
        ParamDef('x', 'int'),
        ParamDef('y', 'int'),
        ParamDef('w', 'int'),
        ParamDef('h', 'int'),
        ParamDef('color', 'int'),
      ], ReturnDef('void')),
      EndpointDef('hal_display_flush', 'Flush buffer to physical display', [],
          ReturnDef('void')),
    ]),
    'hal.video': FunctionalityDef(
        'hal.video', 'Codec-free A/V sink (push decoded frames/PCM)', [
      EndpointDef('hal_video_config', 'Announce video geometry', [
        ParamDef('width', 'int'),
        ParamDef('height', 'int'),
        ParamDef('pixfmt', 'int', '0=RGBA8888'),
      ], ReturnDef('void')),
      EndpointDef('hal_video_frame', 'Submit one decoded RGBA frame', [
        ParamDef('data', 'ptr'),
        ParamDef('len', 'uint32'),
        ParamDef('width', 'int'),
        ParamDef('height', 'int'),
        ParamDef('pixfmt', 'int'),
        ParamDef('pts_ms', 'int'),
      ], ReturnDef('void')),
      EndpointDef('hal_audio_pcm', 'Submit one block of decoded PCM', [
        ParamDef('data', 'ptr'),
        ParamDef('len', 'uint32'),
        ParamDef('sample_rate', 'int'),
        ParamDef('channels', 'int'),
        ParamDef('sampfmt', 'int', '0=s16, 1=f32'),
        ParamDef('pts_ms', 'int'),
      ], ReturnDef('void')),
      EndpointDef('hal_video_end', 'Signal end of stream', [],
          ReturnDef('void')),
    ]),
    'hal.gpio':
        FunctionalityDef('hal.gpio', 'GPIO pins (ESP32 only)', [
      EndpointDef('hal_gpio_mode', 'Set pin mode', [
        ParamDef('pin', 'int'),
        ParamDef('mode', 'int', '0=input, 1=output, 2=input_pullup'),
      ], ReturnDef('void')),
      EndpointDef('hal_gpio_read', 'Read pin value', [
        ParamDef('pin', 'int'),
      ], ReturnDef('int', '0 or 1')),
      EndpointDef('hal_gpio_write', 'Write pin value', [
        ParamDef('pin', 'int'),
        ParamDef('value', 'int', '0 or 1'),
      ], ReturnDef('void')),
    ]),
  };
}
