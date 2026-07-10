part of 'launcher.dart';

// ── Launcher ──────────────────────────────────────────────────────────

/// Wapps that are installed but temporarily hidden from the grid (their
/// implementation isn't finished yet). Folder names, matched during the scan.
const Set<String> _kHiddenWapps = {'maps', 'atm', 'wallet'};

/// Outcome of the unmet-dependency dialog shown before launching a wapp.
enum _DepAction { cancel, openAnyway, install }

class LauncherPage extends StatefulWidget {
  const LauncherPage({super.key});

  @override
  State<LauncherPage> createState() => _LauncherPageState();
}

class _LauncherPageState extends State<LauncherPage> {
  List<WappManifest>? _wapps;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    _scanArchive();
    _maybeRequestBatteryExemption();
    // Re-scan whenever the user switches profiles so the grid
    // reflects the new profile's apps/ folder. storage_paths.dart
    // already routes through the active profile, so just triggering
    // a rescan is enough.
    ProfileService.instance.activeProfileNotifier.addListener(
      _onProfileChanged,
    );
  }

  @override
  void dispose() {
    ProfileService.instance.activeProfileNotifier.removeListener(
      _onProfileChanged,
    );
    super.dispose();
  }

  void _onProfileChanged() {
    setState(() => _wapps = null);
    _scanArchive();
  }

  // One-time prompt to exempt the app from Android battery optimization, so the
  // always-on background service (APRS-IS + Blossom/seed servers) survives deep
  // sleep on aggressive OEMs. Asked once; the user can re-enable in settings.
  Future<void> _maybeRequestBatteryExemption() async {
    final prefs = await PreferencesService.instance();
    if (prefs.batteryExemptionAsked) return;
    if (await BatteryOptimization.isExempt()) return;
    await prefs.setBatteryExemptionAsked(true);
    await BatteryOptimization.requestExemption();
  }

  Future<void> _scanArchive() async {
    // Wrap the scan in the task monitor so its startup time and any
    // failures are visible in the same place as every other startup
    // step. This is the canonical "template process method" pattern —
    // every startup task should go through runMonitoredStartup.
    await runMonitoredStartup(
      'launcher.scan',
      'Scan installed wapps',
      _scanArchiveBody,
      description:
          'Reads the in-repo install wapp + every installed-apps '
          'subdirectory and parses their manifest.json',
    );
    if (_wapps != null) {
      EventBus().fire(AppStartedEvent());
    }
  }

  Future<void> _scanArchiveBody() async {
    // The grid shows ONLY wapps installed in the active profile. The
    // default set is installed once at boot by [ensureProfileSeeded];
    // the shared ../wapps library is the catalog, never shown directly.
    final wapps = <WappManifest>[];
    final seen = <String>{};

    final installed = installedAppsStorage();
    if (await installed.directoryExists('')) {
      final entries = await installed.listDirectory('');
      for (final entry in entries) {
        if (!entry.isDirectory) continue;
        // The wapp editor is never a grid tile — it's the built-in editor
        // reached via each wapp's Edit action. Skip it here too so legacy
        // profiles that seeded it into wapps/ don't surface it.
        if (entry.name == 'app-creator') continue;
        // Temporarily hidden wapps (unfinished) — kept out of the grid even on
        // profiles that already have them installed.
        if (_kHiddenWapps.contains(entry.name)) continue;
        final pkg = wappPackageStorage(installed.getAbsolutePath(entry.path));
        await _scanManifest(pkg, wapps, seen);
      }
    }

    // Rebuild the widget registry from the fresh scan. Wapps that
    // got uninstalled since last scan stop appearing as providers;
    // newly installed ones immediately become available.
    FunctionalityRegistry.instance.clear();
    FunctionalityRegistry.instance.registerCore();
    for (final m in wapps) {
      FunctionalityRegistry.instance.register(m);
    }

    // Warm the SVG icon cache BEFORE the grid builds with these wapps. Each
    // read is a platform-channel round trip; hitting them all inside one
    // build frame was a one-shot ~700ms stall. One await per icon spreads
    // the reads across event-loop turns instead.
    for (final m in wapps) {
      final svg = m.svgIconPath;
      if (svg == null || svg.isEmpty) continue;
      await Future<void>.delayed(Duration.zero);
      _svgIconBytes(svg);
    }

    if (mounted) setState(() => _wapps = wapps);
  }

  Future<void> _scanManifest(
    ProfileStorage pkg,
    List<WappManifest> wapps,
    Set<String> seen,
  ) async {
    final json = await pkg.readJson('manifest.json');
    if (json == null) return;
    try {
      // Backfill signature on the fly when missing — phase 1 of the
      // wapp-signing plan. If the active profile has no nsec yet the
      // sign step is a no-op and publisherNpub stays empty. Signing
      // writes a `signature.json` sidecar into the wapp's directory
      // so built-ins (writable in dev checkouts) and user installs
      // (writable under the profile data dir) both get covered.
      var publisher = await WappSigningService.instance.readPublisherNpub(pkg);
      if (publisher.isEmpty && ProfileService.instance.activeProfile != null) {
        final wappId = (json['id'] as String?) ?? '';
        final wappVersion = (json['version'] as String?) ?? '1.0.0';
        if (wappId.isNotEmpty) {
          final ok = await WappSigningService.instance.signPackage(
            pkg,
            wappId: wappId,
            wappVersion: wappVersion,
          );
          if (ok) {
            publisher = await WappSigningService.instance.readPublisherNpub(
              pkg,
            );
          }
        }
      }
      final manifest = WappManifest.fromJson(
        json,
        pkg.basePath,
        publisherNpub: publisher,
      );
      // 'library' wapps have no UI and never appear on the grid (the
      // body filters by app/system/addon), but they MUST be scanned so
      // they register as providers in the FunctionalityRegistry and
      // count as installed when the resolver checks requires.libraries.
      const validKinds = {'app', 'system', 'addon', 'library'};
      if (validKinds.contains(manifest.kind) && seen.add(manifest.id)) {
        wapps.add(manifest);
      }
    } catch (_) {}
  }

  Future<void> _openWapp(
    WappManifest manifest, {
    String? initialView,
    Map<String, dynamic>? initialPost,
  }) async {
    // Install-driven dependency gate: if this wapp declares requires
    // that no installed wapp satisfies, prompt the user to install a
    // provider instead of letting it fail at runtime. The user can
    // still open it anyway (a missing optional dependency shouldn't
    // hard-block experimentation).
    final unmet = DependencyResolver.resolve(manifest, _wapps ?? const []);
    if (unmet.isNotEmpty) {
      final action = await _showDependencyDialog(manifest, unmet);
      if (action == null || action == _DepAction.cancel) return;
      if (action == _DepAction.install) {
        _openStore();
        return;
      }
      // _DepAction.openAnyway falls through to the normal launch.
    }
    if (!mounted) return;
    // Opening clears the tile's unread badge; the wapp re-publishes its live
    // count (from its conversation stores) once it's running. Count a launch
    // only after dependency gating has actually allowed navigation.
    final wappId = BackgroundWappManager.folderName(manifest.dirPath);
    WappUnreadService.instance.clearAll(wappId);
    await LaunchCountStore.instance.increment(wappId);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WappPage(
          wappDir: manifest.dirPath,
          title: manifest.title.isNotEmpty ? manifest.title : manifest.name,
          initialView: initialView,
          initialPost: initialPost,
        ),
      ),
    );
    _scanArchive(); // Rescan after returning (new installs)
  }

  Future<void> _openWappIntent(String intent) async {
    final normalized = intent.trim().toLowerCase();
    final manifest = _wappForIntent(normalized);
    if (manifest == null) return;
    await _openWapp(manifest, initialView: normalized);
  }

  /// Hero-card tap: open the post's thread in whatever wapp declares the
  /// `social` intent. No-op when none is installed — the card is then just a
  /// headline.
  Future<void> _openNoveltyPost(NoveltyItem item) async {
    if (item.id.isEmpty) return;
    final manifest = _wappForIntent('social');
    if (manifest == null) return;
    // Hand the post we already hold to the wapp page, so the thread opens
    // instantly with the hero's content instead of waiting for the wapp to
    // re-download it. Same row shape the activity archive emits; 'from' is
    // the 12-char pubkey prefix the feed uses to key author profiles.
    await _openWapp(
      manifest,
      initialView: 'post:${item.id}',
      initialPost: {
        't': item.createdAt.millisecondsSinceEpoch,
        'dir': 'in',
        'from': item.authorPubkey.length >= 12
            ? item.authorPubkey.substring(0, 12)
            : item.authorPubkey,
        'text': item.rawText,
        'kind': 'msg',
        'mid': item.id,
        'parent': '',
        'time': '',
        'pop': 0,
      },
    );
  }

  WappManifest? _wappForIntent(String intent) {
    final wapps = _wapps;
    if (wapps == null) return null;
    final normalized = intent.trim().toLowerCase();
    for (final w in wapps) {
      if (w.kind == 'library') continue;
      if (w.providedIntents.contains(normalized)) return w;
    }
    return null;
  }

  /// Open the built-in editor focused on [wapp] (the per-tile "Edit" action).
  /// Pushes the App Creator package (installed at boot to its own location,
  /// outside the grid) with [WappPage.editWappDir] set so it auto-loads this
  /// wapp and skips the Projects picker.
  Future<void> _editWapp(WappManifest wapp) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WappPage(
          wappDir: editorWappDirPath(),
          title: 'App Creator',
          editWappDir: wapp.dirPath,
        ),
      ),
    );
    _scanArchive(); // Rescan after returning (edits may change metadata)
  }

  /// Open the Wapp Store (the `install` wapp) so the user can install a
  /// provider for a missing dependency. Falls back to a snackbar if the
  /// store wapp itself isn't present.
  void _openStore() {
    final store = _wapps?.where(
      (w) => w.id == 'tools.geogram.install' || w.name == 'install',
    );
    final installWapp = (store != null && store.isNotEmpty)
        ? store.first
        : null;
    if (installWapp == null) {
      rootMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Wapp Store is not installed')),
      );
      return;
    }
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => WappPage(
              wappDir: installWapp.dirPath,
              title: installWapp.title.isNotEmpty
                  ? installWapp.title
                  : installWapp.name,
            ),
          ),
        )
        .then((_) => _scanArchive());
  }

  Future<_DepAction?> _showDependencyDialog(
    WappManifest manifest,
    UnmetDependencies unmet,
  ) {
    final cs = Theme.of(context).colorScheme;
    Widget section(String label, List<String> items) {
      if (items.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              color: cs.primary,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          for (final id in items)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Text(
                '• $id',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
        ],
      );
    }

    return showDialog<_DepAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${manifest.title} needs more'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This wapp depends on capabilities that no installed wapp '
              'provides yet. Install a provider from the Wapp Store, or '
              'open it anyway.',
            ),
            section('Functionalities', unmet.functionalities),
            section('Libraries', unmet.libraries),
            section('Runtime (HAL)', unmet.hal),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _DepAction.cancel),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _DepAction.openAnyway),
            child: const Text('Open anyway'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _DepAction.install),
            child: const Text('Install…'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      drawer: _AppDrawer(
        onSettings: () async {
          Navigator.of(context).pop();
          await Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const IwiSettingsPage()));
        },
      ),
      appBar: _HomeHeader(
        onMenu: () => _scaffoldKey.currentState?.openDrawer(),
        onNotifications: () {
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const NotificationsPage()));
        },
        messagesWapp: _wappForIntent('messages'),
        chatWapp: _wappForIntent('chat'),
        onMessages: () => _openWappIntent('messages'),
        onChat: () => _openWappIntent('chat'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_wapps == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final entries = _launcherEntries();

    if (entries.isEmpty) {
      return const Center(
        child: Text('No wapps found', style: TextStyle(color: Colors.grey)),
      );
    }

    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 180),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _NoveltiesCarousel(onOpenItem: _openNoveltyPost),
              const SizedBox(height: 20),
              _ModuleBars(entries: entries),
            ],
          ),
        ),
        _AllAppsSheet(entries: entries),
      ],
    );
  }

  List<_LauncherEntry> _launcherEntries() {
    final wapps = _wapps ?? const <WappManifest>[];
    final apps = wapps.where((w) => w.kind == 'app').toList();
    final systemWapps = wapps.where((w) => w.kind == 'system').toList();
    final addonWapps = wapps.where((w) => w.kind == 'addon').toList();

    return <_LauncherEntry>[
      for (final wapp in apps)
        _LauncherEntry(
          name: wapp.title.isNotEmpty ? wapp.title : wapp.name,
          icon: wapp.iconData,
          textIcon: wapp.textIcon,
          svgIconPath: wapp.svgIconPath,
          color: wapp.color,
          modified: wapp.userModified,
          onTap: () => _openWapp(wapp),
          onEdit: () => _editWapp(wapp),
          wappId: BackgroundWappManager.folderName(wapp.dirPath),
          wappDir: wapp.dirPath,
          subtitle: wapp.description.isNotEmpty
              ? wapp.description
              : wapp.summary,
        ),
      if (systemWapps.isNotEmpty)
        _LauncherEntry(
          name: 'System',
          icon: Icons.settings_applications,
          color: const Color(0xFF37474F),
          onTap: () => _openFolder('System', systemWapps),
        ),
      if (addonWapps.isNotEmpty)
        _LauncherEntry(
          name: 'Addons',
          icon: Icons.extension,
          color: const Color(0xFF4E342E),
          onTap: () => _openFolder('Addons', addonWapps),
        ),
    ];
  }

  void _openFolder(String title, List<WappManifest> wapps) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => _FolderPage(
              title: title,
              wapps: wapps,
              onOpenWapp: _openWapp,
              onEditWapp: _editWapp,
            ),
          ),
        )
        .then((_) => _scanArchive());
  }
}

/// Wapp SVG icon bytes, read once per path. The tiles used to hit the disk on
/// EVERY build — a sheet drag rebuilds the whole grid each frame, and the
/// repeated synchronous reads were the launcher's biggest build-time stall
/// (frames >700ms in the perf log). Icons don't change while installed; an
/// install/edit goes through a rescan which can keep serving the same bytes.
final Map<String, Uint8List?> _svgIconCache = {};

Uint8List? _svgIconBytes(String path) => _svgIconCache.putIfAbsent(path, () {
      final raw = platform.readArbitraryFileBytesSync(path);
      return raw == null ? null : Uint8List.fromList(raw);
    });

class _LauncherEntry {
  final String name;
  final IconData icon;
  final String? textIcon;
  final String? svgIconPath;
  final Color color;
  final VoidCallback onTap;

  /// True when this tile is a wapp the user customized via the App
  /// Creator — the tile shows a small "edited" badge.
  final bool modified;

  /// "Edit" action for the tile's context menu; null for folder tiles.
  final VoidCallback? onEdit;

  /// Wapp identity for the "run in background" context-menu toggle; null for
  /// folder tiles.
  final String? wappId;
  final String? wappDir;

  /// One-line explanation shown under the name on the home module bars. Empty
  /// for folder tiles and for wapps whose manifest carries no description.
  final String subtitle;

  const _LauncherEntry({
    required this.name,
    required this.icon,
    required this.color,
    required this.onTap,
    this.textIcon,
    this.svgIconPath,
    this.modified = false,
    this.onEdit,
    this.wappId,
    this.wappDir,
    this.subtitle = '',
  });
}

/// Sub-page for System / Addons folder tiles. Shows the same grid
/// layout as the main launcher, filtered to one category.
class _FolderPage extends StatelessWidget {
  final String title;
  final List<WappManifest> wapps;
  final void Function(WappManifest) onOpenWapp;
  final void Function(WappManifest) onEditWapp;

  const _FolderPage({
    required this.title,
    required this.wapps,
    required this.onOpenWapp,
    required this.onEditWapp,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 120,
            mainAxisSpacing: 20,
            crossAxisSpacing: 20,
          ),
          itemCount: wapps.length,
          itemBuilder: (context, index) {
            final wapp = wapps[index];
            return _AppIcon(
              name: wapp.title.isNotEmpty ? wapp.title : wapp.name,
              icon: wapp.iconData,
              textIcon: wapp.textIcon,
              svgIconPath: wapp.svgIconPath,
              color: wapp.color,
              modified: wapp.userModified,
              onTap: () => onOpenWapp(wapp),
              onEdit: () => onEditWapp(wapp),
              wappId: BackgroundWappManager.folderName(wapp.dirPath),
              wappDir: wapp.dirPath,
            );
          },
        ),
      ),
    );
  }
}

/// Compact AppBar title showing the active profile's display name
/// with a popup menu to switch to any other profile or add a new one.
/// Listens directly to [ProfileService.instance.activeProfileNotifier]
/// so the label updates the instant `switchTo` fires.
class _ProfileSwitcher extends StatefulWidget {
  const _ProfileSwitcher();

  @override
  State<_ProfileSwitcher> createState() => _ProfileSwitcherState();
}

class _ProfileSwitcherState extends State<_ProfileSwitcher> {
  @override
  void initState() {
    super.initState();
    ProfileService.instance.activeProfileNotifier.addListener(_refresh);
    // revision fires on in-place edits (nickname/avatar/colour) too.
    ProfileService.instance.revision.addListener(_refresh);
  }

  @override
  void dispose() {
    ProfileService.instance.activeProfileNotifier.removeListener(_refresh);
    ProfileService.instance.revision.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _editProfileFlow(IwiProfile p) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => ProfileEditPage(profile: p)));
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _addProfileFlow() async {
    // Push the welcome page as a modal to generate / import another
    // profile. canCancel adds a back arrow and leaves the user inside the
    // current profile if they bail out.
    //
    // Capture the Navigator BEFORE the await: on completion the WelcomePage
    // calls saveAndActivate, which flips activeProfileNotifier and rebuilds
    // the launcher's home subtree under a NEW profile-id key — deactivating
    // THIS page's context. Popping via `Navigator.of(context)` inside the
    // onComplete callback would then look up a deactivated widget and throw
    // (the "something was null" error the user saw, even though the profile
    // had already been saved). The Navigator state itself survives the
    // rebuild, so hold a direct reference and pop through that.
    final navigator = Navigator.of(context);
    await navigator.push(
      MaterialPageRoute(
        builder: (_) => WelcomePage(
          canCancel: true,
          onComplete: () {
            if (navigator.canPop()) navigator.pop();
          },
        ),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = ProfileService.instance;
    final active = service.activeProfile;
    // "Nickname (CALLSIGN)" when a nickname is set, otherwise just the
    // callsign — never "CALLSIGN (CALLSIGN)" (displayName falls back to the
    // callsign when there's no nickname).
    final label = active == null
        ? 'No profile'
        : (active.nickname.trim().isNotEmpty
              ? '${active.nickname.trim()} (${active.callsign})'
              : active.callsign);
    final cs = Theme.of(context).colorScheme;

    return PopupMenuButton<String>(
      tooltip: 'Switch profile',
      offset: const Offset(0, 40),
      onSelected: (value) async {
        if (value == '__add__') {
          await _addProfileFlow();
        } else if (value == '__edit__') {
          if (active != null) await _editProfileFlow(active);
        } else {
          await service.switchTo(value);
        }
      },
      itemBuilder: (ctx) => [
        for (final p in service.profiles)
          PopupMenuItem<String>(
            value: p.id,
            child: Row(
              children: [
                ProfileAvatar(profile: p, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        p.displayName,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      // Only show the callsign sub-line when a nickname is set,
                      // so a profile without one isn't listed as "X1ABCD" twice.
                      if (p.nickname.trim().isNotEmpty)
                        Text(
                          p.callsign,
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurfaceVariant,
                            fontFamily: 'monospace',
                          ),
                        ),
                    ],
                  ),
                ),
                if (p.id == active?.id)
                  Icon(Icons.check, size: 18, color: cs.primary),
              ],
            ),
          ),
        const PopupMenuDivider(),
        if (active != null)
          const PopupMenuItem<String>(
            value: '__edit__',
            child: Row(
              children: [
                Icon(Icons.edit, size: 18),
                SizedBox(width: 8),
                Text('Edit profile…'),
              ],
            ),
          ),
        const PopupMenuItem<String>(
          value: '__add__',
          child: Row(
            children: [
              Icon(Icons.person_add, size: 18),
              SizedBox(width: 8),
              Text('Add profile…'),
            ],
          ),
        ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (active != null)
            ProfileAvatar(profile: active, size: 26)
          else
            Icon(Icons.badge, size: 20, color: cs.primary),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const Icon(Icons.arrow_drop_down, size: 20),
        ],
      ),
    );
  }
}

class _AppIcon extends StatelessWidget {
  final String name;
  final IconData icon;
  final String? textIcon;
  final String? svgIconPath;
  final Color color;
  final VoidCallback onTap;
  final bool modified;

  /// Long-press / right-click "Edit" action — opens this wapp in the
  /// built-in editor. Null for tiles that aren't editable (folders).
  final VoidCallback? onEdit;

  /// Wapp identity for the "run in background" context-menu toggle. Folder
  /// name (autostart key) + package dir. Null for folder tiles.
  final String? wappId;
  final String? wappDir;

  const _AppIcon({
    required this.name,
    required this.icon,
    required this.color,
    required this.onTap,
    this.textIcon,
    this.svgIconPath,
    this.modified = false,
    this.onEdit,
    this.wappId,
    this.wappDir,
  });

  /// Show the tile context menu (Open / Edit / pin / autostart) at the pointer.
  /// Wapp tiles always get a menu — pinning to the home bars or the dock needs
  /// only a [wappId]. Folder tiles have neither [onEdit] nor [wappId] and stay
  /// plain tap-only.
  Future<void> _showContextMenu(BuildContext context, Offset globalPos) async {
    if (onEdit == null && wappId == null) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final prefs = PreferencesService.instanceSync;
    final canPin = wappId != null && prefs != null;
    final canAutostart = wappId != null && wappDir != null && prefs != null;
    final autostartOn = canAutostart && prefs.getWappAutostart(wappId!);
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPos & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: 'open',
          child: Row(
            children: [
              Icon(Icons.open_in_new, size: 18),
              SizedBox(width: 10),
              Text('Open'),
            ],
          ),
        ),
        if (onEdit != null)
          const PopupMenuItem(
            value: 'edit',
            child: Row(
              children: [
                Icon(Icons.edit, size: 18),
                SizedBox(width: 10),
                Text('Edit'),
              ],
            ),
          ),
        if (canPin) ..._homePinMenuItems(prefs, wappId!),
        if (canAutostart)
          PopupMenuItem(
            value: 'autostart',
            child: Row(
              children: [
                Icon(
                  autostartOn ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 18,
                ),
                const SizedBox(width: 10),
                const Text('Run in background'),
              ],
            ),
          ),
      ],
    );
    if (selected == 'open') onTap();
    if (selected == 'edit') onEdit?.call();
    if (canPin) await _applyHomePinChoice(selected, wappId!, prefs);
    if (selected == 'autostart' && canAutostart) {
      final enable = !autostartOn;
      await prefs.setWappAutostart(wappId!, enable);
      // Keep the on-boot auto-start flag in sync with the autostart config.
      await BackgroundWappManager.instance.syncBootAutostart(prefs);
      if (enable) {
        await BackgroundWappManager.instance.start(wappDir!);
      } else {
        BackgroundWappManager.instance.stop(wappId!);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Icon resolution order: SVG file (picked by the user in App
    // Creator and persisted as media/icons/icon.svg), then a short
    // text label (emoji / single char), then the Material icon
    // guess from [WappManifest.iconData]. All three cases render
    // as white glyphs inside the 56x56 coloured tile: SVGs get a
    // srcIn colour filter that repaints every non-transparent pixel
    // white (SVGs in the wild are authored in black or dark
    // strokes), and emoji glyphs — which ignore TextStyle.color
    // because they come from a colour font — are wrapped in a
    // ColorFiltered so their alpha mask is repainted white too.
    const whiteFilter = ColorFilter.mode(Colors.white, BlendMode.srcIn);
    final hasSvg = svgIconPath != null && svgIconPath!.isNotEmpty;
    final hasText = textIcon != null && textIcon!.isNotEmpty;
    // For the SVG case we read the bytes through the platform
    // helper and render via SvgPicture.memory, so the same code
    // path works on both desktop (real filesystem) and web (stub
    // returns null and we fall through to the Material icon).
    Uint8List? svgBytes;
    if (hasSvg) {
      svgBytes = _svgIconBytes(svgIconPath!);
    }
    Widget inner;
    if (svgBytes != null) {
      // Render custom SVGs with their original colors so the
      // author's design stays recognizable. Only the Material icon
      // fallback gets the white recolour.
      inner = Padding(
        padding: const EdgeInsets.all(8),
        child: SvgPicture.memory(
          svgBytes,
          fit: BoxFit.contain,
          theme: const SvgTheme(currentColor: Colors.white),
          placeholderBuilder: (_) => const SizedBox.shrink(),
        ),
      );
    } else if (hasText) {
      inner = ColorFiltered(
        colorFilter: whiteFilter,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              textIcon!,
              style: const TextStyle(
                fontSize: 32,
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
    } else {
      inner = Icon(icon, size: 28, color: Colors.white);
    }
    return GestureDetector(
      onSecondaryTapDown: onEdit == null
          ? null
          : (d) => _showContextMenu(context, d.globalPosition),
      onLongPressStart: onEdit == null
          ? null
          : (d) => _showContextMenu(context, d.globalPosition),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: inner,
                ),
                // "Edited by you" badge — a small pencil chip in the
                // top-right corner for wapps customized via App Creator.
                if (modified)
                  Positioned(
                    top: -4,
                    right: -4,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          width: 1.5,
                        ),
                      ),
                      child: const Icon(
                        Icons.edit,
                        size: 11,
                        color: Colors.white,
                      ),
                    ),
                  ),
                // Unread badge — a count chip (e.g. APRS messages) in the
                // top-right, driven by WappUnreadService and updated live.
                if (wappId != null)
                  Positioned(
                    top: -6,
                    right: -6,
                    child: ValueListenableBuilder<Map<String, int>>(
                      valueListenable: WappUnreadService.instance.counts,
                      builder: (context, counts, _) {
                        final n = WappUnreadService.instance.totalFor(wappId!);
                        if (n <= 0) return const SizedBox.shrink();
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          constraints: const BoxConstraints(minWidth: 18),
                          decoration: BoxDecoration(
                            color: const Color(0xFFda3633),
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(
                              color: Theme.of(context).scaffoldBackgroundColor,
                              width: 1.5,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            n > 99 ? '99+' : '$n',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              name,
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
