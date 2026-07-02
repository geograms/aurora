part of 'launcher.dart';

// ── Iwi Settings ─────────────────────────────────────────────────────

class IwiSettingsPage extends StatefulWidget {
  const IwiSettingsPage({super.key});

  @override
  State<IwiSettingsPage> createState() => _IwiSettingsPageState();
}

class _IwiSettingsPageState extends State<IwiSettingsPage> {
  PreferencesService? _prefs;
  String? _dataDir;
  List<_WappDataEntry> _wappDataEntries = [];
  final UpdateService _upd = UpdateService.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await PreferencesService.instance();
    final defaultPath = wappsDataStorage(prefs).basePath;
    await _upd.load(); // populate the stable/beta update-folder addresses
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _dataDir = prefs.wappDataDir ?? defaultPath;
    });
    await _refreshWappData();
  }

  /// Prompt for a single text value (used for the Reticulum sharing-folder
  /// addresses). Returns the trimmed input, or null if cancelled.
  Future<String?> _editTextPref({
    required String title,
    required String help,
    required String hint,
    required String initial,
  }) async {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              help,
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: hint,
                filled: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
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
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  String _folderSubtitle(String v) =>
      v.trim().isEmpty ? 'Not set (uses the built-in default)' : v.trim();

  Future<void> _editWappStoreFolder() async {
    final r = await _editTextPref(
      title: 'Wapp store folder',
      help: 'Reticulum address (npub… or hex folder id) of a signed folder '
          'that holds .wapp packages and an index.json catalog. The store '
          'fetches and verifies them peer-to-peer — no web server needed. '
          'Leave blank to use the built-in default source.',
      hint: 'npub1…',
      initial: _prefs?.wappStoreSource ?? '',
    );
    if (r == null || _prefs == null) return;
    _prefs!.wappStoreSource = r.isEmpty ? null : r;
    if (mounted) setState(() {});
  }

  Future<void> _editUpdateFolder({required bool beta}) async {
    final r = await _editTextPref(
      title: beta ? 'Update folder (beta)' : 'Update folder (stable)',
      help: 'Reticulum address (npub… or hex folder id) of the signed folder '
          'the app pulls ${beta ? 'beta' : 'stable'} releases from. Binaries '
          'are fetched peer-to-peer and verified by sha256. Leave blank to '
          'reset to the built-in default.',
      hint: 'npub1…',
      initial: beta ? _upd.betaFolder : _upd.stableFolder,
    );
    if (r == null) return;
    if (beta) {
      await _upd.setBetaFolder(r);
    } else {
      await _upd.setStableFolder(r);
    }
    if (mounted) setState(() {});
  }

  Future<void> _refreshWappData() async {
    final dataDir = _dataDir;
    if (dataDir == null) return;
    final storage = makeFilesystemStorage(dataDir);
    if (!await storage.directoryExists('')) {
      if (mounted) setState(() => _wappDataEntries = []);
      return;
    }
    final subdirs = await storage.listDirectory('');
    final entries = <_WappDataEntry>[];
    for (final sub in subdirs) {
      if (!sub.isDirectory) continue;
      var size = 0;
      try {
        final children =
            await storage.listDirectory(sub.path, recursive: true);
        for (final c in children) {
          if (!c.isDirectory) size += c.size ?? 0;
        }
      } catch (_) {}
      entries.add(_WappDataEntry(
        sub.name,
        storage.getAbsolutePath(sub.path),
        size,
      ));
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    if (mounted) setState(() => _wappDataEntries = entries);
  }

  /// Human-readable description of the current locale pref for the
  /// Settings subtitle. Shows "Auto — pt_PT" when no explicit choice
  /// has been made (so the user can see what "Auto" resolved to),
  /// and just the explicit locale otherwise.
  String _localeSubtitle() {
    final p = _prefs;
    if (p == null) return '';
    final explicit = p.localePreference;
    final effective = p.activeLocale();
    if (explicit == null || explicit.isEmpty) return 'Auto — $effective';
    return effective;
  }

  /// Persist the new locale preference and fire [LocaleChangedEvent]
  /// so every open [WappPage] reloads its translations. The empty
  /// string value ("") resets to "Auto" (follows the OS).
  void _onLocaleChanged(String? value) {
    final p = _prefs;
    if (p == null) return;
    p.localePreference = (value == null || value.isEmpty) ? null : value;
    setState(() {});
    EventBus().fire(LocaleChangedEvent(locale: p.activeLocale()));
  }

  void _onBleDebugChanged(bool enabled) {
    final p = _prefs;
    if (p == null) return;
    p.bleDebug = enabled;
    if (mounted) setState(() {});
  }

  Future<void> _onRemoteApiChanged(bool enabled) async {
    final p = _prefs;
    if (p == null) return;
    p.remoteApiEnabled = enabled;
    if (enabled) {
      await RemoteApiService.instance
          .start(port: p.remoteApiPort, navigatorKey: rootNavigatorKey);
    } else {
      await RemoteApiService.instance.stop();
    }
    if (mounted) setState(() {});
  }

  Future<void> _editRnsServers() async {
    if (_prefs == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const RnsServersPage()),
    );
    if (mounted) setState(() {}); // refresh the subtitle count on return
  }

  Future<void> _pickDirectory() async {
    final defaultPath =
        _prefs == null ? '' : wappsDataStorage(_prefs!).basePath;
    final controller = TextEditingController(text: _dataDir);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wapp Data Directory'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Each wapp stores its settings and files in a subfolder here, '
              'named after the wapp ID.',
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: 'Directory path',
                filled: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.folder_open),
                  tooltip: 'Reset to default',
                  onPressed: () => controller.text = defaultPath,
                ),
              ),
              autofocus: true,
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
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty && _prefs != null) {
      // Create the directory through the abstraction so the same code path
      // will work later with encrypted/IndexedDB backends.
      await makeFilesystemStorage(result).createDirectory('');
      _prefs!.wappDataDir = result;
      if (mounted) setState(() => _dataDir = result);
      await _refreshWappData();
    }
  }

  Future<void> _openDataDir() async {
    final dataDir = _dataDir;
    if (dataDir == null) return;
    // Make sure it exists (via the abstraction), then hand the absolute
    // path to the platform's external file manager. Both calls flow
    // through `platform.*` so the web build has a clean no-op instead
    // of a dart:io Process spawn.
    await makeFilesystemStorage(dataDir).createDirectory('');
    await platform.openInFileManager(dataDir);
  }

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _prefs == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // ── Language ──
                Text('Language',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        )),
                const SizedBox(height: 4),
                Text(
                  'Controls how wapps resolve their @key translation '
                  'sentinels. "Auto" follows the operating system.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
                  ),
                  color: cs.surfaceContainerLow,
                  child: ListTile(
                    leading: const Icon(Icons.language),
                    title: const Text('Language'),
                    subtitle: Text(
                      _localeSubtitle(),
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                    trailing: DropdownButton<String>(
                      value: _prefs?.localePreference ?? '',
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(value: '', child: Text('Auto')),
                        DropdownMenuItem(
                            value: 'en', child: Text('English')),
                        DropdownMenuItem(
                            value: 'pt', child: Text('Português')),
                        DropdownMenuItem(
                            value: 'de', child: Text('Deutsch')),
                        DropdownMenuItem(
                            value: 'fr', child: Text('Français')),
                        DropdownMenuItem(
                            value: 'es', child: Text('Español')),
                      ],
                      onChanged: _onLocaleChanged,
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // ── Updates ──
                Text('Updates',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        )),
                const SizedBox(height: 4),
                Text(
                  'Check for new Geogram releases (stable or beta) and '
                  'install them in place.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
                  ),
                  color: cs.surfaceContainerLow,
                  child: ListTile(
                    leading: const Icon(Icons.system_update),
                    title: const Text('Update Center'),
                    subtitle: Text(
                      'Version $kAppVersion',
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const UpdatePage()),
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // ── Remote control API ──
                Text('Remote control',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        )),
                const SizedBox(height: 4),
                Text(
                  'Exposes a JSON HTTP API (status, logs, launch a wapp) on '
                  'port ${_prefs?.remoteApiPort ?? 3456}. Reachable over the '
                  'network — turn off on untrusted networks.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
                  ),
                  color: cs.surfaceContainerLow,
                  child: SwitchListTile(
                    secondary: const Icon(Icons.cable),
                    title: const Text('Remote control API'),
                    subtitle: Text(
                      RemoteApiService.instance.running
                          ? 'Listening on 0.0.0.0:${_prefs?.remoteApiPort ?? 3456}'
                          : 'Off',
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                    value: _prefs?.remoteApiEnabled ?? false,
                    onChanged: _onRemoteApiChanged,
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
                  ),
                  color: cs.surfaceContainerLow,
                  child: SwitchListTile(
                    secondary: const Icon(Icons.bug_report),
                    title: const Text('BLE debug logging'),
                    subtitle: Text(
                      'Log BLE advertise/scan/broadcast activity to the app log',
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                    value: _prefs?.bleDebug ?? false,
                    onChanged: _onBleDebugChanged,
                  ),
                ),
                const SizedBox(height: 24),

                // ── Reticulum ──
                Text('Reticulum',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        )),
                const SizedBox(height: 4),
                Text(
                  'Bootstrap hubs the node connects to. It tries each in order '
                  'until one answers with real Reticulum traffic.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
                  ),
                  color: cs.surfaceContainerLow,
                  child: ListTile(
                    leading: const Icon(Icons.dns),
                    title: const Text('Bootstrap servers'),
                    subtitle: Text(
                      () {
                        final list = _prefs?.rnsBootstrapServers ?? const [];
                        if (list.isEmpty) return 'None set';
                        final n = list.length;
                        return '$n server${n == 1 ? '' : 's'} — ${list.first}'
                            '${n > 1 ? ' …' : ''}';
                      }(),
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                    trailing: const Icon(Icons.edit),
                    onTap: _editRnsServers,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Host for the mesh: act as a NOSTR relay + file host so peers '
                  'have a free place to store notes and files. Tiered fair-use '
                  'quotas apply — your own and people you follow are kept; '
                  'strangers are capped.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
                  ),
                  color: cs.surfaceContainerLow,
                  child: Column(
                    children: [
                      SwitchListTile(
                        secondary: const Icon(Icons.cloud_upload_outlined),
                        title: const Text('Host for the mesh'),
                        subtitle: Text(
                          'Store notes + files for other nodes (relay + Blossom)',
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                        value: _prefs?.hostEnabled ?? true,
                        onChanged: (v) {
                          _prefs?.hostEnabled = v;
                          RnsService.instance.applyHostingSettings();
                          setState(() {});
                        },
                      ),
                      const Divider(height: 1),
                      SwitchListTile(
                        secondary: const Icon(Icons.battery_charging_full),
                        title: const Text('Only when charging on Wi-Fi'),
                        subtitle: Text(
                          'Host only while charging on Wi-Fi/Ethernet (off = host '
                          'on any connection)',
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                        value: _prefs?.hostCapacityGated ?? true,
                        onChanged: (_prefs?.hostEnabled ?? true)
                            ? (v) {
                                _prefs?.hostCapacityGated = v;
                                RnsService.instance.applyHostingSettings();
                                setState(() {});
                              }
                            : null,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // ── Sharing folders (Reticulum) ──
                Text('Sharing folders',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        )),
                const SizedBox(height: 4),
                Text(
                  'Signed Reticulum folders the app pulls from, peer-to-peer '
                  'and verified by sha256. Each is an npub… (or hex folder id). '
                  'Change these to follow a different publisher; leave blank '
                  'for the built-in defaults.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
                  ),
                  color: cs.surfaceContainerLow,
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.widgets_outlined),
                        title: const Text('Wapp store folder'),
                        subtitle: Text(
                          _folderSubtitle(_prefs?.wappStoreSource ?? ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                        trailing: const Icon(Icons.edit),
                        onTap: _editWappStoreFolder,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.system_update_alt),
                        title: const Text('Update folder (stable)'),
                        subtitle: Text(
                          _folderSubtitle(_upd.stableFolder),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                        trailing: const Icon(Icons.edit),
                        onTap: () => _editUpdateFolder(beta: false),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.science_outlined),
                        title: const Text('Update folder (beta)'),
                        subtitle: Text(
                          _folderSubtitle(_upd.betaFolder),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                        trailing: const Icon(Icons.edit),
                        onTap: () => _editUpdateFolder(beta: true),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // ── Data Directory ──
                Text('Storage',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        )),
                const SizedBox(height: 4),
                Text(
                  'Where wapp settings, downloads, and user files are stored.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
                  ),
                  color: cs.surfaceContainerLow,
                  child: ListTile(
                    leading: const Icon(Icons.folder),
                    title: const Text('Wapp Data Directory'),
                    subtitle: Text(
                      _dataDir ?? 'Not set',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.open_in_new),
                          tooltip: 'Open in file explorer',
                          onPressed: _openDataDir,
                        ),
                        const Icon(Icons.edit),
                      ],
                    ),
                    onTap: _pickDirectory,
                  ),
                ),
                const SizedBox(height: 24),

                // ── Per-wapp data ──
                Text('Wapp Data',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        )),
                const SizedBox(height: 4),
                Text(
                  'Each subfolder contains settings and files for one wapp.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                ..._buildWappDataList(cs),
              ],
            ),
    );
  }

  List<Widget> _buildWappDataList(ColorScheme cs) {
    final entries = _wappDataEntries;
    if (entries.isEmpty) {
      return [
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
          ),
          color: cs.surfaceContainerLow,
          child: const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('No wapp data yet'),
            subtitle: Text('Data folders are created when a wapp first runs.'),
          ),
        ),
      ];
    }

    return [
      Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
        color: cs.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < entries.length; i++) ...[
              ListTile(
                leading: const Icon(Icons.extension),
                title: Text(entries[i].name),
                subtitle: Text(
                  _humanSize(entries[i].size),
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                ),
                trailing: IconButton(
                  icon: Icon(Icons.delete_outline, color: cs.error),
                  tooltip: 'Delete wapp data',
                  onPressed: () => _confirmDelete(entries[i]),
                ),
              ),
              if (i < entries.length - 1)
                Divider(
                    height: 1,
                    thickness: 1,
                    color: cs.outlineVariant.withAlpha(50)),
            ],
          ],
        ),
      ),
    ];
  }

  Future<void> _confirmDelete(_WappDataEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${entry.name}?'),
        content: Text(
            'This will permanently delete all settings and files for '
            '"${entry.name}" (${_humanSize(entry.size)}).'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        // Split the absolute path into parent + leaf and delete via the
        // abstraction so the same code path works with non-filesystem
        // backends in the future.
        final sep = platform.pathSeparator;
        final slashIdx = entry.path.lastIndexOf(sep);
        if (slashIdx > 0) {
          final parent = entry.path.substring(0, slashIdx);
          final leaf = entry.path.substring(slashIdx + 1);
          await makeFilesystemStorage(parent)
              .deleteDirectory(leaf, recursive: true);
        }
        await _refreshWappData();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete: $e')),
          );
        }
      }
    }
  }
}

class _WappDataEntry {
  final String name;
  final String path;
  final int size;
  _WappDataEntry(this.name, this.path, this.size);
}

// ── Reticulum bootstrap servers ──────────────────────────────────────────
//
// A full-screen editor for the ordered list of bootstrap hubs. The node tries
// each in order until one answers with real Reticulum traffic, so order is the
// priority. Add / edit (separate host + port fields) / remove / reorder, all
// persisted immediately.

class RnsServersPage extends StatefulWidget {
  const RnsServersPage({super.key});

  @override
  State<RnsServersPage> createState() => _RnsServersPageState();
}

class _RnsServersPageState extends State<RnsServersPage> {
  PreferencesService? _prefs;
  List<String> _servers = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await PreferencesService.instance();
    if (!mounted) return;
    setState(() {
      _prefs = p;
      _servers = List<String>.from(p.rnsBootstrapServers);
    });
  }

  void _save() {
    _prefs?.rnsBootstrapServers = _servers;
  }

  /// Split "host:port" into (host, port-string). Port defaults to "4242".
  (String, String) _split(String entry) {
    final s = entry.trim();
    final i = s.lastIndexOf(':');
    if (i <= 0 || i == s.length - 1) return (s, '4242');
    return (s.substring(0, i), s.substring(i + 1));
  }

  Future<void> _addOrEdit({int? index}) async {
    final initial = index == null ? ('', '4242') : _split(_servers[index]);
    final hostCtl = TextEditingController(text: initial.$1);
    final portCtl = TextEditingController(text: initial.$2);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(index == null ? 'Add server' : 'Edit server'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: hostCtl,
                autofocus: true,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Host',
                  hintText: 'rns.example.net',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: portCtl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Port',
                  hintText: '4242',
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
              onPressed: () {
                final host = hostCtl.text.trim();
                if (host.isEmpty) {
                  Navigator.pop(ctx);
                  return;
                }
                final port = int.tryParse(portCtl.text.trim()) ?? 4242;
                Navigator.pop(ctx, '$host:$port');
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (result == null) return;
    setState(() {
      if (index == null) {
        _servers.add(result);
      } else {
        _servers[index] = result;
      }
    });
    _save();
  }

  void _remove(int index) {
    setState(() => _servers.removeAt(index));
    _save();
  }

  void _resetDefaults() {
    setState(() {
      _prefs?.rnsBootstrapServers = <String>[]; // clears → getter returns defaults
      _servers = List<String>.from(_prefs?.rnsBootstrapServers ?? const []);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reticulum servers'),
        actions: [
          IconButton(
            icon: const Icon(Icons.restore),
            tooltip: 'Reset to defaults',
            onPressed: _resetDefaults,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEdit(),
        icon: const Icon(Icons.add),
        label: const Text('Add server'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              'Bootstrap hubs the node connects to, in priority order. It tries '
              'each from the top until one answers with real Reticulum traffic. '
              'Drag to reorder.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(
            child: _servers.isEmpty
                ? Center(
                    child: Text('No servers — tap "Add server".',
                        style: TextStyle(color: cs.onSurfaceVariant)),
                  )
                : ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 96),
                    itemCount: _servers.length,
                    onReorder: (oldI, newI) {
                      setState(() {
                        if (newI > oldI) newI -= 1;
                        final item = _servers.removeAt(oldI);
                        _servers.insert(newI, item);
                      });
                      _save();
                    },
                    itemBuilder: (context, i) {
                      final entry = _servers[i];
                      final hp = _split(entry);
                      return Card(
                        key: ValueKey('rns-srv-$i-$entry'),
                        elevation: 0,
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side:
                              BorderSide(color: cs.outlineVariant.withAlpha(80)),
                        ),
                        color: cs.surfaceContainerLow,
                        child: ListTile(
                          leading: CircleAvatar(
                            radius: 14,
                            backgroundColor: cs.primaryContainer,
                            child: Text('${i + 1}',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: cs.onPrimaryContainer)),
                          ),
                          title: Text(hp.$1,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('port ${hp.$2}',
                              style: TextStyle(color: cs.onSurfaceVariant)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit),
                                tooltip: 'Edit',
                                onPressed: () => _addOrEdit(index: i),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: 'Remove',
                                onPressed: () => _remove(i),
                              ),
                              ReorderableDragStartListener(
                                index: i,
                                child: const Padding(
                                  padding: EdgeInsets.only(left: 4),
                                  child: Icon(Icons.drag_handle),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

