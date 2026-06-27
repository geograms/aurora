import 'package:shared_preferences/shared_preferences.dart';

import '../platform/platform.dart' as platform;

/// Persistent user preferences backed by shared_preferences.
/// Works on all platforms including web (uses localStorage on web).
class PreferencesService {
  static PreferencesService? _instance;
  late final SharedPreferences _prefs;

  PreferencesService._();

  static Future<PreferencesService>? _pending;

  static Future<PreferencesService> instance() {
    if (_instance != null) return Future<PreferencesService>.value(_instance!);
    // Race-safe: concurrent callers share one in-flight future, and the
    // singleton is published only AFTER its SharedPreferences is ready — so
    // no caller can observe a half-initialized instance (LateInitError).
    return _pending ??= () async {
      final service = PreferencesService._();
      service._prefs = await SharedPreferences.getInstance();
      _instance = service;
      return service;
    }();
  }

  /// Sync accessor — null until the first `instance()` call has fully
  /// completed (it returns the instance only after _prefs is ready).
  static PreferencesService? get instanceSync => _instance;

  // Terminal settings
  double get terminalFontSize => _prefs.getDouble('terminal.fontSize') ?? 16.0;
  set terminalFontSize(double v) => _prefs.setDouble('terminal.fontSize', v);

  String get terminalFontFamily => _prefs.getString('terminal.fontFamily') ?? 'RobotoMono';
  set terminalFontFamily(String v) => _prefs.setString('terminal.fontFamily', v);

  double get terminalLineHeight => _prefs.getDouble('terminal.lineHeight') ?? 1.5;
  set terminalLineHeight(double v) => _prefs.setDouble('terminal.lineHeight', v);

  String get terminalColorScheme => _prefs.getString('terminal.colorScheme') ?? 'dark';
  set terminalColorScheme(String v) => _prefs.setString('terminal.colorScheme', v);

  bool get terminalShowTimestamps => _prefs.getBool('terminal.showTimestamps') ?? false;
  set terminalShowTimestamps(bool v) => _prefs.setBool('terminal.showTimestamps', v);

  int get terminalMaxLines => _prefs.getInt('terminal.maxLines') ?? 5000;
  set terminalMaxLines(int v) => _prefs.setInt('terminal.maxLines', v);

  // ── AI / Robot editor settings ───────────────────────────────────
  //
  // Backs the wapp editor's Robot tab. `aiProviderId` selects an entry
  // from lib/ai/ (e.g. 'ollama', 'openai', 'anthropic', 'builtin');
  // baseUrl/model fall back to that provider's defaults when blank.
  // NOTE: apiKey is stored in plaintext here — fine for a local dev
  // tool, but it is not encrypted.
  String get aiProviderId => _prefs.getString('ai.providerId') ?? 'ollama';
  set aiProviderId(String v) => _prefs.setString('ai.providerId', v);

  String get aiBaseUrl => _prefs.getString('ai.baseUrl') ?? '';
  set aiBaseUrl(String v) => _prefs.setString('ai.baseUrl', v);

  String get aiModel => _prefs.getString('ai.model') ?? '';
  set aiModel(String v) => _prefs.setString('ai.model', v);

  String get aiApiKey => _prefs.getString('ai.apiKey') ?? '';
  set aiApiKey(String v) => _prefs.setString('ai.apiKey', v);

  /// Optional override for the editor's default system prompt. Empty = use
  /// the built-in wapp-editing prompt assembled by the Robot controller.
  String get aiSystemPrompt => _prefs.getString('ai.systemPrompt') ?? '';
  set aiSystemPrompt(String v) => _prefs.setString('ai.systemPrompt', v);

  // ── Remote-control API ───────────────────────────────────────────
  //
  // Opens a JSON HTTP server (RemoteApiService) on [remoteApiPort] so the
  // app can be driven/inspected remotely (status, logs, launch a wapp).
  // Binds 0.0.0.0, so it is reachable from the network — turn it off on
  // untrusted networks. Default on for development convenience.
  bool get remoteApiEnabled => _prefs.getBool('remoteApi.enabled') ?? true;
  set remoteApiEnabled(bool v) => _prefs.setBool('remoteApi.enabled', v);

  int get remoteApiPort => _prefs.getInt('remoteApi.port') ?? 3456;
  set remoteApiPort(int v) => _prefs.setInt('remoteApi.port', v);

  // Run the pure-Dart I2P node as a background process (device-to-device sharing
  // across NATs). Off by default — it reseeds + builds tunnels (network/CPU), so
  // it's opt-in. Governed by the task monitor + PowerGovernor (auto-paused on
  // CPU overload / low battery).
  bool get i2pEnabled => _prefs.getBool('i2p.enabled') ?? false;
  set i2pEnabled(bool v) => _prefs.setBool('i2p.enabled', v);

  // Verbose BLE transport logging (advertise/scan/broadcast frames, NACKs).
  // Off by default; when on, the BLE layer routes diagnostics to LogService so
  // they show in the in-app log (and /api/log) without needing adb logcat.
  bool get bleDebug => _prefs.getBool('ble.debug') ?? false;
  set bleDebug(bool v) => _prefs.setBool('ble.debug', v);

  // Auto-pair: when two Aurora devices discover each other, automatically open a
  // GATT link (no manual pairing) for larger point-to-point transfers (e.g.
  // binary files / RNS resources). The link is transient — it idles out so the
  // connectionless broadcast (APRS, RNS announces) resumes. On by default.
  bool get bleAutoPair => _prefs.getBool('ble.autoPair') ?? true;
  set bleAutoPair(bool v) => _prefs.setBool('ble.autoPair', v);

  // Reticulum file sharing: daily OUTBOUND budget we'll spend serving files to
  // others (anti-abuse + politeness on metered links). Default 1 GB/day.
  int get fileServeQuotaMb => _prefs.getInt('files.serveQuotaMb') ?? 1024;
  set fileServeQuotaMb(int v) => _prefs.setInt('files.serveQuotaMb', v);

  // Whether to serve files while on a metered/cellular connection. Off by
  // default — receiving still works; we just don't spend cellular data serving.
  bool get fileServeOnCellular => _prefs.getBool('files.serveOnCellular') ?? false;
  set fileServeOnCellular(bool v) => _prefs.setBool('files.serveOnCellular', v);

  // Store-and-forward hosting: act as a NOSTR relay + Blossom host for other
  // nodes (notes and files), governed by a tier+quota system. Master switch on
  // by default; capacity-gated so a phone only hosts when charging on Wi-Fi/
  // Ethernet. All limits are tunable here with fair-use defaults.
  bool get hostEnabled => _prefs.getBool('host.enabled') ?? true;
  set hostEnabled(bool v) => _prefs.setBool('host.enabled', v);

  bool get hostCapacityGated => _prefs.getBool('host.capacityGated') ?? true;
  set hostCapacityGated(bool v) => _prefs.setBool('host.capacityGated', v);

  // Whole-node hosting ceiling (everything we store for others), in GB.
  int get hostCeilingGb => _prefs.getInt('host.ceilingGb') ?? 100;
  set hostCeilingGb(int v) => _prefs.setInt('host.ceilingGb', v < 0 ? 0 : v);

  // Strangers' (non-followed) slice of the ceiling, in GB.
  int get hostStrangerSliceGb => _prefs.getInt('host.strangerSliceGb') ?? 100;
  set hostStrangerSliceGb(int v) =>
      _prefs.setInt('host.strangerSliceGb', v < 0 ? 0 : v);

  // Strangers' text-note count cap per month.
  int get hostStrangerNotesPerMonth =>
      _prefs.getInt('host.strangerNotesPerMonth') ?? 1000;
  set hostStrangerNotesPerMonth(int v) =>
      _prefs.setInt('host.strangerNotesPerMonth', v < 0 ? 0 : v);

  // Strangers' content is deletable after this age, in days (default 5 years).
  int get hostStrangerRetentionDays =>
      _prefs.getInt('host.strangerRetentionDays') ?? 1825;
  set hostStrangerRetentionDays(int v) =>
      _prefs.setInt('host.strangerRetentionDays', v < 0 ? 0 : v);

  // Per-wapp autostart: when on, the wapp runs as a background service
  // (started at boot) and keeps its engine ticking even while its UI page is
  // closed — e.g. Chat staying connected to BLE/APRS-IS to receive messages.
  // The Chat wapp (folder 'chat', formerly 'aprs') hosts the messaging (groups,
  // direct messages, Activity feed, beacons), so it autostarts BY DEFAULT — it
  // must keep receiving + notifying in the background even when its page (or the
  // whole app) is closed. Other wapps default off. The user can still turn it
  // off explicitly.
  static const String _commsWappId = 'chat';
  bool getWappAutostart(String wappId) =>
      _prefs.getBool('wapp.autostart.$wappId') ?? (wappId == _commsWappId);
  Future<void> setWappAutostart(String wappId, bool v) =>
      _prefs.setBool('wapp.autostart.$wappId', v);

  /// Move a wapp's autostart preference from [oldId] to [newId] (used once when a
  /// wapp folder is renamed, e.g. aprs -> chat). No-op if nothing was stored.
  Future<void> migrateWappAutostart(String oldId, String newId) async {
    final oldKey = 'wapp.autostart.$oldId';
    if (!_prefs.containsKey(oldKey)) return;
    final v = _prefs.getBool(oldKey) ?? false;
    await _prefs.setBool('wapp.autostart.$newId', v);
    await _prefs.remove(oldKey);
  }

  /// Ids of all wapps that should autostart (explicitly enabled, plus the comms
  /// wapp by default unless the user turned it off).
  List<String> autostartWappIds() {
    const prefix = 'wapp.autostart.';
    final ids = _prefs
        .getKeys()
        .where((k) => k.startsWith(prefix) && (_prefs.getBool(k) ?? false))
        .map((k) => k.substring(prefix.length))
        .toSet();
    if (_prefs.getBool('$prefix$_commsWappId') ?? true) {
      ids.add(_commsWappId);
    } else {
      ids.remove(_commsWappId);
    }
    return ids.toList();
  }

  // Whether the Android BootReceiver should auto-start the background service
  // after a reboot. Written here (via shared_preferences) so it lands in the
  // same FlutterSharedPreferences store the native receiver reads — kept in sync
  // with "is any wapp marked autostart". Stored on disk as
  // "flutter.autoStartOnBoot".
  bool get autoStartOnBoot => _prefs.getBool('autoStartOnBoot') ?? false;
  Future<void> setAutoStartOnBoot(bool v) =>
      _prefs.setBool('autoStartOnBoot', v);

  // Whether we've already shown the Android battery-optimization exemption
  // prompt (so we ask once rather than nagging every launch).
  bool get batteryExemptionAsked =>
      _prefs.getBool('battery.exemptionAsked') ?? false;
  Future<void> setBatteryExemptionAsked(bool v) =>
      _prefs.setBool('battery.exemptionAsked', v);

  // Last-known scalar field values (settings) for a wapp, as a JSON string, so
  // a background/headless engine can run with the user's configured settings
  // (callsign, server, radius, …) instead of bare defaults.
  String? getWappFields(String wappId) =>
      _prefs.getString('wapp.fields.$wappId');
  void setWappFields(String wappId, String json) =>
      _prefs.setString('wapp.fields.$wappId', json);

  // First-run Android onboarding (permissions intro panel) shown + handled.
  bool get onboardingComplete => _prefs.getBool('onboarding.complete') ?? false;
  // Awaited so the flag is flushed before the app may be killed/restarted.
  Future<void> setOnboardingComplete(bool v) =>
      _prefs.setBool('onboarding.complete', v);

  // Wapp Store default catalog source — the URL (or local path) the
  // install wapp seeds into its `source` KV on first run, so a future
  // deployment can point the store at a different catalog without
  // rebuilding the wasm. Empty/null = fall back to the in-repo binaries
  // dir (dev checkout) or the wapp's built-in default
  // (https://geogram.radio/wapps).
  // The store's own Settings tab can still override this per-install.
  String? get wappStoreSource => _prefs.getString('wappStore.source');
  set wappStoreSource(String? v) {
    if (v == null || v.isEmpty) {
      _prefs.remove('wappStore.source');
    } else {
      _prefs.setString('wappStore.source', v);
    }
  }

  // Identity-backup passphrase. Empty (default) means the survives-uninstall
  // identity backup is written in plaintext; non-empty means it is AES-encrypted
  // with this passphrase. Stored app-private (wiped on uninstall) so auto-backup
  // can encrypt silently; the user must re-enter it to restore on a fresh install.
  String get identityBackupPassphrase =>
      _prefs.getString('identityBackup.passphrase') ?? '';
  set identityBackupPassphrase(String v) {
    if (v.isEmpty) {
      _prefs.remove('identityBackup.passphrase');
    } else {
      _prefs.setString('identityBackup.passphrase', v);
    }
  }

  // Wapp data directory — root folder for per-wapp user data
  String? get wappDataDir => _prefs.getString('wapp.dataDir');
  set wappDataDir(String? v) {
    if (v == null) {
      _prefs.remove('wapp.dataDir');
    } else {
      _prefs.setString('wapp.dataDir', v);
    }
  }

  // Widget provider preferences — when multiple wapps advertise the
  // same widgetId, this tells the [WidgetBroker] which provider to
  // prefer. Stored as one entry per widgetId keyed
  // `widget.provider.<widget-id>`. `null` means "no preference —
  // pick the first registered provider".
  String? getPreferredProvider(String widgetId) =>
      _prefs.getString('widget.provider.$widgetId');

  void setPreferredProvider(String widgetId, String? providerWappId) {
    final key = 'widget.provider.$widgetId';
    if (providerWappId == null || providerWappId.isEmpty) {
      _prefs.remove(key);
    } else {
      _prefs.setString(key, providerWappId);
    }
  }

  // ── Locale preference ────────────────────────────────────────────
  //
  // The active UI locale controls how wapps resolve their `@key`
  // translation sentinels. An empty / null value means "follow the
  // OS" — [activeLocale] returns [Platform.localeName] in that case
  // so callers don't have to special-case it.
  //
  // Stored as a short tag like `pt_PT`, `en_US`, `de_DE`, `pt`, `en`.
  // Resolving a wapp's language file tries the full tag, then the
  // language-only prefix, then `en`, then the literal source string.

  /// The raw preference value. Null means "auto" (follow the OS).
  String? get localePreference => _prefs.getString('locale');
  set localePreference(String? v) {
    if (v == null || v.isEmpty) {
      _prefs.remove('locale');
    } else {
      _prefs.setString('locale', v);
    }
  }

  /// The effective active locale. Returns the stored preference
  /// when set, otherwise the OS locale (via the platform abstraction),
  /// with a final fallback to `en` so the rest of the app never
  /// sees an empty string.
  String activeLocale() {
    final stored = localePreference;
    if (stored != null && stored.isNotEmpty) return stored;
    return platform.currentLocale();
  }

  /// Language-only portion of [activeLocale] — `pt_PT` → `pt`,
  /// `pt` → `pt`. Used by the fallback chain so a wapp that only
  /// ships `lang/pt.json` still matches `pt_BR` users.
  String activeLanguageCode() {
    final full = activeLocale();
    final sep = full.contains('_')
        ? full.indexOf('_')
        : full.contains('-')
            ? full.indexOf('-')
            : -1;
    return sep < 0 ? full.toLowerCase() : full.substring(0, sep).toLowerCase();
  }

  // ── Reticulum (RNS) auto-start ───────────────────────────────────
  //
  // The node is always-on by default: it auto-starts at boot and stays
  // running so folder sharing/discovery and file transfer work without a
  // manual step. The bootstrap is a public Reticulum testnet TCP hub the
  // device connects to as a client; override host/port to point at your own.
  bool get rnsAutoStart => _prefs.getBool('rns.autoStart') ?? true;
  set rnsAutoStart(bool v) => _prefs.setBool('rns.autoStart', v);

  String get rnsBootstrapHost =>
      _prefs.getString('rns.bootstrapHost') ?? 'rns.beleth.net';
  set rnsBootstrapHost(String v) => _prefs.setString('rns.bootstrapHost', v);

  int get rnsBootstrapPort => _prefs.getInt('rns.bootstrapPort') ?? 4242;
  set rnsBootstrapPort(int v) => _prefs.setInt('rns.bootstrapPort', v);

  /// Auto-download referenced media (images) up to this many MB; larger files
  /// show a size + "tap to download" instead. 0 = always require a tap.
  int get mediaAutoMaxMb => _prefs.getInt('media.autoMaxMb') ?? 10;
  set mediaAutoMaxMb(int v) => _prefs.setInt('media.autoMaxMb', v < 0 ? 0 : v);

  /// Editable, ordered list of Reticulum TCP bootstrap hubs ("host:port"). The
  /// node tries each in turn until one answers with real Reticulum traffic. The
  /// defaults are public testnet hubs; users can edit the list in Settings.
  // Verified-reachable community TCP hubs (TCPClientInterface, port 4242). The
  // old *.connect.reticulum.network testnet is decommissioned (NXDOMAIN) and
  // betweentheborders is a web server, so they're intentionally excluded.
  static const List<String> _defaultRnsServers = [
    'rns.beleth.net:4242',
    'use.inertia.chat:4242',
    'rns.wisco.network:4242',
    'sydney.reticulum.au:4242',
    'rns.birdsnet.com.br:4242',
  ];

  List<String> get rnsBootstrapServers {
    final v = _prefs.getStringList('rns.bootstrapServers');
    if (v == null || v.isEmpty) return List<String>.from(_defaultRnsServers);
    return v;
  }

  set rnsBootstrapServers(List<String> v) {
    final cleaned = [
      for (final s in v)
        if (s.trim().isNotEmpty) s.trim()
    ];
    _prefs.setStringList('rns.bootstrapServers', cleaned);
  }
}
