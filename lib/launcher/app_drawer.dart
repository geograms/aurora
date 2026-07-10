part of 'launcher.dart';

class _AppDrawer extends StatelessWidget {
  final VoidCallback onSettings;

  const _AppDrawer({required this.onSettings});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final profile = ProfileService.instance.activeProfile;
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  if (profile != null)
                    ProfileAvatar(profile: profile, size: 44)
                  else
                    CircleAvatar(
                      backgroundColor: cs.primaryContainer,
                      child: Icon(Icons.person, color: cs.onPrimaryContainer),
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      profile?.displayName ?? 'Aurora',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Settings'),
              onTap: onSettings,
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text('Aurora $kAppVersion+$kBuildNumber'),
            ),
          ],
        ),
      ),
    );
  }
}
