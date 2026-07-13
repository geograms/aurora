part of 'launcher.dart';

/// First-run Android intro: explains and REQUESTS every permission Aurora
/// needs, showing each one's live granted/missing state. The user cannot
/// continue to profile creation until all required permissions are granted —
/// so nothing surfaces a late prompt after a profile exists. Skipped on
/// non-Android platforms (no runtime permissions).
class PermissionsIntroPage extends StatefulWidget {
  final Future<void> Function() onComplete;
  const PermissionsIntroPage({super.key, required this.onComplete});

  @override
  State<PermissionsIntroPage> createState() => _PermissionsIntroPageState();
}

class _PermissionsIntroPageState extends State<PermissionsIntroPage>
    with WidgetsBindingObserver {
  final Map<String, bool> _granted = {};
  bool _busy = false;
  bool _allGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The All-files (special-access) grant leaves the app for system settings;
    // re-check when we come back so the row flips to granted without a manual
    // refresh, and Continue enables automatically.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final svc = AndroidPermissionsService.instance;
    for (final item in AndroidPermissionsService.items) {
      _granted[item.key] = await svc.isGranted(item);
    }
    final all = await svc.allGranted();
    if (mounted) setState(() => _allGranted = all);
  }

  Future<void> _grant(AppPermission item) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await AndroidPermissionsService.instance.requestItem(item);
    } catch (_) {}
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _grantAll() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await AndroidPermissionsService.instance.requestAll();
    } catch (_) {}
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _continue() async {
    if (!_allGranted) return;
    await widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(Icons.travel_explore,
                          size: 36, color: cs.onPrimaryContainer),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Welcome to Geogram',
                              style: theme.textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text(
                            'Off-grid messaging over Bluetooth and the internet.',
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                Row(
                  children: [
                    Text('Permissions',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text(
                      _allGranted ? 'All granted' : 'Tap to grant',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: _allGranted ? Colors.green : cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Grant these before continuing. Nothing works without them, '
                  'and asking now means no surprise prompts later.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                // Grant-all sits ABOVE the list: it is what almost everyone
                // wants, and below a full-height list it was off-screen.
                if (!_allGranted)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _grantAll,
                      icon: const Icon(Icons.done_all, size: 18),
                      label: const Text('Grant all'),
                    ),
                  ),
                if (!_allGranted) const SizedBox(height: 16),
                for (final item in AndroidPermissionsService.items)
                  _permissionItem(theme, item),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer.withAlpha(128),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.privacy_tip_outlined,
                          size: 20, color: cs.secondary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Your data stays on your device. These permissions are '
                          'only used for local messaging and connectivity.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: cs.onSecondaryContainer),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    // Disabled until every required permission is granted — the
                    // gate that stops a late prompt after profile creation.
                    onPressed: (_allGranted && !_busy) ? _continue : null,
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_allGranted
                            ? 'Continue'
                            : 'Grant permissions to continue'),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _iconFor(String name) {
    switch (name) {
      case 'bluetooth':
        return Icons.bluetooth;
      case 'notifications':
        return Icons.notifications_outlined;
      case 'folder':
        return Icons.folder_outlined;
      case 'wifi':
        return Icons.wifi;
      case 'location':
        return Icons.location_on_outlined;
      case 'battery':
        return Icons.battery_charging_full;
      default:
        return Icons.check_circle_outline;
    }
  }

  Widget _permissionItem(ThemeData theme, AppPermission item) {
    final cs = theme.colorScheme;
    final granted = _granted[item.key] ?? item.info;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(_iconFor(item.icon), size: 20, color: cs.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                Text(item.desc,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Trailing state: informational rows are auto-satisfied; required
          // rows show a green check when granted or a Grant button when not.
          if (item.info || granted)
            Icon(Icons.check_circle,
                size: 22, color: item.info ? cs.onSurfaceVariant : Colors.green)
          else
            TextButton(
              onPressed: _busy ? null : () => _grant(item),
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                minimumSize: Size.zero,
              ),
              child: const Text('Grant'),
            ),
        ],
      ),
    );
  }
}
