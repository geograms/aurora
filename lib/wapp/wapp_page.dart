import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb, ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart'
    show
        Clipboard,
        ClipboardData,
        HapticFeedback,
        HardwareKeyboard,
        KeyDownEvent,
        LogicalKeyboardKey;
import 'package:file_selector/file_selector.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:graph3d/graph3d.dart';
import 'package:vector_math/vector_math_64.dart' show Quaternion, Vector3;

import '../connections/internet/http_transport.dart';
import '../platform/platform.dart' as platform;

import 'native/media_capability.dart';
import 'native/wasm_audio_output.dart';
import 'native/wasm_video_player.dart' show WasmVideoThumbnailer;
import 'native/wasm_video_session.dart';

import 'file_folder_picker.dart';
import 'geoui/geoui_ast.dart';
import 'geoui/geoui_parser.dart';
import 'geoui/geoui_renderer.dart';
import '../editor/code_editor_field.dart';
import 'geoui/widgets/log_view_field.dart';
import 'geoui/widgets/chat_palette.dart';
import 'geoui/widgets/chat_view_field.dart';
import 'geoui/widgets/activity_feed.dart';
import 'geoui/widgets/micron_view.dart';
import 'geoui/widgets/profile_route.dart';
import 'geoui/widgets/media_view.dart' show sharedMediaArchive;
import '../profile/profile_edit_page.dart';
import '../util/media_ref.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_imeta.dart';
import 'geoui/conversation_store.dart';
import 'geoui/geo_chat_archive.dart';
import 'geoui/activity_archive.dart';
import 'geoui/widgets/conversations_field.dart';
import 'geoui/widgets/people_view_field.dart';
import 'shared_media_fetch.dart';
import 'geoui/tile_cache.dart';
import 'background_wapp_manager.dart';
import 'android_foreground_service.dart';
import '../profile/iwi_profile.dart';
import '../models/monitored_task.dart';
import '../services/media_disk_cache.dart';
import '../services/event_bus.dart';
import '../services/log_service.dart';
import '../services/notification_service.dart';
import '../services/location_service.dart';
import '../services/preferences_service.dart';
import '../services/reticulum/rns_service.dart';
import '../util/time_ago.dart';
import '../services/wapp_unread_service.dart';
import '../services/hero/hero_inbox.dart';
import '../profile/profile_service.dart';
import '../profile/profile_storage.dart';
import 'coin/coin_host_bridge.dart';
import 'coin/atm_host_bridge.dart';
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
import 'wapp_graph_scene.dart';
import 'wapp_icons.dart';
import 'wapp_engine.dart';
import '../services/mesh/mesh_custody.dart';

part '../editor/wapp_editor.dart';
part '../editor/wapp_robot.dart';
part 'wapp_maps.dart';
part 'wapp_graph.dart';

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

  /// Optional command JSON delivered to the module right after init (same shape
  /// as a GeoUI action: `{"command":"…", …}`). Used by deep links so e.g. the
  /// circles wapp can jump straight to the "apply to join" flow.
  final String? initialCommand;

  /// Open this conversation id (e.g. a callsign) as soon as the wapp is up —
  /// the host-side deep link other wapps use to jump into a 1:1 chat (e.g.
  /// the Bluetooth wapp's envelope button).
  final String? initialConvo;

  /// For a `post:<mid>` [initialView]: the post's row (activity-archive map
  /// shape), already held by the caller. Lets the thread page open instantly
  /// with this as its root instead of waiting for the wapp to re-download the
  /// post; replies stream in as the wapp's subscription fills the archive.
  final Map<String, dynamic>? initialPost;

  /// Optional generic view intent delivered as `view.open` after init. Wapps
  /// that do not implement the intent ignore it.
  final String? initialView;

  const WappPage({
    super.key,
    required this.wappDir,
    required this.title,
    this.openFilePath,
    this.openFileMode = 'view',
    this.editWappDir,
    this.initialCommand,
    this.initialConvo,
    this.initialView,
    this.initialPost,
  });

  @override
  State<WappPage> createState() => _WappPageState();
}

class _WappPageState extends State<WappPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
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
  // Speaker sink for PCM a wapp decodes in wasm (e.g. the Player wapp playing
  // music). Wired unconditionally so audio-only playback is audible even when
  // no video surface is mounted; video sessions read it as the A/V master clock.
  WasmAudioOutput? _audioOut;

  // Media-session state last reported by the wapp (Player music/radio). Drives
  // background keep-alive and the Android lock-screen / notification controls.
  bool _mediaActive = false; // playing or paused (something is loaded)
  bool _bgKeepAlive = false; // this page's engine is ticking in the background
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
  // Screens are split into tab screens (shown in the tab bar) and menu screens
  // (`"menu": true` — reached from the top-right options menu as a panel). Both
  // are subsets of [_screens]; the full list keeps its indices for tab-switching.
  final _tabScreens = <GeoUiBlock>[];
  final _tabNames = <String>[];
  final _menuScreens = <GeoUiBlock>[];
  final _menuNames = <String>[];
  // The menu screen currently shown as a full panel (null = normal tab view).
  GeoUiBlock? _panelScreen;
  String _panelName = '';
  String?
  _panelTitle; // dynamic AppBar title for the open panel (e.g. folder name)
  TabController? _tabController;
  final _nostrSearchCtl = TextEditingController(); // Search panel query box

  // The reticulum wapp's native graph reports its open full-screen panel here so
  // the app bar shows that panel's title + a single back arrow (no second one).
  String? _graphPanelTitle;
  VoidCallback? _graphPanelBack;

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
  // Structured catalog cards pushed by a wapp via `ui.data` (target "catalog")
  // — the Wapp Store's available-wapps list. Replace-semantics each push.
  final _catalogItems = <Map<String, dynamic>>[];
  // Real wapp icon SVGs carried in the catalog index.json, keyed by the .wapp
  // leaf filename (which is the card `id` the store echoes back). Lets the store
  // show each wapp's authored icon even before it is installed — the SVG bytes
  // never cross into the wasm sandbox, only this host-side map.
  final _catalogIcons = <String, Uint8List>{};
  // Catalog metadata keyed by the stable wapp slug (the install directory name,
  // e.g. "aprs"): the published version and the .wapp leaf filename. Lets the
  // host decide Install / Update / Installed against what's actually installed
  // on the device, and drive "Update all".
  final _catalogMeta = <String, Map<String, String>>{};
  // Installed wapp versions keyed by slug (install dir) — read from each
  // installed manifest. Refreshed when the catalog loads and after installs.
  final _installedVersions = <String, String>{};
  // The Reticulum folder address the current catalog was fetched from, so
  // "Update all" can re-install each outdated wapp directly.
  String _catalogSourceAddr = '';
  bool _updatingAll = false;
  String _catalogLayout = 'list';
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

  /// Post ids already shown in each chat/feed field. A note published to several
  /// relays arrives on several subscriptions, and the feed must show it ONCE —
  /// the event id is the post's identity, so this is the whole test. Seeded from
  /// the persisted archive on restore, or the restored posts would each be
  /// appended a second time when the wapp re-sent them live.
  final _feedIds = <String, Set<String>>{};
  final _lastFireBatch = <String, int>{};
  int _archived = 0;
  int _archivedLogAt = 0;

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
  String _tileUrl =
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
  bool _hasMap = false;
  // Native graph state (generic `$type:"graph"` GeoUI group). The wapp pushes a
  // {nodes,edges} snapshot via `ui.graph.set`; the host renders it with the
  // graph3d 3D engine. See wapp_graph.dart.
  final ValueNotifier<Map<String, dynamic>?> _graphData =
      ValueNotifier<Map<String, dynamic>?>(null);
  // Configured bootstrap hubs [{endpoint,connected}] pushed via ui.graph.hubs,
  // rendered by the native bootstrap-manager panel inside _GraphView.
  final ValueNotifier<List<dynamic>?> _graphHubs =
      ValueNotifier<List<dynamic>?>(null);
  // Pins pushed by the wapp via `ui.map.marker`, keyed by id (e.g. a
  // callsign). Rendered as an overlay by [_SlippyMap]; tapping a pin
  // dispatches a `marker_tap` command back to the wapp.
  final Map<String, Map<String, dynamic>> _mapMarkers = {};

  // Coverage/filter radius + its centre (my station), pushed by the wapp
  // via `ui.map.radius`. Defaults let the circle + slider show before the
  // first connect; the persisted location (or the wapp) overrides them.
  // Default centre = Coimbra; the user's chosen/last location is restored from
  // the wapp's persisted my_lat/my_lon on startup (see _applyPersistedFields).
  double? _mapRadiusKm = 100;
  double? _mapCenterLat = 40.2056;
  double? _mapCenterLon = -8.4196;

  // Geo-chat split into Live (manual) and Beacons (everything automated).
  // APRS has no flag for "human-typed", so we use a marker: a message whose
  // text starts with ">>" is treated as a manual message → Live; all other
  // traffic (position/status/telemetry beacons, auto-replies) → Beacons.
  final List<Map<String, dynamic>> _geoLive = [];
  final List<Map<String, dynamic>> _geoBeacons = [];

  /// Persistent, geo-queryable archive of Live geo-chat messages (generic —
  /// see geo_chat_archive.dart). Set once the wapp data dir is known.
  GeoChatArchive? _geoArchive;

  /// Persistent Activity feed (shared with the background engine), so posts
  /// received while the app was closed appear when the user opens Activity.
  ActivityArchive? _activityArchive;

  /// Callsigns to hide from the Activity feed (blocked + muted), pushed by the
  /// wapp via ui.activity.filter. Uppercased.
  Set<String> _activityHidden = const {};
  CoinHostBridge? _coinBridge;
  AtmHostBridge? _atmBridge;

  /// Bumped whenever the Activity archive changes, so an open (pushed) thread
  /// page rebuilds with newly-arrived replies/likes.
  final ValueNotifier<int> _activityRev = ValueNotifier<int>(0);

  /// Absolute like/reply counts a wapp pushes for its posts via
  /// `ui.activity.stats` (keyed by post mid). Generic: any wapp can report
  /// engagement it tracks itself (e.g. NOSTR relay reactions).
  final Map<String, ({int likes, int replies, bool mine})> _wappPostStats = {};

  /// Author profiles a wapp pushes via `ui.profile.set` (keyed by the post's
  /// `from`). {name, pic, about, nip05, npub}. Generic — lets a wapp resolve
  /// its own identities (e.g. NOSTR kind-0) to a display name + avatar.
  ///
  /// PERSISTED to disk: once an author is resolved it stays resolved in every
  /// view (Saved, threads, profile page) and across restarts — it does not
  /// depend on that author still being in the live feed.
  final Map<String, Map<String, String>> _wappProfiles = {};
  File? _wappProfilesFile;
  Timer? _wappProfilesSaveTimer;

  /// Posts we've reposted (kind-6 "retweet"), by mid — for the optimistic
  /// green Retweet state in the feed / thread / profile.
  final Set<String> _wappReposted = {};

  /// The full hex pubkey of a post's author, from the 12-char prefix the feed
  /// carries as `from`. A reaction must p-tag the author (NIP-25) or the
  /// author never learns about it — and then their notification panel is
  /// silent while people are voting on them.
  String _activityAuthorHex(String mid) {
    final posts = _activityArchive?.recent() ?? const <Map<String, dynamic>>[];
    for (final p in posts) {
      if ((p['mid'] ?? '').toString() != mid) continue;
      final short = (p['from'] ?? '').toString();
      final prof = RnsService.instance.nostrProfileByShort12(short);
      final npub = prof['npub'] ?? '';
      if (npub.isNotEmpty) {
        try {
          return NostrCrypto.decodeNpub(npub);
        } catch (_) {}
      }
      return '';
    }
    return '';
  }

  /// Repost a publication (kind-6): tell the wapp + reflect it immediately.
  void _repostPost(Map<String, dynamic> post) {
    final mid = (post['mid'] ?? '').toString();
    if (mid.isEmpty || _wappReposted.contains(mid)) return;
    _wappReposted.add(mid);
    _fieldValues['activity_mid'] = mid;
    _fieldValues['activity_author'] = (post['from'] ?? '').toString();
    _sendCommand('activity_repost');
    setState(() {});
  }

  /// Periodic FEED backfill over Reticulum (complements APRS-IS, which loses
  /// messages): asks peers for FEED notes since the last sweep.
  Timer? _feedBackfillTimer;
  // A faster sweep right after the wapp opens, so a device that just joined the
  // network fetches older FEED posts as soon as RNS is up AND a relay peer has
  // been discovered (the steady 3-min timer was too slow for a fresh join).
  Timer? _fastBackfillTimer;
  int _fastBackfillTicks = 0;
  int _lastFeedBackfillSec = 0;

  /// Callsigns we follow / have blocked (bridged from the APRS wapp), so the
  /// profile UI shows the right Follow/Following + Block/Unblock controls.
  final Set<String> _followedCalls = {};
  final Set<String> _blockedCalls = {};

  // Transport/status indicators shown on the map, pushed by the wapp via
  // `ui.map.status` (e.g. APRS-IS connected, BLE active). Each {id,label,on}.
  final List<Map<String, dynamic>> _mapStatus = [];

  // Geo-chat panel open/closed (owned here so the unread badge survives tab
  // switches) and the count of Live messages received while it was closed.
  // The Geo Chat tab isn't the default tab, so it starts "closed" — arrivals
  // accumulate as an unread badge until the user opens that tab.
  bool _geoChatOpen = false;
  int _geoUnread = 0;

  /// Fraction of the Geochat tab's height given to the chat panel under the
  /// map (the rest is map). User-resizable via the drag handle between them.
  double _geoSplit = 0.45;

  /// Landscape only: fraction of the Geochat tab's WIDTH given to the chat
  /// column on the right (the rest is the map on the left). User-resizable via
  /// the vertical drag handle between them.
  double _geoSplitLand = 0.42;

  /// The conversation open in the conversations widget (host-owned so the
  /// AppBar can show the thread title + the single back arrow in portrait).
  String? _convOpenId;

  /// People-search open on the conversation list. Host-owned because the search
  /// icon sits in the AppBar (next to the ☰) while the search field renders in
  /// the list body.
  bool _convSearching = false;

  /// In-wapp navigation state, driven by the wapp via `ui.nav` messages. When
  /// [_wappNavBack] is true the AppBar shows [_wappNavTitle] (e.g. the current
  /// folder name) and the back arrow / system-back are forwarded to the wapp as
  /// a `nav_back` command (go up one level) instead of leaving the wapp. The
  /// wapp clears it (back:false) once it returns to its root, so the next back
  /// shows the wapp name and exits. Generic — no app knowledge here.
  String? _wappNavTitle;
  bool _wappNavBack = false;

  /// When true (the default) the map frames the coverage circle on mount.
  /// Cleared by locate-on-map so the located station stays centred instead;
  /// restored on any rail navigation.
  bool _mapAutoFit = true;

  void _setGeoChatOpen(bool open) {
    if (!mounted) return;
    setState(() {
      _geoChatOpen = open;
      if (open) _geoUnread = 0; // opening clears the Map-tab notification
    });
    _syncAppBadge();
  }

  void _geoChatAdd(Map raw, {bool archive = true}) {
    // Persist Live (geo-tagged ">>") messages so they survive restarts and can
    // be queried back by region. Replayed history passes archive:false so it
    // isn't re-archived (and doesn't bump unread / notifications).
    if (archive) _geoArchive?.add(raw);
    final msg = raw.map((k, v) => MapEntry(k.toString(), v));
    final text = (msg['text'] ?? '').toString().trimLeft();
    if (text.startsWith('>>')) {
      // Manual message — drop the ">>" marker for display.
      msg['text'] = text.substring(2).trimLeft();
      _geoLive.add(msg);
      if (_geoLive.length > 300) _geoLive.removeRange(0, _geoLive.length - 300);
      // Notify on the Map tab when a received message lands while the chat box
      // is closed (own outgoing echoes don't count). Not for replayed history.
      if (archive && msg['dir'] == 'in' && !_geoChatOpen) _geoUnread++;
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

  /// Load archived Live geo-chat for the region the wapp asked about and replay
  /// it into the Live feed (oldest→newest). Driven by `ui.chat.history`.
  void _loadGeoHistory(Map data) {
    final arch = _geoArchive;
    if (arch == null) return;
    final lat = (data['lat'] as num?)?.toDouble();
    final lon = (data['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return;
    final radius =
        (data['radius_km'] as num?)?.toDouble() ?? _mapRadiusKm ?? 100;
    final limit = (data['limit'] as num?)?.toInt() ?? 200;
    final since = (data['since_ms'] as num?)?.toInt();
    final recs = arch.query(
      lat: lat,
      lon: lon,
      radiusKm: radius,
      limit: limit,
      sinceMs: since,
    );
    if (recs.isEmpty || !mounted) return;
    for (final r in recs) {
      // The archive doesn't store the display time; derive it from the record
      // timestamp so replayed bubbles carry a sensible label.
      final t = (r['t'] as num?)?.toInt();
      if (t != null && (r['time'] == null || (r['time'] as String).isEmpty)) {
        r['time'] = _fmtArchiveTime(t);
      }
      _geoChatAdd(r, archive: false);
    }
    setState(() {});
  }

  /// Compact time label for a replayed archive message: `HH:mm` for today,
  /// otherwise `MM-dd HH:mm` so older history is distinguishable.
  static String _fmtArchiveTime(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final hm = '${two(d.hour)}:${two(d.minute)}';
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return hm;
    }
    return '${two(d.month)}-${two(d.day)} $hm';
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
        final field = entry.name.substring(
          0,
          entry.name.length - 5,
        ); // strip .json
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

  /// Override the seeded field defaults with values the user previously saved
  /// (persisted to the wapp KV via the settings form / map interactions). Only
  /// declared fields that actually have a stored value are touched, coerced to
  /// the field's existing type. Run after the engine's KV is loaded
  /// (setStorage). For the map this restores the last my_lat/my_lon centre +
  /// radius so the geo-chat opens where the user left it, not the default.
  void _applyPersistedFields() {
    for (final name in _fieldValues.keys.toList()) {
      final v = _engine.kvGet(name);
      if (v == null) continue;
      final cur = _fieldValues[name];
      if (cur is bool) {
        _fieldValues[name] = v == 'true';
      } else if (cur is int) {
        final n = int.tryParse(v);
        if (n != null) _fieldValues[name] = n;
      } else if (cur is num) {
        final n = num.tryParse(v);
        if (n != null) _fieldValues[name] = n;
      } else {
        _fieldValues[name] = v; // string (or untyped) — store verbatim
      }
    }
    // Mirror a restored map centre/radius into the live map state so the map
    // shows the saved location immediately (before the wapp pushes its own
    // ui.map.radius). my_lat/my_lon are the established centre field names.
    final la = double.tryParse('${_fieldValues['my_lat'] ?? ''}');
    final lo = double.tryParse('${_fieldValues['my_lon'] ?? ''}');
    if (la != null && lo != null && (la != 0 || lo != 0)) {
      _mapCenterLat = la;
      _mapCenterLon = lo;
      _mapLat = la;
      _mapLon = lo;
    }
    final km = double.tryParse(
      '${_fieldValues['radius_km'] ?? _fieldValues['map_radius'] ?? _engine.kvGet('radius_km') ?? ''}',
    );
    if (km != null && km > 0) _mapRadiusKm = km;
  }

  /// Persist the map centre + radius to the wapp KV (the same store the settings
  /// form writes to), so they survive a restart. Called whenever the user moves
  /// the coverage circle (GPS, drag, long-press) or changes the radius.
  void _persistMapLocation() {
    final la = _mapCenterLat, lo = _mapCenterLon, km = _mapRadiusKm;
    if (la != null && lo != null) {
      _engine.kvSet('my_lat', la.toStringAsFixed(5));
      _engine.kvSet('my_lon', lo.toStringAsFixed(5));
    }
    if (km != null) _engine.kvSet('radius_km', km.round().toString());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Deep-linked post (launcher hero tap): open its thread on the FIRST frame
    // with the row the caller already holds — before the engine even boots, so
    // the feed never flashes underneath. Replies fill in as the wapp's
    // subscription lands them in the archive (revision bumps repaint).
    final heldPost = widget.initialPost;
    if (heldPost != null &&
        (widget.initialView ?? '').startsWith('post:') &&
        (heldPost['mid'] ?? '').toString().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openActivityThread(heldPost);
      });
    }
    // Repaint the Activity stream when a followed peer's profile is fetched.
    RnsService.instance.addProfileListener(_onProfilesChanged);
    // Repaint (throttled) when the NOSTR engine pushes fresh stats/events, so
    // an open thread's like/reply counts update the moment they arrive.
    RnsService.instance.addNostrListener(_onNostrChanged);
    // Periodically recover FEED posts lost over APRS-IS from Reticulum peers.
    _feedBackfillTimer = Timer.periodic(
      const Duration(minutes: 3),
      (_) => unawaited(_backfillFeed()),
    );
    // Aggressive early sweep: a just-joined device often comes up before RNS is
    // connected and before any relay peer is known, so the single 8s shot used
    // to miss and then wait 3 minutes. Retry every 15s for the first ~5 minutes
    // (until a sweep actually pulls notes), so older posts arrive promptly once
    // the node connects and discovers a peer.
    _fastBackfillTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_fastBackfillTick()),
    );
    // If this wapp is running as a background service, hand it over to this
    // page so only one engine (and one BLE scan) is live while it's open.
    BackgroundWappManager.instance.suspend(_wappName);
    unawaited(_loadWappProfilesCache());
    _loadWapp();
  }

  /// Load the persisted author-profile cache so names/avatars resolve in every
  /// view (including Saved + old threads) from the first frame.
  Future<void> _loadWappProfilesCache() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/wapp_profiles.json');
      _wappProfilesFile = f;
      if (!f.existsSync()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return;
      j.forEach((k, v) {
        if (v is Map && !_wappProfiles.containsKey('$k')) {
          _wappProfiles['$k'] = {
            for (final e in v.entries) '${e.key}': '${e.value}',
          };
        }
      });
      if (mounted) {
        setState(() {});
        _activityRev.value++;
      }
    } catch (_) {}
  }

  /// Persist the profile cache a few seconds after the last update (debounced).
  void _saveWappProfilesCacheSoon() {
    _wappProfilesSaveTimer?.cancel();
    _wappProfilesSaveTimer = Timer(const Duration(seconds: 3), () async {
      final f = _wappProfilesFile;
      if (f == null) return;
      try {
        await f.writeAsString(jsonEncode(_wappProfiles));
      } catch (_) {}
    });
  }

  void _onProfilesChanged() {
    if (mounted) setState(() {});
  }

  // Engine pushes arrive up to every 400ms; throttle the repaint so an open
  // thread updates its counts promptly without rebuilding on every tick.
  int _lastNostrRepaintMs = 0;
  void _onNostrChanged() {
    if (!mounted) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastNostrRepaintMs < 500) return;
    _lastNostrRepaintMs = now;
    _activityRev.value++; // repaints an open ActivityThreadPage
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // Back in the foreground: this page owns the engine again — drop the
      // background one, and refresh so anything it received while we were away
      // (e.g. Activity posts) shows immediately.
      if (_bgKeepAlive) {
        BackgroundWappManager.instance.releasePage(_wappName);
        _bgKeepAlive = false;
      }
      BackgroundWappManager.instance.suspend(_wappName);
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // App backgrounded while this page is still open. If audio is playing
      // (Player music/radio), keep THIS page's engine ticking via the native
      // heartbeat so playback continues uninterrupted (a fresh headless engine
      // couldn't reproduce the live decoder/position). Otherwise hand off to the
      // background manager (if the wapp autostarts) for receive/notify.
      if (_mediaActive) {
        _bgKeepAlive = true;
        BackgroundWappManager.instance.keepPageAlive(_wappName, _bgTick);
      } else {
        unawaited(BackgroundWappManager.instance.resume(widget.wappDir));
      }
    }
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

    // Partition screens into tab screens and menu (panel) screens. A screen
    // flagged `"hidden": true` is neither a tab nor a corner-menu entry — it is
    // an internal panel the wapp opens contextually via ui.screen.open (e.g. an
    // editor reached from a row's action). It still lives in [_screens] so
    // ui.screen.open can find it by name.
    _tabScreens.clear();
    _tabNames.clear();
    _menuScreens.clear();
    _menuNames.clear();
    for (var i = 0; i < _screens.length; i++) {
      if (_screens[i].getBool('hidden') == true) {
        continue; // openable panel, but kept out of the tab bar and options menu
      }
      if (_screens[i].getBool('menu') == true) {
        _menuScreens.add(_screens[i]);
        _menuNames.add(_screenNames[i]);
      } else {
        _tabScreens.add(_screens[i]);
        _tabNames.add(_screenNames[i]);
      }
    }
    // Defensive: never leave the tab bar empty (a wapp that flags every screen).
    if (_tabScreens.isEmpty) {
      _tabScreens.addAll(_screens);
      _tabNames.addAll(_screenNames);
      _menuScreens.clear();
      _menuNames.clear();
    }

    // Build tab controller (sized to the tab screens only). The top tab bar
    // mirrors its index; rebuild on change (incl. programmatic switches like
    // "locate on map") and toggle the Geo Chat unread badge when that tab is
    // entered/left.
    _tabController = TabController(length: _tabScreens.length, vsync: this);
    _tabController!.addListener(() {
      if (!mounted) return;
      if (!_tabController!.indexIsChanging) {
        _setGeoChatOpen(_isGeoChatScreen(_tabScreens[_tabController!.index]));
      }
      setState(() {});
    });

    // Set up persistent KV storage under the per-wapp data dir.
    final prefs = await PreferencesService.instance();
    final wappData = wappDataStorageFor(prefs, _wappName);
    await wappData.createDirectory('');
    _wappData = wappData;
    _geoArchive = GeoChatArchive.forStorage(wappData);
    _activityArchive = ActivityArchive.forStorage(wappData);
    // NOSTR web of trust: never firehose-evict posts from people the user
    // follows or who follow them. Harmless for other wapps (their callsign
    // authors never intersect the hex-pubkey trust set).
    _activityArchive!.protectedAuthors = () =>
        RnsService.instance.nostrProtectedAuthors().toSet();
    // Coin wallet bridge: backs the "wallet" wapp's coin.* messages. Lazy — the
    // holdings DB is only opened when a coin operation actually runs.
    _coinBridge = CoinHostBridge(wappData);
    await _coinBridge!.init();
    // ATM node bridge: backs the "atm" wapp (operate a coin's blockchain and
    // distribute its faucet). Lazy like the coin bridge.
    _atmBridge = AtmHostBridge(wappData);
    await _atmBridge!.init();
    _engine.setStorage(wappData);
    // Tag the per-wapp RNS datagram channel (hal_rns_*) with this wapp's id so
    // two devices running the same wapp exchange datagrams and others don't.
    _engine.setAppId(_wappName);
    // Restore persisted settings (saved to the wapp KV) over the declared field
    // defaults, so a wapp's saved settings — the map's my_lat/my_lon centre in
    // particular — survive a restart instead of reverting to the default.
    _applyPersistedFields();
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
      final hostDefault = PreferencesService.instanceSync?.wappStoreSource;
      if (hostDefault != null && hostDefault.isNotEmpty) {
        _engine.kvSet('source', hostDefault);
      } else {
        final cwd = platform.currentDirectory();
        final candidates = [
          '$cwd/../wapps/binaries', // sibling repo (canonical)
          '$cwd/../../wapps/binaries', // nested workspace fallback
          '$cwd/wapps/binaries', // legacy in-tree
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

    // Paint the tab bar + fields NOW — the archive/conversation caches are
    // already loaded, so cached posts show instantly. Otherwise the screen sits
    // on "Loading…" for up to a minute while the wasm engine compiles + connects
    // + subscribes, which reads as "something is broken".
    if (mounted) {
      _status = 'Running';
      setState(() {});
    }

    // Load the WASM binary from the package.
    final wasmBytes = await _pkg.readBytes('app.wasm');
    if (wasmBytes == null) {
      setState(() => _status = 'app.wasm not found');
      EventBus().fire(
        WappCrashedEvent(
          wappId: _wappName,
          phase: 'load',
          error: 'app.wasm not found at ${_pkg.basePath}/app.wasm',
        ),
      );
      return;
    }

    try {
      await _engine.load(wasmBytes);
      // Route PCM the wapp decodes straight to the speaker. Degrades to silence
      // (never crashes) on platforms without the PCM plugin.
      _audioOut = WasmAudioOutput();
      _engine.onAudioPcm = _audioOut!.pushPcm;
      _engine.init();
      _drainOutbox();

      final interval = _engine.tickIntervalMs;

      // Register this wapp's tick loop with the task monitor.
      TaskMonitorService.instance.register(
        MonitoredTask(
          id: _tickTaskId,
          name: _wappName,
          description: 'Tick loop for $_wappName',
          serviceName: 'wapps',
          priority: TaskPriority.normal,
          type: TaskType.periodic,
          interval: Duration(milliseconds: interval),
        ),
      );

      _tickTimer = Timer.periodic(Duration(milliseconds: interval), (_) {
        // Honour pause-from-task-monitor: skip the tick body but keep
        // the timer alive so resume just works.
        final task = TaskMonitorService.instance.getTask(_tickTaskId);
        if (task?.status == TaskStatus.paused) return;
        // While backgrounded as the media owner the native heartbeat drives the
        // engine; skip the (throttled) Dart timer so we don't double-tick.
        if (_bgKeepAlive) return;
        TaskMonitorService.instance.reportStart(_tickTaskId);
        try {
          _engine.tick();
          _drainOutbox();
          TaskMonitorService.instance.reportSuccess(_tickTaskId);
        } catch (e) {
          TaskMonitorService.instance.reportFailure(_tickTaskId, e);
          EventBus().fire(
            WappCrashedEvent(wappId: _wappName, phase: 'tick', error: e),
          );
        }
      });

      // "Open with…" delivery: hand the chosen file to the module via
      // a file.open message right after init so the wapp can react on
      // its next event pump. The wapp reads `path`/`mode` from its
      // inbox; wapps that don't handle it simply ignore the message.
      final openPath = widget.openFilePath;
      if (openPath != null && openPath.isNotEmpty) {
        _engine.sendMessage(
          jsonEncode({
            'type': 'file.open',
            'path': openPath,
            'mode': widget.openFileMode,
          }),
        );
        _engine.handleEvent();
        _drainOutbox();
      }

      final initialView = widget.initialView;
      if (initialView != null && initialView.isNotEmpty) {
        _engine.sendMessage(
          jsonEncode({'type': 'view.open', 'view': initialView}),
        );
        _engine.handleEvent();
        _drainOutbox();
        // 'post:<mid>' asks for a specific publication (e.g. the launcher hero
        // card). The wapp subscribes to it above. When the caller handed the
        // post along, its thread is ALREADY open (pushed on the first frame in
        // initState); otherwise wait for the post to land and open then.
        if (initialView.startsWith('post:') && widget.initialPost == null) {
          _openPostWhenAvailable(initialView.substring(5));
        }
      }

      // Deep-link / launch command: deliver one command to the module after
      // init (e.g. a circles "apply_url" from a geogram.radio/circle link).
      final initCmd = widget.initialCommand;
      if (initCmd != null && initCmd.isNotEmpty) {
        _engine.sendMessage(initCmd);
        _engine.handleEvent();
        _drainOutbox();
      }

      EventBus().fire(WappLoadedEvent(wappId: _wappName, wappName: _wappName));
      setState(() => _status = 'Running');

      // Deep link into a conversation (host-side UI state, after the screens
      // exist): jump straight to the 1:1 thread.
      final convo = widget.initialConvo;
      if (convo != null && convo.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _openConvoById(convo);
        });
      }

      // Per-wapp "Edit" entry: this App Creator page was opened to edit
      // one specific wapp — jump straight into its editor.
      if (_isAppCreator && widget.editWappDir != null) {
        await _autoEditTarget();
      }
    } catch (e) {
      EventBus().fire(
        WappCrashedEvent(wappId: _wappName, phase: 'load', error: e),
      );
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
          _outputLines.add(
            _OutputLine(
              item['text'] as String? ?? '',
              item['level'] as String? ?? 'out',
            ),
          );
          changed = true;
        } else if (type == 'ui.data') {
          // Structured cards (Wapp Store catalog). Replace the current set.
          final target = data['target'] as String? ?? '';
          if (target == 'catalog') {
            final items = (data['items'] as List?) ?? const [];
            _catalogItems
              ..clear()
              ..addAll(
                items.whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
              );
            changed = true;
          }
        } else if (type == 'ui.set_field') {
          // Set one field's value from the wapp: the way a settings screen shows
          // what the host currently believes (a read-only stat, or the option
          // that is actually in force). Without this a wapp could only ever
          // build lists — which is why the Indexer briefly rendered its options
          // as a people-widget, i.e. as tabs.
          final name = '${data['name'] ?? ''}';
          if (name.isNotEmpty) {
            _fieldValues[name] = '${data['value'] ?? ''}';
            changed = true;
          }
        } else if (type == 'ui.attr') {
          // e.g. catalog layout list/grid toggle.
          if ((data['target'] as String? ?? '') == 'catalog' &&
              (data['attr'] as String? ?? '') == 'layout') {
            _catalogLayout = '${data['value'] ?? 'list'}';
            changed = true;
          }
        } else if (type == 'store.sources') {
          // Install wapp push: the current source list straight out
          // of its KV store. Mirror it to _fieldValues['source'] as
          // a newline-joined string so the sources group renderer
          // (and any other reader) sees the same shape the wapp has
          // on disk.
          final list = data['sources'] as List?;
          final asStrings = list == null
              ? <String>[]
              : list.whereType<String>().toList();
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
        } else if (type == 'ui.log.clear') {
          // Empty a $type:"log" field's buffer (e.g. before a fresh run).
          final fieldName = data['field'] as String? ?? 'output';
          final existing = _fieldValues[fieldName];
          if (existing is List && existing.isNotEmpty) {
            existing.clear();
            changed = true;
          }
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
            Future.microtask(() {
              if (mounted) _sendCommand(c);
            });
          }
        } else if (type == 'rns.hub.add') {
          // Reticulum bootstrap-hub management (non-disruptive config from the
          // reticulum wapp). Endpoint is "host:port". Async; fire-and-forget.
          final ep = (data['endpoint'] as String? ?? '').trim();
          if (ep.isNotEmpty) {
            // ignore: discarded_futures
            RnsService.instance.addBootstrap(ep);
          }
        } else if (type == 'rns.hub.remove') {
          final ep = (data['endpoint'] as String? ?? '').trim();
          if (ep.isNotEmpty) RnsService.instance.removeBootstrap(ep);
        } else if (type == 'rns.hub.connect') {
          final ep = (data['endpoint'] as String? ?? '').trim();
          if (ep.isNotEmpty) {
            // ignore: discarded_futures
            RnsService.instance.connectBootstrap(ep);
          }
        } else if (type == 'rns.hub.disconnect') {
          final ep = (data['endpoint'] as String? ?? '').trim();
          final i = ep.lastIndexOf(':');
          if (i > 0) {
            final host = ep.substring(0, i).trim();
            final port = int.tryParse(ep.substring(i + 1).trim()) ?? 4242;
            if (host.isNotEmpty) {
              RnsService.instance.disconnectUplink(host, port);
            }
          }
        } else if (type == 'rns.passive.set') {
          RnsService.instance.setPassive(data['value'] == true);
        } else if (type == 'rns.lxmf.send') {
          // Send a 1:1 LXMF message to an observed node the reticulum wapp picked
          // in the graph. The peer is addressed by its public key (meta.pubkey);
          // the service derives the LXMF delivery dest. Fire-and-forget — the
          // graph shows an optimistic "queued" toast (LXMF stores-and-forwards).
          final pubkey = (data['pubkey'] as String? ?? '').trim();
          final content = (data['content'] as String? ?? '');
          final title = (data['title'] as String? ?? '');
          if (pubkey.isNotEmpty && content.isNotEmpty) {
            // ignore: discarded_futures
            RnsService.instance.sendLxmfToPubkey(
              pubkeyHex: pubkey,
              title: title,
              content: content,
            );
          }
        } else if (type == 'mesh.message') {
          // Bluetooth wapp envelope button: jump into the Chat wapp's 1:1
          // conversation with that callsign (deep link via initialConvo).
          final cs = (data['callsign'] as String? ?? '').trim();
          if (cs.isNotEmpty && mounted) {
            final dir = '${installedAppsDirPath()}/chat';
            // ignore: discarded_futures
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    WappPage(wappDir: dir, title: 'Chat', initialConvo: cs),
              ),
            );
          }
        } else if (type == 'ui.graph.set') {
          // The wapp pushes a {nodes,edges} snapshot for the native `$type:
          // "graph"` widget. We just hand it to the ValueNotifier the _GraphView
          // listens to; it diffs the topology and (re)lays-out off the main
          // thread only when the node/edge set actually changed.
          final payload = data['payload'];
          if (payload is Map) {
            _graphData.value = payload.cast<String, dynamic>();
          }
        } else if (type == 'ui.graph.hubs') {
          // The wapp forwards the raw bootstrap-hub list for the native
          // bootstrap-manager panel.
          final payload = data['payload'];
          if (payload is List) _graphHubs.value = payload;
        } else if (type == 'ui.chat.append') {
          // Append one message to a $type:"chat" field's buffer. Each
          // message is a map {dir:'in'|'out', from, text, time}. Backing
          // list is created lazily like ui.log.append.
          final fieldName = data['field'] as String? ?? 'messages';
          final msg = data['message'];
          if (msg is Map) {
            // Activity/FEED media is tap-to-download (posts can carry large
            // images/videos the user should choose to fetch) — don't auto-pull it
            // here; the Activity card shows its size + a one-click download button.
            if (fieldName != 'activity') {
              _maybeFetchSharedMedia(
                msg['text']?.toString() ?? '',
                (msg['dir']?.toString() ?? 'in'),
                msg['from']?.toString(),
              );
            }
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
              final row = msg.map((k, v) => MapEntry(k.toString(), v));
              final source = (row['source'] ?? '').toString();
              final batch = (row['batch'] as num?)?.toInt() ?? 0;
              final batchMode = (row['batch_mode'] ?? '').toString();
              final batchIndex = (row['batch_index'] as num?)?.toInt() ?? -1;
              if (fieldName == 'activity' &&
                  source == 'firehose' &&
                  batch > 0 &&
                  batchIndex == 0 &&
                  batchMode != 'manual' &&
                  _lastFireBatch[fieldName] != batch) {
                _lastFireBatch[fieldName] = batch;
                buf.removeWhere((p) => (p['source'] ?? '') == 'firehose');
                _activityArchive?.clearSource('firehose');
                _feedIds[fieldName] = {
                  for (final p in buf)
                    if ((p['mid'] ?? '').toString().isNotEmpty)
                      (p['mid'] ?? '').toString(),
                };
                _activityRev.value++;
              }
              // Recover NIP-92 imeta (video poster / blurhash / dimensions)
              // for feed posts: the wapp forwards only the text, but the full
              // event (tags included) sits in the local relay store under the
              // post's mid. Local sqlite lookup — no network.
              if (fieldName == 'activity' || fieldName == 'search_results') {
                final mid = (row['mid'] ?? '').toString();
                final hasMeta = (row['meta'] ?? '').toString().isNotEmpty;
                final text = (row['text'] ?? '').toString();
                if (!hasMeta && mid.length == 64 && text.contains('http')) {
                  final tags = RnsService.instance.relayLocalEvent(
                    mid,
                  )?['tags'];
                  if (tags is List) {
                    final m = imetaMetaJson(tags);
                    if (m.isNotEmpty) {
                      row['meta'] = m;
                      msg['meta'] = m; // the archive persists [msg]
                    }
                  }
                }
              }
              // The SAME post, twice. A note is published to several relays and
              // comes back on several subscriptions — the firehose, discovery and
              // the follows feed all pour into `activity`, each with its own
              // seen-set — so one event id reaches this buffer more than once.
              // The id (mid) is the post's identity: a feed must never show it
              // twice, whatever route it took to get here.
              //
              // Profile cards carry no mid, so those fall back to the author.
              var dup = false;
              final mid = (row['mid'] ?? '').toString();
              if (mid.isNotEmpty) {
                dup = !_feedIds
                    .putIfAbsent(fieldName, () => <String>{})
                    .add(mid);
              } else if (fieldName == 'search_results') {
                final from = (row['from'] ?? '').toString();
                dup = buf.any(
                  (e) =>
                    (e['mid'] ?? '').toString().isEmpty &&
                      (e['from'] ?? '').toString() == from,
                );
              }
              if (!dup) {
                buf.add(row);
                // Persist the Activity feed so background-received posts survive
                // into the foreground (and across restarts). A duplicate is not
                // archived either — it would come back as a duplicate.
                if (fieldName == 'activity') {
                  _activityArchive?.add(msg);
                  _activityRev.value++; // refresh any open thread page
                  _archived++;
                  final nowMs = DateTime.now().millisecondsSinceEpoch;
                  if (nowMs - _archivedLogAt > 30000) {
                    _archivedLogAt = nowMs;
                    LogService.instance.add(
                      'activity archived: $_archived posts since last report',
                    );
                    _archived = 0;
                  }
                }
              } else if (fieldName == 'activity' && mid.isNotEmpty) {
                final author = (row['author'] ?? '').toString().toLowerCase();
                if (author.length == 64) {
                  for (final existing in buf) {
                    if ((existing['mid'] ?? '').toString() == mid) {
                      existing['author'] = author;
                      break;
                    }
                  }
                  _activityArchive?.enrichAuthor(mid, author);
                  _activityRev.value++;
                }
              }
            }
            changed = true;
          }
        } else if (type == 'ui.people.set') {
          // Replace a $type:"people" field's section list (the social-style
          // people list: Following / Followers with tags + row actions).
          final fieldName = data['field'] as String? ?? 'people';
          final sections = data['sections'];
          if (sections is List) {
            _fieldValues[fieldName] = sections
                .whereType<Map>()
                .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
                .toList();
            changed = true;
          }
        } else if (type == 'ui.stats.set') {
          // Replace a $type:"stats" field's tiles — the native dashboard grid
          // (big value, whispering label, optional sparkline). Statistics are
          // not a form; a read-only text box is an input somebody disabled.
          final fieldName = data['field'] as String? ?? 'stats';
          final tiles = data['tiles'];
          if (tiles is List) {
            _fieldValues[fieldName] = tiles
                .whereType<Map>()
                .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
                .toList();
            changed = true;
          }
        } else if (type == 'ui.rail.set') {
          // Replace a $type:"rail" field's items (the folder navigation rail:
          // [{id,name,icon}]). Tapping one fires `<field>_tap` with `<field>_id`.
          final fieldName = data['field'] as String? ?? 'rail';
          final items = data['items'];
          if (items is List) {
            _fieldValues[fieldName] = items
                .whereType<Map>()
                .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
                .toList();
            changed = true;
          }
        } else if (type == 'ui.chat.history') {
          // The wapp asks to (re)load archived geo-chat for a region, e.g. on
          // open or after the radius changes. Generic: the host queries the
          // archive by centre+radius and replays the matches into the feed.
          if ((data['field'] as String? ?? 'geochat') == 'geochat') {
            _loadGeoHistory(data);
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
            // The Activity feed is backed by a persisted archive — wipe it too,
            // else cleared posts reappear on the next rebuild/restart.
            if (fieldName == 'activity') {
              _activityArchive?.clearAll();
              _activityRev.value++;
              changed = true;
            }
            _feedIds.remove(fieldName); // cleared feed = nothing seen in it
          }
        } else if (type == 'ui.convo.upsert') {
          final field = data['field'] as String? ?? 'conversations';
          _convStore(field).upsert(data);
          // The wapp can ask to OPEN the conversation it just upserted (e.g. the
          // "New message" flow, which should drop the user straight into the new
          // 1:1 instead of leaving them on the list). Honour `select:true` by
          // making it the open thread host-side.
          if (data['select'] == true) {
            final id = (data['id'] ?? '').toString();
            if (id.isNotEmpty) {
              _convOpenId = id;
              _convStore(field).clearUnread(id);
              _syncAppBadge();
            }
          }
          _scheduleConvoSave(field);
          changed = true;
        } else if (type == 'ui.convo.msg') {
          final field = data['field'] as String? ?? 'conversations';
          _convStore(field).addMessage(data);
          _scheduleConvoSave(field);
          // Bulk-lane tap: outgoing 1:1 with a hosted file: token queues the
          // payload for mesh delivery (encrypted wires hide the token, the
          // bubble text doesn't).
          MeshCustodyDelegate.onConvoOutMessage(data);
          changed = true;
        } else if (type == 'ui.convo.remove') {
          final field = data['field'] as String? ?? 'conversations';
          _convStore(field).remove(data);
          _scheduleConvoSave(field);
          changed = true;
        } else if (type == 'ui.convo.react') {
          final field = data['field'] as String? ?? 'conversations';
          _convStore(field).react(data);
          _scheduleConvoSave(field);
          changed = true;
        } else if (type == 'ui.convo.status') {
          // Delivery/read receipt: advance an outgoing 1:1 message's tick state
          // (sent → delivered → read), keyed by its correlation id `rid`.
          final field = data['field'] as String? ?? 'conversations';
          _convStore(field).setStatus(data);
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
        } else if (type == 'ui.nav') {
          // In-wapp navigation chrome: the wapp reports the current title and
          // whether system-back should drill up (true) or leave the wapp
          // (false). Drives the AppBar title + back interception below.
          final t = data['title'] as String?;
          final b = data['back'] == true;
          if (t != _wappNavTitle || b != _wappNavBack) {
            _wappNavTitle = (t != null && t.isNotEmpty) ? t : null;
            _wappNavBack = b;
            changed = true;
          }
        } else if (type == 'ui.screen.open') {
          // The wapp asks the host to open one of its screens as a full-size
          // panel (e.g. a per-folder Stats / Edit panel reached from a row
          // menu). Matched by screen name; no-op if unknown.
          final want = (data['name'] as String? ?? '').trim();
          // Optional dynamic title (e.g. the open folder's name instead of the
          // static screen name).
          final title = (data['title'] as String? ?? '').trim();
          for (var i = 0; i < _screens.length; i++) {
            if (_screenNames[i] == want) {
              _panelScreen = _screens[i];
              _panelName = _screenNames[i];
              _panelTitle = title.isNotEmpty ? title : null;
              changed = true;
              break;
            }
          }
        } else if (type == 'ui.screen.close') {
          if (_panelScreen != null) {
            _panelScreen = null;
            _panelTitle = null;
            changed = true;
          }
        } else if (type == 'ui.field.set') {
          // Set a scalar field's value (prefill an editor). The cached
          // TextEditingController re-syncs to the new value on the next build.
          final f = data['field'] as String?;
          if (f != null && f.isNotEmpty) {
            _fieldValues[f] = data['value'];
            changed = true;
          }
        } else if (type.startsWith('coin.') || type.startsWith('atm.')) {
          // Wallet + ATM wapp bridges over the participation-coin library
          // (package:reticulum). coin.* manages held coins; atm.* operates a
          // coin's blockchain and faucet. Both return UI field updates.
          final updates = type.startsWith('atm.')
              ? _atmBridge?.handle(type, data)
              : _coinBridge?.handle(type, data);
          if (updates != null) {
            updates.forEach((field, value) => _fieldValues[field] = value);
            changed = true;
          }
        } else if (type == 'social.follow' || type == 'social.unfollow') {
          // Generic NOSTR-follow bridge: a wapp (e.g. APRS, when you follow a
          // callsign whose public key it knows) tells the host to host that
          // pubkey's content with the "followed" retention tier. App-agnostic —
          // the host just keeps a set of followed pubkeys.
          final key = (data['pubkey'] ?? '').toString();
          if (key.isNotEmpty) {
            if (type == 'social.follow') {
              RnsService.instance.followPubkey(key);
            } else {
              RnsService.instance.unfollowPubkey(key);
            }
          }
        } else if (type == 'social.identity') {
          // The APRS wapp tells the host a callsign's NOSTR pubkey (learned from
          // its key beacon), so the Activity feed + profile can show the npub.
          final call = (data['callsign'] ?? '').toString();
          final key = (data['pubkey'] ?? '').toString();
          if (call.isNotEmpty && key.isNotEmpty) {
            RnsService.instance.recordCallsignPubkey(call, key);
          }
        } else if (type == 'social.followstate' ||
            type == 'social.blockstate') {
          // The APRS wapp tells the host whether we follow / have blocked a
          // callsign, so the profile UI shows the right buttons.
          final call = (data['callsign'] ?? '').toString().trim().toUpperCase();
          final on = data['on'] == true;
          if (call.isNotEmpty) {
            final set = type == 'social.followstate'
                ? _followedCalls
                : _blockedCalls;
            if (on) {
              set.add(call);
            } else {
              set.remove(call);
            }
            // Let the RNS service keep (re)fetching followed profiles in the
            // background, retrying ones that failed earlier.
            if (type == 'social.followstate') {
              RnsService.instance.setFollowedCallsigns(_followedCalls);
            }
          }
        } else if (type == 'ui.activity.react') {
          // A like vote on an Activity post (by mid). Tally it in the archive.
          final mid = (data['mid'] ?? '').toString();
          final from = (data['from'] ?? '').toString();
          if (mid.isNotEmpty && from.isNotEmpty) {
            _activityArchive?.setReaction(
              mid,
              from,
              data['like'] == true,
              data['mine'] == true,
            );
            _activityRev.value++; // refresh any open thread page
            changed = true;
          }
        } else if (type == 'ui.activity.stats') {
          // A wapp reports absolute like/reply counts for a post (mid) it tracks
          // itself. Generic — the host just stores + renders them.
          final mid = (data['mid'] ?? '').toString();
          if (mid.isNotEmpty) {
            _wappPostStats[mid] = (
              likes: (data['likes'] as num?)?.toInt() ?? 0,
              replies: (data['replies'] as num?)?.toInt() ?? 0,
              mine: data['mine'] == true,
            );
            if (_wappPostStats.length > 1000) {
              _wappPostStats.remove(_wappPostStats.keys.first);
            }
            _activityRev.value++; // refresh an open thread's like/reply counts
            changed = true;
          }
        } else if (type == 'ui.profile.set') {
          // A wapp resolves one of its post authors (by the post's `from`) to a
          // display name + avatar + bio. Generic — the host just stores it.
          final key = (data['key'] ?? '').toString();
          if (key.isNotEmpty) {
            // MERGE into any existing entry so a later sparse push (e.g. just an
            // npub) never clobbers an already-resolved name/avatar.
            final merged = Map<String, String>.from(
              _wappProfiles[key] ?? const {},
            );
            for (final f in const [
              'name',
              'pic',
              'about',
              'nip05',
              'npub',
              'website',
              'lud16',
              'banner',
            ]) {
              final v = (data[f] ?? '').toString();
              if (v.isNotEmpty) merged[f] = v;
            }
            _wappProfiles[key] = merged;
            if (_wappProfiles.length > 4000) {
              _wappProfiles.remove(_wappProfiles.keys.first);
            }
            _saveWappProfilesCacheSoon(); // keep it resolved across views/restarts
            _activityRev.value++; // refresh open thread's author names/avatars
            changed = true;
          }
        } else if (type == 'ui.activity.filter') {
          // The wapp pushes the set of callsigns to hide from Activity (blocked
          // + muted). Existing + future posts from them are filtered out.
          final calls = (data['calls'] as List?) ?? const [];
          _activityHidden = {for (final c in calls) c.toString().toUpperCase()};
          changed = true;
        } else if (type == 'social.note') {
          // A wapp (APRS) tells the host to store one of OUR posts (a group
          // bulletin or Activity message) as a signed NOSTR note, so peers can
          // request our posts later. Generic on the host side.
          final text = (data['text'] ?? '').toString();
          final topic = (data['topic'] ?? '').toString();
          final parent = (data['parent'] ?? '').toString();
          if (text.isNotEmpty) {
            unawaited(() async {
              // Embed a tiny preview thumbnail so peers can show a picture for
              // this post without downloading the full media first.
              final enriched = await _embedNoteThumbnail(text);
              await RnsService.instance.publishNote(
                enriched,
                topic: topic.isEmpty ? null : topic,
                parent: parent.isEmpty ? null : parent,
              );
            }());
          }
        } else if (type == 'ui.toast') {
          // Legacy message shape — route through the unified service
          // so old wapps inherit system-tray delivery + history.
          NotificationService.instance.show(
            GeogramNotification(
              level: NotificationLevel.info,
              title: _wappName,
              body: data['message'] as String? ?? '',
              source: 'wapp:$_wappName',
            ),
          );
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
          NotificationService.instance.show(
            GeogramNotification(
              level: level,
              title: data['title'] as String? ?? _wappName,
              body: data['body'] as String?,
              source: 'wapp:$_wappName',
              tag: data['tag'] as String?,
              scope: scope,
            ),
          );
        } else if (type == 'unread') {
          final count = (data['count'] as num?)?.toInt();
          if (count != null) {
            WappUnreadService.instance.setCount(
              _wappName,
              count,
              intent: data['intent']?.toString(),
            );
          }
        } else if (type.startsWith('hero.')) {
          // A card on the launcher's hero carousel. Handled identically here and
          // in BackgroundWappManager, because a wapp that publishes one is
          // usually headless when it does (a blog fetching in the background is
          // the motivating case).
          HeroInbox.instance.handleMessage(_wappName, data);
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
          unawaited(
            FunctionalityBroker.instance.handleRequest(
              callerEngineId: _engine.engineId,
              functionalityId: data['widget'] as String? ?? '',
              reqId: data['req_id'] as String? ?? '',
              args: (data['args'] as Map<String, dynamic>?) ?? const {},
            ),
          );
        } else if (type == 'compile') {
          unawaited(_handleCompile(data));
        } else if (type == 'install') {
          unawaited(_handleInstall(data));
        } else if (type == 'file.pick') {
          // A wapp wants the user to pick a file (e.g. movies'
          // pick_video / pick_subtitle). Show the native picker and
          // deliver the result back as a file.open message.
          unawaited(_handleFilePick(data));
        } else if (type == 'media.session') {
          _handleMediaSession(data);
        } else if (type == 'fs.pick') {
          // A wapp wants the user to browse and pick a file OR folder (Files
          // wapp "Add / Share"). Show the file/folder navigator; deliver the
          // result back as fs.picked {path, dir}.
          unawaited(_handleFsPick(data));
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
      } catch (e) {
        // A wapp emitted a message the host couldn't parse — log it (it used to
        // be swallowed silently, which hid a malformed-JSON catalog for ages).
        LogService.instance.add(
          'wapp/$_wappName: dropped unparseable message ($e, ${raw.length}B)',
        );
      }
    }
    if (changed && mounted) {
      _syncAppBadge();
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
            _scrollController.jumpTo(
              _scrollController.position.maxScrollExtent,
            );
          }
        });
      }
    }
  }

  Future<void> _handleFetchIndex(Map<String, dynamic> data) async {
    final source = data['source'] as String? ?? '';
    if (source.isEmpty) return;

    // A signed Reticulum folder source (npub… / hex folder id / rns: scheme):
    // browse the folder over Reticulum and build the catalog from it. Same
    // decentralized, signature-verified delivery as the app updater — the wapp
    // store can be shared peer-to-peer with no central web host.
    if (_isRnsFolderSource(source)) {
      await _fetchIndexFromRns(_rnsFolderAddr(source));
      return;
    }

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

  /// True when a wapp-store source points at a signed Reticulum folder rather
  /// than an HTTP catalog or a local path: an `npub1…` address, a 64-hex folder
  /// id, or an explicit `rns:` / `reticulum:` scheme.
  static bool _isRnsFolderSource(String s) {
    final t = s.trim();
    final lower = t.toLowerCase();
    if (lower.startsWith('rns:') || lower.startsWith('reticulum:')) return true;
    if (lower.startsWith('npub1')) return true;
    return RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(t);
  }

  /// Strip any `rns:` / `reticulum:` (optionally `//`) scheme, leaving the bare
  /// folder address (npub or hex) that RnsService.folder* accepts.
  static String _rnsFolderAddr(String s) {
    var t = s.trim();
    final lower = t.toLowerCase();
    if (lower.startsWith('reticulum://')) {
      t = t.substring(12);
    } else if (lower.startsWith('reticulum:')) {
      t = t.substring(10);
    } else if (lower.startsWith('rns://')) {
      t = t.substring(6);
    } else if (lower.startsWith('rns:')) {
      t = t.substring(4);
    }
    return t.trim();
  }

  /// The publisher npub of a browsed folder: the folder's owner key (folderId
  /// is the owner's secp256k1 public key) encoded as an npub, so the store card
  /// shows the verified publisher. Falls back to [addr] when it's already an
  /// npub and the state carries no folderId.
  static String _rnsOwnerNpub(Map<String, dynamic> state, String addr) {
    final fid = (state['folderId'] as String? ?? '').trim();
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(fid)) {
      try {
        return NostrCrypto.encodeNpub(fid.toLowerCase());
      } catch (_) {}
    }
    return addr.toLowerCase().startsWith('npub1') ? addr.trim() : '';
  }

  /// Build the store catalog from a signed Reticulum folder and hand it to the
  /// store wapp as a `wapp.index` message — the Reticulum equivalent of
  /// fetching `index.json` over HTTP. The folder is expected to hold the .wapp
  /// binaries plus (ideally) an `index.json` catalog with the same shape as the
  /// HTTP store; when present we reuse it verbatim and only rewrite each entry's
  /// `file` to the content sha (the fetch handle) so install can pull it by
  /// hash. With no index.json we synthesise a catalog from the `<id>-<ver>.wapp`
  /// filenames. Every entry is stamped with the folder owner's npub.
  Future<void> _fetchIndexFromRns(String addr) async {
    try {
      // Fast path: the local/cached folder reduction — instant when we own the
      // folder or already mirrored/cached it (e.g. the host's own catalog). Only
      // fall back to a (slow) network browse when we have nothing cached yet, so
      // the store never blocks on DHT round-trips for a folder it already holds.
      var state = RnsService.instance.folderBrowse(addr);
      var files = (state['files'] as List?) ?? const [];
      if (files.isEmpty) {
        state = await RnsService.instance.folderBrowseAsync(addr);
        files = (state['files'] as List?) ?? const [];
      }
      final ownerNpub = _rnsOwnerNpub(state, addr);

      // Index the folder by leaf filename -> {sha, size}.
      final byBasename = <String, Map<String, dynamic>>{};
      String? indexSha;
      for (final f in files) {
        if (f is! Map) continue;
        final name = (f['name'] ?? '').toString();
        final sha = (f['x'] ?? '').toString();
        if (name.isEmpty || sha.isEmpty) continue;
        final base = name.split('/').last;
        byBasename[base] = {'sha': sha, 'size': f['size']};
        if (base == 'index.json') indexSha = sha;
      }

      List<dynamic> catalog;
      if (indexSha != null) {
        final bytes = await RnsService.instance.folderFetchBytes(
          addr,
          indexSha,
        );
        if (bytes == null) {
          _outputLines.add(
            _OutputLine(
              'Could not fetch index.json from the Reticulum folder '
                  '(no provider online yet)',
              'err',
            ),
          );
          if (mounted) setState(() {});
          return;
        }
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is List) {
          catalog = decoded;
        } else if (decoded is Map && decoded['wapps'] is List) {
          catalog = decoded['wapps'] as List;
        } else {
          catalog = const [];
        }
      } else {
        // Synthesise from `<id>-<version>.wapp` filenames.
        catalog = [];
        final re = RegExp(
          r'^(.+)-(\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z.]+)?)\.wapp$',
        );
        for (final base in byBasename.keys) {
          if (!base.endsWith('.wapp')) continue;
          final m = re.firstMatch(base);
          final id = m != null
              ? m.group(1)!
              : base.substring(0, base.length - 5);
          final ver = m != null ? m.group(2)! : '1.0.0';
          catalog.add(<String, dynamic>{
            'name': id,
            'version': ver,
            'file': base,
            'description': id,
          });
        }
      }

      // Rewrite each entry's `file` to the content sha so do_install can fetch
      // by hash, and stamp the verified publisher.
      _catalogIcons.clear();
      _catalogMeta.clear();
      _catalogSourceAddr = addr;
      final enriched = <dynamic>[];
      for (final raw in catalog) {
        if (raw is! Map) {
          enriched.add(raw);
          continue;
        }
        final entry = Map<String, dynamic>.from(raw.cast<String, dynamic>());
        // Keep `file` as the leaf FILENAME (e.g. "aprs-0.2.60.wapp") — the store
        // derives the wapp slug/name from it, and _installWappFromRns resolves
        // the filename back to its content sha at install time. (Rewriting it to
        // the sha here made every card's name show the hash.) Just fill size.
        final fileField = (entry['file'] ?? '').toString();
        final leaf = fileField.split('/').last;
        final hit = byBasename[leaf];
        if (hit != null && entry['size'] == null && hit['size'] != null) {
          entry['size'] = hit['size'];
        }
        if (ownerNpub.isNotEmpty) entry['publisher_npub'] = ownerNpub;
        // Lift the inline SVG icon into the host-side map (keyed by the leaf
        // filename, which is the card id the store echoes back) and strip it
        // from the entry so the wasm payload stays small.
        final iconStr = (entry['icon'] ?? '').toString();
        if (iconStr.isNotEmpty && leaf.isNotEmpty) {
          try {
            _catalogIcons[leaf] = Uint8List.fromList(utf8.encode(iconStr));
          } catch (_) {}
          entry.remove('icon');
        }
        // Record version + leaf by slug so the host can decide install/update
        // state and drive "Update all".
        if (leaf.isNotEmpty) {
          _catalogMeta[_wappSlug(leaf)] = {
            'version': (entry['version'] ?? '').toString(),
            'file': leaf,
          };
        }
        enriched.add(entry);
      }

      await _refreshInstalledVersions();
      _engine.sendMessage(jsonEncode({'type': 'wapp.index', 'data': enriched}));
      // Pump until the wapp has consumed every queued message — it handles one
      // per call, so a single handleEvent() could process a stale message ahead
      // of ours and leave wapp.index unprocessed.
      var guard = 0;
      while (_engine.inboxLength > 0 && guard++ < 64) {
        _engine.handleEvent();
      }
      _drainOutbox();
      if (mounted) setState(() {});
    } catch (e) {
      _outputLines.add(
        _OutputLine('Failed to read Reticulum folder: $e', 'err'),
      );
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
        final candidates = <String>['$archiveRoot/$name', '$indexDir/$name'];
        for (final candidate in candidates) {
          final pkg = wappPackageStorage(candidate);
          if (pkg.existsSync('signature.json')) {
            final npub = WappSigningService.instance.readPublisherNpubSync(pkg);
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

    // Signed Reticulum folder source: fetch the .wapp bytes by content sha over
    // Reticulum (the enriched catalog put the sha in `file`), verify-on-fetch,
    // and install. Records an `rns` reload source so Reload re-fetches P2P.
    if (_isRnsFolderSource(source)) {
      await _installWappFromRns(
        _rnsFolderAddr(source),
        filePath,
        name,
        version,
      );
      return;
    }

    // Resolve the source dir (may be a .json path or a plain directory).
    var baseDir = source;
    if (baseDir.endsWith('.json')) {
      final slashIdx = baseDir
          .replaceAll(platform.pathSeparator, '/')
          .lastIndexOf('/');
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
          wappId: _wappSlug(name),
          url: '$base/$filePath',
        );
      } else {
        final srcStorage = wappPackageStorage(baseDir);
        if (!await srcStorage.exists(filePath)) {
          _outputLines.add(
            _OutputLine('File not found: $baseDir/$filePath', 'err'),
          );
          if (mounted) setState(() {});
          return;
        }
        final archiveBytes = await srcStorage.readBytes(filePath);
        if (archiveBytes == null || archiveBytes.isEmpty) {
          _outputLines.add(
            _OutputLine('Empty or missing .wapp: $filePath', 'err'),
          );
          if (mounted) setState(() {});
          return;
        }
        result = await WappInstallerService.instance.installFromBytes(
          wappId: _wappSlug(name),
          zipBytes: Uint8List.fromList(archiveBytes),
          source: WappSource.file('$baseDir/$filePath'),
        );
      }
      if (!result.ok) {
        _outputLines.add(_OutputLine(result.error ?? 'Install failed', 'err'));
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
      await _refreshInstalledVersions();

      _outputLines.add(_OutputLine('$name v$version installed', 'info'));
      if (mounted) setState(() {});
    } catch (e) {
      _outputLines.add(_OutputLine('Install failed: $e', 'err'));
      if (mounted) setState(() {});
    }
  }

  /// Install a wapp from a signed Reticulum folder. [fileRef] is the content
  /// sha (set by the enriched catalog); if it isn't a bare sha we resolve it by
  /// leaf filename against a fresh browse. The bytes are fetched + content-
  /// verified by RnsService.folderFetchBytes; the device then re-seeds the
  /// .wapp so the store works peer-to-peer.
  Future<void> _installWappFromRns(
    String addr,
    String fileRef,
    String name,
    String version,
  ) async {
    try {
      var sha = fileRef.trim();
      if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha)) {
        // Resolve a filename back to its sha via a fresh browse.
        final state = await RnsService.instance.folderBrowseAsync(addr);
        final base = sha.split('/').last;
        sha = '';
        for (final f in (state['files'] as List?) ?? const []) {
          if (f is! Map) continue;
          if ((f['name'] ?? '').toString().split('/').last == base) {
            sha = (f['x'] ?? '').toString();
            break;
          }
        }
      }
      if (sha.isEmpty) {
        _outputLines.add(_OutputLine('Not found in folder: $fileRef', 'err'));
        if (mounted) setState(() {});
        return;
      }
      final bytes = await RnsService.instance.folderFetchBytes(
        addr,
        sha,
        ext: '.wapp',
      );
      if (bytes == null) {
        _outputLines.add(
          _OutputLine(
            'Could not fetch $name over Reticulum (no provider online yet)',
            'err',
          ),
        );
        if (mounted) setState(() {});
        return;
      }
      final result = await WappInstallerService.instance.installFromBytes(
        // Install under the stable slug so it overwrites the bundled wapp
        // (a real update) instead of creating a versioned junk directory.
        wappId: _wappSlug(name),
        zipBytes: bytes,
        source: WappSource.rns(addr, sha),
      );
      if (!result.ok) {
        _outputLines.add(_OutputLine(result.error ?? 'Install failed', 'err'));
        if (mounted) setState(() {});
        return;
      }
      _engine.sendMessage(
        jsonEncode({
          'type': 'wapp.installed',
          'name': name,
          'version': version,
        }),
      );
      _engine.handleEvent();
      _drainOutbox();
      await _refreshInstalledVersions();
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

  // ── Media session (Player music/radio: background + lock-screen) ─────
  /// The wapp reported its playback state. Forward it to the native
  /// MediaSession (lock-screen / notification controls) and track whether
  /// audio is active so we keep this page's engine alive in the background.
  void _handleMediaSession(Map<String, dynamic> data) {
    final state = (data['state'] as String? ?? 'stopped');
    final active = state == 'playing' || state == 'paused';
    _mediaActive = active;
    if (active) {
      // Make sure the OS routes transport buttons back to this page.
      AndroidForegroundService.instance.onMediaAction = _onMediaAction;
      unawaited(
        AndroidForegroundService.instance.mediaUpdate({
          'state': state,
          'title': data['title']?.toString() ?? '',
          'artist': data['artist']?.toString() ?? '',
          'durationMs': (data['durationMs'] as num?)?.toInt() ?? 0,
          'positionMs': (data['positionMs'] as num?)?.toInt() ?? 0,
          'canNext': data['canNext'] == true,
          'canPrev': data['canPrev'] == true,
        }),
      );
    } else {
      unawaited(AndroidForegroundService.instance.mediaStop());
    }
  }

  /// A lock-screen / notification transport button was pressed. Forward it to
  /// the wapp as the matching command (the Player handles these already).
  void _onMediaAction(String action) {
    final cmd = switch (action) {
      'play' || 'pause' => 'playpause',
      'next' => 'next',
      'previous' || 'prev' => 'prev',
      'stop' => 'playpause',
      _ => '',
    };
    if (cmd.isEmpty) return;
    _sendCommand(cmd);
    _engine.handleEvent();
    _drainOutbox();
  }

  /// One engine tick driven by the native heartbeat while this page is the
  /// background media owner (keeps decoding + feeding the speaker, screen off).
  void _bgTick() {
    try {
      _engine.tick();
      _drainOutbox();
    } catch (_) {}
  }

  // ── Video bridge (movies wapp `$type:"video"` group) ────────────────

  /// Lazily create a [MediaSession] from the active media.video backend
  /// the first time the wapp asks to load a video. No-op (stays null)
  /// when the mediapack capability isn't installed/supported.
  void _ensureVideoStack() {
    if (_mediaSession != null) return;
    final session = MediaCapabilities.newSession();
    if (session == null) return;
    _mediaSession = session;
    // Wire THIS wapp's wasm decoder to the render session. The frame-sink
    // imports forward decoded RGBA/PCM from _engine to the session; both
    // live in this State, so routing is 1:1 (no global session registry).
    if (session is WasmVideoSession) {
      _engine.onVideoConfig = session.configure;
      _engine.onVideoFrame = session.pushFrame;
      _engine.onVideoEnd = session.markEnded;
      // Audio stays on _audioOut (wired at load); the session uses it as the
      // A/V master clock so video tracks its real playback position.
      session.masterClock = () =>
          _audioOut?.active == true ? _audioOut!.playedPosition : null;
    }
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
      _engine.sendMessage(
        jsonEncode({
          'type': 'file.open',
          'path': path,
          'name': file.name,
          'extension': ext,
          'mode': mode,
          'size': -1,
        }),
      );
      _engine.handleEvent();
      _drainOutbox();
    } catch (_) {}
  }

  /// Attach a file to the chat composer: pick a file (native dialog), archive
  /// it into the shared media archive, advertise it on Reticulum so receivers
  /// can fetch it, and return its `file:<sha>.<ext>` token to insert.
  Future<String?> _attachFileToChat() async {
    try {
      const images = XTypeGroup(
        label: 'Images',
        extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic'],
      );
      const any = XTypeGroup(label: 'All files');
      final file = await openFile(acceptedTypeGroups: const [images, any]);
      if (file == null) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      final dot = file.name.lastIndexOf('.');
      final ext = dot >= 0 ? file.name.substring(dot + 1).toLowerCase() : 'bin';
      return attachMediaFile(bytes, ext, name: file.name);
    } catch (_) {
      return null;
    }
  }

  /// Browse and pick a file OR folder; return it to the wapp as fs.picked.
  /// data: {title, mode: "both"|"file"|"folder", initial}
  Future<void> _handleFsPick(Map<String, dynamic> data) async {
    final mode = (data['mode'] as String?) ?? 'both';
    try {
      final res = await FileFolderPicker.show(
        context,
        title: (data['title'] as String?) ?? 'Add / Share',
        initialDirectory: data['initial'] as String?,
        allowFileSelect: mode != 'folder',
        allowFolderSelect: mode != 'file',
      );
      if (res == null) return;
      final name = res.path.split('/').last;
      _engine.sendMessage(
        jsonEncode({
          'type': 'fs.picked',
          'path': res.path,
          'name': name,
          'dir': res.isDir,
        }),
      );
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
            bindings: _WappFieldBindings(
              _engine,
              _fieldValues,
              () => setState(() {}),
            ),
            i18n: _i18n,
            onAction: (action) {
              _engine.sendMessage(
                jsonEncode({'type': 'action', 'action': action}),
              );
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
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
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
    PreferencesService.instanceSync?.setWappFields(
      _wappName,
      jsonEncode(scalarFields),
    );
    _engine.sendMessage(jsonEncode({'command': cmd, 'fields': scalarFields}));
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
    // Only room actions are rendered by the widget; slot:"list" actions go to
    // the AppBar (_convListActions) so they cost no screen row.
    final roomActions = <ConvAction>[];
    for (final a in group.childrenOf('action')) {
      if ((a.getString('slot') ?? 'list') != 'room') continue;
      roomActions.add(
        ConvAction(
          a.name ?? '',
          a.getString('icon') ?? 'add',
          a.getString('tip') ?? a.name ?? '',
          label: a.getString('label') ?? '',
        ),
      );
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
      // slot:"menu" → rendered as a checkable item in the room options menu
      // (top-right ☰), not as a checkbox above the composer.
      if ((f.getString('slot') ?? '') == 'menu') continue;
      toggles.add(
        ComposerToggle(
          name,
          f.getString('label') ?? name,
          value,
          localOnly: f.getBool('localOnly') ?? false,
        ),
      );
    }
    return ConversationsField(
      store: store,
      roomActions: roomActions,
      toggles: toggles,
      // Host-controlled selection: in portrait the AppBar carries the open
      // thread's title + back arrow, so the widget skips its own header.
      openId: _convOpenId,
      onOpenChanged: (id) => setState(() {
        _convOpenId = id;
        // Opening a thread hands the AppBar to it — leave search behind.
        if (id != null) _convSearching = false;
      }),
      // The search icon lives in the AppBar (_convListActions); the widget only
      // renders the search field + results while this is on.
      searchOpen: _convSearching,
      onSearchClose: () => setState(() => _convSearching = false),
      showRoomHeader: false,
      // Sub-folder rail shown by default inside an open conversation; the wapp
      // pushes it (ui.rail.set field "conv_rail") when a conversation opens.
      roomRail: (_fieldValues['conv_rail'] is List)
          ? (_fieldValues['conv_rail'] as List)
                .whereType<Map>()
                .map((m) => m.cast<String, dynamic>())
                .toList()
          : const <Map<String, dynamic>>[],
      onRoomRailTap: (id) {
        _fieldValues['conv_rail_id'] = id;
        _sendCommand('conv_rail_tap');
      },
      onToggle: (name, value) => setState(() => _fieldValues[name] = value),
      onLocate: _locateFromMessage,
      onSenderTap: _showProfile,
      // Find-a-user search: the local database (known callsign↔key contacts +
      // follows) unioned with everyone currently visible on the Reticulum
      // network (observed announces). Tapping a result opens the full profile.
      onSearchPeople: (q) => RnsService.instance.searchPeople(q),
      onOpenProfile: (callsign, npub) =>
          _openProfile(callsign, npub: npub.isEmpty ? null : npub),
      onAttach: _attachFileToChat,
      onSelect: (id) {
        setState(() => store.clearUnread(id));
        _syncAppBadge();
        // Tell the wapp a conversation opened so it can populate the folder rail.
        _fieldValues['${field}_convo'] = id;
        _sendCommand('${field}_open');
      },
      onSend: (id, text) {
        _fieldValues['${field}_convo'] = id;
        _fieldValues['${field}_input'] = text;
        _sendCommand('${field}_send');
      },
      onAction: (name, openId) {
        _fieldValues['${field}_convo'] = openId;
        _sendCommand(name);
      },
      onForward: (id, m) => _showForwardPanel(field, store, m),
      onHide: (id, key) {
        _fieldValues['${field}_convo'] = id;
        _fieldValues['${field}_hidekey'] = key;
        _sendCommand('${field}_hide');
      },
      onBlock: (from) {
        if (from.isEmpty) return;
        _fieldValues['${field}_blockcall'] = from;
        _sendCommand('${field}_block');
      },
      onMute: (id, muted) {
        setState(() => store.setMuted(id, muted));
        _scheduleConvoSave(field);
        _syncAppBadge(); // muting drops it from the app-wide badge
      },
      onClose: (id) {
        setState(() {
          store.setClosed(id, true);
          if (_convOpenId == id) _convOpenId = null;
        });
        // Tell the wapp to unsubscribe so we stop receiving the group entirely.
        _fieldValues['${field}_convo'] = id;
        _sendCommand('${field}_close');
        _scheduleConvoSave(field);
        _syncAppBadge();
      },
    );
  }

  // ── Forward a message ──────────────────────────────────────────────────
  // A WhatsApp/Telegram-style picker: search a known contact (any conversation
  // we already have — DMs and group rooms) or type a fresh callsign / #group,
  // then re-send the message's text there. Forwarding reuses the normal send
  // path (no wire marker, so non-Aurora stations read it cleanly).
  void _showForwardPanel(
    String field,
    ConversationStore store,
    Map<String, dynamic> m,
  ) {
    final raw = (m['text'] ?? '').toString();
    if (raw.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => _ForwardPanel(
        contacts: store.ordered(),
        onPick: (target) {
          Navigator.pop(sheet);
          final id = target.trim();
          if (id.isEmpty) return;
          _fieldValues['${field}_convo'] = id;
          _fieldValues['${field}_input'] = raw;
          _sendCommand('${field}_send');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Forwarded to $id'),
                duration: const Duration(seconds: 1),
              ),
            );
          }
        },
      ),
    );
  }

  // Show a chat message's sender on the map: switch to the screen hosting the
  // map and frame the sender's location alongside our own (the radius centre)
  // so the two can be compared. Coordinates come from the message (lat/lon).
  // Highlighted target from the last "locate" tap (drawn as a reticle on the
  // map so the station is unmistakable).
  double? _locateLat, _locateLon;

  // An incoming chat message can carry a media token plus the seeder's
  // BitTorrent infohash + LAN peer hint ("file:<sha>.<ext> … ih:<40hex>
  // pa:<ip>:<port>"). The actual fetch lives in shared_media_fetch.dart so the
  // background manager runs it too (media arrives whatever screen we're on).
  void _maybeFetchSharedMedia(String text, String dir, [String? from]) =>
      maybeFetchSharedMedia(text, dir, from: from);

  void _locateFromMessage(Map<String, dynamic> m) {
    final lat = (m['lat'] as num?)?.toDouble();
    final lon = (m['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return;
    final idx = _tabScreens.indexWhere(
      (s) => s.children.any((c) => c.keyword == 'group' && c.type == 'map'),
    );
    if (idx >= 0) {
      if (_panelScreen != null) _panelScreen = null; // leave any open panel
      if (_tabController != null && _tabController!.index != idx) {
        _tabController!.animateTo(idx);
      }
    }
    // Centre directly on the target and zoom in so it's clearly visible. The
    // zoom adapts to how far the station is from us (closer → tighter) but is
    // clamped to a zoomed-in range so the target is always easy to see.
    final myLat = _mapCenterLat, myLon = _mapCenterLon;
    int zoom = 14;
    if (myLat != null && myLon != null) {
      final span =
          (max((myLat - lat).abs(), (myLon - lon).abs()) * 2.2) + 0.003;
      zoom = (log(360 * 700 / (256 * span)) / log(2)).clamp(12, 16).floor();
    }
    setState(() {
      _mapLat = lat;
      _mapLon = lon;
      _mapZoom = zoom;
      _locateLat = lat;
      _locateLon = lon;
      // Show the located station, not the fitted coverage circle, when the
      // map (re)mounts for this navigation.
      _mapAutoFit = false;
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
    // Optional: text the user can copy to the clipboard (e.g. a file token /
    // sha). Renders a Copy button under the body — the only way to grab a
    // reference on a touch device.
    final copyText = (data['copy'] ?? '').toString();
    final chips =
        (data['chips'] as List?)
            ?.whereType<Map>()
            .map(
              (c) => MapEntry(
                (c['label'] ?? '').toString(),
                (c['value'] ?? '').toString(),
              ),
            )
            .toList() ??
        const <MapEntry<String, String>>[];
    final instant = (data['chipMode'] ?? 'instant') == 'instant';
    final input = data['input'] as Map?;
    final confirmLabel = (data['confirm'] ?? '').toString();
    // Optional boolean toggle (e.g. a Local/Global scope switch). Generic: the
    // wapp gets its state back as prompt_toggle.
    final toggle = data['toggle'] as Map?;
    final toggleLabel = (toggle?['label'] ?? '').toString();

    final controller = TextEditingController(
      text: (input?['value'] ?? '').toString(),
    );
    // Selection + toggle state live in the method scope so they persist across
    // StatefulBuilder rebuilds and are shared by the dialog and full-screen
    // renderers below.
    String selected = '';
    bool toggleOn = (toggle?['default'] == true);
    // A wapp can request a full-screen panel (vs the compact centred dialog)
    // for prompts that deserve more room — e.g. the "Add a group" picker.
    final fullscreen = data['fullscreen'] == true;
    void result(String value, String text) {
      _fieldValues['prompt_id'] = id;
      _fieldValues['prompt_value'] = value;
      _fieldValues['prompt_input'] = text;
      _fieldValues['prompt_toggle'] = toggleOn;
      _sendCommand('prompt');
    }

    void confirm(BuildContext ctx) {
      final t = controller.text.trim();
      if (t.isEmpty && selected.isEmpty) return;
      Navigator.pop(ctx);
      result(selected, t);
    }

    // The prompt body, shared by both renderers. The toggle (e.g. a Local/
    // Global scope switch) is rendered FIRST — on top — so the scope choice is
    // the first thing the user sees and sets.
    Widget content(BuildContext ctx, void Function(VoidCallback) setLocal) {
      final cs = Theme.of(ctx).colorScheme;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (toggleLabel.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(toggleLabel, style: const TextStyle(fontSize: 14)),
                value: toggleOn,
                onChanged: (v) => setLocal(() => toggleOn = v),
              ),
            ),
          if (body.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SelectableText(
                body,
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5),
              ),
            ),
          if (copyText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: copyText));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Copied to clipboard'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
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
                          onSelected: (_) => setLocal(() => selected = c.value),
                        ),
              ],
            ),
          if (input != null) ...[
            const SizedBox(height: 14),
            TextField(
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
              onSubmitted: (_) => confirm(ctx),
            ),
          ],
        ],
      );
    }

    if (fullscreen) {
      // A dedicated full-screen panel: roomy, with the title + actions in an
      // app bar so the picker isn't cramped.
      showDialog<void>(
        context: context,
        useSafeArea: false,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setLocal) => Dialog.fullscreen(
            child: Scaffold(
              appBar: AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(ctx),
                ),
                title: Text(title),
                actions: [
                  if (confirmLabel.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilledButton(
                        onPressed: () => confirm(ctx),
                        child: Text(confirmLabel),
                      ),
                    ),
                ],
              ),
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: content(ctx, setLocal),
              ),
            ),
          ),
        ),
      );
      return;
    }

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final mq = MediaQuery.of(ctx).size;
          return AlertDialog(
            title: Text(title),
            // A roomy, easily-scrollable panel — nearly full width and up to
            // 70% of the screen height — so a long chip list scrolls
            // comfortably instead of a cramped little dialog.
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 24,
            ),
            content: SizedBox(
              width: mq.width,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: mq.height * 0.7),
                child: SingleChildScrollView(child: content(ctx, setLocal)),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              if (confirmLabel.isNotEmpty)
                FilledButton(
                  onPressed: () => confirm(ctx),
                  child: Text(confirmLabel),
                ),
            ],
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    RnsService.instance.removeProfileListener(_onProfilesChanged);
    RnsService.instance.removeNostrListener(_onNostrChanged);
    _nostrSearchCtl.dispose();
    _feedBackfillTimer?.cancel();
    _fastBackfillTimer?.cancel();
    _tickTimer?.cancel();
    // Flush any pending conversation writes so the latest messages aren't lost.
    _convSaveTimer?.cancel();
    if (_convDirty.isNotEmpty) unawaited(_flushConvoSaves());
    TaskMonitorService.instance.unregister(_tickTaskId);
    EventBus().fire(WappUnloadedEvent(wappId: _wappName, wappName: _wappName));
    _localeSub?.cancel();
    // Tear down the media session if the video group was used. Drop the
    // engine's frame-sink callbacks first so a late frame can't touch a
    // disposed session.
    _engine.onVideoConfig = null;
    _engine.onVideoFrame = null;
    _engine.onAudioPcm = null;
    _engine.onVideoEnd = null;
    _mediaSession?.dispose();
    _mediaSession = null;
    // Tear down media keep-alive + the lock-screen notification.
    if (_bgKeepAlive) {
      BackgroundWappManager.instance.releasePage(_wappName);
      _bgKeepAlive = false;
    }
    if (_mediaActive) {
      AndroidForegroundService.instance.onMediaAction = null;
      unawaited(AndroidForegroundService.instance.mediaStop());
      _mediaActive = false;
    }
    _audioOut?.dispose();
    _audioOut = null;
    _searchDebounce?.cancel();
    for (final c in _searchCtl.values) {
      c.dispose();
    }
    _searchCtl.clear();
    _videoCurrentPath = null;
    _graphData.dispose();
    _graphHubs.dispose();
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
  /// Hex pubkey behind an npub. "Keep data" is stored against the hex key
  /// because the mirror, the retention tiers and the relay store all speak hex;
  /// null for a contact we only know by callsign.
  static String? _keepHexOf(String? npub) {
    if (npub == null || npub.isEmpty) return null;
    try {
      final hex = NostrCrypto.decodeNpub(npub);
      return hex.length == 64 ? hex.toLowerCase() : null;
    } catch (_) {
      return null;
    }
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

    // A menu screen opened as a full panel: shares this state (so live updates
    // still flow) and has a back arrow that returns to the tab view.
    if (_panelScreen != null) {
      // Management actions on a folder-view panel (rail + chat) collapse into a
      // single top-right gear menu. Settings-form panels render their own action
      // buttons inline, so they don't get the gear (avoids duplicates).
      final isFolderView = _panelScreen!.children.any(
        (c) => c.keyword == 'field' && c.type == 'rail',
      );
      final panelActions = isFolderView
          ? _panelScreen!.children
                .where(
                  (c) => c.keyword == 'action' && (c.name ?? '').isNotEmpty,
                )
                .toList()
          : const <GeoUiBlock>[];
      return PopScope(
        canPop: false,
        onPopInvoked: (didPop) {
          if (!didPop) setState(() => _panelScreen = null);
        },
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Back',
              onPressed: () => setState(() => _panelScreen = null),
            ),
            title: Text(_panelTitle ?? _panelName),
            actions: [
              if (panelActions.isNotEmpty)
                PopupMenuButton<String>(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: 'Settings',
                  onSelected: _sendCommand,
                  itemBuilder: (_) => [
                    for (final a in panelActions)
                      PopupMenuItem<String>(
                        value: a.name!,
                        child: Row(
                          children: [
                            Icon(
                              geoUiResolveIcon(
                                a.getString('icon') ?? 'settings',
                              ),
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              _i18n.resolve(a.getString('label') ?? a.name!),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
            ],
          ),
          body: _buildScreen(_panelScreen!),
        ),
      );
    }

    final tabView = TabBarView(
      controller: _tabController,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (var i = 0; i < _tabScreens.length; i++)
          _buildScreen(_tabScreens[i]),
      ],
    );
    // Top-tab navigation: the primary screens (Activity, Messages, Geochat,
    // Follows…) are equal tabs in a horizontal bar at the top — tapping one
    // switches content inline, no per-panel back button.
    final idx = _tabController!.index;
    final showTabs = _tabScreens.length > 1;

    // Thread chrome: in portrait, an open conversation takes over the AppBar
    // (its title + a back arrow that returns to the list) — the conversations
    // widget itself renders headerless. The wide side-by-side layout keeps its
    // own in-panel header instead. This back arrow is intra-Messages (closing a
    // conversation), distinct from tab navigation.
    final convGroup = _tabScreens[idx].children
        .where((c) => c.keyword == 'group' && c.type == 'conversations')
        .firstOrNull;
    ConversationItem? thread;
    var convField = '';
    if (convGroup != null &&
        _convOpenId != null &&
        MediaQuery.of(context).size.width < 640) {
      convField = convGroup.name ?? 'conversations';
      thread = _convStore(convField).items[_convOpenId];
    }

    // In-wapp drill navigation (e.g. folder → subfolder): the wapp owns the
    // depth; back drills up one level until it reports back:false at its root.
    final navBack = thread == null && _wappNavBack;

    return PopScope(
      // Intercept system-back to close an open reticulum-graph panel, a
      // conversation thread, or to drill up one in-wapp level. Otherwise back
      // leaves for the launcher.
      canPop: _graphPanelBack == null && thread == null && !navBack,
      onPopInvoked: (didPop) {
        if (didPop) return;
        if (_graphPanelBack != null) {
          _graphPanelBack!();
        } else if (thread != null) {
          setState(() => _convOpenId = null);
        } else if (navBack) {
          _sendCommand('nav_back');
        }
      },
      child: Scaffold(
        backgroundColor: ChatPalette.windowBg,
        appBar: AppBar(
          backgroundColor: ChatPalette.windowBg,
          foregroundColor: ChatPalette.text,
          leading: _graphPanelBack != null
              // A reticulum-graph full-screen panel is open: the single back
              // arrow closes it (no second in-panel arrow).
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back',
                  onPressed: _graphPanelBack,
                )
              : thread != null
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back',
                  onPressed: () => setState(() => _convOpenId = null),
                )
              : navBack
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Up',
                  onPressed: () => _sendCommand('nav_back'),
                )
              : null, // default "←" pops back to the launcher
          title: _graphPanelTitle != null
              ? Text(_graphPanelTitle!)
              : thread != null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      thread.title.isEmpty ? thread.id : thread.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (thread.badge.isNotEmpty)
                      Text(
                        thread.badge,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                )
              : Text(navBack ? _wappNavTitle! : widget.title),
          // The horizontal tab bar lives under the title. Hidden while a
          // conversation thread or a graph panel takes over the screen.
          bottom: (showTabs && thread == null && _graphPanelTitle == null)
              ? TabBar(
                  controller: _tabController,
                  labelColor: ChatPalette.accent,
                  indicatorColor: ChatPalette.accent,
                  unselectedLabelColor: ChatPalette.secondary,
                  isScrollable: _tabScreens.length > 4,
                  tabAlignment: _tabScreens.length > 4
                      ? TabAlignment.start
                      : TabAlignment.fill,
                  // Compact label so wider names (e.g. "Messages") fit a
                  // quarter-width tab without being clipped.
                  labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                  labelStyle: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                  unselectedLabelStyle: const TextStyle(fontSize: 11.5),
                  onTap: (i) {
                    _mapAutoFit =
                        true; // manual nav → frame the coverage circle
                    // Another tab's list is a different search context.
                    if (_convSearching) {
                      setState(() => _convSearching = false);
                    }
                    _setGeoChatOpen(_isGeoChatScreen(_tabScreens[i]));
                  },
                  tabs: [
                    for (var i = 0; i < _tabScreens.length; i++)
                      Tab(
                        icon: _railIcon(
                          i,
                          selected: _tabController!.index == i,
                        ),
                        text: _i18n.resolve(_tabNames[i]),
                        iconMargin: const EdgeInsets.only(bottom: 2),
                      ),
                  ],
                )
              : null,
          actions: _graphPanelTitle != null
              ? const [] // a graph panel owns the screen — no wapp options menu
              : [
                  ..._channelIndicators(),
                  // A menu screen that asks for it ("appbar": true) also gets a
                  // direct icon here, left of the ☰. Search is the case this is
                  // for: burying it in a menu makes people not use it, and a
                  // whole tab for something you reach for once an hour is worse.
                  ..._appBarPanelButtons(),
                  // The conversation list's own actions (search + the wapp's
                  // slot:"list" actions) — here rather than in a row of their own
                  // above the list.
                  ..._convListActions(convGroup, threadOpen: thread != null),
                  // A single top-right options menu (☰). When a conversation thread is
                  // open its room actions (e.g. Recurring bulletin, Private) are folded
                  // in at the top — no separate gear icon.
                  _buildWappOptionsMenu(
                    roomActions: (thread != null && convGroup != null)
                        ? convGroup
                              .childrenOf('action')
                              .where(
                                (a) =>
                                    (a.getString('slot') ?? 'list') == 'room',
                              )
                              .toList()
                        : const [],
                    // Per-conversation toggles (e.g. Include my location) folded into the
                    // same menu, checkable, when a conversation room is open.
                    roomToggles: (thread != null && convGroup != null)
                        ? convGroup
                              .childrenOf('field')
                              .where(
                                (f) =>
                                    f.type == 'bool' &&
                                    (f.getString('slot') ?? '') == 'menu',
                              )
                              .toList()
                        : const [],
                    roomConvField: convField,
                    roomConvId: _convOpenId,
                  ),
                ],
        ),
        body: tabView,
      ),
    );
  }

  /// Icon for a tab screen: the screen's declared `icon`, else inferred from
  /// its name.
  IconData _tabIcon(int i) {
    final declared = _tabScreens[i].getString('icon');
    if (declared != null && declared.isNotEmpty)
      return geoUiResolveIcon(declared);
    return _iconForScreen(_tabNames[i]);
  }

  /// True if [s] is the dedicated Geo Chat tab (a screen whose content is the
  /// `geochat` chat field).
  bool _isGeoChatScreen(GeoUiBlock s) => s.children.any(
    (c) => c.keyword == 'field' && c.type == 'chat' && c.name == 'geochat',
  );

  /// Push this wapp's total unread (all conversation stores + geo-chat) to the
  /// launcher tile badge (e.g. the APRS app icon on the main panel), keyed by
  /// the same folder id the launcher uses.
  void _syncAppBadge() {
    var total = _geoUnread;
    for (final s in _convStores.values) {
      total += s.totalUnread;
    }
    WappUnreadService.instance.setCount(
      BackgroundWappManager.folderName(widget.wappDir),
      total,
    );
  }

  /// Total unread across the conversation stores of a tab screen (Messages).
  int _tabUnread(int i) {
    var n = 0;
    for (final g in _tabScreens[i].children) {
      if (g.keyword == 'group' && g.type == 'conversations') {
        n += _convStore(g.name ?? 'conversations').totalUnread;
      }
    }
    return n;
  }

  /// Rail/tab icon for tab [i] with an unread badge: the Geo Chat tab uses the
  /// geo-chat counter; a Messages (conversations) tab uses the summed unread of
  /// its conversations.
  Widget _railIcon(int i, {required bool selected}) {
    final icon = Icon(
      _tabIcon(i),
      color: selected ? ChatPalette.accent : ChatPalette.secondary,
    );
    final count = _isGeoChatScreen(_tabScreens[i]) ? _geoUnread : _tabUnread(i);
    if (count <= 0) return icon;
    return Badge(
      label: Text(count > 99 ? '99+' : '$count'),
      textColor: Colors.white,
      backgroundColor: const Color(0xFFda3633),
      child: icon,
    );
  }

  /// An icon for a menu-screen entry, picked from its name (falls back to a
  /// generic panel icon). Purely cosmetic.
  IconData _iconForScreen(String name) {
    switch (name.toLowerCase()) {
      case 'activity':
      case 'home':
      case 'feed':
        return Icons.home_outlined;
      case 'messenger':
      case 'messages':
        return Icons.mail_outline;
      case 'map':
        return Icons.map_outlined;
      case 'geo chat':
      case 'geochat':
      case 'chat':
        return Icons.forum_outlined;
      case 'follows':
      case 'following':
        return Icons.people_outline;
      case 'folders':
        return Icons.folder_shared;
      case 'sharing':
      case 'share':
        return Icons.share;
      case 'library':
      case 'files':
        return Icons.folder;
      case 'settings':
        return Icons.settings;
      case 'tools':
        return Icons.build;
      case 'keys':
        return Icons.key;
      case 'beacon':
        return Icons.cell_tower;
      case 'about':
        return Icons.info_outline;
      default:
        return Icons.dashboard_outlined;
    }
  }

  /// Screen-level actions of the active tab when it is a people screen. People
  /// screens fill the body, so their actions have no inline home — they live in
  /// the top-right options menu instead of a separate in-panel dropdown.
  /// The icon a menu screen shows (its declared `icon`, else the name mapper).
  IconData _panelIcon(int i) {
    final declared = _menuScreens[i].getString('icon');
    return (declared != null && declared.isNotEmpty)
        ? geoUiResolveIcon(declared)
        : _iconForScreen(_menuNames[i]);
  }

  /// Fire one wapp action by name (the same message an inline `<action>` sends).
  void _onWappAction(String action) {
    _engine.sendMessage(jsonEncode({'type': 'action', 'action': action}));
    _engine.handleEvent();
    _drainOutbox();
  }

  /// Icon buttons in the app bar for menu screens flagged `"appbar": true`.
  /// They open exactly the same panel the options menu would — unless the screen
  /// also says `"popup": true`, in which case its actions ARE the button: a
  /// popup menu that fires them directly. A "+" that costs one tap to reach
  /// "Open a link" / "Share a folder" should not open a page to do it.
  List<Widget> _appBarPanelButtons() {
    final out = <Widget>[];
    for (var i = 0; i < _menuScreens.length; i++) {
      if (_menuScreens[i].getBool('appbar') != true) continue;
      final name = _menuNames[i];

      if (_menuScreens[i].getBool('popup') == true) {
        final actions = _menuScreens[i]
            .childrenOf('action')
            .where((a) => (a.name ?? '').isNotEmpty)
            .toList();
        if (actions.isEmpty) continue;
        out.add(
          PopupMenuButton<String>(
          tooltip: _i18n.resolve(name),
          icon: Icon(_panelIcon(i)),
          onSelected: _onWappAction,
          itemBuilder: (_) => [
            for (final a in actions)
              PopupMenuItem<String>(
                value: a.name!,
                child: Row(
                  children: [
                    if ((a.getString('icon') ?? '').isNotEmpty) ...[
                      Icon(geoUiResolveIcon(a.getString('icon')!), size: 20),
                      const SizedBox(width: 10),
                    ],
                      Text(_i18n.resolve(a.getString('label') ?? a.name!)),
                  ],
                ),
              ),
          ],
          ),
        );
        continue;
      }
      // The screen's own `icon` first — the name mapper only knows a handful
      // of well-known screens and falls back to a generic dashboard glyph,
      // which is how a Search panel ended up with a grid icon.
      // A notifications panel carries its unread count on the icon — that badge
      // IS the reason to look at it.
      final isNotif = _menuScreens[i].children.any(
        (c) => c.keyword == 'field' && c.name == 'notifications',
      );
      final unread = isNotif
          ? RnsService.instance.nostrNotificationsUnread()
          : 0;

      Widget button = IconButton(
        icon: Icon(_panelIcon(i)),
        tooltip: _i18n.resolve(name),
        onPressed: () {
          // (marking read happens in _buildNotificationsScreen, so every route
          // into the panel clears the badge — not just this one)
          setState(() {
            _panelScreen = _menuScreens[i];
            _panelName = name;
          });
        },
      );
      if (unread > 0) {
        button = Badge.count(count: unread, child: button);
      }
      out.add(button);
    }
    return out;
  }

  /// The conversation list's actions, rendered in the AppBar left of the ☰:
  /// people-search plus the wapp's `slot:"list"` actions (e.g. "New message",
  /// "Join a group"). They used to be a blue icon row above the list, which cost
  /// a whole screen row to carry two or three icons. Hidden while a thread is
  /// open — that thread owns the AppBar, and its `slot:"room"` actions are in ☰.
  List<Widget> _convListActions(
    GeoUiBlock? convGroup, {
    required bool threadOpen,
  }) {
    if (convGroup == null || threadOpen) return const [];
    final field = convGroup.name ?? 'conversations';
    // Compact hit boxes: a wapp can declare three of these (Circles: new, join,
    // plus search) and at the default 48dp pitch they sprawl across the bar and
    // squeeze the title. Grouped tight, they read as one cluster next to the ☰.
    const dense = BoxConstraints.tightFor(width: 36, height: 36);
    return [
      IconButton(
        tooltip: _convSearching ? 'Close search' : 'Find a user',
        icon: Icon(_convSearching ? Icons.close : Icons.search),
        padding: EdgeInsets.zero,
        constraints: dense,
        visualDensity: VisualDensity.compact,
        onPressed: () => setState(() => _convSearching = !_convSearching),
      ),
      for (final a in convGroup.childrenOf('action'))
        if ((a.getString('slot') ?? 'list') != 'room')
          IconButton(
            tooltip: _i18n.resolve(
              a.getString('tip') ?? a.getString('label') ?? a.name ?? '',
            ),
            icon: Icon(convIcon(a.getString('icon') ?? 'add')),
            padding: EdgeInsets.zero,
            constraints: dense,
            visualDensity: VisualDensity.compact,
            onPressed: () {
              _fieldValues['${field}_convo'] = _convOpenId ?? '';
              _sendCommand(a.name ?? '');
            },
          ),
      const SizedBox(width: 4),
    ];
  }

  List<GeoUiBlock> _activeScreenMenuActions() {
    final tc = _tabController;
    if (tc == null || _tabScreens.isEmpty) return const [];
    final s = _tabScreens[tc.index];
    // Screens whose body is a full-bleed field (people list or chat feed) can't
    // show inline action buttons, so their actions surface in the options menu.
    final fullBleed = s.children.any(
      (c) => c.keyword == 'field' && (c.type == 'people' || c.type == 'chat'),
    );
    if (!fullBleed) return const [];
    return s.children.where((c) => c.keyword == 'action').toList();
  }

  /// Compact channel/transport indicators for the AppBar (left of the menu),
  /// driven by the wapp's `ui.map.status` items. Each known channel shows as a
  /// small chip (NET, BLE, … future LoRa/radio) — coloured when active, dimmed
  /// when configured-but-inactive. Same colour scheme as the chat origin chips.
  List<Widget> _channelIndicators() {
    if (_mapStatus.isEmpty) return const [];
    // Only show a channel tag when that channel is actually available — a dimmed
    // "off" tag read as still-usable. Available ones are all green.
    const green = Color(0xFF34C759);
    final chips = <Widget>[];
    for (final s in _mapStatus) {
      final label = (s['label'] ?? '').toString();
      if (label.isEmpty || s['on'] != true) continue; // hide unavailable
      chips.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: green.withAlpha(40),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: green.withAlpha(130), width: 0.6),
            ),
            child: Text(
              label.toUpperCase(),
              style: const TextStyle(
                color: green,
                fontSize: 9,
                height: 1.1,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ),
      );
    }
    if (chips.isEmpty) return const [];
    return [
      Center(
        child: Row(mainAxisSize: MainAxisSize.min, children: chips),
      ),
      const SizedBox(width: 4),
    ];
  }

  /// Top-right options menu: the active screen's actions (for people screens),
  /// then any screens flagged `"menu": true` (open as panels), plus "Edit".
  Widget _buildWappOptionsMenu({
    List<GeoUiBlock> roomActions = const [],
    List<GeoUiBlock> roomToggles = const [],
    String roomConvField = '',
    String? roomConvId,
  }) {
    final actions = _activeScreenMenuActions();
    return PopupMenuButton<String>(
      icon: const Icon(Icons.menu),
      tooltip: 'Options',
      onSelected: (value) {
        if (value == 'edit') {
          _editThisWapp();
        } else if (value.startsWith('toggle:')) {
          // A per-conversation local toggle (e.g. Include my location): flip the
          // field value the next conversations_send will read.
          final n = value.substring(7);
          setState(() => _fieldValues[n] = !(_fieldValues[n] == true));
        } else if (value.startsWith('room:')) {
          // A conversation room action (e.g. Private, Recurring): tell the wapp
          // which conversation it applies to, then fire it.
          _fieldValues['${roomConvField}_convo'] = roomConvId;
          _sendCommand(value.substring(5));
        } else if (value.startsWith('action:')) {
          _sendCommand(value.substring(7));
        } else if (value.startsWith('panel:')) {
          final i = int.tryParse(value.substring(6)) ?? -1;
          if (i >= 0 && i < _menuScreens.length) {
            setState(() {
              _panelScreen = _menuScreens[i];
              _panelName = _menuNames[i];
            });
          }
        }
      },
      itemBuilder: (_) => [
        for (final f in roomToggles)
          CheckedPopupMenuItem<String>(
            value: 'toggle:${f.name ?? ''}',
            checked: _fieldValues[f.name] == true,
            child: Text(_i18n.resolve(f.getString('label') ?? f.name ?? '')),
          ),
        if (roomToggles.isNotEmpty && (roomActions.isNotEmpty))
          const PopupMenuDivider(),
        for (final a in roomActions)
          PopupMenuItem<String>(
            value: 'room:${a.name ?? ''}',
            child: ListTile(
              leading: Icon(convIcon(a.getString('icon') ?? 'settings')),
              title: Text(_i18n.resolve(a.getString('label') ?? a.name ?? '')),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
        if (roomActions.isNotEmpty || roomToggles.isNotEmpty)
          const PopupMenuDivider(),
        for (final a in actions)
          PopupMenuItem<String>(
            value: 'action:${a.name ?? ''}',
            child: ListTile(
              leading: Icon(
                geoUiResolveIcon(a.getString('icon') ?? 'settings'),
              ),
              title: Text(_i18n.resolve(a.getString('label') ?? a.name ?? '')),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
        if (actions.isNotEmpty) const PopupMenuDivider(),
        for (var i = 0; i < _menuScreens.length; i++)
          PopupMenuItem<String>(
            value: 'panel:$i',
            child: ListTile(
              // The screen's own icon when it declares one — the name mapper
              // only knows a few well-known screens (Search and Relay servers
              // both came out as a generic grid).
              leading: Icon(_panelIcon(i)),
              title: Text(_menuNames[i]),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
        if (_menuScreens.isNotEmpty) const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: 'edit',
          child: ListTile(
            leading: Icon(Icons.edit),
            // "Edit" alone reads as "edit something in this wapp" — the note,
            // the message, whatever is on screen. It opens the wapp's SOURCE in
            // the editor, which is a very different thing to click by accident.
            title: Text('Edit wapp'),
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

    // Native graph group — a generic `$type:"graph"` node-link surface,
    // rendered full-bleed by the graph3d 3D engine. Mirrors the map
    // full-bleed branch.
    final graphGroup = screen.children
        .where((c) => c.keyword == 'group' && c.type == 'graph')
        .firstOrNull;
    if (graphGroup != null) return _buildGraphScreen(screen, graphGroup);

    // Conversations (generic, data-driven messenger primitive) — host renders
    // the contact list + chat view from the wapp-pushed ConversationStore.
    final convoGroup = screen.children
        .where((c) => c.keyword == 'group' && c.type == 'conversations')
        .firstOrNull;
    if (convoGroup != null)
      return _buildConversationsScreen(screen, convoGroup);

    // Folder view — a `$type:"rail"` field renders a left navigation rail of
    // (permitted) sub-folders alongside the active area (a chat field). Generic:
    // the wapp pushes rail items via ui.rail.set and the chat via ui.chat.*.
    final railField = screen.children
        .where((c) => c.keyword == 'field' && c.type == 'rail')
        .firstOrNull;
    if (railField != null) return _buildFolderView(screen, railField);

    // Video group (movies wapp) — host renders the media_kit surface
    // with the screen's other children (the header-actions menu) as an
    // overlay so pick_video / pick_subtitle stay reachable.
    final videoGroup = screen.children
        .where((c) => c.keyword == 'group' && c.type == 'video')
        .firstOrNull;
    if (videoGroup != null) return _buildVideoScreen(screen, videoGroup);

    // Tasks viewer — host renders cards from the cached MonitoredTask
    // snapshot kept in _taskSnapshot, refreshed each time the wapp polls.
    final hasTasksGroup = screen.children.any(
      (c) => c.keyword == 'group' && c.type == 'tasks',
    );
    if (hasTasksGroup) {
      return _buildTasksScreen();
    }

    // Projects picker (App Creator) — host renders a list of installed
    // wapps so the user can pick one to edit or start a new one.
    final hasProjectsGroup = screen.children.any(
      (c) => c.keyword == 'group' && c.type == 'projects',
    );
    if (hasProjectsGroup) {
      return _buildProjectsScreen();
    }

    // Output-only screen (e.g. Shop catalog) — no command input
    final hasOutputGroup = screen.children.any(
      (c) => c.keyword == 'group' && c.type == 'output',
    );
    if (hasOutputGroup) {
      return _buildOutputScreen();
    }

    // Cards screen (Wapp Store catalog) — the wapp pushes structured cards via
    // `ui.data` (target "catalog") and the host renders + drives their actions.
    final cardsGroup = screen.children
        .where((c) => c.keyword == 'group' && c.type == 'cards')
        .firstOrNull;
    if (cardsGroup != null) {
      return _buildCardsScreen(screen, cardsGroup);
    }

    // Functionalities browser — system wapp that lists all registered
    // functionalities, their providers, and lets the user pick defaults.
    final hasFunctionalitiesGroup = screen.children.any(
      (c) => c.keyword == 'group' && c.type == 'functionalities',
    );
    if (hasFunctionalitiesGroup) {
      return _buildFunctionalitiesScreen();
    }

    // Sources manager — install wapp's Settings tab. Shows the
    // current repository list (pushed by the wapp via store.sources)
    // with add+remove affordances and URL validation.
    final hasSourcesGroup = screen.children.any(
      (c) => c.keyword == 'group' && c.type == 'sources',
    );
    if (hasSourcesGroup) {
      return _buildSourcesScreen();
    }

    // UI editor — App Creator's UI tab. A split Code/Visual editor
    // that lets the author click-to-edit GeoUI blocks or drop into
    // raw JSON. Bound to `_fieldValues['source_ui']`.
    final hasUiEditorGroup = screen.children.any(
      (c) => c.keyword == 'group' && c.type == 'ui-editor',
    );
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
              (c) => c.keyword == 'action' && c.name == 'run-tests',
            ))) {
      return _buildTestsScreen();
    }

    // Robot — App Creator's AI chat tab. A configurable (offline/online)
    // assistant that proposes edits to the wapp's files. See wapp_robot.dart.
    final hasRobotGroup = screen.children.any(
      (c) => c.keyword == 'group' && c.type == 'robot',
    );
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
    final hasTranslationsGroup =
        screen.children.any(
          (c) => c.keyword == 'group' && c.type == 'translations',
        ) ||
        (screen.name ?? '').toLowerCase().contains('translation');
    if (hasTranslationsGroup) {
      return _buildTranslationsScreen();
    }

    // Terminal screen — has output + command input
    final hasTerminal = screen.children.any(
      (c) =>
          c.keyword == 'group' && c.children.any((gc) => gc.keyword == 'watch'),
    );
    if (hasTerminal) {
      return _buildTerminalScreen();
    }

    // Files screen (App Creator) — a `$type:"split"` group. Render the
    // proper file-list + full-height code editor instead of falling
    // through to the Settings form (which is the wrong UI and overflows
    // because of its fixed-height identity box).
    final hasSplit = screen.children.any(
      (c) => c.keyword == 'group' && c.type == 'split',
    );
    if (hasSplit) return _filesEditorBody();

    // People screen — a screen carrying a `$type:"people"` field renders as
    // a full-height social list (sections + rows + actions) with the screen's
    // own action buttons (e.g. "Follow a callsign") as a compact header row.
    final peopleField = screen.children
        .where((c) => c.keyword == 'field' && c.type == 'people')
        .firstOrNull;
    if (peopleField != null) return _buildPeopleScreen(screen, peopleField);

    // The internet side of NOSTR: relays (where posts come from) and Blossom
    // servers (where their images come from). Host-built — the wapp owns
    // neither list — and opted into with a field named `nostr_internet`.
    final netField = screen.children
        .where((c) => c.keyword == 'field' && c.name == 'nostr_internet')
        .firstOrNull;
    if (netField != null) return _buildNostrInternetScreen();

    // Notifications panel — who reacted to, replied to or reposted MY posts.
    // Host-built (the data is NOSTR, not the wapp's), opted into with a field
    // named `notifications`.
    final notifField = screen.children
        .where((c) => c.keyword == 'field' && c.name == 'notifications')
        .firstOrNull;
    if (notifField != null) return _buildNotificationsScreen();

    // Search panel — a query box on top of a read-only results feed. Detected
    // by a `search_results` chat field (any wapp can opt in with that name).
    final searchField = screen.children
        .where(
          (c) =>
              c.keyword == 'field' &&
              c.type == 'chat' &&
              c.name == 'search_results',
        )
        .firstOrNull;
    if (searchField != null) return _buildSearchScreen(screen, searchField);

    // Feed screen — a screen whose only content is a single `$type:"chat"`
    // field (e.g. the Activity tab) renders as a full-height feed + composer
    // (Twitter-style), not a fixed-height box inside a scroll form.
    final directChat = screen.children
        .where((c) => c.keyword == 'field' && c.type == 'chat')
        .toList();
    final hasGroups = screen.children.any((c) => c.keyword == 'group');
    if (directChat.length == 1 && !hasGroups) {
      // The geo-chat field gets the dedicated Live|Beacons panel; any other
      // chat-only screen is a plain full-height feed.
      if ((directChat.first.name ?? '') == 'geochat') {
        return _buildGeoChatScreen();
      }
      return _buildChatFeedScreen(directChat.first);
    }

    // Settings-like screen — use GeoUI renderer
    return _buildSettingsScreen(screen);
  }

  /// Search panel: a query box over a read-only results feed (the post cards +
  /// tap→thread/profile wiring), and — when the wapp declares them — its own
  /// filter fields between the two.
  ///
  /// Searching happens AS YOU TYPE (debounced): a Search button that has to be
  /// pressed is one step nobody takes, and the wapp's query fans out to the
  /// local index and every relay, internet and Reticulum alike.
  Widget _buildSearchScreen(GeoUiBlock screen, GeoUiBlock chatField) {
    void run() {
      _fieldValues['search_input'] = _nostrSearchCtl.text.trim();
      _sendCommand('search_go');
    }

    // Everything the wapp put on the panel other than the query box and the
    // results feed: its filters. Rendered through the normal GeoUI renderer so
    // a wapp can add a filter without the host learning about it.
    final filters = screen.children
        .where(
          (c) =>
            c.keyword == 'field' &&
            c.name != 'search_results' &&
              c.name != 'search_input',
        )
        .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _nostrSearchCtl,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => run(),
                  onChanged: (_) {
                    setState(() {}); // the clear button
                    _searchDebounce?.cancel();
                    _searchDebounce = Timer(
                      const Duration(milliseconds: 250),
                      run,
                    );
                  },
                  decoration: InputDecoration(
                    hintText: 'Search posts and people',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _nostrSearchCtl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            tooltip: 'Clear',
                            onPressed: () {
                              _nostrSearchCtl.clear();
                              run();
                              setState(() {});
                            },
                          ),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // The wapp's filters, as one compact line of chips.
        //
        // Rendering them through the ordinary form renderer gave a stack of
        // full-width segmented buttons that wrapped their own labels ("Everyt
        // hing", "An y tim e") and pushed the results off the screen. Filters
        // are an adjustment, not a form: they belong on one scrollable line.
        if (filters.isNotEmpty) _buildSearchFilterBar(filters),
        Divider(
          height: 1,
          color: Theme.of(context).colorScheme.outlineVariant.withAlpha(60),
        ),
        Expanded(child: _buildChatFeedScreen(chatField)),
      ],
    );
  }

  /// Relays + Blossom servers, both editable.
  ///
  /// Before this the relay list was read-only (you could see them and nothing
  /// else) and the Blossom servers — the machines every image in the feed is
  /// fetched from, and every picture you share is uploaded TO — were a constant
  /// buried in the transfer code. You could not see them, let alone choose them.
  Widget _buildNostrInternetScreen() {
    final cs = Theme.of(context).colorScheme;
    final rns = RnsService.instance;
    final relays = rns.nostrRelays();
    final blossom = rns.blossomServers();

    Color statusColour(String s) => switch (s) {
          'connected' => const Color(0xFF4CC38A),
          'connecting' => const Color(0xFFE0A93A),
          _ => cs.onSurfaceVariant,
        };

    Widget sectionTitle(String text, String tip) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Text(
            text,
                  style: TextStyle(
                      color: cs.primary,
                      fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
              const SizedBox(height: 2),
          Text(tip, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ],
          ),
        );

    Widget addRow({
      required TextEditingController ctl,
      required String hint,
      required VoidCallback onAdd,
    }) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: ctl,
                  onSubmitted: (_) => onAdd(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: hint,
                    border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                    contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: onAdd, child: const Text('Add')),
            ],
          ),
        );

    return ListView(
      children: [
        sectionTitle(
          'Relays',
            'Where posts come from and go to. wss:// over the internet, '
              'rns:// over Reticulum, or this device.',
        ),
        for (final r in relays)
          SwitchListTile(
            value: r['enabled'] != false,
            onChanged: (on) {
              rns.nostrRelayEnable('${r['uri']}', on);
              setState(() {});
            },
            title: Text(
              '${r['uri']}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 8,
                  color: statusColour('${r['status']}'),
                ),
              const SizedBox(width: 6),
                Text(
                  '${r['status']} · ${r['scheme']}',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ],
            ),
            secondary: IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: 'Remove',
              onPressed: () {
                rns.nostrRelayRemove('${r['uri']}');
                setState(() {});
              },
            ),
            dense: true,
          ),
        addRow(
          ctl: _relayAddCtl,
          hint: 'wss://relay.example.com  |  rns://<id>  |  local',
          onAdd: () {
            if (rns.nostrRelayAdd(_relayAddCtl.text.trim())) {
              _relayAddCtl.clear();
            }
            setState(() {});
          },
        ),
        const SizedBox(height: 8),
        sectionTitle(
          'Blossom media servers',
            'Images in the feed are fetched from these by their sha256, and '
              'anything you share is uploaded to them. Tried in order.',
        ),
        for (final b in blossom)
          ListTile(
            dense: true,
            leading: Icon(Icons.image_outlined, color: cs.onSurfaceVariant),
            title: Text(
              b,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: 'Remove',
              onPressed: () {
                rns.blossomRemove(b);
                setState(() {});
              },
            ),
          ),
        if (blossom.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'None — shared media will not reach anyone over the internet, '
              'and images posted by others will not load.',
              style: TextStyle(fontSize: 11, color: cs.error),
            ),
          ),
        addRow(
          ctl: _blossomAddCtl,
          hint: 'https://blossom.example.com',
          onAdd: () {
            if (rns.blossomAdd(_blossomAddCtl.text.trim())) {
              _blossomAddCtl.clear();
            }
            setState(() {});
          },
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  final _relayAddCtl = TextEditingController();
  final _blossomAddCtl = TextEditingController();

  /// Reactions, replies and reposts of MY posts — the Twitter "Notifications"
  /// tab. Rows read as a sentence ("X liked your post"), with the post they are
  /// about underneath, and tapping one opens the thread.
  Widget _buildNotificationsScreen() {
    final cs = Theme.of(context).colorScheme;
    final events = RnsService.instance.nostrNotifications();

    // Looking at the panel IS reading them. This is the one choke point every
    // route ends up at — the appbar icon, the overflow menu, and ui.screen.open
    // — so marking here covers all three, where before only the appbar icon did
    // (and the badge stayed lit for the other two).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      RnsService.instance.nostrNotificationsMarkRead();
      if (mounted) setState(() {});
    });
    if (events.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.notifications_none,
              size: 40,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text('Nothing yet.', style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 4),
            Text(
              'Likes, replies and reposts of your posts land here.',
                textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: events.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: cs.outlineVariant.withAlpha(45)),
      itemBuilder: (_, i) {
        final e = events[i];
        final kind = (e['kind'] as num?)?.toInt() ?? 0;
        final pubkey = (e['pubkey'] ?? '').toString();
        final short = pubkey.length >= 12 ? pubkey.substring(0, 12) : pubkey;
        final prof = RnsService.instance.nostrProfileByShort12(short);
        final who = (prof['name'] ?? '').isNotEmpty
            ? prof['name']!
            : (short.isEmpty ? 'someone' : short);
        final content = (e['content'] ?? '').toString();

        // What happened, in the user's words.
        // A kind-1 that p-tags me is only a REPLY when it e-tags one of my
        // posts. Without that it is a mention — and calling every mention a
        // reply sent people looking for a conversation that does not exist.
        final isReply =
            kind == 1 &&
            (((e['tags'] as List?) ?? const []).any(
              (t) => t is List && t.isNotEmpty && '${t[0]}' == 'e',
            ));
        final (IconData icon, Color colour, String what) = switch (kind) {
          7 =>
            content.trim() == '-' || content.trim() == '👎'
                ? (
                    Icons.thumb_down,
                    const Color(0xFFE05561),
                    'downvoted your post',
                  )
              : content.trim() == '+' || content.trim() == '👍'
                  ? (Icons.thumb_up, const Color(0xFF4CC38A), 'upvoted your post')
                  : (Icons.favorite, Colors.pink, 'liked your post'),
          6 => (Icons.repeat, const Color(0xFF00BA7C), 'reposted your post'),
          _ =>
            isReply
              ? (Icons.chat_bubble, ChatPalette.accent, 'replied to you')
              : (Icons.alternate_email, ChatPalette.accent, 'mentioned you'),
        };

        // The post it is about: a reply carries its text, a reaction does not.
        final body = kind == 1 ? content : '';
        final ts = ((e['created_at'] as num?)?.toInt() ?? 0) * 1000;

        return ListTile(
          leading: CircleAvatar(
            radius: 18,
            backgroundColor: colour.withValues(alpha: 0.15),
            child: Icon(icon, size: 18, color: colour),
          ),
          title: Text.rich(
            TextSpan(
              children: [
              TextSpan(
                  text: who,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              TextSpan(text: ' $what'),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: body.isEmpty
              ? (ts > 0
                  ? Text(
                      timeAgo(DateTime.fromMillisecondsSinceEpoch(ts)),
                      style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                    )
                  : null)
              : Text(body, maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: () => _openNotificationTarget(e),
        );
      },
    );
  }

  /// Open the post a notification is about.
  ///
  /// The post is usually in the local archive (it is normally MY post), but it
  /// does not have to be — a reaction can arrive for something I wrote on
  /// another device, and then the tap did nothing at all. So: archive first,
  /// then the relay store, then ask the relays and open it when it lands.
  void _openNotificationTarget(Map<String, dynamic> e) {
    String rootId = '';
    final tags = (e['tags'] as List?) ?? const [];
    for (final t in tags) {
      if (t is List && t.length >= 2 && '${t[0]}' == 'e') {
        rootId = '${t[1]}';
        break;
      }
    }

    // A mention (a kind-1 that p-tags me but e-tags nothing of mine) IS the
    // post — open it, not a root it does not have.
    if (rootId.isEmpty) rootId = (e['id'] ?? '').toString();
    if (rootId.isEmpty) return;

    final local = _postFromArchive(rootId);
    if (local != null) {
      _openActivityThread(local);
      return;
    }

    final ev = RnsService.instance.nostrEventById(rootId);
    if (ev != null) {
      _openActivityThread(_postFromEvent(ev));
      return;
    }
    // Not here yet — it has just been requested from the relays. Say so, and
    // open it as soon as it lands rather than leaving the tap looking broken.
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('Fetching the post…')));
    var tries = 0;
    Timer.periodic(const Duration(milliseconds: 400), (t) {
      tries++;
      final got = RnsService.instance.nostrEventById(rootId);
      if (got != null) {
        t.cancel();
        if (mounted) _openActivityThread(_postFromEvent(got));
      } else if (tries > 15 || !mounted) {
        t.cancel();
      }
    });
  }

  Map<String, dynamic>? _postFromArchive(String mid) {
    for (final p
        in _activityArchive?.recent() ?? const <Map<String, dynamic>>[]) {
      if ((p['mid'] ?? '').toString() == mid) return p;
    }
    return null;
  }

  /// A raw NOSTR event as the feed's post shape.
  Map<String, dynamic> _postFromEvent(Map<String, dynamic> ev) {
    final pubkey = (ev['pubkey'] ?? '').toString();
    final content = (ev['content'] ?? '').toString();
    return {
      'mid': (ev['id'] ?? '').toString(),
      'from': pubkey.length >= 12 ? pubkey.substring(0, 12) : pubkey,
      // The card reads `text` — `body` is only the list key. Setting the wrong
      // one opened the post with an empty body.
      'text': content,
      'body': content,
      'dir': 'in',
      't': ((ev['created_at'] as num?)?.toInt() ?? 0) * 1000,
    };
  }

  /// One line of filter chips for the search panel, built from the wapp's own
  /// filter fields: `enum` → a chip per option (single choice), `bool` → a
  /// toggle chip. Each carries the field's `apply` command, so touching one
  /// re-runs the search immediately.
  Widget _buildSearchFilterBar(List<GeoUiBlock> filters) {
    final cs = Theme.of(context).colorScheme;

    void fire(GeoUiBlock f) {
      final apply = f.getString('apply');
      if (apply != null && apply.isNotEmpty) _sendCommand(apply);
    }

    final chips = <Widget>[];
    for (final f in filters) {
      final name = f.name ?? '';
      if (name.isEmpty) continue;

      if (f.type == 'enum') {
        final options = f.childrenOf('option');
        final current =
            _fieldValues[name]?.toString() ??
            f.getString('default') ??
            (options.isNotEmpty ? (options.first.name ?? '') : '');
        for (final o in options) {
          final value = o.name ?? '';
          final label = _i18n.resolve(o.getString('label') ?? value);
          chips.add(
            ChoiceChip(
            label: Text(label),
            selected: current == value,
            visualDensity: VisualDensity.compact,
            labelStyle: const TextStyle(fontSize: 12.5),
            onSelected: (_) {
              setState(() => _fieldValues[name] = value);
              fire(f);
            },
            ),
          );
        }
      } else if (f.type == 'bool') {
        final on = _fieldValues[name] == true;
        chips.add(
          FilterChip(
            avatar: Icon(
              Icons.image_outlined,
              size: 16,
              color: on ? cs.onSecondaryContainer : cs.onSurfaceVariant,
            ),
          label: Text(_i18n.resolve(f.getString('label') ?? name)),
          selected: on,
          visualDensity: VisualDensity.compact,
          labelStyle: const TextStyle(fontSize: 12.5),
          onSelected: (v) {
            setState(() => _fieldValues[name] = v);
            fire(f);
          },
          ),
        );
      }
    }
    if (chips.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) => Center(child: chips[i]),
      ),
    );
  }

  /// Show a station's profile: forwarded to the wapp as the generic
  /// `profile` command with `profile_call`; the wapp answers with a prompt
  /// (title/body/actions) describing whatever a "profile" means to it.
  void _showProfile(String from) {
    if (from.isEmpty) return;
    _fieldValues['profile_call'] = from;
    _sendCommand('profile');
  }

  /// A full-height people list (Following / Followers, tags, row actions).
  ///
  /// Two optional headers render above the list:
  ///  • a `<group $type="player">` → a now-playing + transport bar (the Player
  ///    wapp's music controls; stateful icons driven by np_* field values);
  ///  • when the screen sets `"toolbar": true`, its top-level `<action>`s render
  ///    as a button row at the top (so a list panel can carry an "Add" button
  ///    without an options menu). Otherwise actions stay in the ⋮ options menu.
  Widget _buildPeopleScreen(GeoUiBlock screen, GeoUiBlock field) {
    final name = field.name ?? 'people';
    final stored = _fieldValues[name];
    final sections = stored is List
        ? stored
              .whereType<Map>()
              .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
              .toList()
        : const <Map<String, dynamic>>[];
    final playerGroup = screen.children
        .where((c) => c.keyword == 'group' && c.type == 'player')
        .firstOrNull;
    final showToolbar = screen.getBool('toolbar') == true;
    final toolbarActions = showToolbar
        ? screen.children
              .where((c) => c.keyword == 'action' && (c.name ?? '').isNotEmpty)
              .toList()
        : const <GeoUiBlock>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (playerGroup != null) _buildPlayerBar(),
        if (toolbarActions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final a in toolbarActions) _toolbarButton(a)],
            ),
          ),
        if (screen.getBool('search') == true) _buildSearchBar(name),
        Expanded(
          child: PeopleViewField(
            fieldName: name,
            sections: sections,
            emptyText: field.getString('empty'),
            onTap: (id) {
              _fieldValues['${name}_id'] = id;
              _sendCommand('${name}_tap');
            },
            onAction: (action, id) {
              _fieldValues['${name}_id'] = id;
              _sendCommand(action);
            },
          ),
        ),
      ],
    );
  }

  Widget _toolbarButton(GeoUiBlock a) {
    final name = a.name!;
    final label = _i18n.resolve(a.getString('label') ?? name);
    final icon = a.getString('icon');
    final primary = (a.getString('style') ?? '') == 'primary';
    final ico = icon != null ? Icon(geoUiResolveIcon(icon), size: 18) : null;
    void onTap() => _sendCommand(name);
    if (primary) {
      return ico != null
          ? FilledButton.icon(onPressed: onTap, icon: ico, label: Text(label))
          : FilledButton(onPressed: onTap, child: Text(label));
    }
    return ico != null
        ? OutlinedButton.icon(onPressed: onTap, icon: ico, label: Text(label))
        : OutlinedButton(onPressed: onTap, child: Text(label));
  }

  // Per-field search controllers + a debounce so live typing doesn't fire a
  // command on every keystroke.
  final Map<String, TextEditingController> _searchCtl = {};
  Timer? _searchDebounce;

  /// A persistent search box above a people list. As the user types it sends
  /// `<field>_search` with the query in `<field>_query`; the wapp filters and
  /// re-renders the list. Empty query restores the normal view.
  Widget _buildSearchBar(String field) {
    final ctl = _searchCtl.putIfAbsent(field, () => TextEditingController());
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: TextField(
        controller: ctl,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          hintText: 'Search',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: ctl.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Clear',
                  onPressed: () {
                    ctl.clear();
                    _runSearch(field, '');
                    setState(() {});
                  },
                ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 6,
          ),
        ),
        onChanged: (q) {
          setState(() {}); // refresh the clear button
          _searchDebounce?.cancel();
          _searchDebounce = Timer(
            const Duration(milliseconds: 250),
            () => _runSearch(field, q),
          );
        },
        onSubmitted: (q) => _runSearch(field, q),
      ),
    );
  }

  void _runSearch(String field, String query) {
    _fieldValues['${field}_query'] = query;
    _sendCommand('${field}_search');
  }

  /// Now-playing + transport bar for the Player wapp's music mode. Reads the
  /// wapp's np_* field values (set via ui.field.set) so the play/pause, shuffle
  /// and repeat icons reflect live state; each control sends its command.
  Widget _buildPlayerBar() {
    final cs = Theme.of(context).colorScheme;
    String fv(String k) => _fieldValues[k]?.toString() ?? '';
    bool fb(String k) => fv(k) == 'true' || fv(k) == '1';
    final rawTitle = fv('np_title');
    final title = rawTitle.isEmpty ? 'Nothing playing' : rawTitle;
    final time = fv('np_time');
    final playing = fb('np_playing');
    final shuffle = fb('np_shuffle');
    final repeat = fb('np_repeat');
    final progress = (double.tryParse(fv('np_progress')) ?? 0) / 1000.0;
    Widget ctl(
      IconData i,
      String cmd, {
      bool active = false,
      double size = 24,
      bool filled = false,
    }) => filled
        ? IconButton.filled(
            iconSize: size,
            icon: Icon(i),
            onPressed: () => _sendCommand(cmd),
          )
        : IconButton(
            iconSize: size,
            icon: Icon(i),
            color: active ? cs.primary : cs.onSurfaceVariant,
            onPressed: () => _sendCommand(cmd),
          );
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              // Always determinate (empty when position/duration unknown) — an
              // indeterminate bar would imply buffering, which it isn't.
              value: progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0,
              minHeight: 4,
              backgroundColor: cs.surfaceContainer,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            time.isEmpty ? ' ' : time,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ctl(Icons.shuffle, 'shuffle', active: shuffle, size: 22),
              ctl(Icons.skip_previous, 'prev', size: 30),
              ctl(
                playing ? Icons.pause : Icons.play_arrow,
                'playpause',
                size: 30,
                filled: true,
              ),
              ctl(Icons.skip_next, 'next', size: 30),
              ctl(Icons.repeat, 'repeat', active: repeat, size: 22),
            ],
          ),
        ],
      ),
    );
  }

  /// Folder view: a left navigation rail of sub-folders + the active area (the
  /// folder's chat). The rail is data-driven (ui.rail.set); tapping an item
  /// fires `<rail>_tap` with `<rail>_id`. The chat shows the folder's messages
  /// when `<chat>_active` is true, else a "select a folder" placeholder.
  Widget _buildFolderView(GeoUiBlock screen, GeoUiBlock railField) {
    final cs = Theme.of(context).colorScheme;
    final railName = railField.name ?? 'folderrail';
    final stored = _fieldValues[railName];
    final items = stored is List
        ? stored.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList()
        : const <Map<String, dynamic>>[];
    final selId = (_fieldValues['${railName}_sel'] ?? '').toString();

    final rail = Container(
      width: 96,
      color: cs.surfaceContainerHigh,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final it in items)
            _railItem(cs, railName, it, (it['id'] ?? '').toString() == selId),
        ],
      ),
    );

    final chatField = screen.children
        .where((c) => c.keyword == 'field' && c.type == 'chat')
        .firstOrNull;
    Widget detail;
    if (chatField != null) {
      final cname = chatField.name ?? 'folderchat';
      final active = _fieldValues['${cname}_active'] == true;
      if (!active) {
        detail = Center(
          child: Text(
            'Select a folder',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        );
      } else {
        final cm = _fieldValues[cname];
        final msgs = cm is List
            ? cm.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList()
            : const <Map<String, dynamic>>[];
        detail = ChatViewField(
          fieldName: cname,
          label: '',
          hint: chatField.getString('hint') ?? 'Message…',
          fill: true,
          safeBottom: true,
          messages: msgs,
          onSenderTap: _showProfile,
          onAttach: _attachFileToChat,
          onSend: (text) {
            _fieldValues['${cname}_input'] = text;
            _sendCommand('${cname}_send');
          },
        );
      }
    } else {
      detail = const SizedBox.shrink();
    }

    // No sub-folders to navigate → don't show an empty left column at all.
    if (items.isEmpty) return detail;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        rail,
        const VerticalDivider(width: 1),
        Expanded(child: detail),
      ],
    );
  }

  Widget _railItem(
    ColorScheme cs,
    String field,
    Map<String, dynamic> it,
    bool selected,
  ) {
    final id = (it['id'] ?? '').toString();
    final name = (it['name'] ?? '').toString();
    final icon = (it['icon'] ?? '').toString();
    final fg = selected ? cs.onSecondaryContainer : cs.onSurfaceVariant;
    return InkWell(
      onTap: () {
        _fieldValues['${field}_id'] = id;
        _sendCommand('${field}_tap');
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        color: selected ? cs.secondaryContainer : null,
        child: Column(
          children: [
            railIconFor(id, icon, fg),
            const SizedBox(height: 4),
            Text(
              name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: fg),
            ),
          ],
        ),
      ),
    );
  }

  /// Keep a post's remote media in the disk cache (exempt from LRU eviction)
  /// because the logged-in user interacted with it (saved / opened its thread).
  void _keepPostMedia(Map<String, dynamic> post) {
    final urls = activityMediaUrls(
      activityStrip((post['text'] ?? '').toString()),
    );
    if (urls.isNotEmpty) {
      // ignore: discarded_futures
      MediaDiskCache.instance.keepAll(urls);
    }
  }

  /// Resolve a post author to name+avatar: prefer a wapp-pushed profile
  /// (ui.profile.set), else the built-in stream profile lookup.
  ({String? name, ImageProvider? avatar}) _feedProfileFor(String from) {
    final p = _wappProfiles[from];
    if (p != null && (p['name'] != null || p['pic'] != null)) {
      final pic = p['pic'];
      return (
        name: p['name'],
        avatar: (pic != null && pic.isNotEmpty) ? NetworkImage(pic) : null,
      );
    }
    // Persistent engine store (any author whose kind-0 we've EVER fetched),
    // keyed by the 12-char prefix — resolves Saved/old-thread authors that
    // aren't in the current live feed.
    final eng = RnsService.instance.nostrProfileByShort12(from);
    final eName = eng['name'];
    if ((eName != null && eName.isNotEmpty) ||
        (eng['pic']?.isNotEmpty == true)) {
      final pic = eng['pic'];
      return (
        name: eName,
        avatar: (pic != null && pic.isNotEmpty) ? NetworkImage(pic) : null,
      );
    }
    // My own posts/replies: use my local profile so my name + avatar always
    // show (my kind-0 isn't fetched from relays — I am the author).
    final selfHex = RnsService.instance.nostrSelfHex();
    if (selfHex != null &&
        selfHex.length >= 12 &&
        from == selfHex.substring(0, 12)) {
      final self = _loadSelfProfile();
      if ((self.name != null && self.name!.isNotEmpty) || self.avatar != null) {
        return (name: self.name, avatar: self.avatar);
      }
    }
    return _streamProfileFor(from);
  }

  /// Tapping an author: open the full-screen profile page (banner, bio, links,
  /// their posts + Message/Follow/Mute/Block), seeded from exactly what the feed
  /// already shows so the header is never blank.
  void _feedSenderTap(String from) => _openNostrProfile(from);

  /// Open the profile of a MENTIONED author. A mention decodes to a full 64-char
  /// pubkey; the feed (and every profile route) keys an author by the first 12
  /// chars of it, so this is the same screen the author's avatar opens — no
  /// second profile path to keep in step.
  /// The full 64-char pubkey behind a feed's 12-char author key. The host knows
  /// this from the profile store and from the archive — it does not need the
  /// wapp's ring of recent authors, which is exactly what used to fail.
  String? _fullPubkeyFor(String from) {
    final short = from.trim().toLowerCase();
    if (short.length == 64) return short;
    if (short.startsWith('npub1')) {
      final hex = RnsService.instance.nostrHexFromNpub(short);
      if (hex != null && hex.length == 64) return hex;
    }
    final npub =
        _wappProfiles[from]?['npub'] ??
        RnsService.instance.nostrProfileByShort12(short)['npub'] ??
        RnsService.instance.npubForCallsign(from);
    if (npub != null && npub.isNotEmpty) {
      final hex = RnsService.instance.nostrHexFromNpub(npub);
      if (hex != null && hex.length == 64) return hex;
    }
    return null;
  }

  /// Follow/unfollow an author of a post, by their full key. An unfollow that
  /// cannot be resolved must SAY so rather than pretend it worked.
  void _applyNostrFollow(String from, bool follow) {
    final hex = _fullPubkeyFor(from);
    // No key on this device yet? The wapp command still went out, and the follow
    // will resolve when the author's profile lands. Say NOTHING: a warning here
    // fires on a perfectly ordinary follow and is pure noise — the user reported
    // it as "a stupid error appearing when I follow someone", and they were right.
    if (hex == null) return;
    if (follow) {
      RnsService.instance.followPubkey(hex);
    } else {
      RnsService.instance.unfollowPubkey(hex);
    }
  }

  void _openNostrProfileByHex(String hex) {
    if (hex.length < 12) return;
    _openNostrProfile(hex.substring(0, 12));
  }

  /// Full-screen Twitter-style profile for a NOSTR author: banner + avatar +
  /// name + bio + nip05/website/lightning + their posts, with Message, Follow,
  /// Mute and Block actions.
  void _openNostrProfile(String from) {
    final arch = _activityArchive;
    final uc = from.toUpperCase();
    // Merge the persistent engine profile (banner/website/npub/…) under any
    // wapp-pushed one so Saved/old-thread authors get the full rich page too.
    final p = <String, String>{
      ...RnsService.instance.nostrProfileByShort12(from),
      ...?_wappProfiles[from],
    };
    // Seed name + avatar from the SAME resolver the feed uses — guarantees the
    // profile header matches the feed even when the wapp hasn't pushed a full
    // profile yet.
    final feedProf = _feedProfileFor(from);
    final npub = (p['npub']?.isNotEmpty == true)
        ? p['npub']
        : RnsService.instance.npubForCallsign(from);
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => ProfileRoute(
              // Same publications, same card, same wiring as the stream.
              voteInfo: (mid) => RnsService.instance.nostrVotes(mid),
              onVote: (mid, vote) {
                final author = _activityAuthorHex(mid);
                RnsService.instance.nostrVote(mid, author, vote);
                setState(() {});
              },
              isSaved: (mid) => _activityArchive?.isSaved(mid) ?? false,
              onSave: (post) {
                _activityArchive?.toggleSaved(post);
                _keepPostMedia(post);
                setState(() {});
              },
              profileFor: _feedProfileFor,
              npubFor: (c) =>
                  _wappProfiles[c]?['npub'] ??
                  RnsService.instance.npubForCallsign(c),
              callsign: from,
              npub: npub,
              metadata: p.isEmpty ? null : p,
              presetName: feedProf.name,
              presetAvatar: feedProf.avatar,
              // Pull the fresh kind-0 (banner, website, lightning, name, pic) when we
              // can resolve an npub — non-destructive, only fills what's missing.
              fetchMetadata: npub == null
                  ? null
                  : () => RnsService.instance.fetchProfileMetadata(npub),
              firstSeenMs: arch?.firstSeenMs(from),
              postCount: arch?.postCount(from) ?? 0,
              posts: arch?.byAuthor(from) ?? const [],
              onPostTap: (post) {
                Navigator.of(context).pop();
                _openActivityThread(post);
              },
              // Per-post Like / Reply / Retweet, same wiring as the feed.
              mentionResolver: RnsService.instance.nostrMentionName,
              onMentionTap: _openNostrProfileByHex,
              likeInfo: _likeInfoFor,
              onLike: (m, like) {
                _fieldValues['activity_mid'] = m;
                _fieldValues['activity_unlike'] = !like;
                _sendCommand('activity_like');
                setState(() {});
              },
              replyCount: _replyCountFor,
              onReplyPost: (post) {
                Navigator.of(context).pop();
                _openActivityThread(post);
              },
              isReposted: (m) => _wappReposted.contains(m),
              onRepost: _repostPost,
              following: _followedCalls.contains(uc),
              blocked: _activityHidden.contains(uc),
              muted: RnsService.instance.isMutedCallsign(uc),
              onMessage: () {
                final hex = npub == null
                    ? null
                    : RnsService.instance.nostrHexFromNpub(npub);
                Navigator.of(context).pop();
                if (hex != null) _openConvoById(hex);
              },
              onSetFollow: (follow) {
                if (follow) {
                  _followedCalls.add(uc);
                  if (npub != null) {
                    _fieldValues['follow_input'] = npub;
                    _sendCommand('follow_add');
                  }
                } else {
                  _followedCalls.remove(uc);
                  if (npub != null) {
                    _fieldValues['follows_list_id'] = npub;
                    _sendCommand('follows_list_tap');
                  }
                }
                // …and durably, host-side, with the full key: the wapp commands
                // above are a courtesy, not the record.
                _applyNostrFollow(npub ?? from, follow);
                setState(() {});
              },
              onSetBlock: (block) {
                _fieldValues['activity_call'] = from;
                _sendCommand('activity_block');
                setState(() {});
              },
              // "Keep data": host their posts + media on this device.
              keepData:
                  _keepHexOf(npub) != null &&
                  RnsService.instance.isKeepData(_keepHexOf(npub)!),
              onSetKeep: _keepHexOf(npub) == null
                  ? null
                  : (keep) {
                      RnsService.instance.setKeepData(_keepHexOf(npub)!, keep);
                      if (mounted) setState(() {});
                    },
              onSetMute: (mute) {
                // The mute lives in the HOST, persisted. The wapp is told too
                // (it may keep its own list), but the feed must not depend on a
                // wapp round-trip to stop showing someone: the button was doing
                // nothing at all, because no wapp ever implemented the command.
                RnsService.instance.setMutedCallsign(from, mute);
                _fieldValues['activity_call'] = from;
                _sendCommand('activity_mute');
                setState(() {});
              },
              resolveAvatar: _imageForPicture,
            ),
          ),
        )
        .then((_) {
          if (!mounted) return;
          _sendCommand('activity_refresh');
          setState(() {});
        });
  }

  void _showWappProfileSheet(String from, Map<String, String> p) {
    final pic = p['pic'];
    final banner = p['banner'];
    final name = p['name'] ?? from;
    final about = p['about'];
    final npub = p['npub'];
    final nip05 = p['nip05'];
    final website = p['website'];
    final lud16 = p['lud16'];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        Widget kv(IconData icon, String text, {Color? color}) => Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 17, color: color ?? cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  text,
                  style: TextStyle(fontSize: 13, color: color ?? cs.onSurface),
                ),
              ),
            ],
          ),
        );
        return SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (banner != null && banner.isNotEmpty)
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                    child: Image.network(
                      banner,
                      height: 120,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 30,
                            backgroundImage: (pic != null && pic.isNotEmpty)
                                ? NetworkImage(pic)
                                : null,
                            child: (pic == null || pic.isEmpty)
                                ? Text(
                                    name.isNotEmpty
                                        ? name[0].toUpperCase()
                                        : '?',
                                  )
                                : null,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  style: const TextStyle(
                                    fontSize: 19,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                if (nip05 != null)
                                  Text(
                                    nip05,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: cs.primary,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (about != null) ...[
                        const SizedBox(height: 14),
                        SelectableText(
                          about,
                          style: const TextStyle(fontSize: 14, height: 1.35),
                        ),
                      ],
                      if (website != null && website.isNotEmpty)
                        kv(Icons.link, website, color: cs.primary),
                      if (lud16 != null && lud16.isNotEmpty)
                        kv(Icons.bolt, lud16, color: const Color(0xFFF7931A)),
                      if (npub != null) kv(Icons.key, npub),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// A full-height chat feed (the chat field fills the tab; the composer sits
  /// at the bottom). Used for screens that are just a `$type:"chat"` field.
  Widget _buildChatFeedScreen(GeoUiBlock chat) {
    final name = chat.name ?? 'activity';
    final hint = chat.getString('hint') ?? 'Message…';
    // The Activity feed gets a Twitter-style layout (compose on top, centered
    // post stream) and renders from the PERSISTED archive, so posts received in
    // the background (app closed) appear alongside live ones.
    if (name == 'activity') {
      // Opening the stream = the user is looking. Recover any socket Android
      // froze while we were backgrounded, or the feed shows its age instead of
      // the network. Throttled inside, so calling from build is fine.
      RnsService.instance.nostrResume();
      final posts =
          _activityArchive?.recent() ?? const <Map<String, dynamic>>[];
      return ActivityFeed(
        posts: posts,
        replyCount: _replyCountFor,
        onAttach: _attachImageOrVideoToChat,
        onItemTap: _openConvoFromFeed,
        onSenderTap: _feedSenderTap,
        npubFor: (c) =>
            _wappProfiles[c]?['npub'] ?? RnsService.instance.npubForCallsign(c),
        // Follow set for the "Following" filter: the host's own follows PLUS my
        // NOSTR contact list (kind-3), keyed to match a post's `from`.
        followedCalls: {
          ..._followedCalls,
          ...RnsService.instance.nostrFollowShort12(),
        },
        followedPubkeys: _wappName == 'social'
            ? RnsService.instance.nostrFollowPubkeys()
            : null,
        selfPubkey: _wappName == 'social'
            ? RnsService.instance.nostrSelfHex()
            : null,
        authorPubkeyFor: _wappName == 'social' ? _fullPubkeyFor : null,
        hiddenCalls: {
          ..._activityHidden,
          ...RnsService.instance.mutedCallsigns,
        },
        onBlock: (from) {
          if (from.isEmpty) return;
          _fieldValues['activity_call'] = from;
          _sendCommand('activity_block');
        },
        onMute: (from) {
          if (from.isEmpty) return;
          RnsService.instance.setMutedCallsign(from, true);
          _fieldValues['activity_call'] = from;
          _sendCommand('activity_mute');
          setState(() {});
        },
        // Follow straight from a post. The wapp does the NOSTR side (kind-3);
        // the host reflects it at once so the ⋯ menu and the Following filter
        // do not lie to the user while the relay round-trips.
        onFollow: (from, follow) {
          if (from.isEmpty) return;
          final uc = from.toUpperCase();
          setState(() {
            if (follow) {
              _followedCalls.add(uc);
            } else {
              _followedCalls.remove(uc);
            }
          });
          // Do the follow HOST-side with the full key. Handing the wapp a 12-char
          // prefix and hoping it can resolve it was a silent failure: the wapp
          // looks the prefix up in a 96-entry ring of recently-seen authors, and
          // if the account had scrolled out of that ring the follow set was never
          // touched at all — so an unfollow did nothing and the account was back
          // on the next rebuild.
          _applyNostrFollow(from, follow);
          _fieldValues['profile_target'] = from;
          _sendCommand(follow ? 'profile_follow' : 'profile_unfollow');
        },
        likeInfo: _likeInfoFor,
        // Votes are host-side NOSTR (NIP-25 "+"/"-"): the wapp does not need to
        // know, and every other NOSTR client reads them.
        voteInfo: (mid) => RnsService.instance.nostrVotes(mid),
        onVote: (mid, vote) {
          final author = _activityAuthorHex(mid);
          RnsService.instance.nostrVote(mid, author, vote);
          setState(() {});
        },
        isSaved: (mid) => _activityArchive?.isSaved(mid) ?? false,
        savedPosts: () =>
            _activityArchive?.savedPosts() ?? const <Map<String, dynamic>>[],
        onLike: (mid, like) {
          // Generic: hand the like to the wapp (it decides what a "like" means —
          // APRS group vote, NOSTR kind-7 reaction, …).
          _fieldValues['activity_mid'] = mid;
          _fieldValues['activity_unlike'] = !like;
          _sendCommand('activity_like');
        },
        onSave: (post) {
          _activityArchive?.toggleSaved(post);
          _keepPostMedia(post); // pinned/saved — keep its media
          setState(() {});
        },
        isReposted: (mid) => _wappReposted.contains(mid),
        onRepost: _repostPost,
        onSelfTap: () {
          final self = ProfileService.instance.activeProfile;
          if (self != null) _openProfile(self.callsign);
        },
        selfAvatar: _loadSelfProfile().avatar,
        profileFor: _feedProfileFor,
        mentionResolver: RnsService.instance.nostrMentionName,
        onMentionTap: _openNostrProfileByHex,
        onOpenThread: _openActivityThread,
        onRefresh: (filter) async {
          // A pull-to-refresh is a request for MORE, now.
          // 1. Wake the network: reconnect any socket Android froze while the
          //    app was backgrounded and re-ask the firehose for the missed
          //    window (since-bounded — one fetch, not the churn loop that got
          //    the subscription dropped).
          // 2. Hand over the best 100 the curator is holding rather than making
          //    the user wait out its ten-second trickle.
          // Reopen the wapp subscription before asking the host for a batch.
          // Doing this afterwards raced tab changes: the host returned zero,
          // then Social finally subscribed when the refresh had already ended.
          _sendCommand('${name}_refresh');
          await Future<void>.delayed(const Duration(milliseconds: 250));
          if (filter == 'all') {
            final count = await RnsService.instance.nostrRefreshBurst(n: 100);
            LogService.instance.add('social refresh: filter=all batch=$count');
          } else {
            RnsService.instance.nostrResume();
            LogService.instance.add('social refresh: filter=$filter reopened');
          }
        },
        curatedAll: _wappName == 'social',
        // Remember the All/Following/Saved tab across restarts, per wapp.
        initialFilter: PreferencesService.instanceSync?.getWappUiPref(
          _wappName,
          'feedFilter',
        ),
        onFilterChanged: (f) {
          PreferencesService.instanceSync?.setWappUiPref(
          _wappName,
          'feedFilter',
          f,
          );
          _fieldValues['activity_filter'] = f;
          _sendCommand('activity_filter_changed');
        },
        onSend: (text) {
          _fieldValues['${name}_input'] = text;
          _sendCommand('${name}_send');
        },
      );
    }
    // Search results: a read-only Twitter-style stream reusing the post cards
    // and their tap→thread / tap-author→profile wiring, fed from _fieldValues
    // (NOT the persisted archive), so it never pollutes the main feed.
    if (name == 'search_results') {
      final raw = _fieldValues[name];
      final results = raw is List
          ? raw.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList()
          : const <Map<String, dynamic>>[];
      return ActivityFeed(
        posts: results,
        readOnly: true,
        onSend: (_) {},
        npubFor: (c) =>
            _wappProfiles[c]?['npub'] ?? RnsService.instance.npubForCallsign(c),
        profileFor: _feedProfileFor,
        mentionResolver: RnsService.instance.nostrMentionName,
        onMentionTap: _openNostrProfileByHex,
        onSenderTap: _feedSenderTap,
        onOpenThread: _openActivityThread,
        replyCount: _replyCountFor,
        likeInfo: _likeInfoFor,
      );
    }
    final stored = _fieldValues[name];
    final messages = stored is List
        ? stored.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList()
        : const <Map<String, dynamic>>[];
    return ChatViewField(
      fieldName: name,
      label: '',
      hint: hint,
      fill: true,
      safeBottom: true,
      messages: messages,
      onLocate: _locateFromMessage,
      onSenderTap: _showProfile,
      onItemTap: _openConvoFromFeed,
      // Activity posts can carry an image or video (only those, for now).
      onAttach: _attachImageOrVideoToChat,
      onSend: (text) {
        _fieldValues['${name}_input'] = text;
        _sendCommand('${name}_send');
      },
    );
  }

  /// Pick an image for a `$type:"image"` field: store it content-addressed,
  /// set the field to its `file:<sha>.<ext>` token, and forward [action] so the
  /// wapp persists the new picture.
  Future<void> _pickImageForField(String field, String action) async {
    final token = await _attachImageOnly();
    if (token == null) return;
    _fieldValues[field] = token;
    if (mounted) setState(() {});
    _sendCommand(action);
  }

  /// Pick an image only (no video), archive it content-addressed, and return the
  /// `file:<sha>.<ext>` token.
  Future<String?> _attachImageOnly() async {
    try {
      const images = XTypeGroup(
        label: 'Images',
        extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic'],
      );
      final file = await openFile(acceptedTypeGroups: const [images]);
      if (file == null) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      final dot = file.name.lastIndexOf('.');
      final ext = dot >= 0 ? file.name.substring(dot + 1).toLowerCase() : 'png';
      return attachMediaFile(bytes, ext, name: file.name);
    } catch (_) {
      return null;
    }
  }

  /// Attach an image or video (only) to a composer: pick, archive, advertise on
  /// Reticulum, return the `file:<sha>.<ext>` token to insert.
  Future<String?> _attachImageOrVideoToChat() async {
    try {
      const images = XTypeGroup(
        label: 'Images',
        extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic'],
      );
      const videos = XTypeGroup(
        label: 'Videos',
        extensions: ['mp4', 'mov', 'webm', 'mkv', 'avi', 'm4v', '3gp'],
      );
      final file = await openFile(acceptedTypeGroups: const [images, videos]);
      if (file == null) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      final dot = file.name.lastIndexOf('.');
      final ext = dot >= 0 ? file.name.substring(dot + 1).toLowerCase() : 'bin';
      return attachMediaFile(bytes, ext, name: file.name);
    } catch (_) {
      return null;
    }
  }

  // Tapping an Activity-feed item jumps to its conversation in the Messages tab
  // so the user can continue it. The item carries a `convo` ("#GROUP" or a
  // callsign); we switch to the conversations tab and open that room (creating
  // the row if it doesn't exist yet, e.g. a brand-new BLE contact).
  void _openConvoFromFeed(Map<String, dynamic> m) =>
      _openConvoById((m['convo'] ?? '').toString().trim());

  /// Recover FEED posts that were lost over APRS-IS by asking peers on Reticulum
  /// for FEED notes since the last sweep (NOSTR kind-1), reconstructing each as a
  /// feed entry (the callsign is derived from the note's pubkey) and archiving
  /// any we don't already have. APRS-IS stays the primary path; this fills gaps.
  /// One aggressive early backfill attempt; stops the fast timer once it pulls
  /// notes (connected + a peer found) or after ~5 minutes of trying.
  Future<void> _fastBackfillTick() async {
    _fastBackfillTicks++;
    final added = await _backfillFeed();
    if (added > 0 || _fastBackfillTicks >= 20) {
      _fastBackfillTimer?.cancel();
      _fastBackfillTimer = null;
    }
  }

  bool _backfillRunning = false;

  Future<int> _backfillFeed() async {
    final arch = _activityArchive;
    if (arch == null || !RnsService.instance.isUp) return 0;
    // Never let backfills overlap: each may query several peers, and the fast
    // timer fires every 15s — without this guard they pile up into many
    // concurrent relay queries and swamp the node.
    if (_backfillRunning) return 0;
    _backfillRunning = true;
    try {
      final a = await _backfillFeedInner(arch);
      // Same sweep also backfills the subscribed group conversations (Messages
      // tab) so a fresh install sees previous group messages, not just Activity.
      final g = await _backfillGroups();
      return a + g;
    } finally {
      _backfillRunning = false;
    }
  }

  /// Backfill the Messages-tab group conversations from Reticulum: for each
  /// subscribed group (`#NAME` / `#NAME*`), ask peers for that group's kind-1
  /// notes and add any we don't already have. Mirrors [_backfillFeedInner] but
  /// targets conversations instead of the Activity feed. Idempotent: dedups on
  /// the message id (sha1(from|text)[:2], identical to the wapp's group msg_id),
  /// which also collapses a backfilled post against its live copy. Runs on the
  /// same fast/slow timers, so a just-joined device fills group history once RNS
  /// is up and a relay/peer is reachable.
  Future<int> _backfillGroups() async {
    final store = _convStores['conversations'];
    if (store == null || !RnsService.instance.isUp) return 0;
    // Distinct group topics from the subscribed (open) group conversations.
    final topics = <String>{};
    for (final entry in store.items.entries) {
      final id = entry.key;
      if (!id.startsWith('#') || entry.value.closed) continue;
      var t = id.substring(1);
      final star = t.indexOf('*');
      if (star >= 0) t = t.substring(0, star);
      if (t.isNotEmpty) topics.add(t);
    }
    if (topics.isEmpty) return 0;
    final selfPub = RnsService.instance.selfPubHex?.toLowerCase();
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final since = nowSec - 7 * 24 * 3600; // last week, like the FEED backfill
    var added = 0;
    for (final topic in topics) {
      List<Map<String, dynamic>> notes;
      try {
        notes = await RnsService.instance.fetchFeedBackfill(
          since,
          topic: topic,
        );
      } catch (_) {
        continue;
      }
      if (!mounted) return added;
      if (notes.isEmpty) continue;
      // Deliver to whichever ids the user actually has (global and/or local).
      final convIds = <String>[
        for (final cand in ['#$topic*', '#$topic'])
          if (store.items[cand] != null && !store.items[cand]!.closed) cand,
      ];
      for (final convId in convIds) {
        final it = store.items[convId]!;
        final existingMids = <String>{
          for (final m in it.messages)
            if ((m['mid'] ?? '').toString().isNotEmpty) m['mid'].toString(),
        };
        final preUnread = it.unread; // backfilled history shouldn't ring badges
        // Oldest→newest so appended bubbles read in chronological order.
        for (final n in notes.reversed) {
          final pub = (n['pub'] ?? '').toString();
          final text = (n['text'] ?? '').toString();
          if (pub.isEmpty || text.isEmpty) continue;
          if (selfPub != null && pub.toLowerCase() == selfPub) continue;
          String from;
          try {
            from = 'X1${NostrCrypto.deriveCallsign(pub)}';
          } catch (_) {
            continue;
          }
          final mid = activityMid(from, text);
          if (!existingMids.add(mid))
            continue; // already present (live or prior)
          final ts = (n['ts'] as int?) ?? nowSec;
          final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
          final hhmm =
              '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
          store.addMessage({
            'id': convId,
            'dir': 'in',
            'from': from,
            'text': text,
            'time': hhmm,
            'via': 'RET',
            'mid': mid,
            'key': mid,
            'parent': (n['parent'] ?? '').toString(),
            't': ts * 1000,
          });
          added++;
        }
        it.unread = preUnread;
      }
    }
    if (added > 0) {
      _scheduleConvoSave('conversations');
      if (mounted) setState(() {});
    }
    return added;
  }

  Future<int> _backfillFeedInner(ActivityArchive arch) async {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final since = _lastFeedBackfillSec == 0
        ? nowSec -
              7 *
                  24 *
                  3600 // first run: last week
        : _lastFeedBackfillSec - 300; // small overlap so nothing slips through
    List<Map<String, dynamic>> notes;
    try {
      notes = await RnsService.instance.fetchFeedBackfill(since);
    } catch (_) {
      return 0;
    }
    if (!mounted) return 0;
    final selfPub = RnsService.instance.selfPubHex;
    var added = 0;
    for (final n in notes) {
      final pub = (n['pub'] ?? '').toString();
      final text = (n['text'] ?? '').toString();
      if (pub.isEmpty || text.isEmpty) continue;
      if (selfPub != null && pub.toLowerCase() == selfPub) {
        continue; // our own posts aren't "missed" — we already have them
      }
      String from;
      try {
        from = 'X1${NostrCrypto.deriveCallsign(pub)}';
      } catch (_) {
        continue;
      }
      // Dedup on content (old rows may lack a stored mid).
      if (arch.hasContent(from, text)) continue;
      final mid = activityMid(from, text);
      final ts = (n['ts'] as int?) ?? nowSec;
      final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
      final hhmm =
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      arch.add({
        'dir': 'in',
        'from': from,
        'text': text,
        'time': hhmm,
        'via':
            'RET', // Reticulum over the internet (matches the wapp's RET tag)
        'mid': mid,
        'parent': (n['parent'] ?? '').toString(),
        't': ts * 1000,
        // NIP-92 imeta (video poster/blurhash/dim) recovered from the event.
        'meta': (n['meta'] ?? '').toString(),
      });
      // Backfilled posts can reference large media. Do NOT auto-download it during
      // backfill — the Activity card shows the size + a one-click download button
      // so the user decides (a week of history could be many GB otherwise).
      added++;
    }
    // Only advance the high-water mark once a sweep actually returned notes. A
    // fresh node usually comes up before any relay/peer is reachable; advancing on
    // an empty sweep would lock us out of ever re-fetching the 7-day history (the
    // bug that left Activity empty for new users). Keep retrying the full week
    // until the first real pull, then switch to incremental.
    if (notes.isNotEmpty) _lastFeedBackfillSec = nowSec;
    if (added > 0) {
      _activityRev.value++;
      if (mounted) setState(() {});
    }
    return added;
  }

  /// Open a publication's full-screen forum thread (the post + its replies).
  /// Replies post via the same `activity_reply` wire (the wapp wraps them as
  /// "+<mid> text"). The thread refreshes live via [_activityRev].
  /// Like tally for a post, best source first: the wapp's live stats push,
  /// the wapp's own archive, then the NOSTR engine — whose tallies are now
  /// seeded from persisted reaction receipts, so a hero-opened thread shows
  /// its counts instantly instead of waiting for a relay round trip.
  ({int count, bool mine}) _likeInfoFor(String mid) {
    final s = _wappPostStats[mid];
    if (s != null) return (count: s.likes, mine: s.mine);
    final a = _activityArchive?.likeInfo(mid) ?? (count: 0, mine: false);
    if (a.count > 0) return a;
    final hub = RnsService.instance.nostrStats(mid);
    return hub.likes > 0 ? (count: hub.likes, mine: hub.mine) : a;
  }

  /// Reply tally, same source order as [_likeInfoFor].
  int _replyCountFor(String mid) {
    final live = _wappPostStats[mid]?.replies;
    if (live != null && live > 0) return live;
    final archived = _activityArchive?.replyCount(mid) ?? 0;
    if (archived > 0) return archived;
    return RnsService.instance.nostrStats(mid).replies;
  }

  /// Open the thread for [mid] as soon as its post exists in the activity
  /// archive. On a fresh launch the post usually isn't stored yet — the wapp
  /// has just been told (via `view.open`) to subscribe to it — so poll briefly
  /// instead of opening a blank thread. Gives up quietly after ~12s: the feed
  /// is still on screen, which is a sane place to land.
  void _openPostWhenAvailable(String mid) {
    if (mid.isEmpty) return;
    var tries = 0;
    Timer.periodic(const Duration(milliseconds: 600), (t) {
      if (!mounted) return t.cancel();
      final row = _activityArchive?.byMid(mid);
      if (row != null) {
        t.cancel();
        _openActivityThread(row);
      } else if (++tries >= 20) {
        t.cancel();
      }
    });
  }

  void _openActivityThread(Map<String, dynamic> post) {
    final mid = (post['mid'] ?? '').toString();
    if (mid.isEmpty) return;
    _keepPostMedia(post); // opening a thread = an interaction — keep its media
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => ActivityThreadPage(
              root: post,
              revision: _activityRev,
              loadThread: (rootMid) =>
                  _activityArchive?.threadReplies(rootMid) ??
                  const <Map<String, dynamic>>[],
              replyCount: _replyCountFor,
              likeInfo: _likeInfoFor,
              onLike: (m, like) {
                _fieldValues['activity_mid'] = m;
                _fieldValues['activity_unlike'] = !like;
                _sendCommand('activity_like');
              },
              // The thread shows the SAME votes as the stream — without these
              // an upvote cast in the feed vanished the moment you opened the
              // post, which reads as a vote that was lost.
              voteInfo: (m) => RnsService.instance.nostrVotes(m),
              onVote: (m, vote) {
                RnsService.instance.nostrVote(m, _activityAuthorHex(m), vote);
                _activityRev.value++;
                setState(() {});
              },
              isSaved: (m) => _activityArchive?.isSaved(m) ?? false,
              onSave: (p) {
                _activityArchive?.toggleSaved(p);
                _activityRev.value++;
              },
              isReposted: (m) => _wappReposted.contains(m),
              onRepost: (p) {
                _repostPost(p);
                _activityRev.value++;
              },
              onReply: (parentMid, text) {
                if (text.trim().isEmpty) return;
                _fieldValues['activity_target_mid'] = parentMid;
                _fieldValues['activity_input'] = text.trim();
                _sendCommand('activity_reply');
              },
              onSenderTap: _feedSenderTap,
              profileFor: _feedProfileFor,
              mentionResolver: RnsService.instance.nostrMentionName,
              onMentionTap: _openNostrProfileByHex,
              npubFor: (c) =>
                  _wappProfiles[c]?['npub'] ??
                  RnsService.instance.npubForCallsign(c),
              onAttach: _attachImageOrVideoToChat,
            ),
          ),
        )
        .then((_) {
          // Back on the stream: pull the latest + repaint so posts that arrived
          // while reading the thread appear ("updates falling in").
          if (!mounted) return;
          _sendCommand('activity_refresh');
          setState(() {});
        });
  }

  void _openConvoById(String convo) {
    if (convo.isEmpty) return;
    final idx = _tabScreens.indexWhere(
      (s) => s.children.any(
        (c) => c.keyword == 'group' && c.type == 'conversations',
      ),
    );
    if (idx < 0) return;
    const field = 'conversations';
    final store = _convStore(field);
    if (!store.items.containsKey(convo)) store.upsert({'id': convo});
    setState(() {
      _panelScreen = null;
      _convOpenId = convo;
      store.clearUnread(convo);
      if (_tabController != null && _tabController!.index != idx) {
        _tabController!.animateTo(idx);
      }
    });
    _syncAppBadge();
  }

  /// Open a full, Twitter-style profile page for [callsign]: identity details
  /// (npub, first seen, post count) + the posts they've written.
  void _openProfile(String callsign, {String? npub}) {
    final c = callsign.trim();
    if (c.isEmpty) return;
    final arch = _activityArchive;
    final self = ProfileService.instance.activeProfile;
    final isSelf =
        self != null && c.toUpperCase() == self.callsign.toUpperCase();
    // For our own profile, prefer the local identity's npub (we may not have a
    // learned callsign->key mapping for ourselves). Otherwise use the caller's
    // hint (e.g. from a network search result) before falling back to the local
    // callsign→key map.
    final resolvedNpub = isSelf
        ? (self.npub.isNotEmpty ? self.npub : null)
        : (npub ?? RnsService.instance.npubForCallsign(c));
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProfileRoute(
              // Same publications, same card, same wiring as the stream.
              voteInfo: (mid) => RnsService.instance.nostrVotes(mid),
              onVote: (mid, vote) {
                final author = _activityAuthorHex(mid);
                RnsService.instance.nostrVote(mid, author, vote);
                setState(() {});
              },
              isSaved: (mid) => _activityArchive?.isSaved(mid) ?? false,
              onSave: (post) {
                _activityArchive?.toggleSaved(post);
                _keepPostMedia(post);
                setState(() {});
              },
              profileFor: _feedProfileFor,
              npubFor: (c) =>
                  _wappProfiles[c]?['npub'] ??
                  RnsService.instance.npubForCallsign(c),
          callsign: c,
          npub: resolvedNpub,
          isSelf: isSelf,
          // Hosting your OWN posts is not a choice — they already live here.
          keepData:
              !isSelf &&
              _keepHexOf(resolvedNpub) != null &&
              RnsService.instance.isKeepData(_keepHexOf(resolvedNpub)!),
          onSetKeep: isSelf || _keepHexOf(resolvedNpub) == null
              ? null
              : (keep) {
                  RnsService.instance.setKeepData(
                    _keepHexOf(resolvedNpub)!,
                    keep,
                  );
                  if (mounted) setState(() {});
                },
          firstSeenMs: arch?.firstSeenMs(c),
          postCount: arch?.postCount(c) ?? 0,
          posts: arch?.byAuthor(c) ?? const [],
          onPostTap: (post) {
            Navigator.of(context).pop();
            _openConvoFromFeed(post);
          },
          onMessage: isSelf
              ? null
              : () {
                  Navigator.of(context).pop();
                  _openConvoById(c);
                },
          following: _followedCalls.contains(c.toUpperCase()),
          blocked: _blockedCalls.contains(c.toUpperCase()),
          onSetFollow: isSelf
              ? null
              : (follow) {
                  final uc = c.toUpperCase();
                  if (follow) {
                    _followedCalls.add(uc);
                  } else {
                    _followedCalls.remove(uc);
                  }
                  _fieldValues['profile_target'] = c;
                  _sendCommand(follow ? 'profile_follow' : 'profile_unfollow');
                },
          onSetBlock: isSelf
              ? null
              : (block) {
                  final uc = c.toUpperCase();
                  if (block) {
                    _blockedCalls.add(uc);
                  } else {
                    _blockedCalls.remove(uc);
                  }
                  _fieldValues['profile_target'] = c;
                  _sendCommand(block ? 'profile_block' : 'profile_unblock');
                },
          loadSelf: isSelf ? _loadSelfProfile : null,
          onEdit: isSelf ? _editOwnProfile : null,
          fetchMetadata: isSelf || resolvedNpub == null
              ? null
              : () => RnsService.instance.fetchProfileMetadata(resolvedNpub),
          // The Reticulum devices this user has been seen announcing from, with a
          // live online/last-seen status — resolved by callsign (each device
          // beacons the same callsign). Refreshed each time the panel opens.
          fetchDevices: () async => RnsService.instance.devicesForCallsign(c),
          resolveAvatar: _imageForPicture,
        ),
      ),
    );
  }

  /// Open the shared full profile page for a geogram device tapped in the
  /// Reticulum graph — the same page NOSTR/Chat show (Follow / Message / Mute),
  /// plus the reticulum facts: observed first-seen + the hubs it's reachable via.
  void _openReticulumProfile({
    required String callsign,
    String? npub,
    int? firstSeenMs,
    List<String> reachableVia = const [],
  }) {
    final c = callsign.trim();
    if (c.isEmpty) return;
    final arch = _activityArchive;
    final resolvedNpub = (npub != null && npub.isNotEmpty)
        ? npub
        : RnsService.instance.npubForCallsign(c);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProfileRoute(
              // Same publications, same card, same wiring as the stream.
              voteInfo: (mid) => RnsService.instance.nostrVotes(mid),
              onVote: (mid, vote) {
                final author = _activityAuthorHex(mid);
                RnsService.instance.nostrVote(mid, author, vote);
                setState(() {});
              },
              isSaved: (mid) => _activityArchive?.isSaved(mid) ?? false,
              onSave: (post) {
                _activityArchive?.toggleSaved(post);
                _keepPostMedia(post);
                setState(() {});
              },
              profileFor: _feedProfileFor,
              npubFor: (c) =>
                  _wappProfiles[c]?['npub'] ??
                  RnsService.instance.npubForCallsign(c),
          callsign: c,
          npub: resolvedNpub,
          firstSeenMs: firstSeenMs ?? arch?.firstSeenMs(c),
          reachableVia: reachableVia,
          postCount: arch?.postCount(c) ?? 0,
          posts: arch?.byAuthor(c) ?? const [],
          onPostTap: (post) {
            Navigator.of(context).pop();
            _openConvoFromFeed(post);
          },
          onMessage: () {
            Navigator.of(context).pop();
            _openConvoById(c);
          },
          following: _followedCalls.contains(c.toUpperCase()),
          blocked: _blockedCalls.contains(c.toUpperCase()),
          muted: RnsService.instance.isMutedCallsign(c),
          onSetFollow: (follow) {
            final uc = c.toUpperCase();
            if (follow) {
              _followedCalls.add(uc);
            } else {
              _followedCalls.remove(uc);
            }
            _applyNostrFollow(c, follow);
            _fieldValues['profile_target'] = c;
            _sendCommand(follow ? 'profile_follow' : 'profile_unfollow');
          },
          onSetBlock: (block) {
            final uc = c.toUpperCase();
            if (block) {
              _blockedCalls.add(uc);
            } else {
              _blockedCalls.remove(uc);
            }
            _fieldValues['profile_target'] = c;
            _sendCommand(block ? 'profile_block' : 'profile_unblock');
          },
          onSetMute: (mute) {
            RnsService.instance.setMutedCallsign(c, mute);
            if (mounted) setState(() {}); // re-filter the graph lists
          },
          // "Keep data": this device becomes a home for their posts and media.
          // Keyed by hex pubkey — what the mirror, the retention tiers and the
          // relay store all speak — so it is only offered for accounts we can
          // resolve an npub for.
          keepData:
              _keepHexOf(resolvedNpub) != null &&
              RnsService.instance.isKeepData(_keepHexOf(resolvedNpub)!),
          onSetKeep: _keepHexOf(resolvedNpub) == null
              ? null
              : (keep) {
                  RnsService.instance.setKeepData(
                    _keepHexOf(resolvedNpub)!,
                    keep,
                  );
                  if (mounted) setState(() {});
                },
          fetchMetadata: resolvedNpub == null
              ? null
              : () => RnsService.instance.fetchProfileMetadata(resolvedNpub),
          fetchDevices: () async => RnsService.instance.devicesForCallsign(c),
          resolveAvatar: _imageForPicture,
        ),
      ),
    );
  }

  /// Resolve a stream post author's callsign to its display name + avatar. Our
  /// own callsign uses the local identity; others use the auto-fetched NOSTR
  /// profile cache (populated only for people we follow).
  ({String? name, ImageProvider? avatar}) _streamProfileFor(String callsign) {
    final self = ProfileService.instance.activeProfile;
    if (self != null && callsign.toUpperCase() == self.callsign.toUpperCase()) {
      return (
        name: self.nickname.trim().isEmpty ? null : self.nickname.trim(),
        avatar: _loadSelfProfile().avatar,
      );
    }
    final meta = RnsService.instance.profileMetaFor(callsign);
    if (meta == null) {
      // Not cached yet — if we follow this callsign, auto-fetch its NOSTR
      // profile (deduped + TTL-gated in the service; repaints via the listener).
      if (_followedCalls.contains(callsign.trim().toUpperCase())) {
        RnsService.instance.fetchFollowedProfile(callsign);
      }
      return (name: null, avatar: null);
    }
    final name = (meta['name'] ?? meta['display_name'] ?? '').toString().trim();
    final pic = (meta['picture'] ?? '').toString();
    return (
      name: name.isEmpty ? null : name,
      avatar: pic.isEmpty ? null : _imageForPicture(pic),
    );
  }

  /// Read our own profile (nickname/description/avatar) for the profile view.
  SelfData _loadSelfProfile() {
    final p = ProfileService.instance.activeProfile;
    if (p == null) return (name: null, about: null, avatar: null);
    ImageProvider? avatar;
    if (p.avatar.isNotEmpty) {
      try {
        final path = ProfileService.instance
            .storageForProfile(p.id)
            .getAbsolutePath(p.avatar);
        final f = File(path);
        if (f.existsSync()) avatar = FileImage(f);
      } catch (_) {}
    }
    return (name: p.nickname, about: p.description, avatar: avatar);
  }

  /// Open the profile editor, then publish the updated profile as a NOSTR
  /// kind-0 note so peers can fetch it by npub.
  Future<void> _editOwnProfile() async {
    final p = ProfileService.instance.activeProfile;
    if (p == null) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ProfileEditPage(profile: p)),
    );
    if (saved != true) return;
    // The avatar lives at a fixed path ('avatar.png'); evict the cached image so
    // a freshly-picked picture re-decodes instead of showing the old one.
    final edited = ProfileService.instance.activeProfile;
    if (edited != null && edited.avatar.isNotEmpty) {
      try {
        final path = ProfileService.instance
            .storageForProfile(edited.id)
            .getAbsolutePath(edited.avatar);
        await FileImage(File(path)).evict();
      } catch (_) {}
    }
    await _publishOwnProfileMetadata();
  }

  /// Build the signed kind-0 metadata note from the active profile: nickname →
  /// name, description → about, avatar → a small inline `data:` PNG so the
  /// picture travels WITH the note over the relay (reliable between peers; no
  /// dependency on the media swarm / public hosts).
  Future<void> _publishOwnProfileMetadata() async {
    final p = ProfileService.instance.activeProfile;
    if (p == null) return;
    String? picture;
    if (p.avatar.isNotEmpty) {
      try {
        final path = ProfileService.instance
            .storageForProfile(p.id)
            .getAbsolutePath(p.avatar);
        final f = File(path);
        if (await f.exists()) {
          final bytes = await f.readAsBytes();
          final thumb = await _thumbnailPng(bytes, 96);
          if (thumb != null) {
            picture = 'data:image/png;base64,${base64Encode(thumb)}';
          }
        }
      } catch (_) {}
    }
    await RnsService.instance.publishMetadata(
      name: p.nickname,
      about: p.description,
      picture: picture,
    );
  }

  /// If [text] references a held image or video via a `file:` token, embed a
  /// tiny PNG preview as a `tn:<base64url>` token so peers can render a
  /// thumbnail for the post WITHOUT downloading the full file. Only the first
  /// media that yields a preview, only when the encoded form stays small;
  /// otherwise [text] is returned unchanged.
  Future<String> _embedNoteThumbnail(String text) async {
    try {
      if (text.contains(' tn:')) return text; // already carries a preview
      final archive = sharedMediaArchive();
      if (archive == null) return text;
      for (final r in MediaRef.findAll(text)) {
        if (r.kind != MediaKind.image && r.kind != MediaKind.video) continue;
        // Reuse a cached poster if one exists, else generate + cache it.
        // Video posters come from the player wapp's wasm decoder (headless).
        var poster = archive.getScreenshot(r.sha256);
        if (poster == null) {
          final full = archive.get(r.sha256);
          if (full == null) continue; // not held — can't make a preview
          poster = r.kind == MediaKind.image
              ? await _thumbnailPng(full, 128)
              : await WasmVideoThumbnailer.generate(full, r.ext);
          if (poster == null) continue;
          archive.setScreenshot(r.sha256, poster);
        }
        // Wire copy: cached posters can be up to 360px — re-downscale so the
        // inline token stays small, dropping to 96px if 128px still busts the
        // cap (relay ingest allows 64 KB of content; stay well under).
        var wire = await _thumbnailPng(poster, 128) ?? poster;
        var b64 = base64Url.encode(wire);
        if (b64.length > 40000) {
          wire = await _thumbnailPng(poster, 96) ?? wire;
          b64 = base64Url.encode(wire);
          if (b64.length > 40000) continue; // too large to inline
        }
        return '$text tn:$b64';
      }
    } catch (_) {}
    return text;
  }

  /// Downscale [src] image bytes to a square-ish PNG at most [size] px wide, for
  /// embedding in a profile note. Null on decode failure.
  Future<Uint8List?> _thumbnailPng(Uint8List src, int size) async {
    try {
      final codec = await ui.instantiateImageCodec(src, targetWidth: size);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  /// Resolve a profile `picture` field to an avatar image: an inline `data:` URI
  /// (preferred — bytes are right there) or a `file:<sha>` media token resolved
  /// from the local media archive (swarm fetch kicked off if missing).
  ImageProvider? _imageForPicture(String picture) {
    final pic = picture.trim();
    if (pic.isEmpty) return null;
    if (pic.startsWith('data:')) {
      final comma = pic.indexOf(',');
      if (comma < 0) return null;
      try {
        return MemoryImage(base64Decode(pic.substring(comma + 1)));
      } catch (_) {
        return null;
      }
    }
    final refs = MediaRef.findAll(pic);
    if (refs.isEmpty) return null;
    final ref = refs.first;
    final bytes = sharedMediaArchive()?.get(ref.sha256);
    if (bytes != null) return MemoryImage(bytes);
    maybeFetchSharedMedia(ref.token, 'in');
    return null;
  }

  // ── Tasks viewer ──────────────────────────────────────────────────

  Widget _buildTasksScreen() {
    final cs = Theme.of(context).colorScheme;
    final tasks = _taskSnapshot;

    final running = tasks.where((t) => t.status == TaskStatus.running).length;
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
                label: 'running',
                count: running,
                color: Colors.green,
              ),
              const SizedBox(width: 6),
              _StatusPill(label: 'idle', count: idle, color: cs.primary),
              const SizedBox(width: 6),
              _StatusPill(label: 'paused', count: paused, color: Colors.amber),
              const SizedBox(width: 6),
              _StatusPill(label: 'error', count: errored, color: cs.error),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _sendCommand('pause-all'),
                icon: const Icon(Icons.pause_circle, size: 18),
                label: const Text('Pause all'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              TextButton.icon(
                onPressed: () => _sendCommand('resume-all'),
                icon: const Icon(Icons.play_circle, size: 18),
                label: const Text('Resume all'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: tasks.isEmpty
              ? const Center(
                  child: Text(
                    'No tasks registered yet.',
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
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
                      Text(
                        task.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        task.id,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                _MiniPill(label: task.status.name, color: statusColor),
                const SizedBox(width: 4),
                _MiniPill(label: task.priority.name, color: priorityColor),
                const SizedBox(width: 4),
                _MiniPill(label: task.type.name, color: cs.onSurfaceVariant),
                if (task.bootStart != BootStart.none) ...[
                  const SizedBox(width: 4),
                  _MiniPill(
                    label: 'boot:${task.bootStart.name}',
                    color: bootColor,
                  ),
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
                if (lastMs != null) _Stat(label: 'last', value: '${lastMs}ms'),
                _Stat(label: 'cpu', value: '${task.totalCpuMs}ms'),
                if (task.interval != null)
                  _Stat(
                    label: 'every',
                    value: '${task.interval!.inMilliseconds}ms',
                  ),
              ],
            ),
            if (task.lastError != null) ...[
              const SizedBox(height: 6),
              Text(
                task.lastError!,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: cs.error,
                ),
              ),
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
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                if (isPaused)
                  TextButton.icon(
                    onPressed: () => _sendCommand('resume ${task.id}'),
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('Resume'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                const Spacer(),
                if (isCritical)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      'critical — cannot pause',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
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
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
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
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
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
                        horizontal: 18,
                        vertical: 14,
                      ),
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
            child: Icon(
              Icons.cloud_outlined,
              size: 20,
              color: cs.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(host, style: const TextStyle(fontWeight: FontWeight.w600)),
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
    _engine.sendMessage(
      jsonEncode({
        'type': 'action',
        'action': 'set_sources',
        'fields': {'source': next.join('\n')},
      }),
    );
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
    final isUrl =
        lowered.startsWith('http://') || lowered.startsWith('https://');
    if (isUrl) {
      // Build candidate URLs to try in priority order.
      final trimmed = raw.endsWith('/')
          ? raw.substring(0, raw.length - 1)
          : raw;
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
      final base = raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
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
      final resp = await HttpTransport.shared.get(
        Uri.parse(url),
        timeout: const Duration(seconds: 6),
      );
      if (!resp.isOk) return false;
      final parsed = jsonDecode(resp.bodyString);
      return parsed is List;
    } catch (_) {
      return false;
    }
  }

  /// Wapp Store catalog: render the structured cards a wapp pushed via
  /// `ui.data` (target "catalog"), plus the screen's header-actions menu (the
  /// top-right ⋮). Tapping a card's action dispatches it back to the wapp (e.g.
  /// "install:<slug>" → the store's do_install), so the store stays in control.
  Widget _buildCardsScreen(GeoUiBlock screen, GeoUiBlock cardsGroup) {
    final cs = Theme.of(context).colorScheme;
    final updates = _catalogUpdateSlugs();

    void dispatch(String name) {
      if (name.isEmpty) return;
      _engine.sendMessage(jsonEncode({'type': 'action', 'action': name}));
      _engine.handleEvent();
      _drainOutbox();
    }

    // Collect the header-actions menu items (the top-right ⋮).
    final menuItems = <GeoUiBlock>[];
    for (final g in screen.children.where(
      (c) => c.keyword == 'group' && c.type == 'header-actions',
    )) {
      for (final m in g.children.where(
        (c) => c.keyword == 'group' && c.type == 'menu',
      )) {
        menuItems.addAll(m.children.where((c) => c.keyword == 'action'));
      }
      menuItems.addAll(g.children.where((c) => c.keyword == 'action'));
    }

    final tip = _i18n.resolve(screen.getString('tip') ?? '');
    final empty = _i18n.resolve(
      cardsGroup.getString('empty') ?? 'No wapps found yet.',
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 6, 4),
          child: Row(
            children: [
              Expanded(
                child: tip.isEmpty
                    ? const SizedBox.shrink()
                    : Text(
                        tip,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
              ),
              if (updates.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Badge(
                    label: Text('${updates.length}'),
                    child: Icon(
                      Icons.system_update,
                      color: cs.onSurfaceVariant,
                      size: 22,
                    ),
                  ),
                ),
              if (menuItems.isNotEmpty)
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  tooltip: 'Options',
                  onSelected: dispatch,
                  itemBuilder: (_) => [
                    for (final a in menuItems)
                      PopupMenuItem<String>(
                        value: a.name ?? '',
                        child: Row(
                          children: [
                            Icon(
                              geoUiResolveIcon(a.getString('icon') ?? 'tune'),
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              _i18n.resolve(
                                a.getString('label') ?? a.name ?? '',
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
        if (updates.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Material(
              color: cs.tertiaryContainer,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.system_update,
                      color: cs.onTertiaryContainer,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        updates.length == 1
                            ? '1 update available'
                            : '${updates.length} updates available',
                        style: TextStyle(
                          color: cs.onTertiaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _updatingAll ? null : () => _updateAll(),
                      icon: _updatingAll
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.upgrade, size: 16),
                      label: Text(_updatingAll ? 'Updating...' : 'Update all'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(
          child: _catalogItems.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      empty,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                  itemCount: _catalogItems.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) =>
                      _catalogCard(_catalogItems[i], cs, dispatch),
                ),
        ),
      ],
    );
  }

  Widget _catalogCard(
    Map<String, dynamic> item,
    ColorScheme cs,
    void Function(String) dispatch,
  ) {
    final id = '${item['id'] ?? ''}';
    final title = '${item['title'] ?? (id.isEmpty ? 'Wapp' : id)}';
    final subtitle = '${item['subtitle'] ?? ''}';
    final desc = '${item['description'] ?? ''}';
    final chips = (item['chips'] as List?) ?? const [];
    final actions = (item['actions'] as List?) ?? const [];
    final action = actions.isNotEmpty && actions.first is Map
        ? Map<String, dynamic>.from(actions.first as Map)
        : null;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: _storeIconWidget(
                id,
                size: 26,
                color: cs.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (desc.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        desc,
                        style: const TextStyle(fontSize: 13),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (chips.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final c in chips.whereType<Map>())
                            _catalogChip(
                              '${c['label'] ?? ''}',
                              '${c['icon'] ?? ''}',
                              cs,
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _catalogTrailing(_wappSlug(id), title, action, cs, dispatch),
          ],
        ),
      ),
    );
  }

  /// The trailing controls of a catalog card: the Install/Update/Installed
  /// button, plus an Uninstall (delete) button for anything installed on this
  /// device — except the store itself, which can't remove itself while running.
  Widget _catalogTrailing(
    String slug,
    String title,
    Map<String, dynamic>? action,
    ColorScheme cs,
    void Function(String) dispatch,
  ) {
    final btn = action != null
        ? _catalogActionButton(slug, action, cs, dispatch)
        : const SizedBox.shrink();
    final installed = _catalogState(slug) != 'install';
    final canUninstall = installed && slug != 'install' && slug != _wappName;
    if (!canUninstall) return btn;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn,
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 20),
          tooltip: 'Uninstall',
          visualDensity: VisualDensity.compact,
          color: cs.error,
          onPressed: () => _confirmUninstallFromStore(slug, title),
        ),
      ],
    );
  }

  /// Confirm, then remove an installed wapp from this device. The folder/catalog
  /// is untouched, so the card flips back to "Install" and the wapp can be
  /// reinstalled anytime.
  Future<void> _confirmUninstallFromStore(String slug, String title) async {
    final name = title.isEmpty ? slug : title;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final dcs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text('Uninstall $name?'),
          content: const Text(
            'This removes the wapp from this device. You can reinstall it '
            'anytime from the store.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: dcs.error,
                foregroundColor: dcs.onError,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Uninstall'),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    final result = await WappInstallerService.instance.uninstall(slug);
    if (!result.ok) {
      _outputLines.add(_OutputLine(result.error ?? 'Uninstall failed', 'err'));
    } else {
      _outputLines.add(_OutputLine('$name uninstalled', 'info'));
    }
    await _refreshInstalledVersions();
    if (mounted) setState(() {});
  }

  Widget _catalogChip(String label, String icon, ColorScheme cs) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cs.onSurfaceVariant.withAlpha(28),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon.isNotEmpty) ...[
            Icon(geoUiResolveIcon(icon), size: 13, color: cs.onSurfaceVariant),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// Render a catalog card's button from the host-computed install state for
  /// [slug] (authoritative — based on what's actually installed on the device),
  /// not the label the store guessed. The action name is still the store's
  /// (e.g. "install:<file>") so the dispatch reaches do_install.
  Widget _catalogActionButton(
    String slug,
    Map<String, dynamic> a,
    ColorScheme cs,
    void Function(String) dispatch,
  ) {
    final name = '${a['name'] ?? 'install:$slug'}';
    switch (_catalogState(slug)) {
      case 'installed':
        return OutlinedButton.icon(
          onPressed: null,
          icon: const Icon(Icons.check, size: 16),
          label: const Text('Installed'),
          style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
        );
      case 'update':
        return FilledButton.icon(
          onPressed: () => dispatch(name),
          icon: const Icon(Icons.upgrade, size: 16),
          label: const Text('Update'),
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            backgroundColor: cs.tertiary,
            foregroundColor: cs.onTertiary,
          ),
        );
      default:
        return FilledButton.icon(
          onPressed: () => dispatch(name),
          icon: const Icon(Icons.download, size: 16),
          label: const Text('Install'),
          style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
        );
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

      final match = RegExp(
        r'^\s{2}(\S+)\s+v(\S+)(?:\s+\(([^)]+)\))?(.*)$',
      ).firstMatch(text);
      if (match != null && line.level == 'out') {
        final name = match.group(1)!;
        final version = match.group(2)!;
        final size = match.group(3) ?? '';
        final status = match.group(4)?.trim() ?? '';

        final actuallyInstalled = _installed.existsSync('$name/app.wasm');

        wapps.add(
          _CatalogWapp(
            name: name,
            version: version,
            size: size,
            installed: actuallyInstalled,
            updateAvailable: status.contains('[update:'),
          ),
        );
        continue;
      }

      // Metadata line attached to the previously-added wapp. The
      // four-space indent is the wapp's way of saying "this belongs
      // to the entry above me".
      if (line.level == 'out' && text.startsWith('    ') && wapps.isNotEmpty) {
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
              .where(
                (w) =>
                    w.name.toLowerCase().contains(query) ||
                    w.description.toLowerCase().contains(query),
              )
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
        SliverToBoxAdapter(child: _buildStoreHeader(cs, total: wapps.length)),

        // Featured banner for the first catalog entry — a little
        // Play-Store-flavoured spotlight on what's "new" in the repo.
        if (hasCatalog)
          SliverToBoxAdapter(child: _buildFeaturedCard(wapps.first, cs)),

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
                    Row(
                      children: [
                        Icon(Icons.error_outline, size: 18, color: cs.error),
                        const SizedBox(width: 8),
                        Text(
                          'Something went wrong',
                          style: TextStyle(
                            color: cs.onErrorContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    for (final err in errors)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          err,
                          style: TextStyle(
                            color: cs.onErrorContainer,
                            fontSize: 12,
                          ),
                        ),
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
                      horizontal: 8,
                      vertical: 2,
                    ),
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
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
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

  Widget _buildStoreHeader(ColorScheme cs, {required int total}) {
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
                  prefixIcon: Icon(Icons.search, color: cs.onSurfaceVariant),
                  suffixIcon: _storeSearch.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _storeSearch = ''),
                        ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
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
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
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
            colors: [color.withAlpha(180), color.withAlpha(90)],
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
        final bytes = ScopedProfileStorage(
          _installed,
          wapp.name,
        ).readBytesSync(relativePath);
        if (bytes != null) return bytes;
      }
      // 2. Built-in archive
      final archivePkg = wappPackageStorage(
        '${platform.currentDirectory()}/../wapps/${wapp.name}',
      );
      return archivePkg.readBytesSync(relativePath);
    }

    final effectiveBytes = _readFromWapp('store/description.json');

    if (effectiveBytes != null) {
      try {
        final desc =
            jsonDecode(utf8.decode(effectiveBytes)) as Map<String, dynamic>;
        final descriptions =
            desc['descriptions'] as Map<String, dynamic>? ?? {};
        // Resolve by active locale, fallback to en.
        final prefs = PreferencesService.instanceSync;
        final locale = prefs?.activeLocale() ?? 'en';
        final langCode = locale.split('_').first;
        final localeDesc =
            (descriptions[locale] ??
                    descriptions[langCode] ??
                    descriptions['en'])
                as Map<String, dynamic>?;
        if (localeDesc != null) {
          wapp.storeTitle = (localeDesc['title'] as String?) ?? '';
          wapp.storeSummary = (localeDesc['summary'] as String?) ?? '';
          wapp.storeBody = (localeDesc['body'] as String?) ?? '';
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
        final perm = jsonDecode(utf8.decode(permBytes)) as Map<String, dynamic>;
        final access = perm['access'] as Map<String, dynamic>? ?? {};
        final commentAccess = access['comment'] as Map<String, dynamic>?;
        final reactAccess = access['react'] as Map<String, dynamic>?;
        wapp.permitComments = commentAccess?['type'] != 'none';
        wapp.permitLikes = reactAccess?['type'] != 'none';
      } catch (_) {}
    }

    // If no store description was found, try reading the manifest's
    // description field as a title fallback.
    if (wapp.storeTitle.isEmpty) {
      final manifestBytes = _readFromWapp('manifest.json');
      if (manifestBytes != null) {
        try {
          final m =
              jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
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
      wapp.likeCount = WappSocialStore.instance.reactionCount(wappDir);
      wapp.commentCount = WappSocialStore.instance.commentCount(wappDir);
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
    final displayDesc = wapp.storeSummary.isNotEmpty ? wapp.storeSummary : '';

    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                          fontSize: 10,
                          color: cs.onSurfaceVariant,
                        ),
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
                        horizontal: 6,
                        vertical: 4,
                      ),
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
                                color: liked ? cs.primary : cs.onSurfaceVariant,
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
                        horizontal: 6,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.comment_outlined,
                            size: 14,
                            color: cs.onSurfaceVariant,
                          ),
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
                SizedBox(height: 28, child: _storeActionButton(wapp, cs)),
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
                                style: TextStyle(color: cs.onSurfaceVariant),
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              itemCount: currentComments.length,
                              itemBuilder: (ctx, i) {
                                final c = currentComments[i];
                                final author = c['npub'] as String? ?? '';
                                final short = author.length > 16
                                    ? '${author.substring(0, 10)}...'
                                    : author;
                                final ts = c['created_at'] as int? ?? 0;
                                final date =
                                    DateTime.fromMillisecondsSinceEpoch(
                                      ts * 1000,
                                    );
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.person_outline,
                                            size: 14,
                                            color: cs.onSurfaceVariant,
                                          ),
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
                                              color: cs.onSurfaceVariant,
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
                              color: cs.outlineVariant.withAlpha(80),
                            ),
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
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                ),
                                onSubmitted: (text) {
                                  if (text.trim().isEmpty) return;
                                  final id =
                                      '${myNpub.hashCode.abs()}_${DateTime.now().millisecondsSinceEpoch}';
                                  store.addComment(
                                    dir,
                                    id: id,
                                    content: text.trim(),
                                    npub: myNpub,
                                  );
                                  commentController.clear();
                                  wapp.commentCount++;
                                  setSheetState(() {});
                                  setState(() {});
                                },
                              ),
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.send,
                                color: cs.primary,
                                size: 20,
                              ),
                              onPressed: () {
                                final text = commentController.text.trim();
                                if (text.isEmpty) return;
                                final id =
                                    '${myNpub.hashCode.abs()}_${DateTime.now().millisecondsSinceEpoch}';
                                store.addComment(
                                  dir,
                                  id: id,
                                  content: text,
                                  npub: myNpub,
                                );
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
  Widget _storeActionButton(
    _CatalogWapp wapp,
    ColorScheme cs, {
    bool dark = false,
  }) {
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
                : cs.primary.withAlpha(120),
          ),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
          size: 16,
        ),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black87,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      );
    }
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(
        wapp.updateAvailable ? Icons.upgrade : Icons.download_rounded,
        size: 16,
      ),
      label: Text(label),
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
  /// Reduce a .wapp leaf filename to its stable slug — the install directory
  /// name. "aprs-0.2.60.wapp" -> "aprs", "app-creator-0.3.4.wapp" ->
  /// "app-creator", "widget_demo-1.0.1.wapp" -> "widget_demo". The slug matches
  /// both the bundled wapp folders and what the catalog card echoes back, so it
  /// is the single key for install/update/installed state.
  static String _wappSlug(String fileOrId) {
    var s = fileOrId.split('/').last;
    if (s.toLowerCase().endsWith('.wapp')) s = s.substring(0, s.length - 5);
    final m = RegExp(
      r'^(.+)-(\d+\.\d+(?:\.\d+)?(?:[-.][0-9A-Za-z.]+)?)$',
    ).firstMatch(s);
    return m != null ? m.group(1)! : s;
  }

  /// Compare two dotted version strings numerically. Returns >0 when [a] is
  /// newer than [b], 0 when equal, <0 when older. Non-numeric suffixes
  /// (e.g. "-beta.4") are reduced to their leading integer per segment.
  static int _versionCmp(String a, String b) {
    List<int> parts(String v) => v.split(RegExp(r'[.\-+]')).map((s) {
      final m = RegExp(r'^\d+').firstMatch(s);
      return m != null ? int.parse(m.group(0)!) : 0;
    }).toList();
    final pa = parts(a), pb = parts(b);
    for (var i = 0; i < pa.length || i < pb.length; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  /// Re-read the version of every installed wapp (keyed by its folder slug) so
  /// the store can show Install / Update / Installed and an update counter.
  Future<void> _refreshInstalledVersions() async {
    final next = <String, String>{};
    try {
      if (await _installed.directoryExists('')) {
        for (final e in await _installed.listDirectory('')) {
          if (!e.isDirectory) continue;
          try {
            final m = await wappPackageStorage(
              _installed.getAbsolutePath(e.path),
            ).readJson('manifest.json');
            final ver = (m?['version'] ?? '').toString();
            if (ver.isNotEmpty) next[e.name] = ver;
          } catch (_) {}
        }
      }
    } catch (_) {}
    _installedVersions
      ..clear()
      ..addAll(next);
  }

  /// The install state of a catalog card by its slug: 'install' (not present),
  /// 'update' (installed, catalog is newer), or 'installed' (up to date).
  String _catalogState(String slug) {
    final inst = _installedVersions[slug];
    if (inst == null) return 'install';
    final cat = _catalogMeta[slug]?['version'] ?? '';
    if (cat.isEmpty) return 'installed';
    return _versionCmp(cat, inst) > 0 ? 'update' : 'installed';
  }

  /// Slugs that have a newer version available in the catalog.
  List<String> _catalogUpdateSlugs() => _catalogMeta.keys
      .where((slug) => _catalogState(slug) == 'update')
      .toList();

  /// Re-install every wapp that has a newer version in the catalog, in turn,
  /// straight from the signed Reticulum folder the catalog came from.
  Future<void> _updateAll() async {
    if (_updatingAll) return;
    final slugs = _catalogUpdateSlugs();
    if (slugs.isEmpty || _catalogSourceAddr.isEmpty) return;
    setState(() => _updatingAll = true);
    try {
      for (final slug in slugs) {
        final meta = _catalogMeta[slug];
        final file = meta?['file'] ?? '';
        final version = meta?['version'] ?? '';
        if (file.isEmpty) continue;
        // _installWappFromRns fetches by content sha, installs under the slug,
        // and refreshes _installedVersions on success.
        await _installWappFromRns(_catalogSourceAddr, file, slug, version);
      }
    } finally {
      await _refreshInstalledVersions();
      if (mounted) setState(() => _updatingAll = false);
    }
  }

  Uint8List? _storeSvgBytesFor(String name) {
    // 0. A catalog icon shipped inline in the folder's index.json (so a wapp
    //    that isn't installed yet still shows its authored icon in the store).
    final catalog = _catalogIcons[name];
    if (catalog != null && catalog.isNotEmpty) return catalog;
    // Try multiple sources for the wapp's manifest + icon:
    // 1. Current running wapp (if name matches)
    // 2. Installed copy under the profile
    // 3. Built-in archive
    final candidates = <ProfileStorage>[
      if (name == _wappName) _pkg,
      if (_installed.existsSync('$name/manifest.json'))
        ScopedProfileStorage(_installed, name),
      wappPackageStorage('${platform.currentDirectory()}/../wapps/$name'),
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
  Widget _storeIconWidget(
    String name, {
    required double size,
    Color color = Colors.white,
  }) {
    final svgBytes = _storeSvgBytesFor(name);
    if (svgBytes != null) {
      return Padding(
        padding: EdgeInsets.all(size * 0.12),
        child: SvgPicture.memory(
          svgBytes,
          fit: BoxFit.contain,
          theme: SvgTheme(currentColor: color),
          placeholderBuilder: (_) =>
              Icon(wappIconFor(name), size: size, color: color),
        ),
      );
    }
    return Icon(wappIconFor(name), size: size, color: color);
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
              const Text(
                '\$ ',
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: Color(0xFF7EE787),
                  fontSize: 13,
                ),
              ),
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
    String funcId,
    List<WappManifest> providers,
    ColorScheme cs,
  ) {
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
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(12),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
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
                  fontSize: 13,
                  color: cs.onSurface,
                  height: 1.3,
                ),
              ),
            ),
          // ── Providers ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Text(
              'Providers',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant,
                letterSpacing: 0.3,
              ),
            ),
          ),
          for (final provider in providers)
            _buildProviderRow(funcId, provider, providers, cs),
          // ── Endpoints ──
          if (def != null && def.endpoints.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Text(
                'Endpoints',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            for (final ep in def.endpoints) _buildEndpointRow(ep, cs),
            // Per-functionality JSON spec button
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: OutlinedButton.icon(
                onPressed: () => _showFunctionalitySpec(funcId, def, providers),
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
                          style: TextStyle(color: cs.primary, fontSize: 12),
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
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                  fontSize: 11,
                  color: cs.onSurfaceVariant,
                  height: 1.3,
                ),
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
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                ),
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
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                ),
                                decoration: InputDecoration(
                                  hintText: p.description.isNotEmpty
                                      ? p.description
                                      : p.type,
                                  hintStyle: TextStyle(
                                    fontSize: 11,
                                    color: cs.onSurfaceVariant.withAlpha(120),
                                  ),
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 6,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                ),
                                keyboardType:
                                    p.type == 'int' ||
                                        p.type == 'uint32' ||
                                        p.type == 'uint64'
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
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
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
                  border: Border.all(color: cs.outlineVariant.withAlpha(80)),
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

  void _showFunctionalitySpec(
    String funcId,
    FunctionalityDef def,
    List<WappManifest> providers,
  ) {
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
        builder: (_) => _ApiJsonExportPage(title: funcId, json: jsonText),
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
        return platform.currentDirectory().isNotEmpty ? 'linux-desktop' : 'web';
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

  Widget _buildProviderRow(
    String funcId,
    WappManifest provider,
    List<WappManifest> allProviders,
    ColorScheme cs,
  ) {
    final prefs = PreferencesService.instanceSync;
    final preferredId = prefs?.getPreferredProvider(funcId);
    final isDefault =
        allProviders.length == 1 ||
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
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
      bindings: _WappFieldBindings(
        _engine,
        _fieldValues,
        () => setState(() {}),
      ),
      i18n: _i18n,
      resolveImage: _imageForPicture,
      onAction: (action) {
        // A `$type:"image"` field's Choose button fires `<field>__pickimage`.
        // The host owns the native picker + the content-addressed archive, so it
        // handles the pick here: store the image, set the field to its token, and
        // forward the command so the wapp persists the new picture.
        if (action.endsWith('__pickimage')) {
          final base = action.substring(
            0,
            action.length - '__pickimage'.length,
          );
          _pickImageForField(base, action);
          return;
        }
        if (action == 'save') {
          _engine.sendMessage(
            jsonEncode({
              'type': 'action',
              'action': 'save',
              'fields': _fieldValues,
            }),
          );
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
    final isSettingsScreen = screen.children.any(
      (c) => c.keyword == 'group' && c.name == 'identity',
    );
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
    'video': 'Codec-free A/V sink',
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
          decoration: const InputDecoration(hintText: 'e.g. weather_card'),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Imported: ${profile.callsign}'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Invalid nsec: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  /// Split a comma-separated string into a trimmed, non-empty list.
  static List<String> _splitCsv(String csv) =>
      csv.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

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
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
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
          letterSpacing: 0.3,
        ),
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
              fontWeight: FontWeight.w600,
            ),
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
    // Settings field that drives the host media auto-download threshold (MB).
    if (fieldName == 'media_auto_mb') {
      final mb = int.tryParse('$value'.trim());
      if (mb != null) PreferencesService.instanceSync?.mediaAutoMaxMb = mb;
    }
    _onChange();
  }
}

// ── Forward-message picker ───────────────────────────────────────────────
// A search box over existing conversations (DMs + group rooms) plus a free
// callsign/#group field, used to forward a message somewhere else.
class _ForwardPanel extends StatefulWidget {
  final List<ConversationItem> contacts;
  final void Function(String target) onPick;
  const _ForwardPanel({required this.contacts, required this.onPick});

  @override
  State<_ForwardPanel> createState() => _ForwardPanelState();
}

class _ForwardPanelState extends State<_ForwardPanel> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final q = _search.text.trim().toUpperCase();
    final matches = [
      for (final c in widget.contacts)
        if (q.isEmpty ||
            c.id.toUpperCase().contains(q) ||
            c.title.toUpperCase().contains(q))
          c,
    ];
    // Offer the typed text itself as a fresh target (callsign or #group) when it
    // isn't already an exact existing conversation.
    final typed = _search.text.trim();
    final exact = widget.contacts.any((c) => c.id.toUpperCase() == q);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Row(
                  children: [
                    const Icon(Icons.forward, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Forward to',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: TextField(
                  controller: _search,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search contacts, or type a callsign / #group',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (v) {
                    if (v.trim().isNotEmpty) widget.onPick(v.trim());
                  },
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: ListView(
                  children: [
                    if (typed.isNotEmpty && !exact)
                      ListTile(
                        leading: CircleAvatar(
                          backgroundColor: cs.primaryContainer,
                          child: const Icon(Icons.send, size: 18),
                        ),
                        title: Text('Send to "$typed"'),
                        subtitle: const Text('new callsign or #group'),
                        onTap: () => widget.onPick(typed),
                      ),
                    for (final c in matches)
                      ListTile(
                        leading: CircleAvatar(
                          backgroundColor: cs.secondaryContainer,
                          child: Icon(
                            c.id.startsWith('#') ? Icons.groups : Icons.person,
                            size: 18,
                          ),
                        ),
                        title: Text(c.title.isEmpty ? c.id : c.title),
                        subtitle: c.title.isEmpty || c.title == c.id
                            ? null
                            : Text(c.id),
                        onTap: () => widget.onPick(c.id),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Slippy tile map widget ───────────────────────────────────────────
