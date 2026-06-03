part of 'launcher.dart';

// ── Launcher ──────────────────────────────────────────────────────────

/// Outcome of the unmet-dependency dialog shown before launching a wapp.
enum _DepAction { cancel, openAnyway, install }

class LauncherPage extends StatefulWidget {
  const LauncherPage({super.key});

  @override
  State<LauncherPage> createState() => _LauncherPageState();
}

class _LauncherPageState extends State<LauncherPage> {
  List<WappManifest>? _wapps;

  @override
  void initState() {
    super.initState();
    _scanArchive();
    // Re-scan whenever the user switches profiles so the grid
    // reflects the new profile's apps/ folder. storage_paths.dart
    // already routes through the active profile, so just triggering
    // a rescan is enough.
    ProfileService.instance.activeProfileNotifier
        .addListener(_onProfileChanged);
  }

  @override
  void dispose() {
    ProfileService.instance.activeProfileNotifier
        .removeListener(_onProfileChanged);
    super.dispose();
  }

  void _onProfileChanged() {
    setState(() => _wapps = null);
    _scanArchive();
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
      description: 'Reads the in-repo install wapp + every installed-apps '
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

    if (mounted) setState(() => _wapps = wapps);
  }

  Future<void> _scanManifest(
      ProfileStorage pkg, List<WappManifest> wapps, Set<String> seen) async {
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
      if (publisher.isEmpty &&
          ProfileService.instance.activeProfile != null) {
        final wappId = (json['id'] as String?) ?? '';
        final wappVersion = (json['version'] as String?) ?? '1.0.0';
        if (wappId.isNotEmpty) {
          final ok = await WappSigningService.instance.signPackage(
            pkg,
            wappId: wappId,
            wappVersion: wappVersion,
          );
          if (ok) {
            publisher =
                await WappSigningService.instance.readPublisherNpub(pkg);
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

  Future<void> _openWapp(WappManifest manifest) async {
    // Install-driven dependency gate: if this wapp declares requires
    // that no installed wapp satisfies, prompt the user to install a
    // provider instead of letting it fail at runtime. The user can
    // still open it anyway (a missing optional dependency shouldn't
    // hard-block experimentation).
    final unmet =
        DependencyResolver.resolve(manifest, _wapps ?? const []);
    if (unmet.isNotEmpty) {
      final action = await _showDependencyDialog(manifest, unmet);
      if (action == _DepAction.cancel) return;
      if (action == _DepAction.install) {
        _openStore();
        return;
      }
      // _DepAction.openAnyway falls through to the normal launch.
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WappPage(
          wappDir: manifest.dirPath,
          title: manifest.title.isNotEmpty ? manifest.title : manifest.name,
        ),
      ),
    );
    _scanArchive(); // Rescan after returning (new installs)
  }

  /// Open the Wapp Store (the `install` wapp) so the user can install a
  /// provider for a missing dependency. Falls back to a snackbar if the
  /// store wapp itself isn't present.
  void _openStore() {
    final store = _wapps?.where((w) =>
        w.id == 'tools.geogram.install' || w.name == 'install');
    final installWapp = (store != null && store.isNotEmpty) ? store.first : null;
    if (installWapp == null) {
      rootMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Wapp Store is not installed')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WappPage(
          wappDir: installWapp.dirPath,
          title: installWapp.title.isNotEmpty
              ? installWapp.title
              : installWapp.name,
        ),
      ),
    ).then((_) => _scanArchive());
  }

  Future<_DepAction?> _showDependencyDialog(
      WappManifest manifest, UnmetDependencies unmet) {
    final cs = Theme.of(context).colorScheme;
    Widget section(String label, List<String> items) {
      if (items.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Text(label,
              style: TextStyle(
                  color: cs.primary, fontWeight: FontWeight.w600, fontSize: 13)),
          for (final id in items)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Text('• $id',
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12)),
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
                'open it anyway.'),
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
      appBar: AppBar(
        title: const _ProfileSwitcher(),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const IwiSettingsPage()),
              );
            },
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_wapps == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // Partition wapps by category.
    final apps = _wapps!.where((w) => w.kind == 'app').toList();
    final systemWapps = _wapps!.where((w) => w.kind == 'system').toList();
    final addonWapps = _wapps!.where((w) => w.kind == 'addon').toList();

    final entries = <_LauncherEntry>[
      for (final wapp in apps)
        _LauncherEntry(
          name: wapp.title.isNotEmpty ? wapp.title : wapp.name,
          icon: wapp.iconData,
          textIcon: wapp.textIcon,
          svgIconPath: wapp.svgIconPath,
          color: wapp.color,
          onTap: () => _openWapp(wapp),
        ),
      // Folder tiles at the end of the grid.
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

    if (entries.isEmpty) {
      return const Center(
        child: Text('No wapps found', style: TextStyle(color: Colors.grey)),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(24),
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 120,
          mainAxisSpacing: 20,
          crossAxisSpacing: 20,
        ),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final e = entries[index];
          return _AppIcon(
            name: e.name,
            icon: e.icon,
            textIcon: e.textIcon,
            svgIconPath: e.svgIconPath,
            color: e.color,
            onTap: e.onTap,
          );
        },
      ),
    );
  }

  void _openFolder(String title, List<WappManifest> wapps) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _FolderPage(
          title: title,
          wapps: wapps,
          onOpenWapp: _openWapp,
        ),
      ),
    ).then((_) => _scanArchive());
  }
}

class _LauncherEntry {
  final String name;
  final IconData icon;
  final String? textIcon;
  final String? svgIconPath;
  final Color color;
  final VoidCallback onTap;

  const _LauncherEntry({
    required this.name,
    required this.icon,
    required this.color,
    required this.onTap,
    this.textIcon,
    this.svgIconPath,
  });
}

/// Sub-page for System / Addons folder tiles. Shows the same grid
/// layout as the main launcher, filtered to one category.
class _FolderPage extends StatelessWidget {
  final String title;
  final List<WappManifest> wapps;
  final void Function(WappManifest) onOpenWapp;

  const _FolderPage({
    required this.title,
    required this.wapps,
    required this.onOpenWapp,
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
              onTap: () => onOpenWapp(wapp),
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
  }

  @override
  void dispose() {
    ProfileService.instance.activeProfileNotifier.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _addProfileFlow() async {
    // Push the welcome page as a modal to generate / import another
    // profile. On completion, saveAndActivate fires the notifier and
    // this widget rebuilds with the fresh display name. canCancel
    // adds a back arrow and leaves the user inside the current
    // profile if they bail out.
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WelcomePage(
          canCancel: true,
          onComplete: () => Navigator.of(context).pop(),
        ),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = ProfileService.instance;
    final active = service.activeProfile;
    final label = active?.displayName ?? 'No profile';
    final cs = Theme.of(context).colorScheme;

    return PopupMenuButton<String>(
      tooltip: 'Switch profile',
      offset: const Offset(0, 40),
      onSelected: (value) async {
        if (value == '__add__') {
          await _addProfileFlow();
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
                Icon(
                  p.id == active?.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: cs.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(p.displayName,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(p.callsign,
                          style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant,
                              fontFamily: 'monospace')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        const PopupMenuDivider(),
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
          Icon(Icons.badge, size: 20, color: cs.primary),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
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

  const _AppIcon({
    required this.name,
    required this.icon,
    required this.color,
    required this.onTap,
    this.textIcon,
    this.svgIconPath,
  });

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
      final raw = platform.readArbitraryFileBytesSync(svgIconPath!);
      if (raw != null) svgBytes = Uint8List.fromList(raw);
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
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
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
          const SizedBox(height: 6),
          Text(
            name,
            style: const TextStyle(fontSize: 12),
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

