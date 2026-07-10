part of 'launcher.dart';

/// The icon dock in the collapsed all-apps peek: the wapps the user pinned
/// there, else the ones they open most, topped up from the installed list so
/// the row is never short.
class _QuickLaunchRow extends StatefulWidget {
  final List<_LauncherEntry> entries;

  const _QuickLaunchRow({required this.entries});

  @override
  State<_QuickLaunchRow> createState() => _QuickLaunchRowState();
}

class _QuickLaunchRowState extends State<_QuickLaunchRow> {
  static const int _slots = 4;

  List<String> _preferred = const [];
  String _signature = '';

  @override
  void initState() {
    super.initState();
    _signature = _entrySignature(widget.entries);
    _load();
    LaunchCountStore.instance.revision.addListener(_load);
  }

  @override
  void dispose() {
    LaunchCountStore.instance.revision.removeListener(_load);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _QuickLaunchRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _entrySignature(widget.entries);
    if (next != _signature) {
      _signature = next;
      _load();
    }
  }

  Future<void> _load() async {
    final preferred = await LaunchCountStore.instance.preferredDock(_slots);
    if (mounted) setState(() => _preferred = preferred);
  }

  @override
  Widget build(BuildContext context) {
    final selected = _resolveHomeSlot(widget.entries, _preferred, _slots);
    if (selected.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 86,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final e in selected)
            Expanded(
              child: _AppIcon(
                name: e.name,
                icon: e.icon,
                textIcon: e.textIcon,
                svgIconPath: e.svgIconPath,
                color: e.color,
                modified: e.modified,
                onTap: e.onTap,
                onEdit: e.onEdit,
                wappId: e.wappId,
                wappDir: e.wappDir,
              ),
            ),
        ],
      ),
    );
  }
}
