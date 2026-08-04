part of 'launcher.dart';

/// Open the wapp a notification came from — on the exact conversation when
/// the notification names one. [source] follows the `wapp:<folder>`
/// convention (docs/notifications.md); anything else is not routable here.
/// Delegates to [openWappByFolder], the same door the Android notification
/// deep link uses, so both taps behave identically.
Future<bool> _openWappBySource(BuildContext context, String source,
    {String? convo}) {
  if (!source.startsWith('wapp:')) return Future.value(false);
  return openWappByFolder(
    source.substring(5).trim(),
    convo: convo,
    navigator: Navigator.of(context),
  );
}

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationStore.instance.markAllSeen();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear',
            onPressed: () => NotificationStore.instance.clear(),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<StoredNotification>>(
        valueListenable: NotificationStore.instance.items,
        builder: (context, items, _) {
          final filtered = _filtered(items);
          return Column(
            children: [
              SizedBox(
                height: 52,
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  scrollDirection: Axis.horizontal,
                  children: [
                    _chip('all', 'All'),
                    _chip('wapp', 'Wapps'),
                    _chip('host', 'Host'),
                    for (final level in NotificationLevel.values)
                      _chip(level.name, level.name),
                  ],
                ),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? const Center(child: Text('No notifications'))
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        children: _grouped(filtered),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _chip(String value, String label) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        selected: _filter == value,
        label: Text(label),
        onSelected: (_) => setState(() => _filter = value),
      ),
    );
  }

  List<StoredNotification> _filtered(List<StoredNotification> items) {
    return items
        .where((n) {
          if (_filter == 'all') return true;
          if (_filter == 'wapp') return n.source.startsWith('wapp:');
          if (_filter == 'host') return n.source.startsWith('host:');
          return n.level.name == _filter;
        })
        .toList(growable: false);
  }

  List<Widget> _grouped(List<StoredNotification> items) {
    final out = <Widget>[];
    String? lastGroup;
    for (final n in items) {
      final group = _dayLabel(n.timestamp);
      if (group != lastGroup) {
        out.add(
          Padding(
            padding: const EdgeInsets.only(top: 18, bottom: 8),
            child: Text(
              group,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
            ),
          ),
        );
        lastGroup = group;
      }
      out.add(_NotificationRow(notification: n));
    }
    return out;
  }

  String _dayLabel(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}

class _NotificationRow extends StatelessWidget {
  final StoredNotification notification;

  const _NotificationRow({required this.notification});

  @override
  Widget build(BuildContext context) {
    final color = switch (notification.level) {
      NotificationLevel.success => const Color(0xFF52C77E),
      NotificationLevel.warning => const Color(0xFFE0A11B),
      NotificationLevel.error => const Color(0xFFda3633),
      NotificationLevel.info => Theme.of(context).colorScheme.primary,
    };
    // Rows route by source: a wapp notification opens its wapp, the updater's
    // rows open Settings (which hosts Updates). Other host rows have nowhere
    // meaningful to go and stay inert (null onTap = no splash, no promise).
    final source = notification.source;
    VoidCallback? onTap;
    if (source.startsWith('wapp:')) {
      onTap = () => unawaited(
          _openWappBySource(context, source, convo: notification.convo));
    } else if (source == 'host:updates') {
      onTap = () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const IwiSettingsPage()),
          );
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: onTap,
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(_iconFor(notification), color: color),
        ),
        title: Text(notification.title),
        subtitle: (notification.body ?? '').isEmpty
            ? null
            : Text(notification.body!),
        // Who it came from goes top-right beside the time, as a NAME: the raw
        // routing id ("wapp:chat") was leaking a wire convention into the UI on
        // its own line under every message.
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              _sourceLabel(source),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _relativeTime(notification.timestamp),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(StoredNotification n) {
    if (n.source.startsWith('wapp:')) return Icons.apps;
    return switch (n.level) {
      NotificationLevel.success => Icons.check_circle_outline,
      NotificationLevel.warning => Icons.warning_amber,
      NotificationLevel.error => Icons.error_outline,
      NotificationLevel.info => Icons.notifications_none,
    };
  }

  /// Human label for a notification source. `wapp:<folder>` and `host:<service>`
  /// are routing ids (docs/notifications.md), not something to show a user:
  /// strip the prefix and title-case what is left.
  String _sourceLabel(String source) {
    var s = source;
    final colon = s.indexOf(':');
    if (colon >= 0) s = s.substring(colon + 1);
    s = s.trim();
    if (s.isEmpty) return source;
    return s[0].toUpperCase() + s.substring(1);
  }

  String _relativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }
}
