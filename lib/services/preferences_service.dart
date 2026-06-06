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

  // Per-wapp autostart: when on, the wapp runs as a background service
  // (started at boot) and keeps its engine ticking even while its UI page is
  // closed — e.g. APRS staying connected to BLE/APRS-IS to receive messages.
  bool getWappAutostart(String wappId) =>
      _prefs.getBool('wapp.autostart.$wappId') ?? false;
  Future<void> setWappAutostart(String wappId, bool v) =>
      _prefs.setBool('wapp.autostart.$wappId', v);

  /// Ids of all wapps the user enabled for autostart.
  List<String> autostartWappIds() {
    const prefix = 'wapp.autostart.';
    return _prefs
        .getKeys()
        .where((k) => k.startsWith(prefix) && (_prefs.getBool(k) ?? false))
        .map((k) => k.substring(prefix.length))
        .toList();
  }

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
}
