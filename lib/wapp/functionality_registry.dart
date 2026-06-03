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
