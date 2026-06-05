part of 'launcher.dart';

/// First-run Android intro that explains the permissions Aurora needs and
/// requests them on Continue. Modelled on geogram's onboarding page. Shown
/// once (gated by PreferencesService.onboardingComplete); skipped on
/// non-Android platforms.
class PermissionsIntroPage extends StatefulWidget {
  final Future<void> Function() onComplete;
  const PermissionsIntroPage({super.key, required this.onComplete});

  @override
  State<PermissionsIntroPage> createState() => _PermissionsIntroPageState();
}

class _PermissionsIntroPageState extends State<PermissionsIntroPage> {
  bool _busy = false;

  Future<void> _continue() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await AndroidPermissionsService.instance.requestAll();
    } catch (_) {}
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
                          Text('Welcome to Aurora',
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
                Text('Permissions',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                for (final item in AndroidPermissionsService.items)
                  _permissionItem(
                      theme, _iconFor(item.title), item.title, item.desc),
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
                    onPressed: _busy ? null : _continue,
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Continue'),
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

  IconData _iconFor(String title) {
    switch (title) {
      case 'Bluetooth':
        return Icons.bluetooth;
      case 'Internet':
        return Icons.wifi;
      default:
        return Icons.check_circle_outline;
    }
  }

  Widget _permissionItem(
      ThemeData theme, IconData icon, String title, String desc) {
    final cs = theme.colorScheme;
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
            child: Icon(icon, size: 20, color: cs.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                Text(desc,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
