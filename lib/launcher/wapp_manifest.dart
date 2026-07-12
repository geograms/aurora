part of 'launcher.dart';

// ── Wapp manifest model ──────────────────────────────────────────────

class WappManifest {
  final String id;

  /// On-disk folder name (last path segment of [dirPath]). Slug-only,
  /// no spaces — used as the key into `installedAppsStorage()` and
  /// `wappDataStorageFor()`.
  final String name;

  /// Short launcher label (1–3 words). Read from `manifest.title`.
  /// Falls back to `manifest.description` for legacy wapps that
  /// predate the explicit `title` field, then to the folder name.
  final String title;

  /// One-line explanation. Read from `manifest.description` (current
  /// schema). For legacy wapps — where `description` actually held the
  /// title — this is empty so the long text lives in [summary].
  final String description;

  /// Paragraph-long explanation. Read from `manifest.summary`.
  final String summary;

  final String kind;
  final String? icon;

  /// Optional launcher tile colour from `manifest.color` (a hex string like
  /// "#B71C1C" / "0xFFB71C1C" / "B71C1C"). Null → auto-pick from the id hash.
  final String? colorHex;
  final String dirPath;

  /// Publisher npub extracted from this wapp's `signature.json`
  /// sidecar (if any). Empty means the wapp is unsigned. Populated
  /// during launcher scan via [WappSigningService.readPublisherNpub].
  final String publisherNpub;

  /// Functionality IDs this wapp provides. Populated from
  /// `provides.functionalities` in the manifest — accepts both bare
  /// strings (`"text.greet"`) and rich objects with API detail.
  final List<String> providedFunctionalities;

  /// Rich API definitions parsed from manifest objects. Empty when
  /// the manifest uses bare string declarations.
  final List<FunctionalityDef> functionalityDefs;

  /// Functionality IDs this wapp needs another wapp to provide. From
  /// `requires.functionalities`. Used by [DependencyResolver] to gate
  /// launch and prompt the user to install a provider when missing.
  final List<String> requiredFunctionalities;

  /// Library wapp IDs this wapp calls via `hal_lib_call`. From
  /// `requires.libraries`.
  final List<String> requiredLibraries;

  /// HAL capability tags this wapp needs from the runtime itself
  /// (e.g. `process`, `file`, `http`). From `requires.hal`.
  final List<String> requiredHal;

  /// Event topics this wapp wants pre-subscribed at init. From
  /// `requires.events`.
  final List<String> requiredEvents;

  /// File-type handlers this wapp declares under
  /// `provides.file_handlers`. Drives the "Open with…" picker via
  /// [WappFileAssociations].
  final List<WappFileHandler> fileHandlers;

  /// Host-launchable view intents declared under `provides.intents`.
  final List<String> providedIntents;

  /// OS platforms this wapp advertises support for (`manifest.platforms`)
  /// — linux/windows/macos/android/ios/web. Empty = unspecified (any).
  final List<String> supportedPlatforms;

  /// Hardware targets this wapp advertises (`manifest.hardware`) —
  /// intel/arm/esp32/N/A/… Empty = unspecified (any).
  final List<String> supportedHardware;

  /// Native per-platform binaries shipped INSIDE the wapp package, from
  /// `provides.native_binaries` — a map of `<platform>-<arch>` (e.g.
  /// "linux-x86_64", "windows-x86_64") to a wapp-relative path (e.g.
  /// "bin/ffmpeg-linux-x86_64"). Lets a wapp escape wasm's limits (no SIMD
  /// asm, no threads) with real binaries while the HOST stays codec-free;
  /// executing them is the same trust boundary as `hal_process_exec`.
  final Map<String, String> nativeBinaries;

  /// True when the user authored/edited this wapp via the App Creator
  /// (`manifest.user_modified`). The launcher badges these as customized.
  final bool userModified;

  WappManifest({
    required this.id,
    required this.name,
    required this.title,
    required this.description,
    this.summary = '',
    required this.kind,
    this.icon,
    this.colorHex,
    required this.dirPath,
    this.publisherNpub = '',
    this.providedFunctionalities = const [],
    this.functionalityDefs = const [],
    this.requiredFunctionalities = const [],
    this.requiredLibraries = const [],
    this.requiredHal = const [],
    this.requiredEvents = const [],
    this.fileHandlers = const [],
    this.providedIntents = const [],
    this.supportedPlatforms = const [],
    this.supportedHardware = const [],
    this.nativeBinaries = const {},
    this.userModified = false,
  });

  /// Whether this wapp advertises support for [host] (an OS name from
  /// `platform.platformName()`). An empty `platforms` list means the
  /// wapp made no claim, so we treat it as universally supported.
  bool supportsPlatform(String host) =>
      supportedPlatforms.isEmpty || supportedPlatforms.contains(host);

  factory WappManifest.fromJson(
    Map<String, dynamic> json,
    String dirPath, {
    String publisherNpub = '',
  }) {
    final id = json['id'] as String? ?? '';
    final folderName = dirPath.split(platform.pathSeparator).last;

    // Field semantics (current schema, as used by the mature wapps):
    //   title       — short launcher label  ("Maps")
    //   description — one-line explanation   ("Satellite maps with…")
    //   summary     — paragraph-long text
    // Legacy schema (older wapps, no explicit title): `description`
    // WAS the title and `summary` the long text. Detect legacy by the
    // absence of a non-empty `title` so old wapps still show a sensible
    // label instead of dumping their one-liner onto the tile.
    final hasTitle =
        json['title'] is String && (json['title'] as String).trim().isNotEmpty;
    final manifestTitle = hasTitle
        ? (json['title'] as String).trim()
        : (json['description'] as String? ?? '');
    final manifestDescription = hasTitle
        ? (json['description'] as String? ?? '')
        : '';
    final manifestSummary = json['summary'] as String? ?? '';

    // Parse provides.functionalities — accepts both bare strings
    // ("text.greet") and rich objects with endpoint detail. Bare
    // strings go into providedFunctionalities; objects go into both
    // providedFunctionalities (by id) and functionalityDefs.
    final provides = json['provides'];
    final funcList = provides is Map<String, dynamic>
        ? (provides['functionalities'] ?? provides['widgets'])
        : null;
    final funcIds = <String>[];
    final funcDefs = <FunctionalityDef>[];
    if (funcList is List) {
      for (final entry in funcList) {
        if (entry is String) {
          funcIds.add(entry);
        } else if (entry is Map<String, dynamic>) {
          final def = FunctionalityDef.fromJson(entry);
          if (def.id.isNotEmpty) {
            funcIds.add(def.id);
            funcDefs.add(def);
          }
        }
      }
    }

    // Parse provides.file_handlers → WappFileHandler list. Drives the
    // "Open with…" picker. Bare/malformed entries are skipped.
    final handlerList = provides is Map<String, dynamic>
        ? provides['file_handlers']
        : null;
    final fileHandlers = <WappFileHandler>[];
    if (handlerList is List) {
      for (final e in handlerList) {
        if (e is Map<String, dynamic>) {
          fileHandlers.add(WappFileHandler.fromJson(e));
        }
      }
    }

    final intentList = provides is Map<String, dynamic>
        ? provides['intents']
        : null;
    final providedIntents = intentList is List
        ? intentList
              .whereType<String>()
              .map((s) => s.trim().toLowerCase())
              .where((s) => s.isNotEmpty)
              .toList()
        : const <String>[];

    // Parse requires.* — each is a plain list of string IDs/tags. A
    // missing or malformed section yields an empty list so a wapp with
    // no declared dependencies simply has nothing to gate on.
    final requires = json['requires'];
    List<String> reqList(String key) {
      if (requires is! Map<String, dynamic>) return const [];
      final raw = requires[key];
      if (raw is! List) return const [];
      return raw.whereType<String>().where((s) => s.isNotEmpty).toList();
    }

    // Top-level platform / hardware advertisement.
    List<String> topList(String key) {
      final raw = json[key];
      if (raw is! List) return const [];
      return raw
          .whereType<String>()
          .map((s) => s.toLowerCase())
          .where((s) => s.isNotEmpty)
          .toList();
    }

    return WappManifest(
      id: id,
      name: folderName.isNotEmpty ? folderName : id.split('.').last,
      title: manifestTitle.isNotEmpty ? manifestTitle : folderName,
      description: manifestDescription,
      summary: manifestSummary,
      kind: json['kind'] as String? ?? 'app',
      icon: json['icon'] as String?,
      colorHex: json['color'] as String?,
      dirPath: dirPath,
      publisherNpub: publisherNpub,
      providedFunctionalities: funcIds,
      functionalityDefs: funcDefs,
      requiredFunctionalities: reqList('functionalities'),
      requiredLibraries: reqList('libraries'),
      requiredHal: reqList('hal'),
      requiredEvents: reqList('events'),
      fileHandlers: fileHandlers,
      providedIntents: providedIntents,
      supportedPlatforms: topList('platforms'),
      supportedHardware: topList('hardware'),
      nativeBinaries: () {
        final raw = provides is Map<String, dynamic>
            ? provides['native_binaries']
            : null;
        if (raw is! Map) return const <String, String>{};
        return {
          for (final e in raw.entries)
            if (e.value is String && (e.value as String).isNotEmpty)
              e.key.toString().toLowerCase(): e.value as String,
        };
      }(),
      userModified: json['user_modified'] == true,
    );
  }

  /// Map wapp IDs to Material icons. Delegates to the shared
  /// [wappIconFor] so the launcher grid and the wapp Store use the
  /// same visual identity for any given wapp.
  IconData get iconData => wappIconFor('$id $name');

  /// Extract a short text label from `manifest.icon` if one is set.
  /// Path-shaped values (`media/icons/foo.svg`) return null so the
  /// caller falls through to [svgIconPath] instead. Returns up to
  /// the first two grapheme-ish chars so an emoji ZWJ sequence
  /// doesn't get truncated mid-sequence.
  String? get textIcon {
    final raw = icon;
    if (raw == null || raw.isEmpty) return null;
    if (raw.contains('/') || raw.contains('\\')) return null;
    return raw.characters.take(2).toString();
  }

  /// Absolute path to an SVG icon sidecar if one is referenced by
  /// `manifest.icon`. Null when the manifest points elsewhere or
  /// isn't path-shaped at all. The launcher uses this to decide
  /// whether to render the SVG instead of falling back to
  /// [iconData].
  String? get svgIconPath {
    final raw = icon;
    if (raw == null || raw.isEmpty) return null;
    if (!raw.toLowerCase().endsWith('.svg')) return null;
    if (!raw.contains('/') && !raw.contains('\\')) return null;
    return '$dirPath${platform.pathSeparator}$raw';
  }

  /// Launcher tile colour: an explicit `manifest.color` if given, else picked
  /// deterministically from the id hash.
  Color get color {
    final override = _parseHexColor(colorHex);
    if (override != null) return override;
    final colors = [
      const Color(0xFF0F3460),
      const Color(0xFF533483),
      const Color(0xFF1A5276),
      const Color(0xFF6C3483),
      const Color(0xFF1E8449),
      const Color(0xFFB9770E),
      const Color(0xFF943126),
      const Color(0xFF2E4053),
    ];
    return colors[id.hashCode.abs() % colors.length];
  }

  /// Parse a manifest colour string ("#RRGGBB", "RRGGBB", "0xAARRGGBB" or
  /// "AARRGGBB") into a [Color], or null if absent/malformed. 6-digit values are
  /// assumed fully opaque.
  static Color? _parseHexColor(String? raw) {
    if (raw == null) return null;
    var s = raw.trim().replaceAll('#', '');
    if (s.toLowerCase().startsWith('0x')) s = s.substring(2);
    if (s.length == 6) s = 'ff$s';
    if (s.length != 8) return null;
    final v = int.tryParse(s, radix: 16);
    return v == null ? null : Color(v);
  }
}
