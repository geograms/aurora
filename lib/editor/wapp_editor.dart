// Single-wapp editor (App Creator) UI, extracted from wapp_page.dart.
// These are methods on _WappPageState (via an extension) plus the
// editor-only data classes; behaviour is identical to when they lived
// inline. Part of the wapp_page library so they keep full access to
// the State's private fields and helpers.

part of '../wapp/wapp_page.dart';

/// Mode flag for App Creator's UI editor screen — either the raw
/// JSON in a code field, or a click-to-edit block tree. See
/// [_WappPageState._buildUiEditorScreen] for the consumer.
enum _UiEditorMode { visual, code }

/// Discriminates between a palette insert and a canvas-to-canvas
/// move when a drop lands on a drop zone.
enum _UiDragKind { palette, move }

/// Palette entry describing one draggable block type shown on the
/// left side of the WYSIWYG editor. The template map is deep-cloned
/// at drop time so every insertion gets its own copy.
class _UiPaletteEntry {
  final String label;
  final String? subLabel;
  final IconData icon;
  final Map<String, dynamic> template;

  const _UiPaletteEntry({
    required this.label,
    this.subLabel,
    required this.icon,
    required this.template,
  });
}

/// Payload carried by a [Draggable] inside the WYSIWYG editor.
/// `kind == palette` means "insert this template"; `kind == move`
/// means "relocate the block currently at movePath".
class _UiDragPayload {
  final _UiDragKind kind;
  final Map<String, dynamic>? payload;
  final List<int>? movePath;

  const _UiDragPayload._(this.kind, this.payload, this.movePath);

  factory _UiDragPayload.fromPalette(Map<String, dynamic> template) =>
      _UiDragPayload._(_UiDragKind.palette, template, null);

  factory _UiDragPayload.fromMove(List<int> path) =>
      _UiDragPayload._(_UiDragKind.move, null, List<int>.from(path));
}

/// One row rendered by the App Creator Projects tab. Immutable —
/// refresh replaces the list rather than mutating entries.
/// One row in the single-wapp editor's file list (label + the
/// `_fieldValues` key holding its content + highlight language).
class _EditFile {
  final String label;
  final String field;
  final String language;
  final IconData icon;
  const _EditFile({
    required this.label,
    required this.field,
    required this.language,
    required this.icon,
  });
}

class _ProjectEntry {
  /// Folder slug (on-disk directory name under apps/ or
  /// wapps/). Used as the install target.
  final String folder;

  /// `manifest.id` — used for dedup between user installs and
  /// built-in source-tree copies.
  final String id;

  /// Short human-readable title pulled from `manifest.description`.
  final String title;

  /// Long form from `manifest.summary`.
  final String description;

  /// Absolute path to the wapp's package directory. For user
  /// installs that's `~/.local/share/aurora/devices/<id>/apps/<folder>/`;
  /// for built-ins it's `<cwd>/wapps/<folder>/` (or an ancestor).
  /// `_loadProject` reads manifest + home.ui.json + app.wasm from
  /// here.
  final String dirPath;

  /// True when the wapp lives in the source tree under
  /// `wapps/` rather than in `installedAppsStorage()`. The
  /// Projects tab hides the Delete button on pristine built-ins and
  /// flags them with a visual badge.
  final bool isBuiltIn;

  const _ProjectEntry({
    required this.folder,
    required this.id,
    required this.title,
    required this.description,
    required this.dirPath,
    required this.isBuiltIn,
  });
}

extension _WappEditor on _WappPageState {
  /// App Creator compile pipeline. Called from `_drainOutbox` when
  /// the wapp emits a `{"type":"compile","source":"..."}` message.
  /// Runs the current compiler backend and caches the result in the
  /// wapp's work folder under `last_compiled.wasm`.
  Future<void> _handleCompile(Map<String, dynamic> data) async {
    final wappData = _wappData;
    if (wappData == null) {
      _logLine('(compile) internal error: wapp data storage not ready');
      return;
    }
    final source = data['source'] as String? ?? '';
    if (source.isEmpty) {
      _logLine('(compile) empty source — nothing to build');
      return;
    }

    _logLine('── compile started (${source.length} chars) ──');
    final result = await WappCompilerService.instance.compile(
      source: source,
      pkg: _pkg,
      workStorage: wappData,
    );

    if (result.stdout.isNotEmpty) _logMultiline(result.stdout);
    if (result.stderr.isNotEmpty) _logMultiline(result.stderr);

    if (!result.ok) {
      _logLine('compile failed: ${result.error}');
      NotificationService.instance.show(GeogramNotification(
        level: NotificationLevel.error,
        title: 'Compile failed',
        body: result.error ?? 'see log view for details',
        source: 'host:app-creator',
      ));
      return;
    }

    final bytes = result.wasmBytes!;
    await wappData.writeBytes('last_compiled.wasm', bytes);
    // A fresh compile supersedes any bytes loaded from disk.
    _loadedWasmBytes = null;
    _logLine(
        'compile ok: ${bytes.length} bytes in ${result.durationMs}ms');
    NotificationService.instance.show(GeogramNotification(
      level: NotificationLevel.success,
      title: 'Compile succeeded',
      body:
          '${bytes.length} bytes, ${result.durationMs}ms via ${WappCompilerService.instance.backend.name}',
      source: 'host:app-creator',
    ));
  }

  /// App Creator install pipeline. Called from `_drainOutbox` when
  /// the wapp emits a `{"type":"install","id":...,"title":...,
  /// "name":...,"description":...,"source_ui":...}` message.
  ///
  /// Two modes:
  ///
  /// 1. **Fresh compile**: `last_compiled.wasm` exists in the wapp
  ///    work folder. The installer writes a new wapp with those
  ///    bytes, then the cache is deleted so the next install reverts
  ///    to edit-in-place unless the user recompiles.
  /// 2. **Edit in place**: no `last_compiled.wasm`. The installer
  ///    reuses whatever `app.wasm` is already at `apps/<folderName>/`
  ///    — this is the "change title, change UI, keep the wasm" path.
  ///    Fails cleanly if neither a fresh compile nor an existing
  ///    install is available.
  Future<void> _handleInstall(Map<String, dynamic> data) async {
    final wappData = _wappData;
    if (wappData == null) {
      _logLine('(install) internal error: wapp data storage not ready');
      return;
    }
    final id = data['id'] as String? ?? '';
    final title = data['title'] as String? ?? '';
    final folderName = data['name'] as String? ?? '';
    final description = data['description'] as String? ?? '';
    final sourceUi = data['source_ui'] as String? ?? '';
    if (id.isEmpty) {
      _logLine('(install) empty id — fill the Settings tab first');
      return;
    }
    if (folderName.isEmpty) {
      _logLine('(install) empty name — fill the Settings tab first');
      return;
    }

    // Pick the wasm bytes to install. Priority order:
    //  1. A fresh compile (last_compiled.wasm written by _handleCompile)
    //  2. Bytes loaded by _loadProject when the user picked a project
    //     from the Projects tab (this is the "fork a built-in" path)
    //  3. Existing installed-apps app.wasm (pure metadata / UI edit
    //     on an already-installed user wapp)
    //  4. Nothing — installer returns a clean error.
    Uint8List? freshBytes = await wappData.readBytes('last_compiled.wasm');
    String mode;
    if (freshBytes != null && freshBytes.isNotEmpty) {
      mode = 'fresh compile';
    } else if (_loadedWasmBytes != null && _loadedWasmBytes!.isNotEmpty) {
      freshBytes = _loadedWasmBytes;
      mode = 'loaded wasm (forking into user install)';
    } else {
      mode = 'edit in place';
    }
    _logLine('── install started: $id ($mode) ──');

    // Preserve the C source alongside the binary so a subsequent
    // Edit → load can populate the Code tab with the original text.
    // For edit-in-place installs that never touched the source, the
    // installer carries the existing main.c forward automatically.
    final sourceC = (_fieldValues['source'] as String?) ?? '';
    final icon = (_fieldValues['wapp_icon'] as String?) ?? '';
    // Translations come from the App Creator Translations tab as a
    // `Map<String, Map<String, String>>` (locale → key → value).
    // Pass null when empty so the installer's edit-in-place path
    // doesn't strip a previously-written lang/ dir.
    final translationsRaw = _fieldValues['translations'];
    final translations = _coerceTranslations(translationsRaw);

    final version =
        (_fieldValues['wapp_version'] as String?) ?? '1.0.0';
    final tickInterval =
        int.tryParse((_fieldValues['wapp_tick_interval'] as String?) ?? '') ??
            5000;
    final halRaw = _fieldValues['wapp_hal_requires'];
    final halRequires = halRaw is List<String>
        ? halRaw
        : _WappPageState._splitCsv(halRaw is String ? halRaw : 'log');
    final provRaw = _fieldValues['wapp_provides_functionalities'];
    final providesWidgets = provRaw is List<String>
        ? provRaw
        : _WappPageState._splitCsv(provRaw is String ? provRaw : '');

    final result = await WappInstallerService.instance.installFromCompiled(
      id: id,
      title: title,
      folderName: folderName,
      description: description,
      version: version,
      kind: (_fieldValues['wapp_kind'] as String?) ?? 'app',
      tickIntervalMs: tickInterval,
      halRequires: halRequires,
      providesWidgets: providesWidgets,
      wasmBytes: freshBytes,
      homeScreenJson: sourceUi.isEmpty ? null : sourceUi,
      sourceC: sourceC.isEmpty ? null : sourceC,
      icon: icon.isEmpty ? null : icon,
      translations: translations,
      overwrite: true,
      // Installing from the App Creator means the user authored/edited
      // this wapp — mark it so the launcher badges it as customized.
      userModified: true,
    );
    if (!result.ok) {
      _logLine('install failed: ${result.error}');
      NotificationService.instance.show(GeogramNotification(
        level: NotificationLevel.error,
        title: 'Install failed',
        body: result.error ?? 'see log view',
        source: 'host:app-creator',
      ));
      return;
    }

    // Consume the fresh compile cache so a subsequent install
    // without a recompile takes the edit-in-place path.
    try {
      await wappData.delete('last_compiled.wasm');
    } catch (_) {}
    // And drop any bytes loaded from a Projects-tab pick — the
    // installer has written them out; further installs should read
    // from the (now-existing) installedAppsStorage copy.
    _loadedWasmBytes = null;

    _logLine('install ok: $id');
    NotificationService.instance.show(GeogramNotification(
      level: NotificationLevel.success,
      title: 'Installed',
      body: (title.isNotEmpty ? title : folderName) +
          ' — back to the launcher to see it on the grid.',
      source: 'host:app-creator',
    ));
    // Refresh the Projects tab so a freshly installed wapp shows up
    // immediately if the user switches back to it.
    unawaited(_refreshProjects());
  }

  /// Load a wapp into the App Creator editor — called from the
  /// Projects tab Edit button with a `_ProjectEntry` that tells us
  /// the dir path to read from (works for both user installs under
  /// `installedAppsStorage()` and built-ins under `wapps/`).
  ///
  /// Reads manifest + home.ui.json + app.wasm + main.c from the
  /// entry's dirPath. The wasm bytes land in [_loadedWasmBytes] so
  /// the subsequent install — even without a fresh compile — has
  /// bytes to write. For built-ins this effectively forks the
  /// source-tree wapp into `installedAppsStorage()` on the next
  /// install.
  ///
  /// Original C source is loaded when the wapp ships it. Built-in
  /// wapps always have `main.c` next to `app.wasm` in
  /// `wapps/<name>/`. User installs only have it when they
  /// were created by App Creator after the source-preservation
  /// change landed — older installs have no `main.c` and the Code
  /// tab stays empty with a log-line hint.
  Future<void> _loadProject(_ProjectEntry entry) async {
    final pkg = wappPackageStorage(entry.dirPath);
    final manifest = await pkg.readJson('manifest.json');
    if (manifest == null) {
      _logLine('(load) missing or invalid manifest.json at ${entry.dirPath}');
      NotificationService.instance.show(GeogramNotification(
        level: NotificationLevel.error,
        title: 'Load failed',
        body: 'manifest.json not found at ${entry.dirPath}',
        source: 'host:app-creator',
      ));
      return;
    }
    final id = manifest['id'] as String? ?? '';
    final title = manifest['description'] as String? ?? '';
    final description = manifest['summary'] as String? ?? '';
    // Normalise manifest.icon into the shape the IconField binding
    // expects (see widgets/icon_field.dart):
    //   - empty                → empty binding
    //   - short text / emoji   → binding verbatim
    //   - path to a .svg file  → read the file and prefix with
    //                            `svg:` so the editor shows a
    //                            preview and a subsequent Install
    //                            round-trips the bytes cleanly
    //   - any other path       → skip (we can't render non-svg
    //                            image formats yet)
    final rawIcon = manifest['icon'] as String? ?? '';
    String iconForField = '';
    if (rawIcon.isNotEmpty) {
      if (rawIcon.endsWith('.svg') &&
          (rawIcon.contains('/') || rawIcon.contains('\\'))) {
        final svgContent = await pkg.readString(rawIcon) ?? '';
        if (svgContent.isNotEmpty) {
          iconForField = 'svg:$svgContent';
        }
      } else if (!rawIcon.contains('/') && !rawIcon.contains('\\')) {
        iconForField = rawIcon;
      }
    }
    final uiJson =
        await pkg.readString('screens/home.ui.json') ?? '';
    final wasm = await pkg.readBytes('app.wasm');
    final sourceC = await pkg.readString('main.c') ?? '';

    // Load every lang/*.json sidecar so the Translations tab opens
    // pre-populated. Keys are locale codes (without extension),
    // values are flat string→string maps.
    final translations = <String, Map<String, String>>{};
    if (await pkg.directoryExists('lang')) {
      final langEntries = await pkg.listDirectory('lang');
      for (final langEntry in langEntries) {
        if (langEntry.isDirectory) continue;
        final path = langEntry.path;
        if (!path.endsWith('.json')) continue;
        final base = path.split('/').last;
        final code = base.substring(0, base.length - 5);
        final asJson = await pkg.readJson('lang/$base');
        if (asJson == null) continue;
        final inner = <String, String>{};
        for (final e in asJson.entries) {
          if (e.value is String) inner[e.key] = e.value as String;
        }
        translations[code] = inner;
      }
    }

    // Mutate the bindings map in place. A subsequent setState lets
    // CodeEditorField / TextField widgets pick up the new values
    // via their didUpdateWidget paths.
    _fieldValues['wapp_title'] = title;
    _fieldValues['wapp_id'] = id;
    _fieldValues['wapp_description'] = description;
    _fieldValues['wapp_name'] = entry.folder;
    _fieldValues['wapp_icon'] = iconForField;
    _fieldValues['wapp_version'] =
        (manifest['version'] as String?) ?? '1.0.0';
    _fieldValues['wapp_kind'] =
        (manifest['kind'] as String?) ?? 'app';
    final tickVal = '${manifest['tick_interval_ms'] ?? 5000}';
    _fieldValues['wapp_tick_interval'] = tickVal;
    _tickIntervalController.text = tickVal;
    // HAL requires — stored as List<String> for the chip picker.
    final halList = manifest['requires']?['hal'];
    _fieldValues['wapp_hal_requires'] = halList is List
        ? halList.cast<String>().toList()
        : <String>['log'];
    // Provides functionalities — stored as List<String> for the chip editor.
    final providesFns = manifest['provides']?['functionalities']
        ?? manifest['provides']?['widgets']
        ?? manifest['provides']?['functions'];
    _fieldValues['wapp_provides_functionalities'] = providesFns is List
        ? providesFns.cast<String>().toList()
        : <String>[];
    _fieldValues['source_ui'] = uiJson;
    _fieldValues['source'] = sourceC;
    _fieldValues['translations'] = translations;
    // Lock the Code tab when the loaded wapp didn't ship main.c.
    // User can still start fresh via the "Create new wapp" button.
    _fieldValues['source__readonly'] = sourceC.isEmpty;
    _loadedWasmBytes = wasm;

    _logLine('loaded ${entry.folder}: id=$id, '
        'title=${title.isEmpty ? '(empty)' : title}, '
        'ui=${uiJson.length} chars, '
        'source=${sourceC.isEmpty ? '(missing)' : '${sourceC.length} chars'}, '
        'wasm=${wasm?.length ?? 0} bytes'
        '${entry.isBuiltIn ? ' (built-in)' : ''}');
    if (sourceC.isEmpty) {
      _logLine('(no main.c shipped with this wapp — Code tab will be '
          'empty; Compile will rebuild from whatever you type in)');
    }
    NotificationService.instance.show(GeogramNotification(
      level: NotificationLevel.success,
      title: 'Loaded ${entry.folder}',
      body: entry.isBuiltIn
          ? 'Built-in wapp — installing will create a user fork at apps/${entry.folder}.'
          : (title.isNotEmpty ? title : '(no title in manifest)'),
      source: 'host:app-creator',
    ));
    if (mounted) setState(() {});
  }

  /// Clear the identity / source / source_ui fields from the
  /// bindings and re-run `_seedFieldDefaults` on every screen so the
  /// editor snaps back to its default new-wapp state. Called from
  /// `_showProjectPicker` when the user picks "Create new wapp".
  /// Log buffers (`output`) are intentionally preserved.
  void _resetToNewProject() {
    const keysToReset = {
      'wapp_title',
      'wapp_name',
      'wapp_id',
      'wapp_description',
      'wapp_icon',
      'wapp_version',
      'wapp_kind',
      'wapp_tick_interval',
      'wapp_hal_requires',
      'wapp_provides_functionalities',
      'source',
      'source_ui',
      'source__readonly',
      'translations',
    };
    for (final key in keysToReset) {
      _fieldValues.remove(key);
    }
    for (final screen in _screens) {
      _seedFieldDefaults(screen);
    }
    // Any `*__readonly` flag the previously-loaded project might
    // have set is gone; the Code tab is editable again.
    _fieldValues['source__readonly'] = false;
    _tickIntervalController.text = '5000';
    _logLine('── new project — fields reset to defaults ──');
    NotificationService.instance.show(GeogramNotification(
      level: NotificationLevel.info,
      title: 'New wapp',
      body: 'Fields reset. Edit Settings, then Compile + Install.',
      source: 'host:app-creator',
    ));
    if (mounted) setState(() {});
  }

  /// Scan both `installedAppsStorage()` and the source-tree
  /// `wapps/` path for installed wapps. Dedup by
  /// `manifest.id` — user installs take precedence over built-ins
  /// with the same id so that an edited fork hides the original.
  /// Sort: user installs first, then built-ins, alphabetical by
  /// folder within each group.
  Future<void> _refreshProjects() async {
    if (_projectsLoading) return;
    if (mounted) setState(() => _projectsLoading = true);

    final userEntries = <_ProjectEntry>[];
    final builtInEntries = <_ProjectEntry>[];
    final seenIds = <String>{};

    // --- User installs first (they win dedup) ---
    final installed = installedAppsStorage();
    if (await installed.directoryExists('')) {
      final entries = await installed.listDirectory('');
      for (final entry in entries) {
        if (!entry.isDirectory) continue;
        final manifest =
            await installed.readJson('${entry.name}/manifest.json');
        if (manifest == null) continue;
        final id = manifest['id'] as String? ?? '';
        if (id.isNotEmpty) seenIds.add(id);
        userEntries.add(_ProjectEntry(
          folder: entry.name,
          id: id,
          title: (manifest['description'] as String?) ?? '',
          description: (manifest['summary'] as String?) ?? '',
          dirPath: installed.getAbsolutePath(entry.name),
          isBuiltIn: false,
        ));
      }
    }

    // --- Then built-ins, skipping ids already in user installs ---
    // Same candidate paths as main.dart _scanArchiveBody. On web
    // `platform.currentDirectory()` returns an empty string, so
    // neither candidate resolves and the archive scan is a no-op
    // (web built-ins come from the fetch-based loader instead).
    final cwd = platform.currentDirectory();
    final archiveCandidates = [
      '$cwd/../wapps',
      '$cwd/../../wapps',
    ];
    for (final archivePath in archiveCandidates) {
      final archive = wappPackageStorage(archivePath);
      if (!await archive.directoryExists('')) continue;
      final entries = await archive.listDirectory('');
      for (final entry in entries) {
        if (!entry.isDirectory) continue;
        final pkgDir = archive.getAbsolutePath(entry.name);
        final pkg = wappPackageStorage(pkgDir);
        final manifest = await pkg.readJson('manifest.json');
        if (manifest == null) continue;
        final id = manifest['id'] as String? ?? '';
        if (id.isNotEmpty && seenIds.contains(id)) continue;
        if (id.isNotEmpty) seenIds.add(id);
        builtInEntries.add(_ProjectEntry(
          folder: entry.name,
          id: id,
          title: (manifest['description'] as String?) ?? '',
          description: (manifest['summary'] as String?) ?? '',
          dirPath: pkgDir,
          isBuiltIn: true,
        ));
      }
      break; // first archive dir that exists wins
    }

    userEntries.sort((a, b) => a.folder.compareTo(b.folder));
    builtInEntries.sort((a, b) => a.folder.compareTo(b.folder));
    final list = <_ProjectEntry>[...userEntries, ...builtInEntries];

    if (!mounted) return;
    setState(() {
      _projects = list;
      _projectsLoading = false;
    });
  }

  /// Enter App Creator editor mode — reveals the Code/UI/Settings
  /// tabs. Called after the user picks a project or hits "Create new
  /// wapp" on the Projects panel. Lazily builds the editor tab
  /// controller so repeat entries keep the same instance (and its
  /// animation state) across a single wapp session.
  void _enterEditorMode() {
    _editorTabController ??= TabController(
      length: _editorTabCount,
      vsync: this,
      initialIndex: 0,
    );
    // Always land on the Code tab on (re-)entry.
    _editorTabController!.index = 0;
    if (mounted) setState(() => _editorMode = true);
  }

  /// Exit App Creator editor mode — returns to the Projects panel. The
  /// back arrow on the editor scaffold calls this. When the page was
  /// opened to edit a single wapp (the per-wapp "Edit" menu), there is
  /// no Projects panel to return to, so leave the page entirely.
  void _exitEditorMode() {
    if (_singleTargetEdit) {
      if (mounted) Navigator.of(context).maybePop();
      return;
    }
    if (mounted) setState(() => _editorMode = false);
  }

  /// Auto-load the single wapp named by [WappPage.editWappDir] into the
  /// App Creator editor (skipping the Projects list). Called once at the
  /// end of [_loadWapp] when this page was opened via the per-wapp Edit
  /// menu.
  Future<void> _autoEditTarget() async {
    final dir = widget.editWappDir;
    if (dir == null) return;
    final pkg = wappPackageStorage(dir);
    final manifest = await pkg.readJson('manifest.json');
    if (manifest == null) {
      NotificationService.instance.show(GeogramNotification(
        level: NotificationLevel.error,
        title: 'Edit failed',
        body: 'manifest.json not found at $dir',
        source: 'host:app-creator',
      ));
      return;
    }
    final norm = dir.replaceAll('\\', '/').replaceAll(RegExp(r'/$'), '');
    final folder = norm.contains('/') ? norm.split('/').last : norm;
    final installedBase =
        installedAppsStorage().basePath.replaceAll('\\', '/');
    final entry = _ProjectEntry(
      folder: folder,
      id: manifest['id'] as String? ?? '',
      title: manifest['description'] as String? ?? '',
      description: manifest['summary'] as String? ?? '',
      dirPath: dir,
      isBuiltIn: !norm.startsWith(installedBase),
    );
    _singleTargetEdit = true;
    await _loadProject(entry);
    _enterEditorMode();
  }

  /// Open the App Creator focused on THIS wapp (the per-wapp "Edit"
  /// menu action). Resolves the installed app-creator package and pushes
  /// a new [WappPage] with [WappPage.editWappDir] set to this wapp's dir.
  Future<void> _editThisWapp() async {
    final appCreatorDir = editorWappDirPath();
    if (!await wappPackageStorage(appCreatorDir).exists('manifest.json')) {
      NotificationService.instance.show(GeogramNotification(
        level: NotificationLevel.error,
        title: 'Editor not available',
        body: 'The built-in wapp editor failed to install. Restart aurora.',
        source: 'host:launcher',
      ));
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WappPage(
          wappDir: appCreatorDir,
          title: 'App Creator',
          editWappDir: widget.wappDir,
        ),
      ),
    );
  }

  /// The subset of [_screens] shown inside the App Creator editor
  /// view (i.e. everything except Projects). Order is preserved from
  /// home.ui.json so the author controls the tab layout — which must
  /// be Code, UI, Translations, Settings.
  ///
  /// Filtering by the child group instead of the screen name is
  /// deliberate: after the i18n rework the name became an `@key`
  /// sentinel (e.g. `@screen.projects`) so a plain string compare
  /// against "projects" stopped matching. The projects list group is
  /// identified by its stable `name == "projects"` (its `$type` is
  /// "cards", so a type compare misses it — that was the leak).
  List<GeoUiBlock> get _editorScreens => _screens
      .where((s) => !s.children.any((c) =>
          c.keyword == 'group' &&
          (c.name == 'projects' || c.type == 'projects')))
      .toList();

  /// The tab labels shown for the editor, matched 1:1 to
  /// [_editorScreens]. Used only for the App Creator scaffold.
  List<String> get _editorScreenNames =>
      _editorScreens.map((s) => s.name ?? '').toList();

  /// Number of editor tabs surfaced for App Creator. Matches the
  /// length of [_editorScreens].
  int get _editorTabCount => _editorScreens.length;

  /// Build the App Creator Projects tab. First call kicks off the
  /// async scan; subsequent calls render the cached list.
  Widget _buildProjectsScreen() {
    if (_projects == null && !_projectsLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refreshProjects();
      });
    }

    final cs = Theme.of(context).colorScheme;
    final projects = _projects ?? const <_ProjectEntry>[];

    return Column(
      children: [
        // Header: Create new + refresh.
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: cs.outlineVariant.withAlpha(80)),
            ),
          ),
          child: Row(
            children: [
              FilledButton.icon(
                onPressed: () {
                  _resetToNewProject();
                  _enterEditorMode();
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Create new wapp'),
              ),
              const Spacer(),
              IconButton(
                onPressed: _projectsLoading ? null : _refreshProjects,
                icon: _projectsLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                tooltip: 'Refresh',
              ),
            ],
          ),
        ),
        Expanded(
          child: projects.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _projectsLoading
                          ? 'Scanning installed wapps…'
                          : 'No user-installed wapps yet.\n'
                              'Click "Create new wapp" to start one, or use '
                              'the Install wapp from the launcher to pull '
                              'one from a repository.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  itemCount: projects.length,
                  itemBuilder: (context, i) =>
                      _buildProjectCard(projects[i], cs),
                ),
        ),
      ],
    );
  }

  /// Resolve the actual icon for a project card — reads the wapp's
  /// manifest.icon, loads the SVG if present, falls back to Material.
  Widget _projectIcon(_ProjectEntry entry, ColorScheme cs) {
    final pkg = wappPackageStorage(entry.dirPath);
    final manifestBytes = pkg.readBytesSync('manifest.json');
    if (manifestBytes != null) {
      try {
        final manifest =
            jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
        final icon = manifest['icon'] as String?;
        if (icon != null &&
            icon.isNotEmpty &&
            icon.toLowerCase().endsWith('.svg') &&
            icon.contains('/')) {
          final svgBytes = pkg.readBytesSync(icon);
          if (svgBytes != null && svgBytes.isNotEmpty) {
            return SizedBox(
              width: 26,
              height: 26,
              child: SvgPicture.memory(
                svgBytes,
                fit: BoxFit.contain,
                theme: const SvgTheme(currentColor: Color(0xFF666666)),
              ),
            );
          }
        }
        // Text icon (emoji / char)
        if (icon != null &&
            icon.isNotEmpty &&
            !icon.contains('/') &&
            !icon.contains('\\')) {
          return SizedBox(
            width: 26,
            height: 26,
            child: FittedBox(
              child: Text(icon.characters.take(2).toString(),
                  style: const TextStyle(fontSize: 22)),
            ),
          );
        }
      } catch (_) {}
    }
    return Icon(
      wappIconFor(entry.id.isNotEmpty ? entry.id : entry.folder),
      color: cs.primary,
      size: 26,
    );
  }

  Widget _buildProjectCard(_ProjectEntry entry, ColorScheme cs) {
    final pathPrefix = entry.isBuiltIn ? 'wapps/' : 'apps/';
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
      ),
      color: cs.surfaceContainerLow,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () async {
          await _loadProject(entry);
          _enterEditorMode();
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _projectIcon(entry, cs),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            entry.title.isNotEmpty
                                ? entry.title
                                : entry.folder,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14),
                          ),
                        ),
                        if (entry.isBuiltIn) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: cs.secondaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'built-in',
                              style: TextStyle(
                                fontSize: 10,
                                color: cs.onSecondaryContainer,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$pathPrefix${entry.folder}',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                        fontFamily: 'monospace',
                      ),
                    ),
                    if (entry.id.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        entry.id,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (entry.description.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        entry.description,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      await _loadProject(entry);
                      _enterEditorMode();
                    },
                    icon: const Icon(Icons.edit, size: 16),
                    label: const Text('Edit'),
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                  ),
                  if (!entry.isBuiltIn)
                    TextButton.icon(
                      onPressed: () => _deleteProject(entry),
                      icon: Icon(Icons.delete_outline,
                          size: 16, color: cs.error),
                      label: Text('Delete',
                          style: TextStyle(color: cs.error)),
                      style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The file-list + full-height code editor split used by the editor's
  /// Code/Files tab (via [_buildScreen]'s split path). Uses Row +
  /// Expanded so it fills the available height and never overflows.
  Widget _filesEditorBody() {
    final cs = Theme.of(context).colorScheme;

    GeoUiBlock? settingsScreen;
    for (final s in _screens) {
      if ((s.name ?? '').toLowerCase() == 'settings') {
        settingsScreen = s;
        break;
      }
    }

    const files = <_EditFile>[
      _EditFile(label: 'main.c', field: 'source', language: 'c', icon: Icons.code),
      _EditFile(
          label: 'home.ui.json',
          field: 'source_ui',
          language: 'json',
          icon: Icons.web),
    ];

    Widget tile(IconData icon, String label, String key) {
      final selected = _activeEditFile == key;
      return ListTile(
        dense: true,
        selected: selected,
        selectedTileColor: cs.primary.withAlpha(28),
        leading: Icon(icon,
            size: 18, color: selected ? cs.primary : cs.onSurfaceVariant),
        title: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal)),
        onTap: () => setState(() => _activeEditFile = key),
      );
    }

    final left = SizedBox(
      width: 190,
      child: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text('FILES',
                style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.2,
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600)),
          ),
          for (final f in files) tile(f.icon, f.label, f.field),
          if (settingsScreen != null) ...[
            const Divider(height: 14),
            tile(Icons.tune, 'Settings', 'settings'),
          ],
        ],
      ),
    );

    Widget right;
    if (_activeEditFile == 'settings' && settingsScreen != null) {
      right = _buildSettingsScreen(settingsScreen);
    } else {
      final active = files.firstWhere((f) => f.field == _activeEditFile,
          orElse: () => files.first);
      final content = (_fieldValues[active.field] as String?) ?? '';
      final readOnly =
          active.field == 'source' && _fieldValues['source__readonly'] == true;
      right = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(active.icon, size: 16, color: cs.primary),
                const SizedBox(width: 8),
                Text(active.label,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                if (active.field == 'source' && !readOnly)
                  TextButton.icon(
                    onPressed: () => _handleCompile(
                        {'source': (_fieldValues['source'] as String?) ?? ''}),
                    icon: const Icon(Icons.build, size: 18),
                    label: const Text('Compile'),
                  ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _settingsSaveToDisk,
                  icon: const Icon(Icons.save, size: 18),
                  label: const Text('Save'),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: CodeEditorField(
                key: ValueKey('editfile-${active.field}'),
                fieldName: active.field,
                label: '',
                languageId: active.language,
                initialValue: content,
                readOnly: readOnly,
                expand: true,
                onChanged: (v) => _fieldValues[active.field] = v,
              ),
            ),
          ),
          SizedBox(
            height: 160,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: LogViewField(
                fieldName: 'output',
                label: 'Output',
                lines: _resolveLogBuffer('output'),
              ),
            ),
          ),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        left,
        const VerticalDivider(width: 1),
        Expanded(child: right),
      ],
    );
  }

  /// The editor's Tests tab — a real panel that lists the cases found
  /// in the edited wapp's tests/*.c, lets the user edit them, toggle
  /// each on/off, and run them with per-case pass/fail/skip results.
  /// Self-contained in [_TestsPanel] so it holds its own state.
  Widget _buildTestsScreen() {
    String? dir = widget.editWappDir;
    if (dir == null || dir.isEmpty) {
      final name = (_fieldValues['wapp_name'] as String?) ?? '';
      if (name.isNotEmpty) dir = installedAppsStorage().getAbsolutePath(name);
    }
    if (dir == null || dir.isEmpty) {
      return const Center(
        child: Text('Open or pick a project to see its tests.'),
      );
    }
    return _TestsPanel(key: ValueKey('tests-$dir'), wappDir: dir);
  }

  /// Initial App Creator view — just the Projects panel. No tab
  /// bar, no "Projects" label; the AppBar title is the wapp title
  /// so the user knows they're in App Creator, and the body is the
  /// projects list directly.
  Widget _buildAppCreatorProjects() {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _buildProjectsScreen(),
    );
  }

  /// App Creator editor view — shown after the user picks a project
  /// or clicks "Create new wapp". Back arrow returns to the Projects
  /// panel; tabs are Code / UI / Settings, matching the order in
  /// home.ui.json (with Projects filtered out).
  Widget _buildAppCreatorEditor() {
    final editorScreens = _editorScreens;
    final editorNames = _editorScreenNames;
    // Guard: if home.ui.json has fewer editor screens than the
    // previously-built controller expects, rebuild it. Keeps the
    // navigation coherent even while developing.
    if (_editorTabController == null ||
        _editorTabController!.length != editorScreens.length) {
      _editorTabController?.dispose();
      _editorTabController = TabController(
        length: editorScreens.length,
        vsync: this,
      );
    }
    final currentName = _fieldValues['wapp_title'] as String? ?? '';
    final titleSuffix = currentName.isEmpty ? '' : ' — $currentName';
    // Single-wapp edit (per-wapp "Edit" menu) has no Projects panel to
    // return to, so the back arrow leaves the page ("Done") and the
    // title reads "Edit — <wapp>" instead of "App Creator — <wapp>".
    final title =
        _singleTargetEdit ? 'Edit$titleSuffix' : '${widget.title}$titleSuffix';
    final backTooltip = _singleTargetEdit ? 'Done' : 'Back to projects';
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: backTooltip,
          onPressed: _exitEditorMode,
        ),
        title: Text(title),
        bottom: TabBar(
          controller: _editorTabController,
          tabs: editorNames
              .map((n) => Tab(text: _i18n.resolve(n)))
              .toList(),
          isScrollable: true,
        ),
      ),
      body: TabBarView(
        controller: _editorTabController,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (final screen in editorScreens) _buildScreen(screen),
        ],
      ),
    );
  }

  /// Install wapp Settings tab — a list of configured repositories
  /// with a single input + Add button and per-row remove affordances.
  /// Pulls its initial state from the {"type":"store.sources"} message
  /// the wapp pushes on init. Every mutation re-sends the whole list
  /// back to the wapp via a `set_sources` action — the wapp persists
  /// to its KV under "source" and echoes store.sources back so the
  /// two sides stay in sync.
  /// App Creator UI editor — the `UI` tab. Switches between a raw
  /// JSON code view (reuses [CodeEditorField]) and a click-to-edit
  /// block tree. Both sides operate on the same `_fieldValues['source_ui']`
  /// string, so the install pipeline doesn't need to know which mode
  /// the author was using.
  ///
  /// Visual-mode data model:
  /// - Parses `source_ui` as dynamic JSON. Top-level may be a list
  ///   of screens (the convention) or a single screen object.
  /// - Screens are addressed by [_uiActiveScreenIndex].
  /// - Any block inside the active screen is addressed by a path
  ///   (list of indices into the chain of `children` arrays) stored
  ///   in [_uiSelectedPath]. An empty list means "the screen itself";
  ///   `null` means "nothing selected".
  /// - Mutations walk the live `dynamic` copy, apply the change,
  ///   then re-encode the whole thing back into `_fieldValues['source_ui']`.
  Widget _buildUiEditorScreen() {
    final cs = Theme.of(context).colorScheme;
    final raw = (_fieldValues['source_ui'] as String?) ?? '';

    // Header row: Code | Visual toggle + context-dependent actions.
    Widget header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          SegmentedButton<_UiEditorMode>(
            segments: const [
              ButtonSegment(
                value: _UiEditorMode.visual,
                icon: Icon(Icons.account_tree, size: 18),
                label: Text('Visual'),
              ),
              ButtonSegment(
                value: _UiEditorMode.code,
                icon: Icon(Icons.code, size: 18),
                label: Text('Code'),
              ),
            ],
            selected: {_uiEditorMode},
            onSelectionChanged: (s) =>
                setState(() => _uiEditorMode = s.first),
            showSelectedIcon: false,
          ),
          const Spacer(),
          if (_uiEditorMode == _UiEditorMode.visual)
            FilledButton.tonalIcon(
              onPressed: _uiNewScreen,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New screen'),
            ),
        ],
      ),
    );

    Widget body;
    if (_uiEditorMode == _UiEditorMode.code) {
      body = Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: CodeEditorField(
          fieldName: 'source_ui',
          label: 'home.ui.json',
          languageId: 'json',
          initialValue: raw,
          onChanged: (v) {
            _fieldValues['source_ui'] = v;
            // Reset the visual selection so switching back to the
            // tree view doesn't point at a stale path.
            if (mounted) setState(() => _uiSelectedPath = null);
          },
          tip: 'GeoUI screens, raw JSON. Changes round-trip to the '
              'visual editor on save.',
        ),
      );
    } else {
      // Visual mode — parse, show screen tabs + tree + inspector.
      dynamic parsed;
      try {
        parsed = raw.trim().isEmpty
            ? <dynamic>[]
            : jsonDecode(raw);
      } catch (e) {
        body = _buildUiEditorError('This UI has a JSON syntax error — '
            'switch to Code mode to fix it.\n\n$e');
        return Column(children: [header, Expanded(child: body)]);
      }
      final screens = _uiScreensOf(parsed);
      if (screens.isEmpty) {
        body = _buildUiEditorEmpty();
      } else {
        if (_uiActiveScreenIndex >= screens.length) {
          _uiActiveScreenIndex = 0;
        }
        body = _buildUiEditorVisual(screens, cs);
      }
    }

    return Column(children: [header, Expanded(child: body)]);
  }

  /// Write [screens] back to `_fieldValues['source_ui']` as pretty
  /// printed JSON so the Code view (and the Install pipeline) see
  /// the mutation immediately.
  void _uiPersist(List<Map<String, dynamic>> screens) {
    const encoder = JsonEncoder.withIndent('  ');
    _fieldValues['source_ui'] = encoder.convert(screens);
  }

  Widget _buildUiEditorError(String message) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 48, color: cs.error),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildUiEditorEmpty() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dashboard_customize_outlined,
                size: 56, color: cs.primary),
            const SizedBox(height: 12),
            Text(
              'No screens yet',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            Text(
              'Click "New screen" above to add a blank screen and '
              'start building the UI.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUiEditorVisual(
      List<Map<String, dynamic>> screens, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Screen tabs — one chip per top-level screen.
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: screens.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (_, i) {
              final screen = screens[i];
              final label = (screen['name'] as String?) ?? 'Screen ${i + 1}';
              final selected = i == _uiActiveScreenIndex;
              return ChoiceChip(
                label: Text(label),
                selected: selected,
                // Default chips enforce a 48px tap target, which overflows
                // the 44px-tall row. Shrink-wrap so they fit.
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => setState(() {
                  _uiActiveScreenIndex = i;
                  _uiSelectedPath = null;
                }),
              );
            },
          ),
        ),
        Divider(height: 1, color: cs.outlineVariant.withAlpha(80)),

        // Three-pane editor: palette | canvas | inspector. The
        // palette holds draggable block templates, the canvas
        // renders the active screen as clickable mock widgets with
        // drop zones between children, and the inspector edits the
        // attributes of whatever is selected on the canvas.
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 200,
                child: _buildUiPalette(cs),
              ),
              VerticalDivider(
                  width: 1, color: cs.outlineVariant.withAlpha(80)),
              Expanded(
                flex: 3,
                child: _buildUiCanvas(screens, cs),
              ),
              VerticalDivider(
                  width: 1, color: cs.outlineVariant.withAlpha(80)),
              SizedBox(
                width: 300,
                child: _buildUiInspector(screens, cs),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Left-side panel — a scrollable list of draggable block
  /// templates. Each tile is a [Draggable] carrying a
  /// `Map<String, dynamic>` payload; the canvas drop targets read
  /// the payload and insert a deep-copy at the drop position.
  Widget _buildUiPalette(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerLow,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        children: [
          Text(
            'Palette',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            'Drag onto the canvas',
            style: TextStyle(
              fontSize: 11,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          for (final entry in _uiPaletteEntries())
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _buildPaletteTile(entry, cs),
            ),
        ],
      ),
    );
  }

  Widget _buildPaletteTile(_UiPaletteEntry entry, ColorScheme cs) {
    final tile = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant.withAlpha(100)),
      ),
      child: Row(
        children: [
          Icon(entry.icon, size: 18, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  entry.label,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (entry.subLabel != null) ...[
                  const SizedBox(height: 1),
                  Text(
                    entry.subLabel!,
                    style: TextStyle(
                      fontSize: 10,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Icon(Icons.drag_indicator, size: 16, color: cs.onSurfaceVariant),
        ],
      ),
    );
    return Draggable<_UiDragPayload>(
      data: _UiDragPayload.fromPalette(entry.template),
      feedback: Material(
        elevation: 6,
        color: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 180),
          child: Opacity(opacity: 0.88, child: tile),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: tile),
      child: tile,
    );
  }

  /// Center pane — a scrollable, click-to-select preview of the
  /// current screen. Each block renders as a mock widget that looks
  /// roughly like the real thing (text field, button, log viewer,
  /// etc.), wrapped in a [GestureDetector] that flips the selection
  /// and an outline decoration when selected. Drop zones sit between
  /// children so palette items and reordered blocks can be inserted
  /// at exact positions.
  Widget _buildUiCanvas(
      List<Map<String, dynamic>> screens, ColorScheme cs) {
    final active = screens[_uiActiveScreenIndex];
    return Container(
      color: cs.surface,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
        children: [
          _buildCanvasHeader(active, cs),
          const SizedBox(height: 12),
          _buildCanvasBlock(active, const [], cs, asRoot: true),
        ],
      ),
    );
  }

  /// Thin bar above the canvas body that shows which screen we're
  /// editing plus its tip.
  Widget _buildCanvasHeader(Map<String, dynamic> screen, ColorScheme cs) {
    final name = (screen['name'] as String?) ?? 'Screen';
    final tip = (screen['tip'] as String?) ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.phone_android, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            Text(
              name,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
        if (tip.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            tip,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ],
    );
  }

  /// Recursive canvas renderer. A block is drawn as:
  /// - container blocks (screen, group) → outlined card containing
  ///   its children interleaved with drop zones
  /// - leaf blocks (field, action, label) → a mock widget that
  ///   resembles the live rendering
  ///
  /// [path] is the chain of child indices that reaches this block
  /// from the active screen. The outermost call passes `const []`
  /// which addresses the screen itself. `asRoot` disables the outer
  /// outline + drag handle because the screen isn't draggable — it
  /// lives in the top-level `screens` array, not a `children` list.
  Widget _buildCanvasBlock(
    Map<String, dynamic> block,
    List<int> path,
    ColorScheme cs, {
    bool asRoot = false,
  }) {
    final kw = (block[r'$'] as String?) ?? 'block';
    final isContainer = kw == 'screen' || kw == 'group';
    final selected = _uiSelectedPath != null &&
        _listEquals(_uiSelectedPath!, path);

    final inner = isContainer
        ? _buildCanvasContainer(block, path, cs)
        : _buildCanvasLeaf(block, cs);

    // Selection outline. Also used to highlight containers so the
    // user sees the boundary of each group / screen even when not
    // selected.
    final outlineColor = selected
        ? cs.primary
        : isContainer
            ? cs.outlineVariant.withAlpha(140)
            : Colors.transparent;
    final outlineWidth = selected ? 2.0 : (isContainer ? 1.0 : 0.0);

    Widget wrapped = Container(
      margin: asRoot
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: selected
            ? cs.primaryContainer.withAlpha(60)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: outlineColor, width: outlineWidth),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _uiSelectedPath = path),
        child: Padding(
          padding: isContainer
              ? const EdgeInsets.fromLTRB(10, 10, 10, 10)
              : const EdgeInsets.fromLTRB(4, 4, 4, 4),
          child: inner,
        ),
      ),
    );

    // Non-root blocks are draggable so the user can grab them and
    // drop them into another container / position.
    if (!asRoot) {
      wrapped = LongPressDraggable<_UiDragPayload>(
        data: _UiDragPayload.fromMove(path),
        feedback: Material(
          elevation: 6,
          color: Colors.transparent,
          child: Opacity(
            opacity: 0.85,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: wrapped,
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: wrapped),
        delay: const Duration(milliseconds: 250),
        child: wrapped,
      );
    }

    return wrapped;
  }

  /// Build the interior of a container block: a header line with
  /// the keyword + name, then every child interleaved with drop
  /// zones so users can drop into exact positions.
  Widget _buildCanvasContainer(
      Map<String, dynamic> block, List<int> path, ColorScheme cs) {
    final kw = (block[r'$'] as String?) ?? 'block';
    final type = (block[r'$type'] as String?) ?? '';
    final name = (block['name'] as String?) ?? '';
    final children = (block['children'] as List?) ?? const [];

    // Special group renderings: show a chip stand-in so the user
    // understands these groups are rendered natively by the host
    // and don't have editable children in the WYSIWYG sense.
    final isSpecialGroup =
        kw == 'group' && const {
              'projects',
              'tasks',
              'map',
              'output',
              'sources',
              'ui-editor'
            }.contains(type);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(_uiIconForBlock(kw, type), size: 14, color: cs.primary),
            const SizedBox(width: 6),
            Text(
              kw.toUpperCase(),
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
                color: cs.primary,
              ),
            ),
            if (type.isNotEmpty) ...[
              const SizedBox(width: 6),
              Text(
                ':$type',
                style: TextStyle(
                  fontSize: 10,
                  color: cs.onSurfaceVariant,
                  fontFamily: 'monospace',
                ),
              ),
            ],
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                name,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (isSpecialGroup)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.secondaryContainer.withAlpha(120),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: cs.outlineVariant.withAlpha(120)),
            ),
            child: Row(
              children: [
                Icon(Icons.auto_awesome,
                    size: 16, color: cs.onSecondaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'This group is rendered natively by the host '
                    '(type: $type). It has no drag-and-drop children.',
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          )
        else ...[
          _buildCanvasDropZone(path, 0, cs),
          for (var i = 0; i < children.length; i++)
            if (children[i] is Map<String, dynamic>) ...[
              _buildCanvasBlock(
                children[i] as Map<String, dynamic>,
                [...path, i],
                cs,
              ),
              _buildCanvasDropZone(path, i + 1, cs),
            ],
          if (children.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Drop blocks from the palette here',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ],
    );
  }

  /// Drop-target thin bar placed between (or around) children of a
  /// container. When a drag hovers over it, it expands and highlights
  /// so the user sees exactly where the block will land.
  Widget _buildCanvasDropZone(
      List<int> parentPath, int insertIndex, ColorScheme cs) {
    return DragTarget<_UiDragPayload>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) =>
          _uiHandleDrop(details.data, parentPath, insertIndex),
      builder: (context, candidate, rejected) {
        final active = candidate.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: active ? 26 : 8,
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: active
                ? cs.primary.withAlpha(60)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active
                  ? cs.primary
                  : cs.outlineVariant.withAlpha(60),
              width: active ? 2 : 1,
              style: BorderStyle.solid,
            ),
          ),
          alignment: Alignment.center,
          child: active
              ? Text(
                  'Drop here',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                  ),
                )
              : null,
        );
      },
    );
  }

  /// Render a leaf block (field / action / label) as a mock widget
  /// that resembles the live rendering: text fields show a placeholder
  /// TextField, actions show a real button styled the same way, etc.
  /// Everything is non-interactive so the user can click to select
  /// without accidentally editing the preview.
  Widget _buildCanvasLeaf(Map<String, dynamic> block, ColorScheme cs) {
    final kw = (block[r'$'] as String?) ?? '';
    if (kw == 'action') {
      final label = (block['label'] as String?) ?? 'Action';
      final style = (block['style'] as String?) ?? 'secondary';
      return IgnorePointer(
        child: switch (style) {
          'primary' => FilledButton(
              onPressed: () {},
              child: Text(label),
            ),
          'danger' => FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: cs.error,
                foregroundColor: cs.onError,
              ),
              onPressed: () {},
              child: Text(label),
            ),
          _ => OutlinedButton(
              onPressed: () {},
              child: Text(label),
            ),
        },
      );
    }
    if (kw == 'label') {
      final text = (block['text'] as String?) ?? '';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(text, style: const TextStyle(fontSize: 13)),
      );
    }
    if (kw == 'field') {
      final type = (block[r'$type'] as String?) ?? 'string';
      final label = (block['label'] as String?) ?? (block['name'] as String? ?? '');
      final tip = (block['tip'] as String?) ?? '';
      return _buildCanvasFieldMock(type, label, tip, block, cs);
    }
    // Unknown leaf — show generic pill.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        (block['name'] as String?) ?? kw,
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  /// Mock rendering for a `$type:"..."` field. Keeps the real
  /// Flutter widget shapes (TextField, Switch, …) so the preview
  /// matches what the user will see at runtime.
  Widget _buildCanvasFieldMock(
    String type,
    String label,
    String tip,
    Map<String, dynamic> block,
    ColorScheme cs,
  ) {
    final base = InputDecoration(
      labelText: label,
      helperText: tip.isEmpty ? null : tip,
      filled: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      isDense: true,
    );
    switch (type) {
      case 'bool':
        return SwitchListTile(
          value: (block['default'] as bool?) ?? false,
          title: Text(label),
          subtitle: tip.isEmpty ? null : Text(tip),
          onChanged: null,
          contentPadding: EdgeInsets.zero,
        );
      case 'int':
      case 'float':
        return IgnorePointer(
          child: TextField(
            controller: TextEditingController(
                text: '${block['default'] ?? ''}'),
            decoration: base,
          ),
        );
      case 'enum':
        return IgnorePointer(
          child: DropdownButtonFormField<String>(
            initialValue: null,
            decoration: base,
            items: const [],
            onChanged: (_) {},
          ),
        );
      case 'code':
        final lang = (block['language'] as String?) ?? 'text';
        return Container(
          height: 120,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(10),
            border:
                Border.all(color: cs.outlineVariant.withAlpha(100)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.isEmpty ? '$lang source' : label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: Text(
                  '// $lang code editor\n// syntax highlighted at runtime',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.white54,
                  ),
                ),
              ),
            ],
          ),
        );
      case 'log':
        return Container(
          height: 120,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF0B1020),
            borderRadius: BorderRadius.circular(10),
            border:
                Border.all(color: cs.outlineVariant.withAlpha(100)),
          ),
          child: Text(
            label.isEmpty ? 'Log output' : label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.white70,
            ),
          ),
        );
      case 'icon':
        return Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.extension,
                  color: Colors.white, size: 26),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        );
      case 'string':
      default:
        final multiline = (block['multiline'] as bool?) ?? false;
        return IgnorePointer(
          child: TextField(
            controller: TextEditingController(
                text: '${block['default'] ?? ''}'),
            maxLines: multiline ? ((block['lines'] as num?)?.toInt() ?? 3) : 1,
            decoration: base,
          ),
        );
    }
  }

  /// Insert or move a block based on a drag payload. Called from
  /// every drop zone.
  void _uiHandleDrop(
      _UiDragPayload data, List<int> parentPath, int insertIndex) {
    final raw = (_fieldValues['source_ui'] as String?) ?? '[]';
    final dynamic parsed;
    try {
      parsed = jsonDecode(raw);
    } catch (_) {
      return;
    }
    final screens = _uiScreensOf(parsed);
    if (_uiActiveScreenIndex >= screens.length) return;
    final activeScreen = screens[_uiActiveScreenIndex];

    if (data.kind == _UiDragKind.palette) {
      // Fresh insert from the palette — deep-copy the template.
      final block = _deepClone(data.payload!);
      _uiInsertBlockAt(activeScreen, parentPath, insertIndex, block);
      _uiPersist(screens);
      setState(() => _uiSelectedPath = [...parentPath, insertIndex]);
      return;
    }

    // Move existing block.
    final sourcePath = data.movePath!;
    if (sourcePath.isEmpty) return; // can't move the screen itself
    // Avoid dropping a block into its own subtree.
    if (_isDescendant(parentPath, sourcePath)) return;
    final sourceParentPath = sourcePath.sublist(0, sourcePath.length - 1);
    final sourceParent = _uiLookup(activeScreen, sourceParentPath);
    if (sourceParent == null) return;
    final sourceKidsRaw = sourceParent['children'];
    if (sourceKidsRaw is! List) return;
    final sourceKids = sourceKidsRaw;
    final sourceIndex = sourcePath.last;
    if (sourceIndex < 0 || sourceIndex >= sourceKids.length) return;
    final movingBlock = sourceKids.removeAt(sourceIndex);

    // Adjust the insert index if the source was a sibling earlier
    // in the same parent (removing it shifts everyone up by one).
    var adjustedInsert = insertIndex;
    final sameParent = _listEquals(sourceParentPath, parentPath);
    if (sameParent && sourceIndex < adjustedInsert) {
      adjustedInsert--;
    }
    _uiInsertBlockAt(
        activeScreen, parentPath, adjustedInsert, movingBlock as Map<String, dynamic>);
    _uiPersist(screens);
    setState(() => _uiSelectedPath = [...parentPath, adjustedInsert]);
  }

  void _uiInsertBlockAt(
    Map<String, dynamic> activeScreen,
    List<int> parentPath,
    int insertIndex,
    Map<String, dynamic> block,
  ) {
    final parent = _uiLookup(activeScreen, parentPath);
    if (parent == null) return;
    var kidsRaw = parent['children'];
    List<dynamic> kids;
    if (kidsRaw is List) {
      kids = kidsRaw;
    } else {
      kids = <dynamic>[];
      parent['children'] = kids;
    }
    final clamped = insertIndex < 0
        ? 0
        : (insertIndex > kids.length ? kids.length : insertIndex);
    kids.insert(clamped, block);
  }

  /// True when [path] is inside the subtree rooted at [ancestor].
  bool _isDescendant(List<int> path, List<int> ancestor) {
    if (ancestor.isEmpty) return false;
    if (path.length < ancestor.length) return false;
    for (var i = 0; i < ancestor.length; i++) {
      if (path[i] != ancestor[i]) return false;
    }
    return true;
  }

  /// Right-side pane — edits the scalar attributes of the currently
  /// selected block. Fields are typed (Switch for bool, number
  /// keyboard for num, text area for `multiline` strings) so the
  /// user isn't just typing into a JSON string.
  Widget _buildUiInspector(
      List<Map<String, dynamic>> screens, ColorScheme cs) {
    final selected = _uiSelectedPath;
    if (selected == null) {
      return Container(
        color: cs.surfaceContainerLow,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Click a block on the canvas to edit its properties.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ),
        ),
      );
    }
    final active = screens[_uiActiveScreenIndex];
    final block = _uiLookup(active, selected);
    if (block == null) {
      return Container(
        color: cs.surfaceContainerLow,
        child: Center(
          child: Text(
            'Selection is stale — pick another block.',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      );
    }
    final kw = (block[r'$'] as String?) ?? 'block';
    final type = (block[r'$type'] as String?) ?? '';
    final isRoot = selected.isEmpty;

    return Container(
      color: cs.surfaceContainerLow,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        children: [
          Row(
            children: [
              Icon(_uiIconForBlock(kw, type),
                  size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  kw.toUpperCase() + (type.isNotEmpty ? ' : $type' : ''),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              if (!isRoot)
                IconButton(
                  onPressed: _uiDeleteSelected,
                  icon: Icon(Icons.delete_outline, color: cs.error),
                  tooltip: 'Delete',
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 12),
          for (final field in _uiInspectorFields(block))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: field,
            ),
          if (!isRoot) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () => _uiMoveSelected(-1),
                  icon: const Icon(Icons.arrow_upward, size: 14),
                  label: const Text('Up'),
                  style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                ),
                const SizedBox(width: 6),
                OutlinedButton.icon(
                  onPressed: () => _uiMoveSelected(1),
                  icon: const Icon(Icons.arrow_downward, size: 14),
                  label: const Text('Down'),
                  style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Single attribute editor. Picks the right widget based on the
  /// current value's type.
  Widget _uiInspectorField(String key, dynamic value) {
    if (value is bool) {
      return SwitchListTile(
        title: Text(key, style: const TextStyle(fontSize: 12)),
        value: value,
        contentPadding: EdgeInsets.zero,
        dense: true,
        onChanged: (v) => _uiUpdateAttributeTyped(key, v),
      );
    }
    if (value is num) {
      return TextField(
        controller: TextEditingController(text: value.toString()),
        decoration: InputDecoration(
          labelText: key,
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
        keyboardType: const TextInputType.numberWithOptions(
            signed: true, decimal: true),
        onChanged: (v) {
          final parsed = num.tryParse(v);
          if (parsed != null) _uiUpdateAttributeTyped(key, parsed);
        },
      );
    }
    // String (or missing) fallback. Use multiline for `default` when
    // the block is marked multiline, and for `tip` which is often
    // long.
    final s = value?.toString() ?? '';
    final wantsMulti = key == 'tip' || (key == 'default' && s.contains('\n'));
    return TextField(
      controller: TextEditingController(text: s),
      decoration: InputDecoration(
        labelText: key,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
      maxLines: wantsMulti ? 4 : 1,
      minLines: wantsMulti ? 2 : 1,
      onChanged: (v) => _uiUpdateAttributeTyped(key, v),
    );
  }

  /// Updater that preserves the value's JSON type. Used from the
  /// inspector widgets that already know whether they're editing a
  /// bool / num / string.
  void _uiUpdateAttributeTyped(String key, dynamic value) {
    final path = _uiSelectedPath;
    if (path == null) return;
    final raw = (_fieldValues['source_ui'] as String?) ?? '[]';
    try {
      final parsed = jsonDecode(raw);
      final screens = _uiScreensOf(parsed);
      if (_uiActiveScreenIndex >= screens.length) return;
      final block = _uiLookup(screens[_uiActiveScreenIndex], path);
      if (block == null) return;
      block[key] = value;
      _uiPersist(screens);
    } catch (_) {}
  }

  /// App Creator Translations tab — per-locale key/value table
  /// editor for the wapp's `lang/<locale>.json` sidecars. The
  /// authoritative state lives in
  /// `_fieldValues['translations']` as
  /// `Map<String /*locale*/, Map<String, String>>`, seeded by
  /// [_loadProject] and shipped through [WappInstallerService] on
  /// install. Empty string values are kept so the extract-keys
  /// button can surface untranslated stubs.
  Widget _buildTranslationsScreen() {
    final cs = Theme.of(context).colorScheme;
    final translations = _translationsMap();

    // Sorted locale list for the dropdown. Always includes `en`
    // as the de-facto fallback so authors can start there even
    // when no lang/*.json files exist yet.
    final locales = translations.keys.toList()..sort();
    if (locales.isEmpty) locales.add('en');
    // Clamp the active selection to something valid.
    if (_translationsLocale == null ||
        !locales.contains(_translationsLocale)) {
      _translationsLocale = locales.first;
    }
    final activeLocale = _translationsLocale!;
    final currentMap = translations.putIfAbsent(
        activeLocale, () => <String, String>{});

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        Text(
          'Translations',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          'Each locale becomes a lang/<code>.json sidecar inside '
          'the wapp package. Strings in the UI prefixed with @key '
          'resolve to the value below at runtime — the fallback '
          'chain is exact tag → language-only → en → the literal '
          'key.',
          style: TextStyle(color: cs.onSurfaceVariant, height: 1.35),
        ),
        const SizedBox(height: 12),

        // Persistence banner + save button. Typing into the rows
        // below only mutates the in-memory bindings — the actual
        // lang/*.json sidecars are written by the installer, which
        // also writes everything else (source, UI, icon, …). The
        // Save button is a convenience that triggers the same code
        // path Install on the Code tab does, so the author can
        // commit translations without tab-hopping.
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            color: cs.primaryContainer.withAlpha(80),
            borderRadius: BorderRadius.circular(12),
            border:
                Border.all(color: cs.outlineVariant.withAlpha(100)),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline, color: cs.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Edits are kept in memory while you type. '
                  'Click Save to write every lang/<locale>.json '
                  'sidecar to disk (same as clicking Install '
                  'on the Code tab).',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onPrimaryContainer,
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _translationsSaveToDisk,
                icon: const Icon(Icons.save, size: 16),
                label: const Text('Save'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Locale picker + add / remove buttons.
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: activeLocale,
                decoration: InputDecoration(
                  labelText: 'Locale',
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                items: [
                  for (final code in locales)
                    DropdownMenuItem(
                      value: code,
                      child: Text(
                        '$code  (${currentMap.length} key'
                        '${currentMap.length == 1 ? '' : 's'})'
                        .replaceAll(
                            '${currentMap.length}', '${translations[code]?.length ?? 0}'),
                      ),
                    ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _translationsLocale = v);
                },
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: _translationsAddLocale,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add locale'),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: activeLocale == 'en'
                  ? null
                  : () => _translationsRemoveLocale(activeLocale),
              icon: Icon(Icons.delete_outline,
                  size: 16, color: cs.error),
              label: Text('Remove',
                  style: TextStyle(color: cs.error)),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Toolbar: extract @keys from UI + add a blank key.
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: () => _translationsExtractKeys(activeLocale),
              icon: const Icon(Icons.auto_fix_high, size: 16),
              label: const Text('Extract @keys from UI'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => _translationsAddKey(activeLocale),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add key'),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Key/value rows.
        if (currentMap.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cs.outlineVariant.withAlpha(80)),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: cs.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'No keys yet. Click "Extract @keys from UI" to '
                    'scan the UI tab for references, or "Add key" '
                    'to create one manually.',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          )
        else
          for (final key in (currentMap.keys.toList()..sort()))
            _buildTranslationsRow(activeLocale, key, currentMap[key] ?? '', cs),
      ],
    );
  }

  Widget _buildTranslationsRow(
      String locale, String key, String value, ColorScheme cs) {
    // Use a keyed TextEditingController so the row survives locale
    // switches without dropping the user's in-flight edit.
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outlineVariant.withAlpha(80)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.key_outlined,
                    size: 14, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    key,
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => _translationsRemoveKey(locale, key),
                  icon: Icon(Icons.close, size: 16, color: cs.error),
                  tooltip: 'Remove key',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 4),
            TextField(
              controller: TextEditingController(text: value),
              decoration: InputDecoration(
                hintText: value.isEmpty ? '(untranslated)' : null,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              maxLines: 3,
              minLines: 1,
              onChanged: (v) => _translationsSetValue(locale, key, v),
            ),
          ],
        ),
      ),
    );
  }

  void _translationsSetValue(String locale, String key, String value) {
    final map = _translationsMap();
    final inner = map.putIfAbsent(locale, () => <String, String>{});
    inner[key] = value;
    // No setState — the text field is controlled by its own
    // controller; we only need the mutation to land in the
    // bindings so Install picks it up.
  }

  void _translationsRemoveLocale(String locale) {
    final map = _translationsMap();
    map.remove(locale);
    setState(() {
      if (_translationsLocale == locale) {
        _translationsLocale =
            map.keys.isEmpty ? null : map.keys.first;
      }
    });
  }

  void _translationsRemoveKey(String locale, String key) {
    final map = _translationsMap();
    // Removing a key from one locale removes it from all of them
    // so the author's locale tables stay in sync.
    for (final loc in map.keys) {
      map[loc]?.remove(key);
    }
    setState(() {});
  }

  /// Walk the current UI JSON looking for every `@key` reference in
  /// any string field and add the missing keys to every locale with
  /// an empty value. Never overwrites an existing translation.
  void _translationsExtractKeys(String locale) {
    final rawUi = (_fieldValues['source_ui'] as String?) ?? '';
    if (rawUi.trim().isEmpty) return;
    final discovered = <String>{};
    try {
      final parsed = jsonDecode(rawUi);
      _translationsWalk(parsed, discovered);
    } catch (_) {
      return;
    }
    if (discovered.isEmpty) return;
    final map = _translationsMap();
    // Create the active locale if it doesn't exist yet.
    final target = map.putIfAbsent(locale, () => <String, String>{});
    for (final key in discovered) {
      target.putIfAbsent(key, () => '');
      // Mirror the empty stub into every other locale so the row
      // renders across the dropdown consistently.
      for (final loc in map.keys) {
        if (loc != locale) map[loc]!.putIfAbsent(key, () => '');
      }
    }
    setState(() {});
  }

  /// Recursive walker for [_translationsExtractKeys]. Collects any
  /// string value (at any depth) that starts with `@` and looks
  /// like a valid key (no whitespace).
  void _translationsWalk(dynamic node, Set<String> out) {
    if (node is Map) {
      for (final v in node.values) {
        _translationsWalk(v, out);
      }
    } else if (node is List) {
      for (final v in node) {
        _translationsWalk(v, out);
      }
    } else if (node is String) {
      if (node.startsWith('@') && node.length > 1 &&
          !node.contains(' ') && !node.contains('\n')) {
        out.add(node.substring(1));
      }
    }
  }

  /// Delete the currently-selected block from its parent's children
  /// array. Cannot delete the screen itself — the inspector hides
  /// the button in that case.
  void _uiDeleteSelected() {
    final path = _uiSelectedPath;
    if (path == null || path.isEmpty) return;
    final raw = (_fieldValues['source_ui'] as String?) ?? '[]';
    try {
      final parsed = jsonDecode(raw);
      final screens = _uiScreensOf(parsed);
      if (_uiActiveScreenIndex >= screens.length) return;
      final parentPath = path.sublist(0, path.length - 1);
      final parent =
          _uiLookup(screens[_uiActiveScreenIndex], parentPath);
      if (parent == null) return;
      final kids = parent['children'];
      if (kids is! List) return;
      final idx = path.last;
      if (idx < 0 || idx >= kids.length) return;
      kids.removeAt(idx);
      _uiPersist(screens);
      setState(() => _uiSelectedPath = null);
    } catch (_) {}
  }

  /// Shift the selected block up (delta = -1) or down (delta = +1)
  /// within its siblings. Clamped to the children array bounds.
  void _uiMoveSelected(int delta) {
    final path = _uiSelectedPath;
    if (path == null || path.isEmpty) return;
    final raw = (_fieldValues['source_ui'] as String?) ?? '[]';
    try {
      final parsed = jsonDecode(raw);
      final screens = _uiScreensOf(parsed);
      if (_uiActiveScreenIndex >= screens.length) return;
      final parentPath = path.sublist(0, path.length - 1);
      final parent =
          _uiLookup(screens[_uiActiveScreenIndex], parentPath);
      if (parent == null) return;
      final kids = parent['children'];
      if (kids is! List) return;
      final idx = path.last;
      final target = idx + delta;
      if (target < 0 || target >= kids.length) return;
      final block = kids.removeAt(idx);
      kids.insert(target, block);
      _uiPersist(screens);
      setState(() => _uiSelectedPath = [...parentPath, target]);
    } catch (_) {}
  }

  /// Append a new blank screen to the top-level list and select it.
  void _uiNewScreen() {
    final raw = (_fieldValues['source_ui'] as String?) ?? '';
    List<Map<String, dynamic>> screens;
    try {
      final parsed =
          raw.trim().isEmpty ? <dynamic>[] : jsonDecode(raw);
      screens = _uiScreensOf(parsed);
    } catch (_) {
      screens = <Map<String, dynamic>>[];
    }
    final next = <String, dynamic>{
      r'$': 'screen',
      'name': 'Screen ${screens.length + 1}',
      'children': <dynamic>[],
    };
    screens.add(next);
    _uiPersist(screens);
    setState(() {
      _uiActiveScreenIndex = screens.length - 1;
      _uiSelectedPath = const [];
    });
  }

  bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Full App Creator Settings screen — identity fields via GeoUI
  /// renderer, plus custom chip pickers for HAL requires and provides.
  Widget _buildAppCreatorSettings(Widget identityRenderer) {
    final cs = Theme.of(context).colorScheme;
    final profile = ProfileService.instance.activeProfile;
    final npub = profile?.npub ?? '';

    // Ensure list-typed fields exist.
    _fieldValues.putIfAbsent('wapp_hal_requires', () => <String>['log']);
    _fieldValues.putIfAbsent('wapp_provides_functionalities', () => <String>[]);
    _fieldValues.putIfAbsent('wapp_kind', () => 'app');
    _fieldValues.putIfAbsent('wapp_tick_interval', () => '5000');

    final halRequires = _fieldValues['wapp_hal_requires'];
    final halList = halRequires is List<String>
        ? halRequires
        : <String>['log'];
    final providesList = _fieldValues['wapp_provides_functionalities'];
    final provides = providesList is List<String>
        ? providesList
        : <String>[];

    return Column(
      children: [
        // ── Save banner ──
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            color: cs.primaryContainer.withAlpha(80),
            border: Border(
              bottom: BorderSide(color: cs.outlineVariant.withAlpha(100)),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline, color: cs.primary, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Changes are kept in memory while you edit. '
                  'Click Save to write them to disk.',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onPrimaryContainer,
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _settingsSaveToDisk,
                icon: const Icon(Icons.save, size: 16),
                label: const Text('Save'),
              ),
            ],
          ),
        ),

        // ── Signing identity ──
        _buildSigningIdentitySection(cs, profile, npub),

        // ── Scrollable body: GeoUI identity + runtime + deps ──
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
            children: [
              // Identity fields via GeoUI renderer (title, name, id,
              // version, description, icon). SizedBox must be tall
              // enough to fit all fields without internal scrolling,
              // otherwise the renderer's SingleChildScrollView
              // swallows scroll events and prevents the outer
              // ListView from reaching Category / HAL / Provides.
              SizedBox(
                height: 700,
                child: identityRenderer,
              ),

              // ── Category ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'Category',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(
                  'Where this wapp appears on the launcher.',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: {
                    'app': 'App (main grid)',
                    'system': 'System',
                    'addon': 'Addon',
                  }.entries.map((e) {
                    final selected =
                        (_fieldValues['wapp_kind'] ?? 'app') == e.key;
                    return ChoiceChip(
                      label: Text(e.value),
                      selected: selected,
                      onSelected: (on) {
                        if (on) {
                          setState(() => _fieldValues['wapp_kind'] = e.key);
                        }
                      },
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 12),

              // ── Tick interval ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: TextField(
                  controller: _tickIntervalController,
                  decoration: InputDecoration(
                    labelText: 'Tick interval (ms)',
                    helperText:
                        'How often module_tick() runs. 0 to disable.',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (v) =>
                      _fieldValues['wapp_tick_interval'] = v,
                ),
              ),
              const SizedBox(height: 20),

              // ── HAL requires — chip picker ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: Text(
                  'HAL dependencies',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(
                  'Select which HAL capabilities this wapp needs. '
                  'The launcher checks these at load time.',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: _WappPageState._halCapabilities.entries.map((e) {
                    final selected = halList.contains(e.key);
                    return FilterChip(
                      label: Text(e.key),
                      tooltip: e.value,
                      selected: selected,
                      onSelected: (on) {
                        setState(() {
                          if (on) {
                            if (!halList.contains(e.key)) {
                              halList.add(e.key);
                            }
                          } else {
                            halList.remove(e.key);
                          }
                          _fieldValues['wapp_hal_requires'] = halList;
                        });
                      },
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 20),

              // ── Provides functionalities — tag editor ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: Text(
                  'Provides functionalities',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(
                  'Functionalities this wapp provides for other wapps to use.',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final w in provides)
                      InputChip(
                        label: Text(w),
                        onDeleted: () {
                          setState(() {
                            provides.remove(w);
                            _fieldValues['wapp_provides_functionalities'] = provides;
                          });
                        },
                      ),
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 16),
                      label: const Text('Add'),
                      onPressed: () => _addProvidesFunctionality(provides),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSigningIdentitySection(
      ColorScheme cs, IwiProfile? profile, String npub) {
    final allProfiles = ProfileService.instance.profiles;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.verified_user, color: cs.primary, size: 18),
              const SizedBox(width: 8),
              Text(
                'Signing identity',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const Spacer(),
              // Copy npub
              if (npub.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  tooltip: 'Copy npub',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: npub));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('npub copied'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                ),
            ],
          ),
          const SizedBox(height: 6),
          // Profile picker dropdown
          if (allProfiles.length > 1)
            DropdownButtonFormField<String>(
              initialValue: profile?.id,
              isDense: true,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Active profile',
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              items: allProfiles.map((p) {
                final label = p.displayName;
                final short = p.npub.length > 20
                    ? '${p.npub.substring(0, 12)}…${p.npub.substring(p.npub.length - 6)}'
                    : p.npub;
                return DropdownMenuItem(
                  value: p.id,
                  child: Text('$label  ($short)',
                      overflow: TextOverflow.ellipsis),
                );
              }).toList(),
              onChanged: (id) async {
                if (id == null) return;
                await ProfileService.instance.switchTo(id);
                if (mounted) setState(() {});
              },
            )
          else if (npub.isNotEmpty)
            Text(
              npub,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: cs.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            )
          else
            Text(
              'No profile — wapps will not be signed',
              style: TextStyle(fontSize: 12, color: cs.error),
            ),
          const SizedBox(height: 6),
          // Action row: generate new / import nsec
          Row(
            children: [
              TextButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New identity'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                ),
                onPressed: () async {
                  final preview = ProfileService.instance.generatePreview();
                  await ProfileService.instance.saveAndActivate(preview);
                  if (!mounted) return;
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(
                        'New identity created: ${preview.callsign}'),
                    duration: const Duration(seconds: 3),
                  ));
                },
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                icon: const Icon(Icons.key, size: 16),
                label: const Text('Import nsec'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                ),
                onPressed: () => _importNsec(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Persist App Creator settings (title, name, id, description, icon,
  /// UI, translations) to the installed-apps folder. Follows the same
  /// pattern as [_translationsSaveToDisk] — delegates to
  /// [_handleInstall] which writes the full wapp package.
  Future<void> _settingsSaveToDisk() async {
    final id = (_fieldValues['wapp_id'] as String?) ?? '';
    if (id.isEmpty) {
      NotificationService.instance.show(GeogramNotification(
        level: NotificationLevel.error,
        title: 'Cannot save',
        body: 'Open or create a project first (ID is empty).',
        source: 'host:app-creator',
      ));
      return;
    }
    await _handleInstall(<String, dynamic>{
      'id': id,
      'title': (_fieldValues['wapp_title'] as String?) ?? '',
      'name': (_fieldValues['wapp_name'] as String?) ?? '',
      'description':
          (_fieldValues['wapp_description'] as String?) ?? '',
      'source_ui': (_fieldValues['source_ui'] as String?) ?? '',
    });
  }

  /// Confirm-and-delete a project. Pops a dialog; on confirm,
  /// nukes the installed-apps folder and refreshes the list. Also
  /// fires `WappLoadedEvent` so the launcher rescan drops the tile.
  Future<void> _deleteProject(_ProjectEntry entry) async {
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${entry.folder}?'),
        content: Text(
          'This will permanently delete apps/${entry.folder}/ and '
          'everything inside it (manifest, wasm, screens). This '
          'cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await installedAppsStorage()
          .deleteDirectory(entry.folder, recursive: true);
    } catch (e) {
      NotificationService.instance.show(GeogramNotification(
        level: NotificationLevel.error,
        title: 'Delete failed',
        body: e.toString(),
        source: 'host:app-creator',
      ));
      return;
    }
    NotificationService.instance.show(GeogramNotification(
      level: NotificationLevel.info,
      title: 'Deleted ${entry.folder}',
      source: 'host:app-creator',
    ));
    // WappLoadedEvent doubles as "launcher, please rescan" — reuse it.
    EventBus().fire(WappLoadedEvent(wappId: entry.id, wappName: entry.folder));
    await _refreshProjects();
  }

  /// Extract the top-level screen list from a parsed `source_ui`.
  /// Handles both shapes: a List of blocks (convention) and a single
  /// block object. Non-screen top-level blocks are passed through
  /// too so the user can see + delete them.
  List<Map<String, dynamic>> _uiScreensOf(dynamic parsed) {
    if (parsed is List) {
      return parsed.whereType<Map<String, dynamic>>().toList();
    }
    if (parsed is Map<String, dynamic>) return [parsed];
    return [];
  }

  /// Static catalogue of block types the user can drag from the
  /// palette. Each entry bundles the icon, the label, an optional
  /// subtitle, and a template JSON to deep-copy at drop time.
  List<_UiPaletteEntry> _uiPaletteEntries() {
    return [
      const _UiPaletteEntry(
        label: 'Screen',
        subLabel: 'Top-level tab',
        icon: Icons.web,
        template: {
          r'$': 'screen',
          'name': 'Screen',
          'tip': '',
          'children': <dynamic>[],
        },
      ),
      const _UiPaletteEntry(
        label: 'Group',
        subLabel: 'Card container',
        icon: Icons.folder_special,
        template: {
          r'$': 'group',
          'name': 'Group',
          'tip': '',
          'children': <dynamic>[],
        },
      ),
      const _UiPaletteEntry(
        label: 'Label',
        subLabel: 'Plain text',
        icon: Icons.label,
        template: {r'$': 'label', 'text': 'Hello world'},
      ),
      const _UiPaletteEntry(
        label: 'Action button',
        subLabel: 'Sends action to wapp',
        icon: Icons.smart_button,
        template: {
          r'$': 'action',
          'name': 'save',
          'label': 'Save',
          'style': 'primary',
        },
      ),
      const _UiPaletteEntry(
        label: 'Text field',
        subLabel: 'Single-line input',
        icon: Icons.text_fields,
        template: {
          r'$': 'field',
          r'$type': 'string',
          'name': 'field1',
          'label': 'Field',
          'default': '',
        },
      ),
      const _UiPaletteEntry(
        label: 'Multi-line field',
        subLabel: 'Text area',
        icon: Icons.subject,
        template: {
          r'$': 'field',
          r'$type': 'string',
          'name': 'field1',
          'label': 'Field',
          'multiline': true,
          'lines': 5,
          'default': '',
        },
      ),
      const _UiPaletteEntry(
        label: 'Toggle',
        subLabel: 'On / off switch',
        icon: Icons.toggle_on,
        template: {
          r'$': 'field',
          r'$type': 'bool',
          'name': 'enabled',
          'label': 'Enabled',
          'default': false,
        },
      ),
      const _UiPaletteEntry(
        label: 'Number',
        subLabel: 'Integer input',
        icon: Icons.numbers,
        template: {
          r'$': 'field',
          r'$type': 'int',
          'name': 'count',
          'label': 'Count',
          'default': 0,
        },
      ),
      const _UiPaletteEntry(
        label: 'Code editor',
        subLabel: 'Syntax highlighted',
        icon: Icons.code,
        template: {
          r'$': 'field',
          r'$type': 'code',
          'name': 'source',
          'label': 'Source',
          'language': 'c',
          'default': '',
        },
      ),
      const _UiPaletteEntry(
        label: 'Log view',
        subLabel: 'Append-only list',
        icon: Icons.description,
        template: {
          r'$': 'field',
          r'$type': 'log',
          'name': 'output',
          'label': 'Output',
        },
      ),
      const _UiPaletteEntry(
        label: 'Icon picker',
        subLabel: 'Emoji or SVG',
        icon: Icons.image,
        template: {
          r'$': 'field',
          r'$type': 'icon',
          'name': 'icon',
          'label': 'Icon',
          'default': '',
        },
      ),
    ];
  }

  /// Produce per-attribute editor widgets for [block]. Skips
  /// `children` (edited via drag-drop) and uses typed widgets for
  /// known attribute shapes.
  List<Widget> _uiInspectorFields(Map<String, dynamic> block) {
    final widgets = <Widget>[];
    final keys = [
      for (final k in block.keys)
        if (k != 'children') k
    ];
    for (final key in keys) {
      final v = block[key];
      widgets.add(_uiInspectorField(key, v));
    }
    return widgets;
  }

  /// Shortcut used by the Translations tab's Save button. Fires the
  /// same `_handleInstall` path the Code tab's Install action uses,
  /// so every `lang/<locale>.json` sidecar lands on disk without the
  /// author having to switch tabs. The payload fields are drawn
  /// directly from the current bindings (title, id, name,
  /// description, source_ui) so the installer's downstream logic
  /// sees exactly the same inputs.
  Future<void> _translationsSaveToDisk() async {
    final id = (_fieldValues['wapp_id'] as String?) ?? '';
    if (id.isEmpty) {
      NotificationService.instance.show(GeogramNotification(
        level: NotificationLevel.error,
        title: 'Cannot save translations',
        body: 'Open or create a project first (ID is empty).',
        source: 'host:app-creator',
      ));
      return;
    }
    await _handleInstall(<String, dynamic>{
      'id': id,
      'title': (_fieldValues['wapp_title'] as String?) ?? '',
      'name': (_fieldValues['wapp_name'] as String?) ?? '',
      'description':
          (_fieldValues['wapp_description'] as String?) ?? '',
      'source_ui': (_fieldValues['source_ui'] as String?) ?? '',
    });
  }

  /// Access (or lazily create) the nested translations map inside
  /// `_fieldValues`. Returns a live reference so mutations persist
  /// without a manual writeback.
  Map<String, Map<String, String>> _translationsMap() {
    var existing = _fieldValues['translations'];
    if (existing is Map<String, Map<String, String>>) return existing;
    // Be tolerant of stale shapes: rebuild from scratch with a
    // proper typed map if the binding was seeded as plain dynamic
    // (e.g. by JSON deserialisation of a loaded project).
    final next = <String, Map<String, String>>{};
    if (existing is Map) {
      for (final e in existing.entries) {
        final loc = e.key.toString();
        final raw = e.value;
        if (raw is Map) {
          final inner = <String, String>{};
          for (final kv in raw.entries) {
            inner[kv.key.toString()] = kv.value?.toString() ?? '';
          }
          next[loc] = inner;
        }
      }
    }
    _fieldValues['translations'] = next;
    return next;
  }

  Future<void> _translationsAddLocale() async {
    final controller = TextEditingController();
    final locale = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add locale'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Short tag, e.g. en, pt, de, fr, pt_BR.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Locale code',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (locale == null || locale.isEmpty) return;
    final map = _translationsMap();
    if (map.containsKey(locale)) {
      setState(() => _translationsLocale = locale);
      return;
    }
    // Seed the new locale with every key that already exists in
    // `en` (or in the first existing locale) so the author has a
    // sensible starting point instead of an empty table.
    final seed = map['en'] ?? (map.isNotEmpty ? map.values.first : null);
    final fresh = <String, String>{};
    if (seed != null) {
      for (final k in seed.keys) {
        fresh[k] = '';
      }
    }
    map[locale] = fresh;
    setState(() => _translationsLocale = locale);
  }

  Future<void> _translationsAddKey(String locale) async {
    final controller = TextEditingController();
    final key = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add translation key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Dot-separated name like `settings.title_label`. '
              'The UI refers to it as `@settings.title_label`.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Key',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (key == null || key.isEmpty) return;
    final map = _translationsMap();
    // Add the key to EVERY locale so the row shows up everywhere.
    // Empty value for locales that don't have it yet.
    for (final loc in map.keys) {
      map[loc]!.putIfAbsent(key, () => '');
    }
    // Seed into the active locale too if the map was empty.
    map.putIfAbsent(locale, () => <String, String>{})[key] ??= '';
    setState(() {});
  }

  /// Walk [screen] along [path] and return the leaf block (mutable
  /// reference into the dynamic tree). Returns null when any index
  /// runs off the end of its parent's `children` array.
  Map<String, dynamic>? _uiLookup(
      Map<String, dynamic> screen, List<int> path) {
    dynamic current = screen;
    for (final i in path) {
      if (current is! Map) return null;
      final kids = current['children'];
      if (kids is! List || i < 0 || i >= kids.length) return null;
      current = kids[i];
    }
    return current is Map<String, dynamic> ? current : null;
  }

  /// Pick a representative Material icon for a block keyword+type so
  /// the tree rows have a quick visual anchor. Keyword wins when
  /// there is no specific type override.
  IconData _uiIconForBlock(String keyword, String type) {
    final kwLower = keyword.toLowerCase();
    final typeLower = type.toLowerCase();
    if (kwLower == 'screen') return Icons.web;
    if (kwLower == 'group') {
      if (typeLower == 'projects') return Icons.folder_open;
      if (typeLower == 'tasks') return Icons.task_alt;
      if (typeLower == 'map') return Icons.map;
      if (typeLower == 'output') return Icons.receipt_long;
      if (typeLower == 'sources') return Icons.cloud;
      if (typeLower == 'ui-editor') return Icons.account_tree;
      return Icons.folder_special;
    }
    if (kwLower == 'field') {
      if (typeLower == 'code') return Icons.code;
      if (typeLower == 'log') return Icons.description;
      if (typeLower == 'icon') return Icons.image;
      if (typeLower == 'bool') return Icons.toggle_on;
      if (typeLower == 'int' || typeLower == 'float') return Icons.numbers;
      if (typeLower == 'enum') return Icons.list;
      return Icons.text_fields;
    }
    if (kwLower == 'action') return Icons.smart_button;
    if (kwLower == 'label') return Icons.label;
    return Icons.widgets;
  }
}

// ── Tests panel ──────────────────────────────────────────────────────
//
// The editor's Tests tab. Discovers WAPP_TEST cases from the edited
// wapp's tests/*.c, shows them with enable toggles + result badges,
// edits the selected file, and runs the suite by compiling tests.wasm
// (via the compiler backend) and invoking module_run_tests on a
// headless WappEngine, parsing the tests.case / tests.complete stream.

class _DiscoveredTest {
  final String file; // relative, e.g. tests/test_aprs.c
  final String name;
  const _DiscoveredTest(this.file, this.name);
}

class _CaseResult {
  final bool? passed; // null = not run yet
  final bool skipped;
  final String error;
  const _CaseResult({this.passed, this.skipped = false, this.error = ''});
}

class _TestsPanel extends StatefulWidget {
  final String wappDir;
  const _TestsPanel({super.key, required this.wappDir});

  @override
  State<_TestsPanel> createState() => _TestsPanelState();
}

class _TestsPanelState extends State<_TestsPanel> {
  late final ProfileStorage _pkg;
  final List<String> _files = []; // tests/*.c relative paths
  final List<_DiscoveredTest> _cases = [];
  final Set<String> _disabled = {};
  final Map<String, _CaseResult> _results = {};
  String? _selectedFile;
  String _editorText = '';
  final List<String> _log = []; // streamed messages + results
  final ScrollController _logScroll = ScrollController();
  bool _loaded = false;
  bool _running = false;
  int _passed = 0, _failed = 0, _skipped = 0;
  bool _ran = false;

  @override
  void initState() {
    super.initState();
    _pkg = wappPackageStorage(widget.wappDir);
    _discover();
  }

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  void _logLine(String s) {
    _log.add(s);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _discover() async {
    final files = <String>[];
    final cases = <_DiscoveredTest>[];
    if (await _pkg.directoryExists('tests')) {
      final entries = await _pkg.listDirectory('tests');
      for (final e in entries) {
        if (e.isDirectory) continue;
        final n = e.name;
        if (!n.startsWith('test_') || !n.endsWith('.c')) continue;
        final rel = 'tests/$n';
        files.add(rel);
        final src = await _pkg.readString(rel) ?? '';
        for (final m
            in RegExp(r'WAPP_TEST\(\s*(\w+)\s*\)').allMatches(src)) {
          cases.add(_DiscoveredTest(rel, m.group(1)!));
        }
      }
    }
    final disabled = <String>{};
    final dj = await _pkg.readString('tests/disabled.json');
    if (dj != null) {
      try {
        for (final x in jsonDecode(dj) as List) {
          disabled.add(x.toString());
        }
      } catch (_) {}
    }
    files.sort();
    if (!mounted) return;
    setState(() {
      _files
        ..clear()
        ..addAll(files);
      _cases
        ..clear()
        ..addAll(cases);
      _disabled
        ..clear()
        ..addAll(disabled);
      _selectedFile = files.isNotEmpty ? files.first : null;
      _loaded = true;
    });
    if (_selectedFile != null) _loadFile(_selectedFile!);
  }

  Future<void> _loadFile(String rel) async {
    final text = await _pkg.readString(rel) ?? '';
    if (!mounted) return;
    setState(() {
      _selectedFile = rel;
      _editorText = text;
    });
  }

  Future<void> _saveFile() async {
    final rel = _selectedFile;
    if (rel == null) return;
    await _pkg.writeString(rel, _editorText);
    if (!mounted) return;
    setState(() => _logLine('saved $rel'));
  }

  Future<void> _toggle(String name, bool enabled) async {
    setState(() {
      if (enabled) {
        _disabled.remove(name);
      } else {
        _disabled.add(name);
      }
    });
    await _pkg.writeString('tests/disabled.json', jsonEncode(_disabled.toList()));
  }

  Future<void> _run({bool liveOnly = false}) async {
    if (_running || _files.isEmpty) return;
    setState(() {
      _running = true;
      _ran = false;
      _results.clear();
      _log.clear();
      _logLine(liveOnly
          ? '── Run live (talks to APRS-IS; UI may freeze briefly) ──'
          : '── Run tests ──');
      _logLine('compiling ${_files.length} file(s)…');
    });
    // Persist any in-editor changes so the build sees them.
    if (_selectedFile != null) await _pkg.writeString(_selectedFile!, _editorText);

    final srcs = _files.map((f) => _pkg.getAbsolutePath(f)).toList();
    final res = await WappCompilerService.instance
        .compileTests(testSources: srcs, workStorage: _pkg);
    if (!res.ok) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _logLine('COMPILE FAILED (${res.error ?? "error"})');
        for (final l in (res.stderr + '\n' + res.stdout).split('\n')) {
          if (l.trim().isNotEmpty) _logLine(l);
        }
      });
      return;
    }
    setState(() => _logLine(
        'compiled tests.wasm (${res.wasmBytes!.length} bytes) in ${res.durationMs}ms'));

    // The quick run skips the live (network) case; "Run live" skips the
    // rest. User checkbox-disabled cases are always skipped too.
    final auto = <String>{};
    for (final c in _cases) {
      final isLive = c.name.startsWith('live_');
      if (liveOnly ? !isLive : isLive) auto.add(c.name);
    }
    final csv = (<String>{..._disabled, ...auto}).join(',');

    final messages = <String>[];
    final engine = WappEngine();
    try {
      await engine.load(res.wasmBytes!);
      engine.kvSet('test.disabled', csv);
      engine.runTests();
      messages.addAll(engine.drainOutbox());
    } catch (e) {
      messages.add('{"type":"error","msg":"$e"}');
    } finally {
      engine.dispose();
    }

    final results = <String, _CaseResult>{};
    int p = 0, f = 0, s = 0;
    final lines = <String>[];
    for (final raw in messages) {
      try {
        final d = jsonDecode(raw) as Map<String, dynamic>;
        switch (d['type']) {
          case 'tests.case':
            final nm = d['name']?.toString() ?? '';
            final sk = d['skipped'] == true;
            final ps = d['passed'] == true;
            final er = d['error']?.toString() ?? '';
            results[nm] = _CaseResult(passed: ps, skipped: sk, error: er);
            final mark = sk ? '⊘ skip' : (ps ? '✓ pass' : '✗ FAIL');
            lines.add('$mark  $nm${(!ps && !sk && er.isNotEmpty) ? "  — $er" : ""}');
            break;
          case 'tests.log': // evidence emitted by a test (e.g. live data)
            lines.add('    ${d['text'] ?? ''}');
            break;
          case 'tests.complete':
            p = (d['passed'] as num?)?.toInt() ?? 0;
            f = (d['failed'] as num?)?.toInt() ?? 0;
            s = (d['skipped'] as num?)?.toInt() ?? 0;
            break;
          case 'error':
            lines.add('runner error: ${d['msg']}');
            break;
        }
      } catch (_) {
        lines.add(raw); // show anything unparseable verbatim
      }
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _ran = true;
      _results
        ..clear()
        ..addAll(results);
      _passed = p;
      _failed = f;
      _skipped = s;
      for (final l in lines) _logLine(l);
      _logLine('── done: ✓$p  ✗$f  ⊘$s ──');
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_cases.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No tests found.\nAdd tests/test_*.c with WAPP_TEST(name) cases.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 340, child: _buildList(cs)),
              const VerticalDivider(width: 1),
              Expanded(child: _buildEditor(cs)),
            ],
          ),
        ),
        const Divider(height: 1),
        _buildLogWindow(cs),
      ],
    );
  }

  Widget _buildLogWindow(ColorScheme cs) {
    return Container(
      height: 200,
      width: double.infinity,
      color: const Color(0xFF0B0E13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                Icon(Icons.terminal, size: 15, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Text('TEST LOG',
                    style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurfaceVariant)),
                const Spacer(),
                if (_log.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear_all, size: 16),
                    tooltip: 'Clear log',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() => _log.clear()),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _log.isEmpty
                ? Center(
                    child: Text(
                        'Run a test to see messages and results here.',
                        style: TextStyle(
                            color: cs.onSurfaceVariant.withAlpha(150),
                            fontSize: 12)),
                  )
                : Scrollbar(
                    controller: _logScroll,
                    child: ListView.builder(
                      controller: _logScroll,
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                      itemCount: _log.length,
                      itemBuilder: (context, i) {
                        final line = _log[i];
                        Color c = Colors.white70;
                        if (line.startsWith('✓')) c = const Color(0xFF66BB6A);
                        else if (line.startsWith('✗') ||
                            line.contains('FAIL')) c = const Color(0xFFE57373);
                        else if (line.startsWith('⊘')) c = const Color(0xFFFFB74D);
                        else if (line.startsWith('──')) c = cs.primary;
                        else if (line.startsWith('    ')) c = const Color(0xFF7FB0E0);
                        return Text(line,
                            style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.4,
                                color: c));
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(ColorScheme cs) {
    final items = <Widget>[];
    items.add(Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FilledButton.icon(
                onPressed: _running ? null : () => _run(),
                icon: _running
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.play_arrow, size: 18),
                label: const Text('Run tests'),
              ),
              if (_cases.any((c) => c.name.startsWith('live_'))) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _running ? null : () => _run(liveOnly: true),
                  icon: const Icon(Icons.public, size: 18),
                  label: const Text('Run live'),
                ),
              ],
            ],
          ),
          if (_ran)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 2),
              child: _summaryChip(cs),
            ),
        ],
      ),
    ));

    for (final file in _files) {
      final base = file.split('/').last;
      items.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: Text(base.toUpperCase(),
            style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant)),
      ));
      for (final c in _cases.where((c) => c.file == file)) {
        final enabled = !_disabled.contains(c.name);
        final r = _results[c.name];
        items.add(InkWell(
          onTap: () => _loadFile(file),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            child: Row(
              children: [
                Checkbox(
                  value: enabled,
                  visualDensity: VisualDensity.compact,
                  onChanged: (v) => _toggle(c.name, v ?? true),
                ),
                _badge(r, enabled),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    c.name,
                    style: TextStyle(
                      fontSize: 13,
                      color: enabled ? cs.onSurface : cs.onSurfaceVariant,
                      decoration:
                          enabled ? null : TextDecoration.lineThrough,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ));
        if (r != null && r.passed == false && !r.skipped && r.error.isNotEmpty) {
          items.add(Padding(
            padding: const EdgeInsets.fromLTRB(56, 0, 12, 4),
            child: Text(r.error,
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFFE57373), height: 1.3)),
          ));
        }
      }
    }
    return ListView(children: items);
  }

  Widget _summaryChip(ColorScheme cs) {
    return Row(children: [
      Text('✓$_passed',
          style: const TextStyle(
              color: Color(0xFF66BB6A), fontWeight: FontWeight.bold)),
      const SizedBox(width: 8),
      Text('✗$_failed',
          style: TextStyle(
              color: _failed > 0 ? const Color(0xFFE57373) : cs.onSurfaceVariant,
              fontWeight: FontWeight.bold)),
      const SizedBox(width: 8),
      Text('⊘$_skipped', style: TextStyle(color: cs.onSurfaceVariant)),
    ]);
  }

  Widget _badge(_CaseResult? r, bool enabled) {
    if (!enabled) return const Text('⊘', style: TextStyle(color: Colors.orange));
    if (r == null) {
      return const SizedBox(width: 14, child: Text('—', textAlign: TextAlign.center));
    }
    if (r.skipped) return const Text('⊘', style: TextStyle(color: Colors.orange));
    if (r.passed == true) {
      return const Icon(Icons.check_circle, size: 14, color: Color(0xFF66BB6A));
    }
    return const Icon(Icons.cancel, size: 14, color: Color(0xFFE57373));
  }

  Widget _buildEditor(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.science_outlined, size: 16, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_selectedFile ?? 'No file',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              FilledButton.icon(
                onPressed: _selectedFile == null ? null : _saveFile,
                icon: const Icon(Icons.save, size: 18),
                label: const Text('Save'),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: _selectedFile == null
                ? const Center(child: Text('Select a test file'))
                : CodeEditorField(
                    key: ValueKey('testfile-$_selectedFile'),
                    fieldName: 'testfile',
                    label: '',
                    languageId: 'c',
                    initialValue: _editorText,
                    expand: true,
                    onChanged: (v) => _editorText = v,
                  ),
          ),
        ),
      ],
    );
  }
}
