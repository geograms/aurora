import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
        Clipboard,
        ClipboardData,
        HardwareKeyboard,
        KeyDownEvent,
        LogicalKeyboardKey;
import 'package:file_selector/file_selector.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../connections/internet/http_transport.dart';
import '../platform/platform.dart' as platform;

import 'native/media_capability.dart';

import 'geoui/geoui_ast.dart';
import 'geoui/geoui_parser.dart';
import 'geoui/geoui_renderer.dart';
import '../editor/code_editor_field.dart';
import 'geoui/widgets/log_view_field.dart';
import 'geoui/widgets/chat_view_field.dart';
import 'geoui/conversation_store.dart';
import 'geoui/widgets/conversations_field.dart';
import 'geoui/tile_cache.dart';
import 'background_wapp_manager.dart';
import '../profile/iwi_profile.dart';
import '../models/monitored_task.dart';
import '../services/event_bus.dart';
import '../services/notification_service.dart';
import '../services/preferences_service.dart';
import '../profile/profile_service.dart';
import '../profile/profile_storage.dart';
import '../profile/storage_paths.dart';
import 'i18n_context.dart';
import '../services/task_monitor_service.dart';
import '../editor/wapp_compiler_service.dart';
import '../editor/robot_chat_controller.dart';
import '../ai/ai.dart';
import 'wapp_installer_service.dart';
import 'wapp_signing_service.dart';
import 'wapp_social_store.dart';
import '../launcher/launcher.dart' show WappManifest;
import 'functionality_broker.dart';
import 'functionality_registry.dart';
import 'wapp_icons.dart';
import 'wapp_engine.dart';

part '../editor/wapp_editor.dart';
part '../editor/wapp_robot.dart';
part 'wapp_maps.dart';

/// Generic wapp page — loads .ui.json screens from a wapp directory,
/// instantiates the WASM module, and renders screens as tabs.
/// Handles terminal output, settings forms, and map viewports.
class WappPage extends StatefulWidget {
  final String wappDir;
  final String title;

  /// Absolute path of a file to hand the wapp on launch (the "Open
  /// with…" path). Null for a normal launch. Delivered to the module
  /// after init as a `file.open` message.
  final String? openFilePath;

  /// Mode for [openFilePath] — "view" (default) or "edit".
  final String openFileMode;

  /// When set (and this page is the App Creator), the App Creator opens
  /// straight into editing the wapp at this absolute package dir — the
  /// Projects list is skipped and Back returns to the launcher. Used by
  /// the per-wapp "Edit" menu.
  final String? editWappDir;

  const WappPage({
    super.key,
    required this.wappDir,
    required this.title,
    this.openFilePath,
    this.openFileMode = 'view',
    this.editWappDir,
  });

  @override
  State<WappPage> createState() => _WappPageState();
}

class _WappPageState extends State<WappPage> with TickerProviderStateMixin {
  final _engine = WappEngine();
  Timer? _tickTimer;
  String _status = 'Loading...';

  /// Wapp folder name — used as a stable id for storage, task monitor,
  /// and lifecycle events. The basePath is a filesystem directory on
  /// desktop (`…/wapps/app-creator`) and an HTTP URL on web
  /// (`/wapps/app-creator.wapp`). Both splits go through forward
  /// slashes because URLs use `/` regardless of the host platform's
  /// native separator; after the split we strip any trailing `.wapp`
  /// extension so `_isAppCreator` / matches by wapp name stay
  /// identical on desktop and in the browser.
  late final String _wappName = _deriveWappName(_pkg.basePath);

  static String _deriveWappName(String basePath) {
    final normalized = basePath.replaceAll('\\', '/');
    var last = normalized.split('/').last;
    if (last.toLowerCase().endsWith('.wapp')) {
      last = last.substring(0, last.length - 5);
    }
    return last;
  }

  /// Compound id for the per-wapp tick task in [TaskMonitorService].
  late final String _tickTaskId = 'wapp.$_wappName.${_engine.engineId}';

  /// Storage rooted at the wapp package dir (read-only source of manifest,
  /// app.wasm, screens, media).
  late final ProfileStorage _pkg = wappPackageStorage(widget.wappDir);

  // ── Video group state (movies wapp) ────────────────────────────────
  // A MediaSession from the active media.video backend (the mediapack
  // capability). Lazily created on first `video.load` so the engine
  // cost is only paid by wapps that actually use it. Null when the
  // capability isn't installed/supported. Disposed in [dispose].
  MediaSession? _mediaSession;
  String? _videoCurrentPath;

  /// Storage for installed wapps (extracted .wapp packages) — used by the
  /// install/uninstall flow.
  final ProfileStorage _installed = installedAppsStorage();

  /// Per-wapp work folder storage, set up by `_loadWapp`. Holds the
  /// wapp's KV, its draft projects, and any host-service scratch data
  /// (e.g. App Creator's compile-tmp/ and last_compiled.wasm).
  ProfileStorage? _wappData;

  // Screens parsed from .ui.json
  final _screens = <GeoUiBlock>[];
  final _screenNames = <String>[];
  TabController? _tabController;

  /// True when this wapp is the App Creator. Drives a navigation split
  /// where the initial view is just the Projects panel (no tabs) and
  /// the Code / UI / Settings tabs are only revealed after the user
  /// picks or creates a project.
  bool get _isAppCreator => _wappName == 'app-creator';

  /// Editor-mode flag for App Creator. False = show Projects panel
  /// only; true = show Code/UI/Settings tabs with a back arrow.
  bool _editorMode = false;

  /// True when this App Creator page was opened to edit one specific
  /// wapp (via [WappPage.editWappDir] / the per-wapp "Edit" menu). In
  /// that mode the Projects list is never shown and Back leaves the
  /// page entirely instead of returning to Projects.
  bool _singleTargetEdit = false;

  /// Which file the single-wapp editor is currently showing. One of the
  /// [_EditFile.field] keys below ('source' = main.c, 'source_ui' =
  /// home.ui.json) or 'settings' for the metadata form.
  String _activeEditFile = 'source';

  /// TabController for the App Creator editor (Code/UI/Settings).
  /// Created lazily the first time the user enters editor mode so we
  /// don't allocate a controller for the Projects-only view.
  TabController? _editorTabController;

  // Terminal output
  final _outputLines = <_OutputLine>[];
  final _cmdController = TextEditingController();
  final _tickIntervalController = TextEditingController(text: '5000');
  final _scrollController = ScrollController();

  // Wapp Store (install wapp) — search query for filtering cards.
  // Empty string means "show everything".
  String _storeSearch = '';

  // ── App Creator UI editor state ────────────────────────────────
  //
  // The UI tab can either render the raw JSON in a code field
  // ([_uiEditorMode = code]) or walk the parsed block tree and
  // let the user click-to-edit each node in a side panel
  // ([_uiEditorMode = visual]). The visual path operates on a
  // mutable `dynamic` copy of the JSON that is re-serialised back
  // into `_fieldValues['source_ui']` on every mutation so Install
  // always picks up the latest edit.
  _UiEditorMode _uiEditorMode = _UiEditorMode.visual;

  /// Which top-level screen the visual editor is currently showing.
  /// Matches index into the top-level JSON array when `source_ui` is
  /// a list of screens; clamped to a safe value every render.
  int _uiActiveScreenIndex = 0;

  /// Path to the currently-selected block, expressed as a list of
  /// child indices. `[]` means "the screen itself is selected";
  /// `[2]` means "children[2]"; `[2, 0]` means "children[2].children[0]".
  /// Null means nothing is selected.
  List<int>? _uiSelectedPath;

  /// Currently-editing locale on App Creator's Translations tab. The
  /// key-value map for this locale is what the form actually edits;
  /// the inspector pulls straight from
  /// `_fieldValues['translations'][locale]`. Null when no locale is
  /// selected (also when the wapp doesn't have any lang/*.json yet).
  String? _translationsLocale;

  // Structured mirror of the install wapp's sources list, pushed by
  // the wapp on init / after save via {"type":"store.sources"}.
  // Drives the sources manager UI on the Settings tab. Starts as an
  // empty list until the wapp has confirmed its state — _sourcesLoaded
  // flips true the first time a store.sources message arrives so the
  // UI can distinguish "no sources yet" from "still booting".
  List<String> _storeSources = const [];
  bool _sourcesLoaded = false;

  // New-source input state for the sources manager. _sourcesInput
  // is the live text in the URL field; _sourcesError holds the most
  // recent validation failure (cleared on successful Add or edit);
  // _sourcesBusy gates the UI during the async HTTP probe.
  final _sourcesInputController = TextEditingController();
  String _sourcesError = '';
  bool _sourcesBusy = false;

  // Settings bindings
  final _fieldValues = <String, dynamic>{};

  // ── Robot (AI chat) tab state ──────────────────────────────────────
  // Chat lives in a ChangeNotifier so the conversation streams without
  // rebuilding the whole editor. Created lazily the first time the Robot
  // tab is built (see wapp_robot.dart). _robotInput backs the message box.
  RobotChatController? _robot;
  final _robotInput = TextEditingController();

  /// Per-wapp translation context. Loaded from `lang/<locale>.json`
  /// inside the wapp package on mount and refreshed whenever the
  /// user switches language via [LocaleChangedEvent]. Passed to
  /// every [GeoUiScreenRenderer] so `@key` sentinels resolve to the
  /// user's preferred locale. Empty until `_loadWapp` populates it.
  I18nContext _i18n = I18nContext.empty();

  /// Subscription to [LocaleChangedEvent] so the open wapp rebuilds
  /// its translations live on locale change. Cancelled in [dispose].
  EventSubscription<LocaleChangedEvent>? _localeSub;

  // Map state
  double _mapLat = 0, _mapLon = 0;
  int _mapZoom = 2;
  String _tileUrl = 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
  bool _hasMap = false;
  // Pins pushed by the wapp via `ui.map.marker`, keyed by id (e.g. a
  // callsign). Rendered as an overlay by [_SlippyMap]; tapping a pin
  // dispatches a `marker_tap` command back to the wapp.
  final Map<String, Map<String, dynamic>> _mapMarkers = {};

  // Coverage/filter radius + its centre (my station), pushed by the wapp
  // via `ui.map.radius`. Defaults let the circle + slider show before the
  // first connect; the wapp overrides them with the real position.
  double? _mapRadiusKm = 100;
  double? _mapCenterLat = 38.7223;
  double? _mapCenterLon = -9.1393;

  // Geo-chat split into Live (manual) and Beacons (everything automated).
  // APRS has no flag for "human-typed", so we use a marker: a message whose
  // text starts with ">>" is treated as a manual message → Live; all other
  // traffic (position/status/telemetry beacons, auto-replies) → Beacons.
  final List<Map<String, dynamic>> _geoLive = [];
  final List<Map<String, dynamic>> _geoBeacons = [];

  // Transport/status indicators shown on the map, pushed by the wapp via
  // `ui.map.status` (e.g. APRS-IS connected, BLE active). Each {id,label,on}.
  final List<Map<String, dynamic>> _mapStatus = [];

  // Geo-chat panel open/closed (owned here so the unread badge survives tab
  // switches) and the count of Live messages received while it was closed.
  bool _geoChatOpen = true;
  int _geoUnread = 0;

  void _setGeoChatOpen(bool open) {
    if (!mounted) return;
    setState(() {
      _geoChatOpen = open;
      if (open) _geoUnread = 0; // opening clears the Map-tab notification
    });
  }

  void _geoChatAdd(Map raw) {
    final msg = raw.map((k, v) => MapEntry(k.toString(), v));
    final text = (msg['text'] ?? '').toString().trimLeft();
    if (text.startsWith('>>')) {
      // Manual message — drop the ">>" marker for display.
      msg['text'] = text.substring(2).trimLeft();
      _geoLive.add(msg);
      if (_geoLive.length > 300) _geoLive.removeRange(0, _geoLive.length - 300);
      // Notify on the Map tab when a received message lands while the chat box
      // is closed (own outgoing echoes don't count).
      if (msg['dir'] == 'in' && !_geoChatOpen) _geoUnread++;
    } else {
      // Stamp arrival so stale presence/position beacons can be aged out.
      msg['_rxMs'] = DateTime.now().millisecondsSinceEpoch;
      _geoBeacons.add(msg);
      // Drop beacons older than 24h — presence spam shouldn't pile up forever.
      final cutoff =
          DateTime.now().millisecondsSinceEpoch - 24 * 60 * 60 * 1000;
      _geoBeacons.removeWhere((m) {
        final t = m['_rxMs'];
        return t is int && t < cutoff;
      });
      if (_geoBeacons.length > 300) {
        _geoBeacons.removeRange(0, _geoBeacons.length - 300);
      }
    }
  }

  // Generic conversation stores keyed by the GeoUI field name. A wapp drives
  // these via the ui.convo.* protocol; the host renders them with the generic
  // ConversationsField. No app-specific (e.g. APRS) knowledge lives here.
  final Map<String, ConversationStore> _convStores = {};

  ConversationStore _convStore(String field) =>
      _convStores.putIfAbsent(field, () => ConversationStore());

  // Conversation persistence: stores are saved under the wapp data dir as
  // `messages/<field>.json` and reloaded on open, so the Messenger survives a
  // restart. Writes are debounced and coalesced across fields.
  static const String _convDir = 'messages';
  Timer? _convSaveTimer;
  final Set<String> _convDirty = {};

  /// Restore persisted conversation stores from `messages/*.json` (called from
  /// _loadWapp once _wappData is set, before the first build).
  Future<void> _loadConversations() async {
    final data = _wappData;
    if (data == null) return;
    try {
      if (!await data.directoryExists(_convDir)) return;
      for (final entry in await data.listDirectory(_convDir)) {
        if (entry.isDirectory || !entry.path.endsWith('.json')) continue;
        final field = entry.name.substring(0, entry.name.length - 5); // strip .json
        final json = await data.readJson(entry.path);
        if (json != null) {
          _convStores[field] = ConversationStore()..loadJson(json);
        }
      }
    } catch (_) {
      // Corrupt/partial file — start empty rather than blocking the wapp.
    }
  }

  /// Mark a conversation field dirty and schedule a debounced save.
  void _scheduleConvoSave(String field) {
    _convDirty.add(field);
    _convSaveTimer?.cancel();
    _convSaveTimer = Timer(const Duration(milliseconds: 800), _flushConvoSaves);
  }

  Future<void> _flushConvoSaves() async {
    final data = _wappData;
    if (data == null) return;
    final fields = _convDirty.toList();
    _convDirty.clear();
    try {
      await data.createDirectory(_convDir);
      for (final field in fields) {
        final store = _convStores[field];
        if (store == null) continue;
        await data.writeJson('$_convDir/$field.json', store.toJson());
      }
    } catch (_) {
      // Best-effort: re-mark so the next change retries.
      _convDirty.addAll(fields);
    }
  }

  // Cached MonitoredTask snapshot (refreshed when the wapp polls
  // system.tasks.list — see _refreshTaskSnapshot).
  List<MonitoredTask> _taskSnapshot = const [];

  void _refreshTaskSnapshot() {
    _taskSnapshot = TaskMonitorService.instance.tasks;
  }

  /// Return the `List<String>` backing a `$type:"log"` field, creating
  /// it if it does not yet exist. Used by host-side handlers (compile
  /// stub, install stub, ui.log.append) that need to push lines into
  /// a log field without caring whether the renderer has seeded it.
  List<String> _resolveLogBuffer(String fieldName) {
    final existing = _fieldValues[fieldName];
    if (existing is List<String>) return existing;
    final fresh = <String>[];
    _fieldValues[fieldName] = fresh;
    return fresh;
  }

  /// Push a log line into the `output` log field and mark the UI
  /// dirty. Used by the compile/install handlers so their progress
  /// shows up in the App Creator log view without round-tripping
  /// through the wapp.
  void _logLine(String line) {
    _resolveLogBuffer('output').add(line);
    if (mounted) setState(() {});
  }

  /// Append every non-empty line of [blob] individually so multi-line
  /// compiler output renders as separate log entries (easier to read,
  /// works with auto-scroll).
  void _logMultiline(String blob) {
    if (blob.isEmpty) return;
    final buf = _resolveLogBuffer('output');
    for (final line in const LineSplitter().convert(blob)) {
      if (line.isEmpty) continue;
      buf.add(line);
    }
    if (mounted) setState(() {});
  }





  /// Project-picker state for the App Creator Projects tab. `null`
  /// means "haven't scanned yet" — the screen renderer kicks off a
  /// refresh on first build. Subsequent edits to installedAppsStorage
  /// (install, delete) call `_refreshProjects` to pick up changes.
  List<_ProjectEntry>? _projects;
  bool _projectsLoading = false;

  /// Bytes of the currently-loaded wapp's `app.wasm`. Populated by
  /// `_loadProject` so that installing an edited-in-place wapp can
  /// reuse the original compiled binary without round-tripping
  /// through the compiler. Cleared after a successful install (so
  /// subsequent installs fall back to reading from
  /// installedAppsStorage) and after a fresh compile (so the new
  /// bytes take precedence).
  Uint8List? _loadedWasmBytes;













  /// Recursively walk a GeoUI block tree and seed [_fieldValues] with
  /// the right initial value for every `field` descendant. This runs
  /// during `_loadWapp`, BEFORE the widget tree builds, so the
  /// renderers can stay pure reads — they never call `setValue` from
  /// inside a build method.
  ///
  /// - `log` fields get an empty `List<String>` (shared mutable
  ///   buffer between host-side appenders and the LogViewField).
  /// - `int` / `float` fields get their numeric default.
  /// - `bool` fields get their boolean default.
  /// - Every other field (including `code`, `string`, `enum`) gets
  ///   its string default if declared.
  void _seedFieldDefaults(GeoUiBlock block) {
    if (block.keyword == 'field') {
      final name = block.name;
      if (name != null && !_fieldValues.containsKey(name)) {
        final type = block.type ?? 'string';
        if (type == 'log') {
          _fieldValues[name] = <String>[];
        } else if (type == 'chat') {
          _fieldValues[name] = <Map<String, dynamic>>[];
        } else {
          final def = block.decls['default'];
          if (def is GeoUiNumber) {
            _fieldValues[name] = def.value;
          } else if (def is GeoUiBool) {
            _fieldValues[name] = def.value;
          } else if (def is GeoUiString) {
            _fieldValues[name] = def.value;
          }
        }
      }
    }
    for (final child in block.children) {
      _seedFieldDefaults(child);
    }
  }

  @override
  void initState() {
    super.initState();
    // If this wapp is running as a background service, hand it over to this
    // page so only one engine (and one BLE scan) is live while it's open.
    BackgroundWappManager.instance.suspend(_wappName);
    _loadWapp();
  }

  /// Refresh [_i18n] from the wapp package using the currently-
  /// preferred locale. Called once on wapp load and again every
  /// time the user switches language so the change takes effect
  /// without reloading the whole wapp.
  Future<void> _reloadI18n() async {
    final prefs = await PreferencesService.instance();
    final locale = prefs.activeLocale();
    final lang = prefs.activeLanguageCode();
    _i18n = await I18nContext.loadFromPackage(
      _pkg,
      locale: locale,
      languageOnly: lang,
    );
    // Also hand the fresh table to the engine so hal_i18n_get()
    // calls from the wapp code see the same translations as the
    // GeoUI renderer.
    _engine.setI18n(_i18n);
  }

  Future<void> _loadWapp() async {
    // Load the wapp's translation tables first so the screens we're
    // about to parse can resolve their `@key` references right away.
    // On first run this reads `lang/<locale>.json` from the wapp
    // package (e.g. wapps/install/lang/pt_PT.json) and
    // merges the English fallback. Wapps without a `lang/` dir
    // produce an empty context and every string passes through as-
    // authored.
    await _reloadI18n();
    // Live reload on language switch: the Settings row fires
    // LocaleChangedEvent, we rebuild the context and setState so
    // every GeoUiScreenRenderer picks up the new i18n on its next
    // build pass.
    _localeSub = EventBus().on<LocaleChangedEvent>((_) async {
      await _reloadI18n();
      if (mounted) setState(() {});
    });

    // Parse .ui.json screens from the package's screens/ directory.
    if (await _pkg.directoryExists('screens')) {
      final entries = await _pkg.listDirectory('screens');
      for (final entry in entries) {
        if (entry.isDirectory || !entry.path.endsWith('.ui.json')) continue;
        final content = await _pkg.readString(entry.path);
        if (content == null) continue;
        try {
          final parsed = GeoUiParser(content).parse();
          for (final block in parsed.blocks) {
            if (block.keyword == 'screen') {
              _addScreen(block);
            } else if (block.keyword == 'app') {
              for (final child in block.children) {
                if (child.keyword == 'screen') _addScreen(child);
              }
            }
          }
        } catch (_) {}
      }
    }

    // Load field defaults from screens (recursive — fields can live
    // either inside a group card or directly under the screen).
    for (final screen in _screens) {
      // Map screens still carry their viewport knobs on the group block.
      for (final group in screen.childrenOf('group')) {
        if (group.type == 'map') {
          _hasMap = true;
          _mapLat = group.getNumber('default-lat') ?? 0;
          _mapLon = group.getNumber('default-lon') ?? 0;
          _mapZoom = group.getNumber('default-zoom')?.toInt() ?? 12;
          _tileUrl = group.getString('tile-url') ?? _tileUrl;
        }
      }
      _seedFieldDefaults(screen);
    }

    // Build tab controller
    _tabController = TabController(length: _screenNames.length, vsync: this);

    // Set up persistent KV storage under the per-wapp data dir.
    final prefs = await PreferencesService.instance();
    final wappData = wappDataStorageFor(prefs, _wappName);
    await wappData.createDirectory('');
    _wappData = wappData;
    _engine.setStorage(wappData);
    // Restore persisted Messenger conversations before the first build so the
    // history shows immediately when the tab opens.
    await _loadConversations();

    // Seed the install wapp's `source` KV on first run (when the user
    // hasn't set one via the store's own Settings tab). Priority:
    //   1. Host-configured default (PreferencesService.wappStoreSource) so
    //      a deployment can point the store at another catalog without
    //      rebuilding the wasm.
    //   2. The in-repo wapps/binaries/ catalog when running from a source
    //      checkout — resolved from the runtime cwd by probing index.json
    //      across a few candidate layouts (deriving from widget.wappDir was
    //      off by one level after the wapps/archive -> wapps move).
    //   3. Nothing — the wasm's built-in DEFAULT_SOURCE
    //      (https://geogram.radio/wapps) takes over.
    if (_wappName == 'install' && !_engine.hasKvKey('source')) {
      final hostDefault =
          PreferencesService.instanceSync?.wappStoreSource;
      if (hostDefault != null && hostDefault.isNotEmpty) {
        _engine.kvSet('source', hostDefault);
      } else {
        final cwd = platform.currentDirectory();
        final candidates = [
          '$cwd/../wapps/binaries',    // sibling repo (canonical)
          '$cwd/../../wapps/binaries', // nested workspace fallback
          '$cwd/wapps/binaries',       // legacy in-tree
        ];
        for (final candidate in candidates) {
          final binStorage = wappPackageStorage(candidate);
          if (await binStorage.exists('index.json')) {
            _engine.kvSet('source', binStorage.basePath);
            break;
          }
        }
      }
    }

    // Load the WASM binary from the package.
    final wasmBytes = await _pkg.readBytes('app.wasm');
    if (wasmBytes == null) {
      setState(() => _status = 'app.wasm not found');
      EventBus().fire(WappCrashedEvent(
        wappId: _wappName, phase: 'load',
        error: 'app.wasm not found at ${_pkg.basePath}/app.wasm',
      ));
      return;
    }

    try {
      await _engine.load(wasmBytes);
      _engine.init();
      _drainOutbox();

      final interval = _engine.tickIntervalMs;

      // Register this wapp's tick loop with the task monitor.
      TaskMonitorService.instance.register(MonitoredTask(
        id: _tickTaskId,
        name: _wappName,
        description: 'Tick loop for $_wappName',
        serviceName: 'wapps',
        priority: TaskPriority.normal,
        type: TaskType.periodic,
        interval: Duration(milliseconds: interval),
      ));

      _tickTimer = Timer.periodic(Duration(milliseconds: interval), (_) {
        // Honour pause-from-task-monitor: skip the tick body but keep
        // the timer alive so resume just works.
        final task = TaskMonitorService.instance.getTask(_tickTaskId);
        if (task?.status == TaskStatus.paused) return;
        TaskMonitorService.instance.reportStart(_tickTaskId);
        try {
          _engine.tick();
          _drainOutbox();
          TaskMonitorService.instance.reportSuccess(_tickTaskId);
        } catch (e) {
          TaskMonitorService.instance.reportFailure(_tickTaskId, e);
          EventBus().fire(WappCrashedEvent(
            wappId: _wappName, phase: 'tick', error: e,
          ));
        }
      });

      // "Open with…" delivery: hand the chosen file to the module via
      // a file.open message right after init so the wapp can react on
      // its next event pump. The wapp reads `path`/`mode` from its
      // inbox; wapps that don't handle it simply ignore the message.
      final openPath = widget.openFilePath;
      if (openPath != null && openPath.isNotEmpty) {
        _engine.sendMessage(jsonEncode({
          'type': 'file.open',
          'path': openPath,
          'mode': widget.openFileMode,
        }));
        _engine.handleEvent();
        _drainOutbox();
      }

      EventBus().fire(WappLoadedEvent(wappId: _wappName, wappName: _wappName));
      setState(() => _status = 'Running');

      // Per-wapp "Edit" entry: this App Creator page was opened to edit
      // one specific wapp — jump straight into its editor.
      if (_isAppCreator && widget.editWappDir != null) {
        await _autoEditTarget();
      }
    } catch (e) {
      EventBus().fire(WappCrashedEvent(
        wappId: _wappName, phase: 'load', error: e,
      ));
      setState(() => _status = 'Error: $e');
    }
  }

  void _addScreen(GeoUiBlock screen) {
    final name = screen.name ?? 'Screen ${_screens.length}';
    // Deduplicate
    if (_screenNames.any((n) => n.toLowerCase() == name.toLowerCase())) return;
    _screens.add(screen);
    _screenNames.add(name);
  }

  void _drainOutbox() {
    final messages = _engine.drainOutbox();
    if (messages.isEmpty) return;
    var changed = false;
    for (final raw in messages) {
      try {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        final type = data['type'] as String? ?? '';
        if (type == 'ui.append') {
          final item = data['item'] as Map<String, dynamic>? ?? {};
          _outputLines.add(_OutputLine(
            item['text'] as String? ?? '',
            item['level'] as String? ?? 'out',
          ));
          changed = true;
        } else if (type == 'store.sources') {
          // Install wapp push: the current source list straight out
          // of its KV store. Mirror it to _fieldValues['source'] as
          // a newline-joined string so the sources group renderer
          // (and any other reader) sees the same shape the wapp has
          // on disk.
          final list = data['sources'] as List?;
          final asStrings =
              list == null ? <String>[] : list.whereType<String>().toList();
          _fieldValues['source'] = asStrings.join('\n');
          _storeSources = asStrings;
          _sourcesLoaded = true;
          changed = true;
        } else if (type == 'ui.log.append') {
          // Append a single line to a $type:"log" field's buffer.
          // The wapp addresses the target field by name. If the
          // field's backing list doesn't exist yet (first line
          // before the renderer ran) we create it lazily.
          final fieldName = data['field'] as String? ?? 'output';
          final line = data['line'] as String? ?? '';
          final existing = _fieldValues[fieldName];
          final List<String> buf;
          if (existing is List<String>) {
            buf = existing;
          } else {
            buf = <String>[];
            _fieldValues[fieldName] = buf;
          }
          buf.add(line);
          changed = true;
        } else if (type == 'ui.map.viewport') {
          _mapLat = (data['lat'] as num?)?.toDouble() ?? _mapLat;
          _mapLon = (data['lon'] as num?)?.toDouble() ?? _mapLon;
          _mapZoom = (data['zoom'] as num?)?.toInt() ?? _mapZoom;
          changed = true;
        } else if (type == 'ui.map.marker') {
          // Upsert a pin on the map keyed by id (e.g. a callsign). The
          // wapp pushes one of these per position it wants shown; the
          // _SlippyMap overlay renders them. Re-sending the same id
          // moves/relabels the existing pin.
          final id = data['id'] as String? ?? '';
          final lat = (data['lat'] as num?)?.toDouble();
          final lon = (data['lon'] as num?)?.toDouble();
          if (id.isNotEmpty && lat != null && lon != null) {
            _mapMarkers[id] = {
              'id': id,
              'lat': lat,
              'lon': lon,
              'label': data['label'] as String? ?? id,
              if (data['color'] != null) 'color': data['color'],
              if (data['kind'] != null) 'kind': data['kind'],
              if (data['heard'] != null) 'heard': data['heard'],
              if (data['detail'] != null) 'detail': data['detail'],
            };
            changed = true;
          }
        } else if (type == 'ui.map.markers.clear') {
          if (_mapMarkers.isNotEmpty) {
            _mapMarkers.clear();
            changed = true;
          }
        } else if (type == 'ui.map.status') {
          // Replace the transport/status indicators shown on the map. Generic:
          // the wapp supplies labelled on/off items (no app knowledge here).
          final items = data['items'];
          _mapStatus.clear();
          if (items is List) {
            for (final it in items) {
              if (it is Map) {
                _mapStatus.add({
                  'id': (it['id'] ?? '').toString(),
                  'label': (it['label'] ?? '').toString(),
                  'on': it['on'] == true,
                });
              }
            }
          }
          changed = true;
        } else if (type == 'ui.map.radius') {
          // Coverage circle: centre (my station) + filter radius (km).
          _mapCenterLat = (data['lat'] as num?)?.toDouble() ?? _mapCenterLat;
          _mapCenterLon = (data['lon'] as num?)?.toDouble() ?? _mapCenterLon;
          _mapRadiusKm = (data['km'] as num?)?.toDouble() ?? _mapRadiusKm;
          changed = true;
        } else if (type == 'host.run_command') {
          // A wapp self-triggers one of its own commands (e.g. auto-connect
          // on load). Deferred so it runs after this drain, and _sendCommand
          // bundles the current (seeded) field values.
          final c = data['command'] as String?;
          if (c != null && c.isNotEmpty) {
            Future.microtask(() { if (mounted) _sendCommand(c); });
          }
        } else if (type == 'ui.chat.append') {
          // Append one message to a $type:"chat" field's buffer. Each
          // message is a map {dir:'in'|'out', from, text, time}. Backing
          // list is created lazily like ui.log.append.
          final fieldName = data['field'] as String? ?? 'messages';
          final msg = data['message'];
          if (msg is Map) {
            if (fieldName == 'geochat') {
              // Split into Live vs Beacons (repeat detection).
              _geoChatAdd(msg);
            } else {
              final existing = _fieldValues[fieldName];
              final List<Map<String, dynamic>> buf;
              if (existing is List<Map<String, dynamic>>) {
                buf = existing;
              } else {
                buf = <Map<String, dynamic>>[];
                _fieldValues[fieldName] = buf;
              }
              buf.add(msg.map((k, v) => MapEntry(k.toString(), v)));
            }
            changed = true;
          }
        } else if (type == 'ui.chat.clear') {
          final fieldName = data['field'] as String? ?? 'messages';
          if (fieldName == 'geochat') {
            _geoLive.clear();
            _geoBeacons.clear();
            changed = true;
          } else {
            final existing = _fieldValues[fieldName];
            if (existing is List && existing.isNotEmpty) {
              existing.clear();
              changed = true;
            }
          }
        } else if (type == 'ui.convo.upsert') {
          final field = data['field'] as String? ?? 'conversations';
          _convStore(field).upsert(data);
          _scheduleConvoSave(field);
          changed = true;
        } else if (type == 'ui.convo.msg') {
          final field = data['field'] as String? ?? 'conversations';
          _convStore(field).addMessage(data);
          _scheduleConvoSave(field);
          changed = true;
        } else if (type == 'ui.convo.pin') {
          final field = data['field'] as String? ?? 'conversations';
          _convStore(field).pin(data);
          _scheduleConvoSave(field);
          changed = true;
        } else if (type == 'ui.convo.unpin') {
          final field = data['field'] as String? ?? 'conversations';
          _convStore(field).unpin(data);
          _scheduleConvoSave(field);
          changed = true;
        } else if (type == 'ui.convo.clear') {
          final field = data['field'] as String? ?? 'conversations';
          _convStore(field).clear(data['id'] as String?);
          _scheduleConvoSave(field);
          changed = true;
        } else if (type == 'ui.prompt') {
          // Generic prompt: the wapp asks the host to show a dialog (title +
          // optional text input + optional chips) and returns the result as a
          // "prompt" command. No app knowledge here.
          _showWappPrompt(data);
        } else if (type == 'ui.toast') {
          // Legacy message shape — route through the unified service
          // so old wapps inherit system-tray delivery + history.
          NotificationService.instance.show(GeogramNotification(
            level: NotificationLevel.info,
            title: _wappName,
            body: data['message'] as String? ?? '',
            source: 'wapp:$_wappName',
          ));
        } else if (type == 'notify') {
          // New unified notification protocol.
          final levelStr = (data['level'] as String? ?? 'info').toLowerCase();
          final level = switch (levelStr) {
            'success' => NotificationLevel.success,
            'warning' || 'warn' => NotificationLevel.warning,
            'error' || 'err' => NotificationLevel.error,
            _ => NotificationLevel.info,
          };
          final scopeStr = (data['scope'] as String? ?? 'app').toLowerCase();
          final scope = switch (scopeStr) {
            'system' => NotificationScope.system,
            'both' => NotificationScope.both,
            _ => NotificationScope.app,
          };
          NotificationService.instance.show(GeogramNotification(
            level: level,
            title: data['title'] as String? ?? _wappName,
            body: data['body'] as String?,
            source: 'wapp:$_wappName',
            tag: data['tag'] as String?,
            scope: scope,
          ));
        } else if (type == 'wapp.fetch_index') {
          unawaited(_handleFetchIndex(data));
        } else if (type == 'wapp.install') {
          unawaited(_handleWappInstall(data));
        } else if (type == 'system.tasks.list') {
          _refreshTaskSnapshot();
          changed = true;
        } else if (type == 'system.tasks.pause') {
          TaskMonitorService.instance.pause(data['id'] as String? ?? '');
          _refreshTaskSnapshot();
          changed = true;
        } else if (type == 'system.tasks.resume') {
          TaskMonitorService.instance.resume(data['id'] as String? ?? '');
          _refreshTaskSnapshot();
          changed = true;
        } else if (type == 'system.tasks.pause_all') {
          TaskMonitorService.instance.pauseAllNonCritical();
          _refreshTaskSnapshot();
          changed = true;
        } else if (type == 'system.tasks.resume_all') {
          TaskMonitorService.instance.resumeAll();
          _refreshTaskSnapshot();
          changed = true;
        } else if (type == 'system.tasks.governor') {
          // Let the tasks wapp tune the CPU governor at runtime. Any
          // omitted field leaves that setting unchanged.
          TaskMonitorService.instance.configureGovernor(
            enabled: data['enabled'] as bool?,
            threshold: (data['threshold'] as num?)?.toDouble(),
            window: (data['window'] as num?)?.toInt(),
          );
          _refreshTaskSnapshot();
          changed = true;
        } else if (type == 'widget.request') {
          // Caller wapp is requesting a widget. Delegate to the
          // host-side broker which spins up a headless provider
          // engine and delivers the response back to this engine's
          // inbox on the next tick.
          unawaited(FunctionalityBroker.instance.handleRequest(
            callerEngineId: _engine.engineId,
            functionalityId: data['widget'] as String? ?? '',
            reqId: data['req_id'] as String? ?? '',
            args: (data['args'] as Map<String, dynamic>?) ?? const {},
          ));
        } else if (type == 'compile') {
          unawaited(_handleCompile(data));
        } else if (type == 'install') {
          unawaited(_handleInstall(data));
        } else if (type == 'file.pick') {
          // A wapp wants the user to pick a file (e.g. movies'
          // pick_video / pick_subtitle). Show the native picker and
          // deliver the result back as a file.open message.
          unawaited(_handleFilePick(data));
        } else if (type == 'video.load') {
          _handleVideoLoad(data);
          changed = true;
        } else if (type == 'video.subtitle') {
          _handleVideoSubtitle(data);
        } else if (type == 'video.play' ||
            type == 'video.pause' ||
            type == 'video.stop' ||
            type == 'video.seek' ||
            type == 'video.skip') {
          _handleVideoCommand(type, data);
        }
      } catch (_) {}
    }
    if (changed && mounted) {
      setState(() {});
      // Terminal-style wapps tail their log — auto-scroll to the
      // newest line. The Wapp Store (install wapp) reuses the same
      // controller but wants the user to land at the TOP with the
      // featured banner + first cards visible, so we skip the jump
      // there. Any wapp that doesn't want auto-tail can be added
      // to this exclusion list.
      if (_wappName != 'install') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController
                .jumpTo(_scrollController.position.maxScrollExtent);
          }
        });
      }
    }
  }

  Future<void> _handleFetchIndex(Map<String, dynamic> data) async {
    final source = data['source'] as String? ?? '';
    if (source.isEmpty) return;

    // Resolve the source into (dir, file) and wrap the dir in a transient
    // ProfileStorage. The source may be either a directory (implicit
    // index.json) or an explicit path to a .json file.
    String absPath = source;
    if (!absPath.endsWith('.json')) {
      if (!absPath.endsWith('/')) absPath += '/';
      absPath += 'index.json';
    }
    final sep = platform.pathSeparator;
    final slashIdx = absPath.replaceAll(sep, '/').lastIndexOf('/');
    if (slashIdx <= 0) {
      _outputLines.add(_OutputLine('Invalid index path: $absPath', 'err'));
      if (mounted) setState(() {});
      return;
    }
    final dir = absPath.substring(0, slashIdx);
    final file = absPath.substring(slashIdx + 1);
    final dirStorage = wappPackageStorage(dir);

    final content = await dirStorage.readString(file);
    if (content == null) {
      _outputLines.add(_OutputLine('Index not found: $absPath', 'err'));
      if (mounted) setState(() {});
      return;
    }

    try {
      final contents = jsonDecode(content);
      // Enrich every catalog entry with the real publisher_npub
      // from the matching wapp's signature.json. The sibling
      // `wapps/<name>/` layout is the canonical location —
      // that's where the launcher scans built-ins and writes their
      // signatures. We also fall back to `<dir>/<name>/` in case a
      // binaries-style layout placed signature.json alongside the
      // .wapp file. If neither has a signature the entry stays
      // unsigned (empty publisher_npub) and the store card shows
      // the "unknown publisher" state.
      final enriched = _enrichCatalogWithSignatures(contents, dir);
      final msg = jsonEncode({'type': 'wapp.index', 'data': enriched});
      _engine.sendMessage(msg);
      _engine.handleEvent();
      _drainOutbox();
      if (mounted) setState(() {});
    } catch (e) {
      _outputLines.add(_OutputLine('Failed to read index: $e', 'err'));
      if (mounted) setState(() {});
    }
  }

  /// Walk [catalog] (the parsed index.json) and fill in each entry's
  /// `publisher_npub` from the actual wapp's `signature.json` sidecar.
  /// The canonical source tree for built-ins is `wapps/<name>/`;
  /// [indexDir] is the directory of the index.json (e.g. `wapps/binaries/`)
  /// and we look up the signing side at `../archive/<name>/` relative
  /// to it. The fallback path checks `<indexDir>/<name>/` in case the
  /// consumer put signatures next to the binaries.
  dynamic _enrichCatalogWithSignatures(dynamic catalog, String indexDir) {
    if (catalog is! List) return catalog;
    // Compute the two candidate lookup roots once.
    final normalized = indexDir.replaceAll(platform.pathSeparator, '/');
    final parent = normalized.contains('/')
        ? normalized.substring(0, normalized.lastIndexOf('/'))
        : normalized;
    // Built-in wapps live directly under the wapps/ root (the parent of
    // wapps/binaries/), not under a wapps/archive/ subtree — that path
    // went away with the archive->flat move.
    final archiveRoot = parent;
    final result = <dynamic>[];
    for (final rawEntry in catalog) {
      if (rawEntry is! Map<String, dynamic>) {
        result.add(rawEntry);
        continue;
      }
      final entry = Map<String, dynamic>.of(rawEntry);
      final fileField = entry['file'] as String? ?? '';
      // Derive folder name from the "file" path, e.g.
      // "maps/maps-1.0.0.wapp" → "maps".
      final slashIdx = fileField.indexOf('/');
      if (slashIdx > 0) {
        final name = fileField.substring(0, slashIdx);
        final candidates = <String>[
          '$archiveRoot/$name',
          '$indexDir/$name',
        ];
        for (final candidate in candidates) {
          final pkg = wappPackageStorage(candidate);
          if (pkg.existsSync('signature.json')) {
            final npub =
                WappSigningService.instance.readPublisherNpubSync(pkg);
            if (npub.isNotEmpty) {
              entry['publisher_npub'] = npub;
              break;
            }
          }
        }
      }
      result.add(entry);
    }
    return result;
  }

  Future<void> _handleWappInstall(Map<String, dynamic> data) async {
    final source = data['source'] as String? ?? '';
    final filePath = data['file'] as String? ?? '';
    final name = data['name'] as String? ?? '';
    final version = data['version'] as String? ?? '';
    if (source.isEmpty || filePath.isEmpty || name.isEmpty) return;

    // Resolve the source dir (may be a .json path or a plain directory).
    var baseDir = source;
    if (baseDir.endsWith('.json')) {
      final slashIdx = baseDir.replaceAll(platform.pathSeparator, '/').lastIndexOf('/');
      if (slashIdx <= 0) return;
      baseDir = baseDir.substring(0, slashIdx);
    }

    final lowered = baseDir.toLowerCase();
    final isRemote =
        lowered.startsWith('http://') || lowered.startsWith('https://');

    try {
      // Hand the .wapp (ZIP) bytes to the installer service, which
      // extracts, validates app.wasm, records source.json for Reload,
      // signs, and fires WappLoadedEvent so the launcher rescans.
      // Centralising here keeps the store install and the dependency
      // "Install…" flow on the exact same code path.
      final InstallResult result;
      if (isRemote) {
        // Remote catalog (e.g. raw.githubusercontent.com/geograms/wapps/
        // main/binaries): download the .wapp ZIP over HTTP. The store's
        // do_install already rewrote any github tree URL to the raw form,
        // so concatenating dir + file gives the byte URL directly.
        // installFromUrl records a WappSource.url so Reload re-fetches.
        final base = baseDir.endsWith('/')
            ? baseDir.substring(0, baseDir.length - 1)
            : baseDir;
        result = await WappInstallerService.instance.installFromUrl(
          wappId: name,
          url: '$base/$filePath',
        );
      } else {
        final srcStorage = wappPackageStorage(baseDir);
        if (!await srcStorage.exists(filePath)) {
          _outputLines
              .add(_OutputLine('File not found: $baseDir/$filePath', 'err'));
          if (mounted) setState(() {});
          return;
        }
        final archiveBytes = await srcStorage.readBytes(filePath);
        if (archiveBytes == null || archiveBytes.isEmpty) {
          _outputLines.add(
              _OutputLine('Empty or missing .wapp: $filePath', 'err'));
          if (mounted) setState(() {});
          return;
        }
        result = await WappInstallerService.instance.installFromBytes(
          wappId: name,
          zipBytes: Uint8List.fromList(archiveBytes),
          source: WappSource.file('$baseDir/$filePath'),
        );
      }
      if (!result.ok) {
        _outputLines.add(
            _OutputLine(result.error ?? 'Install failed', 'err'));
        if (mounted) setState(() {});
        return;
      }

      // Confirm installation to the module so it updates its KV.
      final confirmMsg = jsonEncode({
        'type': 'wapp.installed',
        'name': name,
        'version': version,
      });
      _engine.sendMessage(confirmMsg);
      _engine.handleEvent();
      _drainOutbox();

      _outputLines.add(_OutputLine('$name v$version installed', 'info'));
      if (mounted) setState(() {});
    } catch (e) {
      _outputLines.add(_OutputLine('Install failed: $e', 'err'));
      if (mounted) setState(() {});
    }
  }

  Future<void> _uninstallWapp(String name) async {
    // Delete via the service so WappUnloadedEvent fires and the
    // launcher drops the tile on its next rescan.
    await WappInstallerService.instance.uninstall(name);
    _sendCommand('remove $name');
    _engine.handleEvent();
    _drainOutbox();
    if (mounted) setState(() {});
  }

  // ── Video bridge (movies wapp `$type:"video"` group) ────────────────

  /// Lazily create a [MediaSession] from the active media.video backend
  /// the first time the wapp asks to load a video. No-op (stays null)
  /// when the mediapack capability isn't installed/supported.
  void _ensureVideoStack() {
    _mediaSession ??= MediaCapabilities.newSession();
  }

  /// {type:"video.load","path":"…","autoplay":true} — open a local file.
  void _handleVideoLoad(Map<String, dynamic> data) {
    final path = (data['path'] as String? ?? '').trim();
    if (path.isEmpty) return;
    _ensureVideoStack();
    final session = _mediaSession;
    if (session == null) return; // capability unavailable
    final autoplay = data['autoplay'] != false;
    // Re-loading the file that's already open just resumes it instead
    // of restarting from scratch.
    if (path == _videoCurrentPath) {
      if (autoplay) session.play();
      return;
    }
    _videoCurrentPath = path;
    session.open(path, autoplay: autoplay);
    if (mounted) setState(() {});
  }

  /// {type:"video.subtitle","path":"…"} — attach an external subtitle.
  void _handleVideoSubtitle(Map<String, dynamic> data) {
    final path = (data['path'] as String? ?? '').trim();
    if (path.isEmpty) return;
    _mediaSession?.setSubtitle(path);
  }

  /// Transport controls: play / pause / stop / seek / skip.
  void _handleVideoCommand(String type, Map<String, dynamic> data) {
    final session = _mediaSession;
    if (session == null) return;
    switch (type) {
      case 'video.play':
        session.play();
        break;
      case 'video.pause':
        session.pause();
        break;
      case 'video.stop':
        session.stop();
        _videoCurrentPath = null;
        if (mounted) setState(() {});
        break;
      case 'video.seek':
        final ms = (data['ms'] as num?)?.toInt();
        if (ms != null) session.seek(Duration(milliseconds: ms));
        break;
      case 'video.skip':
        final deltaMs = (data['ms'] as num?)?.toInt() ?? 0;
        session.skip(Duration(milliseconds: deltaMs));
        break;
    }
  }

  /// {type:"file.pick","extensions":[…],"title":"…","mode":"view"} —
  /// show the native picker and return a file.open to the module.
  Future<void> _handleFilePick(Map<String, dynamic> data) async {
    final extensions = (data['extensions'] as List?)
        ?.map((e) => e.toString().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();
    final title = (data['title'] as String?) ?? 'Pick a file';
    final mode = (data['mode'] as String?) ?? 'view';
    try {
      final typeGroup = XTypeGroup(
        label: title,
        extensions: (extensions != null && extensions.isNotEmpty)
            ? extensions
            : null,
      );
      final XFile? file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file == null) return;
      final path = file.path;
      final dot = path.lastIndexOf('.');
      final ext = dot >= 0 ? path.substring(dot + 1).toLowerCase() : '';
      _engine.sendMessage(jsonEncode({
        'type': 'file.open',
        'path': path,
        'name': file.name,
        'extension': ext,
        'mode': mode,
        'size': -1,
      }));
      _engine.handleEvent();
      _drainOutbox();
    } catch (_) {}
  }

  /// Render a `$type:"video"` screen: the media_kit surface fills the
  /// body; everything else on the screen (the header-actions menu) is
  /// laid over the top-right so the user can still pick a video.
  Widget _buildVideoScreen(GeoUiBlock screen, GeoUiBlock videoGroup) {
    final overlayChildren = screen.children
        .where((c) => !(c.keyword == 'group' && c.type == 'video'))
        .toList();

    Widget? overlay;
    if (overlayChildren.isNotEmpty) {
      overlay = Container(
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(140),
          borderRadius: BorderRadius.circular(28),
        ),
        child: IconTheme(
          data: const IconThemeData(color: Colors.white),
          child: GeoUiScreenRenderer(
            screen: GeoUiBlock(keyword: 'screen', children: overlayChildren),
            bindings:
                _WappFieldBindings(_engine, _fieldValues, () => setState(() {})),
            i18n: _i18n,
            onAction: (action) {
              _engine.sendMessage(
                  jsonEncode({'type': 'action', 'action': action}));
              _engine.handleEvent();
              _drainOutbox();
            },
          ),
        ),
      );
    }

    Widget body;
    final session = _mediaSession;
    if (session != null) {
      // A video is loaded (or about to be) — paint the backend surface.
      final fit = _videoFitFromName(videoGroup.getString('fit') ?? 'contain');
      body = ColoredBox(color: Colors.black, child: session.buildSurface(fit));
    } else if (!MediaCapabilities.backendAvailable) {
      body = _videoPlaceholder(
        Icons.videocam_off_outlined,
        'Video not supported on this platform.',
        'No media backend is available here.',
      );
    } else if (MediaCapabilities.active == null) {
      body = _videoPlaceholder(
        Icons.extension_outlined,
        'Media support not installed.',
        'Install the Mediapack wapp from the Wapp Store to play video.',
      );
    } else {
      body = _videoPlaceholder(
        Icons.movie_outlined,
        'No video loaded.',
        'Use the menu (top-right) to pick a video.',
      );
    }

    if (overlay == null) return body;
    return Stack(
      fit: StackFit.expand,
      children: [
        body,
        Positioned(top: 8, right: 8, child: overlay),
      ],
    );
  }

  BoxFit _videoFitFromName(String name) {
    switch (name) {
      case 'cover':
        return BoxFit.cover;
      case 'fill':
        return BoxFit.fill;
      case 'fitWidth':
        return BoxFit.fitWidth;
      case 'fitHeight':
        return BoxFit.fitHeight;
      case 'none':
        return BoxFit.none;
      case 'scaleDown':
        return BoxFit.scaleDown;
      case 'contain':
      default:
        return BoxFit.contain;
    }
  }

  /// Centered icon + title + subtitle placeholder for the video surface
  /// (no media loaded, capability missing, or platform unsupported).
  Widget _videoPlaceholder(IconData icon, String title, String subtitle) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  void _sendCommand(String cmd) {
    // Bundle a scalar projection of the current field values so the
    // wapp's module_handle_event can read (source, wapp_id, ...) from
    // a single message without round-tripping through a separate save
    // step. Non-scalar entries — primarily the List<String> log
    // buffers — are dropped so we don't ship log history with every
    // action click. Wapps that only read data['command'] ignore the
    // extra "fields" key harmlessly.
    final scalarFields = <String, dynamic>{};
    for (final entry in _fieldValues.entries) {
      final v = entry.value;
      if (v is String || v is num || v is bool) {
        scalarFields[entry.key] = v;
      }
    }
    // Persist settings so a background/headless run of this wapp (autostart)
    // uses the user's configuration rather than bare defaults.
    PreferencesService.instanceSync
        ?.setWappFields(_wappName, jsonEncode(scalarFields));
    _engine.sendMessage(jsonEncode({
      'command': cmd,
      'fields': scalarFields,
    }));
    _engine.handleEvent();
    _drainOutbox();
  }

  // ── Generic conversations primitive ($type:"conversations") ─────────
  // Renders the wapp-owned ConversationStore. Carries no app knowledge:
  // titles/badges/icons/pinned are supplied by the wapp via ui.convo.*, and
  // user intent is forwarded as generic, field-name-derived commands.
  Widget _buildConversationsScreen(GeoUiBlock screen, GeoUiBlock group) {
    final field = group.name ?? 'conversations';
    final store = _convStore(field);
    final listActions = <ConvAction>[];
    final roomActions = <ConvAction>[];
    for (final a in group.childrenOf('action')) {
      final ca = ConvAction(a.name ?? '', a.getString('icon') ?? 'add',
          a.getString('tip') ?? a.name ?? '');
      if ((a.getString('slot') ?? 'list') == 'room') {
        roomActions.add(ca);
      } else {
        listActions.add(ca);
      }
    }
    // Composer toggles: bool field children. State is held in _fieldValues so
    // it rides along with conversations_send like any other scalar field.
    final toggles = <ComposerToggle>[];
    for (final f in group.childrenOf('field')) {
      if (f.type != 'bool') continue;
      final name = f.name ?? '';
      if (name.isEmpty) continue;
      final cur = _fieldValues[name];
      final value = cur is bool ? cur : (f.getBool('default') ?? false);
      _fieldValues[name] = value;
      toggles.add(ComposerToggle(name, f.getString('label') ?? name, value));
    }
    return ConversationsField(
      store: store,
      title: group.getString('label') ?? screen.name ?? 'Conversations',
      listActions: listActions,
      roomActions: roomActions,
      toggles: toggles,
      onToggle: (name, value) => setState(() => _fieldValues[name] = value),
      onLocate: _locateFromMessage,
      onSelect: (id) => setState(() => store.clearUnread(id)),
      onSend: (id, text) {
        _fieldValues['${field}_convo'] = id;
        _fieldValues['${field}_input'] = text;
        _sendCommand('${field}_send');
      },
      onAction: (name, openId) {
        _fieldValues['${field}_convo'] = openId;
        _sendCommand(name);
      },
      onPinnedDismiss: (id, key) {
        _fieldValues['${field}_convo'] = id;
        _fieldValues['${field}_pinkey'] = key;
        _sendCommand('${field}_unpin');
      },
    );
  }

  // Show a chat message's sender on the map: switch to the screen hosting the
  // map and frame the sender's location alongside our own (the radius centre)
  // so the two can be compared. Coordinates come from the message (lat/lon).
  // Highlighted target from the last "locate" tap (drawn as a reticle on the
  // map so the station is unmistakable).
  double? _locateLat, _locateLon;

  void _locateFromMessage(Map<String, dynamic> m) {
    final lat = (m['lat'] as num?)?.toDouble();
    final lon = (m['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return;
    final idx = _screens.indexWhere((s) =>
        s.children.any((c) => c.keyword == 'group' && c.type == 'map'));
    if (idx >= 0 && _tabController != null && _tabController!.index != idx) {
      _tabController!.animateTo(idx);
    }
    // Centre directly on the target and zoom in so it's clearly visible. The
    // zoom adapts to how far the station is from us (closer → tighter) but is
    // clamped to a zoomed-in range so the target is always easy to see.
    final myLat = _mapCenterLat, myLon = _mapCenterLon;
    int zoom = 14;
    if (myLat != null && myLon != null) {
      final span = (max((myLat - lat).abs(), (myLon - lon).abs()) * 2.2) + 0.003;
      zoom = (log(360 * 700 / (256 * span)) / log(2)).clamp(12, 16).floor();
    }
    setState(() {
      _mapLat = lat;
      _mapLon = lon;
      _mapZoom = zoom;
      _locateLat = lat;
      _locateLon = lon;
    });
  }

  // Generic prompt dialog requested by a wapp via ui.prompt. Shows a title,
  // optional body, optional chips (single-select), and an optional text
  // input, then returns the result as a "prompt" command with fields
  // prompt_id / prompt_value / prompt_input. No app knowledge here.
  void _showWappPrompt(Map<String, dynamic> data) {
    final id = (data['id'] ?? '').toString();
    final title = (data['title'] ?? '').toString();
    final body = (data['body'] ?? '').toString();
    final chips = (data['chips'] as List?)
            ?.whereType<Map>()
            .map((c) => MapEntry(
                (c['label'] ?? '').toString(), (c['value'] ?? '').toString()))
            .toList() ??
        const <MapEntry<String, String>>[];
    final instant = (data['chipMode'] ?? 'instant') == 'instant';
    final input = data['input'] as Map?;
    final confirmLabel = (data['confirm'] ?? '').toString();

    final controller = TextEditingController();
    void result(String value, String text) {
      _fieldValues['prompt_id'] = id;
      _fieldValues['prompt_value'] = value;
      _fieldValues['prompt_input'] = text;
      _sendCommand('prompt');
    }

    showDialog<void>(
      context: context,
      builder: (ctx) {
        String selected = '';
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final cs = Theme.of(ctx).colorScheme;
            return AlertDialog(
              title: Text(title),
              content: SizedBox(
                width: 380,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (body.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(body,
                            style: TextStyle(
                                color: cs.onSurfaceVariant, fontSize: 12.5)),
                      ),
                    if (chips.isNotEmpty)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final c in chips)
                            instant
                                ? ActionChip(
                                    label: Text(c.key),
                                    onPressed: () {
                                      Navigator.pop(ctx);
                                      result(c.value, '');
                                    },
                                  )
                                : ChoiceChip(
                                    label: Text(c.key),
                                    selected: selected == c.value,
                                    onSelected: (_) =>
                                        setLocal(() => selected = c.value),
                                  ),
                        ],
                      ),
                    if (input != null) ...[
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: controller,
                              autofocus: true,
                              maxLength: (input['max'] as num?)?.toInt(),
                              textCapitalization: TextCapitalization.sentences,
                              decoration: InputDecoration(
                                hintText: (input['hint'] ?? '').toString(),
                                prefixText: (input['prefix'] ?? '').toString(),
                                border: const OutlineInputBorder(),
                                isDense: true,
                                counterText: '',
                              ),
                              onSubmitted: (t) {
                                if (t.trim().isEmpty && selected.isEmpty) return;
                                Navigator.pop(ctx);
                                result(selected, t.trim());
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel')),
                if (confirmLabel.isNotEmpty)
                  FilledButton(
                    onPressed: () {
                      final t = controller.text.trim();
                      if (t.isEmpty && selected.isEmpty) return;
                      Navigator.pop(ctx);
                      result(selected, t);
                    },
                    child: Text(confirmLabel),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    // Flush any pending conversation writes so the latest messages aren't lost.
    _convSaveTimer?.cancel();
    if (_convDirty.isNotEmpty) unawaited(_flushConvoSaves());
    TaskMonitorService.instance.unregister(_tickTaskId);
    EventBus().fire(WappUnloadedEvent(wappId: _wappName, wappName: _wappName));
    _localeSub?.cancel();
    // Tear down the media session if the video group was used.
    _mediaSession?.dispose();
    _mediaSession = null;
    _videoCurrentPath = null;
    _engine.dispose();
    // Page closed: restart the background service if the user enabled autostart
    // for this wapp (so it keeps receiving once its engine ref is released).
    unawaited(BackgroundWappManager.instance.resume(widget.wappDir));
    _cmdController.dispose();
    _scrollController.dispose();
    _sourcesInputController.dispose();
    _robot?.dispose();
    _robotInput.dispose();
    _tabController?.dispose();
    _editorTabController?.dispose();
    super.dispose();
  }

  /// A tab label, with an unread-count badge on the map screen's tab when
  /// geo-chat messages have arrived while the chat box was closed.
  Widget _buildScreenTab(String name, GeoUiBlock screen) {
    final label = _i18n.resolve(name);
    final isMap =
        screen.children.any((c) => c.keyword == 'group' && c.type == 'map');
    if (!isMap || _geoUnread <= 0) return Tab(text: label);
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            constraints: const BoxConstraints(minWidth: 18),
            decoration: BoxDecoration(
              color: const Color(0xFFda3633),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              _geoUnread > 99 ? '99+' : '$_geoUnread',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_tabController == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Center(child: Text(_status)),
      );
    }

    if (_isAppCreator) {
      // Opened to edit one specific wapp (the per-wapp Edit menu): show
      // the full editor (Code / UI / Translations / Settings tabs) with
      // the Projects tab filtered out — same scaffold as the App Creator
      // editor, just titled "Edit — <wapp>" and with a "Done" back arrow.
      if (_singleTargetEdit) return _buildAppCreatorEditor();
      return _editorMode
          ? _buildAppCreatorEditor()
          : _buildAppCreatorProjects();
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [_buildWappOptionsMenu()],
        bottom: _screenNames.length > 1
            ? TabBar(
                controller: _tabController,
                tabs: [
                  for (var i = 0; i < _screenNames.length; i++)
                    _buildScreenTab(_screenNames[i], _screens[i]),
                ],
                isScrollable: true,
              )
            : null,
      ),
      body: TabBarView(
        controller: _tabController,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (var i = 0; i < _screens.length; i++)
            _buildScreen(_screens[i]),
        ],
      ),
    );
  }

  /// Top-right three-line options menu shown on an open wapp. Currently
  /// just "Edit" (opens the App Creator focused on this wapp); built as
  /// a menu so more per-wapp options can be added later.
  Widget _buildWappOptionsMenu() {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.menu),
      tooltip: 'Options',
      onSelected: (value) {
        if (value == 'edit') _editThisWapp();
      },
      itemBuilder: (_) => const [
        PopupMenuItem<String>(
          value: 'edit',
          child: ListTile(
            leading: Icon(Icons.edit),
            title: Text('Edit'),
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        ),
      ],
    );
  }




  Widget _buildScreen(GeoUiBlock screen) {
    // Check if this screen has a map group
    final mapGroup = screen.children
        .where((c) => c.keyword == 'group' && c.type == 'map')
        .firstOrNull;
    if (mapGroup != null) return _buildMapScreen(screen, mapGroup);

    // Conversations (generic, data-driven messenger primitive) — host renders
    // the contact list + chat view from the wapp-pushed ConversationStore.
    final convoGroup = screen.children
        .where((c) => c.keyword == 'group' && c.type == 'conversations')
        .firstOrNull;
    if (convoGroup != null) return _buildConversationsScreen(screen, convoGroup);

    // Video group (movies wapp) — host renders the media_kit surface
    // with the screen's other children (the header-actions menu) as an
    // overlay so pick_video / pick_subtitle stay reachable.
    final videoGroup = screen.children
        .where((c) => c.keyword == 'group' && c.type == 'video')
        .firstOrNull;
    if (videoGroup != null) return _buildVideoScreen(screen, videoGroup);

    // Tasks viewer — host renders cards from the cached MonitoredTask
    // snapshot kept in _taskSnapshot, refreshed each time the wapp polls.
    final hasTasksGroup = screen.children.any((c) =>
        c.keyword == 'group' && c.type == 'tasks');
    if (hasTasksGroup) {
      return _buildTasksScreen();
    }

    // Projects picker (App Creator) — host renders a list of installed
    // wapps so the user can pick one to edit or start a new one.
    final hasProjectsGroup = screen.children.any((c) =>
        c.keyword == 'group' && c.type == 'projects');
    if (hasProjectsGroup) {
      return _buildProjectsScreen();
    }

    // Output-only screen (e.g. Shop catalog) — no command input
    final hasOutputGroup = screen.children.any((c) =>
        c.keyword == 'group' && c.type == 'output');
    if (hasOutputGroup) {
      return _buildOutputScreen();
    }

    // Functionalities browser — system wapp that lists all registered
    // functionalities, their providers, and lets the user pick defaults.
    final hasFunctionalitiesGroup = screen.children.any((c) =>
        c.keyword == 'group' && c.type == 'functionalities');
    if (hasFunctionalitiesGroup) {
      return _buildFunctionalitiesScreen();
    }

    // Sources manager — install wapp's Settings tab. Shows the
    // current repository list (pushed by the wapp via store.sources)
    // with add+remove affordances and URL validation.
    final hasSourcesGroup = screen.children.any((c) =>
        c.keyword == 'group' && c.type == 'sources');
    if (hasSourcesGroup) {
      return _buildSourcesScreen();
    }

    // UI editor — App Creator's UI tab. A split Code/Visual editor
    // that lets the author click-to-edit GeoUI blocks or drop into
    // raw JSON. Bound to `_fieldValues['source_ui']`.
    final hasUiEditorGroup = screen.children.any((c) =>
        c.keyword == 'group' && c.type == 'ui-editor');
    if (hasUiEditorGroup) {
      return _buildUiEditorScreen();
    }

    // Tests — App Creator's Tests tab. Custom panel that lists the
    // edited wapp's test cases and runs them (see _buildTestsScreen).
    // Only in the editor; the generic Tests screen (button + log) is
    // replaced by the richer panel.
    if (_isAppCreator &&
        ((screen.name ?? '') == 'Tests' ||
            screen.children.any(
                (c) => c.keyword == 'action' && c.name == 'run-tests'))) {
      return _buildTestsScreen();
    }

    // Robot — App Creator's AI chat tab. A configurable (offline/online)
    // assistant that proposes edits to the wapp's files. See wapp_robot.dart.
    final hasRobotGroup = screen.children.any((c) =>
        c.keyword == 'group' && c.type == 'robot');
    if (hasRobotGroup) {
      return _buildRobotScreen();
    }

    // Translations editor — App Creator's Translations tab. Edits
    // the wapp's `lang/<locale>.json` sidecars as a flat key-value
    // table per locale; the install pipeline ships whichever locales
    // the author filled in.
    // The Translations screen in home.ui.json carries only a generic
    // `$type:"split"` group — same as the Files screen — so a type check
    // can't tell them apart and it used to fall through to the Files
    // editor. Disambiguate by the (non-localized) screen name. The
    // `contains` also matches an `@screen.translations` i18n sentinel.
    final hasTranslationsGroup = screen.children.any((c) =>
            c.keyword == 'group' && c.type == 'translations') ||
        (screen.name ?? '').toLowerCase().contains('translation');
    if (hasTranslationsGroup) {
      return _buildTranslationsScreen();
    }

    // Terminal screen — has output + command input
    final hasTerminal = screen.children.any((c) =>
        c.keyword == 'group' &&
        c.children.any((gc) => gc.keyword == 'watch'));
    if (hasTerminal) {
      return _buildTerminalScreen();
    }

    // Files screen (App Creator) — a `$type:"split"` group. Render the
    // proper file-list + full-height code editor instead of falling
    // through to the Settings form (which is the wrong UI and overflows
    // because of its fixed-height identity box).
    final hasSplit = screen.children
        .any((c) => c.keyword == 'group' && c.type == 'split');
    if (hasSplit) return _filesEditorBody();

    // Settings-like screen — use GeoUI renderer
    return _buildSettingsScreen(screen);
  }

  // ── Tasks viewer ──────────────────────────────────────────────────

  Widget _buildTasksScreen() {
    final cs = Theme.of(context).colorScheme;
    final tasks = _taskSnapshot;

    final running =
        tasks.where((t) => t.status == TaskStatus.running).length;
    final idle = tasks.where((t) => t.status == TaskStatus.idle).length;
    final paused = tasks.where((t) => t.status == TaskStatus.paused).length;
    final errored = tasks.where((t) => t.status == TaskStatus.error).length;

    return Column(
      children: [
        // Header summary + bulk actions
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: cs.outlineVariant.withAlpha(80)),
            ),
          ),
          child: Row(
            children: [
              _StatusPill(
                  label: 'running', count: running, color: Colors.green),
              const SizedBox(width: 6),
              _StatusPill(label: 'idle', count: idle, color: cs.primary),
              const SizedBox(width: 6),
              _StatusPill(
                  label: 'paused', count: paused, color: Colors.amber),
              const SizedBox(width: 6),
              _StatusPill(label: 'error', count: errored, color: cs.error),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _sendCommand('pause-all'),
                icon: const Icon(Icons.pause_circle, size: 18),
                label: const Text('Pause all'),
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact),
              ),
              TextButton.icon(
                onPressed: () => _sendCommand('resume-all'),
                icon: const Icon(Icons.play_circle, size: 18),
                label: const Text('Resume all'),
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact),
              ),
            ],
          ),
        ),
        Expanded(
          child: tasks.isEmpty
              ? const Center(
                  child: Text('No tasks registered yet.',
                      style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  itemCount: tasks.length,
                  itemBuilder: (context, i) => _buildTaskCard(tasks[i], cs),
                ),
        ),
      ],
    );
  }

  Widget _buildTaskCard(MonitoredTask task, ColorScheme cs) {
    final statusColor = switch (task.status) {
      TaskStatus.running => Colors.green,
      TaskStatus.idle => cs.primary,
      TaskStatus.paused => Colors.amber,
      TaskStatus.error => cs.error,
    };
    final priorityColor = switch (task.priority) {
      TaskPriority.critical => cs.error,
      TaskPriority.normal => cs.primary,
      TaskPriority.low => cs.onSurfaceVariant,
    };
    final bootColor = switch (task.bootStart) {
      BootStart.sequential => Colors.deepOrange,
      BootStart.parallel => Colors.cyan,
      BootStart.none => cs.onSurfaceVariant,
    };
    final isCritical = task.priority == TaskPriority.critical;
    final isPaused = task.status == TaskStatus.paused;
    final lastMs = task.lastDuration?.inMilliseconds;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
      ),
      color: cs.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title row: name + pills
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(task.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14)),
                      const SizedBox(height: 2),
                      Text(task.id,
                          style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
                _MiniPill(label: task.status.name, color: statusColor),
                const SizedBox(width: 4),
                _MiniPill(label: task.priority.name, color: priorityColor),
                const SizedBox(width: 4),
                _MiniPill(
                    label: task.type.name, color: cs.onSurfaceVariant),
                if (task.bootStart != BootStart.none) ...[
                  const SizedBox(width: 4),
                  _MiniPill(
                      label: 'boot:${task.bootStart.name}',
                      color: bootColor),
                ],
              ],
            ),
            const SizedBox(height: 8),
            // Stats
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _Stat(label: 'service', value: task.serviceName),
                _Stat(label: 'runs', value: '${task.runCount}'),
                _Stat(label: 'ok', value: '${task.successCount}'),
                _Stat(label: 'fail', value: '${task.failCount}'),
                if (lastMs != null)
                  _Stat(label: 'last', value: '${lastMs}ms'),
                _Stat(label: 'cpu', value: '${task.totalCpuMs}ms'),
                if (task.interval != null)
                  _Stat(
                      label: 'every',
                      value: '${task.interval!.inMilliseconds}ms'),
              ],
            ),
            if (task.lastError != null) ...[
              const SizedBox(height: 6),
              Text(task.lastError!,
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: cs.error)),
            ],
            const SizedBox(height: 8),
            // Actions
            Row(
              children: [
                if (!isCritical && !isPaused)
                  TextButton.icon(
                    onPressed: () => _sendCommand('pause ${task.id}'),
                    icon: const Icon(Icons.pause, size: 16),
                    label: const Text('Pause'),
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                  ),
                if (isPaused)
                  TextButton.icon(
                    onPressed: () => _sendCommand('resume ${task.id}'),
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('Resume'),
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                  ),
                const Spacer(),
                if (isCritical)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('critical — cannot pause',
                        style: TextStyle(
                            fontSize: 11, color: cs.onSurfaceVariant)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Output-only screen (Shop catalog) ──────────────────────────────







  // ── Palette ─────────────────────────────────────────────────────




  // ── Canvas ──────────────────────────────────────────────────────








  // ── Drop handling ──────────────────────────────────────────────




  /// Deep clone a JSON-shaped map so palette templates are inserted
  /// as independent instances. `jsonDecode(jsonEncode(x))` is the
  /// canonical way to deep-copy a JSON value in Dart.
  Map<String, dynamic> _deepClone(Map<String, dynamic> source) {
    return jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
  }

  // ── Inspector (right pane) ─────────────────────────────────────





  // ── Translations editor ───────────────────────────────────────




  /// Convert whatever's sitting in `_fieldValues['translations']`
  /// into the strongly-typed shape the installer expects. Returns
  /// null when there's nothing usable so the installer can skip
  /// the lang/ write path entirely.
  Map<String, Map<String, String>>? _coerceTranslations(dynamic raw) {
    if (raw is Map<String, Map<String, String>>) {
      return raw.isEmpty ? null : raw;
    }
    if (raw is Map) {
      final out = <String, Map<String, String>>{};
      for (final e in raw.entries) {
        final loc = e.key.toString();
        final inner = e.value;
        if (inner is Map) {
          final map = <String, String>{};
          for (final kv in inner.entries) {
            map[kv.key.toString()] = kv.value?.toString() ?? '';
          }
          if (map.isNotEmpty) out[loc] = map;
        }
      }
      return out.isEmpty ? null : out;
    }
    return null;
  }















  Widget _buildSourcesScreen() {
    final cs = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Header.
        Text(
          'Repositories',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          'The wapp store downloads its catalog from every repository '
          'listed here. New entries are validated — only URLs that '
          'reply with a valid /wapps/index.json are accepted.',
          style: TextStyle(color: cs.onSurfaceVariant, height: 1.35),
        ),
        const SizedBox(height: 20),

        // Existing repositories list.
        if (!_sourcesLoaded)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_storeSources.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: cs.outlineVariant.withAlpha(80)),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: cs.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'No repositories yet. Add one below to see wapps '
                    'in the Store tab.',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          )
        else
          for (var i = 0; i < _storeSources.length; i++)
            _buildSourceRow(_storeSources[i], i, cs),

        const SizedBox(height: 24),

        // Add new.
        Text(
          'Add a repository',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: cs.outlineVariant.withAlpha(80)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _sourcesInputController,
                      enabled: !_sourcesBusy,
                      decoration: InputDecoration(
                        hintText: 'https://example.com',
                        prefixIcon: const Icon(Icons.link, size: 20),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _addSource(),
                      onChanged: (_) {
                        if (_sourcesError.isNotEmpty) {
                          setState(() => _sourcesError = '');
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: _sourcesBusy ? null : _addSource,
                    icon: _sourcesBusy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add, size: 18),
                    label: const Text('Add'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 14),
                    ),
                  ),
                ],
              ),
              if (_sourcesError.isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(Icons.error_outline, size: 16, color: cs.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _sourcesError,
                        style: TextStyle(fontSize: 12, color: cs.error),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'The store will try <url>/wapps/index.json first, then '
                '<url>/index.json. For local paths, pass the directory '
                'that contains the index.',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// One row inside the repositories list — shows the host chip,
  /// the raw URL in monospace, and a red remove button.
  Widget _buildSourceRow(String url, int index, ColorScheme cs) {
    final host = _extractHostForDisplay(url);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant.withAlpha(80)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.cloud_outlined,
                size: 20, color: cs.onPrimaryContainer),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  host,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  url,
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant,
                    fontFamily: 'monospace',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _sourcesBusy ? null : () => _removeSource(index),
            icon: Icon(Icons.delete_outline, color: cs.error),
            tooltip: 'Remove',
          ),
        ],
      ),
    );
  }

  /// Human-readable host extracted from a URL / path. Mirrors the
  /// wapp's own `extract_host` behaviour so chips look the same on
  /// both sides.
  String _extractHostForDisplay(String url) {
    var p = url;
    if (p.startsWith('https://')) {
      p = p.substring(8);
    } else if (p.startsWith('http://')) {
      p = p.substring(7);
    } else {
      return 'local';
    }
    final end = p.indexOf(RegExp(r'[/:?]'));
    return end < 0 ? p : p.substring(0, end);
  }

  /// Kick off the Add flow: validate the URL, and if it passes,
  /// append it to [_storeSources] and push the new list to the wapp.
  Future<void> _addSource() async {
    final raw = _sourcesInputController.text.trim();
    if (raw.isEmpty) return;
    if (_storeSources.contains(raw)) {
      setState(() => _sourcesError = 'This repository is already in the list.');
      return;
    }
    setState(() {
      _sourcesBusy = true;
      _sourcesError = '';
    });
    try {
      final resolved = await _validateSource(raw);
      if (resolved == null) {
        if (mounted) {
          setState(() {
            _sourcesBusy = false;
            _sourcesError =
                'Could not find a valid index.json at this URL. '
                'Check the address and try again.';
          });
        }
        return;
      }
      if (_storeSources.contains(resolved)) {
        if (mounted) {
          setState(() {
            _sourcesBusy = false;
            _sourcesError =
                'This repository is already in the list (as $resolved).';
          });
        }
        return;
      }
      final next = [..._storeSources, resolved];
      _pushSources(next);
      if (mounted) {
        _sourcesInputController.clear();
        setState(() {
          _sourcesBusy = false;
          _sourcesError = '';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _sourcesBusy = false;
          _sourcesError = 'Validation failed: $e';
        });
      }
    }
  }

  /// Drop the entry at [index] from [_storeSources] and push the
  /// shorter list back to the wapp. The wapp will echo the new
  /// store.sources and trigger a catalog refresh.
  void _removeSource(int index) {
    if (index < 0 || index >= _storeSources.length) return;
    final next = [..._storeSources];
    next.removeAt(index);
    _pushSources(next);
  }

  /// Send the authoritative sources list back to the wapp as a
  /// `set_sources` action. The wapp persists, re-parses, re-fetches,
  /// and echoes store.sources so this widget rebuilds with the
  /// confirmed state.
  void _pushSources(List<String> next) {
    _fieldValues['source'] = next.join('\n');
    setState(() => _storeSources = next);
    _engine.sendMessage(jsonEncode({
      'type': 'action',
      'action': 'set_sources',
      'fields': {'source': next.join('\n')},
    }));
    _engine.handleEvent();
    _drainOutbox();
  }

  /// Probe [raw] for a valid wapp index. Tries `<raw>/wapps/index.json`
  /// first, falls back to `<raw>/index.json`, and finally accepts the
  /// bare URL if it already points at a `.json` file. Returns the
  /// normalised URL that will be stored on success, or null on
  /// failure. Local paths are checked via filesystem I/O.
  Future<String?> _validateSource(String raw) async {
    final lowered = raw.toLowerCase();
    final isUrl = lowered.startsWith('http://') || lowered.startsWith('https://');
    if (isUrl) {
      // Build candidate URLs to try in priority order.
      final trimmed = raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
      final candidates = <String>[];
      if (lowered.endsWith('.json')) {
        candidates.add(raw);
      } else {
        candidates.add('$trimmed/wapps/index.json');
        candidates.add('$trimmed/index.json');
      }
      for (final candidate in candidates) {
        if (await _probeJsonUrl(candidate)) {
          // Store the candidate that worked — the wapp uses it as-is
          // because it ends with .json.
          return candidate;
        }
      }
      return null;
    }
    // Local filesystem candidates. Skipped entirely on web — the
    // browser has no filesystem so a local path here is nonsense.
    if (kIsWeb) return null;
    final candidates = <String>[];
    if (lowered.endsWith('.json')) {
      candidates.add(raw);
    } else {
      final base =
          raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
      candidates.add('$base/wapps/index.json');
      candidates.add('$base/index.json');
    }
    for (final candidate in candidates) {
      try {
        final bytes = platform.readArbitraryFileBytesSync(candidate);
        if (bytes == null) continue;
        final contents = utf8.decode(bytes);
        try {
          final parsed = jsonDecode(contents);
          if (parsed is List) return candidate;
        } catch (_) {}
      } catch (_) {}
    }
    return null;
  }

  /// Fetch [url] and return true if it responds 200 with a JSON array
  /// body. Goes through the connections internet transport so the same
  /// code runs on desktop and web. Six-second deadline matches the
  /// previous implementation.
  Future<bool> _probeJsonUrl(String url) async {
    try {
      final resp = await HttpTransport.shared
          .get(Uri.parse(url), timeout: const Duration(seconds: 6));
      if (!resp.isOk) return false;
      final parsed = jsonDecode(resp.bodyString);
      return parsed is List;
    } catch (_) {
      return false;
    }
  }

  Widget _buildOutputScreen() {
    // Parse output lines into wapp entries for card display. The wapp's
    // main.c still speaks a text-log protocol, so we regex-lift the
    // structured catalog rows out of it on the host side. Format:
    //   [info] N wapp(s) available:
    //   [out]   name            vX.Y.Z  (NKB)  [installed] or [update: ...]
    //   [out]     Description text
    //   [out]     @host.example.com       <- optional source chip
    //   [out]     by:npub1…              <- optional publisher chip
    //
    // The description / host / publisher lines all use a 4-space
    // indent and are attached to the most recently emitted wapp
    // entry. That lets the wapp emit them in any order without
    // needing a strict grammar on the host side.
    final wapps = <_CatalogWapp>[];
    final errors = <String>[];

    for (var i = 0; i < _outputLines.length; i++) {
      final line = _outputLines[i];
      final text = line.text;

      final match = RegExp(r'^\s{2}(\S+)\s+v(\S+)(?:\s+\(([^)]+)\))?(.*)$')
          .firstMatch(text);
      if (match != null && line.level == 'out') {
        final name = match.group(1)!;
        final version = match.group(2)!;
        final size = match.group(3) ?? '';
        final status = match.group(4)?.trim() ?? '';

        final actuallyInstalled = _installed.existsSync('$name/app.wasm');

        wapps.add(_CatalogWapp(
          name: name,
          version: version,
          size: size,
          installed: actuallyInstalled,
          updateAvailable: status.contains('[update:'),
        ));
        continue;
      }

      // Metadata line attached to the previously-added wapp. The
      // four-space indent is the wapp's way of saying "this belongs
      // to the entry above me".
      if (line.level == 'out' &&
          text.startsWith('    ') &&
          wapps.isNotEmpty) {
        final meta = text.trimLeft();
        final last = wapps.last;
        if (meta.startsWith('@')) {
          last.sourceHost = meta.substring(1);
        } else if (meta.startsWith('by:')) {
          last.publisherNpub = meta.substring(3);
        } else if (last.description.isEmpty) {
          last.description = meta;
        }
        continue;
      }

      if (line.level == 'err') {
        errors.add(text);
      }
    }

    // Enrich catalog entries with NDF store metadata.
    for (final wapp in wapps) {
      _enrichCatalogWapp(wapp);
    }

    final cs = Theme.of(context).colorScheme;
    final source = (_fieldValues['source'] as String?) ?? '';
    final query = _storeSearch.toLowerCase();
    final visibleWapps = query.isEmpty
        ? wapps
        : wapps
            .where((w) =>
                w.name.toLowerCase().contains(query) ||
                w.description.toLowerCase().contains(query))
            .toList();

    final hasCatalog = wapps.isNotEmpty;

    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        // Store header — search + refresh + source chip. Pinned so it
        // stays visible while the catalog scrolls.
        // Plain adapter rather than a pinned persistent header — the
        // latter requires a fixed extent that Flutter's layout engine
        // clamps against the child's paintExtent, and any mismatch
        // throws "layoutExtent exceeds paintExtent" which tears down
        // the whole CustomScrollView before any card can render.
        // Losing the pin-on-scroll behaviour is a fair trade for a
        // store view that actually shows content.
        SliverToBoxAdapter(
          child: _buildStoreHeader(cs, total: wapps.length),
        ),

        // Featured banner for the first catalog entry — a little
        // Play-Store-flavoured spotlight on what's "new" in the repo.
        if (hasCatalog)
          SliverToBoxAdapter(
            child: _buildFeaturedCard(wapps.first, cs),
          ),

        // Error strip — only shown when the wapp emitted [err] lines.
        if (errors.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.errorContainer.withAlpha(120),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.error.withAlpha(120)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.error_outline, size: 18, color: cs.error),
                      const SizedBox(width: 8),
                      Text('Something went wrong',
                          style: TextStyle(
                              color: cs.onErrorContainer,
                              fontWeight: FontWeight.w600)),
                    ]),
                    const SizedBox(height: 6),
                    for (final err in errors)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(err,
                            style: TextStyle(
                                color: cs.onErrorContainer, fontSize: 12)),
                      ),
                  ],
                ),
              ),
            ),
          ),

        // Section heading above the list.
        if (hasCatalog)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Row(
                children: [
                  Text(
                    query.isEmpty ? 'All apps' : 'Results',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${visibleWapps.length}',
                      style: TextStyle(
                        color: cs.onPrimaryContainer,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

        // Empty / error states.
        if (!hasCatalog)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _buildStoreEmptyState(cs, source: source),
          )
        else if (visibleWapps.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  'No wapps match "$_storeSearch"',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverGrid(
              gridDelegate:
                  const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.45,
              ),
              delegate: SliverChildBuilderDelegate(
                (_, i) => _buildWappCard(visibleWapps[i], cs),
                childCount: visibleWapps.length,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildStoreHeader(
    ColorScheme cs, {
    required int total,
  }) {
    return Container(
      color: cs.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: cs.outlineVariant.withAlpha(80)),
              ),
              child: TextField(
                textInputAction: TextInputAction.search,
                onChanged: (v) => setState(() => _storeSearch = v),
                decoration: InputDecoration(
                  hintText: 'Search wapps',
                  prefixIcon:
                      Icon(Icons.search, color: cs.onSurfaceVariant),
                  suffixIcon: _storeSearch.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _storeSearch = ''),
                        ),
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: cs.surfaceContainerHigh,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () {
                _sendCommand('list');
                _engine.handleEvent();
                _drainOutbox();
              },
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Icon(Icons.refresh, color: cs.primary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStoreEmptyState(ColorScheme cs, {required String source}) {
    final hasSource = source.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(28),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.storefront, size: 56, color: cs.primary),
          ),
          const SizedBox(height: 20),
          Text(
            hasSource ? 'Loading catalog…' : 'No repository configured',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            hasSource
                ? 'Fetching index.json from your repository. Use '
                    'Refresh above if the list stays empty.'
                : 'Set a repository URL or local path in the Settings tab, '
                    'then pull to refresh to see the wapps available for '
                    'install.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
          ),
          if (!hasSource) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () {
                if (_tabController != null) _tabController!.animateTo(1);
              },
              icon: const Icon(Icons.settings, size: 18),
              label: const Text('Open settings'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFeaturedCard(_CatalogWapp wapp, ColorScheme cs) {
    final color = _storeCardColor(wapp.name);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              color.withAlpha(180),
              color.withAlpha(90),
            ],
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(40),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withAlpha(90)),
              ),
              alignment: Alignment.center,
              child: _storeIconWidget(wapp.name, size: 40),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Featured',
                    style: TextStyle(
                      color: Colors.white.withAlpha(200),
                      fontSize: 11,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    wapp.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (wapp.description.isNotEmpty)
                    Text(
                      wapp.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withAlpha(230),
                        fontSize: 13,
                        height: 1.3,
                      ),
                    ),
                  const SizedBox(height: 10),
                  _storeActionButton(wapp, cs, dark: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Enrich a catalog wapp with NDF store metadata — reads
  /// `store/description.json` and `social.sqlite3` from the wapp
  /// package (installed copy or built-in archive).
  void _enrichCatalogWapp(_CatalogWapp wapp) {
    // Resolve the wapp's own package storage — installed copy first,
    // then built-in archive. Never fall back to the current wapp's
    // storage (_pkg) since that's the install wapp itself.
    Uint8List? _readFromWapp(String relativePath) {
      // 1. Installed copy
      if (_installed.existsSync('${wapp.name}/manifest.json')) {
        final bytes = ScopedProfileStorage(_installed, wapp.name)
            .readBytesSync(relativePath);
        if (bytes != null) return bytes;
      }
      // 2. Built-in archive
      final archivePkg = wappPackageStorage(
          '${platform.currentDirectory()}/../wapps/${wapp.name}');
      return archivePkg.readBytesSync(relativePath);
    }

    final effectiveBytes = _readFromWapp('store/description.json');

    if (effectiveBytes != null) {
      try {
        final desc = jsonDecode(utf8.decode(effectiveBytes))
            as Map<String, dynamic>;
        final descriptions =
            desc['descriptions'] as Map<String, dynamic>? ?? {};
        // Resolve by active locale, fallback to en.
        final prefs = PreferencesService.instanceSync;
        final locale = prefs?.activeLocale() ?? 'en';
        final langCode = locale.split('_').first;
        final localeDesc = (descriptions[locale] ??
                descriptions[langCode] ??
                descriptions['en']) as Map<String, dynamic>?;
        if (localeDesc != null) {
          wapp.storeTitle =
              (localeDesc['title'] as String?) ?? '';
          wapp.storeSummary =
              (localeDesc['summary'] as String?) ?? '';
          wapp.storeBody =
              (localeDesc['body'] as String?) ?? '';
        }
        wapp.changelog = (desc['changelog'] as String?) ?? '';
        final shots = desc['screenshots'];
        if (shots is List) {
          wapp.screenshotPaths = shots.cast<String>();
        }
      } catch (_) {}
    }

    // Read permissions.json for interaction settings.
    final permBytes = _readFromWapp('permissions.json');
    if (permBytes != null) {
      try {
        final perm = jsonDecode(utf8.decode(permBytes))
            as Map<String, dynamic>;
        final access = perm['access'] as Map<String, dynamic>? ?? {};
        final commentAccess = access['comment'] as Map<String, dynamic>?;
        final reactAccess = access['react'] as Map<String, dynamic>?;
        wapp.permitComments =
            commentAccess?['type'] != 'none';
        wapp.permitLikes =
            reactAccess?['type'] != 'none';
      } catch (_) {}
    }

    // If no store description was found, try reading the manifest's
    // description field as a title fallback.
    if (wapp.storeTitle.isEmpty) {
      final manifestBytes = _readFromWapp('manifest.json');
      if (manifestBytes != null) {
        try {
          final m = jsonDecode(utf8.decode(manifestBytes))
              as Map<String, dynamic>;
          wapp.storeTitle = (m['description'] as String?) ?? '';
        } catch (_) {}
      }
    }

    // Read social.sqlite3 counts.
    if (!kIsWeb) {
      // Find the wapp directory path for the SQLite database.
      String? wappDir;
      if (_installed.existsSync('${wapp.name}/manifest.json')) {
        wappDir = _installed.getAbsolutePath(wapp.name);
      } else {
        final archiveDir =
            '${platform.currentDirectory()}/../wapps/${wapp.name}';
        wappDir = archiveDir;
      }
      wapp.likeCount =
          WappSocialStore.instance.reactionCount(wappDir);
      wapp.commentCount =
          WappSocialStore.instance.commentCount(wappDir);
    }
  }

  Widget _buildWappCard(_CatalogWapp wapp, ColorScheme cs) {
    final tileColor = _storeCardColor(wapp.name);
    final profile = ProfileService.instance.activeProfile;
    final myNpub = profile?.npub ?? '';
    final liked = myNpub.isNotEmpty && wapp.permitLikes
        ? _isLiked(wapp)
        : false;
    // Title: store description > manifest description > name slug.
    // Avoid showing the name slug ("install") as title when we have
    // a proper human-readable name from the store description or
    // the manifest's description field.
    final displayTitle = wapp.storeTitle.isNotEmpty
        ? wapp.storeTitle
        : (wapp.description.isNotEmpty ? wapp.description : wapp.name);
    final displayDesc = wapp.storeSummary.isNotEmpty
        ? wapp.storeSummary
        : '';

    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      color: cs.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Icon + title row ──
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: tileColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: _storeIconWidget(wapp.name, size: 20),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayTitle,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'v${wapp.version}',
                        style: TextStyle(
                            fontSize: 10, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── Description ──
          if (displayDesc.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
              child: Text(
                displayDesc,
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurfaceVariant,
                  height: 1.3,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),

          const Spacer(),

          // ── Bottom bar: social + install ──
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 6, 6),
            child: Row(
              children: [
                // Like
                if (wapp.permitLikes)
                  InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: myNpub.isNotEmpty
                        ? () => _toggleLike(wapp, myNpub)
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            liked ? Icons.thumb_up : Icons.thumb_up_outlined,
                            size: 14,
                            color: liked ? cs.primary : cs.onSurfaceVariant,
                          ),
                          if (wapp.likeCount > 0) ...[
                            const SizedBox(width: 3),
                            Text(
                              '${wapp.likeCount}',
                              style: TextStyle(
                                fontSize: 11,
                                color: liked
                                    ? cs.primary
                                    : cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                // Comment
                if (wapp.permitComments)
                  InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => _showComments(wapp),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.comment_outlined,
                              size: 14, color: cs.onSurfaceVariant),
                          if (wapp.commentCount > 0) ...[
                            const SizedBox(width: 3),
                            Text(
                              '${wapp.commentCount}',
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                const Spacer(),
                // Install / Update
                SizedBox(
                  height: 28,
                  child: _storeActionButton(wapp, cs),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Social actions ──────────────────────────────────────────────

  String _wappDirFor(_CatalogWapp wapp) {
    if (_installed.existsSync('${wapp.name}/manifest.json')) {
      return _installed.getAbsolutePath(wapp.name);
    }
    return '${platform.currentDirectory()}/../wapps/${wapp.name}';
  }

  bool _isLiked(_CatalogWapp wapp) {
    final npub = ProfileService.instance.activeProfile?.npub ?? '';
    if (npub.isEmpty) return false;
    return WappSocialStore.instance.hasReacted(_wappDirFor(wapp), npub);
  }

  void _toggleLike(_CatalogWapp wapp, String npub) {
    final dir = _wappDirFor(wapp);
    final store = WappSocialStore.instance;
    if (store.hasReacted(dir, npub)) {
      // Find and remove the reaction.
      final reactions = store.reactions(dir);
      for (final r in reactions) {
        if (r['npub'] == npub) {
          store.removeReaction(dir, r['id'] as String);
          break;
        }
      }
      wapp.likeCount = (wapp.likeCount - 1).clamp(0, 999999);
    } else {
      final id =
          '${npub.hashCode.abs()}_${DateTime.now().millisecondsSinceEpoch}';
      store.addReaction(dir, id: id, npub: npub);
      wapp.likeCount++;
    }
    setState(() {});
  }

  void _showComments(_CatalogWapp wapp) {
    final dir = _wappDirFor(wapp);
    final store = WappSocialStore.instance;
    final comments = store.topLevelComments(dir);
    final profile = ProfileService.instance.activeProfile;
    final myNpub = profile?.npub ?? '';
    final commentController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final currentComments = store.topLevelComments(dir);
            return DraggableScrollableSheet(
              initialChildSize: 0.6,
              minChildSize: 0.3,
              maxChildSize: 0.9,
              expand: false,
              builder: (ctx, scrollController) {
                final cs = Theme.of(ctx).colorScheme;
                return Column(
                  children: [
                    // Handle
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: cs.onSurfaceVariant.withAlpha(80),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Row(
                        children: [
                          Text(
                            'Comments',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: cs.onSurface,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${currentComments.length}',
                            style: TextStyle(
                              fontSize: 14,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Comment list
                    Expanded(
                      child: currentComments.isEmpty
                          ? Center(
                              child: Text(
                                'No comments yet',
                                style: TextStyle(
                                    color: cs.onSurfaceVariant),
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16),
                              itemCount: currentComments.length,
                              itemBuilder: (ctx, i) {
                                final c = currentComments[i];
                                final author = c['npub'] as String? ?? '';
                                final short = author.length > 16
                                    ? '${author.substring(0, 10)}...'
                                    : author;
                                final ts = c['created_at'] as int? ?? 0;
                                final date = DateTime
                                    .fromMillisecondsSinceEpoch(
                                        ts * 1000);
                                return Padding(
                                  padding:
                                      const EdgeInsets.only(bottom: 12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(Icons.person_outline,
                                              size: 14,
                                              color:
                                                  cs.onSurfaceVariant),
                                          const SizedBox(width: 4),
                                          Text(
                                            short,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: cs.primary,
                                              fontFamily: 'monospace',
                                            ),
                                          ),
                                          const Spacer(),
                                          Text(
                                            '${date.day}/${date.month}/${date.year}',
                                            style: TextStyle(
                                              fontSize: 10,
                                              color:
                                                  cs.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        c['content'] as String? ?? '',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: cs.onSurface,
                                          height: 1.4,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                    // Add comment input
                    if (myNpub.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(
                                color: cs.outlineVariant.withAlpha(80)),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: commentController,
                                style: const TextStyle(fontSize: 13),
                                decoration: InputDecoration(
                                  hintText: 'Add a comment...',
                                  isDense: true,
                                  contentPadding:
                                      const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 10),
                                  border: OutlineInputBorder(
                                    borderRadius:
                                        BorderRadius.circular(20),
                                  ),
                                ),
                                onSubmitted: (text) {
                                  if (text.trim().isEmpty) return;
                                  final id =
                                      '${myNpub.hashCode.abs()}_${DateTime.now().millisecondsSinceEpoch}';
                                  store.addComment(dir,
                                      id: id,
                                      content: text.trim(),
                                      npub: myNpub);
                                  commentController.clear();
                                  wapp.commentCount++;
                                  setSheetState(() {});
                                  setState(() {});
                                },
                              ),
                            ),
                            IconButton(
                              icon: Icon(Icons.send,
                                  color: cs.primary, size: 20),
                              onPressed: () {
                                final text =
                                    commentController.text.trim();
                                if (text.isEmpty) return;
                                final id =
                                    '${myNpub.hashCode.abs()}_${DateTime.now().millisecondsSinceEpoch}';
                                store.addComment(dir,
                                    id: id,
                                    content: text,
                                    npub: myNpub);
                                commentController.clear();
                                wapp.commentCount++;
                                setSheetState(() {});
                                setState(() {});
                              },
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  /// Render the right-side action button for a store card. Same widget
  /// used by both the featured banner and the list cards — the `dark`
  /// flag flips it to a white-on-transparent variant for the banner's
  /// coloured background.
  Widget _storeActionButton(_CatalogWapp wapp, ColorScheme cs,
      {bool dark = false}) {
    // The store wapp itself (`install`) is what we're currently
    // running — there's no meaningful "install" action on its own
    // card, so show a muted "Running" chip.
    if (wapp.name == 'install') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: (dark ? Colors.white : cs.onSurfaceVariant).withAlpha(40),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          'Running',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: dark ? Colors.white : cs.onSurfaceVariant,
          ),
        ),
      );
    }

    if (wapp.installed && !wapp.updateAvailable) {
      return OutlinedButton.icon(
        onPressed: () => _uninstallWapp(wapp.name),
        icon: const Icon(Icons.check, size: 16),
        label: const Text('Installed'),
        style: OutlinedButton.styleFrom(
          foregroundColor: dark ? Colors.white : cs.primary,
          side: BorderSide(
              color: dark
                  ? Colors.white.withAlpha(160)
                  : cs.primary.withAlpha(120)),
          visualDensity: VisualDensity.compact,
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        ),
      );
    }

    final label = wapp.updateAvailable ? 'Update' : 'Install';
    void onPressed() {
      _sendCommand('install ${wapp.name}');
      _engine.handleEvent();
      _drainOutbox();
    }

    if (dark) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(
            wapp.updateAvailable ? Icons.upgrade : Icons.download_rounded,
            size: 16),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black87,
          visualDensity: VisualDensity.compact,
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20)),
        ),
      );
    }
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(
          wapp.updateAvailable ? Icons.upgrade : Icons.download_rounded,
          size: 16),
      label: Text(label),
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }

  /// Resolve a wapp's `manifest.icon` sidecar SVG to its raw bytes
  /// for store-card rendering. Matches the priority the launcher
  /// grid uses for [WappManifest.svgIconPath]:
  ///
  ///   1. If the named wapp is the currently-running one, read its
  ///      package storage (works for the Install/Store wapp itself).
  ///   2. Otherwise, read from the active profile's installed-apps
  ///      folder. Catalog entries that haven't been installed yet
  ///      return null — the caller falls back to [wappIconFor].
  ///
  /// Returns null when no `.svg` path is declared or the sidecar
  /// doesn't exist in the storage. Using `readBytesSync` instead of
  /// a `File(path).existsSync()` lookup means the web fetch-based
  /// [MemoryProfileStorage] resolves identically to the desktop
  /// [FilesystemProfileStorage].
  Uint8List? _storeSvgBytesFor(String name) {
    // Try multiple sources for the wapp's manifest + icon:
    // 1. Current running wapp (if name matches)
    // 2. Installed copy under the profile
    // 3. Built-in archive
    final candidates = <ProfileStorage>[
      if (name == _wappName) _pkg,
      if (_installed.existsSync('$name/manifest.json'))
        ScopedProfileStorage(_installed, name),
      wappPackageStorage(
          '${platform.currentDirectory()}/../wapps/$name'),
    ];

    for (final pkg in candidates) {
      final manifestBytes = pkg.readBytesSync('manifest.json');
      if (manifestBytes == null) continue;
      try {
        final manifest =
            jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
        final icon = manifest['icon'] as String?;
        if (icon == null || icon.isEmpty) continue;
        if (!icon.toLowerCase().endsWith('.svg')) continue;
        if (!icon.contains('/') && !icon.contains('\\')) continue;
        final svgBytes = pkg.readBytesSync(icon);
        if (svgBytes != null && svgBytes.isNotEmpty) return svgBytes;
      } catch (_) {}
    }
    return null;
  }

  /// Build the icon widget that goes inside a store card's coloured
  /// tile. Prefers the wapp's own SVG (matches the launcher grid),
  /// falls back to the shared Material heuristic. [size] matches the
  /// enclosing tile so a white-on-colour Material icon fills cleanly.
  /// SVGs pass through a srcIn white colour filter so wapps whose
  /// icons are authored in dark strokes still read cleanly on the
  /// coloured tile.
  Widget _storeIconWidget(String name, {required double size}) {
    const whiteFilter = ColorFilter.mode(Colors.white, BlendMode.srcIn);
    final svgBytes = _storeSvgBytesFor(name);
    if (svgBytes != null) {
      return Padding(
        padding: EdgeInsets.all(size * 0.12),
        child: SvgPicture.memory(
          svgBytes,
          fit: BoxFit.contain,
          theme: const SvgTheme(currentColor: Colors.white),
          placeholderBuilder: (_) => Icon(
            wappIconFor(name),
            size: size,
            color: Colors.white,
          ),
        ),
      );
    }
    return Icon(wappIconFor(name), size: size, color: Colors.white);
  }

  /// Small pill-shaped chip used on store cards to show origin and
  /// publisher metadata. Tooltipable so the user can hover-reveal a
  /// truncated npub. Keeps the visual weight light so it doesn't
  /// compete with the primary action button.
  Widget _storeMetaChip({
    required IconData icon,
    required String label,
    required ColorScheme cs,
    String? tooltip,
  }) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant.withAlpha(110)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: cs.onSurfaceVariant,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
  }

  /// Format a publisher identity for display on a store card. Given
  /// a bech32 npub (or any string), produces `X1ABCD (npub1abcd…wxyz)`
  /// — the X1-prefixed callsign derived from the key, followed by a
  /// shortened form of the key in parentheses. The full npub goes
  /// into the tooltip so the user can read or copy-paste it.
  /// Non-npub strings are shown as-is (truncated if long).
  String _formatPublisher(String raw) {
    if (raw.isEmpty) return '';
    String shortNpub;
    if (raw.length <= 16) {
      shortNpub = raw;
    } else {
      final head = raw.substring(0, 9);
      final tail = raw.substring(raw.length - 4);
      shortNpub = '$head…$tail';
    }
    if (!raw.toLowerCase().startsWith('npub1') || raw.length < 10) {
      return shortNpub;
    }
    // Callsign: X1 + first 4 chars after 'npub1', uppercased.
    final callsign = 'X1${raw.substring(5, 9).toUpperCase()}';
    return '$callsign ($shortNpub)';
  }

  /// Deterministic card-tile colour based on the wapp name so every
  /// entry has a stable, recognisable swatch.
  Color _storeCardColor(String name) {
    const palette = <Color>[
      Color(0xFF6750A4),
      Color(0xFF3F6CFF),
      Color(0xFF0A8754),
      Color(0xFFCC4A1B),
      Color(0xFF1E6091),
      Color(0xFF7B3F98),
      Color(0xFFCF8D2E),
      Color(0xFF2E7D32),
    ];
    return palette[name.hashCode.abs() % palette.length];
  }

  // ── Terminal screen ────────────────────────────────────────────────

  Widget _buildTerminalScreen() {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(12),
            itemCount: _outputLines.length,
            itemBuilder: (context, i) {
              final line = _outputLines[i];
              return Text(
                line.text,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: _outputColor(line.level),
                ),
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Colors.grey.shade800)),
          ),
          child: Row(
            children: [
              const Text('\$ ',
                  style: TextStyle(
                      fontFamily: 'monospace',
                      color: Color(0xFF7EE787),
                      fontSize: 13)),
              Expanded(
                child: TextField(
                  controller: _cmdController,
                  autofocus: true,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    hintText: 'Type a command...',
                  ),
                  onSubmitted: (v) {
                    if (v.trim().isNotEmpty) _sendCommand(v.trim());
                    _cmdController.clear();
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Color _outputColor(String level) => switch (level) {
        'cmd' => const Color(0xFF7EE787),
        'err' || 'error' => const Color(0xFFF85149),
        'info' => const Color(0xFF58A6FF),
        'warn' || 'warning' => const Color(0xFFE3B341),
        _ => const Color(0xFFE6EDF3),
      };

  // ── Functionalities screen ─────────────────────────────────────────

  /// State for the "Try it" results, keyed by endpoint name.
  final Map<String, String> _tryResults = {};
  /// Input controllers for endpoint params, keyed by "endpoint.param".
  final Map<String, TextEditingController> _tryInputs = {};

  Widget _buildFunctionalitiesScreen() {
    final cs = Theme.of(context).colorScheme;
    final registry = FunctionalityRegistry.instance;
    final allIds = registry.allFunctionalityIds.toList()..sort();

    if (allIds.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'No functionalities registered.\n\n'
            'Wapps declare functionalities in their manifest under '
            '"provides.functionalities". Install a wapp that provides '
            'one (e.g. Functionality Demo) to see it listed here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: allIds.length,
      itemBuilder: (context, index) {
        final funcId = allIds[index];
        final providers = registry.providersFor(funcId);
        return _buildFunctionalityCard(funcId, providers, cs);
      },
    );
  }

  Widget _buildFunctionalityCard(
      String funcId, List<WappManifest> providers, ColorScheme cs) {
    final def = FunctionalityRegistry.instance.defFor(funcId);
    final isCore = funcId.startsWith('hal.');
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outlineVariant.withAlpha(60)),
      ),
      color: cs.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header bar ──
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            decoration: BoxDecoration(
              color: isCore
                  ? cs.primaryContainer.withAlpha(50)
                  : cs.tertiaryContainer.withAlpha(50),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: isCore ? cs.primary : cs.tertiary,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isCore ? 'CORE' : 'WAPP',
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    funcId,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace',
                      color: cs.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // ── Description ──
          if (def != null && def.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                def.description,
                style: TextStyle(
                    fontSize: 13, color: cs.onSurface, height: 1.3),
              ),
            ),
          // ── Providers ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Text('Providers',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant,
                    letterSpacing: 0.3)),
          ),
          for (final provider in providers)
            _buildProviderRow(funcId, provider, providers, cs),
          // ── Endpoints ──
          if (def != null && def.endpoints.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Text('Endpoints',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                      letterSpacing: 0.3)),
            ),
            for (final ep in def.endpoints)
              _buildEndpointRow(ep, cs),
            // Per-functionality JSON spec button
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: OutlinedButton.icon(
                onPressed: () =>
                    _showFunctionalitySpec(funcId, def, providers),
                icon: const Icon(Icons.data_object, size: 14),
                label: const Text('View JSON spec'),
                style: OutlinedButton.styleFrom(
                  textStyle: const TextStyle(fontSize: 11),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  Widget _buildEndpointRow(EndpointDef ep, ColorScheme cs) {
    final result = _tryResults[ep.name];
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(80),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant.withAlpha(50)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Method signature line
          Row(
            children: [
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                      color: cs.onSurface,
                    ),
                    children: [
                      TextSpan(
                        text: ep.name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(
                        text: '(',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                      if (ep.params.isNotEmpty)
                        TextSpan(
                          text: ep.params
                              .map((p) => '${p.type} ${p.name}')
                              .join(', '),
                          style: TextStyle(
                            color: cs.primary,
                            fontSize: 12,
                          ),
                        ),
                      TextSpan(
                        text: ')',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.tertiaryContainer.withAlpha(120),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  '→ ${ep.returns.type}',
                  style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                    color: cs.onTertiaryContainer,
                  ),
                ),
              ),
            ],
          ),
          // Description
          if (ep.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                ep.description,
                style: TextStyle(
                    fontSize: 11, color: cs.onSurfaceVariant, height: 1.3),
              ),
            ),
          // Parameters — input fields for each
          if (ep.params.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final p in ep.params)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 90,
                            child: RichText(
                              text: TextSpan(
                                style: TextStyle(
                                    fontSize: 11, fontFamily: 'monospace'),
                                children: [
                                  TextSpan(
                                    text: p.name,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: cs.onSurface,
                                    ),
                                  ),
                                  TextSpan(
                                    text: ' ${p.type}',
                                    style: TextStyle(color: cs.primary),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: SizedBox(
                              height: 32,
                              child: TextField(
                                controller: _tryInputs.putIfAbsent(
                                  '${ep.name}.${p.name}',
                                  () => TextEditingController(),
                                ),
                                style: const TextStyle(
                                    fontSize: 12, fontFamily: 'monospace'),
                                decoration: InputDecoration(
                                  hintText: p.description.isNotEmpty
                                      ? p.description
                                      : p.type,
                                  hintStyle: TextStyle(
                                      fontSize: 11,
                                      color: cs.onSurfaceVariant
                                          .withAlpha(120)),
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 6),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                ),
                                keyboardType:
                                    p.type == 'int' || p.type == 'uint32' || p.type == 'uint64'
                                        ? TextInputType.number
                                        : TextInputType.text,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          // Returns
          if (ep.returns.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: RichText(
                text: TextSpan(
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  children: [
                    const TextSpan(
                        text: 'Returns: ',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    TextSpan(text: ep.returns.description),
                  ],
                ),
              ),
            ),
          // Try it button + result
          const SizedBox(height: 8),
          SizedBox(
            height: 32,
            child: FilledButton.icon(
              onPressed: () => _tryEndpoint(ep),
              icon: const Icon(Icons.play_arrow, size: 16),
              label: const Text('Run'),
              style: FilledButton.styleFrom(
                textStyle: const TextStyle(fontSize: 12),
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
            ),
          ),
          if (result != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(6),
                  border:
                      Border.all(color: cs.outlineVariant.withAlpha(80)),
                ),
                child: SelectableText(
                  result,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: cs.onSurface,
                    height: 1.4,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showFunctionalitySpec(String funcId, FunctionalityDef def,
      List<WappManifest> providers) {
    final spec = <String, dynamic>{
      'functionality': funcId,
      'description': def.description,
      'providers': [
        for (final p in providers)
          {'id': p.id, 'name': p.title.isNotEmpty ? p.title : p.name},
      ],
      'endpoints': [
        for (final ep in def.endpoints)
          <String, dynamic>{
            'name': ep.name,
            'description': ep.description,
            'params': [
              for (final p in ep.params)
                <String, dynamic>{
                  'name': p.name,
                  'type': p.type,
                  if (p.description.isNotEmpty) 'description': p.description,
                },
            ],
            'returns': <String, dynamic>{
              'type': ep.returns.type,
              if (ep.returns.description.isNotEmpty)
                'description': ep.returns.description,
              if (ep.returns.fields.isNotEmpty) 'fields': ep.returns.fields,
            },
          },
      ],
    };
    final jsonText = const JsonEncoder.withIndent('  ').convert(spec);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ApiJsonExportPage(
          title: funcId,
          json: jsonText,
        ),
      ),
    );
  }

  void _tryEndpoint(EndpointDef ep) {
    // Collect input values from controllers.
    final args = <String, String>{};
    for (final p in ep.params) {
      final ctrl = _tryInputs['${ep.name}.${p.name}'];
      args[p.name] = ctrl?.text ?? '';
    }
    String result;
    try {
      result = _executeHalTest(ep.name, args);
    } catch (e) {
      result = 'Error: $e';
    }
    setState(() => _tryResults[ep.name] = result);
  }

  String _executeHalTest(String name, Map<String, String> args) {
    final now = DateTime.now();
    switch (name) {
      // ── Time ──
      case 'hal_time_ms':
        return '${now.millisecondsSinceEpoch} ms';
      case 'hal_time_epoch':
        return '${now.millisecondsSinceEpoch ~/ 1000} s\n${now.toIso8601String()}';

      // ── Platform / Heap ──
      case 'hal_platform':
        return platform.currentDirectory().isNotEmpty
            ? 'linux-desktop'
            : 'web';
      case 'hal_heap_free':
        return 'N/A on desktop (no heap limit)';

      // ── Log ──
      case 'hal_log':
        final level = int.tryParse(args['level'] ?? '') ?? 1;
        final msg = args['msg'] ?? '(empty)';
        final labels = ['DEBUG', 'INFO', 'WARN', 'ERROR'];
        final label = level >= 0 && level < 4 ? labels[level] : 'L$level';
        return '[$label] $msg\nLogged at ${now.toIso8601String()}';

      // ── Yield ──
      case 'hal_yield':
        return 'OK — no-op on desktop';

      // ── Sensors ──
      case 'hal_sensor_temperature':
        return 'INT32_MIN\nNo sensor hardware on this platform.\nOn ESP32: returns centidegrees C (e.g. 2500 = 25.00°C)';
      case 'hal_sensor_humidity':
        return 'INT32_MIN\nNo sensor hardware on this platform.\nOn ESP32: returns centipercent (e.g. 6500 = 65.00%)';
      case 'hal_sensor_battery':
        return 'INT32_MIN\nNo sensor hardware on this platform.\nOn ESP32: returns millivolts (e.g. 3700 = 3.7V)';
      case 'hal_sensor_gps_lat':
        return 'INT32_MIN\nNo GPS on this platform.\nOn device: returns latitude × 1e7';
      case 'hal_sensor_gps_lon':
        return 'INT32_MIN\nNo GPS on this platform.\nOn device: returns longitude × 1e7';

      // ── Display ──
      case 'hal_display_width':
        return '${MediaQuery.of(context).size.width.toInt()} px';
      case 'hal_display_height':
        return '${MediaQuery.of(context).size.height.toInt()} px';
      case 'hal_display_clear':
        return 'OK — display cleared (no-op on desktop)';
      case 'hal_display_text':
        final x = args['x'] ?? '0';
        final y = args['y'] ?? '0';
        final color = args['color'] ?? '1';
        final text = args['text'] ?? '';
        return 'Drew "$text" at ($x, $y) color=$color\n(No-op on desktop — renders on ESP32/embedded display)';
      case 'hal_display_pixel':
        return 'Drew pixel at (${args['x'] ?? 0}, ${args['y'] ?? 0}) color=${args['color'] ?? 0}\n(No-op on desktop)';
      case 'hal_display_rect':
        return 'Drew rect at (${args['x']}, ${args['y']}) ${args['w']}×${args['h']} color=${args['color']}\n(No-op on desktop)';
      case 'hal_display_flush':
        return 'OK — buffer flushed (no-op on desktop)';

      // ── GPIO ──
      case 'hal_gpio_mode':
        final modes = {0: 'INPUT', 1: 'OUTPUT', 2: 'INPUT_PULLUP'};
        final mode = int.tryParse(args['mode'] ?? '') ?? 0;
        return 'Pin ${args['pin'] ?? '?'} set to ${modes[mode] ?? 'UNKNOWN'}\n(No-op on desktop — ESP32 only)';
      case 'hal_gpio_read':
        return '0\nPin ${args['pin'] ?? '?'} (stub on desktop — always 0)';
      case 'hal_gpio_write':
        return 'OK — pin ${args['pin'] ?? '?'} = ${args['value'] ?? '?'}\n(No-op on desktop)';

      // ── LoRa ──
      case 'hal_lora_available_hw':
        return '0\nNo LoRa hardware detected on this platform.';
      case 'hal_lora_send':
        final data = args['data'] ?? '';
        return data.isEmpty
            ? 'Error: no data provided'
            : '-1\nNo LoRa hardware. Would send ${data.length} bytes.';
      case 'hal_lora_available':
        return '0\nNo LoRa hardware — no data available.';
      case 'hal_lora_recv':
        return '0 bytes\nNo LoRa hardware.';

      // ── BLE ──
      case 'hal_ble_scan_start':
        return '-1\nBLE not available on desktop.';
      case 'hal_ble_scan_stop':
        return 'OK (no-op on desktop)';
      case 'hal_ble_scan_read':
        return '[]\nNo BLE scan results.';
      case 'hal_ble_advertise':
        return '-1\nBLE not available on desktop.';
      case 'hal_ble_advertise_stop':
        return 'OK (no-op on desktop)';

      // ── Messaging ──
      case 'hal_msg_send':
        final json = args['json'] ?? '';
        return json.isEmpty
            ? 'Error: empty message'
            : 'Sent ${json.length} bytes to host';
      case 'hal_msg_available':
        return '0\nNo pending messages.';
      case 'hal_msg_recv':
        return '(empty)\nNo pending messages to receive.';

      // ── KV ──
      case 'hal_kv_get':
        final key = args['key'] ?? '';
        return key.isEmpty
            ? 'Error: key is empty'
            : 'Requires wapp context.\nWould look up key "$key" in the module\'s scoped store.';
      case 'hal_kv_set':
        final key = args['key'] ?? '';
        final value = args['value'] ?? '';
        return key.isEmpty
            ? 'Error: key is empty'
            : 'Requires wapp context.\nWould set "$key" = "$value" (${value.length} bytes).';
      case 'hal_kv_delete':
        return 'Requires wapp context.\nWould delete key "${args['key'] ?? ''}"';
      case 'hal_kv_list':
        return 'Requires wapp context.\nWould list keys matching prefix "${args['prefix'] ?? ''}"';
      case 'hal_kv_exists':
        return 'Requires wapp context.\nWould check if key "${args['key'] ?? ''}" exists.';
      case 'hal_kv_size':
        return 'Requires wapp context.\nWould return size of key "${args['key'] ?? ''}".';

      // ── i18n ──
      case 'hal_i18n_get':
        final key = args['key'] ?? '';
        if (key.isEmpty) return 'Error: key is empty';
        final resolved = _i18n.resolve('@$key');
        return resolved.startsWith('@')
            ? 'Not found: "$key"\nNo translation in current locale.'
            : 'Resolved: "$resolved"';

      // ── File ──
      case 'hal_file_open':
        return 'Requires wapp context.\nWould open "${args['path'] ?? ''}" mode=${args['mode'] ?? 0}';
      case 'hal_file_read':
        return 'Requires wapp context + open handle.';
      case 'hal_file_write':
        return 'Requires wapp context + open handle.';
      case 'hal_file_close':
        return 'Requires wapp context + open handle.';

      // ── HTTP ──
      case 'hal_http_request':
        final methods = {0: 'GET', 1: 'POST', 2: 'PUT', 3: 'DELETE'};
        final method = int.tryParse(args['method'] ?? '') ?? 0;
        final url = args['url'] ?? '';
        return url.isEmpty
            ? 'Error: URL is empty'
            : 'Would send ${methods[method] ?? 'GET'} $url\n(Async — poll with hal_http_poll)';
      case 'hal_http_poll':
        return 'Requires active request_id from hal_http_request.';
      case 'hal_http_read_response':
        return 'Requires completed request_id.';
      case 'hal_http_status':
        return 'Requires active request_id.';
      case 'hal_http_free':
        return 'Requires active request_id.';

      // ── Events ──
      case 'hal_event_subscribe':
        return 'Requires wapp context.\nWould subscribe to topic "${args['topic'] ?? ''}"';
      case 'hal_event_unsubscribe':
        return 'Requires wapp context.\nWould unsubscribe from "${args['topic'] ?? ''}"';
      case 'hal_event_publish':
        return 'Requires wapp context.\nWould publish to "${args['topic'] ?? ''}" (${(args['data'] ?? '').length} bytes)';
      case 'hal_event_available':
        return '0\nNo pending events.';
      case 'hal_event_recv':
        return '(empty)\nNo pending events.';

      // ── Lib ──
      case 'hal_lib_call':
        return 'Requires wapp context.\nWould call ${args['fn_name'] ?? '?'} on lib ${args['lib_id'] ?? '?'}\nArgs: ${args['args'] ?? '{}'}';

      default:
        return 'No test handler for $name';
    }
  }

  Widget _buildProviderRow(String funcId, WappManifest provider,
      List<WappManifest> allProviders, ColorScheme cs) {
    final prefs = PreferencesService.instanceSync;
    final preferredId = prefs?.getPreferredProvider(funcId);
    final isDefault = allProviders.length == 1 ||
        provider.id == preferredId ||
        (preferredId == null && provider == allProviders.first);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: allProviders.length > 1
          ? () async {
              final p = await PreferencesService.instance();
              p.setPreferredProvider(funcId, provider.id);
              if (mounted) setState(() {});
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Row(
          children: [
            if (allProviders.length > 1)
              Icon(
                isDefault
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 16,
                color: isDefault ? cs.primary : cs.onSurfaceVariant,
              )
            else
              Icon(Icons.check_circle_outline, size: 16, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                provider.title.isNotEmpty ? provider.title : provider.name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isDefault ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            Text(
              provider.id,
              style: TextStyle(
                fontSize: 10,
                fontFamily: 'monospace',
                color: cs.onSurfaceVariant,
              ),
            ),
            if (isDefault) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'DEFAULT',
                  style: TextStyle(
                    fontSize: 9,
                    color: cs.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Settings screen ────────────────────────────────────────────────

  Widget _buildSettingsScreen(GeoUiBlock screen) {
    final renderer = GeoUiScreenRenderer(
      screen: screen,
      bindings: _WappFieldBindings(_engine, _fieldValues, () => setState(() {})),
      i18n: _i18n,
      onAction: (action) {
        if (action == 'save') {
          _engine.sendMessage(jsonEncode({
            'type': 'action',
            'action': 'save',
            'fields': _fieldValues,
          }));
          _engine.handleEvent();
          _drainOutbox();

          // Switch to first tab (Shop) to show results
          if (_tabController != null && _tabController!.index != 0) {
            _tabController!.animateTo(0);
          }
        } else {
          // Any other action name is forwarded to the wapp as a plain
          // command string. Lets debug/test wapps use standard GeoUI
          // action buttons without needing custom Flutter code.
          _sendCommand(action);
        }
      },
    );

    // App Creator: full custom settings screen with proper dependency
    // pickers instead of the generic GeoUI renderer. This chrome (signing
    // identity, identity fields, category, HAL, provides) only belongs on
    // the Settings screen — identified by its `identity` group. Other
    // settings-like App Creator screens (e.g. Tests) fall through here too,
    // so render their own GeoUI verbatim rather than the settings form.
    if (!_isAppCreator) return renderer;
    final isSettingsScreen = screen.children
        .any((c) => c.keyword == 'group' && c.name == 'identity');
    if (!isSettingsScreen) return renderer;
    return _buildAppCreatorSettings(renderer);
  }

  // Available HAL capability groups — derived from geogram_wasm_hal.h.
  // Each entry maps a manifest requires.hal tag to a human description.
  static const _halCapabilities = <String, String>{
    'log': 'Logging',
    'time': 'Time functions',
    'kv': 'Key-value storage',
    'i18n': 'Translations',
    'file': 'File I/O',
    'http': 'HTTP requests',
    'socket': 'Raw TCP sockets',
    'msg': 'Inter-wapp messaging',
    'event': 'Event pub/sub',
    'lib': 'Library calls',
    'lora': 'LoRa radio',
    'ble': 'Bluetooth LE',
    'sensor': 'Sensors',
    'display': 'Display/screen',
    'gpio': 'GPIO pins',
  };


  Future<void> _addProvidesFunctionality(List<String> provides) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add functionality'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'e.g. weather_card',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty && !provides.contains(name)) {
      setState(() {
        provides.add(name);
        _fieldValues['wapp_provides_functionalities'] = provides;
      });
    }
  }


  Future<void> _importNsec() async {
    final controller = TextEditingController();
    final nsec = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import signing key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paste your nsec1… private key. This will create a new '
              'profile and set it as the active signing identity.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: 'nsec1…',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (nsec == null || nsec.isEmpty) return;
    try {
      final profile = ProfileService.instance.buildFromNsec(nsec);
      await ProfileService.instance.saveAndActivate(profile);
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Imported: ${profile.callsign}'),
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Invalid nsec: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      }
    }
  }


  /// Split a comma-separated string into a trimmed, non-empty list.
  static List<String> _splitCsv(String csv) => csv
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  // ── Map screen ─────────────────────────────────────────────────────


  // Live-drag radius (km) for the map's radius bar; null when not dragging.
  // (Map builders + widgets live in wapp_maps.dart.)
  double? _mapDragKm;
}

/// Full-screen page showing the complete API definition as copyable
/// JSON. Opened from the Functionalities screen's "Export API as JSON"
/// button.
class _ApiJsonExportPage extends StatelessWidget {
  final String title;
  final String json;
  const _ApiJsonExportPage({required this.title, required this.json});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy to clipboard',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: json));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('API JSON copied to clipboard'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          json,
          style: TextStyle(
            fontSize: 12,
            fontFamily: 'monospace',
            color: cs.onSurface,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}

class _OutputLine {
  final String text;
  final String level;
  _OutputLine(this.text, this.level);
}







// ── Tasks screen helper widgets ──────────────────────────────────────

class _StatusPill extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  const _StatusPill({
    required this.label,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(40),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$count $label',
        style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _MiniPill extends StatelessWidget {
  final String label;
  final Color color;
  const _MiniPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(35),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: '$label ',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          TextSpan(
            text: value,
            style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: cs.onSurface,
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _CatalogWapp {
  final String name;
  final String version;
  final String size;
  final bool installed;
  final bool updateAvailable;
  // Mutable metadata — attached by [_WappPageState._buildOutputScreen]
  // after the entry has been pushed, in order to keep the line-by-line
  // text-log parser simple (one walk, no lookahead).
  String description = '';
  String sourceHost = '';
  String publisherNpub = '';
  // NDF store enrichment — populated by _enrichCatalogWapp after parse.
  String storeTitle = '';
  String storeSummary = '';
  String storeBody = '';
  String changelog = '';
  List<String> screenshotPaths = const [];
  int likeCount = 0;
  int commentCount = 0;
  bool permitLikes = true;
  bool permitComments = true;

  _CatalogWapp({
    required this.name,
    required this.version,
    this.size = '',
    this.installed = false,
    this.updateAvailable = false,
  });
}

class _WappFieldBindings implements GeoUiBindings {
  final WappEngine _engine;
  final Map<String, dynamic> _values;
  final VoidCallback _onChange;
  _WappFieldBindings(this._engine, this._values, this._onChange);

  @override
  dynamic getValue(String fieldName) => _values[fieldName];

  @override
  void setValue(String fieldName, dynamic value) {
    _values[fieldName] = value;
    // Mirror scalar edits straight into the module's KV so the wapp
    // reads them via hal_kv_get — this is how settings forms (e.g. the
    // terminal's) actually take effect. Without it, edits live only in
    // a host-side map the module never sees.
    if (value is String) {
      _engine.kvSet(fieldName, value);
    } else if (value is num || value is bool) {
      _engine.kvSet(fieldName, value.toString());
    }
    _onChange();
  }
}

// ── Slippy tile map widget ───────────────────────────────────────────




